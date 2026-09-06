#!/usr/bin/env node
"use strict";

// Deterministic post-checksum patch of the pinned server's split-7z reader.
// Keep this tracked: Resources/server.js is a generated, ignored build input.
const fs = require("node:fs");
const path = require("node:path");
const marker = "/* VortX split-7z byte ranges v1 */";

function unique(source, token) {
    const start = source.indexOf(token);
    if (start < 0 || source.indexOf(token, start + token.length) >= 0) {
        throw new Error("Usenet patch: missing or ambiguous anchor: " + token.slice(0, 90));
    }
    return start;
}

function replaceBetween(source, startToken, endToken, replacement) {
    const start = unique(source, startToken), end = unique(source, endToken);
    if (end <= start) throw new Error("Usenet patch: reversed anchors");
    return source.slice(0, start) + replacement + source.slice(end);
}

function replaceOnce(source, before, after) {
    unique(source, before);
    return source.replace(before, after);
}

// These functions are serialized into the existing webpack module. They refer
// only to its existing variables, or to standard Node/ECMAScript globals.
async function readFromVolumes(absoluteOffset, length) {
    // Header reads must be exact and bounded, including headers split across
    // volumes. HTTP/file Readable `end` is inclusive, while `length` is a count.
    if (!Number.isSafeInteger(absoluteOffset) || absoluteOffset < 0 ||
        !Number.isSafeInteger(length) || length < 0 || length > 16 * 1024 * 1024) {
        throw new Error("Invalid or oversized 7-Zip header range");
    }
    let total = 0;
    for (const volume of a7zFiles) {
        if (!Number.isSafeInteger(volume.length) || volume.length <= 0) throw new Error("Invalid archive volume size");
        total += volume.length;
        if (!Number.isSafeInteger(total)) throw new Error("Archive size exceeds safe addressing");
    }
    if (absoluteOffset > total || length > total - absoluteOffset) throw new Error("7-Zip header exceeds available volumes");
    const buffers = [];
    let position = absoluteOffset, remaining = length;
    for (const volume of a7zFiles) {
        if (!remaining) break;
        if (position >= volume.length) { position -= volume.length; continue; }
        const count = Math.min(remaining, volume.length - position);
        const input = await volume.createReadStream({ start: position, end: position + count - 1 });
        let received = 0;
        try {
            for await (const chunk of input) {
                received += chunk.length;
                if (received > count) throw new Error("Archive server exceeded requested header range");
                buffers.push(chunk);
            }
            if (received !== count) throw new Error("Truncated archive header range");
        } finally {
            if (input.request && typeof input.request.abort === "function") input.request.abort();
            if (typeof input.destroy === "function") input.destroy();
        }
        remaining -= count;
        position = 0;
    }
    return Buffer.concat(buffers, length);
}

function getFileChunks(file) {
    const data = file.data, coders = data.folder.coders;
    if (coders.length !== 1 || !isCompressionMethod(coders[0].decompressionMethodId, CompressionMethods_COPY)) {
        throw new Error("Streaming compressed 7-Zip file data is not supported");
    }
    // A COPY folder can contain several files. packOffset points to the folder,
    // not necessarily to the selected file. Ignore neither this offset nor the
    // real sizes of preceding volumes (the final volume is often shorter).
    let position = data.packOffset + data.offset, remaining = data.length;
    if (![data.packOffset, data.offset, data.length, data.packSize, position].every(Number.isSafeInteger) ||
        data.packOffset < 0 || data.offset < 0 || remaining < 0 ||
        data.offset > data.packSize || remaining > data.packSize - data.offset) {
        throw new Error("Invalid stored 7-Zip file extent");
    }
    const chunks = [];
    for (const volume of rarFiles) {
        if (!remaining) break;
        if (position >= volume.length) { position -= volume.length; continue; }
        const count = Math.min(remaining, volume.length - position);
        chunks.push({ name: file.name, compression: coders[0].decompressionMethodId,
            fileHead: file, chunk: new RarFileChunk(volume, position, position + count - 1) });
        remaining -= count;
        position = 0;
    }
    if (remaining) throw new Error("Stored 7-Zip file exceeds available volumes");
    return chunks;
}

