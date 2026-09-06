#!/usr/bin/env node
"use strict";

// The pinned NNTP worker treated TCP packets as complete protocol responses.
// Install a byte-stream parser without changing the public grabber interface.
const fs = require("node:fs");
const path = require("node:path");
const marker = "/* VortX NNTP wire v1 */";

function createWorker(net, tls) {
    return class NNTPWorker {
        constructor(opts) {
            this.opts = opts;
            this.state = "OFFLINE";
            this.client = null;
            this.group = null;
            this.pending = null;
            this.generation = 0;
        }
        close() {
            this.generation++;
            this.disconnect(new Error("NNTP connection closed"));
        }
        disconnect(error) {
            const client = this.client;
            this.client = null;
            this.group = null;
            this.state = "OFFLINE";
            this.settle(error);
            if (client) client.destroy();
        }
        settle(error, value) {
            const pending = this.pending;
            this.pending = null;
            if (!pending) return;
            clearTimeout(pending.timer);
            pending.chunks = [];
            error ? pending.reject(error) : pending.resolve(value);
        }
        request(command, article = false) {
            if (this.pending) return Promise.reject(new Error("Overlapping NNTP command"));
            if (command && /[\r\n]/.test(command)) return Promise.reject(new Error("Invalid NNTP command"));
            return new Promise((resolve, reject) => {
                const pending = this.pending = { resolve, reject, article, mode: "status",
                    control: Buffer.alloc(0), chunks: [], bytes: 0, tail: Buffer.alloc(0), timer: null };
                const timeout = Number.isFinite(this.opts.timeout) && this.opts.timeout > 0 ? this.opts.timeout : 20000;
                pending.timer = setTimeout(() => this.disconnect(new Error("NNTP response timed out")), timeout);
                if (command) {
                    if (!this.client || this.client.destroyed) this.disconnect(new Error("NNTP socket unavailable"));
                    else this.client.write(command + "\r\n");
                }
            });
        }
        onData(buffer) {
            const pending = this.pending;
            if (!pending) { this.disconnect(new Error("Unexpected NNTP response")); return; }
            if (pending.mode === "status") {
                const data = pending.control.length ? Buffer.concat([pending.control, buffer]) : buffer;
                const end = data.indexOf("\r\n");
                if (end < 0) {
                    if (data.length > 65536) this.disconnect(new Error("NNTP status line too large"));
                    else pending.control = data;
                    return;
                }
                if (end > 65536) { this.disconnect(new Error("NNTP status line too large")); return; }
                const line = data.subarray(0, end).toString("ascii");
                if (!/^\d{3}(?: |$)/.test(line)) { this.disconnect(new Error("Malformed NNTP status")); return; }
                pending.code = line.slice(0, 3);
                pending.control = Buffer.alloc(0);
                if (!pending.article || pending.code !== "220") {
                    this.settle(null, { code: pending.code, body: null });
                    return;
                }
                pending.mode = "article";
                buffer = data.subarray(end + 2);
            }
            if (!buffer.length) return;
            // Carry four bytes between socket reads: the five-byte article
            // terminator is allowed to straddle ANY TCP/TLS packet boundary.
            const scan = pending.tail.length ? Buffer.concat([pending.tail, buffer]) : buffer;
            const terminator = scan.indexOf("\r\n.\r\n");
            const consumed = terminator < 0 ? buffer.length : terminator + 5 - pending.tail.length;
            pending.chunks.push(buffer.subarray(0, consumed));
            pending.bytes += consumed;
            if (pending.bytes > 64 * 1024 * 1024) { this.disconnect(new Error("NNTP article exceeds safety limit")); return; }
            if (terminator < 0) { pending.tail = scan.subarray(Math.max(0, scan.length - 4)); return; }
            const article = Buffer.concat(pending.chunks, pending.bytes);
            const headerEnd = article.indexOf("\r\n\r\n");
            if (headerEnd < 0) { this.disconnect(new Error("NNTP article headers missing")); return; }
            // Preserve dot-stuffing: the vendored yEnc decoder removes it.
            this.settle(null, { code: pending.code, body: article.subarray(headerEnd + 4, article.length - 3) });
        }
        async connect() {
            const banner = this.request(null);
            let socket;
            try {
                socket = this.opts.protocol === "nntps"
                    ? tls.connect({ host: this.opts.host, port: this.opts.port, rejectUnauthorized: false })
                    : net.connect({ host: this.opts.host, port: this.opts.port });
            } catch (_) {
                this.disconnect(new Error("NNTP connection configuration invalid"));
                await banner;
                return;
            }
            // Keep the existing provider TLS policy; this patch is wire framing,
            // not a change to configured/self-hosted server trust settings.
            this.client = socket;
            socket.on("data", buffer => { if (this.client === socket) this.onData(buffer); });
            socket.on("error", () => { if (this.client === socket) this.disconnect(new Error("NNTP transport error")); });
            socket.on("end", () => { if (this.client === socket) this.disconnect(new Error("NNTP server disconnected")); });
            socket.on("close", () => { if (this.client === socket) this.disconnect(new Error("NNTP socket closed")); });
            const greeting = await banner;
            if (!/^(200|201)$/.test(greeting.code)) throw new Error("NNTP greeting rejected (" + greeting.code + ")");
            if (this.opts.user || this.opts.pass) {
                const user = await this.request("AUTHINFO USER " + (this.opts.user || ""));
                if (user.code === "381") {
                    const password = await this.request("AUTHINFO PASS " + (this.opts.pass || ""));
                    if (password.code !== "281") throw new Error("NNTP authentication rejected (" + password.code + ")");
                } else if (user.code !== "281") throw new Error("NNTP authentication rejected (" + user.code + ")");
            }
        }
        getArticle(group, article, callback) {
            if (this.state === "BUSY") { queueMicrotask(() => callback(new Error("NNTP worker busy"))); return; }
            this.state = "BUSY";
            const generation = this.generation;
            const current = () => {
                if (generation !== this.generation) throw new Error("NNTP request cancelled");
            };
            (async () => {
                if (!this.client) await this.connect();
                current();
                if (this.group !== group) {
                    await this.request("GROUP " + group);
                    current();
                    // ARTICLE by message-id does not require GROUP selection
                    // (RFC 3977 §6.2.1). Some providers omit group listings but
                    // still serve the NZB's articles; retain that compatibility.
                    this.group = group;
                }
                const id = /^<[^<>\s]+>$/.test(article) ? article : "<" + article + ">";
                const result = await this.request("ARTICLE " + id, true);
                current();
                if (result.code !== "220") throw new Error("NNTP article unavailable (" + result.code + ")");
                return result;
            })().then(result => {
                if (generation !== this.generation) { callback(new Error("NNTP request cancelled"), null, null); return; }
                this.state = "READY";
                callback(null, result.code, result.body);
            }, error => {
                // Do not let a cancelled older request tear down a reused worker.
                if (generation === this.generation) this.disconnect(error);
                callback(error, null, null);
            });
        }
    };
}

