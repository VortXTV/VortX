import Foundation

/// Local-preview capture follows the same configured playback-time cadence that
/// community coverage and VTT metadata advertise. Frame-drop diagnostics are
/// deliberately absent: telemetry must never disable capture.
///
/// `presentationReady` is a SEPARATE, non-telemetry gate (report item 8: the diagnosed output-drop bursts
/// coincide with trickplay captures run at 0/10/20s, before the display has finished settling). It answers
/// "has the presentation pipeline been stable long enough for a capture to be safe", derived only from
/// elapsed time and the HDMI display-mode-switch state - never from a frame-drop count - so it does not
/// reopen the deliberately-rejected feedback loop above. Defaults to `true` so every other call site (and
/// the existing tests) is unaffected.
struct TrickplayCaptureCadencePolicy {
    static func shouldCapture(
        playbackTime: Double,
        lastCaptureTime: Double,
        intervalSeconds: Double,
        playbackActive: Bool,
        isScrubbing: Bool,
        captureInFlight: Bool,
        presentationReady: Bool = true
    ) -> Bool {
        guard playbackTime.isFinite,
              lastCaptureTime.isFinite,
              intervalSeconds.isFinite,
              intervalSeconds > 0,
              playbackTime > 0,
              playbackActive,
              !isScrubbing,
              !captureInFlight,
              presentationReady else { return false }
        let elapsed = playbackTime - lastCaptureTime
        return elapsed <= -intervalSeconds || elapsed >= intervalSeconds
    }
}

/// Separates the local renderer capture decision from remote/provider preview availability. UHD HDR local
/// grabs can extend the renderer's drawable-acquire work, while a provider sprite sheet has no such cost.
/// Unknown or unprobed media is deliberately non-UHD here, so it fails open to the ordinary local path.
struct TrickplayLocalCaptureEligibilityPolicy {
    enum DynamicRange: Equatable, Sendable {
        case dolbyVision
        case hdr10
        case hlg
        case hdr
        case sdr
        case unknown

        var isHDR: Bool {
            switch self {
            case .dolbyVision, .hdr10, .hlg, .hdr:
                return true
            case .sdr, .unknown:
                return false
            }
        }
    }

    struct Input: Equatable, Sendable {
        let isUltraHighDefinition: Bool
        let dynamicRange: DynamicRange
    }

    struct Decision: Equatable, Sendable {
        let isUltraHighDefinitionHDR: Bool
        let permitsLocalCapture: Bool
        let permitsRemoteProviderPreviews: Bool
    }

    static func decision(_ input: Input) -> Decision {
        let isUltraHighDefinitionHDR = input.isUltraHighDefinition && input.dynamicRange.isHDR
        return .init(
            isUltraHighDefinitionHDR: isUltraHighDefinitionHDR,
            permitsLocalCapture: !isUltraHighDefinitionHDR,
            permitsRemoteProviderPreviews: true
        )
    }
}

/// First-frame + display-settle readiness for trickplay capture (report item 8). The libmpv frame grab
/// scales the drawable INLINE on mpv's VO thread (`MetalLayer.nextDrawable`, right before the very next
/// present), so a capture request that lands during a display-mode renegotiation or in the first seconds of
/// a new renderer generation extends exactly the drawable wait the diagnosed bursts show. Withholding
/// capture until both gates clear keeps every capture's GPU work outside that window without having to move
/// the scale off the VO thread. UHD HDR/DV content gets the longer threshold: it is both the most expensive
/// frame to scale and the specific case the diagnostic log ties to a drop burst.
enum TrickplayPresentationReadinessPolicy {
    static let defaultSettleSeconds: Double = 5
    static let uhdHDRSettleSeconds: Double = 30

    static func isReady(
        elapsedSinceFirstFrame: Double?,
        displaySwitchSettled: Bool,
        isUltraHighDefinitionHDR: Bool
    ) -> Bool {
        guard displaySwitchSettled,
              let elapsedSinceFirstFrame, elapsedSinceFirstFrame.isFinite else {
            return false
        }
        let threshold = isUltraHighDefinitionHDR ? uhdHDRSettleSeconds : defaultSettleSeconds
        return elapsedSinceFirstFrame >= threshold
    }
}

/// A physical engine or source remount keeps the same stable media key and must
/// retain all local, community, and session capture state. Only a true media or
/// episode-timeline key change starts a fresh capture session.
enum TrickplayCaptureSessionPolicy {
    enum Transition: Equatable {
        case preserve
        case reset
    }

    static func transition(
        from currentMediaKey: String?,
        to nextMediaKey: String?
    ) -> Transition {
        currentMediaKey == nextMediaKey ? .preserve : .reset
    }
}

