#!/usr/bin/env node
"use strict";

// Exercise the real vendored parser after applying the tracked production patch
// entirely in memory. No provider credentials, media download, or bundle edit.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const http = require("node:http");
const { Readable } = require("node:stream");
const { patch } = require("../scripts/patch-server-usenet.js");
const root = path.resolve(__dirname, "..");
const source = fs.readFileSync(process.argv[2] || path.join(root, "app/Resources/server.js"), "utf8");

function loadReader(bundle) {
    const at = bundle.indexOf('var _events = __webpack_require__(4), ZXX_EXTENSION = /\\.7Z');
    assert(at > 0, "actual 7z parser is present");
    const start = bundle.lastIndexOf('function(module, exports, __webpack_require__) {', at);
    const end = bundle.indexOf('\n}, function(module, exports)', at) + 2;
    const deps = { 4: require("node:events"), 3: require("node:stream"), 5: path, 1: fs,
        1289: { decompress() { throw new Error("Fixture headers are intentionally uncompressed"); } } };
    const context = { Buffer, process, console: { log() {}, error() {} } };
    const factory = vm.runInNewContext('(' + bundle.slice(start, end) + ')', context);
    const module = { exports: {} };
    factory(module, module.exports, id => { assert(id in deps); return deps[id]; });
    return module.exports.RarFilesPackage;
}

function loadRoute(bundle, file) {
    const at = bundle.indexOf('const Router = __webpack_require__(109), bodyParser = __webpack_require__(50), getRarStream = __webpack_require__(561)');
    const start = bundle.lastIndexOf('function(module, exports, __webpack_require__) {', at);
    const end = bundle.indexOf('\n}, function(module, exports, __webpack_require__)', at) + 2;
    let handler;
    const router = { use() { return this; }, post() { return this; }, all() { return this; }, get(_, fn) { handler = fn; return this; } };
    const deps = { 109: () => router, 50: { json() {} }, 561: async () => file,
        1292: () => "video/x-matroska", 169: {}, 278: {}, 4: require("node:events"),
        1293: { createKey() {}, async waitForKey() {} } };
    const factory = vm.runInNewContext('(' + bundle.slice(start, end) + ')', { console });
    const module = { exports: {} };
    factory(module, module.exports, id => { assert(id in deps, String(id)); return deps[id]; });
    module.exports();
    return handler;
}

function loadURLMedia(bundle, get) {
    const at = bundle.indexOf('const needle = __webpack_require__(74), getContentLength = __webpack_require__(1291);');
    const start = bundle.lastIndexOf('function(module, exports, __webpack_require__) {', at);
    const end = bundle.indexOf('\n}, function(module, exports, __webpack_require__)', at) + 2;
    const factory = vm.runInNewContext('(' + bundle.slice(start, end) + ')', { console });
    const module = { exports: {} };
    factory(module, module.exports, id => {
        if (id === 74) return { get };
        if (id === 1291) return async () => { throw new Error("Fixture supplies exact lengths"); };
        throw new Error("Unexpected media dependency " + id);
    });
    return module.exports;
}

async function testHTTP(bundle, file, expected) {
    const handler = loadRoute(bundle, file);
    const server = http.createServer((req, res) => { handler(req, res).catch(error => { res.destroy(error); }); });
    await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
    const request = (range, method = "GET") => new Promise((resolve, reject) => {
        const req = http.request({ hostname: "127.0.0.1", port: server.address().port, method,
            headers: range === undefined ? {} : { Range: range }, agent: false }, res => {
            const chunks = [];
            res.on("data", chunk => chunks.push(chunk)); res.on("error", reject);
            res.on("end", () => resolve({ status: res.statusCode, headers: res.headers, data: Buffer.concat(chunks) }));
        });
        req.setTimeout(1000, () => req.destroy(new Error("Fixture HTTP timeout")));
        req.on("error", reject); req.end();
    });
    try {
        for (const [range, start, end] of [[undefined, 0, 73], ["bytes=0-0", 0, 0], ["bytes=7-52", 7, 52], ["bytes=73-", 73, 73], ["bytes=-5", 69, 73], ["bytes=0-999", 0, 73]]) {
            const response = await request(range);
            assert.equal(response.status, range ? 206 : 200);
            assert.equal(Number(response.headers["content-length"]), end - start + 1);
            assert.deepEqual(response.data, expected.subarray(start, end + 1), "real HTTP body exactly matches advertised range");
            if (range) assert.equal(response.headers["content-range"], `bytes ${start}-${end}/${expected.length}`);
        }
        for (const range of ["bytes=74-", "bytes=2-1", "bytes=-0", "bytes=", "bytes=0-1,3-4", "bytes=9007199254740992-"]) {
            const response = await request(range);
            assert.equal(response.status, 416);
            assert.equal(response.headers["content-range"], "bytes */74");
        }
        const head = await request(undefined, "HEAD");
        assert.equal(head.status, 200); assert.equal(head.data.length, 0); assert.equal(head.headers["content-length"], "74");
    } finally { await new Promise(resolve => server.close(resolve)); }
}

