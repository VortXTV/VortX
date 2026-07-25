// ContinueWatchingMirrorTests: a standalone, runnable proof that the "Mirror Continue Watching from Stremio"
// toggle actually DECIDES something, and that its default decides exactly what the app did before it was wired.
// It exercises the REAL logic:
//   - ContinueWatchingMirror.swift ... the gate (`stremioMayReplaceContinueWatching`), the pure floor
//                                      (`resolveContinueWatching`), the episode ordering, and `LocalRewindLog`.
//
// VortX's Apple app has no Xcode unit-test bundle (verification is build + on-device, per repo convention), so
// this follows the SettingsLocalWinsTests / SettingsBackupSecretsTests convention: a self-contained executable
// compiled with the system toolchain, with the REAL source compiled in and only the app type the file extends
// (MirrorSettings) stubbed so it links standalone.
//
//     xcrun swiftc -o /tmp/cwmirrortest \
//         app/SourcesShared/ContinueWatchingMirror.swift \
//         app/Tests/ContinueWatchingMirrorTests.swift && /tmp/cwmirrortest
//
// The stub below SHADOWS the real `MirrorSettings` (CoreModels.swift) with the SAME keys and the SAME
// `UserDefaults.standard.bool` defaults, so the toggle semantics under test are the shipping ones.

import Foundation

// MARK: - Stub (the enum ContinueWatchingMirror.swift extends; keys + defaults copied from CoreModels.swift)

enum MirrorSettings {
    static let addonsKey = "stremiox.sync.mirror.addons"
    static let libraryKey = "stremiox.sync.mirror.library"
    static let continueWatchingKey = "stremiox.sync.mirror.cw"

    static var mirrorAddons: Bool { UserDefaults.standard.bool(forKey: addonsKey) }
    static var mirrorLibrary: Bool { UserDefaults.standard.bool(forKey: libraryKey) }
    static var mirrorContinueWatching: Bool { UserDefaults.standard.bool(forKey: continueWatchingKey) }
}

// MARK: - Harness

var failures = 0
var checks = 0

func expect(_ condition: Bool, _ what: String) {
    checks += 1
    if condition {
        print("  ok    \(what)")
    } else {
        failures += 1
        print("  FAIL  \(what)")
    }
}

func expectPosition(_ got: MirrorSettings.CWPosition, _ want: MirrorSettings.CWPosition, _ what: String) {
    checks += 1
    if got == want {
        print("  ok    \(what)")
    } else {
        failures += 1
        print("  FAIL  \(what)  got t=\(got.t) d=\(got.d) v=\(got.v ?? "nil"), want t=\(want.t) d=\(want.d) v=\(want.v ?? "nil")")
    }
}

func position(_ t: Double, _ d: Double, _ v: String? = nil) -> MirrorSettings.CWPosition {
    MirrorSettings.CWPosition(t: t, d: d, v: v)
}

func resolve(engine: MirrorSettings.CWPosition,
             owned: MirrorSettings.CWPosition?,
             mayReplace: Bool,
             locallyRewound: Bool = false) -> MirrorSettings.CWPosition {
    MirrorSettings.resolveContinueWatching(engine: engine, owned: owned,
                                           mayReplace: mayReplace, locallyRewound: locallyRewound)
}

// MARK: - 1. The gate: what the toggle actually controls, and what the DEFAULT preserves

func testGate() {

    print("\n1. Gate: mirror toggle x live Stremio session")

    // The shipping default. `UserDefaults.standard.bool` for an unset key is false, so an existing user who never
    // touched the toggle is OFF. Assert that here rather than trusting the comment.
    UserDefaults.standard.removeObject(forKey: MirrorSettings.continueWatchingKey)
    expect(MirrorSettings.mirrorContinueWatching == false,
           "the toggle defaults to OFF for an existing user who never set it")

    // No live Stremio session: the gate is INERT and the engine stays authoritative, which is exactly the
    // behaviour the app had before the toggle was wired. This is what makes shipping default-OFF safe.
    expect(MirrorSettings.stremioMayReplaceContinueWatching(stremioSessionLive: false, mirrorOn: false),
           "OFF + no Stremio session: engine authoritative (today's behaviour preserved)")
    expect(MirrorSettings.stremioMayReplaceContinueWatching(stremioSessionLive: false, mirrorOn: true),
           "ON + no Stremio session: engine authoritative (nothing to mirror)")

    // Live Stremio session: this is the ONLY situation the toggle changes.
    expect(MirrorSettings.stremioMayReplaceContinueWatching(stremioSessionLive: true, mirrorOn: true),
           "ON + live Stremio session: Stremio may replace (exact mirror)")
    expect(MirrorSettings.stremioMayReplaceContinueWatching(stremioSessionLive: true, mirrorOn: false) == false,
           "OFF + live Stremio session: Stremio may NOT replace (the floor engages)")

    // The live-toggle convenience must read the same key the settings screens write.
    UserDefaults.standard.set(true, forKey: MirrorSettings.continueWatchingKey)
    expect(MirrorSettings.stremioMayReplaceContinueWatching(stremioSessionLive: true),
           "the live overload reads the toggle the settings screens write (ON)")
    UserDefaults.standard.set(false, forKey: MirrorSettings.continueWatchingKey)
    expect(MirrorSettings.stremioMayReplaceContinueWatching(stremioSessionLive: true) == false,
           "the live overload reads the toggle the settings screens write (OFF)")
}

