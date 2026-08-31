// Executes the exact Node preload rebind state-machine extracted from NodeServer.swift.
//
//   node app/Tests/NodeServerPreloadRebindHarness.js
//
// The fake listener exposes Node's paired once-listener behavior so stale watchdog and terminal callbacks can
// be exercised without booting nodejs-mobile or opening a real loopback port.

"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

function fakeServer() {
  const handlers = new Map();
  const list = (event) => handlers.get(event) || [];
  return {
    once(event, handler) {
      handlers.set(event, [...list(event), handler]);
    },
    removeListener(event, handler) {
      handlers.set(event, list(event).filter((candidate) => candidate !== handler));
    },
    close(callback) { callback(); },
    listen() {},
    emit(event, value) {
      const current = list(event);
      handlers.set(event, []);
      current.forEach((handler) => handler(value));
    },
    listenerCount(event) { return list(event).length; },
  };
}

function harness() {
  const source = fs.readFileSync(path.join("app", "Sources", "NodeServer.swift"), "utf8");
  const start = source.indexOf("        var __rb={busy:false,lastAttemptAt:0");
  const end = source.indexOf("        function __selfCheck", start);
  assert.notEqual(start, -1, "preload rebind state machine start must remain extractable");
  assert.notEqual(end, -1, "preload rebind state machine end must remain extractable");
  const preload = source.slice(start, end).replace(/^        /gm, "");
  const timers = [];
  const context = {
    __servers: [],
    boundPort: 11470,
    STUCKF: "stuck",
    fs: { writeFileSync() {}, unlinkSync() {} },
    w() {},
    JSON,
    String,
    setTimeout(callback, delay) {
      timers.push({ callback, delay });
      return timers.length;
    },
  };
  vm.createContext(context);
  vm.runInContext(`${preload}\nglobalThis.__test = { rebind: __doRebind, wake: __beginNewWake, state: () => ({ ...__rb }) };`, context);
  return { ...context.__test, timers, setServers: (servers) => { context.__servers = servers; } };
}

function testLateAttemptCannotClearNewAttempt() {
  const server = fakeServer();
  const instance = harness();
  instance.setServers([server]);
  instance.rebind("A");
  const attemptA = instance.state().activeAttemptID;
  server.emit("listening");
  instance.rebind("B");
  const before = instance.state();
  assert.notEqual(before.activeAttemptID, attemptA, "fresh refusal after A relisten starts B");
  instance.timers[0].callback();
  const after = instance.state();
  assert.equal(after.activeAttemptID, before.activeAttemptID, "A watchdog cannot retire B");
  assert.equal(after.busy, true, "A watchdog cannot clear B busy state");
}

function testWakeInvalidatesOldCallbacks() {
  const serverA = fakeServer();
  const serverB = fakeServer();
  const instance = harness();
  instance.setServers([serverA]);
  instance.rebind("A");
  const attemptA = instance.state().activeAttemptID;
  instance.wake();
  instance.setServers([serverB]);
  instance.rebind("B");
  const before = instance.state();
  assert.notEqual(before.activeAttemptID, attemptA, "wake invalidates A before B starts");
  serverA.emit("listening");
  const after = instance.state();
  assert.equal(after.activeAttemptID, before.activeAttemptID, "stale A listener cannot retire B");
  assert.equal(after.relistenConfirmed, false, "stale A listener cannot mark B healthy");
}

function testErrorRemovesPairedListeningHandler() {
  const server = fakeServer();
  const instance = harness();
  instance.setServers([server]);
  instance.rebind("A");
  assert.equal(server.listenerCount("error"), 1, "A installs error terminal handler");
  assert.equal(server.listenerCount("listening"), 1, "A installs listening terminal handler");
  server.emit("error", new Error("bind failed"));
  assert.equal(server.listenerCount("listening"), 0, "error removes paired listening handler");
  server.emit("listening");
  assert.equal(instance.state().relistenConfirmed, false, "stale listening after error cannot mark relisten");
}

testLateAttemptCannotClearNewAttempt();
testWakeInvalidatesOldCallbacks();
testErrorRemovesPairedListeningHandler();
console.log("ALL PASS");