class ArchiveInnerStream extends require("node:stream").Readable {
    constructor(chunks, options) {
        super(options);
        this.rarFileChunks = chunks.slice();
        this.opening = false;
        this.stream = null;
    }
    _read() {
        if (this.stream) this.stream.resume();
        else if (!this.opening) this.next();
    }
    async next() {
        if (this.destroyed || this.opening) return;
        const chunk = this.rarFileChunks.shift();
        if (!chunk) { this.push(null); return; }
        this.opening = true;
        try {
            const input = await chunk.getStream();
            this.opening = false;
            if (this.destroyed) { this.abortInput(input); return; }
            this.stream = input;
            let received = 0;
            input.on("data", data => {
                received += data.length;
                if (received > chunk.length) { this.destroy(new Error("Archive volume exceeded requested file range")); return; }
                if (!this.push(data)) input.pause();
            });
            input.once("error", error => this.destroy(error));
            input.once("end", () => {
                if (received !== chunk.length) { this.destroy(new Error("Truncated archive file range")); return; }
                this.stream = null; this.next();
            });
            input.once("close", () => {
                if (this.stream === input && !this.destroyed) this.destroy(new Error("Archive volume closed before end"));
            });
        } catch (error) { this.opening = false; this.destroy(error); }
    }
    abortInput(input) {
        if (!input) return;
        if (input.request && typeof input.request.abort === "function") input.request.abort();
        if (typeof input.destroy === "function") input.destroy();
    }
    _destroy(error, callback) {
        this.rarFileChunks.length = 0;
        const input = this.stream;
        this.stream = null;
        this.abortInput(input);
        callback(error);
    }
}

async function serveArchiveFile(req, res, file) {
    const size = file.length;
    if (!Number.isSafeInteger(size) || size <= 0) { res.statusCode = 502; res.end(); return; }
    let start = 0, end = size - 1;
    const range = req.headers.range;
    if (range !== undefined) {
        const match = typeof range === "string" && /^bytes=(\d*)-(\d*)$/.exec(range);
        const invalid = () => { res.statusCode = 416; res.setHeader("Content-Range", `bytes */${size}`); res.end(); };
        if (!match || (!match[1] && !match[2])) { invalid(); return; }
        if (!match[1]) {
            const suffix = Number(match[2]);
            if (!Number.isSafeInteger(suffix) || suffix <= 0) { invalid(); return; }
            start = Math.max(0, size - suffix);
        } else {
            start = Number(match[1]);
            const requestedEnd = match[2] ? Number(match[2]) : end;
            if (!Number.isSafeInteger(start) || !Number.isSafeInteger(requestedEnd) || start >= size || requestedEnd < start) { invalid(); return; }
            end = Math.min(end, requestedEnd);
        }
    }
    res.statusCode = range === undefined ? 200 : 206;
    res.setHeader("Accept-Ranges", "bytes");
    res.setHeader("Content-Type", getContentType(file));
    res.setHeader("Content-Length", String(end - start + 1));
    if (range !== undefined) res.setHeader("Content-Range", `bytes ${start}-${end}/${size}`);
    if (req.method === "HEAD") { res.end(); return; }
    let readable, cancelled = false;
    const abort = () => { cancelled = true; if (readable) readable.destroy(); };
    res.once("close", abort);
    req.once("aborted", abort);
    try {
        readable = await file.createReadStream({ start, end });
        if (cancelled || res.destroyed) { readable.destroy(); return; }
        readable.once("error", () => res.destroy());
        readable.once("close", () => { req.removeListener("aborted", abort); res.removeListener("close", abort); });
        readable.pipe(res);
    } catch (_) {
        req.removeListener("aborted", abort); res.removeListener("close", abort);
        res.destroy();
    }
}

