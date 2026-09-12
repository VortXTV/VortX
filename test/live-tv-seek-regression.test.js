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

const tv = fs.readFileSync(path.join(__dirname, "../app/SourcesTV/TVPlayerView.swift"), "utf8");
const switchStart = tv.indexOf("private func switchStream(to stream:");
const sourceSwitch = tv.slice(switchStart, tv.indexOf("curURL = newURL", switchStart));
cursor = -1;
for (const token of ["let viewerWasPaused = playbackDeadlineClock.isPaused", "let issuedToken = loadIntoPlayer(",
    "} else if issuedToken == nil", "return false", "queueIncomingTransportIntent(paused: viewerWasPaused)",
    "bindIncomingTransportIntent(to: issuedToken)", "if viewerWasPaused { coordinator.player?.pause() }"]) {
    const next = sourceSwitch.indexOf(token, cursor + 1);
    assert(next > cursor, `source switch must preserve admitted explicit pause intent: ${token}`);
    cursor = next;
}
assert(!sourceSwitch.slice(0, sourceSwitch.indexOf("let issuedToken = loadIntoPlayer(")).includes("coordinator.player?.pause()"));
console.log("PASS source switch: no pre-admission pause, explicit intent preserved for both engines and fenced to accepted token");
