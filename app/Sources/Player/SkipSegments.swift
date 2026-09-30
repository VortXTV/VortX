import Foundation

/// One entry from mpv's `chapter-list` (a title and its start time, in seconds).
struct MPVChapter: Equatable {
    let title: String
    let start: Double
}

/// A skippable span the player offers to jump past.
struct SkipSegment: Equatable, Identifiable {
    enum Kind: String, Codable { case intro, recap, credits, preview }
    let kind: Kind
    let start: Double
    let end: Double
    var id: String { "\(kind.rawValue)-\(Int(start))" }
    var label: String {
        switch kind {
        case .intro:   return "Skip Intro"
        case .recap:   return "Skip Recap"
        case .credits: return "Skip Credits"
        case .preview: return "Skip Preview"
        }
    }
}

/// The persisted automatic-skip delay. The old `stremiox.autoSkip` Bool predates the countdown and
/// defaulted to false, so it cannot be read with a typed default without changing the meaning of an
/// existing user's explicit Off choice. Keep the migration here, beside the shared segment model, so
/// tvOS, iOS, and macOS all resolve the same setting before their player or Settings surface renders.
enum AutoSkipSettings {
    static let delayKey = "stremiox.autoSkipDelaySeconds"
    static let legacyKey = "stremiox.autoSkip"
    static let defaultDelaySeconds = 5

    /// A small, honest choice grid: Off plus the common 5/10/15 second waits and a longer 30 second
    /// option. The policy still accepts any finite value in the safe 0...120 range for synced/custom
    /// values, while Settings only exposes these reachable presets.
    static let choices: [Int] = [0, 5, 10, 15, 30]
    static let choiceLabels: [Int: String] = [
        0: "Off", 5: "5 seconds", 10: "10 seconds", 15: "15 seconds", 30: "30 seconds",
    ]

    static func delaySeconds(in defaults: UserDefaults = .standard) -> Double {
        migrateIfNeeded(in: defaults)
        guard let value = defaults.object(forKey: delayKey) as? NSNumber else {
            return Double(defaultDelaySeconds)
        }
        return Double(sanitized(Double(value.intValue)))
    }

    static func setDelaySeconds(_ seconds: Double, in defaults: UserDefaults = .standard) {
        let normalized = sanitized(seconds)
        defaults.set(normalized, forKey: delayKey)
        // Keep the old key coherent for older builds and account restore readers. This Bool is not the
        // source of truth once the delay key exists; in particular, legacy false is migrated to Off.
        defaults.set(normalized > 0, forKey: legacyKey)
    }

    static func migrateIfNeeded(in defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: delayKey) == nil else { return }
        guard let legacy = defaults.object(forKey: legacyKey) as? NSNumber else { return }
        defaults.set(legacy.boolValue ? defaultDelaySeconds : 0, forKey: delayKey)
    }

    private static func sanitized(_ seconds: Double) -> Int {
        guard seconds.isFinite else { return defaultDelaySeconds }
        // Clamp before converting: a finite synced/custom value can still exceed Int's range.
        return Int(Swift.min(Swift.max(seconds.rounded(), 0), 120))
    }
}

/// Stable identity for one skip span. Start alone is insufficient: two providers can legitimately expose
/// different segment kinds at the same time, and their cancel/completion state must not collide.
struct AutoSkipSegmentKey: Hashable, Equatable {
    let kind: String
    let startMilliseconds: Int
    let endMilliseconds: Int

    init(segment: SkipSegment) {
        kind = segment.kind.rawValue
        startMilliseconds = Int((segment.start * 1000).rounded())
        endMilliseconds = Int((segment.end * 1000).rounded())
    }
}

/// State for the position-driven automatic-skip countdown. It deliberately contains no Task, Timer, Date,
/// or wall-clock value: only genuine playback position deltas can spend the wait. `epoch` is an ownership
/// fence for player hooks that issue a seek after a decision; source/episode changes and user seeks advance
/// it so an old decision cannot jump a new title.
struct AutoSkipCountdownState: Equatable {
    var mediaID: String?
    var epoch: UInt64 = 0
    var lastPosition: Double?
    var activeSegment: AutoSkipSegmentKey?
    var accruedPlaybackSeconds: Double = 0
    var cancelledSegments: Set<AutoSkipSegmentKey> = []
    var completedSegments: Set<AutoSkipSegmentKey> = []

