import Foundation

/// Pure decision for the narrow tvOS HDR chroma-scaling mitigation.
enum TVOSFramePresentationPolicy {
    struct Input: Equatable {
        let fullPlayer: Bool
        let standardQuality: Bool
        let videoWidth: Int
        let videoHeight: Int
        let gamma: String
        let dolbyVision: Bool
        let signalPeak: Double
        let customOptionKeys: [String]
    }

    static func shouldUseBilinearChroma(_ input: Input) -> Bool {
        let gamma = input.gamma.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hdr = gamma == "pq" || gamma == "hlg" || input.dolbyVision
            || (input.signalPeak.isFinite && input.signalPeak > 1)
        let maximumDimension = max(input.videoWidth, input.videoHeight)
        let minimumDimension = min(input.videoWidth, input.videoHeight)
        let is4K = maximumDimension >= 3_840 && minimumDimension >= 1_600
        return input.fullPlayer && input.standardQuality
            && is4K && hdr
            && !hasCustomRendererOrScaler(input.customOptionKeys)
    }

    static func hasCustomRendererOrScaler(_ keys: [String]) -> Bool {
        keys.contains {
            let key = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased().replacingOccurrences(of: "_", with: "-")
            if ["profile", "vo", "vf", "gpu-api", "gpu-context", "gpu-backend",
                "gpu-hwdec-interop", "libplacebo-opts"].contains(key) {
                return true
            }
            if ["scale", "cscale", "dscale", "tscale"].contains(where: {
                key == $0 || key.hasPrefix("\($0)-")
            }) {
                return true
            }
            return key == "glsl-shaders" || key.hasPrefix("glsl-shader-")
        }
    }
}

/// mpv counters can drop back to zero on a VO reset. Preserve a reset-safe interval.
struct FramePresentationDropCounter: Equatable {
    private(set) var raw: Int?
    private var interval = 0

    init(initialRaw: Int? = nil) {
        raw = initialRaw.flatMap { $0 >= 0 ? $0 : nil }
    }

    mutating func observe(_ next: Int) -> Int {
        guard next >= 0 else { return 0 }
        let delta = raw.map { next >= $0 ? next - $0 : next } ?? next
        raw = next
        interval += delta
        return delta
    }

    mutating func takeInterval() -> Int {
        defer { interval = 0 }
        return interval
    }
}

struct FramePresentationVOPassesSnapshot: Equatable, Sendable {
    let count: Int
    let averageMilliseconds: Double
    let peakMilliseconds: Double
    let slowest: String?
}

/// Counters only. Subtitle text, file names, paths, and URLs are never accepted.
struct FramePresentationDiagnosticsSnapshot: Equatable, Sendable {
    let generation: UInt64
    let drawableRequests: Int
    let drawableNil: Int
    let drawableWaitAverageMilliseconds: Double
    let drawableWaitMaximumMilliseconds: Double
    let presentedSampleCallbacks: Int
    let presentedSampleTimeValid: Int
    let presentedSampleAverageMilliseconds: Double
    let presentedSampleMaximumMilliseconds: Double
    let frameDropsSinceReceipt: Int
    let decoderDropsSinceReceipt: Int
    let subtitleCodec: String?
    let subtitleSource: String
    let subtitleCueCount: Int
    let subtitleCuesPerMinute: Double
    let voPasses: FramePresentationVOPassesSnapshot?
    let activeCscale: String?
    let mitigationPriorCscale: String?
    let mitigationApplied: Bool
    let mitigationGate: String
}

/// Shared by mpv's event queue, Metal presented handlers, and the 30-second reader.
final class FramePresentationDiagnosticsAccumulator: @unchecked Sendable {
    static let presentedSampleStride = 30

    private struct State {
        let generation: UInt64
        var intervalStartedAt: Double
        var successfulDrawableSequence = 0
        var drawableRequests = 0
        var drawableNil = 0
        var waitTotal = 0.0
        var waitMax = 0.0
        var presented = 0
        var presentedTimeValid = 0
        var presentedTotal = 0.0
        var presentedMax = 0.0
        var frameDrops: FramePresentationDropCounter
        var decoderDrops: FramePresentationDropCounter
        var subtitleCues = 0
        var lastSubtitleStart: Double?
        var voPasses: FramePresentationVOPassesSnapshot?
    }

    private let lock = NSLock()
    private var state: State?

    func begin(generation: UInt64, now: Double, frameDropRaw: Int?, decoderDropRaw: Int?) {
        lock.lock()
        state = State(
            generation: generation, intervalStartedAt: now.isFinite ? now : 0,
            frameDrops: FramePresentationDropCounter(initialRaw: frameDropRaw),
            decoderDrops: FramePresentationDropCounter(initialRaw: decoderDropRaw)
        )
        lock.unlock()
    }

