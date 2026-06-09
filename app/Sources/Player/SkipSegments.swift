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
