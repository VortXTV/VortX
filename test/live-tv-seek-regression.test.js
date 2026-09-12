"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const source = fs.readFileSync(path.join(__dirname, "../app/Sources/Player/MPVMetalViewController.swift"), "utf8");
const relative = source.slice(source.indexOf("func seek(by seconds: Double)"), source.indexOf("private var seekCacheHoldArmed"));
const ordered = ["cancelCacheReanchorForExplicitSeek()", "supersedeSeekEOFRecoveryForExplicitSeek()",
    "let target = max(0, position + seconds)",
    "if position.isFinite, seconds.isFinite, target.isFinite, seekTargetOutsideCache(target)",
    "armSeekCacheHold()", "lastOutOfWindowSeekTarget = target", "armSeekRefillWatchdog()",
    'command("seek", args: [String(format: "%.1f", seconds), "relative"]'];
let cursor = -1;
for (const token of ordered) {
    const next = relative.indexOf(token, cursor + 1);
    assert(next > cursor, `relative seek must preserve ordered ownership and cache decision: ${token}`);
    cursor = next;
}
assert(!relative.includes('setFlag(MPVProperty.pause'), "relative refill must not change viewer pause intent");
const watchdog = source.slice(source.indexOf("private func scheduleSeekRefillWatchdogCheck"), source.indexOf("private func getDouble"));
assert(watchdog.includes("if self.getFlag(MPVProperty.pause)"));
assert(watchdog.includes("self.seekRefillWatchdogGeneration == generation"));
assert(watchdog.includes("if !stillBuffering"));
assert(watchdog.includes("self.seekRefillRecoveriesThisSeek < Self.seekRefillMaxRecoveries"));
console.log("PASS relative seek: conditional refill protection, live relative semantics, pause intent, bounded generation-owned recovery");