function once(source, before, after) {
    const at = source.indexOf(before);
    if (at < 0 || source.indexOf(before, at + before.length) >= 0) throw new Error("NNTP patch anchor missing/ambiguous: " + before.slice(0, 80));
    return source.slice(0, at) + after + source.slice(at + before.length);
}

function patch(source) {
    if (source.includes(marker)) {
        if (source.split(marker).length !== 2) throw new Error("Duplicate NNTP patch marker");
        return source;
    }
    const anchor = "    var NNTPWorker, async, id, net, bind = function(fn, me) {";
    const at = source.indexOf(anchor);
    if (at < 0 || source.indexOf(anchor, at + anchor.length) >= 0) throw new Error("NNTP worker module missing/ambiguous");
    const end = source.indexOf("\n}, function(module, exports, __webpack_require__) {", at);
    if (end < 0) throw new Error("NNTP worker boundary missing");
    source = source.slice(0, at) + "    " + marker + "\n    module.exports = (" + createWorker.toString() + ")(__webpack_require__(39), __webpack_require__(71));" + source.slice(end);
    // HTTP byte ranges are partial responses, not a new full-file response.
    source = once(source, 'if (res.writeHead(200, {\n                        "Access-Control-Allow-Origin": req.headers.origin || "*",\n                        "Content-Range":',
        'if (res.writeHead(206, {\n                        "Access-Control-Allow-Origin": req.headers.origin || "*",\n                        "Content-Range":');
    // Pause at/above the buffer ceiling, never disable backpressure above it.
    source = once(source, '31457280 > bufferSize && controller.pause()', 'bufferSize >= 31457280 && controller.pause()');
    // IncomingMessage.close is request completion on modern Node, not evidence
    // that the downstream player has finished reading the response.
    source = once(source, 'req.on("close", (function() {\n                    controller.stop(), chunkBuffer = null;',
        'res.on("close", (function() {\n                    controller.stop(), chunkBuffer = null;');
    source = once(source, 'countStreams[reqKey] = 1, req.on("close", (function() {',
        'countStreams[reqKey] = 1, res.on("close", (function() {');
    // Needle otherwise parses application/xml into an object before the NZB
    // parser sees it, turning valid XML downloads into "[object Object]".
    source = once(source, 'needle.get(nzbUrl, {\n                            open_timeout:',
        'needle.get(nzbUrl, {\n                            parse_response: false,\n                            open_timeout:');
    // An idle socket retirement must not permanently poison this reusable
    // grabber. The next request may reuse the same /nzb/stream key after pause.
    const closeStart = source.indexOf('NzbGrabber.prototype.closeAllConns = function(cb) {');
    const closeEnd = source.indexOf('}, NzbGrabber;', closeStart);
    if (closeStart < 0 || closeEnd < closeStart) throw new Error("NNTP grabber close boundary missing");
    source = source.slice(0, closeStart) + `NzbGrabber.prototype.closeAllConns = function(cb) {
            this.closing = true;
            for (const worker of this.queue.getWorkers()) worker.close();
            // Worker cancellation settles on promise microtasks. Keep dispatch
            // fenced until all those callbacks finish; an old grabber must not
            // reopen itself after its caller replaces it.
            setImmediate(() => { if (cb) cb(); });
        ` + source.slice(closeEnd);
    source = once(source, 'var selectionId = getSelectionId(this), self = this;\n            self.selectionIds[selectionId] = [];',
        'var selectionId = getSelectionId(this), self = this;\n            self.closing = false;\n            self.selectionIds[selectionId] = [];');
    // Bound ordered-delivery buffering too, not only bytes already delivered
    // to HTTP. An early slow article otherwise lets later workers fetch the
    // whole NZB into cache before sendFile can apply its backpressure.
    const grabStart = source.indexOf('NzbGrabber.prototype.grabSegments = function(segs, cb, pushAll, requestId) {');
    const grabEnd = source.indexOf('}, NzbGrabber.prototype.parse = nzb', grabStart);
    if (grabStart < 0 || grabEnd < grabStart) throw new Error("NNTP ordered window boundary missing");
    let grab = source.slice(grabStart, grabEnd);
    grab = once(grab, 'var stopped = !1;', `var stopped = !1, holdQueue = false, consumedIndex = 0, queuedIndex = 1;
            const windowSize = Math.max(2, Math.min(16, self.opts.conn * 2));
            function pumpWindow() {
                if (!pushAll || stopped || holdQueue) return;
                while (fileChunks.length && queuedIndex < consumedIndex + windowSize) nextChunk(queuedIndex++);
            }`);
    grab = once(grab, 'for (var idx = 1; fileChunks.length; ) nextChunk(idx), idx++;', 'pumpWindow();');
    grab = once(grab, 'let holdQueue = !1;', '');
    for (const [before, after, count] of [
        ['for (j = 0; cache[j]; )', 'for (j = consumedIndex; cache[j]; )', 2],
        ['for (var j = 0; cache[j]; )', 'for (var j = consumedIndex; cache[j]; )', 1],
        ['if (item = cache[j], j += 1, "boolean" == typeof item) continue;', 'if (item = cache[j], j += 1, "boolean" == typeof item) { consumedIndex = j; continue; }', 3],
        ['cache[j - 1] = !0;', 'cache[j - 1] = !0, consumedIndex = j, pumpWindow();', 3]
    ]) {
        if (grab.split(before).length !== count + 1) throw new Error("NNTP ordered window anchor mismatch");
        grab = grab.split(before).join(after);
    }
    grab = once(grab, 'resumeQueue: () => {\n                    self.queue.next();',
        'resumeQueue: () => {\n                    pumpWindow();\n                    self.queue.next();');
    source = source.slice(0, grabStart) + grab + source.slice(grabEnd);
    return source;
}

module.exports = { patch, createWorker };
if (require.main === module) {
    const target = process.argv[2] || path.join(__dirname, "../app/Resources/server.js");
    const input = fs.readFileSync(target, "utf8"), output = patch(input);
    if (output !== input) fs.writeFileSync(target, output);
    console.log("NNTP wire framing, range response, backpressure and reconnect patch verified");
}
