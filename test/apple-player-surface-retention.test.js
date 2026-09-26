"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const root = path.resolve(__dirname, "..");
const tv = fs.readFileSync(path.join(root, "app/SourcesTV/TVPlayerView.swift"), "utf8");

function section(source, start, end) {
    const a = source.indexOf(start);
    const b = source.indexOf(end, a + start.length);
    assert(a >= 0 && b > a, `missing section ${start}`);
    return source.slice(a, b);
}

// These are wiring contracts: the existing physical controller has already accepted the new
// token before either reset runs. Changing the route here destroys that accepted controller.
for (const name of ["resetRuntimeForIssuedSourceSwitch", "resetRuntimeForIssuedEpisode"]) {
    const reset = section(tv, `private func ${name}(`, "\n    private func ");
    assert(!/avEngineFailed\s*=\s*false/.test(reset),
        `${name} must retain the engine that accepted the incoming source/episode`);
}
const manual = section(tv, "private func performPlayerEngineSwitch(", "\n    private func ");
assert(manual.indexOf("engineSurfaceUsesActiveTuple = true") < manual.indexOf("avEngineFailed = false"),
    "explicit engine retry must prepare the current tuple before changing the route");

for (const file of ["app/SourcesTV/TVPlayerView.swift", "app/Sources/PlayerScreen.swift"]) {
    const source = fs.readFileSync(path.join(root, file), "utf8");
    const surface = section(source, "private var mpvSurfacePlayback:", "\n    }");
    assert(surface.includes("avEngineFailed || engineSurfaceUsesActiveTuple"),
        `${file}: manual AV-to-MPV switch must mount the active episode, not the launch URL`);
    assert(surface.includes("useActiveTuple ? (curURL ?? url) : url"));
    assert(surface.includes("useActiveTuple ? curHeaders : headers"));
    assert(surface.includes(file.includes("SourcesTV")
        ? "useActiveTuple ? curIsLive : initialLiveMode"
        : "useActiveTuple ? isLive : initialIsLive"));
}
console.log("PASS Apple surface retention: in-place replacements retain engine; explicit switches use active media");

const idle = section(tv, "private func refreshPlaybackIdleTimer()", "\n    private func ");
assert(idle.includes("TVPlaybackIdleTimer.update(playbackIdleTimerOwner"));
assert(idle.includes("!leftPlayback && !loadFailed && !playbackDeadlineClock.isPaused"));
assert(!tv.includes("isIdleTimerDisabled = !b"), "raw engine pause is not viewer intent");
for (const name of ["viewerPause", "viewerPlay", "retryPlaybackByUser"]) {
    assert(section(tv, `private func ${name}()`, "\n    private func ").includes("refreshPlaybackIdleTimer()"));
}
assert(tv.includes(".onChange(of: playbackDeadlineClock.isPaused) { _ in refreshPlaybackIdleTimer() }"));
assert(tv.includes(".onChange(of: loadFailed) { _ in refreshPlaybackIdleTimer() }"));
assert(tv.includes("TVPlaybackIdleTimer.release(playbackIdleTimerOwner)"));
assert(tv.includes("isIdleTimerDisabled = false"));
for (const name of ["demoteAVPlayerToMPV", "performPlayerEngineSwitch"]) {
    const handoff = section(tv, `private func ${name}(`, "\n    private func ");
    assert(handoff.includes("let desiredPaused = playbackDeadlineClock.isPaused"));
}
console.log("PASS TV idle and engine handoff follow viewer transport intent, not transient engine pause");
assert(tv.includes("let pausedIntent = playbackDeadlineClock.isPaused"));
assert(section(tv, "private func viewerToggle()", "\n    private func ").includes("if playbackDeadlineClock.isPaused"));

const emptyRecovery = section(tv, "private func recoverEmptySourceAfterSettlement()", "\n    /// The playing source");
assert(emptyRecovery.includes("EmptySourceRecoveryPolicy.decision("));
assert(emptyRecovery.includes("current: currentEmptySourceRecoveryOwner"));
assert(emptyRecovery.includes("exhaustedURLs.insert(owner.failedURL)"));
assert(emptyRecovery.includes("deadlineExpired: elapsed >= StreamRanking.completeSetDeadline"));
assert(section(tv, "private func presentTerminalLoadFailure()", "\n    /// The ordinary").includes("cancelEmptySourceRecovery()"));
for (const file of ["app/SourcesTV/TVPlayerView.swift", "app/Sources/PlayerScreen.swift"]) {
    const source = fs.readFileSync(path.join(root, file), "utf8");
    assert(source.includes("deferredResumeInFlight: postFrameResumeSeekWatchdogTarget != nil"));
    assert(source.includes("postFrameResumeSeekWatchdogOwner == coordinator.player?.activeLoadToken"));
    assert(source.includes("seekForResume(to: reconciliation.presentationSeconds + 0.1)"));
    for (const property of ["pause", "pausedForCache"]) {
        assert(source.includes(`case MPVProperty.${property}:\n            if let loadToken, loadToken != coordinator.player?.activeLoadToken { return }`),
            `${file}: stale ${property} from a replaced engine must be ignored before state changes`);
    }
}
console.log("PASS empty-source settlement is load-owned and bounded; resume recovery excludes ordinary stall reloads");
