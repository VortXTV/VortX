#!/usr/bin/env node
"use strict";

const assert = require("assert");
const fs = require("fs");
const os = require("os");
const path = require("path");
const child = require("child_process");
const http = require("http");
const https = require("https");
const querystring = require("querystring");
const stream = require("stream");
const net = require("net");
const vm = require("vm");

const root = path.resolve(__dirname, "..");
const patcher = path.join(root, "scripts/patch-server-proxy.js");
const patchSource = fs.readFileSync(patcher, "utf8");
const start = "}, function(module, exports, __webpack_require__) {\n    var path = __webpack_require__(5), url = __webpack_require__(6), querystring = __webpack_require__(24), Router = __webpack_require__(100), stream = __webpack_require__(3), https = __webpack_require__(20), fetch = __webpack_require__(34)";
const end = "}, function(module, exports) {\n    module.exports = [ \"udp://fixture\" ];\n}";
const fixture = path.join(os.tmpdir(), `vortx-proxy-fixture-${process.pid}.js`);
const fixtureSource = "var modules = [function(module, exports, __webpack_require__) {\n" + start + "\n" + end + "];\n";
fs.writeFileSync(fixture, fixtureSource);
try {
    child.execFileSync(process.execPath, [patcher, fixture], { stdio: "pipe" });
    child.execFileSync(process.execPath, ["--check", fixture], { stdio: "pipe" });
    const output = fs.readFileSync(fixture, "utf8");
    assert(output.includes("dest.protocol === \"https:\" ? https.Agent : http.Agent") && output.includes("lookup: function"), "HTTP and verified HTTPS connect through a pinned-address agent");
    assert(!output.includes("rejectUnauthorized: !1"), "the proxy module must not disable certificate checks");
    assert(output.includes("forbiddenAddonHeaders") && output.includes("\"range\""), "addon Range is forbidden");
    assert(output.includes("if (req.headers.range) headers.set(\"range\", req.headers.range)"), "downstream Range wins");
    assert(output.includes("safeCrossOriginHeaders") && output.includes("sameOrigin(from, to)"), "cross-origin redirects use an explicit minimum header allowlist");
    assert(!output.includes("set-cookie") && !output.includes("safeCookie"), "unscoped response cookies are never propagated");
    assert(output.includes("new AbortController") && output.includes("req.once(\"aborted\", abort)"), "timeouts and disconnect abort upstream");
    assert(output.includes("setTimeout(() => controller.abort(), headTimeoutMilliseconds)") && output.includes("setTimeout(abort, 10000)"), "head and idle deadlines are bounded");
    assert((output.match(/stream\.pipeline\(/g) || []).length === 2 && output.includes("function settle(error)"), "progressive and HLS bodies have exactly-once pipeline ownership");
    assert(output.includes("clearTimeout(timer); clearTimeout(idle)") && output.includes("controller.abort(); if (!res.destroyed) res.destroy()"), "body failures clear deadlines and tear down both sides");
    assert(output.includes("res.sendStatus(error && error.name === \"AbortError\" ? 504 : 502)"), "pre-head timeout is a bounded 504");
    assert(output.includes("req.method !== \"GET\" && req.method !== \"HEAD\""), "the proxy refuses non-playback HTTP methods");
    assert(output.includes("resolvePublic(dest, controller.signal)") && output.includes("addresses.every(isPublicAddress)"), "every hop requires a cancellable wholly public DNS snapshot");
    assert(output.includes("headTimeoutMilliseconds") && output.includes("signal.addEventListener(\"abort\", aborted"), "DNS resolution shares the advertised head deadline and downstream cancellation");
    assert(output.includes("ipv4only.arpa") && output.includes("[ 32, 40, 48, 56, 64, 96 ]"), "active PREF64 discovery recognizes every RFC6052 layout");
    assert(output.includes("maximumPlaylistBytes") && output.includes("maximumPlaylistLineBytes"), "playlist bytes and partial lines have hard caps");
    assert(output.includes("result.body.resume(); result.body.destroy()"), "redirect response bodies are drained and cancelled before recursion");
    assert(output.includes("fetchOnce(dest") && !output.includes("rejectUnauthorized: false"), "each redirect/final response uses one verified fetch");
    assert(patchSource.includes("childProxy") && patchSource.includes("parseLine"), "playlist children remain routed through the proxy");
    assert(output.includes("headers: finalHeaders") && output.includes("finalHeaders.forEach")
        && !output.includes("ensureArray(opts[cfgOpts.DestinationHeader]).forEach"),
        "playlist children inherit only the credential scope that reached the final origin");
    const fetchScript = fs.readFileSync(path.join(root, "scripts/fetch-server-deps.sh"), "utf8");
    assert(fetchScript.includes('if [ "$SERVER_VERSION" != "4.21.0" ]')
        && fetchScript.indexOf('verify_sha256 "$SERVER_DEST"') < fetchScript.indexOf('node scripts/patch-server-proxy.js'),
        "only the checksum-pinned 4.21 bundle may be patched");
    const ambiguous = fixture + ".ambiguous";
    const ambiguousSource = fixtureSource.replace(end, end + "\n" + end);
    assert.strictEqual(ambiguousSource.split(start).length - 1, 1, "duplicate-end fixture retains exactly one start anchor");
    assert.strictEqual(ambiguousSource.split(end).length - 1, 2, "duplicate-end fixture contains exactly two end anchors");
    fs.writeFileSync(ambiguous, ambiguousSource);
    const ambiguousResult = child.spawnSync(process.execPath, [patcher, ambiguous], { encoding: "utf8" });
    assert.notStrictEqual(ambiguousResult.status, 0, "a duplicate end anchor must fail closed");
    assert(ambiguousResult.stderr.includes("unique proxy module anchors not found"), "duplicate end reports the explicit anchor-integrity error");
    fs.unlinkSync(ambiguous);
    executeRedirectedPlaylistFixture(output).then(({ rewritten, calls, redirectBodies, privateResult, privateIPv6Result, nat64WellKnownResult, nat64LocalResult, hostileDNSResult, nat64DNSResult, nat64LocalDNSResult, activePref64Results, publicIPv6DNSResult, publicIPv6LiteralResult, mixedDNSResult, redirectDNSResult, neverDNSResult, lateDNSResult, lateDNSCallbackCount, discoveryNeverResult, discoveryLateResult, lateDiscoveryCallbackCount, methodResult, oversizedResult }) => {
        const childURL = new URL(rewritten.trim(), "http://127.0.0.1");
        const encoded = childURL.pathname.slice("/proxy/".length).split("/")[0];
        const childOpts = querystring.parse(encoded);
        assert.strictEqual(childOpts.d, "https://b.example", "redirected playlist children target the final origin");
        assert(!Object.values(childOpts).some(value => String(value).includes("origin-a-secret")),
            "redirected playlist children never recover initial-origin credentials");
        const segment = calls.find(call => new URL(call.target).href === "https://b.example/segment.ts");
        assert(segment, "the rewritten segment request executes");
        assert.strictEqual(new URL(segment.target).href, "https://b.example/segment.ts",
            "following the rewritten child performs the segment request against the final origin");
        assert(!segment.headers.has("authorization"), "the executed child request contains no initial-origin authorization");
        const redirected = calls.find(call => new URL(call.target).hostname === "b.example" && new URL(call.target).pathname === "/list.m3u8");
        assert(!redirected.headers.has("proxy-authorization") && !redirected.headers.has("x-api-key"),
            "Proxy-Authorization and custom auth-like headers are stripped across origin");
        assert(calls.every(call => call.pinnedAddress === "8.8.8.8" || call.pinnedAddress === "2606:4700:ffff::1" || call.pinnedAddress === "2606:4700::ffff"), "each executed fetch uses only its vetted pinned address");
        assert.strictEqual(privateResult.status, 502, "private literal destinations fail before fetch");
        assert.strictEqual(privateIPv6Result.status, 502, "private IPv6 literals fail before fetch");
        assert.strictEqual(nat64WellKnownResult.status, 502, "well-known NAT64 literals cannot synthesize loopback destinations");
        assert.strictEqual(nat64LocalResult.status, 502, "local-use NAT64 literals cannot synthesize private destinations");
        assert.strictEqual(hostileDNSResult.status, 502, "private DNS answers fail before fetch");
        assert.strictEqual(nat64DNSResult.status, 502, "NAT64 DNS answers fail before fetch");
        assert.strictEqual(nat64LocalDNSResult.status, 502, "local-use NAT64 DNS answers fail before fetch");
        assert(activePref64Results.length === 6 && activePref64Results.every(result => result.status === 502),
            "active global /96, /64, and /40 PREF64 targets are rejected as both literals and DNS answers");
        assert.strictEqual(publicIPv6DNSResult.status, 200, "globally routed IPv6 remains valid when ffff is an interior hextet");
        assert.strictEqual(publicIPv6LiteralResult.status, 200, "globally routed IPv6 remains valid when ffff is the final hextet");
        assert.strictEqual(mixedDNSResult.status, 502, "mixed public/private DNS snapshots fail closed against rebinding");
        assert.strictEqual(redirectDNSResult.status, 502, "a redirect hop resolving private fails before its fetch");
        assert(neverDNSResult.status === 504 && neverDNSResult.elapsed < 250 && neverDNSResult.abortListeners === 0,
            "a non-returning resolver gets a prompt 504 and releases its downstream listener");
        assert(lateDNSResult.status === 504 && lateDNSCallbackCount === 1,
            "a late resolver callback is ignored after timeout cleanup");
        assert(discoveryNeverResult.status === 504 && discoveryLateResult.status === 504 && lateDiscoveryCallbackCount === 1,
            "unavailable and late PREF64 discovery fail IPv6 closed without accepting a late prefix");
        assert.strictEqual(methodResult.status, 405, "non-GET/HEAD methods are rejected");
        assert(oversizedResult.closed && oversizedResult.status === 200, "unterminated over-limit playlist is terminated after headers");
        assert(redirectBodies.length === 2 && redirectBodies.every(body => body.destroyed), "redirect response bodies are destroyed before the next hop");
        console.log("Embedded server proxy hardening: PASS (53 checks)");
    }).catch(error => { process.nextTick(() => { throw error; }); });
} finally {
    // The behavior promise has already loaded the generated module source into memory.
    try { fs.unlinkSync(fixture); } catch (_) {}
}

async function executeRedirectedPlaylistFixture(generatedSource) {
    let handler;
    const calls = [], redirectBodies = [];
    const Router = () => ({ all: (_, callback) => { handler = callback; return this; } });
    const HeadersImpl = globalThis.Headers;
    const fetchFixture = async (target, options) => {
        const parsed = new URL(target);
        const pinnedAddress = await new Promise((resolve, reject) => {
            options.agent.options.lookup(parsed.hostname, {}, (error, address) => error ? reject(error) : resolve(address));
        });
        calls.push({ target, headers: options.headers, pinnedAddress });
        if (parsed.hostname === "a.example") {
            const body = stream.Readable.from(["discard-me"]); redirectBodies.push(body);
            return { status: 302, headers: new HeadersImpl({ location: "https://b.example/list.m3u8" }), body };
        }
        if (parsed.hostname === "redirect-private.example") {
            const body = stream.Readable.from(["discard-private-hop"]); redirectBodies.push(body);
            return { status: 302, headers: new HeadersImpl({ location: "https://private.example/secret" }), body };
        }
        if (parsed.hostname === "big.example") {
            return { status: 200, headers: new HeadersImpl({ "content-type": "application/vnd.apple.mpegurl" }), body: stream.Readable.from(["x".repeat(70_000)]) };
        }
        if (parsed.hostname === "public-v6.example" || parsed.hostname === "[2606:4700::ffff]") {
            return { status: 200, headers: new HeadersImpl({ "content-type": "video/mp2t" }), body: stream.Readable.from(["OK"]) };
        }
        assert.strictEqual(parsed.hostname, "b.example");
        if (parsed.pathname === "/list.m3u8") {
            return { status: 200, headers: new HeadersImpl({ "content-type": "application/vnd.apple.mpegurl" }), body: stream.Readable.from(["segment.ts\n"]) };
        }
        return { status: 200, headers: new HeadersImpl({ "content-type": "video/mp2t" }), body: stream.Readable.from(["OK"]) };
    };
    fetchFixture.Headers = HeadersImpl;
    const dnsAnswers = {
        "a.example": [ { address: "8.8.8.8", family: 4 } ],
        "b.example": [ { address: "8.8.8.8", family: 4 } ],
        "big.example": [ { address: "8.8.8.8", family: 4 } ],
        "redirect-private.example": [ { address: "8.8.8.8", family: 4 } ],
        "private.example": [ { address: "127.0.0.1", family: 4 } ],
        "nat64.example": [ { address: "64:ff9b::7f00:1", family: 6 } ],
        "nat64-local.example": [ { address: "64:ff9b:1::a00:1", family: 6 } ],
        "public-v6.example": [ { address: "2606:4700:ffff::1", family: 6 } ],
        "pref64-96.example": [ { address: "2001:4860:64::a00:1", family: 6 } ],
        "pref64-64.example": [ { address: "2001:4860:abcd:1234:a:0:100:0", family: 6 } ],
        "pref64-40.example": [ { address: "2001:4860:ab0a:0:1::", family: 6 } ],
        "mixed.example": [ { address: "8.8.8.8", family: 4 }, { address: "127.0.0.1", family: 4 } ]
    };
    let lateDNSCallbackCount = 0, lateDiscoveryCallbackCount = 0, pref64Mode = "normal", pref64Answers = [ { address: "2001:4860:64::c000:aa", family: 6 } ];
    const dnsFixture = { lookup(host, options, callback) {
        if (host === "ipv4only.arpa") {
            if (pref64Mode === "never") return;
            if (pref64Mode === "late") return setTimeout(() => { lateDiscoveryCallbackCount += 1; callback(null, pref64Answers); }, 60);
            return callback(null, pref64Answers);
        }
        if (host === "never.example") return;
        if (host === "late.example") return setTimeout(() => { lateDNSCallbackCount += 1; callback(null, [ { address: "8.8.8.8", family: 4 } ]); }, 60);
        callback(null, dnsAnswers[host] || []);
    } };
    const context = { AbortController, Buffer, clearTimeout, setTimeout: (callback, milliseconds) => setTimeout(callback, milliseconds === 15000 ? 20 : milliseconds) };
    vm.runInNewContext(generatedSource, context);
    const proxyModule = { exports: {} };
    const dependencies = { 3: stream, 5: path, 6: require("url"), 11: http, 20: https, 24: querystring, 34: fetchFixture, 39: net, 100: Router, 620: dnsFixture };
    context.modules[1](proxyModule, proxyModule.exports, id => dependencies[id]);
    proxyModule.exports.getRouter();

    async function request(opts, pathname, method = "GET") {
        const startedAt = Date.now();
        const req = new (require("events").EventEmitter)();
        req.params = { opts, pathname }; req.headers = {}; req.method = method; req.search = "";
        const chunks = [];
        const res = new stream.Writable({ write(chunk, _, done) { chunks.push(Buffer.from(chunk)); done(); } });
        res.writeHead = (status, headers) => { res.statusCode = status; res.responseHeaders = headers; };
        res.sendStatus = status => { res.statusCode = status; res.end(); };
        let closed = false, streamError;
        const finished = new Promise((resolve, reject) => {
            let resolved = false;
            const complete = () => { if (!resolved) { resolved = true; resolve(); } };
            res.once("finish", complete); res.once("close", () => { closed = true; complete(); });
            res.once("error", error => { streamError = error; complete(); });
        });
        handler(req, res, error => { if (error) res.destroy(error); });
        await finished;
        return { body: Buffer.concat(chunks).toString("utf8"), status: res.statusCode, closed, streamError, elapsed: Date.now() - startedAt, abortListeners: req.listenerCount("aborted") };
    }
    const first = await request(querystring.stringify({ d: "https://a.example", h: [ "Authorization:Bearer origin-a-secret", "Proxy-Authorization:Basic proxy-secret", "X-Api-Key:custom-secret" ] }), "list.m3u8");
    const rewritten = first.body;
    const childURL = new URL(rewritten.trim(), "http://127.0.0.1");
    const childParts = childURL.pathname.slice("/proxy/".length).split("/");
    await request(childParts.shift(), childParts.join("/"));
    const beforeHostile = calls.length;
    const privateResult = await request(querystring.stringify({ d: "http://127.0.0.1" }), "secret");
    const privateIPv6Result = await request(querystring.stringify({ d: "http://[::ffff:127.0.0.1]" }), "secret");
    const nat64WellKnownResult = await request(querystring.stringify({ d: "http://[64:ff9b::7f00:1]" }), "secret");
    const nat64LocalResult = await request(querystring.stringify({ d: "http://[64:ff9b:1::a00:1]" }), "secret");
    const hostileDNSResult = await request(querystring.stringify({ d: "https://private.example" }), "secret");
    const nat64DNSResult = await request(querystring.stringify({ d: "https://nat64.example" }), "secret");
    const nat64LocalDNSResult = await request(querystring.stringify({ d: "https://nat64-local.example" }), "secret");
    const mixedDNSResult = await request(querystring.stringify({ d: "https://mixed.example" }), "secret");
    assert.strictEqual(calls.length, beforeHostile, "unsafe destinations never reach fetch");
    const redirectDNSResult = await request(querystring.stringify({ d: "https://redirect-private.example" }), "start");
    assert.strictEqual(calls.length, beforeHostile + 1, "private redirect target is rejected before its own fetch");
    const activePref64Results = [];
    pref64Answers = [ { address: "2001:4860:64::c000:aa", family: 6 } ];
    activePref64Results.push(await request(querystring.stringify({ d: "http://[2001:4860:64::a00:1]" }), "secret"));
    activePref64Results.push(await request(querystring.stringify({ d: "https://pref64-96.example" }), "secret"));
    pref64Answers = [ { address: "2001:4860:abcd:1234:c0:0:aa00:0", family: 6 } ];
    activePref64Results.push(await request(querystring.stringify({ d: "http://[2001:4860:abcd:1234:a:0:100:0]" }), "secret"));
    activePref64Results.push(await request(querystring.stringify({ d: "https://pref64-64.example" }), "secret"));
    pref64Answers = [ { address: "2001:4860:abc0:0:aa::", family: 6 } ];
    activePref64Results.push(await request(querystring.stringify({ d: "http://[2001:4860:ab0a:0:1::]" }), "secret"));
    activePref64Results.push(await request(querystring.stringify({ d: "https://pref64-40.example" }), "secret"));
    assert.strictEqual(calls.length, beforeHostile + 1, "active PREF64 destinations never reach fetch");
    pref64Answers = [ { address: "2001:4860:64::c000:aa", family: 6 } ];
    const publicIPv6DNSResult = await request(querystring.stringify({ d: "https://public-v6.example" }), "video.ts");
    const publicIPv6LiteralResult = await request(querystring.stringify({ d: "http://[2606:4700::ffff]" }), "video.ts");
    const beforeResolverTimeouts = calls.length;
    const neverDNSResult = await request(querystring.stringify({ d: "https://never.example" }), "secret");
    const lateDNSResult = await request(querystring.stringify({ d: "https://late.example" }), "secret");
    await new Promise(resolve => setTimeout(resolve, 80));
    assert.strictEqual(calls.length, beforeResolverTimeouts, "timed-out and late DNS resolutions never create an agent or fetch");
    pref64Mode = "never";
    const discoveryNeverResult = await request(querystring.stringify({ d: "https://public-v6.example" }), "video.ts");
    pref64Mode = "late";
    const discoveryLateResult = await request(querystring.stringify({ d: "https://public-v6.example" }), "video.ts");
    await new Promise(resolve => setTimeout(resolve, 80)); pref64Mode = "normal";
    assert.strictEqual(calls.length, beforeResolverTimeouts, "timed-out and late PREF64 discovery never create an agent or fetch");
    const methodResult = await request(querystring.stringify({ d: "https://b.example" }), "segment.ts", "POST");
    const oversizedResult = await request(querystring.stringify({ d: "https://big.example" }), "list.m3u8");
    return { rewritten, calls, redirectBodies, privateResult, privateIPv6Result, nat64WellKnownResult, nat64LocalResult, hostileDNSResult, nat64DNSResult, nat64LocalDNSResult, activePref64Results, publicIPv6DNSResult, publicIPv6LiteralResult, mixedDNSResult, redirectDNSResult, neverDNSResult, lateDNSResult, lateDNSCallbackCount, discoveryNeverResult, discoveryLateResult, lateDiscoveryCallbackCount, methodResult, oversizedResult };
}
