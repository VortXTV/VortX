// Compiles exact AVPlayerEngine methods, replacing only AV objects with inert main-actor doubles.
// AVAsset intentionally ignores cancellation. No AVFoundation, URL, player session, media or network is used.
import Foundation

typealias PlayerLoadToken = Int
@MainActor final class AVDisplayCriteria {}
@MainActor final class AVPlayerItemVideoOutput {}
@MainActor final class AVPlayerItem {
    enum Status { case unknown, ready }
    var status: Status = .unknown
}
@MainActor final class AVAsset {
    enum Key { case preferredDisplayCriteria }
    var completion: CheckedContinuation<AVDisplayCriteria?, any Error>?
    func load(_ key: Key) async throws -> AVDisplayCriteria? {
        try await withCheckedThrowingContinuation { completion = $0 }
    }
    func finish(_ criteria: AVDisplayCriteria?) {
        completion?.resume(returning: criteria)
        completion = nil
    }
}
@MainActor enum DiagnosticsLog {
    static var messages: [String] = []
    static func log(_ tag: String, _ message: String) { messages.append(message) }
}
@MainActor enum HDRDisplayMode {
    static var applied: [AVDisplayCriteria] = []
    static func applyNativePreferredCriteria(_ criteria: AVDisplayCriteria, in window: Int?) -> Bool {
        applied.append(criteria)
        return true
    }
}
@MainActor final class FixturePlayer {
    var currentItem: AVPlayerItem?
    var replacements = 0
    func replaceCurrentItem(with item: AVPlayerItem?) { currentItem = item; replacements += 1 }
}
@MainActor final class PreflightFixtureEngine {
    var activeLoadToken: PlayerLoadToken? = 1
    var itemGeneration: UInt64 = 1
    var nativePreflightState = AppleAVStartWatchdogPolicy.NativePreflightState()
    var nativePreAttachTask: Task<Void, Never>?
    var nativePreAttachDeadlineTask: Task<Void, Never>?
    var nativeDisplayCriteria: AVDisplayCriteria?
    var fatalErrorEmitted = false
    var terminalLatch = Terminal()
    struct Terminal { var hasEmitted = false }
    var item: AVPlayerItem?
    var videoOutput: AVPlayerItemVideoOutput?
    let player = FixturePlayer()
    var playbackRequested = true
    var readyPlayCalls = 0
    func observe(_ item: AVPlayerItem, loadToken: PlayerLoadToken) {}
    func handleStatus(_ item: AVPlayerItem, loadToken: PlayerLoadToken) {
        if playbackRequested { readyPlayCalls += 1 }
    }
}

