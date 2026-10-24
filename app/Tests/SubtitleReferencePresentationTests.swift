import Foundation

/// Pure tests composed with the actual model and native query in the genuine-C harness. No
/// separate entry point, network, player, credentials, defaults or platform UI are required.
enum SubtitleReferencePresentationTests {
    private struct CheckFailure: Error, CustomStringConvertible {
        let description: String
    }

    private static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw CheckFailure(description: message) }
    }

    private static func cue(_ start: UInt64, _ end: UInt64, _ text: String) -> SubtitleReferenceNativeQuery.RetimedCue {
        .init(startMs: start, endMs: end, text: text)
    }

    private static func file(_ cues: [SubtitleReferenceNativeQuery.RetimedCue], job: UUID = UUID()) -> SubtitleReferenceNativeQuery.RetimedFile {
        .init(originalJob: job, srt: Data("retained original SRT bytes\n".utf8), cues: cues,
              offsetMs: 0, driftPpm: 0, confidence: 1_000)
    }

    private static func indices(_ presentation: SubtitleReferencePresentation.Presentation?) -> [Int] {
        var result: [Int] = []
        presentation?.forEachCue { result.append($0.index) }
        return result
    }

    private static func text(_ cue: SubtitleReferencePresentation.Cue) -> String {
        cue.runs.map(\.text).joined()
    }

    private static func refuses(_ source: SubtitleReferenceNativeQuery.RetimedFile,
                                _ expected: SubtitleReferencePresentation.Failure) throws {
        do {
            _ = try SubtitleReferencePresentation.prepare(source)
            throw CheckFailure(description: "unexpectedly accepted \(expected)")
        } catch let failure as SubtitleReferencePresentation.Failure {
            try check(failure == expected, "wrong refusal: \(failure), expected \(expected)")
        }
    }

    static func run() throws {
        let source = file([
            cue(1_000, 4_000, "first"), cue(2_000, 3_000, "second"),
            cue(3_000, 5_000, "third"), cue(6_000, 7_000, "fourth")
        ])
        let prepared = try SubtitleReferencePresentation.prepare(source)
        try check(prepared.originalJob == source.originalJob && prepared.retimedSRT == source.srt,
                  "preparation must retain original job and exact corrected SRT bytes")
        try check(prepared.cues.count == 4 && prepared.cues.map(\.originalText) == source.cues.map(\.text),
                  "preparation must conserve every cue and original text")
        try check(indices(prepared.lookup(mediaSeconds: 0, manualDelaySeconds: 0).presentation).isEmpty,
                  "before first cue is empty")
        try check(prepared.lookup(mediaSeconds: 0, manualDelaySeconds: 0).nextBoundaryMediaSeconds == 1,
                  "before-first lookup publishes first media boundary")
        try check(indices(prepared.lookup(mediaSeconds: 1, manualDelaySeconds: 0).presentation) == [0],
                  "start is inclusive")
        try check(indices(prepared.lookup(mediaSeconds: 2.5, manualDelaySeconds: 0).presentation) == [0, 1],
                  "all overlaps are retained in original order")
        try check(indices(prepared.lookup(mediaSeconds: 3, manualDelaySeconds: 0).presentation) == [0, 2],
                  "shared edge retires ending cue and begins new cue atomically")
        try check(indices(prepared.lookup(mediaSeconds: 4, manualDelaySeconds: 0).presentation) == [2],
                  "end is exclusive")
        let decimalBoundary = try SubtitleReferencePresentation.prepare(file([
            cue(1_001, 1_003, "decimal"), cue(1_003, 1_005, "shared")
        ]))
        try check(decimalBoundary.lookup(mediaSeconds: Double(1.001).nextDown, manualDelaySeconds: 0).presentation == nil,
                  "decimal start is not admitted before its boundary")
        try check(indices(decimalBoundary.lookup(mediaSeconds: 1.001, manualDelaySeconds: 0).presentation) == [0],
                  "decimal millisecond boundary is inclusive without multiplication rounding")
        try check(indices(decimalBoundary.lookup(mediaSeconds: Double(1.003).nextDown, manualDelaySeconds: 0).presentation) == [0],
                  "decimal cue remains active immediately before its exclusive end")
        try check(indices(decimalBoundary.lookup(mediaSeconds: 1.003, manualDelaySeconds: 0).presentation) == [1],
                  "decimal shared boundary retires and starts exact cues without an epsilon")
        try check(decimalBoundary.lookup(mediaSeconds: 1.005, manualDelaySeconds: 0).presentation == nil,
                  "decimal final end is exclusive")
        try check(indices(prepared.lookup(mediaSeconds: 5.5, manualDelaySeconds: 0).presentation).isEmpty,
                  "gap is empty")
        try check(prepared.lookup(mediaSeconds: 5.5, manualDelaySeconds: 0).nextBoundaryMediaSeconds == 6,
                  "gap retains upcoming media boundary")
        try check(prepared.lookup(mediaSeconds: 7, manualDelaySeconds: 0).presentation == nil
                  && prepared.lookup(mediaSeconds: 7, manualDelaySeconds: 0).nextBoundaryMediaSeconds == nil,
                  "final end clears without a fabricated next boundary")

        var clock = SubtitleReferencePresentation.Clock()
        let first = clock.sample(prepared, mediaSeconds: 2.1, manualDelaySeconds: 0)
        try check(first.changed && indices(first.presentation) == [0, 1], "first sample publishes")
        try check(!clock.sample(prepared, mediaSeconds: 2.9, manualDelaySeconds: 0).changed,
                  "same active set is not republished each frame")
        try check(clock.sample(prepared, mediaSeconds: 3, manualDelaySeconds: 0).changed,
                  "boundary publishes new immutable presentation")
        let backward = clock.sample(prepared, mediaSeconds: 1.5, manualDelaySeconds: 0)
        try check(backward.changed && indices(backward.presentation) == [0], "backward seek has no forward-only cursor")
        let replacement = try SubtitleReferencePresentation.prepare(source)
        try check(clock.sample(replacement, mediaSeconds: 1.5, manualDelaySeconds: 0).changed,
                  "new prepared object with same job/boundary must republish")
        clock.reset()
        try check(clock.sample(replacement, mediaSeconds: 0, manualDelaySeconds: 0).changed,
                  "reset publishes initial clear")
        try check(!clock.sample(replacement, mediaSeconds: 0.5, manualDelaySeconds: 0).changed,
                  "repeated empty interval is quiet")

        try check(indices(prepared.lookup(mediaSeconds: 302.5, manualDelaySeconds: 300).presentation) == [0, 1],
                  "positive manual delay over 120 seconds is not clamped")
        try check(indices(prepared.lookup(mediaSeconds: -297.5, manualDelaySeconds: -300).presentation) == [0, 1],
                  "negative manual delay over 120 seconds is not clamped")
        try check(prepared.lookup(mediaSeconds: 302.5, manualDelaySeconds: 300).nextBoundaryMediaSeconds == 303,
                  "next boundary uses delayed media-clock domain")
        for value in [Double.nan, Double.infinity, -Double.infinity] {
            try check(prepared.lookup(mediaSeconds: value, manualDelaySeconds: 0).presentation == nil,
                      "nonfinite clock must clear")
            try check(prepared.lookup(mediaSeconds: 2, manualDelaySeconds: value).nextBoundaryMediaSeconds == nil,
                      "nonfinite delay must not fabricate a deadline")
        }
        try check(prepared.lookup(mediaSeconds: Double.greatestFiniteMagnitude,
                                  manualDelaySeconds: -Double.greatestFiniteMagnitude).presentation == nil,
                  "clock subtraction overflow clears without integer conversion")
        try check(prepared.lookup(mediaSeconds: Double.greatestFiniteMagnitude,
                                  manualDelaySeconds: 0).presentation == nil,
                  "finite clock far beyond the final boundary clears")

        let longText = String(repeating: "x", count: 5_000)
        let complete = try SubtitleReferencePresentation.prepare(file([
            cue(0, 3_600_000, longText), cue(1, 3_600_000, "  \n preserved \t  "),
            cue(2, 3_600_000, "third"), cue(3, 3_600_000, "fourth"), cue(4, 3_600_000, "fifth")
        ]))
        try check(complete.cues[0].endMs == 3_600_000 && text(complete.cues[0]) == longText,
                  "hour-long cue and more than 4096 scalars remain complete")
        try check(text(complete.cues[1]) == "  \n preserved \t  ", "whitespace is never trimmed")
        try check(indices(complete.lookup(mediaSeconds: 5, manualDelaySeconds: 0).presentation) == [0, 1, 2, 3, 4],
                  "overlap count is not capped at three")

        let styled = try SubtitleReferencePresentation.prepare(file([
            cue(0, 2_000, "A<b>B<i>C</i>D</b><u>E</u><font color=\"#12aBef\">F<b>G</b></font>H"),
            cue(1, 2_000, "&lt;b&gt;literal&lt;/b&gt; &amp; &#65; &#x1F642; &nbsp;R&D<br/>next")
        ]))
        let runs = styled.cues[0].runs
        try check(runs.map(\.text) == ["A", "B", "C", "D", "E", "F", "G", "H"],
                  "supported nested span text remains in order")
        try check(runs[1].style.bold && runs[2].style.bold && runs[2].style.italic
                  && runs[3].style.bold && !runs[3].style.italic && !runs[7].style.bold,
                  "nested bold/italic traits restore at closing tags")
        try check(runs[4].style.underline && runs[5].style.foregroundRGB == 0x12ABEF
                  && runs[6].style.foregroundRGB == 0x12ABEF && runs[6].style.bold
                  && runs[7].style.foregroundRGB == nil,
                  "underline and authored colour scopes are retained, not replaced by base style")
        try check(text(styled.cues[1]) == "<b>literal</b> & A 🙂 \u{00A0}R&D\nnext",
                  "entities decode once without turning escaped text into markup")
        let longEntity = try SubtitleReferencePresentation.prepare(file([
            cue(0, 1_000, "&#" + String(repeating: "0", count: 40) + "65;")
        ]))
        try check(text(longEntity.cues[0]) == "A", "valid long numeric entity is not silently left undecoded")
        let tagsOnly = try SubtitleReferencePresentation.prepare(file([cue(0, 1_000, "<b></b>")]))
        try check(tagsOnly.cues.count == 1 && tagsOnly.cues[0].runs.isEmpty,
                  "empty visible span retains its authored cue and interval")

        for unsupported in ["<s>strike</s>", "<font face=\"other\">font</font>",
                            "<font color=\"red\">red</font>", "<b><i>bad</b></i>",
                            "<b>unclosed", "{\\an8}position", "&unknown;", "&#0;", "&#xD800;"] {
            let refused = file([cue(0, 1_000, "valid"), cue(1, 1_000, unsupported)])
            try refuses(refused, .unsupportedMarkup(index: 1))
            try check(refused.cues.count == 2 && refused.cues[1].text == unsupported,
                      "refusal does not mutate original complete native fallback data")
        }
        try refuses(file([]), .invalidCompleteFile)
        try refuses(file([cue(1, 1, "bad")]), .invalidCue(index: 0))
        try refuses(file([cue(2, 4, "later"), cue(1, 3, "earlier")]), .invalidCue(index: 1))
        try refuses(file([cue(0, 1, "\0")]), .invalidCue(index: 0))

        // Maximum complete native-reply cue count, with every cue simultaneously active. This
        // exercises persistent insertion/removal and original-order visitation without a cap.
        let maximum = try SubtitleReferencePresentation.prepare(file((0..<12_000).map {
            cue(UInt64($0), 3_600_000, "cue \($0)")
        }))
        let all = maximum.lookup(mediaSeconds: 20, manualDelaySeconds: 0).presentation
        try check(maximum.cues.count == 12_000 && all?.activeCueCount == 12_000
                  && indices(all) == Array(0..<12_000), "all 12000 overlapping cues are preserved")
        try check(maximum.boundaryCount == 12_001, "equal end times share one complete boundary")
        try check(maximum.lookup(mediaSeconds: 3_600, manualDelaySeconds: 0).presentation == nil,
                  "maximum-overlap final boundary retires every cue")
        print("SubtitleReferencePresentationTests: PASS (complete cues, overlaps, spans, boundaries, delay, refusal)")
    }
}
