internal import AetherEngine
import AppKit
import Foundation

@MainActor final class Receipt<Value: Sendable> {
    var result: Value?
    var waiter: CheckedContinuation<Value,Never>?
    func record(_ value: Value) { result = value; waiter?.resume(returning: value); waiter = nil }
    func value() async -> Value {
        if let result { return result }
        return await withCheckedContinuation { waiter = $0 }
    }
}
struct Sample: Sendable { let time: Double; let settled: Bool }
@main @MainActor enum AetherPlayerObservationTests {
    static var checks = 0
    static func check(_ value: Bool, _ message: String) {
        guard value else { print("FAIL \(message)"); exit(1) }
        checks += 1; print("PASS \(message)")
    }
    static func watching(_ player: VortXAetherPlayer) -> Receipt<Sample> {
        let receipt = Receipt<Sample>()
        player.onTime = { value in receipt.record(Sample(time: value, settled: player.positionIsSettled)) }
        return receipt
    }
    static func send(_ engine: AetherEngine, _ id: UInt64, _ outcome: SeekEvent.Outcome,
                     origin: SeekEvent.Origin = .programmatic, target: Double = 120) {
        engine.send(.init(id: id, origin: origin, outcome: outcome, target: target))
    }
    static func main() async throws {
        let player = try VortXAetherPlayer(); let engine = AetherEngine.latest!
        do {
            let read = watching(player)
            engine.state = .playing; engine.hasFirstFrameReadyForDisplay = true; engine.clock.currentTime = 12
            let sample = await read.value()
            check(sample.time == 12 && sample.settled, "normal displayed playback publishes settled clock")
        }
        do {
            let read = watching(player)
            engine.clock.currentTime = 120 // Exact upstream deferred-seek ordering: target FIRST.
            check(read.result == nil, "willSet clock cannot synchronously claim an optimistic target")
            send(engine, 1, .began, origin: .deferred); engine.isSeeking = true
            let sample = await read.value()
            check(sample.time == 120 && !sample.settled, "deferred target remains unsettled after seek event catches up")
        }
        do {
            let read = watching(player)
            engine.isSeeking = false; send(engine, 1, .stalled, origin: .deferred)
            check(!(await read.value()).settled, "stalled false seek level never proves a physical landing")
        }
        do {
            let read = watching(player)
            send(engine, 99, .rejected(.liveWithoutDVR))
            check(!(await read.value()).settled, "unrelated rejection preserves outstanding stalled uncertainty")
        }
        do {
            let read = watching(player)
            engine.state = .paused
            send(engine, 1, .landed(renderedTime: 118), origin: .deferred)
            let sample = await read.value()
            check(sample.time == 118 && sample.settled, "late paused landing publishes measured seek-axis position without another clock tick")
        }
        do {
            let read = watching(player)
            send(engine, 2, .began); engine.clock.currentTime = 200
            send(engine, 2, .superseded)
            check(!(await read.value()).settled, "supersession without a landing stays unsettled")
        }
        do {
            let read = watching(player)
            send(engine, 100, .rejected(.sourceNotSeekable))
            check(!(await read.value()).settled, "generic superseded then rejected cannot launder the old target")
        }
        do {
            let read = watching(player)
            send(engine, 3, .began); engine.clock.currentTime = 300; engine.isSeeking = true
            _ = await read.value()
            let next = watching(player)
            send(engine, 2, .landed(renderedTime: 200))
            engine.clock.currentTime = 301
            check(!(await next.value()).settled, "late predecessor landing cannot settle a successor seek")
        }
        do {
            let read = watching(player)
            engine.isSeeking = false; send(engine, 3, .landed(renderedTime: 302))
            let sample = await read.value()
            check(sample.time == 302 && sample.settled, "current seek's own landing restores settlement")
        }
        do {
            let read = watching(player)
            engine.state = .loading; engine.hasFirstFrameReadyForDisplay = false; engine.clock.currentTime = 500
            engine.state = .playing
            check(!(await read.value()).settled, "same-token internal reload loses first-frame authority")
            let shown = watching(player); engine.hasFirstFrameReadyForDisplay = true
            check((await shown.value()).settled, "internal reload's actual new first frame restores ordinary clock")
        }
        do {
            let read = watching(player)
            send(engine, 4, .began, origin: .deferred); engine.clock.currentTime = 600
            send(engine, 4, .superseded, origin: .deferred)
            send(engine, 101, .rejected(.sourceNotSeekable))
            check(!(await read.value()).settled, "deferred rejection without restored clock still fails closed")
        }
        do {
            let read = watching(player)
            send(engine, 5, .began, origin: .deferred); engine.clock.currentTime = 700
            send(engine, 5, .superseded, origin: .deferred)
            engine.clock.currentTime = 501 // 7.53.0 restores nativeHost.currentTime/sourceTime here.
            send(engine, 102, .rejected(.sourceNotSeekable))
            let sample = await read.value()
            check(sample.time == 501 && sample.settled, "forward-only deferred refusal accepts only its explicitly restored physical clock")
        }
        do {
            let read = watching(player)
            send(engine, 6, .began, origin: .deferred); engine.clock.currentTime = 800
            send(engine, 6, .superseded, origin: .deferred)
            _ = await read.value()
            let later = watching(player)
            engine.clock.currentTime = 502; send(engine, 103, .rejected(.sourceNotSeekable))
            check(!(await later.value()).settled, "later unrelated clock and rejection cannot reuse expired deferred-restoration evidence")
        }
        do {
            let read = Receipt<[String]>()
            player.onTracksChanged = { read.record(player.audioTracks.map(\.title)) }
            engine.audioTracks = [TrackInfo(id: 1, name: "Current audio")]
            check(read.result == nil, "track inventory never reads inside willSet")
            check(await read.value() == ["Current audio"], "actual wrapper callback reads newly stored inventory")
        }
        do {
            let retired = Receipt<Bool>()
            player.onTime = { _ in retired.record(true) }
            player.onTracksChanged = { retired.record(true) }
            engine.clock.currentTime = 999
            engine.audioTracks = [TrackInfo(id: 9, name: "Retired audio")]
            player.stop()
            // Negative asynchronous check: let already-ready actor tasks drain.
            // There are no I/O jobs or engine timers in this test-only module.
            try await Task.sleep(for: .milliseconds(10))
            check(retired.result == nil, "queued predecessor clock and inventory do not publish after synchronous stop")
            try await player.load(url: URL(string: "https://example.invalid/new")!, headers: nil,
                                  live: false, startPosition: nil)
            let time = watching(player)
            let tracks = Receipt<[String]>()
            player.onTracksChanged = { tracks.record(player.audioTracks.map(\.title)) }
            engine.state = .playing; engine.hasFirstFrameReadyForDisplay = true
            engine.clock.currentTime = 42
            engine.audioTracks = [TrackInfo(id: 10, name: "Successor audio")]
            let next = await time.value()
            let nextTracks = await tracks.value()
            check(next.time == 42 && next.settled && nextTracks == ["Successor audio"],
                  "new session retains its own clock and inventory after predecessor retirement")
        }
        player.stop()
        check(!player.positionIsSettled, "stop immediately retires stored settlement snapshot")
        print("\(checks) actual wrapper observation checks passed")
    }
}
