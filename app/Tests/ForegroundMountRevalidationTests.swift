import Foundation

@main
enum ForegroundMountRevalidationTests {
    static func main() throws {
        var state = ForegroundMountRevalidation<Int>()
        state.deferUntilPlay(owner: 1, suspendedFor: 120, playHeadAtSuspension: 900)
        precondition(state.consume(owner: 1, isPaused: true) == nil)
        let resumed = state.consume(owner: 1, isPaused: false)
        precondition(resumed?.suspendedFor == 120 && resumed?.playHeadAtSuspension == 900)
        precondition(state.consume(owner: 1, isPaused: false) == nil)
        print("PASS paused foreground retains exact context; Play consumes once")

        for replacement: Int? in [2, nil] {
            state.deferUntilPlay(owner: 1, suspendedFor: 60, playHeadAtSuspension: 40)
            precondition(state.consume(owner: replacement, isPaused: true) == nil)
            precondition(state.consume(owner: 1, isPaused: false) == nil)
        }
        state.deferUntilPlay(owner: 2, suspendedFor: 0, playHeadAtSuspension: nil)
        state.clear()
        precondition(state.consume(owner: 2, isPaused: false) == nil)
        print("PASS replacement, teardown, and admitted load retire stale requests")

        var transport = PlaybackActiveTimeClock()
        transport.setPaused(true, now: 1)
        state.deferUntilPlay(owner: 3, suspendedFor: 70, playHeadAtSuspension: 20)
        precondition(state.consume(owner: 3, isPaused: transport.isPaused) == nil)
        transport.setPaused(false, now: 2)
        precondition(state.consume(owner: 3, isPaused: transport.isPaused) != nil)
        print("PASS engine resume alone cannot override explicit user pause")

        for path in ["app/Sources/PlayerScreen.swift", "app/SourcesTV/TVPlayerView.swift"] {
            let source = try String(contentsOfFile: path, encoding: .utf8)
            let start = source.range(of: "private func revalidateMountOnForeground(")!.lowerBound
            let heal = source.range(of: "private func healLoopbackMountOnForeground(")!.lowerBound
            let validation = source[start..<heal]
            let healing = source[heal...].prefix(1_600)
            precondition(validation.contains("guard !isPaused, !playbackDeadlineClock.isPaused else"))
            precondition(validation.contains("foregroundMountRevalidation.deferUntilPlay(owner: owner"))
            precondition(validation.contains("foregroundMountRevalidation.consume("))
            precondition(validation.contains("isPaused: isPaused || playbackDeadlineClock.isPaused"))
            precondition(healing.contains("guard !isPaused, !playbackDeadlineClock.isPaused else"))
            precondition(healing.contains("guard coordinator.player?.activeLoadToken == owner else"))
            precondition(source.contains("if let b = data as? Bool, !b { resumeDeferredForegroundMountRevalidation() }"))
            precondition(!source.contains("isPaused = b\n                if !b { resumeDeferredForegroundMountRevalidation() }"))
            let load = source.range(of: "private func loadIntoPlayer(")!.lowerBound
            precondition(source[load...].prefix(9_000).contains("foregroundMountRevalidation.clear()"))
        }
        print("PASS both playback surfaces defer paused recovery and fence delayed callbacks by exact load")
    }
}