// MARK: - 2. ON mirrors: the Stremio position wins in every direction

func testMirrorOnReplaces() {

    print("\n2. ON (exact mirror): the engine position always wins")

    expectPosition(resolve(engine: position(120, 6000, "tt1:1:2"), owned: position(3000, 6000, "tt1:1:2"), mayReplace: true),
                   position(120, 6000, "tt1:1:2"),
                   "ON: a Stremio ROLLBACK propagates")
    expectPosition(resolve(engine: position(0, 6000, "tt1:1:2"), owned: position(3000, 6000, "tt1:1:2"), mayReplace: true),
                   position(0, 6000, "tt1:1:2"),
                   "ON: a Stremio FINISH (t back to 0) propagates")
    expectPosition(resolve(engine: position(90, 6000, "tt1:1:1"), owned: position(3000, 6000, "tt1:3:4"), mayReplace: true),
                   position(90, 6000, "tt1:1:1"),
                   "ON: a Stremio roll back to an EARLIER episode propagates")
}

// MARK: - 3. OFF does not: VortX's own position is a floor

func testFloorRefusesRollback() {

    print("\n3. OFF (floor): a Stremio position may seed and may advance, never roll back")

    expectPosition(resolve(engine: position(120, 6000), owned: position(3000, 6000), mayReplace: false),
                   position(3000, 6000),
                   "OFF: a Stremio rollback is REFUSED, the VortX position survives")
    expectPosition(resolve(engine: position(0, 6000), owned: position(3000, 6000), mayReplace: false),
                   position(3000, 6000),
                   "OFF: a Stremio finish is REFUSED, the VortX position survives")
    expectPosition(resolve(engine: position(4200, 6000), owned: position(3000, 6000), mayReplace: false),
                   position(4200, 6000),
                   "OFF: FORWARD progress still wins, so local playback is never blocked")
    expectPosition(resolve(engine: position(3000, 6000), owned: position(3000, 6000), mayReplace: false),
                   position(3000, 6000),
                   "OFF: an equal position is a no-op, not a churn")
    expectPosition(resolve(engine: position(900, 6000), owned: nil, mayReplace: false),
                   position(900, 6000),
                   "OFF: a title VortX owns no position for is SEEDED from Stremio (adds are welcome)")
    expectPosition(resolve(engine: position(900, 6000), owned: position(0, 6000), mayReplace: false),
                   position(900, 6000),
                   "OFF: a VortX position of 0 is nothing to protect, so Stremio seeds it")
    expectPosition(resolve(engine: position(120, 6000), owned: position(3000, 0), mayReplace: false),
                   position(3000, 6000),
                   "OFF: when the VortX position wins, a missing duration is filled from the engine's copy")
}

// MARK: - 4. A LOCAL finish must still propagate under the floor

func testLocalRewindStillPropagates() {

    print("\n4. OFF + a local rewind: this device's own finish is not mistaken for a Stremio rollback")

    expectPosition(resolve(engine: position(0, 6000), owned: position(3000, 6000), mayReplace: false, locallyRewound: true),
                   position(0, 6000),
                   "OFF: a LOCALLY rewound title propagates its zero (finish is not blocked)")
    expectPosition(resolve(engine: position(0, 6000), owned: position(3000, 6000), mayReplace: false, locallyRewound: false),
                   position(3000, 6000),
                   "OFF: the same zero WITHOUT a local rewind stamp is refused (it came from Stremio)")
}

// MARK: - 5. Series: episode-ordered, so a Stremio roll back to an earlier episode is refused too

