import Foundation

/// A near-end position alone is not proof of watching. Accumulate only contiguous,
/// physically advancing observations from one accepted load/episode/seek timeline.
/// True owned EOF remains a separate completion path, including for short content.
struct WatchedPlaybackDwell<Owner: Equatable> {
    struct Context: Equatable {
        let owner: Owner
        let libraryID: String
        let videoID: String
        let episodeGeneration: Int
        let sourceGeneration: Int
        let seekGeneration: UInt64?
    }

    private struct Sample {
        let context: Context
        let time: Double
        let position: Double
        let duration: Double
        let rate: Double
    }
    private var previous: Sample?
    private var flowingSeconds = 0.0

    mutating func reset() {
        previous = nil
        flowingSeconds = 0
    }

    mutating func observe(context: Context, time: Double, position: Double,
                          duration: Double, rate: Double, eligible: Bool) -> Bool {
        guard eligible, time.isFinite, position.isFinite, duration.isFinite,
              rate.isFinite, rate > 0, duration > 0, position >= 0,
              position <= duration, position / duration >= 0.9 else {
            reset()
            return false
        }
        let sample = Sample(context: context, time: time, position: position,
                            duration: duration, rate: rate)
        defer { previous = sample }
        guard let previous, previous.context == context,
              previous.duration == duration, previous.rate == rate else {
            flowingSeconds = 0
            return false
        }
        let elapsed = time - previous.time
        let advanced = position - previous.position
        // A silent interval, frozen clock, regression, or seek-sized jump breaks
        // continuity. Rate-normalized advancement also prevents sparse media
        // movement from receiving full wall-clock credit.
        guard elapsed > 0, elapsed <= 1.5, advanced > 0,
              advanced <= elapsed * rate * 1.5 + 0.5 else {
            flowingSeconds = 0
            return false
        }
        flowingSeconds += min(elapsed, advanced / rate)
        return flowingSeconds + 0.000001 >= 5
    }
}
