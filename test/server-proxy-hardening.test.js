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
const vm = require("vm");

const root = path.resolve(__dirname, "..");
const patcher = path.join(root, "scripts/patch-server-proxy.js");
const patchSource = fs.readFileSync(patcher, "utf8");
const start = "}, function(module, exports, __webpack_require__) {\n    var path = __webpack_require__(5), url = __webpack_require__(6), querystring = __webpack_require__(24), Router = __webpack_require__(100), stream = __webpack_require__(3), https = __webpack_require__(20), fetch = __webpack_require__(34)";
const end = "}, function(module, exports) {\n    module.exports = [ \"udp://fixture\" ];\n}";
const fixture = path.join(os.tmpdir(), `vortx-proxy-fixture-${process.pid}.js`);
fs.writeFileSync(fixture, "var modules = [function(module, exports, __webpack_require__) {\n" + start + "\n" + end + "];\n");
try {
    child.execFileSync(process.execPath, [patcher, fixture], { stdio: "pipe" });
    child.execFileSync(process.execPath, ["--check", fixture], { stdio: "pipe" });
    const output = fs.readFileSync(fixture, "utf8");
    assert(output.includes("https: new https.Agent") && output.includes("http: new http.Agent"), "HTTP and verified HTTPS use scheme-appropriate agents");
    assert(!output.includes("rejectUnauthorized: !1"), "the proxy module must not disable certificate checks");
    assert(output.includes("forbiddenAddonHeaders") && output.includes("\"range\""), "addon Range is forbidden");
    assert(output.includes("if (req.headers.range) headers.set(\"range\", req.headers.range)"), "downstream Range wins");
    assert(output.includes("sensitiveHeaders") && output.includes("sameOrigin(from, to)"), "redirect credentials are origin-bound");
    assert(!output.includes("set-cookie") && !output.includes("safeCookie"), "unscoped response cookies are never propagated");
    assert(output.includes("new AbortController") && output.includes("req.once(\"aborted\", abort)"), "timeouts and disconnect abort upstream");
    assert(output.includes("setTimeout(() => controller.abort(), 15000)") && output.includes("setTimeout(abort, 10000)"), "head and idle deadlines are bounded");
    assert((output.match(/stream\.pipeline\(/g) || []).length === 2 && output.includes("function settle(error)"), "progressive and HLS bodies have exactly-once pipeline ownership");
    assert(output.includes("clearTimeout(timer); clearTimeout(idle)") && output.includes("controller.abort(); if (!res.destroyed) res.destroy()"), "body failures clear deadlines and tear down both sides");
    assert(output.includes("res.sendStatus(error && error.name === \"AbortError\" ? 504 : 502)"), "pre-head timeout is a bounded 504");
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
    fs.writeFileSync(ambiguous, fs.readFileSync(fixture, "utf8") + "\n" + end);
    assert.throws(() => child.execFileSync(process.execPath, [patcher, ambiguous], { stdio: "pipe" }),
        "a duplicate end anchor must fail closed");
    fs.unlinkSync(ambiguous);
    executeRedirectedPlaylistFixture(output).then(({ rewritten, calls }) => {
        const childURL = new URL(rewritten.trim(), "http://127.0.0.1");
        const encoded = childURL.pathname.slice("/proxy/".length).split("/")[0];
        const childOpts = querystring.parse(encoded);
        assert.strictEqual(childOpts.d, "https://b.example", "redirected playlist children target the final origin");
        assert(!Object.values(childOpts).some(value => String(value).includes("origin-a-secret")),
            "redirected playlist children never recover initial-origin credentials");
        const segment = calls[calls.length - 1];
        assert.strictEqual(new URL(segment.target).href, "https://b.example/segment.ts",
            "following the rewritten child performs the segment request against the final origin");
        assert(!segment.headers.has("authorization"), "the executed child request contains no initial-origin authorization");
        console.log("Embedded server proxy hardening: PASS (20 checks)");
    }).catch(error => { process.nextTick(() => { throw error; }); });
} finally {
    // The behavior promise has already loaded the generated module source into memory.
    try { fs.unlinkSync(fixture); } catch (_) {}
}

async function executeRedirectedPlaylistFixture(generatedSource) {
    let handler;
    const calls = [];
    const Router = () => ({ all: (_, callback) => { handler = callback; return this; } });
    const HeadersImpl = globalThis.Headers;
    const fetchFixture = async (target, options) => {
        const parsed = new URL(target);
        calls.push({ target, headers: options.headers });
        if (parsed.hostname === "a.example") {
            return { status: 302, headers: new HeadersImpl({ location: "https://b.example/list.m3u8" }), body: stream.Readable.from([]) };
        }
        assert.strictEqual(parsed.hostname, "b.example");
        if (parsed.pathname === "/list.m3u8") {
            return { status: 200, headers: new HeadersImpl({ "content-type": "application/vnd.apple.mpegurl" }), body: stream.Readable.from(["segment.ts\n"]) };
        }
        return { status: 200, headers: new HeadersImpl({ "content-type": "video/mp2t" }), body: stream.Readable.from(["OK"]) };
    };
    fetchFixture.Headers = HeadersImpl;
    const context = { AbortController, clearTimeout, setTimeout };
    vm.runInNewContext(generatedSource, context);
    const proxyModule = { exports: {} };
    const dependencies = { 3: stream, 5: path, 6: require("url"), 11: http, 20: https, 24: querystring, 34: fetchFixture, 100: Router };
    context.modules[1](proxyModule, proxyModule.exports, id => dependencies[id]);
    proxyModule.exports.getRouter();

    async function request(opts, pathname) {
        const req = new (require("events").EventEmitter)();
        req.params = { opts, pathname }; req.headers = {}; req.method = "GET"; req.search = "";
        const chunks = [];
        const res = new stream.Writable({ write(chunk, _, done) { chunks.push(Buffer.from(chunk)); done(); } });
        res.writeHead = (status, headers) => { res.statusCode = status; res.responseHeaders = headers; };
        res.sendStatus = status => { res.statusCode = status; res.end(); };
        const finished = new Promise((resolve, reject) => { res.once("finish", resolve); res.once("error", reject); });
        handler(req, res, error => { if (error) res.destroy(error); });
        await finished;
        return Buffer.concat(chunks).toString("utf8");
    }
    const rewritten = await request(querystring.stringify({ d: "https://a.example", h: "Authorization:Bearer origin-a-secret" }), "list.m3u8");
    const childURL = new URL(rewritten.trim(), "http://127.0.0.1");
    const childParts = childURL.pathname.slice("/proxy/".length).split("/");
    await request(childParts.shift(), childParts.join("/"));
    return { rewritten, calls };
}
