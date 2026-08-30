#!/usr/bin/env node
"use strict";

const assert = require("assert");
const fs = require("fs");
const os = require("os");
const path = require("path");
const child = require("child_process");

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
    assert(output.includes("new https.Agent;"), "normal TLS verification must use the default HTTPS agent");
    assert(!output.includes("rejectUnauthorized: !1"), "the proxy module must not disable certificate checks");
    assert(output.includes("forbiddenAddonHeaders") && output.includes("\"range\""), "addon Range is forbidden");
    assert(output.includes("if (req.headers.range) headers.set(\"range\", req.headers.range)"), "downstream Range wins");
    assert(output.includes("sensitiveHeaders") && output.includes("sameOrigin(from, to)"), "redirect credentials are origin-bound");
    assert(output.includes("safeCookie") && output.includes("result.headers.has(\"set-cookie\")"), "same-origin redirect cookies are retained narrowly");
    assert(output.includes("new AbortController") && output.includes("req.once(\"aborted\", abort)"), "timeouts and disconnect abort upstream");
    assert(output.includes("setTimeout(() => controller.abort(), 15000)") && output.includes("setTimeout(abort, 10000)"), "head and idle deadlines are bounded");
    assert(output.includes("res.sendStatus(error && error.name === \"AbortError\" ? 504 : 502)"), "pre-head timeout is a bounded 504");
    assert(output.includes("fetchOnce(dest") && !output.includes("rejectUnauthorized: false"), "each redirect/final response uses one verified fetch");
    assert(patchSource.includes("childProxy") && patchSource.includes("parseLine"), "playlist children remain routed through the proxy");
    console.log("Embedded server proxy hardening: PASS (11 checks)");
} finally {
    try { fs.unlinkSync(fixture); } catch (_) {}
}
