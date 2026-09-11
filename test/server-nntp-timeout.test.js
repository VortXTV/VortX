"use strict";
const assert = require("node:assert/strict");
const vm = require("node:vm");
const { createWorker } = require("../scripts/patch-server-nntp.js");

function harness() {
    let now = 0;
    const timers = new Set();
    const setTimeout = (fn, ms) => {
        const timer = { fn, ms, due: now + ms, refresh() { this.due = now + this.ms; } };
        timers.add(timer);
        return timer;
    };
    const Worker = vm.runInNewContext(`(${createWorker.toString()})(null, null)`, {
        Buffer, setTimeout, clearTimeout: timer => timers.delete(timer), queueMicrotask,
    });
    const worker = new Worker({ timeout: 20000 });
    worker.client = { destroy() {}, write() {} };
    const advance = ms => {
        const end = now + ms;
        for (;;) {
            const next = [...timers].filter(t => t.due <= end).sort((a, b) => a.due - b.due)[0];
            if (!next) break;
            now = next.due;
            timers.delete(next);
            next.fn();
        }
        now = end;
    };
    return { worker, advance, timers };
}
async function main() {
    const active = harness();
    const done = active.worker.request(null, true);
    active.worker.onData(Buffer.from("220 article\r\nSubject: fixture\r\n\r\n"));
    for (let i = 0; i < 4; i++) {
        active.advance(19000);
        active.worker.onData(Buffer.from("bytes\r\n"));
        assert(active.worker.pending, "active article must survive total time greater than idle timeout");
    }
    active.worker.onData(Buffer.from(".\r\n"));
    assert.equal((await done).body.toString(), "bytes\r\n".repeat(4));
    assert.equal(active.timers.size, 0);
    console.log("PASS active 76-second article completes byte-exactly without a 20-second forced restart");

    const stalled = harness();
    const failed = stalled.worker.request(null, true).catch(error => error);
    stalled.worker.onData(Buffer.from("220 article\r\nSubject: fixture\r\n\r\nbody"));
    stalled.advance(19000);
    stalled.worker.onData(Buffer.alloc(0));
    stalled.advance(1000);
    assert.match((await failed).message, /response timed out/);
    assert.equal(stalled.worker.pending, null);
    assert.equal(stalled.timers.size, 0);
    console.log("PASS stalled article times out; empty packets cannot extend its idle deadline");

    const slow = harness();
    const bounded = slow.worker.request(null, true).catch(error => error);
    slow.worker.onData(Buffer.from("220 article\r\nSubject: fixture\r\n\r\n"));
    for (let i = 0; i < 6; i++) {
        slow.advance(19000);
        slow.worker.onData(Buffer.from("x"));
    }
    slow.advance(6000);
    assert.match((await bounded).message, /safety deadline/);
    assert.equal(slow.timers.size, 0);
    console.log("PASS dribbling peer still hits the hard 120-second transfer bound");

    const cancelled = harness();
    const cancelledRequest = cancelled.worker.request(null, true).catch(error => error);
    cancelled.worker.close();
    assert.match((await cancelledRequest).message, /closed/);
    assert.equal(cancelled.timers.size, 0);
    console.log("PASS cancellation retires both deadlines");
}
main().catch(error => { console.error(error); process.exitCode = 1; });