@main @MainActor private enum NativeDVPreflightMethodTests {
    static var failures = 0
    static func check(_ name: String, _ ok: Bool) {
        print("\(ok ? "PASS" : "FAIL")  \(name)")
        if !ok { failures += 1 }
    }
    static func flush() async { for _ in 0..<20 { await Task.yield() } }
    static func start(_ engine: PreflightFixtureEngine, _ asset: AVAsset, _ item: AVPlayerItem) {
        engine.beginNativeDVPreAttach(
            asset: asset, item: item, output: AVPlayerItemVideoOutput(),
            loadToken: engine.activeLoadToken!, generation: engine.itemGeneration)
    }
    static func main() async {
        typealias Policy = AppleAVStartWatchdogPolicy
        let slow = PreflightFixtureEngine(), slowAsset = AVAsset(), slowItem = AVPlayerItem()
        slow.playbackRequested = false
        slowItem.status = .ready
        let armedAt = ProcessInfo.processInfo.systemUptime
        var clock = Policy.NativeDecodeClock(uptime: armedAt, activeTime: armedAt)
        start(slow, slowAsset, slowItem)
        await flush()
        check("actual begin publishes owned preparation", slow.phase == .preparing(generation: 1))
        check("actual begin leaves item unattached while metadata pending", slow.player.currentItem == nil)

        let loaded = PreflightFixtureEngine(), loadedAsset = AVAsset(), loadedItem = AVPlayerItem()
        let criteria = AVDisplayCriteria()
        start(loaded, loadedAsset, loadedItem)
        await flush()
        loadedAsset.finish(criteria)
        await flush()
        check("loaded metadata attaches exact item", loaded.player.currentItem === loadedItem)
        check("loaded metadata applies exact Apple-owned criteria", loaded.nativeDisplayCriteria === criteria
            && HDRDisplayMode.applied.last === criteria)
        check("successful attach cancels both pending tasks", loaded.nativePreAttachTask == nil
            && loaded.nativePreAttachDeadlineTask == nil)
        if case .attached(let owner, let time) = loaded.phase {
            check("actual attach publishes exact generation and uptime", owner == 1 && time >= armedAt)
        } else { check("actual attach publishes exact generation and uptime", false) }

        let replaced = PreflightFixtureEngine(), retiredAsset = AVAsset(), retiredItem = AVPlayerItem()
        start(replaced, retiredAsset, retiredItem)
        await flush()
        // The real load path first invalidates the old token, then installs the new generation/token.
        replaced.invalidateLoadToken()
        replaced.itemGeneration = 2
        replaced.activeLoadToken = 2
        let replacementAsset = AVAsset(), replacementItem = AVPlayerItem()
        start(replaced, replacementAsset, replacementItem)
        await flush()
        retiredAsset.finish(AVDisplayCriteria())
        await flush()
        check("ignored cancellation cannot attach superseded generation", replaced.player.currentItem == nil)
        check("stale criteria cannot reconfigure display", HDRDisplayMode.applied.count == 1)
        replacementAsset.finish(nil)
        await flush()
        check("new generation fail-soft attachment succeeds", replaced.player.currentItem === replacementItem)

        let stopped = PreflightFixtureEngine(), stoppedAsset = AVAsset(), stoppedItem = AVPlayerItem()
        start(stopped, stoppedAsset, stoppedItem)
        await flush()
        stopped.invalidateLoadToken() // Same production cancellation used first by stop().
        stoppedAsset.finish(AVDisplayCriteria())
        await flush()
        check("stop invalidation prevents late attach and criteria", stopped.player.currentItem == nil
            && HDRDisplayMode.applied.count == 1 && stopped.phase == .retired)

        let failed = PreflightFixtureEngine(), failedAsset = AVAsset(), failedItem = AVPlayerItem()
        start(failed, failedAsset, failedItem)
        await flush()
        failed.terminalLatch.hasEmitted = true
        failedAsset.finish(AVDisplayCriteria())
        await flush()
        check("terminal receipt prevents late attach and criteria", failed.player.currentItem == nil
            && HDRDisplayMode.applied.count == 1 && failed.phase == .retired)
        failed.invalidateLoadToken()

        // The real ten-second independent production timer must fire despite AVAsset ignoring cancellation.
        try? await Task.sleep(for: .seconds(10.25))
        await flush()
        let attachedSample = ProcessInfo.processInfo.systemUptime
        let elapsed = clock.elapsed(phase: slow.phase, uptime: attachedSample, activeTime: attachedSample)
        check("uncooperative metadata is bounded by independent deadline", slow.player.currentItem === slowItem)
        check("deadline never guesses criteria or changes paused intent", slow.nativeDisplayCriteria == nil
            && !slow.playbackRequested && slow.readyPlayCalls == 0)
        check("deadline reports criteria unavailable explicitly", DiagnosticsLog.messages.contains {
            $0.contains("metadata-deadline-criteria-unavailable")
        })
        check("logged 10.25s scenario retains real decode opportunity", Policy.awaitingMountDecision(
            elapsed: attachedSample - armedAt, ownerCurrent: true, remuxMounted: false, remuxExpected: false,
            directTimeout: 10, remuxAttachTimeout: 30, nativePhase: slow.phase,
            nativeDecodeElapsed: elapsed) == .keepWaiting)
        let replacementsBeforeLate = slow.player.replacements
        slowAsset.finish(AVDisplayCriteria())
        await flush()
        check("late ignored-cancel completion cannot attach again", slow.player.replacements == replacementsBeforeLate)
        check("late ignored-cancel completion cannot change criteria", slow.nativeDisplayCriteria == nil
            && HDRDisplayMode.applied.count == 1)

        for engine in [slow, loaded, replaced, stopped, failed] { engine.invalidateLoadToken() }
        print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
        exit(failures == 0 ? 0 : 1)
    }
}