    init(mediaID: String? = nil) { self.mediaID = mediaID }

    func isSuppressed(for segment: SkipSegment) -> Bool {
        let key = AutoSkipSegmentKey(segment: segment)
        return cancelledSegments.contains(key) || completedSegments.contains(key)
    }
}

enum AutoSkipCountdownDecision: Equatable {
    case idle
    case prompt(segment: AutoSkipSegmentKey, remainingSeconds: Double)
    case skip(segment: AutoSkipSegmentKey, targetSeconds: Double, epoch: UInt64)
}

/// Pure countdown policy shared by the native Apple players. Call `advance` from the existing playback
/// position callback; pass `playbackActive = !isPaused && !buffering`. A paused or buffering callback may
/// still update the remembered position, but it can never spend countdown time.
enum AutoSkipCountdownPolicy {
    /// A delayed position sample larger than this is treated as a seek/telemetry discontinuity, not as real
    /// viewing time. This is intentionally conservative: the player must receive several ordinary samples
    /// before an automatic skip can complete.
    static let maximumSampleDeltaSeconds = 2.0

    static func advance(
        state: inout AutoSkipCountdownState,
        mediaID: String,
        segment: SkipSegment?,
        position: Double,
        duration: Double? = nil,
        playbackActive: Bool,
        delaySeconds: Double
    ) -> AutoSkipCountdownDecision {
        guard position.isFinite else { return .idle }
        bindMediaIfNeeded(&state, mediaID: mediaID)

        guard let segment else {
            clearActive(&state, position: position)
            return .idle
        }
        let key = AutoSkipSegmentKey(segment: segment)
        if state.activeSegment != key {
            state.activeSegment = key
            state.accruedPlaybackSeconds = 0
            state.epoch &+= 1
        }

        let safeDelay = delaySeconds.isFinite ? max(0, delaySeconds) : 0
        let previous = state.lastPosition
        state.lastPosition = position
        if let previous {
            let delta = position - previous
            if !delta.isFinite || delta < 0 || delta > maximumSampleDeltaSeconds {
                // Backward/large jumps are manual seeks or bad telemetry. They invalidate a pending
                // decision but do not permanently cancel the segment.
                state.accruedPlaybackSeconds = 0
                state.epoch &+= 1
            } else if playbackActive, delta > 0, safeDelay > 0 {
                state.accruedPlaybackSeconds = min(safeDelay, state.accruedPlaybackSeconds + delta)
            }
        }

        guard safeDelay > 0,
              !state.cancelledSegments.contains(key),
              !state.completedSegments.contains(key) else {
            return .idle
        }
        if state.accruedPlaybackSeconds >= safeDelay {
            state.completedSegments.insert(key)
            state.epoch &+= 1
            let target = clampedEnd(segment.end, duration: duration, start: segment.start)
            return .skip(segment: key, targetSeconds: target, epoch: state.epoch)
        }
        return .prompt(
            segment: key,
            remainingSeconds: max(0, safeDelay - state.accruedPlaybackSeconds)
        )
    }

    /// Permanently suppress automatic handling of this segment for the current media identity. A later
    /// manual seek back into the span remains possible, but it will never auto-fire again for this media.
    static func cancel(state: inout AutoSkipCountdownState, segment: SkipSegment) {
        let key = AutoSkipSegmentKey(segment: segment)
        state.cancelledSegments.insert(key)
        state.accruedPlaybackSeconds = 0
        state.epoch &+= 1
    }

    /// Manual Skip is immediate and records completion, so the same segment cannot auto-fire after a user
    /// seek or a source failover in the same episode.
    static func complete(state: inout AutoSkipCountdownState, segment: SkipSegment) {
        state.completedSegments.insert(AutoSkipSegmentKey(segment: segment))
        state.accruedPlaybackSeconds = 0
        state.epoch &+= 1
    }

