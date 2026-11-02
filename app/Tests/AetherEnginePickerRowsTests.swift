import Foundation

// Runner inserts maintained property/row/admission slices. UI animation, native engine
// handoff and recovery collaborators are synthetic; no application or engine is launched.
@MainActor enum PlayerEngineRouter { static var aetherEngineAvailable = true }
@MainActor final class SyntheticPlayer { var activeLoadToken: UUID? = UUID() }
@MainActor final class SyntheticCoordinator { var player: SyntheticPlayer? = SyntheticPlayer() }
struct Recovery { var freshLinkInFlight = false }
struct Pending { var issued: Bool }
struct Superseded { var pending: Pending }
@MainActor func withAnimation(_ body: () -> Void) { body() }
struct Row {
    let label: String
    var detail: String = ""
    var selected = false
    var isEnabled = true
    var apply: () -> Void = {}
}
struct OptionRow {
    let label: String
    var detail: String = ""
    var isSelected = false
    var isEnabled = true
    var action: () -> Void = {}
}
@MainActor class Fixture {
    let coordinator = SyntheticCoordinator()
    var isTrailer = false, forceMPV = false
    let url = URL(string: "https://example.invalid/launch.mkv")!
    var curURL: URL?, audioSidecarURL: URL?
    var isAetherEngineActive = false, isAVPlayerActive = false, canUseAVPlayerEngine = true
    var reconnecting = false, autoRetryTask: Bool?, avToMPVHandoff: Bool?, avToMPVHandoffBlocked = false
    var nativeDebridFreshLinkRecovery = Recovery()
    var pendingAdvance: Pending?, supersededAdvance: Superseded?
    var uncommittedIdentityBlocked = false
    var showOptions = true, closes = 0
    var aetherLatch: Bool?, engineLatch: Bool?, manualEngineAVPlayer: Bool?
    var aetherEngineFailed = false
    var accepted: [(av: Bool, aether: Bool)] = []
    func close() { closes += 1 }
}
@MainActor final class MacFixture: Fixture {
// @source:macUncommitted
// @source:macAvailability
// @source:macReady
// @source:macRows
    func switchPlayerEngine(toAVPlayer: Bool, toAether: Bool = false) {
// @source:macAdmission
// @source:macLatches
        accepted.append((toAVPlayer, toAether))
    }
}
@MainActor final class TVFixture: Fixture {
// @source:tvUncommitted
// @source:tvAvailability
// @source:tvReady
// @source:tvRows
    func switchPlayerEngine(toAVPlayer: Bool, toAether: Bool = false) {
// @source:tvAdmission
// @source:tvLatches
        accepted.append((toAVPlayer, toAether))
    }
}
@main @MainActor enum AetherEnginePickerRowsTests {
    static var checks = 0
    static func check(_ value: Bool, _ message: String) {
        precondition(value, message); checks += 1; print("PASS \(message)")
    }
    static func macAether(_ fixture: MacFixture) -> Row? { fixture.engineRows().first { $0.label == "AetherEngine" } }
    static func tvAether(_ fixture: TVFixture) -> OptionRow? { fixture.engineRows().first { $0.label.hasPrefix("AetherEngine") } }
    static func main() {
        #if VORTX_AETHER_ENGINE
        do {
            let mac = MacFixture(); let row = macAether(mac)
            check(row != nil && row?.selected == false && row?.isEnabled == true, "Mac/iOS offers bundled Aether while another engine plays")
            row?.apply()
            check(mac.accepted.count == 1 && mac.accepted[0].aether && !mac.accepted[0].av, "actual Mac/iOS Aether row requests the Aether transition")
            let tv = TVFixture(); let option = tvAether(tv); option?.action()
            check(option?.isSelected == false && tv.accepted.count == 1 && tv.accepted[0].aether && !tv.accepted[0].av,
                  "actual tvOS Aether row requests the Aether transition")
        }
        do {
            let mac = MacFixture(); let tv = TVFixture()
            for fixture in [mac as Fixture, tv as Fixture] {
                fixture.isAVPlayerActive = true
                fixture.engineLatch = true; fixture.manualEngineAVPlayer = true
                fixture.aetherEngineFailed = true
            }
            macAether(mac)?.apply(); tvAether(tv)?.action()
            for fixture in [mac as Fixture, tv as Fixture] {
                check(fixture.aetherLatch == true && fixture.manualEngineAVPlayer == nil
                    && fixture.engineLatch == false && !fixture.aetherEngineFailed,
                    "actual Aether latch assignments leave libmpv as failure destination")
            }
        }
        do {
            let mac = MacFixture(); let old = macAether(mac)
            PlayerEngineRouter.aetherEngineAvailable = false
            check(macAether(mac) == nil && tvAether(TVFixture()) == nil, "unsupported/unbundled/disabled runtime is not offered")
            old?.apply()
            check(mac.accepted.isEmpty, "old row cannot bypass a changed runtime gate at activation")
            mac.isAetherEngineActive = true
            let current = macAether(mac); current?.apply()
            check(current?.selected == true && current?.isEnabled == true && mac.accepted.isEmpty && mac.closes == 2,
                  "currently playing Aether remains identified and selecting it only dismisses")
            PlayerEngineRouter.aetherEngineAvailable = true
        }
        do {
            let mac = MacFixture(); mac.audioSidecarURL = URL(string: "https://example.invalid/audio")
            check(macAether(mac) == nil, "launch separate-audio pair stays on supported engines")
            mac.curURL = URL(string: "https://example.invalid/current.mkv")
            check(macAether(mac) != nil, "unrelated active source is not blocked by launch-only sidecar")
            mac.isTrailer = true
            check(macAether(mac) == nil, "trailer does not offer Aether")
            let tv = TVFixture(); tv.forceMPV = true
            check(tvAether(tv) == nil, "explicit tvOS forceMPV boundary remains authoritative")
        }
        for transition in 0..<5 {
            let mac = MacFixture(); let tv = TVFixture()
            let oldMac = macAether(mac); let oldTV = tvAether(tv)
            for fixture in [mac as Fixture, tv as Fixture] {
                switch transition {
                case 0: fixture.pendingAdvance = Pending(issued: true)
                case 1: fixture.pendingAdvance = Pending(issued: false)
                case 2: fixture.supersededAdvance = Superseded(pending: Pending(issued: true))
                case 3: fixture.supersededAdvance = Superseded(pending: Pending(issued: false))
                default: fixture.uncommittedIdentityBlocked = true
                }
            }
            check(macAether(mac)?.isEnabled == false && tvAether(tv)?.isEnabled == false,
                  "pending media transition stays visible and disabled")
            check(macAether(mac)?.detail == "waiting for playback transition" && tvAether(tv)?.detail == "waiting for playback transition",
                  "pending media uses the playback-transition reason")
            oldMac?.apply(); oldTV?.action()
            check(mac.accepted.isEmpty && tv.accepted.isEmpty,
                  "captured old row cannot replace an uncommitted episode owner")
            for fixture in [mac as Fixture, tv as Fixture] {
                fixture.pendingAdvance = nil; fixture.supersededAdvance = nil; fixture.uncommittedIdentityBlocked = false
            }
            check(macAether(mac)?.isEnabled == true && tvAether(tv)?.isEnabled == true,
                  "permanent Aether choice is enabled again after the pending transaction closes")
        }
        for obstacle in 0..<6 {
            let mac = MacFixture(); let tv = TVFixture()
            for fixture in [mac as Fixture, tv as Fixture] {
                switch obstacle {
                case 0: fixture.nativeDebridFreshLinkRecovery.freshLinkInFlight = true
                case 1: fixture.reconnecting = true
                case 2: fixture.autoRetryTask = true
                case 3: fixture.avToMPVHandoff = true
                case 4: fixture.avToMPVHandoffBlocked = true
                default: fixture.coordinator.player?.activeLoadToken = nil
                }
            }
            let row = macAether(mac); let option = tvAether(tv)
            check(row != nil && option != nil && row?.isEnabled == false && option?.isEnabled == false,
                  "recovery/ownership obstacle \(obstacle) keeps Aether visible but disabled")
            row?.apply(); option?.action()
            check(mac.accepted.isEmpty && tv.accepted.isEmpty, "actual activation guards reject obstacle \(obstacle)")
        }
        #else
        check(macAether(MacFixture()) == nil && tvAether(TVFixture()) == nil,
              "build without Aether feature cannot offer or activate it")
        #endif
        print("\(checks) maintained picker row/admission checks passed")
    }
}
