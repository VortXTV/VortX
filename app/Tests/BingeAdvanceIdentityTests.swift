// BingeAdvanceIdentityTests: a standalone, runnable verification of the UNIFIED CURRENT-EPISODE
// IDENTITY design (the HIMYM binge-desync fix): a binge advance is published ONLY at the incoming
// file's first frame, so the label/selector (curMeta), the loaded media (curURL), the device stream
// store (LastStreamStore), the engine attribution gate (enginePlayerVideoId), and the Back target
// (detail-page re-anchor) can never disagree about which episode is current - including across a
// background boundary that interrupts an advance between load-issue and first frame.
//
// VortX's Apple app has no Xcode unit-test bundle (verification is build + on-device, per CLAUDE.md),
// so, exactly like app/Tests/StreamRankingChipsTests.swift, this is a self-contained Swift executable
// that runs directly with the system toolchain:
//
//     swift app/Tests/BingeAdvanceIdentityTests.swift
//
// It re-implements ONLY the small advance state machine (the decision surface), not the players. The
// mirrors MUST stay in lockstep with the shipped code:
//   - TVPlayerView.play(episode:)          -> advance() below (park in pendingAdvance, never publish)
//   - TVPlayerView timePos started-block   -> tick() below (outgoing-resolve guard + first-frame commit)
//   - TVPlayerView.commitPendingAdvanceOnFirstFrame / PlayerScreen twin -> commit() below
//   - TVPlayerView.reconcileAdvanceOnForeground / PlayerScreen twin     -> foreground() below
//   - LastStreamStore.record at first frame (both platforms)            -> the store write in commit()
//   - DetailView reanchorGridToEngineEpisode / reanchorPageToEngineEpisode / iOSEpisodeStreams
//     .reanchorToEngineEpisode -> reanchorBackTarget() below (fires on dismissal AND foreground)
//
// SCOPE: this asserts DESIGN PROPERTIES against faithful mirrors, NOT the shipped functions directly
// (a standalone script cannot link the app target). The proof the shipped code compiles and links is
// the Xcode build gate; the code-level twins of these assertions live as `assert(...)` in the two
// commit functions.

import Foundation

// MARK: - Mirror of the advance state machine

struct Episode: Equatable { let id: String; let url: String }

struct StoreEntry: Equatable { let videoId: String; let url: String }

/// Mirror of TVPlayerView/PlayerScreen's unified-identity state (one player instance mid-binge).
struct PlayerModel {
    // The five pointers of the original desync, unified:
    var curMetaVideoId: String            // 1. displayed episode (label + selector)
    var curURL: String                    // 2. loaded media
    var store: StoreEntry                 // 3. device stream store (keyed by the TITLE)
    var enginePlayerVideoId: String?      // 4-gate. episode the engine Player is loaded for
    var engineCWVideoId: String           // 4. engine/account CW pointer (advances at watched threshold)
    var backTargetVideoId: String         // 5. nav origin (detail page under the player)

    // Publish-at-first-frame machinery (mirror of PendingEpisodeAdvance):
    struct Pending { let videoId: String; var url: String?; var issued: Bool }
    var pending: Pending?
    var hasStartedPlaying = true

    var engineWritesOpen: Bool { enginePlayerVideoId == curMetaVideoId }

    /// Mirror of play(episode:) start: PARK the advance; publish nothing. (The old model's bug was
    /// `curMetaVideoId = next.id` right here.)
    mutating func advance(to next: Episode) {
        pending = Pending(videoId: next.id, url: nil, issued: false)
        hasStartedPlaying = false
    }

    /// Mirror of the resolve landing (preload or fallback): media pointers + engine re-point move,
    /// display does NOT. `issue` mirrors the ISSUE POINT (loadIntoPlayer handed the file to the player).
    mutating func resolveLanded(_ next: Episode, issue: Bool) {
        curURL = next.url
        pending?.url = next.url
        enginePlayerVideoId = next.id      // synchronous engine re-point (prior fix, preserved)
        if issue { pending?.issued = true }
    }

    /// Mirror of the timePos started-block: an outgoing-file tick during the resolve window
    /// (pending exists, not issued) must NOT start playback or commit; the first tick after issue is
    /// the incoming file's first frame and commits the advance + the store record atomically.
    mutating func tick() {
        if !hasStartedPlaying {
            if let p = pending, !p.issued { return }            // outgoing-resolve tick: skip start block
            hasStartedPlaying = true
            if let p = pending {                                 // FIRST-FRAME COMMIT
                pending = nil
                curMetaVideoId = p.videoId
                precondition(p.url == nil || p.url == curURL,
                             "commit: published episode's media != loaded media")
            }
            // LastStreamStore.record at first frame, refused mid-advance (pending == nil here by
            // construction): videoId and url are the SAME episode.
            if pending == nil { store = StoreEntry(videoId: curMetaVideoId, url: curURL) }
        }
    }

    /// Mirror of the watched threshold: the engine/account CW pointer advances (pointer 4). Gated
    /// writes only flow when the engine pointer matches the DISPLAYED episode.
    mutating func markWatchedThreshold(next: Episode) {
        engineCWVideoId = next.id
    }

    /// Mirror of reconcileAdvanceOnForeground: re-issue an issued-but-never-first-framed load; NEVER
    /// move the display. Returns whether a re-issue happened (the re-issued load then first-frames).
    mutating func foreground() -> Bool {
        guard let p = pending, p.issued, !hasStartedPlaying, p.url != nil else { return false }
        return true   // load re-issued for p.url; a later tick() commits
    }

