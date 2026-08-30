#!/usr/bin/env node
"use strict";

// Replaces only the vendored streaming server's proxy webpack module. The upstream bundle is fetched and
// checksum-verified first, so this deterministic post-fetch patch remains reviewable and reproducible.
const fs = require("fs");
const file = process.argv[2] || "app/Resources/server.js";
const source = fs.readFileSync(file, "utf8");
const startMarker = "}, function(module, exports, __webpack_require__) {\n    var path = __webpack_require__(5), url = __webpack_require__(6), querystring = __webpack_require__(24), Router = __webpack_require__(100), stream = __webpack_require__(3), https = __webpack_require__(20), fetch = __webpack_require__(34)";
const endMarker = "}, function(module, exports) {\n    module.exports = [ \"udp://";
const start = source.indexOf(startMarker);
const end = source.indexOf(endMarker, start + startMarker.length);
if (start < 0 || end < 0 || source.indexOf(startMarker, start + 1) >= 0 || source.indexOf(endMarker, end + 1) >= 0) {
    throw new Error("patch-server-proxy: unique proxy module anchors not found");
}

const moduleSource = `}, function(module, exports, __webpack_require__) {
    var path = __webpack_require__(5), url = __webpack_require__(6), querystring = __webpack_require__(24), Router = __webpack_require__(100), stream = __webpack_require__(3), http = __webpack_require__(11), https = __webpack_require__(20), net = __webpack_require__(39), dns = __webpack_require__(620), fetch = __webpack_require__(34), Headers = fetch.Headers, cfgOpts = {
        Destination: "d", DestinationHeader: "h", ResponseHeader: "r"
    }, proxyReqHeaders = [ "accept", "accept-language", "range", "if-range", "user-agent" ], proxyResHeaders = [ "accept-ranges", "content-type", "content-length", "content-range", "connection", "transfer-encoding", "last-modified", "etag", "server", "date" ], supportedPlaylists = [ ".m3u", ".m3u8" ], forbiddenAddonHeaders = new Set([ "host", "connection", "content-length", "transfer-encoding", "proxy-connection", "proxy-authorization", "proxy-authenticate", "upgrade", "range", "te", "trailer", "keep-alive" ]), safeCrossOriginHeaders = new Set([ "accept", "accept-language", "range", "if-range", "user-agent" ]), maximumPlaylistBytes = 2097152, maximumPlaylistLineBytes = 65536, headTimeoutMilliseconds = 15000;
    function ensureArray(value) { return Array.isArray(value) ? value : value ? [ value ] : []; }
    function validName(name) { return /^[!#$%&'*+.^_\\\`|~0-9A-Za-z-]+$/.test(name); }
    function validValue(value) { return !/[\\r\\n]/.test(value); }
    function parseHeaderString(value) {
        var colon = value.indexOf(":");
        if (colon <= 0) return null;
        var name = value.slice(0, colon), field = value.slice(colon + 1);
        return validName(name) && validValue(field) && !forbiddenAddonHeaders.has(name.toLowerCase()) ? [ name, field ] : null;
    }
    function makeHeaders(sourceHeaders, allowedHeaders, defaults) {
        return allowedHeaders.reduce((headers, header) => {
            if (sourceHeaders.has(header)) headers[header] = sourceHeaders.get(header);
            return headers;
        }, defaults || {});
    }
    function applyAddonHeaders(headers, values) {
        values.forEach(value => { var parsed = parseHeaderString(value); if (parsed) headers.set(parsed[0], parsed[1]); });
    }
    function sameOrigin(a, b) {
        return a.protocol === b.protocol && a.hostname.toLowerCase() === b.hostname.toLowerCase() && (a.port || (a.protocol === "https:" ? "443" : "80")) === (b.port || (b.protocol === "https:" ? "443" : "80"));
    }
    function redirectedHeaders(headers, from, to) {
        var next = new Headers;
        headers.forEach((value, name) => { if (sameOrigin(from, to) || safeCrossOriginHeaders.has(name.toLowerCase())) next.set(name, value); });
        next.set("host", to.host);
        return next;
    }
    function isPublicAddress(address) {
        var family = net.isIP(address);
        if (family === 4) {
            var p = address.split(".").map(Number);
            return !(p[0] === 0 || p[0] === 10 || p[0] === 127 || p[0] >= 224
                || (p[0] === 100 && p[1] >= 64 && p[1] <= 127)
                || (p[0] === 169 && p[1] === 254) || (p[0] === 172 && p[1] >= 16 && p[1] <= 31)
                || (p[0] === 192 && (p[1] === 168 || (p[1] === 0 && (p[2] === 0 || p[2] === 2))))
                || (p[0] === 198 && (p[1] === 18 || p[1] === 19 || p[1] === 51 && p[2] === 100))
                || (p[0] === 203 && p[1] === 0 && p[2] === 113));
        }
        if (family !== 6) return false;
        var lower = address.toLowerCase();
        if (lower.startsWith("::ffff:")) return isPublicAddress(lower.slice(7));
        var compact = lower.replace(/:/g, "");
        // Only globally routed unicast is accepted. This deliberately excludes the well-known and
        // local-use NAT64 prefixes, which could otherwise synthesize a private IPv4 destination.
        return /^[23]/.test(lower) && !lower.includes(".")
            && !/^2001:0*db8:/.test(lower) && !/^fe[c-f]/.test(lower) && !/^0+$/.test(compact) && !/^0*1$/.test(compact);
    }
    function abortError() { var error = new Error("Destination resolution timed out"); error.name = "AbortError"; return error; }
    function lookupAddresses(hostname, signal) {
        return new Promise((resolve, reject) => {
            var settled = false, timer;
            function aborted() { if (!settled) { finish(); reject(abortError()); } }
            function finish() { settled = true; clearTimeout(timer); signal.removeEventListener("abort", aborted); }
            signal.addEventListener("abort", aborted, { once: true });
            if (signal.aborted) return aborted();
            timer = setTimeout(aborted, headTimeoutMilliseconds);
            dns.lookup(hostname, { all: true, verbatim: true }, (error, answers) => {
                if (settled) return;
                finish();
                if (error || !Array.isArray(answers) || !answers.length) return reject(error || new Error("Empty DNS answer"));
                resolve(answers.map(answer => typeof answer === "string" ? answer : answer.address));
            });
        });
    }
    function ipv6Bytes(address) {
        if (net.isIP(address) !== 6 || address.includes(".")) return null;
        var sides = address.toLowerCase().split("::");
        if (sides.length > 2) return null;
        var left = sides[0] ? sides[0].split(":") : [], right = sides.length === 2 && sides[1] ? sides[1].split(":") : [];
        var missing = 8 - left.length - right.length;
        if (missing < 0 || (sides.length === 1 && missing !== 0)) return null;
        var words = left.concat(Array(missing).fill("0"), right).map(word => parseInt(word, 16));
        if (words.length !== 8 || words.some(word => !Number.isInteger(word) || word < 0 || word > 65535)) return null;
        return words.reduce((bytes, word) => bytes.concat([ word >> 8, word & 255 ]), []);
    }
    function bit(bytes, index) { return bytes[index >> 3] >> (7 - (index & 7)) & 1; }
    function embeddedIPv4(bytes, prefixLength) {
        if (prefixLength !== 96 && bytes[8] !== 0) return null;
        var beforeU = prefixLength === 96 ? 32 : 64 - prefixLength, value = 0;
        for (var index = 0; index < 32; index++) value = value * 2 + bit(bytes, index < beforeU ? prefixLength + index : 72 + index - beforeU);
        var suffixStart = prefixLength === 96 ? 128 : 72 + 32 - beforeU;
        for (var suffix = suffixStart; suffix < 128; suffix++) if (bit(bytes, suffix)) return null;
        return [ value >>> 24, value >>> 16 & 255, value >>> 8 & 255, value & 255 ];
    }
    function samePrefix(bytes, prefix) {
        for (var index = 0; index < prefix.length; index++) if (bit(bytes, index) !== prefix.bits[index]) return false;
        return true;
    }
    function discoverPref64(signal) {
        // Do not cache across requests: a network transition can change PREF64 without changing process state.
        return lookupAddresses("ipv4only.arpa", signal).then(addresses => {
            var prefixes = [];
            addresses.forEach(address => {
                var bytes = ipv6Bytes(address);
                if (!bytes) return;
                [ 32, 40, 48, 56, 64, 96 ].forEach(length => {
                    var embedded = embeddedIPv4(bytes, length);
                    if (embedded && embedded[0] === 192 && embedded[1] === 0 && embedded[2] === 0 && (embedded[3] === 170 || embedded[3] === 171)) {
                        prefixes.push({ length: length, bits: Array.from({ length: length }, (_, index) => bit(bytes, index)) });
                    }
                });
            });
            if (!prefixes.length) throw new Error("PREF64 unavailable");
            return prefixes;
        });
    }
    function rejectActivePref64(addresses, signal) {
        var ipv6 = addresses.filter(address => net.isIP(address) === 6);
        if (!ipv6.length) return Promise.resolve();
        return discoverPref64(signal).then(prefixes => {
            if (ipv6.some(address => { var bytes = ipv6Bytes(address); return !bytes || prefixes.some(prefix => samePrefix(bytes, prefix)); })) throw new Error("Unsafe PREF64 destination");
        });
    }
    function resolvePublic(dest, signal) {
        if (net.isIP(dest.hostname)) {
            if (!isPublicAddress(dest.hostname)) return Promise.reject(new Error("Unsafe destination"));
            return rejectActivePref64([ dest.hostname ], signal).then(() => dest.hostname);
        }
        return lookupAddresses(dest.hostname, signal).then(addresses => {
            if (!addresses.every(isPublicAddress)) throw new Error("Unsafe DNS answer");
            return rejectActivePref64(addresses, signal).then(() => addresses[0]);
        });
    }
    function pinnedAgent(dest, address) {
        var Agent = dest.protocol === "https:" ? https.Agent : http.Agent;
        return new Agent({ lookup: function(_, options, callback) { callback(null, address, net.isIP(address)); } });
    }
    function fetchOnce(dest, req, headers, controller) {
        return resolvePublic(dest, controller.signal).then(address => {
            var agent = pinnedAgent(dest, address);
            return fetch(url.format(dest), { method: req.method, headers: headers, agent: agent, redirect: "manual", signal: controller.signal })
                .then(result => ({ result: result, agent: agent }), error => { agent.destroy(); throw error; });
        });
    }
    function releaseRedirect(result, agent) {
        if (result.body) { result.body.resume(); result.body.destroy(); }
        agent.destroy();
    }
    function fetchWithRedirects(dest, req, headers, controller) {
        var count = 0;
        function next() {
            return fetchOnce(dest, req, headers, controller).then(({ result, agent }) => {
                if (!(result.status >= 300 && result.status < 400 && result.headers.has("location"))) return { result: result, dest: dest, headers: headers, agent: agent };
                releaseRedirect(result, agent);
                if (++count > 4) throw new Error("Too many redirects");
                var target = url.parse(url.resolve(url.format(dest), result.headers.get("location")));
                if (target.protocol !== "https:" && target.protocol !== "http:") throw new Error("Unsafe redirect");
                headers = redirectedHeaders(headers, dest, target);
                dest = target;
                return next();
            });
        }
        return next();
    }
    module.exports = { getRouter: function() {
        var router = Router();
        return router.all("/:opts/:pathname(*)?", function(req, res, next) {
            if (req.method !== "GET" && req.method !== "HEAD") return res.sendStatus(405);
            var opts = querystring.parse(req.params.opts);
            opts[cfgOpts.DestinationHeader] = ensureArray(opts[cfgOpts.DestinationHeader]);
            opts[cfgOpts.ResponseHeader] = ensureArray(opts[cfgOpts.ResponseHeader]);
            var dest = url.parse(opts[cfgOpts.Destination]);
            if (!dest || (dest.protocol !== "https:" && dest.protocol !== "http:") || !dest.hostname) return res.sendStatus(400);
            dest.pathname = req.params.pathname || ""; dest.search = req.search || "";
            var headers = new Headers(makeHeaders(new Headers(req.headers), proxyReqHeaders, { host: dest.host }));
            applyAddonHeaders(headers, opts[cfgOpts.DestinationHeader]);
            if (req.headers.range) headers.set("range", req.headers.range);
            else headers.delete("range");
            var controller = new AbortController, started = false, settled = false, activeAgent, idle, timer = setTimeout(() => controller.abort(), headTimeoutMilliseconds);
            function abort() { controller.abort(); }
            function settle(error) {
                if (settled) return;
                settled = true; clearTimeout(timer); clearTimeout(idle);
                req.removeListener("aborted", abort);
                if (activeAgent) activeAgent.destroy();
                if (error) { controller.abort(); if (!res.destroyed) res.destroy(); }
            }
            function failBeforeHead(error) {
                if (settled) return;
                settled = true; clearTimeout(timer); clearTimeout(idle); req.removeListener("aborted", abort); controller.abort();
                res.sendStatus(error && error.name === "AbortError" ? 504 : 502);
            }
            req.once("aborted", abort); res.once("close", function() { if (!res.writableEnded) { abort(); settle(new Error("downstream closed")); } });
            fetchWithRedirects(dest, req, headers, controller).then(({ result, dest: finalDest, headers: finalHeaders, agent }) => {
                clearTimeout(timer); started = true; activeAgent = agent;
                var responseHeaders = makeHeaders(result.headers, proxyResHeaders);
                opts[cfgOpts.ResponseHeader].forEach(value => { var parsed = parseHeaderString(value); if (parsed) responseHeaders[parsed[0]] = parsed[1]; });
                var isPlaylist = supportedPlaylists.includes(path.extname(finalDest.pathname)) || (responseHeaders["content-type"] || "").toLowerCase().includes("mpegurl");
                if (isPlaylist) { delete responseHeaders["content-length"]; responseHeaders["accept-ranges"] = "none"; responseHeaders["transfer-encoding"] = "chunked"; }
                res.writeHead(result.status, responseHeaders);
                function armIdle() { clearTimeout(idle); idle = setTimeout(abort, 10000); }
                result.body.on("data", armIdle); armIdle();
                if (!isPlaylist) return stream.pipeline(result.body, res, settle);
                var rewrite = (function(baseDest) {
                    var partialLine = "", eol = null, totalBytes = 0;
                    function childProxy(lineUrl) {
                        var same = sameOrigin(baseDest, lineUrl), childOpts = {};
                        childOpts[cfgOpts.Destination] = lineUrl.protocol + "//" + lineUrl.host;
                        childOpts[cfgOpts.DestinationHeader] = [];
                        finalHeaders.forEach((value, name) => {
                            var lower = name.toLowerCase();
                            if (!forbiddenAddonHeaders.has(lower) && (same || safeCrossOriginHeaders.has(lower))) {
                                childOpts[cfgOpts.DestinationHeader].push(name + ":" + value);
                            }
                        });
                        return "/proxy/" + querystring.stringify(childOpts) + lineUrl.pathname + (lineUrl.search || "");
                    }
                    function parseUrl(line) {
                        var resolved = url.parse(url.resolve(url.format(baseDest), line));
                        if (resolved.protocol !== "https:" && resolved.protocol !== "http:") return line;
                        return childProxy(resolved);
                    }
                    function parseLine(line) {
                        if (!line.startsWith("#") && line.length > 0) return parseUrl(line);
                        var uri = line.match(/URI="([^"]+)"/);
                        return uri ? line.replace(uri[1], parseUrl(uri[1])) : line;
                    }
                    return new stream.Transform({
                        transform: function(chunk, _, done) {
                            totalBytes += chunk.length;
                            if (totalBytes > maximumPlaylistBytes) return done(new Error("Playlist too large"));
                            var data = partialLine + chunk.toString();
                            if (!eol) {
                                var lf = data.indexOf("\\n"), cr = data.indexOf("\\r");
                                eol = lf < 0 && cr < 0 ? null : lf >= 0 && cr >= 0 ? (cr < lf ? "\\r\\n" : "\\n\\r") : cr < 0 ? "\\n" : "\\r";
                            }
                            if (!eol) {
                                if (Buffer.byteLength(data) > maximumPlaylistLineBytes) return done(new Error("Playlist line too large"));
                                partialLine = data; return done();
                            }
                            var lines = data.split(eol); partialLine = lines.pop();
                            if (Buffer.byteLength(partialLine) > maximumPlaylistLineBytes || lines.some(line => Buffer.byteLength(line) > maximumPlaylistLineBytes)) return done(new Error("Playlist line too large"));
                            lines.forEach(line => this.push(parseLine(line) + eol)); done();
                        },
                        flush: function(done) { done(null, parseLine(partialLine)); partialLine = ""; eol = null; }
                    });
                })(finalDest);
                stream.pipeline(result.body, rewrite, res, settle);
            }).catch(error => {
                clearTimeout(timer); clearTimeout(idle);
                if (!started && !res.headersSent) failBeforeHead(error);
                else settle(error);
            });
        }), router;
    } };
`;

const output = source.slice(0, start) + moduleSource + source.slice(end);
const temporary = file + ".vortx-proxy-" + process.pid;
fs.writeFileSync(temporary, output);
fs.renameSync(temporary, file);
console.log("patch-server-proxy: hardened proxy module installed");