    /// Invalidate a queued automatic decision while preserving cancelled/completed segment memory. Use for
    /// manual seeks and source replacement within the same media identity.
    static func invalidatePending(state: inout AutoSkipCountdownState, position: Double? = nil) {
        state.activeSegment = nil
        state.accruedPlaybackSeconds = 0
        state.lastPosition = position
        state.epoch &+= 1
    }

    /// Bind a new episode/movie identity. A new media identity starts with empty per-segment memory; the
    /// same media identity is treated as a source/seek rebind and retains cancel/completion decisions.
    static func bindMedia(_ state: inout AutoSkipCountdownState, mediaID: String) {
        bindMediaIfNeeded(&state, mediaID: mediaID)
    }

    static func isCurrent(
        state: AutoSkipCountdownState,
        mediaID: String,
        segment: SkipSegment,
        epoch: UInt64
    ) -> Bool {
        state.mediaID == mediaID
            && state.activeSegment == AutoSkipSegmentKey(segment: segment)
            && state.epoch == epoch
    }

    private static func bindMediaIfNeeded(_ state: inout AutoSkipCountdownState, mediaID: String) {
        guard state.mediaID != mediaID else { return }
        state.mediaID = mediaID
        state.lastPosition = nil
        state.activeSegment = nil
        state.accruedPlaybackSeconds = 0
        state.cancelledSegments.removeAll()
        state.completedSegments.removeAll()
        state.epoch &+= 1
    }

    private static func clearActive(_ state: inout AutoSkipCountdownState, position: Double) {
        if state.activeSegment != nil { state.epoch &+= 1 }
        state.activeSegment = nil
        state.accruedPlaybackSeconds = 0
        state.lastPosition = position
    }

    private static func clampedEnd(_ end: Double, duration: Double?, start: Double) -> Double {
        let lower = max(0, start)
        guard let duration, duration.isFinite, duration > 0 else { return max(lower, end) }
        return min(duration, max(lower, end))
    }
}

/// A detected span from ONE source, before resolution. Each detection layer (named chapters today,
/// crowd-sourced timestamps, later on-device fingerprint/heuristics) produces candidates and the
/// `SegmentResolver` votes, so layers stay independent and new ones just plug in.
struct SegmentCandidate: Equatable {
    enum Source: Int, Comparable {
        case chapter = 0, crowdAPI = 1, manual = 2          // priority order: higher wins ties
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }
    let kind: SkipSegment.Kind
    let start: Double
    let end: Double
    let source: Source
    let confidence: Double
}

/// Merges candidates from all layers into the final skip segments. Every span passes sanity guards
/// first (an intro must end in the first 60% of the runtime, credits must start in the back half),
/// so one bad crowd entry or mis-titled chapter can never cause a wild mid-episode skip. Where two
/// layers found the same span, the higher-confidence source wins.
enum SegmentResolver {
    static func resolve(_ candidates: [SegmentCandidate], duration: Double) -> [SkipSegment] {
        guard duration > 0 else { return [] }
        var pool = candidates.compactMap { clamp($0, duration: duration) }
        var result: [SkipSegment] = []
        while let seed = pool.first {
            var cluster = [seed]
            pool.removeFirst()
            pool.removeAll { other in
                guard other.kind == seed.kind, other.start < seed.end, seed.start < other.end else { return false }
                cluster.append(other)
                return true
            }
            if let best = cluster.max(by: { ($0.confidence, $0.source) < ($1.confidence, $1.source) }) {
                result.append(SkipSegment(kind: best.kind, start: best.start, end: best.end))
            }
        }
        return result.sorted { $0.start < $1.start }
    }

    private static func clamp(_ c: SegmentCandidate, duration: Double) -> SegmentCandidate? {
        let start = max(0, min(c.start, duration))
        let end = max(0, min(c.end, duration))
        guard end - start >= 5 else { return nil }          // sub-5s spans are noise, not segments
        switch c.kind {
        case .intro, .recap:
            guard end - start <= 1200, end <= duration * 0.6 else { return nil }
        case .credits, .preview:
            guard start >= duration * 0.5 else { return nil }
        }
        return SegmentCandidate(kind: c.kind, start: start, end: end, source: c.source, confidence: c.confidence)
    }
}