    /// Mirror of the detail-page re-anchor (dismissal AND foreground triggers): Back target follows
    /// the engine CW pointer.
    mutating func reanchorBackTarget() {
        backTargetVideoId = engineCWVideoId
    }
}

var failures = 0
func expect(_ cond: Bool, _ name: String) {
    if cond { print("PASS  \(name)") } else { failures += 1; print("FAIL  \(name)") }
}

let e15 = Episode(id: "E15", url: "url-E15")
let e17 = Episode(id: "E17", url: "url-E17")
let e18 = Episode(id: "E18", url: "url-E18")

func freshPlayerParkedOnE17() -> PlayerModel {
    // Launched at E15, binged to E17, E17 committed normally (all pointers agree on E17).
    PlayerModel(curMetaVideoId: e17.id, curURL: e17.url,
                store: StoreEntry(videoId: e17.id, url: e17.url),
                enginePlayerVideoId: e17.id, engineCWVideoId: e17.id, backTargetVideoId: e15.id)
}

// ---------------------------------------------------------------------------------------------
// 1. Happy-path advance: commit publishes everything at once, store pair matches.
do {
    var p = freshPlayerParkedOnE17()
    p.markWatchedThreshold(next: e18)     // E17 hit ~90%: CW pointer moves ahead (pointer 4)
    p.advance(to: e18)
    p.resolveLanded(e18, issue: true)
    p.tick()                              // incoming first frame
    p.reanchorBackTarget()                // player later dismisses / app foregrounds
    expect(p.curMetaVideoId == e18.id, "happy path: label/selector on E18 after commit")
    expect(p.curURL == e18.url, "happy path: loaded media is E18's file")
    expect(p.store == StoreEntry(videoId: e18.id, url: e18.url), "happy path: store pair (videoId,url) is E18/E18")
    expect(p.engineWritesOpen, "happy path: engine attribution gate open (engine == display)")
    expect(p.backTargetVideoId == e18.id, "happy path: Back target re-anchored to E18")
}

// 2. THE CEO REPRO: E17 -> E18 advance interrupted by backgrounding between load-issue and first
//    frame. NOTHING may present E18: every surface stays on the OUTGOING episode, and the engine
//    gate is CLOSED so no write can misattribute.
do {
    var p = freshPlayerParkedOnE17()
    p.markWatchedThreshold(next: e18)
    p.advance(to: e18)
    p.resolveLanded(e18, issue: true)
    // -- app backgrounds HERE: no first frame ever arrived --
    expect(p.curMetaVideoId == e17.id, "interrupted: label/selector still on OUTGOING E17 (was: E18)")
    expect(p.store == StoreEntry(videoId: e17.id, url: e17.url), "interrupted: store still the matched E17 pair (never mixed)")
    expect(!p.engineWritesOpen, "interrupted: engine gate CLOSED (E18-loaded engine vs E17 display)")
    expect(p.curMetaVideoId == p.store.videoId, "interrupted: display and store agree (single identity)")
    // -- foreground: reconcile re-issues the pending load; display still does not move --
    let reissued = p.foreground()
    expect(reissued, "foreground: interrupted issued load is re-issued")
    expect(p.curMetaVideoId == e17.id, "foreground: display unchanged until the re-issued load first-frames")
    p.tick()                              // the re-issued E18 load produces its first frame
    p.reanchorBackTarget()
    expect(p.curMetaVideoId == e18.id && p.curURL == e18.url
           && p.store == StoreEntry(videoId: e18.id, url: e18.url)
           && p.engineWritesOpen && p.backTargetVideoId == e18.id,
           "recovered: after reconcile+commit ALL surfaces agree on E18")
}

// 3. Resolve-window outgoing tick (fallback path, up to ~20s): must not commit, must not flip
//    playback-started, and attribution keeps naming the outgoing episode.
do {
    var p = freshPlayerParkedOnE17()
    p.advance(to: e18)                    // resolve in flight, nothing issued
    p.tick()                              // OUTGOING E17 file still rendering ticks
    expect(p.curMetaVideoId == e17.id, "resolve window: outgoing tick did not publish E18")
    expect(!p.hasStartedPlaying, "resolve window: outgoing tick did not count as the incoming first frame")
    expect(p.store == StoreEntry(videoId: e17.id, url: e17.url), "resolve window: store untouched (no mixed E18-id/E17-url write)")
}

// 4. Never-issued failure (no playable source): pending clears, everything coherently outgoing.
do {
    var p = freshPlayerParkedOnE17()
    p.advance(to: e18)
    p.pending = nil                       // mirror of the "No playable source" tail clearing the advance
    p.hasStartedPlaying = true            // outgoing file still the loaded one
    expect(p.curMetaVideoId == e17.id && p.curURL == e17.url && p.curMetaVideoId == p.store.videoId,
           "failed advance: all pointers coherently on the outgoing episode")
}

// 5. Source hop DURING an advance (dead first source): the pending URL follows the hop, so the
//    commit records the file actually playing.
do {
    var p = freshPlayerParkedOnE17()
    p.advance(to: e18)
    p.resolveLanded(e18, issue: true)                       // first E18 source issued...
    let e18b = Episode(id: "E18", url: "url-E18-alt")       // ...dead; auto-hop to an alternate source
    p.curURL = e18b.url; p.pending?.url = e18b.url; p.pending?.issued = true   // mirror of switchStream's pending update
    p.tick()
    expect(p.store == StoreEntry(videoId: e18.id, url: e18b.url), "mid-advance hop: store records the hopped-to file under E18")
}

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
