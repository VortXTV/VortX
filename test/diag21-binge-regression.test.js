"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const root = path.resolve(__dirname, "..");

for (const file of ["app/SourcesTV/TVPlayerView.swift", "app/Sources/PlayerScreen.swift"]) {
    const source = fs.readFileSync(path.join(root, file), "utf8");
    const start = source.indexOf("private func handleRejectedEpisodicAsset(");
    const end = source.indexOf("private func handleProperty(", start);
    assert(start >= 0 && end > start);
    const recovery = source.slice(start, end);
    const hop = recovery.indexOf("if hopToNextSource(");
    const pause = recovery.lastIndexOf("coordinator.player?.pause()");
    const terminal = recovery.indexOf("presentTerminalLoadFailure()");
    assert(hop >= 0 && pause > hop && terminal > pause,
        `${file}: unconditional pause belongs to terminal mismatch, after any accepted replacement has returned`);
    assert(recovery.slice(hop, pause).includes("return"),
        `${file}: accepted source hop returns before terminal pause`);
    assert(recovery.indexOf("let viewerWasPaused = isPaused") < hop &&
        recovery.slice(hop, pause).includes("if viewerWasPaused { coordinator.player?.pause() }"),
        `${file}: accepted AVPlayer replacement must restore a real viewer pause after load resets play intent`);
    assert(!recovery.slice(0, hop).includes("coordinator.player?.pause()"),
        `${file}: no synthetic pre-hop pause`);
}
const tv = fs.readFileSync(path.join(root, "app/SourcesTV/TVPlayerView.swift"), "utf8");
assert(tv.includes("private static let nextEpisodeLibmpvWarmPrefixBytes = 32 << 20"));
assert(/BoundedRangeWarmup\.fetch\(\s*request,\s*limit:\s*Self\.nextEpisodeLibmpvWarmPrefixBytes\s*\)/.test(tv),
    "32MiB HTTP warmup and response validator must use the same byte limit");
console.log("PASS diag21: no synthetic pause across source hops; warmup request/validator limits match");