/// Data-only disk seam for local trickplay frames. LocalTrickplayFrameCache owns
/// scheduling and decoded-image memory; this keeps its existing on-disk address
/// stable and lets a fresh cache instance read a prior session's bytes.
struct TrickplayFrameDiskStore {
    let directory: URL

    func write(_ data: Data, mediaKey: String, bucket: Int) throws {
        try data.write(
            to: fileURL(mediaKey: mediaKey, bucket: bucket),
            options: .atomic
        )
    }

    func data(mediaKey: String, bucket: Int) -> Data? {
        try? Data(contentsOf: fileURL(mediaKey: mediaKey, bucket: bucket))
    }

    /// The stored frame whose bucket is CLOSEST to `targetBucket` in either direction, for this media only.
    /// A last-resort scrub fallback: when no frame sits within the primary at-or-before lookback (a scrub past
    /// what has been captured, or into a gap wider than that window), the nearest captured frame still gives an
    /// approximate preview instead of "unavailable". Enumerates this media's files once; nil when it has none.
    /// Runs off the main thread (called only from the cache's ioQueue).
    func nearest(mediaKey: String, targetBucket: Int) -> (bucket: Int, data: Data)? {
        let prefix = filePrefix(mediaKey) + "-"
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return nil }
        var bestBucket: Int?
        var bestDistance = Int.max
        for file in files {
            let name = file.lastPathComponent
            guard name.hasPrefix(prefix), name.hasSuffix(".jpg") else { continue }
            let middle = name.dropFirst(prefix.count).dropLast(4)   // strip "<prefix>-" and ".jpg" -> bucket digits
            guard let bucket = Int(middle) else { continue }
            let distance = abs(bucket - targetBucket)
            if distance < bestDistance { bestDistance = distance; bestBucket = bucket }
        }
        guard let bestBucket, let data = data(mediaKey: mediaKey, bucket: bestBucket) else { return nil }
        return (bestBucket, data)
    }

    private func fileURL(mediaKey: String, bucket: Int) -> URL {
        directory.appendingPathComponent(
            "\(filePrefix(mediaKey))-\(bucket).jpg"
        )
    }

    private func filePrefix(_ mediaKey: String) -> String {
        Data(mediaKey.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// One shared cancellation predicate for every expensive stage of an owned
/// community-upload task. The task that owns the policy is the same task that
/// composes, encodes, and posts, so cancellation remains observable throughout.
enum TrickplayOwnedWorkGate {
    static func permitsStage(taskIsCancelled: Bool) -> Bool {
        !taskIsCancelled
    }
}

/// Per accepted media load circuit breaker for local frame grabs. Remote/community previews remain
/// available; this only stops repeatedly asking a renderer that has proven it cannot supply a frame.
struct TrickplayLocalCaptureBreaker: Equatable, Sendable {
    private(set) var consecutiveNilCaptures = 0
    private(set) var isOpen = false
    static let nilCaptureLimit = 3

    mutating func reset() {
        consecutiveNilCaptures = 0
        isOpen = false
    }

    /// Returns true exactly once, when the breaker opens.
    mutating func recordCapture(hadData: Bool) -> Bool {
        if hadData {
            reset()
            return false
        }
        guard !isOpen else { return false }
        consecutiveNilCaptures += 1
        if consecutiveNilCaptures >= Self.nilCaptureLimit {
            isOpen = true
            return true
        }
        return false
    }
}

/// Small state machine that keeps community trickplay useful without rebuilding the
/// full sprite sheet every minute. Each exact content key gets one progressive
/// attempt once its capture is storable, plus at most one teardown attempt after a
/// failure, progressive decline, or material coverage growth. A declined progressive
/// remains one-shot; a declined or stored teardown response is final for that key.
struct TrickplayUploadPolicy {
    enum Kind: Equatable, Sendable {
        case progressive
        case final
    }

    enum Outcome: Equatable, Sendable {
        case stored
        case rejected
        case failed
    }

    struct Claim: Equatable, Hashable, Sendable {
        let key: String
        let sequence: UInt64
        let kind: Kind
        let frameCount: Int
    }

    enum Admission: Equatable, Sendable {
        case start(Claim)
        case deferred(Claim)
    }

    struct Completion: Equatable, Sendable {
        let applied: Bool
        let nextClaim: Claim?
    }

    private struct KeyState {
        var isTerminal = false
        var progressiveAttempted = false
        var finalAttempted = false
        var progressiveStoredFrameCount: Int?
        var progressiveFinalBaselineFrameCount: Int?
    }

    private(set) var key: String?
    private(set) var inFlight: Claim?
    private(set) var deferredFinals: [Claim] = []
    private var states: [String: KeyState] = [:]
    private var nextSequence: UInt64 = 1
    private static let maxDeferredFinals = 2

    var isTerminal: Bool {
        guard let key else { return false }
        return states[key]?.isTerminal ?? false
    }

    var progressiveAttempted: Bool {
        guard let key else { return false }
        return states[key]?.progressiveAttempted ?? false
    }

    var finalAttempted: Bool {
        guard let key else { return false }
        return states[key]?.finalAttempted ?? false
    }

    var progressiveStoredFrameCount: Int? {
        guard let key else { return nil }
        return states[key]?.progressiveStoredFrameCount
    }

    /// Selects the current capture key without destroying admitted work from the
    /// previous key. At most one upload runs and at most two final snapshots wait,
    /// so rapid title changes cannot create an unbounded queue.
    mutating func reset(for key: String?) {
        guard self.key != key else { return }
        self.key = key
        if let key, states[key] == nil {
            states[key] = KeyState()
        }
        pruneRetiredStates()
    }

    mutating func request(
        key: String,
        kind: Kind,
        frameCount: Int,
        existingFrameCount: Int,
        coverageReady: Bool
    ) -> Admission? {
        if self.key != key { reset(for: key) }
        var state = states[key] ?? KeyState()
        guard !state.isTerminal,
              frameCount >= 2,
              frameCount > existingFrameCount,
              coverageReady else { return nil }

        switch kind {
        case .progressive:
            guard inFlight == nil,
                  !state.progressiveAttempted else { return nil }
            state.progressiveAttempted = true
        case .final:
            guard !state.finalAttempted else { return nil }
            if let baseline = state.progressiveFinalBaselineFrameCount {
                let materialGrowth = max(6, baseline / 4)
                guard frameCount >= baseline + materialGrowth else { return nil }
            }
            if inFlight != nil,
               deferredFinals.count >= Self.maxDeferredFinals {
                return nil
            }
            state.finalAttempted = true
        }
        states[key] = state

        let claim = Claim(
            key: key,
            sequence: nextSequence,
            kind: kind,
            frameCount: frameCount
        )
        nextSequence &+= 1
        if inFlight != nil {
            deferredFinals.append(claim)
            return .deferred(claim)
        }
        inFlight = claim
        return .start(claim)
    }

    /// Retires the selected content key in one transition. The final reservation
    /// is made before selection moves to the next content, so callers can snapshot
    /// the old frames without manually racing a separate final request and reset.
    mutating func retireCurrent(
        frameCount: Int,
        existingFrameCount: Int,
        coverageReady: Bool,
        selecting nextKey: String?
    ) -> Admission? {
        guard let retiringKey = key else {
            reset(for: nextKey)
            return nil
        }
        let admission = request(
            key: retiringKey,
            kind: .final,
            frameCount: frameCount,
            existingFrameCount: existingFrameCount,
            coverageReady: coverageReady
        )
        reset(for: nextKey)
        return admission
    }

    /// Applies only the exact active claim. A completion may belong to a retired
    /// key, because admitted old-key work survives a title change. It can start at
    /// most one eligible deferred final; duplicates and superseded completions do
    /// not mutate the current key.
    mutating func complete(_ claim: Claim, outcome: Outcome) -> Completion {
        guard inFlight == claim else {
            return Completion(applied: false, nextClaim: nil)
        }
        inFlight = nil
        var state = states[claim.key] ?? KeyState()
        switch outcome {
        case .stored:
            if claim.kind == .progressive {
                state.progressiveStoredFrameCount = claim.frameCount
                state.progressiveFinalBaselineFrameCount = claim.frameCount
            } else {
                state.isTerminal = true
            }
        case .rejected:
            if claim.kind == .progressive {
                state.progressiveFinalBaselineFrameCount = claim.frameCount
            } else {
                state.isTerminal = true
            }
        case .failed:
            break
        }
        states[claim.key] = state

        let next = dequeueEligibleFinal()
        inFlight = next
        pruneRetiredStates()
        return Completion(applied: true, nextClaim: next)
    }

    private mutating func dequeueEligibleFinal() -> Claim? {
        while !deferredFinals.isEmpty {
            let candidate = deferredFinals.removeFirst()
            guard let state = states[candidate.key],
                  !state.isTerminal else { continue }
            if let baseline = state.progressiveFinalBaselineFrameCount {
                let materialGrowth = max(6, baseline / 4)
                guard candidate.frameCount >= baseline + materialGrowth else {
                    continue
                }
            }
            return candidate
        }
        return nil
    }

    private mutating func pruneRetiredStates() {
        let retained = Set(
            [key, inFlight?.key].compactMap { $0 }
                + deferredFinals.map(\.key)
        )
        states = states.filter { retained.contains($0.key) }
    }
}
