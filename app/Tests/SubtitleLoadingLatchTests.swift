// SubtitleLoadingLatchTests: a standalone, runnable verification of the EXTERNAL-SUBTITLE LOADING
// LATCH design (the "external subtitles stuck on Loading…" fix): `subtitleLoadingURL` is the single
// latch that (a) marks one add-on / community subtitle row as "Loading…" and (b) gates EVERY other
// subtitle pick (manual and auto) while a load is in flight. The bug class: the chrome latched FIRST
// and then called `coordinator.player?.addExternalSubtitle(...)` through a WEAK optional - in the
// engine demote/switch render gap that call silently vanishes, the completion (the only place the
// latch was cleared) never runs, and every later subtitle pick is silently swallowed for the rest of
// the session. On tvOS the panel snapshot additionally never rebuilt on completion, so the row said
// "Loading…" forever even for loads that finished.
//
// VortX's Apple app has no Xcode unit-test bundle (verification is build + on-device, per CLAUDE.md),
// so, exactly like app/Tests/BingeAdvanceIdentityTests.swift, this is a self-contained Swift
// executable that runs directly with the system toolchain:
//
//     swift app/Tests/SubtitleLoadingLatchTests.swift
//
// It re-implements ONLY the small latch state machine (the decision surface), not the players. The
// mirrors MUST stay in lockstep with the shipped code:
//   - TVPlayerView subtitles-panel add-on row action / PlayerScreen twin -> click() below
//     (bind-engine-before-latch + completion clear + still-live-engine record gate)
//   - TVPlayerView.autoSelectAddonSubtitleIfNeeded / PlayerScreen twin   -> autoPick() below
//     (no autoAddonSubTried latch when the engine is absent, so a later pass retries)
//   - TVPlayerView.selectPooledSubtitle / PlayerScreen twin              -> pooledPick() below
//     (engine re-bound AFTER the pool download await; unlatch when it vanished)
//   - TVPlayerView.demoteAVPlayerToMPV + switchStream + retryLoad + play(episode:) and the
//     PlayerScreen twins -> demoteOrNewLoad() below (the latch self-heal reset)
//   - TVPlayerView.refreshTracksSoon -> the completion's panel rebuild (mirrors iOS refreshSoon)
//
// SCOPE: this asserts DESIGN PROPERTIES against faithful mirrors, NOT the shipped functions directly
// (a standalone script cannot link the app target). The proof the shipped code compiles and links is
// the Xcode build gate.

import Foundation

// MARK: - Mirror of the decision surface

final class EngineMirror {
    let id: Int
    var stopped = false
    init(id: Int) { self.id = id }
}

/// The chrome's subtitle-latch state machine, mirrored. `player` stands for `coordinator.player`
/// (weak in the app: nil in the demote/switch render gap). Completions are collected and run
/// explicitly so tests control WHEN they land relative to demotes.
final class LatchMirror {
    var player: EngineMirror?
    var subtitleLoadingURL: String?
    var autoAddonSubTried = false
    var addedSubURLs = Set<String>()
    var failureSurfaced = false
    var panelRebuilt = false
    /// In-flight completions: (the engine the load was issued on, the url, run-with-ok).
    private(set) var inFlight: [(engine: EngineMirror, url: String, run: (Bool) -> Void)] = []

    /// The manual add-on row action (TVPlayerView subtitles panel / PlayerScreen twin).
    /// Returns false when the click was swallowed (either latch held or no live engine).
    @discardableResult
    func click(url: String) -> Bool {
        // THE FIX: bind the engine BEFORE latching. The old order latched first and let the
        // optional-chained call vanish, stranding the latch forever.
        guard subtitleLoadingURL == nil, let engine = player else { return false }
        subtitleLoadingURL = url
        inFlight.append((engine, url, { ok in
            self.subtitleLoadingURL = nil
            // Still-live-engine gate: never record an add the live engine never saw.
            if ok, engine === self.player { self.addedSubURLs.insert(url) }
            else if !ok { self.failureSurfaced = true }
            self.panelRebuilt = true   // refreshTracksSoon / refreshSoon rebuilds the open panel
        }))
        return true
    }

    /// The auto path (autoSelectAddonSubtitleIfNeeded tier 1). Same latch; must not latch
    /// autoAddonSubTried when the engine is absent so a later pass retries.
    func autoPick(url: String) {
        guard !autoAddonSubTried, subtitleLoadingURL == nil else { return }
        guard let engine = player else { return }   // no latch consumed: the next pass retries
        autoAddonSubTried = true
        subtitleLoadingURL = url
        inFlight.append((engine, url, { ok in
            self.subtitleLoadingURL = nil
            if ok, engine === self.player { self.addedSubURLs.insert(url) }
            self.panelRebuilt = true
        }))
    }

    /// The pooled path: latch, await the pool download, THEN bind the engine (it can vanish during
    /// the await). `downloadOK: false` models the pool download failing (always unlatches).
    func pooledPick(url: String, downloadOK: Bool) {
        guard subtitleLoadingURL == nil else { return }
        subtitleLoadingURL = url
        guard downloadOK else { subtitleLoadingURL = nil; return }
        guard let engine = player else {   // vanished during the await: unlatch + revert
            subtitleLoadingURL = nil
            panelRebuilt = true
            return
        }
        inFlight.append((engine, url, { ok in
            self.subtitleLoadingURL = nil
            if ok, engine === self.player { self.addedSubURLs.insert(url) }
            self.panelRebuilt = true
        }))
    }

    /// A demote / source switch / reload / episode advance: the engine swaps (nil during the render
    /// gap, then a fresh instance) and the reset block self-heals the latch.
    func demoteOrNewLoad(newEngine: EngineMirror?) {
        player?.stopped = true
        player = newEngine
        subtitleLoadingURL = nil   // the self-heal reset added by this fix
    }