    func end() {
        lock.lock()
        state = nil
        lock.unlock()
    }

    func currentGeneration() -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return state?.generation
    }

    /// A non-nil return arms one sampled Metal presented handler for this generation.
    func recordDrawable(wait: Double, returned: Bool) -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard var current = state else { return nil }
        let wait = wait.isFinite ? max(0, wait) : 0
        current.drawableRequests += 1
        current.waitTotal += wait
        current.waitMax = max(current.waitMax, wait)
        if !returned { current.drawableNil += 1 }
        if returned { current.successfulDrawableSequence += 1 }
        state = current
        return returned
            && current.successfulDrawableSequence % Self.presentedSampleStride == 0
            ? current.generation : nil
    }

    func recordPresented(generation: UInt64, latency: Double?) {
        lock.lock()
        defer { lock.unlock() }
        guard var current = state, current.generation == generation else { return }
        current.presented += 1
        if let latency, latency.isFinite, latency > 0 {
            current.presentedTimeValid += 1
            current.presentedTotal += latency
            current.presentedMax = max(current.presentedMax, latency)
        }
        state = current
    }

    func recordDrop(raw: Int, decoder: Bool) -> (generation: UInt64, delta: Int)? {
        lock.lock()
        defer { lock.unlock() }
        guard var current = state else { return nil }
        let delta = decoder
            ? current.decoderDrops.observe(raw)
            : current.frameDrops.observe(raw)
        state = current
        return (current.generation, delta)
    }

    /// `nil` or non-finite means the property is unavailable and resets deduplication.
    /// Only numeric cue starts are retained, never subtitle text.
    func recordSubtitleStart(_ start: Double?) {
        lock.lock()
        defer { lock.unlock() }
        guard var current = state else { return }
        guard let start, start.isFinite else {
            current.lastSubtitleStart = nil
            state = current
            return
        }
        if current.lastSubtitleStart != start {
            current.lastSubtitleStart = start
            current.subtitleCues += 1
        }
        state = current
    }

    func hasVOPasses(generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return state?.generation == generation && state?.voPasses != nil
    }

    func recordVOPasses(_ snapshot: FramePresentationVOPassesSnapshot, generation: UInt64) {
        lock.lock()
        if var current = state, current.generation == generation, current.voPasses == nil {
            current.voPasses = snapshot
            state = current
        }
        lock.unlock()
    }

    func takeSnapshot(
        now: Double,
        subtitleCodec: String?,
        subtitleSource: String,
        activeCscale: String?,
        mitigationPriorCscale: String?,
        mitigationApplied: Bool,
        mitigationGate: String
    ) -> FramePresentationDiagnosticsSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard var current = state else { return nil }
        let intervalEndedAt = now.isFinite
            ? max(now, current.intervalStartedAt)
            : current.intervalStartedAt
        let elapsed = intervalEndedAt - current.intervalStartedAt
        let frameDrops = current.frameDrops.takeInterval()
        let decoderDrops = current.decoderDrops.takeInterval()
        let snapshot = FramePresentationDiagnosticsSnapshot(
            generation: current.generation,
            drawableRequests: current.drawableRequests,
            drawableNil: current.drawableNil,
            drawableWaitAverageMilliseconds: current.drawableRequests > 0
                ? current.waitTotal * 1_000 / Double(current.drawableRequests) : 0,
            drawableWaitMaximumMilliseconds: current.waitMax * 1_000,
            presentedSampleCallbacks: current.presented,
            presentedSampleTimeValid: current.presentedTimeValid,
            presentedSampleAverageMilliseconds: current.presentedTimeValid > 0
                ? current.presentedTotal * 1_000 / Double(current.presentedTimeValid) : 0,
            presentedSampleMaximumMilliseconds: current.presentedMax * 1_000,
            frameDropsSinceReceipt: frameDrops,
            decoderDropsSinceReceipt: decoderDrops,
            subtitleCodec: subtitleCodec,
            subtitleSource: subtitleSource,
            subtitleCueCount: current.subtitleCues,
            subtitleCuesPerMinute: elapsed > 0 ? Double(current.subtitleCues) * 60 / elapsed : 0,
            voPasses: current.voPasses,
            activeCscale: activeCscale,
            mitigationPriorCscale: mitigationPriorCscale,
            mitigationApplied: mitigationApplied,
            mitigationGate: mitigationGate
        )
        current.intervalStartedAt = intervalEndedAt
        current.drawableRequests = 0
        current.drawableNil = 0
        current.waitTotal = 0
        current.waitMax = 0
        current.presented = 0
        current.presentedTimeValid = 0
        current.presentedTotal = 0
        current.presentedMax = 0
        current.subtitleCues = 0
        state = current
        return snapshot
    }
}