function patch(source) {
    if (source.includes(marker)) { unique(source, marker); return source; }
    const anchor = 'var _events = __webpack_require__(4), ZXX_EXTENSION = /\\.7Z';
    const index = unique(source, anchor);
    const moduleStart = source.lastIndexOf('\n}, function(module, exports, __webpack_require__) {', index);
    const moduleEnd = source.indexOf('\n}, function(module, exports)', index);
    if (moduleStart < 0 || moduleEnd < index) throw new Error("Usenet patch: missing 7-Zip module boundaries");
    let reader = source.slice(moduleStart, moduleEnd);
    reader = replaceOnce(reader, 'return Math.max(0, this.endOffset - this.startOffset);',
        'return Math.max(0, this.endOffset - this.startOffset + 1);');
    reader = replaceBetween(reader, 'InnerFileStream = class extends _stream.Readable {', '}, streamToBuffer = async stream',
        'InnerFileStream = ' + ArchiveInnerStream.toString().replace('extends require("node:stream").Readable', 'extends _stream.Readable').replace(/\}\s*$/, '') );
    reader = replaceBetween(reader, 'async function readFromVolumes(absoluteOffset, length) {', '                    class MyBuffer {',
        readFromVolumes.toString() + '\n');
    reader = replaceBetween(reader, 'function getFileChunks(file) {', '            console.log(_files, "_files");',
        getFileChunks.toString() + '\n');
    reader = replaceBetween(reader, '                getChunksToStream(fileStart, fileEnd) {', '                createReadStream(interval) {',
        `                getChunksToStream(fileStart, fileEnd) {
                    const first = this.findMappedChunk(fileStart), last = this.findMappedChunk(fileEnd);
                    const chunks = this.rarFileChunks.slice(first.index, last.index + 1);
                    chunks[0] = chunks[0].padStart(fileStart - first.start);
                    chunks[chunks.length - 1] = chunks[chunks.length - 1].padEnd(last.end - fileEnd);
                    return chunks;
                }
`);
    reader = replaceOnce(reader, 'if (start < 0 || end >= this.length) throw Error("Illegal start/end offset");',
        'if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start < 0 || end < start || end >= this.length) throw Error("Illegal start/end offset");');
    reader = replaceOnce(reader, 'const start = fileOffset, end = fileOffset + chunk.length;',
        'const start = fileOffset, end = fileOffset + chunk.length - 1;');
    reader = replaceBetween(reader, '                    let selectedMap = this.chunkMap[0];', '                    return selectedMap;',
        '                    const selectedMap = this.chunkMap.find(mapping => offset >= mapping.start && offset <= mapping.end);\n' +
        '                    if (!selectedMap) throw new Error("Archive seek is outside the file");\n');
    // Close the owned composite reader, including an in-flight async open, not
    // just whichever nested request happened to exist at the instant of close.
    const routerAnchor = 'const Router = __webpack_require__(109), bodyParser = __webpack_require__(50), getRarStream = __webpack_require__(561)';
    const routerStart = unique(source, routerAnchor);
    let prefix = source.slice(0, moduleStart);
    if (routerStart >= moduleStart) throw new Error("Usenet patch: unexpected 7-Zip router position");
    const beforeRouter = prefix.slice(0, routerStart);
    let router = prefix.slice(routerStart);
    router = replaceBetween(router, '            if ("HEAD" === req.method)', '        })), router;',
        '            return serveArchiveFile(req, res, rarInnerFile);\n');
    router = replaceOnce(router, '    module.exports = function() {', serveArchiveFile.toString() + '\n    module.exports = function() {');
    let suffix = source.slice(moduleEnd);
    const mediaAnchor = 'const needle = __webpack_require__(74), getContentLength = __webpack_require__(1291);';
    const mediaStart = unique(suffix, mediaAnchor), mediaEnd = suffix.indexOf('\n}, function(module, exports, __webpack_require__)', mediaStart);
    if (mediaEnd < 0) throw new Error("Usenet patch: missing 7-Zip HTTP media boundary");
    let media = suffix.slice(mediaStart, mediaEnd);
    media = replaceBetween(media, '                    return Object.values(range).length', 'needle.get(url, opts);',
        `                    if (range && Object.keys(range).length) {
                        const start = range.start === undefined ? 0 : range.start;
                        const end = range.end === undefined ? Number(contentLength) - 1 : range.end;
                        if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start < 0 || end < start || end >= Number(contentLength)) throw new Error("Invalid archive HTTP range");
                        opts.headers = { range: "bytes=" + start + "-" + end };
                    }
                    return `);
    suffix = suffix.slice(0, mediaStart) + media + suffix.slice(mediaEnd);
    return beforeRouter + router + reader.replace('    "use strict";', '    "use strict";\n    ' + marker) + suffix;
}

module.exports = { patch };
if (require.main === module) {
    const target = process.argv[2] || path.join(__dirname, "../app/Resources/server.js");
    const input = fs.readFileSync(target, "utf8"), output = patch(input);
    if (output !== input) fs.writeFileSync(target, output);
    console.log("Usenet split-7z byte-range patch verified");
}