    /// Land the oldest in-flight completion with the given result (models the download finishing).
    func landCompletion(ok: Bool) {
        guard !inFlight.isEmpty else { return }
        let entry = inFlight.removeFirst()
        entry.run(ok)
    }
}

// MARK: - Harness

var failures = 0
func expect(_ cond: Bool, _ name: String) {
    if cond { print("PASS  \(name)") } else { failures += 1; print("FAIL  \(name)") }
}

// MARK: - 1. Happy path: click latches, completion unlatches and records the add.
do {
    let m = LatchMirror(); m.player = EngineMirror(id: 1)
    m.click(url: "https://subs/a.srt")
    expect(m.subtitleLoadingURL == "https://subs/a.srt", "click latches the row")
    m.landCompletion(ok: true)
    expect(m.subtitleLoadingURL == nil, "success unlatches")
    expect(m.addedSubURLs.contains("https://subs/a.srt"), "success records the add")
    expect(m.panelRebuilt, "completion rebuilds the open panel (no eternal Loading… row)")
}

// MARK: - 2. Failure path: unlatches, surfaces, records nothing, panel rebuilt.
do {
    let m = LatchMirror(); m.player = EngineMirror(id: 1)
    m.click(url: "u")
    m.landCompletion(ok: false)
    expect(m.subtitleLoadingURL == nil, "failure unlatches")
    expect(m.addedSubURLs.isEmpty, "failure records nothing")
    expect(m.failureSurfaced, "failure is surfaced (tvOS note / iOS alert)")
    expect(m.panelRebuilt, "failure rebuilds the open panel")
    expect(m.click(url: "u"), "the row is clickable again after a failure")
}

// MARK: - 3. THE BUG CLASS: click in the engine render gap must NOT strand the latch.
do {
    let m = LatchMirror(); m.player = nil   // demote/switch render gap
    let accepted = m.click(url: "u")
    expect(!accepted, "click with no engine is refused")
    expect(m.subtitleLoadingURL == nil, "no engine -> nothing latched (the old code stranded here)")
    m.player = EngineMirror(id: 2)   // engine remounts
    expect(m.click(url: "u"), "subtitle picking works again once the engine is back")
}

// MARK: - 4. Auto pick in the render gap: not latched, and retried on the next pass.
do {
    let m = LatchMirror(); m.player = nil
    m.autoPick(url: "auto")
    expect(m.subtitleLoadingURL == nil && !m.autoAddonSubTried, "auto pick with no engine consumes nothing")
    m.player = EngineMirror(id: 1)
    m.autoPick(url: "auto")   // the next list/track completion re-calls it
    expect(m.subtitleLoadingURL == "auto" && m.autoAddonSubTried, "auto pick retries on the live engine")
    m.landCompletion(ok: true)
    expect(m.addedSubURLs.contains("auto"), "auto pick completes normally")
}

// MARK: - 5. Pooled pick whose engine vanishes DURING the download await: unlatches.
do {
    let m = LatchMirror(); m.player = EngineMirror(id: 1)
    m.player = nil   // vanished between the latch and the post-await bind
    m.pooledPick(url: "pool", downloadOK: true)
    expect(m.subtitleLoadingURL == nil, "pooled pick unlatches when the engine vanished mid-await")
    m.player = EngineMirror(id: 2)
    expect(m.click(url: "u"), "picking still works afterwards")
}

// MARK: - 6. Demote mid-download: latch self-heals, and the dead-engine add is NOT recorded.
do {
    let m = LatchMirror()
    let av = EngineMirror(id: 1)
    m.player = av
    m.click(url: "u")                       // download in flight on the AVPlayer engine
    m.demoteOrNewLoad(newEngine: EngineMirror(id: 2))   // AVPlayer -> libmpv demote
    expect(m.subtitleLoadingURL == nil, "demote self-heals the latch (no eternal gate)")
    m.landCompletion(ok: true)              // the old download lands AFTER the demote
    expect(!m.addedSubURLs.contains("u"), "an add applied to the DEAD engine is not recorded")
    expect(m.click(url: "u"), "the row is still offered and clickable on the new engine")
    m.landCompletion(ok: true)
    expect(m.addedSubURLs.contains("u"), "the re-click on the live engine records normally")
}

// MARK: - 7. Invariant: no reachable sequence leaves the latch set with nothing in flight.
do {
    let m = LatchMirror()
    var engines = [EngineMirror(id: 1)]
    m.player = engines[0]
    var seed: UInt64 = 0x9E3779B97F4A7C15
    func rand(_ n: Int) -> Int {   // deterministic xorshift so failures reproduce
        seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
        return Int(seed % UInt64(n))
    }
    for step in 0 ..< 5000 {
        switch rand(6) {
        case 0: m.click(url: "u\(rand(4))")
        case 1: m.autoPick(url: "auto")
        case 2: m.pooledPick(url: "p\(rand(3))", downloadOK: rand(3) != 0)
        case 3: m.landCompletion(ok: rand(2) == 0)
        case 4:
            let next = rand(4) == 0 ? nil : EngineMirror(id: engines.count + 1)
            if let next { engines.append(next) }
            m.demoteOrNewLoad(newEngine: next)
            m.autoAddonSubTried = false   // the reset blocks re-arm the auto pass on a new load
        default:
            if m.player == nil { m.player = engines.last }   // the next SwiftUI render remounts
        }
        if m.subtitleLoadingURL != nil && m.inFlight.isEmpty {
            expect(false, "step \(step): latch set with nothing in flight (the stuck-on-Loading strand)")
            break
        }
    }
    expect(true, "5000-step fuzz: latch is never stranded (set => a completion is in flight)")
}

print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
