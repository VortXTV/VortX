#!/usr/bin/env node
"use strict";

// Real vendored NNTP worker, NZB parser, scheduler, yEnc decoder and HTTP router.
// All articles and credentials are synthetic and served only on loopback.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const net = require("node:net");
const http = require("node:http");
const { patch } = require("../scripts/patch-server-nntp.js");
const { patch: patchArchive } = require("../scripts/patch-server-usenet.js");
const { fixture: archiveFixture } = require("./server-usenet-archive.test.js");
const execFile = require("node:util").promisify(require("node:child_process").execFile);
const source = fs.readFileSync(process.argv[2] || path.join(__dirname, "../app/Resources/server.js"), "utf8");
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const timers = new Set();
const sockets = new Set();
function load(bundle) {
    const entry = "__webpack_require__(__webpack_require__.s = 564)";
    assert.equal(bundle.split(entry).length, 2);
    const context = { require, process, Buffer, console, queueMicrotask,
        setImmediate, clearImmediate, setInterval, clearInterval,
        setTimeout(fn, ms, ...args) {
            // Only accelerate the HTTP route's idle retirement, not wire timeouts.
            const timer = setTimeout(() => { timers.delete(timer); fn(...args); }, ms === 30000 ? 80 : ms);
            timers.add(timer); return timer;
        }, clearTimeout(timer) { timers.delete(timer); clearTimeout(timer); } };
    vm.runInNewContext(bundle.replace(entry, "globalThis.vxRequire = __webpack_require__"), context);
    return context.vxRequire;
}
function encode(data, name = "fixture.mkv") {
    const lines = [];
    for (let start = 0; start < data.length; start += 128) {
        const bytes = [];
        for (const byte of data.subarray(start, start + 128)) {
            const value = (byte + 42) & 255;
            if ([0, 10, 13, 61].includes(value)) bytes.push(61, (value + 64) & 255);
            else bytes.push(value);
        }
        if (bytes[0] === 46) bytes.unshift(46); // NNTP dot-stuffing
        lines.push(Buffer.from(bytes));
    }
    return Buffer.concat([Buffer.from(`=ybegin line=128 size=${data.length} name=${name}\r\n`),
        ...lines.flatMap(line => [line, Buffer.from("\r\n")]), Buffer.from(`=yend size=${data.length}\r\n`)]);
}
function article(body) {
    return Buffer.concat([Buffer.from("220 1 <fixture> article follows\r\nSubject: fixture\r\nMessage-ID: <fixture>\r\n\r\n"), body, Buffer.from(".\r\n")]);
}
async function fixture(articles, missing = new Set()) {
    let connections = 0;
    const requested = [];
    const server = net.createServer(socket => {
        connections++; sockets.add(socket); socket.setNoDelay(true);
        socket.on("close", () => sockets.delete(socket)); socket.on("error", () => {});
        const send = async buffer => {
            // Split status CRLF and final article terminator on actual TCP reads.
            for (const part of [buffer.subarray(0, 2), buffer.subarray(2, buffer.length - 2), buffer.subarray(-2)]) {
                if (socket.destroyed) return;
                socket.write(part); await delay(2);
            }
        };
        let input = "";
        socket.on("data", buffer => {
            input += buffer.toString("ascii");
            let end;
            while ((end = input.indexOf("\r\n")) >= 0) {
                const line = input.slice(0, end); input = input.slice(end + 2);
                if (line.startsWith("AUTHINFO USER")) void send(Buffer.from("381 password required\r\n"));
                else if (line.startsWith("AUTHINFO PASS")) void send(Buffer.from("281 authenticated\r\n"));
                else if (line === "GROUP unavailable") void send(Buffer.from("411 group unavailable\r\n"));
                else if (line.startsWith("GROUP")) void send(Buffer.from("211 5 1 5 alt.binaries.test\r\n"));
                else if (line === "ARTICLE <silent>") { /* exercise bounded timeout */ }
                else if (line === "ARTICLE <disconnect>") { socket.write("220 article\r\nSubject: x\r\n\r\npartial"); socket.end(); }
                else if (line.startsWith("ARTICLE ")) {
                    requested.push(line.slice(9, -1));
                    const body = missing.has(line.slice(9, -1)) ? undefined : articles.get(line.slice(9, -1));
                    void send(body ? article(body) : Buffer.from("430 article not found\r\n"));
                }
            }
        });
        void send(Buffer.from("200 synthetic NNTP ready\r\n"));
    });
    await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
    return { server, port: server.address().port, connections: () => connections, requested };
}
function get(worker, id) {
    return new Promise((resolve, reject) => worker.getArticle("alt.binaries.test", id, (error, code, body) => error ? reject(error) : resolve({ code, body })));
}
async function wireTests(requireBundle, port, articles) {
    const Worker = requireBundle(1102), yenc = requireBundle(1115);
    const options = { protocol: "nntp", host: "127.0.0.1", port, user: "fixture", pass: "fixture", timeout: 300, conn: 2 };
    const worker = new Worker(options);
    try {
        const response = await get(worker, "piece0");
        assert.equal(response.code, "220"); assert.equal(worker.state, "READY");
        assert.deepEqual(yenc(response.body)[1], yenc(articles.get("piece0"))[1]);
        for (const id of ["missing", "disconnect", "silent"]) {
            await assert.rejects(get(worker, id));
            assert.equal(worker.state, "OFFLINE");
            assert.equal((await get(worker, "piece0")).code, "220", "failed connection can recover");
        }
        const cancelled = get(worker, "silent");
        await delay(20); worker.close();
        await assert.rejects(cancelled);
        assert.equal((await get(worker, "piece0")).code, "220");
        worker.close();
        assert.equal((await get(worker, "piece0")).code, "220", "pause/idle close can reopen");
        await new Promise((resolve, reject) => worker.getArticle("unavailable", "piece0", (error, code) => {
            if (error) reject(error); else { assert.equal(code, "220"); resolve(); }
        }));
        await assert.rejects(new Promise((resolve, reject) => worker.getArticle("x\r\nAUTHINFO USER injected", "piece0", error => error ? reject(error) : resolve())));
        for (let cut = 1; cut < 5; cut++) {
            const fragmented = new Worker(options);
            fragmented.client = { write() {}, destroy() {} };
            const complete = fragmented.request("ARTICLE <fixture>", true);
            const bytes = article(articles.get("piece0"));
            fragmented.onData(bytes.subarray(0, -cut)); fragmented.onData(bytes.subarray(-cut));
            assert.deepEqual((await complete).body, articles.get("piece0"), `terminator split ${cut}`);
            fragmented.close();
        }
        console.log("PASS actual NNTP worker: fragmented auth/article, yEnc, missing article, disconnect, timeout, cancel and reopen");
    } finally { worker.close(); }
}
async function grabberCloseTest(requireBundle, port, articles) {
    const Grabber = requireBundle(1089);
    const grabber = new Grabber({ protocol: "nntp", host: "127.0.0.1", port, conn: 1, timeout: 300 });
    const segment = id => ({ group: "alt.binaries.test", article: id, bytes: 32768 });
    let oldCallbacks = 0;
    const controller = grabber.grabSegments([segment("silent"), segment("piece0")], () => oldCallbacks++, true);
    await delay(20);
    controller.stop();
    await new Promise(resolve => grabber.closeAllConns(resolve));
    assert.equal(grabber.waitingFor.length, 0, "close callback follows active callback drain");
    await delay(20);
    assert(grabber.queue.getWorkers().every(worker => worker.state === "OFFLINE"));
    assert.equal(oldCallbacks, 0, "cancelled readers receive no late data");
    const bytes = await new Promise((resolve, reject) => grabber.grabSegments([segment("piece0")], (error, filename, data) => error ? reject(error) : resolve(data), true));
    assert.deepEqual(bytes, requireBundle(1115)(articles.get("piece0"))[1]);
    await new Promise(resolve => grabber.closeAllConns(resolve));
    console.log("PASS actual grabber: active cancel drains before close callback; new request explicitly reopens");
}
async function windowTest(requireBundle, nntp, articles) {
    const Grabber = requireBundle(1089);
    const grabber = new Grabber({ protocol: "nntp", host: "127.0.0.1", port: nntp.port, conn: 4, timeout: 1000 });
    const segments = Array.from({ length: 100 }, (_, i) => {
        const id = i ? `window-${i}` : "silent";
        if (i) articles.set(id, articles.get("piece0"));
        return { group: "alt.binaries.test", article: id, bytes: 32768 };
    });
    const before = nntp.requested.length;
    const delivered = [];
    let resolveDone;
    const done = new Promise(resolve => { resolveDone = resolve; });
    const controller = grabber.grabSegments(segments, (error, filename, bytes, last) => {
        if (error) throw error;
        delivered.push(bytes);
        if (last) resolveDone();
    }, true);
    await delay(180);
    assert(nntp.requested.length - before <= 7, "held first article bounds later reads to the connection window");
    controller.pause();
    const first = requireBundle(1115)(articles.get("piece0"))[1];
    controller.pushFromBackbone(null, "fixture.mkv", first, false, segments[0].group, "silent", 32768, 0);
    const pausedCount = nntp.requested.length;
    await delay(30);
    assert.equal(nntp.requested.length, pausedCount, "fallback cannot bypass paused window");
    controller.resume();
    let deadline;
    try { await Promise.race([done, new Promise((_, reject) => { deadline = setTimeout(() => reject(new Error("Backbone did not resume ordered window")), 2000); })]); }
    finally { clearTimeout(deadline); }
    assert.equal(delivered.length, 100);
    for (const bytes of delivered) assert.deepEqual(bytes, first);
    controller.stop(); await new Promise(resolve => grabber.closeAllConns(resolve));
    console.log("PASS ordered read-ahead bounded while first article stalls; backbone recovery honors pause and drains all 100 pieces after resume");
}
function legacyControl() {
    if (source.includes("/* VortX NNTP wire v1 */")) return;
    const OldWorker = load(source)(1102);
    const worker = new OldWorker({});
    worker.mode = "ARTICLE_BEGIN"; worker.state = "BUSY";
    let calls = 0;
    worker.callbacks.add(() => calls++);
    const bytes = article(Buffer.from("=ybegin line=128 size=1 name=x.mkv\r\nK\r\n=yend size=1\r\n"));
    worker.onData(bytes.subarray(0, -2)); worker.onData(bytes.subarray(-2));
    assert.equal(calls, 0); assert.equal(worker.state, "BUSY");
    console.log("PASS control reproduces old worker permanently BUSY on split article terminator");
}
function subscriberTest(requireBundle) {
    const exercise = subscriber => {
        const segment = { group: "fixture", article: "backup-handoff" };
        const received = [];
        subscriber.subscribe(subscriber.expected([segment]), segment.group, segment.article, () => {
            subscriber.subscribe(subscriber.expected([segment]), segment.group, segment.article, error => received.push(error));
        });
        subscriber.pushSegment("primary missing", null, segment.group, segment.article, 0);
        return { subscriber, received, segment };
    };
    if (!source.includes("/* VortX NNTP subscriber snapshot v1 */")) {
        const old = exercise(load(source)(1117));
        assert.deepEqual(old.received, ["primary missing"], "control replays the primary failure into the new backup subscription");
    }
    const fixed = exercise(requireBundle(1117));
    assert.deepEqual(fixed.received, [], "backup waits for its own server response");
    fixed.subscriber.pushSegment(null, Buffer.from("backup bytes"), fixed.segment.group, fixed.segment.article, 12);
    assert.deepEqual(fixed.received, [null]);
    console.log("PASS subscription handoff isolates new backup requests from stale primary results");
}
function request(port, pathname, { range, method = "GET", body, cancel = false } = {}) {
    return new Promise((resolve, reject) => {
        const bytes = body && Buffer.from(JSON.stringify(body));
        const req = http.request({ hostname: "127.0.0.1", port, path: pathname, method, agent: false,
            headers: { ...(range ? { Range: range } : {}), ...(bytes ? { "Content-Type": "application/json", "Content-Length": bytes.length } : {}) } }, res => {
            const chunks = [];
            res.on("error", reject);
            res.on("data", chunk => {
                chunks.push(chunk);
                if (cancel) { resolve({ cancelled: true }); res.destroy(); }
            });
            res.on("end", () => resolve({ status: res.statusCode, headers: res.headers, data: Buffer.concat(chunks) }));
        });
        req.setTimeout(3000, () => req.destroy(new Error(`HTTP fixture timed out: ${pathname}`)));
        req.on("error", reject); req.end(bytes);
    });
}
async function httpTests(requireBundle, port, data, segmentSize, articles, archive = false, backupPort) {
    const route = requireBundle(1088);
    const app = requireBundle(241)();
    const packed = archive && archiveFixture([{ name: "readme.txt", bytes: Buffer.from("not video") }, { name: "video.mkv", bytes: data }]);
    const files = archive ? [packed.subarray(0, 131072), packed.subarray(131072, 262144), packed.subarray(262144)] : [data];
    const nzbFiles = files.map((bytes, index) => {
        const name = archive ? `archive.7z.${String(index + 1).padStart(3, "0")}` : "fixture.mkv";
        const segments = [];
        for (let i = 0; i * segmentSize < bytes.length; i++) {
            const id = `${archive ? "archive" : "raw"}-${index}-${i}`;
            articles.set(id, encode(bytes.subarray(i * segmentSize, (i + 1) * segmentSize), name));
            segments.push(`<segment bytes="${segmentSize}" number="${i + 1}">${id}</segment>`);
        }
        return `<file poster="fixture" date="0" subject='"${name}" yEnc'><groups><group>alt.binaries.test</group></groups><segments>${segments.join("")}</segments></file>`;
    });
    const nzb = `<?xml version="1.0"?><nzb xmlns="http://www.newzbin.com/DTD/2003/nzb">${nzbFiles.join("")}</nzb>`;
    app.get("/fixture.nzb", (_, res) => res.type("application/xml").send(nzb));
    app.use("/nzb", route.router());
    app.use("/7zip", requireBundle(1287)());
    const server = http.createServer(app);
    await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
    const httpPort = server.address().port;
    route.setIP("127.0.0.1"); route.setPort(httpPort);
    try {
        const created = await request(httpPort, "/nzb/create", { method: "POST", body: {
            servers: [port, backupPort].filter(Boolean).map(value => `nntp://fixture:fixture@127.0.0.1:${value}/2`), nzbUrl: `http://127.0.0.1:${httpPort}/fixture.nzb` } });
        assert.equal(created.status, 200, created.data.toString());
        const key = JSON.parse(created.data).key;
        const link = await request(httpPort, `/nzb/stream?key=${key}`);
        assert.equal(link.status, 302);
        const streamPath = link.headers.location;
        for (const [range, start, end] of [[undefined, 0, data.length - 1], ["bytes=0-0", 0, 0],
            ["bytes=17-65539", 17, 65539], [`bytes=${data.length - 31}-`, data.length - 31, data.length - 1],
            ["bytes=65540-131071", 65540, 131071], ["bytes=32768-40000", 32768, 40000]]) {
            const response = await request(httpPort, streamPath, { range });
            assert.equal(response.status, range ? 206 : 200);
            assert.equal(Number(response.headers["content-length"]), end - start + 1);
            assert(response.data.equals(data.subarray(start, end + 1)), `exact NNTP bytes ${range || "full"}`);
        }
        await request(httpPort, streamPath, { cancel: true });
        await delay(140); // crosses accelerated route idle socket retirement
        const reopened = await request(httpPort, streamPath, { range: "bytes=70000-99999" });
        assert.deepEqual(reopened.data, data.subarray(70000, 100000), "same key reopened after idle socket close");
        const head = await request(httpPort, streamPath, { method: "HEAD", range: "bytes=70000-99999" });
        assert.equal(head.status, 206); assert.equal(head.data.length, 0);
        if (process.env.VORTX_NNTP_MEDIA_TEST === "1") {
            await execFile("ffmpeg", ["-hide_banner", "-loglevel", "error", "-i", `http://127.0.0.1:${httpPort}${streamPath}`, "-f", "null", "-"], { timeout: 20000 });
            console.log(`PASS actual FFmpeg video/audio decode over ${archive ? "split 7z" : "raw MKV"} NNTP HTTP route`);
        }
        console.log(`PASS real ${archive ? "split-7z" : "raw-file"} NZB→NNTP→yEnc→HTTP: full file, one byte, forward/backward seeks, cancellation, idle pause/reopen and HEAD`);
    } finally { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); }
}
async function main() {
    legacyControl();
    const patched = patchArchive(patch(source));
    assert.equal(patch(patched), patched, "patch is idempotent");
    assert.throws(() => patch("wrong pinned bundle"));
    const requireBundle = load(patched);
    subscriberTest(requireBundle);
    let data = Buffer.alloc(8 * 32768 + 93);
    for (let i = 0; i < data.length; i++) data[i] = (i * 37 + (i >>> 7)) & 255;
    data[0] = 4; // encoded leading dot exercises dot-stuffing exactly once
    if (process.env.VORTX_NNTP_MEDIA_TEST === "1") {
        data = (await execFile("ffmpeg", ["-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=24", "-f", "lavfi", "-i", "sine=frequency=440", "-t", "2", "-c:v", "ffv1", "-c:a", "pcm_s16le", "-f", "matroska", "pipe:1"], { encoding: "buffer", maxBuffer: 16 * 1024 * 1024 })).stdout;
        assert(data.length > 262144, "generated media exercises several volumes");
    }
    const articles = new Map();
    for (let i = 0; i * 32768 < data.length; i++) articles.set(`piece${i}`, encode(data.subarray(i * 32768, (i + 1) * 32768)));
    const nntp = await fixture(articles, new Set(["raw-0-3", "archive-0-2"]));
    const backup = await fixture(articles);
    try {
        await wireTests(requireBundle, nntp.port, articles);
        await grabberCloseTest(requireBundle, nntp.port, articles);
        await windowTest(requireBundle, nntp, articles);
        await httpTests(requireBundle, nntp.port, data, 32768, articles, false, backup.port);
        // A fresh module instance mirrors an independent stream session and
        // avoids retaining the first Express router's mounts across fixtures.
        await httpTests(load(patched), nntp.port, data, 32768, articles, true, backup.port);
        assert(backup.requested.includes("raw-0-3") && backup.requested.includes("archive-0-2"), "real backup server supplied missing primary articles");
        console.log("PASS real two-provider failover preserves exact raw and archive stream bytes");
    }
    finally {
        for (const timer of timers) clearTimeout(timer);
        for (const socket of sockets) socket.destroy();
        await new Promise(resolve => nntp.server.close(resolve));
        await new Promise(resolve => backup.server.close(resolve));
    }
}
main().catch(error => { console.error(error); process.exitCode = 1; });