/// Layer 1: skip spans from named media chapters, the universal (no-network) baseline that desktop
/// players use. A chapter whose title reads like an opening/recap becomes an intro/recap, an
/// ending/credits chapter becomes credits, and the segment runs to the next chapter's start (or the
/// end of the file). Crowd-sourced timestamps (SkipTimestampService) layer on top via the resolver.
enum SkipSegments {
    /// `(token, requiresWholeWord)`. Short ambiguous tokens (anime "OP"/"ED") need a word boundary so
    /// they don't match inside longer words ("op" must not fire on "Opening" or "Stop").
    private static let introTokens: [(String, Bool)] = [
        ("opening", false), ("intro", false), ("op", true),
    ]
    private static let recapTokens: [(String, Bool)] = [
        ("recap", false), ("previously", false),
    ]
    private static let creditsTokens: [(String, Bool)] = [
        ("ending", false), ("outro", false), ("credits", false), ("closing", false), ("ed", true),
    ]
    private static let previewTokens: [(String, Bool)] = [
        ("preview", false), ("next episode", false),
    ]

    /// Intro is checked before credits so "opening credits" reads as an intro, not credits.
    static func chapterCandidates(chapters: [MPVChapter], duration: Double) -> [SegmentCandidate] {
        guard !chapters.isEmpty, duration > 0 else { return [] }
        let sorted = chapters.sorted { $0.start < $1.start }
        var candidates: [SegmentCandidate] = []
        for (i, chapter) in sorted.enumerated() {
            let title = chapter.title.lowercased()
            let kind: SkipSegment.Kind?
            if introTokens.contains(where: { matches(title, $0.0, wholeWord: $0.1) }) {
                kind = .intro
            } else if recapTokens.contains(where: { matches(title, $0.0, wholeWord: $0.1) }) {
                kind = .recap
            } else if creditsTokens.contains(where: { matches(title, $0.0, wholeWord: $0.1) }) {
                kind = .credits
            } else if previewTokens.contains(where: { matches(title, $0.0, wholeWord: $0.1) }) {
                kind = .preview
            } else {
                kind = nil
            }
            guard let kind else { continue }
            let end = i + 1 < sorted.count ? sorted[i + 1].start : duration
            guard end > chapter.start + 1 else { continue }   // ignore degenerate / zero-length spans
            candidates.append(SegmentCandidate(kind: kind, start: chapter.start, end: end,
                                               source: .chapter, confidence: 0.8))
        }
        return candidates
    }

    /// Chapter-only detection, kept for callers that don't merge other layers.
    static func detect(chapters: [MPVChapter], duration: Double) -> [SkipSegment] {
        SegmentResolver.resolve(chapterCandidates(chapters: chapters, duration: duration), duration: duration)
    }

    private static func matches(_ title: String, _ token: String, wholeWord: Bool) -> Bool {
        guard let range = title.range(of: token) else { return false }
        guard wholeWord else { return true }
        let before = range.lowerBound == title.startIndex ? nil : title[title.index(before: range.lowerBound)]
        let after = range.upperBound == title.endIndex ? nil : title[range.upperBound]
        func isBoundary(_ c: Character?) -> Bool { c == nil || !c!.isLetter }
        return isBoundary(before) && isBoundary(after)
    }
}

/// Pure helper for drawing chapter boundary ticks on the seek bar (both players share it). Lives beside
/// `MPVChapter` and is side-effect-free so it unit-tests like the skip logic above.
enum ChapterMarks {
    /// Chapter start times as fractions of the runtime (0...1), for tick marks along the scrubber. Drops
    /// the implicit leading chapter (start < 1s) and any marker within 5s of the end (cosmetic noise),
    /// then collapses fractions that round to the same 0.1% position so a `ForEach(id: \.self)` over the
    /// result is always stable (no duplicate ids, no crash).
    static func fractions(chapters: [MPVChapter], duration: Double) -> [Double] {
        guard duration > 0 else { return [] }
        var seen = Set<Int>()
        var out: [Double] = []
        for start in chapters.map(\.start).sorted() where start > 1 && start < duration - 5 {
            let key = Int(((start / duration) * 1000).rounded())
            guard key > 0, key < 1000, seen.insert(key).inserted else { continue }
            out.append(Double(key) / 1000)
        }
        return out
    }
}
