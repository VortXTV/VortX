import Foundation

/// Standalone pure-value coverage for AVSubtitleReferenceSamplePolicy.
///
/// This file intentionally does not import AVFoundation, AVPlayer, AVAssetReader, or any
/// application type beyond the policy afterimage compiled beside it. It is a source proposal;
/// it has not been compiled or run in this recovery packet.
@main
struct AVSubtitleReferenceSamplePolicyTests {
    private typealias Policy = AVSubtitleReferenceSamplePolicy

    static func main() throws {
        try testTx3gLengthAndSupportedTrailingBoxes()
        try testEmptyAndMarkerSamples()
        try testMalformedAndUnsupportedPayloads()
        try testSampleAndCumulativeBudgets()
        try testTimingValidationAndEnvelope()
        try testDuplicateTimingAndMaximumProof()
        print("AVSubtitleReferenceSamplePolicy pure cases passed")
    }

    private static func sample(
        count: Int = 1,
        subtype: UInt32 = Policy.tx3g,
        text: String = "dialogue",
        start: Double = 0,
        duration: Double = 1,
        numericEpochZero: Bool = true,
        bytes: Data? = nil
    ) -> Policy.Sample {
        .init(
            count: count,
            subtype: subtype,
            presentationSeconds: start,
            durationSeconds: duration,
            numericEpochZero: numericEpochZero,
            bytes: bytes ?? tx3g(text)
        )
    }

    private static func tx3g(_ text: String, trailingBoxes: [Data] = []) -> Data {
        let textBytes = Array(text.utf8)
        precondition(textBytes.count <= Int(UInt16.max))
        var bytes = Data([UInt8(textBytes.count >> 8), UInt8(textBytes.count & 0xff)])
        bytes.append(contentsOf: textBytes)
        for box in trailingBoxes {
            bytes.append(box)
        }
        return bytes
    }

    private static func box(kind: String, payload: [UInt8]) -> Data {
        precondition(kind.utf8.count == 4)
        let kindBytes = Array(kind.utf8)
        let size = UInt32(8 + payload.count)
        var bytes = Data([
            UInt8(size >> 24), UInt8((size >> 16) & 0xff),
            UInt8((size >> 8) & 0xff), UInt8(size & 0xff)
        ])
        bytes.append(contentsOf: kindBytes)
        bytes.append(contentsOf: payload)
        return bytes
    }

    private static func validStylBox() -> Data {
        // styl: uint16 record count (zero records is a bounded, well-formed box).
        box(kind: "styl", payload: [0, 0])
    }

    private static func validTboxBox() -> Data {
        // tbox: four int16 rectangle coordinates.
        box(kind: "tbox", payload: Array(repeating: 0, count: 8))
    }

    private static func marker(bytes: Data = Data()) -> Policy.Sample {
        .init(
            count: 0,
            subtype: Policy.tx3g,
            presentationSeconds: 0,
            durationSeconds: 0,
            numericEpochZero: false,
            bytes: bytes
        )
    }

    private static func expectFailure(
        _ expected: Policy.Failure,
        _ label: String,
        _ operation: () throws -> Void
    ) {
        do {
            try operation()
            preconditionFailure("expected \(expected) for \(label)")
        } catch let failure as Policy.Failure {
            precondition(failure == expected, "wrong failure \(failure) for \(label)")
        } catch {
            preconditionFailure("unexpected error \(error) for \(label)")
        }
    }

    private static func testTx3gLengthAndSupportedTrailingBoxes() throws {
        var window = Policy.Window()
        try window.consume(sample(text: "hi"))
        precondition(window.timings == [.init(startMs: 0, endMs: 1_000)])

        var styled = Policy.Window()
        try styled.consume(sample(text: "styled", bytes: tx3g(
            "styled",
            trailingBoxes: [validStylBox(), validTboxBox()]
        )))
        precondition(styled.timings.count == 1)
        precondition(styled.timings[0].startMs == 0 && styled.timings[0].endMs == 1_000)
    }

    private static func testEmptyAndMarkerSamples() throws {
        var window = Policy.Window()
        try window.consume(sample(text: "   \n", start: 1))
        precondition(window.samples == 1)
        precondition(window.timings.isEmpty)

        // A defined empty tx3g clear may carry zero duration and no numeric epoch; it is
        // non-evidence and must be skipped before dialogue timing validation.
        try window.consume(sample(duration: 0, numericEpochZero: false, bytes: Data([0, 0])))
        precondition(window.samples == 2)
        precondition(window.timings.isEmpty)

        // Whitespace-only text is also a valid empty clear, not malformed timing.
        try window.consume(sample(text: "   \n", duration: 0, numericEpochZero: false))
        precondition(window.samples == 3)
        precondition(window.timings.isEmpty)

        // A BOM-only payload has no visible text and is skipped; real text after its BOM remains
        // dialogue evidence and therefore must satisfy ordinary timing validation.
        try window.consume(sample(text: "\u{feff}", duration: 0, numericEpochZero: false))
        precondition(window.samples == 4)
        precondition(window.timings.isEmpty)
        try window.consume(sample(text: "\u{feff}dialogue", start: 2, duration: 1))
        precondition(window.timings.last == .init(startMs: 2_000, endMs: 3_000))

        // Marker bytes are not parsed as tx3g; they are explicitly non-dialogue evidence.
        try window.consume(marker(bytes: Data(repeating: 0xff, count: 64)))
        precondition(window.samples == 6)
        precondition(window.timings.count == 1)
    }