function uint(value) {
    const n = BigInt(value);
    for (let extra = 0; extra < 8; extra++) {
        if (n < (1n << BigInt(7 + 7 * extra))) {
            const bytes = [(256 - (256 >> extra)) | Number(n >> BigInt(8 * extra))];
            for (let i = 0; i < extra; i++) bytes.push(Number((n >> BigInt(i * 8)) & 255n));
            return Buffer.from(bytes);
        }
    }
    const bytes = Buffer.alloc(9); bytes[0] = 255; bytes.writeBigUInt64LE(n, 1); return bytes;
}

// Minimal valid 7z COPY folder with explicit substream sizes and plain header.
function fixture(files) {
    const payload = Buffer.concat(files.map(file => file.bytes));
    const names = Buffer.from(files.map(file => file.name + '\0').join(''), "utf16le");
    const b = (...values) => Buffer.from(values);
    const header = Buffer.concat([
        b(1, 4, 6), uint(0), uint(1), b(9), uint(payload.length), b(0),
        b(7, 11), uint(1), b(0), uint(1), b(1, 0, 12), uint(payload.length), b(0),
        b(8, 13), uint(files.length), b(9),
        ...files.slice(0, -1).map(file => uint(file.bytes.length)), b(0, 0),
        b(5), uint(files.length), b(17), uint(names.length + 1), b(0), names, b(0, 0)
    ]);
    const signature = Buffer.alloc(32);
    b(0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c, 0, 4).copy(signature);
    signature.writeBigUInt64LE(BigInt(payload.length), 12);
    signature.writeBigUInt64LE(BigInt(header.length), 20);
    function crc(bytes) {
        let value = 0xffffffff;
        for (const byte of bytes) {
            value ^= byte;
            for (let i = 0; i < 8; i++) value = (value >>> 1) ^ ((value & 1) ? 0xedb88320 : 0);
        }
        return (value ^ 0xffffffff) >>> 0;
    }
    signature.writeUInt32LE(crc(header), 28);
    signature.writeUInt32LE(crc(signature.subarray(12)), 8);
    return Buffer.concat([signature, payload, header]);
}

function volumes(bytes, sizes = [bytes.length], options = {}) {
    let offset = 0;
    const reads = [], inputs = [];
    const files = sizes.map((size, i) => {
        const content = bytes.subarray(offset, offset + size); offset += size;
        return { name: 'fixture.7z.' + String(i + 1).padStart(3, '0'), length: size,
            async createReadStream(range) {
                reads.push({ i, ...range });
                const end = Math.min(range.end + 1, content.length);
                const data = content.subarray(range.start, end);
                if (options.delay) await new Promise(resolve => setTimeout(resolve, options.delay));
                const input = Readable.from([options.truncate ? data.subarray(0, Math.max(0, data.length - 1)) : data]);
                input.request = { abort() { input.aborted = true; } };
                inputs.push(input);
                return input;
            } };
    });
    assert.equal(offset, bytes.length);
    return { files, reads, inputs };
}

async function buffer(input) {
    const data = []; for await (const chunk of input) data.push(chunk); return Buffer.concat(data);
}

