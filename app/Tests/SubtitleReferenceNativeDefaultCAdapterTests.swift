// Genuine current-C integration acceptance, run only by the explicit matching-header/library
// harness. The complete production Runtime and query adapter are compiled without substitutes.
// This file deliberately supplies no resolve closure and never opens a player or account.
import Foundation
import Darwin

@main
private enum SubtitleReferenceNativeDefaultCAdapterTests {
    private enum Failure: Error, CustomStringConvertible {
        case check(String)

        var description: String {
            switch self {
            case .check(let name): return name
            }
        }
    }

    private static let job = UUID(uuidString: "540678ac-490c-46fe-a449-994af0393410")!

    // This is the full external file authored from the shared Rust contract's 24 starts. The
    // escaped quote characters are intentional cue text, not SRT positioning metadata.
    private static let externalSRT = Data((#"""
1
00:00:10,000 --> 00:00:11,200
外部 0
quoted \"words\" & second line

2
00:00:14,730 --> 00:00:15,930
外部 1
quoted \"words\" & second line

3
00:00:22,190 --> 00:00:23,390
外部 2
quoted \"words\" & second line

4
00:00:30,870 --> 00:00:32,070
外部 3
quoted \"words\" & second line

5
00:00:33,510 --> 00:00:34,710
外部 4
quoted \"words\" & second line

6
00:00:45,640 --> 00:00:46,840
外部 5
quoted \"words\" & second line

7
00:01:01,930 --> 00:01:03,130
外部 6
quoted \"words\" & second line

8
00:01:05,070 --> 00:01:06,270
外部 7
quoted \"words\" & second line

9
00:01:19,810 --> 00:01:21,010
外部 8
quoted \"words\" & second line

10
00:01:24,260 --> 00:01:25,460
外部 9
quoted \"words\" & second line

11
00:01:43,540 --> 00:01:44,740
外部 10
quoted \"words\" & second line

12
00:01:52,990 --> 00:01:54,190
外部 11
quoted \"words\" & second line

13
00:01:58,170 --> 00:01:59,370
外部 12
quoted \"words\" & second line

14
00:02:14,380 --> 00:02:15,580
外部 13
quoted \"words\" & second line

15
00:02:21,020 --> 00:02:22,220
外部 14
quoted \"words\" & second line

16
00:02:38,690 --> 00:02:39,890
外部 15
quoted \"words\" & second line

17
00:02:47,430 --> 00:02:48,630
外部 16
quoted \"words\" & second line

18
00:03:01,750 --> 00:03:02,950
外部 17
quoted \"words\" & second line

19
00:03:20,810 --> 00:03:22,010
外部 18
quoted \"words\" & second line

20
00:03:27,470 --> 00:03:28,670
外部 19
quoted \"words\" & second line

21
00:03:45,990 --> 00:03:47,190
外部 20
quoted \"words\" & second line

22
00:03:52,180 --> 00:03:53,380
外部 21
quoted \"words\" & second line

23
00:04:11,630 --> 00:04:12,830
外部 22
quoted \"words\" & second line

24
00:04:26,470 --> 00:04:27,670
外部 23
quoted \"words\" & second line
"""# + "\n\n").utf8)

    // Independent full-file golden: every start/end is authored after the expected +2750 ms
    // correction. It is intentionally not derived from the returned file or externalSRT.
    private static let expectedRetimedSRT = Data((#"""
1
00:00:12,750 --> 00:00:13,950
外部 0
quoted \"words\" & second line

2
00:00:17,480 --> 00:00:18,680
外部 1
quoted \"words\" & second line

3
00:00:24,940 --> 00:00:26,140
外部 2
quoted \"words\" & second line

4
00:00:33,620 --> 00:00:34,820
外部 3
quoted \"words\" & second line

5
00:00:36,260 --> 00:00:37,460
外部 4
quoted \"words\" & second line

6
00:00:48,390 --> 00:00:49,590
外部 5
quoted \"words\" & second line

7
00:01:04,680 --> 00:01:05,880
外部 6
quoted \"words\" & second line

8
00:01:07,820 --> 00:01:09,020
外部 7
quoted \"words\" & second line

9
00:01:22,560 --> 00:01:23,760
外部 8
quoted \"words\" & second line

10
00:01:27,010 --> 00:01:28,210
外部 9
quoted \"words\" & second line

11
00:01:46,290 --> 00:01:47,490
外部 10
quoted \"words\" & second line

12
00:01:55,740 --> 00:01:56,940
外部 11
quoted \"words\" & second line

13
00:02:00,920 --> 00:02:02,120
外部 12
quoted \"words\" & second line

14
00:02:17,130 --> 00:02:18,330
外部 13
quoted \"words\" & second line

15
00:02:23,770 --> 00:02:24,970
外部 14
quoted \"words\" & second line

16
00:02:41,440 --> 00:02:42,640
外部 15
quoted \"words\" & second line

17
00:02:50,180 --> 00:02:51,380
外部 16
quoted \"words\" & second line

18
00:03:04,500 --> 00:03:05,700
外部 17
quoted \"words\" & second line

19
00:03:23,560 --> 00:03:24,760
外部 18
quoted \"words\" & second line

20
00:03:30,220 --> 00:03:31,420
外部 19
quoted \"words\" & second line

21
00:03:48,740 --> 00:03:49,940
外部 20
quoted \"words\" & second line

22
00:03:54,930 --> 00:03:56,130
外部 21
quoted \"words\" & second line

23
00:04:14,380 --> 00:04:15,580
外部 22
quoted \"words\" & second line

24
00:04:29,220 --> 00:04:30,420
外部 23
quoted \"words\" & second line
"""# + "\n\n").utf8)

    private static let reference: [SubtitleReferenceNativeQuery.Timing] = [
        .init(startMs: 12_750, endMs: 13_750), .init(startMs: 17_480, endMs: 18_480),
        .init(startMs: 24_940, endMs: 25_940), .init(startMs: 33_620, endMs: 34_620),
        .init(startMs: 36_260, endMs: 37_260), .init(startMs: 48_390, endMs: 49_390),
        .init(startMs: 64_680, endMs: 65_680), .init(startMs: 67_820, endMs: 68_820),
        .init(startMs: 82_560, endMs: 83_560), .init(startMs: 87_010, endMs: 88_010),
        .init(startMs: 106_290, endMs: 107_290), .init(startMs: 115_740, endMs: 116_740),
        .init(startMs: 120_920, endMs: 121_920), .init(startMs: 137_130, endMs: 138_130),
        .init(startMs: 143_770, endMs: 144_770), .init(startMs: 161_440, endMs: 162_440),
        .init(startMs: 170_180, endMs: 171_180), .init(startMs: 184_500, endMs: 185_500),
        .init(startMs: 203_560, endMs: 204_560), .init(startMs: 210_220, endMs: 211_220),
        .init(startMs: 228_740, endMs: 229_740), .init(startMs: 234_930, endMs: 235_930),
        .init(startMs: 254_380, endMs: 255_380), .init(startMs: 269_220, endMs: 270_220)
    ]

    private static func require(_ condition: @autoclosure () -> Bool, _ name: String) throws {
        guard condition() else { throw Failure.check(name) }
    }

    private static func requireLocalRefusals() throws {
        try require(!Thread.isMainThread, "local refusal checks did not run on utility worker")
        // These are genuine adapter guard paths; each call omits resolve and must refuse before
        // crossing into native C because the input cannot satisfy the public API.
        try require(
            SubtitleReferenceNativeQuery.align(
                externalSRT: Data(), reference: reference, originalJob: job
            ) == nil,
            "empty external SRT was accepted"
        )
        try require(
            SubtitleReferenceNativeQuery.align(
                externalSRT: externalSRT, reference: Array(reference.prefix(7)), originalJob: job
            ) == nil,
            "short reference was accepted"
        )
        try require(
            SubtitleReferenceNativeQuery.align(
                externalSRT: Data([0xff]), reference: reference, originalJob: job
            ) == nil,
            "invalid UTF-8 SRT was accepted"
        )
    }

    private static func requireUnknownKindRefusalOnDefaultC() throws {
        try require(!Thread.isMainThread, "unknown-kind check did not run on utility worker")
        let runtime = try VortxNativeRuntime(
            abi: VortxCABI(), ownerID: "subtitle-reference-recovery", ownerName: "Unknown kind refusal"
        )
        defer { _ = runtime.close() }
        let raw = try runtime.resolve(#"{"kind":"subtitle_reference_future"}"#)
        let object = try JSONSerialization.jsonObject(with: Data(raw.utf8))
        guard let reply = object as? [String: Any],
              reply["kind"] as? String == "error",
              reply["result"] == nil else {
            throw Failure.check("unknown native kind was not a distinct error refusal")
        }
    }

    private static func requirePositiveDefaultC() throws {
        try require(!Thread.isMainThread, "positive alignment did not run on utility worker")
        // This is the acceptance under test. Do not supply a resolver: the adapter's default is
        // resolveWithEphemeralRuntime -> VortxNativeRuntime -> VortxCABI -> fresh dylib.
        guard let result = SubtitleReferenceNativeQuery.align(
            externalSRT: externalSRT, reference: reference, originalJob: job
        ) else {
            throw Failure.check("default-C alignment returned nil")
        }
        try require(result.originalJob == job, "original UUID was not preserved")
        try require(result.offsetMs == 2_750, "offset golden mismatch")
        try require(result.driftPpm == 0, "drift golden mismatch")
        try require(result.confidence == 1_000, "confidence golden mismatch")
        // Byte equality against a separately authored complete SRT checks every output cue's
        // index, text, start and end time. This fixture's cues all lie inside the scoring window.
        try require(result.srt == expectedRetimedSRT, "full retimed cue/text/time golden mismatch")
        try require(result.cues.count == 24, "owned complete cue count mismatch")
        for (index, cue) in result.cues.enumerated() {
            try require(cue.startMs == reference[index].startMs,
                        "owned cue start mismatch at \(index)")
            try require(cue.endMs == reference[index].startMs + 1_200,
                        "owned cue end mismatch at \(index)")
            try require(cue.text == "外部 \(index)\nquoted \\\"words\\\" & second line",
                        "owned cue text mismatch at \(index)")
        }
    }

    private static func requireCompleteOutsideWindowOutput() throws {
        // Only the first 900 seconds determine the correction. All four additional dialogue
        // cues are an hour into the file and overlap. Keep their input duration within
        // the native query's two-minute budget; neither query nor presentation may drop them.
        let tail = """
        25
        01:00:00,000 --> 01:01:50,000
        <b>Long tail 0</b>
        第二行 & literal text

        26
        01:00:00,010 --> 01:01:51,000
        <i>Long tail 1</i>

        27
        01:00:00,020 --> 01:01:52,000
        Long tail 2

        28
        01:00:00,030 --> 01:01:53,000
        Long tail 3
        """ + "\n\n"
        let expectedTail = """
        25
        01:00:02,750 --> 01:01:52,750
        <b>Long tail 0</b>
        第二行 & literal text

        26
        01:00:02,760 --> 01:01:53,750
        <i>Long tail 1</i>

        27
        01:00:02,770 --> 01:01:54,750
        Long tail 2

        28
        01:00:02,780 --> 01:01:55,750
        Long tail 3
        """ + "\n\n"
        guard let result = SubtitleReferenceNativeQuery.align(
            externalSRT: externalSRT + Data(tail.utf8), reference: reference, originalJob: job
        ) else { throw Failure.check("outside-window full-file alignment returned nil") }
        try require(result.offsetMs == 2_750 && result.driftPpm == 0 && result.confidence == 1_000,
                    "outside-window cues changed scoring-window correction")
        try require(result.srt == expectedRetimedSRT + Data(expectedTail.utf8),
                    "outside-window full-file golden mismatch")
        try require(result.cues.count == 28, "outside-window complete owned cue count mismatch")
        let expectedTexts = ["<b>Long tail 0</b>\n第二行 & literal text",
                             "<i>Long tail 1</i>", "Long tail 2", "Long tail 3"]
        for index in 0..<4 {
            let cue = result.cues[index + 24]
            try require(cue.startMs == 3_602_750 + UInt64(index * 10),
                        "outside-window owned start mismatch at \(index)")
            try require(cue.endMs == 3_712_750 + UInt64(index * 1_000),
                        "outside-window owned end mismatch at \(index)")
            try require(cue.text == expectedTexts[index],
                        "outside-window markup/multiline text mismatch at \(index)")
        }
    }

    private struct ContractCue {
        let start: UInt64
        let end: UInt64
        let text: String
    }

    /// Fixture writer only: independent expected fields below use the authored +2750 ms shift.
    /// The production adapter still crosses the genuine current C ABI with no resolver substitute.
    private static func fixtureSRT(_ cues: [ContractCue]) -> Data {
        func timestamp(_ value: UInt64) -> String {
            String(format: "%02llu:%02llu:%02llu,%03llu", value / 3_600_000,
                   value / 60_000 % 60, value / 1_000 % 60, value % 1_000)
        }
        return Data(cues.enumerated().map { index, cue in
            "\(index + 1)\n\(timestamp(cue.start)) --> \(timestamp(cue.end))\n\(cue.text)\n\n"
        }.joined().utf8)
    }

    private static func requireEqualStartWholeCueContractDefaultC() throws {
        let starts: [UInt64] = [
            10_000, 14_730, 22_190, 30_870, 33_510, 45_640, 61_930, 65_070,
            79_810, 84_260, 103_540, 112_990, 118_170, 134_380, 141_020, 158_690,
            167_430, 181_750, 200_810, 207_470, 225_990, 232_180, 251_630, 266_470
        ]
        var complete = starts.enumerated().map { index, start in
            ContractCue(start: start, end: start + 1_200, text: "authored \(index)")
        }
        complete[0] = ContractCue(start: 10_000, end: 200_000, text: "whole 190-second cue")
        complete.insert(ContractCue(start: 10_000, end: 12_000, text: "tie, shorter end"), at: 1)
        complete.insert(ContractCue(start: 10_000, end: 12_000, text: "same timing, separate text"), at: 2)
        let tiedReference = complete.map {
            SubtitleReferenceNativeQuery.Timing(startMs: $0.start + 2_750, endMs: $0.end + 2_750)
        }
        // These two cues lie outside the scoring window but must remain in complete output.
        complete.append(ContractCue(start: 3_600_000, end: 7_200_000, text: "outside-window whole hour"))
        complete.append(ContractCue(start: 3_600_000, end: 3_800_000, text: "outside-window tied shorter end"))
        guard let result = SubtitleReferenceNativeQuery.align(
            externalSRT: fixtureSRT(complete), reference: tiedReference, originalJob: job
        ) else { throw Failure.check("equal-start whole-cue default-C alignment returned nil") }
        try require(result.offsetMs == 2_750 && result.driftPpm == 0 && result.confidence == 1_000,
                    "equal-start complete evidence changed authored correction")
        try require(result.cues.count == complete.count, "equal-start complete output lost occurrences")
        for (index, original) in complete.enumerated() {
            let cue = result.cues[index]
            try require(cue.startMs == original.start + 2_750 && cue.endMs == original.end + 2_750
                        && cue.text == original.text, "equal-start output changed cue/order/duration at \(index)")
        }
        let expected = complete.map { ContractCue(start: $0.start + 2_750, end: $0.end + 2_750, text: $0.text) }
        try require(result.srt == fixtureSRT(expected), "equal-start full serialized output mismatch")
        let presentation = try SubtitleReferencePresentation.prepare(result)
        var active: [Int] = []
        presentation.lookup(mediaSeconds: 13, manualDelaySeconds: 0).presentation?.forEachCue { active.append($0.index) }
        try require(active == [0, 1, 2], "genuine equal-start output failed complete presentation")

        // Extra coincident external cues must remain in coverage. One reference occurrence can
        // match at most one external cue; 24/26 raw selected entries is 923, not 1000.
        guard let asymmetric = SubtitleReferenceNativeQuery.align(
            externalSRT: fixtureSRT(complete), reference: reference, originalJob: job
        ) else { throw Failure.check("asymmetric equal-start evidence returned nil") }
        try require(asymmetric.offsetMs == 2_750 && asymmetric.driftPpm == 0
                    && asymmetric.confidence == 923 && asymmetric.cues.count == complete.count,
                    "coincident cues inflated confidence or disappeared from complete output")

        var backwardReference = tiedReference
        backwardReference.swapAt(3, 4)
        try require(SubtitleReferenceNativeQuery.align(externalSRT: fixtureSRT(complete),
                    reference: backwardReference, originalJob: job) == nil,
                    "backward reference starts were accepted")
        var backwardExternal = complete
        backwardExternal.swapAt(3, 4)
        try require(SubtitleReferenceNativeQuery.align(externalSRT: fixtureSRT(backwardExternal),
                    reference: tiedReference, originalJob: job) == nil,
                    "backward external starts were silently repaired")

        // Raw eight-cue evidence across a long enough span still has only two distinct onsets.
        let repeated = (0..<8).map { index in
            let start: UInt64 = index < 4 ? 10_000 : 100_000
            return ContractCue(start: start, end: start + 1_000, text: "repeated \(index)")
        }
        let repeatedReference = repeated.map {
            SubtitleReferenceNativeQuery.Timing(startMs: $0.start + 2_750, endMs: $0.end + 2_750)
        }
        try require(SubtitleReferenceNativeQuery.align(externalSRT: fixtureSRT(repeated),
                    reference: repeatedReference, originalJob: job) == nil,
                    "repeated onsets manufactured independent temporal evidence")
    }

    static func main() async {
        do {
            // One real detached utility task owns every check; each check also verifies that it
            // is off the main thread.
            let worker: Task<Void, Error> = Task.detached(priority: .utility) {
                try Self.requireLocalRefusals()
                try Self.requirePositiveDefaultC()
                try Self.requireCompleteOutsideWindowOutput()
                try Self.requireEqualStartWholeCueContractDefaultC()
                try Self.requireUnknownKindRefusalOnDefaultC()
                try SubtitleReferencePresentationTests.run()
            }
            try await worker.value
            print("PASS genuine default-C subtitle reference alignment; original 24-cue and outside-window 28-cue full-file goldens; drift=0")
        } catch {
            FileHandle.standardError.write(Data("FAIL subtitle reference default-C acceptance: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }
}
