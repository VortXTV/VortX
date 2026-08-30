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
if (start < 0 || end < 0 || source.indexOf(startMarker, start + 1) >= 0) {
    throw new Error("patch-server-proxy: unique proxy module anchors not found");
}

const moduleSource = `}, function(module, exports, __webpack_require__) {
    var path = __webpack_require__(5), url = __webpack_require__(6), querystring = __webpack_require__(24), Router = __webpack_require__(100), stream = __webpack_require__(3), https = __webpack_require__(20), fetch = __webpack_require__(34), Headers = fetch.Headers, cfgOpts = {
        Destination: "d", DestinationHeader: "h", ResponseHeader: "r"
    }, proxyReqHeaders = [ "accept", "accept-encoding", "accept-language", "range", "if-range", "user-agent" ], proxyResHeaders = [ "accept-ranges", "content-type", "content-length", "content-range", "connection", "transfer-encoding", "last-modified", "etag", "server", "date" ], supportedPlaylists = [ ".m3u", ".m3u8" ], forbiddenAddonHeaders = new Set([ "host", "connection", "content-length", "transfer-encoding", "proxy-connection", "upgrade", "range" ]), sensitiveHeaders = new Set([ "authorization", "cookie", "referer", "origin" ]);
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
    function safeCookie(value) {
        var pair = (value || "").split(";", 1)[0].trim(), equals = pair.indexOf("=");
        return equals > 0 && validName(pair.slice(0, equals)) && validValue(pair.slice(equals + 1)) ? pair : null;
    }
    function redirectedHeaders(headers, result, from, to) {
        var next = new Headers;
        headers.forEach((value, name) => { if (sameOrigin(from, to) || !sensitiveHeaders.has(name.toLowerCase())) next.set(name, value); });
        if (sameOrigin(from, to) && result.headers.has("set-cookie")) {
            var cookie = safeCookie(result.headers.get("set-cookie"));
            if (cookie) next.set("cookie", [ next.get("cookie"), cookie ].filter(Boolean).join("; "));
        }
        next.set("host", to.host);
        return next;
    }
    function fetchOnce(dest, req, headers, agent, controller) {
        return fetch(url.format(dest), { method: req.method, headers: headers, agent: agent, redirect: "manual", signal: controller.signal });
    }
    function fetchWithRedirects(dest, req, headers, agent, controller) {
        var count = 0;
        function next() {
            return fetchOnce(dest, req, headers, agent, controller).then(result => {
                if (!(result.status >= 300 && result.status < 400 && result.headers.has("location"))) return { result: result, dest: dest };
                if (++count > 4) throw new Error("Too many redirects");
                var target = url.parse(url.resolve(url.format(dest), result.headers.get("location")));
                if (target.protocol !== "https:") throw new Error("Unsafe redirect");
                headers = redirectedHeaders(headers, result, dest, target);
                dest = target;
                return next();
            });
        }
        return next();
    }
    function urlJoin(segments) { return segments.join("/").replace(/\\/+/g, "/"); }
    module.exports = { getRouter: function() {
        var router = Router(), httpsAgent = new https.Agent;
        return router.all("/:opts/:pathname(*)?", function(req, res, next) {
            var opts = querystring.parse(req.params.opts);
            opts[cfgOpts.DestinationHeader] = ensureArray(opts[cfgOpts.DestinationHeader]);
            opts[cfgOpts.ResponseHeader] = ensureArray(opts[cfgOpts.ResponseHeader]);
            var dest = url.parse(opts[cfgOpts.Destination]);
            if (!dest || dest.protocol !== "https:" || !dest.hostname) return res.sendStatus(400);
            dest.pathname = req.params.pathname || ""; dest.search = req.search || "";
            var headers = new Headers(makeHeaders(new Headers(req.headers), proxyReqHeaders, { host: dest.host }));
            applyAddonHeaders(headers, opts[cfgOpts.DestinationHeader]);
            if (req.headers.range) headers.set("range", req.headers.range);
            else headers.delete("range");
            var controller = new AbortController, started = false, timer = setTimeout(() => controller.abort(), 15000);
            function abort() { controller.abort(); }
            req.once("aborted", abort); res.once("close", function() { if (!res.writableEnded) abort(); });
            fetchWithRedirects(dest, req, headers, httpsAgent, controller).then(({ result, dest: finalDest }) => {
                clearTimeout(timer); started = true;
                var responseHeaders = makeHeaders(result.headers, proxyResHeaders);
                opts[cfgOpts.ResponseHeader].forEach(value => { var parsed = parseHeaderString(value); if (parsed) responseHeaders[parsed[0]] = parsed[1]; });
                var isPlaylist = supportedPlaylists.includes(path.extname(finalDest.pathname)) || (responseHeaders["content-type"] || "").toLowerCase().includes("mpegurl");
                if (isPlaylist) { delete responseHeaders["content-length"]; responseHeaders["accept-ranges"] = "none"; responseHeaders["transfer-encoding"] = "chunked"; }
                res.writeHead(result.status, responseHeaders);
                var idle;
                function armIdle() { clearTimeout(idle); idle = setTimeout(abort, 10000); }
                result.body.on("data", armIdle); result.body.once("end", () => clearTimeout(idle)); result.body.once("error", () => clearTimeout(idle)); armIdle();
                if (!isPlaylist) return result.body.pipe(res);
                var virtualRoot = req.originalUrl.slice(0, -req.url.length) + "/" + querystring.stringify(opts);
                result.body.pipe((function(virtualRoot, baseDest) {
                    var partialLine = "", eol = null;
                    function childProxy(lineUrl) {
                        var same = sameOrigin(baseDest, lineUrl), childOpts = {};
                        childOpts[cfgOpts.Destination] = lineUrl.protocol + "//" + lineUrl.host;
                        childOpts[cfgOpts.DestinationHeader] = [];
                        ensureArray(opts[cfgOpts.DestinationHeader]).forEach(value => {
                            var parsed = parseHeaderString(value);
                            if (parsed && (same || !sensitiveHeaders.has(parsed[0].toLowerCase()))) {
                                childOpts[cfgOpts.DestinationHeader].push(parsed[0] + ":" + parsed[1]);
                            }
                        });
                        return "/proxy/" + querystring.stringify(childOpts) + lineUrl.pathname + (lineUrl.search || "");
                    }
                    function parseUrl(line) {
                        var resolved = url.parse(url.resolve(url.format(baseDest), line));
                        if (resolved.protocol !== "https:") return line;
                        return sameOrigin(baseDest, resolved)
                            ? urlJoin([ virtualRoot, resolved.pathname ]) + (resolved.search || "")
                            : childProxy(resolved);
                    }
                    function parseLine(line) {
                        if (!line.startsWith("#") && line.length > 0) return parseUrl(line);
                        var uri = line.match(/URI="([^"]+)"/);
                        return uri ? line.replace(uri[1], parseUrl(uri[1])) : line;
                    }
                    return new stream.Transform({
                        transform: function(chunk, _, done) {
                            var data = partialLine + chunk.toString();
                            if (!eol) {
                                var lf = data.indexOf("\\n"), cr = data.indexOf("\\r");
                                eol = lf < 0 && cr < 0 ? null : lf >= 0 && cr >= 0 ? (cr < lf ? "\\r\\n" : "\\n\\r") : cr < 0 ? "\\n" : "\\r";
                            }
                            if (!eol) { partialLine = data; return done(); }
                            var lines = data.split(eol); partialLine = lines.pop();
                            lines.forEach(line => this.push(parseLine(line) + eol)); done();
                        },
                        flush: function(done) { done(null, parseLine(partialLine)); partialLine = ""; eol = null; }
                    });
                })(virtualRoot, finalDest)).pipe(res);
            }).catch(error => {
                clearTimeout(timer);
                if (!started && !res.headersSent) res.sendStatus(error && error.name === "AbortError" ? 504 : 502);
                else res.destroy();
            });
        }), router;
    } };
`;

const output = source.slice(0, start) + moduleSource + source.slice(end);
const temporary = file + ".vortx-proxy-" + process.pid;
fs.writeFileSync(temporary, output);
fs.renameSync(temporary, file);
console.log("patch-server-proxy: hardened proxy module installed");