async function run() {
    const output = patch(source);
    assert.equal(patch(output), output, "patch is idempotent");
    assert.throws(() => patch("not a bundle"), /anchor/);
    assert.throws(() => patch(source + source), /anchor/);
    new vm.Script(output, { filename: "patched-server.js" });
    const Reader = loadReader(output), OldReader = loadReader(source);
    const movie = Buffer.from(Array.from({ length: 74 }, (_, i) => i + 10));
    const single = fixture([{ name: "video.mkv", bytes: movie }]);

    const old = await new OldReader(volumes(single).files).parse();
    assert.notEqual(old[0].length, movie.length, "control reproduces upstream advertised-length corruption");
    const oldBytes = await old[0].readToEnd();
    assert.notEqual(oldBytes.length, old[0].length, "control body length disagrees with advertised HTTP length");
    const legacyMedia = await loadURLMedia(source, (_, options) => options.headers.range)({ url: "http://fixture.invalid/archive.7z.001", bytes: 99 }, [], false);
    assert.equal(legacyMedia.createReadStream({ start: 0, end: 0 }), "bytes=0-", "control silently expands a single byte into a whole-volume read");
    const mediaAdapter = await loadURLMedia(output, (_, options) => options.headers.range)({ url: "http://fixture.invalid/archive.7z.001", bytes: 99 }, [], false);
    assert.equal(mediaAdapter.createReadStream({ start: 0, end: 0 }), "bytes=0-0", "HTTP volume adapter preserves an inclusive zero endpoint");
    const interval = { start: 5, end: 5 };
    assert.equal(mediaAdapter.createReadStream(interval), "bytes=5-5");
    assert.deepEqual(interval, { start: 5, end: 5 }, "volume adapter does not mutate caller ranges");
    assert.throws(() => mediaAdapter.createReadStream({ start: 0, end: 99 }), /Invalid/);

    for (const sizes of [[single.length], [40, 43, single.length - 83], [single.length - 12, 12], [15, 21, single.length - 36]]) {
        const media = volumes(single, sizes);
        const parsed = await new Reader(media.files).parse();
        assert.equal(parsed.length, 1);
        const file = parsed[0];
        assert.equal(file.length, movie.length, "exact advertised file length");
        assert.deepEqual(await file.readToEnd(), movie, "exact bytes across unequal volumes and split headers");
        for (const [start, end] of [[0, 0], [0, 7], [7, 8], [8, 51], [50, 52], [73, 73], [0, 73]]) {
            assert.deepEqual(await buffer(await file.createReadStream({ start, end })), movie.subarray(start, end + 1), "inclusive range bytes");
        }
        for (const range of [{ start: -1, end: 1 }, { start: 2, end: 1 }, { start: 0, end: 74 }, { start: NaN, end: 1 }]) {
            assert.throws(() => file.createReadStream(range), /Illegal/);
        }
    }
    const prefix = Buffer.from("not-video-prefix");
    const solid = fixture([{ name: "readme.txt", bytes: prefix }, { name: "video.mkv", bytes: movie }]);
    const oldSolid = await new OldReader(volumes(solid).files).parse({ filter: name => name.endsWith(".mkv") });
    assert.notDeepEqual(await oldSolid[0].readToEnd(), movie, "control reproduces reading the wrong bytes for a COPY subfile");
    const parsed = await new Reader(volumes(solid, [41, 33, solid.length - 74]).files).parse({ filter: name => name.endsWith(".mkv") });
    assert.equal(parsed.length, 1);
    assert.deepEqual(await parsed[0].readToEnd(), movie, "selected file starts at its own COPY-folder offset");
    await testHTTP(output, parsed[0], movie);

    const bad = volumes(single, [single.length], { truncate: true });
    await assert.rejects(new Reader(bad.files).parse(), /Truncated/);
    const beyond = Buffer.from(single); beyond.writeBigUInt64LE(1000000n, 12);
    await assert.rejects(new Reader(volumes(beyond).files).parse(), /exceeds available/);
    const huge = Buffer.from(single); huge.writeBigUInt64LE(17000000n, 20);
    await assert.rejects(new Reader(volumes(huge).files).parse(), /oversized/);

    const delayed = volumes(single, [40, single.length - 40], { delay: 5 });
    const delayedFiles = await new Reader(delayed.files).parse();
    const before = delayed.inputs.length;
    const pending = await delayedFiles[0].createReadStream({ start: 0, end: movie.length - 1 });
    pending.on("error", () => {}); pending.read(0); pending.destroy();
    await new Promise(resolve => setTimeout(resolve, 20));
    const opened = delayed.inputs.slice(before);
    assert.equal(opened.length, 1, "cancelled async open never starts the next volume");
    assert(opened[0].aborted && opened[0].destroyed, "cancel tears down a late-opened child");

    // Simulate a valid metadata read followed by a truncated/overlong body.
    for (const delta of [-1, 1]) {
        const changing = volumes(single);
        const file = (await new Reader(changing.files).parse())[0];
        changing.files[0].createReadStream = async ({ start, end }) => Readable.from([single.subarray(start, end + 1 + delta)]);
        await assert.rejects(file.readToEnd(), /Truncated|exceeded/);
    }

    const fetch = fs.readFileSync(path.join(root, "scripts/fetch-server-deps.sh"), "utf8");
    assert(fetch.indexOf('verify_sha256 "$SERVER_DEST"') < fetch.indexOf('node test/server-usenet-archive.test.js'));
    assert(fetch.indexOf('node test/server-usenet-archive.test.js') < fetch.indexOf('node scripts/patch-server-usenet.js'));

    console.log("Usenet split-7z: PASS — control length mismatch reproduced; exact full/seek bytes, COPY subfile offsets, split headers, malformed sizes, async cancellation verified");
}
run().catch(error => { console.error(error); process.exitCode = 1; });