    private static func testMalformedAndUnsupportedPayloads() throws {
        expectFailure(.malformedSample, "truncated length") {
            var window = Policy.Window()
            try window.consume(sample(bytes: Data([0])))
        }

        expectFailure(.malformedSample, "empty tx3g payload") {
            var window = Policy.Window()
            try window.consume(sample(bytes: Data()))
        }

        // Declared length 2 but only one text byte remains.
        expectFailure(.malformedSample, "declared text truncation") {
            var window = Policy.Window()
            try window.consume(sample(bytes: Data([0, 2, 0x41])))
        }

        // Invalid UTF-8 in the declared one-byte text.
        expectFailure(.malformedSample, "invalid UTF8") {
            var window = Policy.Window()
            try window.consume(sample(bytes: Data([0, 1, 0xff])))
        }

        expectFailure(.unsupportedFormat, "unknown trailing box") {
            var window = Policy.Window()
            try window.consume(sample(bytes: tx3g(
                "x",
                trailingBoxes: [box(kind: "junk", payload: [])]
            )))
        }

        expectFailure(.unsupportedFormat, "unsupported sample subtype") {
            var window = Policy.Window()
            try window.consume(sample(subtype: 0x7776_7474)) // wvtt, not in this tx3g-only policy.
        }

        // A trailing box cannot be represented by a partial eight-byte header.
        expectFailure(.malformedSample, "truncated trailing box") {
            var window = Policy.Window()
            try window.consume(sample(bytes: Data([0, 1, 0x78, 0, 0, 0, 7])))
        }

        // A styl box with one record must declare exactly 22 bytes, not 10.
        expectFailure(.malformedSample, "malformed styl size") {
            var window = Policy.Window()
            try window.consume(sample(bytes: tx3g(
                "x",
                trailingBoxes: [box(kind: "styl", payload: [0, 1])]
            )))
        }

        expectFailure(.malformedSample, "multiple samples in one buffer") {
            var window = Policy.Window()
            try window.consume(sample(count: 2))
        }

        expectFailure(.malformedSample, "negative sample count") {
            var window = Policy.Window()
            try window.consume(sample(count: -1))
        }
    }

    private static func testSampleAndCumulativeBudgets() throws {
        let exactSample = Data(repeating: 0, count: Policy.maximumSampleBytes)
        var exactWindow = Policy.Window()
        try exactWindow.consume(marker(bytes: exactSample))
        precondition(exactWindow.copiedBytes == Policy.maximumSampleBytes)

        expectFailure(.budget, "single sample over 64 KiB") {
            var window = Policy.Window()
            try window.consume(marker(bytes: Data(repeating: 0, count: Policy.maximumSampleBytes + 1)))
        }

        var cumulative = Policy.Window()
        for _ in 0..<64 {
            try cumulative.consume(marker(bytes: exactSample))
        }
        precondition(cumulative.copiedBytes == Policy.maximumCopiedBytes)
        expectFailure(.budget, "cumulative bytes over 4 MiB") {
            try cumulative.consume(marker(bytes: Data([0])))
        }

        var sampleLimit = Policy.Window()
        for _ in 0..<Policy.maximumSamples {
            try sampleLimit.consume(marker())
        }
        precondition(sampleLimit.samples == Policy.maximumSamples)
        expectFailure(.budget, "sample occurrence limit") {
            try sampleLimit.consume(marker())
        }
    }

    private static func testTimingValidationAndEnvelope() throws {
        var epochZero = Policy.Window()
        try epochZero.consume(sample(start: 0, duration: 0.25))
        precondition(epochZero.timings == [.init(startMs: 0, endMs: 250)])

        let invalidCases: [(String, Policy.Sample)] = [
            ("non-numeric epoch", sample(numericEpochZero: false)),
            ("negative PTS", sample(start: -0.01)),
            ("zero duration", sample(duration: 0)),
            ("zero duration with nonzero epoch flag", sample(duration: 0, numericEpochZero: false)),
            ("negative duration", sample(duration: -1)),
            ("NaN PTS", sample(start: .nan)),
            ("infinite duration", sample(duration: .infinity))
        ]
        for (label, invalid) in invalidCases {
            expectFailure(.invalidTiming, label) {
                var window = Policy.Window()
                try window.consume(invalid)
            }
        }

        // Whole-cue policy: crossing 1080 seconds is non-evidence, not a cropped cue.
        var crossing = Policy.Window()
        try crossing.consume(sample(start: 1_079.5, duration: 1))
        precondition(crossing.timings.isEmpty)

        var afterEnvelope = Policy.Window()
        try afterEnvelope.consume(sample(start: 1_080.1, duration: 1))
        precondition(afterEnvelope.timings.isEmpty)

        var decreasing = Policy.Window()
        try decreasing.consume(sample(start: 2))
        expectFailure(.nonMonotonic, "decreasing presentation order") {
            try decreasing.consume(sample(start: 1))
        }
    }

    private static func testDuplicateTimingAndMaximumProof() throws {
        var duplicates = Policy.Window()
        try duplicates.consume(sample(start: 100, duration: 600))
        try duplicates.consume(sample(start: 100, duration: 600))
        precondition(duplicates.timings == [
            .init(startMs: 100_000, endMs: 700_000),
            .init(startMs: 100_000, endMs: 700_000)
        ])

        var maximum = Policy.Window()
        for index in 0..<Policy.maximumTimings {
            try maximum.consume(sample(start: Double(index) * 0.5, duration: 0.25))
        }
        precondition(maximum.timings.count == Policy.maximumTimings)
        precondition(maximum.timings.last == .init(startMs: 511_500, endMs: 511_750))

        // The 1025th valid cue fails the explicit budget rather than being truncated.
        expectFailure(.budget, "timing occurrence limit") {
            try maximum.consume(sample(start: 512, duration: 0.25))
        }
        precondition(maximum.timings.count == Policy.maximumTimings)
    }
}