func testSeriesEpisodeOrdering() {

    print("\n5. OFF + series: episode ordering")

    expectPosition(resolve(engine: position(90, 2400, "tt1:1:1"), owned: position(600, 2400, "tt1:3:4"), mayReplace: false),
                   position(600, 2400, "tt1:3:4"),
                   "OFF: a roll back from S03E04 to S01E01 is REFUSED")
    expectPosition(resolve(engine: position(60, 2400, "tt1:3:5"), owned: position(2300, 2400, "tt1:3:4"), mayReplace: false),
                   position(60, 2400, "tt1:3:5"),
                   "OFF: a roll FORWARD to the next episode wins even at a lower offset")
    expectPosition(resolve(engine: position(60, 2400, "tt1:2:1"), owned: position(2300, 2400, "tt1:1:20"), mayReplace: false),
                   position(60, 2400, "tt1:2:1"),
                   "OFF: season dominates, S02E01 is later than S01E20")
    expectPosition(resolve(engine: position(60, 7200, "tt9"), owned: position(3000, 7200, "tt1:3:4"), mayReplace: false),
                   position(60, 7200, "tt9"),
                   "OFF: unparseable ids are not comparable, so the engine wins (a series is never frozen)")

    expect(MirrorSettings.episodeOrdinal("tt1234567:2:11")?.season == 2, "episodeOrdinal reads the season")
    expect(MirrorSettings.episodeOrdinal("tt1234567:2:11")?.episode == 11, "episodeOrdinal reads the episode")
    expect(MirrorSettings.episodeOrdinal("tt1234567") == nil, "episodeOrdinal declines a movie id")
    expect(MirrorSettings.episodeOrdinal(nil) == nil, "episodeOrdinal declines nil")
    expect(MirrorSettings.episodeOrdinal("tt1:x:y") == nil, "episodeOrdinal declines a non-numeric shape")
}

// MARK: - 6. Overlay profiles are structurally untouched

func testOverlayProfileUntouched() {

    print("\n6. Overlay profile: the account library is never in play")

    // An overlay profile's Continue Watching is ProfileStore's private per-profile overlay; it never reaches the
    // engine library or doc.vortx.library, so the floor has no owned position to consult and is a pass-through.
    // CoreBridge gates both call sites on `activeUsesEngineHistory`, and this asserts the value-level consequence:
    // with no owned position, the incoming value survives unchanged whatever the toggle says.
    expectPosition(resolve(engine: position(1500, 3000), owned: nil, mayReplace: false),
                   position(1500, 3000),
                   "overlay: no owned account position, so the floor cannot alter the profile's own value")
    expectPosition(resolve(engine: position(1500, 3000), owned: nil, mayReplace: true),
                   position(1500, 3000),
                   "overlay: identical with the mirror ON, so the toggle cannot reach a profile overlay")
}

// MARK: - 7. LocalRewindLog: stamps, reads, and self-clears

func testLocalRewindLog() {

    print("\n7. LocalRewindLog")

    UserDefaults.standard.removeObject(forKey: "vortx.cw.localRewinds.v1")
    expect(LocalRewindLog.contains("tt100") == false, "a fresh log holds nothing")
    LocalRewindLog.stamp("tt100")
    expect(LocalRewindLog.contains("tt100"), "a stamped id is held")
    expect(LocalRewindLog.contains("tt200") == false, "an unstamped id is not held")
    LocalRewindLog.stamp("tt100")
    LocalRewindLog.stamp("tt200")
    expect(LocalRewindLog.contains("tt100") && LocalRewindLog.contains("tt200"),
           "re-stamping is idempotent and does not evict a sibling")
    LocalRewindLog.forget("tt100")
    expect(LocalRewindLog.contains("tt100") == false, "forget clears the id")
    expect(LocalRewindLog.contains("tt200"), "forget leaves other ids alone")
    LocalRewindLog.forget("tt999")
    expect(LocalRewindLog.contains("tt200"), "forgetting an absent id is a no-op")
    LocalRewindLog.stamp("")
    expect(LocalRewindLog.contains("") == false, "an empty id is never stamped")
    UserDefaults.standard.removeObject(forKey: "vortx.cw.localRewinds.v1")
}

// MARK: - Result

@main
struct ContinueWatchingMirrorTests {
    static func main() {
        testGate()
        testMirrorOnReplaces()
        testFloorRefusesRollback()
        testLocalRewindStillPropagates()
        testSeriesEpisodeOrdering()
        testOverlayProfileUntouched()
        testLocalRewindLog()

        UserDefaults.standard.removeObject(forKey: MirrorSettings.continueWatchingKey)
        print("")
        if failures == 0 {
            print("PASS: \(checks) checks")
            exit(0)
        }
        print("FAIL: \(failures) of \(checks) checks")
        exit(1)
    }
}
