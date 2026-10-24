import Foundation

// Policy-only collaborators. AVCodecID is deliberately a scalar alias and these
// values are distinct inert constants; this is NOT genuine Libav enum-ABI proof.
private typealias AVCodecID = Int32
private let AV_CODEC_ID_MOV_TEXT: AVCodecID = 0x4D4F5654
private let policyOtherCodec: AVCodecID = 0x4D4F5655

private enum SubtitleEmbeddedExtractor {
    enum TimingWindowFailure: Error {
        case invalidTextPayload
    }

// @source:timingPacketHasOutput
// @source:timingPacketIsMovTextClear
}

private enum SubtitleTimingPolicyTestFailure: Error {
    case failed(String)
}

@main
private enum SubtitleTimingPolicyTests {
    private static func require(_ condition: Bool, _ name: String) throws {
        guard condition else { throw SubtitleTimingPolicyTestFailure.failed(name) }
    }

    private static func output(
        bytesConsumed: Int32,
        packetSize: Int32,
        gotSubtitle: Int32,
        rectangleCount: UInt32
    ) throws -> Bool {
        try SubtitleEmbeddedExtractor.timingPacketHasOutput(
            bytesConsumed: bytesConsumed,
            packetSize: packetSize,
            gotSubtitle: gotSubtitle,
            rectangleCount: rectangleCount)
    }

    private static func requireInvalidOutput(
        bytesConsumed: Int32,
        packetSize: Int32,
        gotSubtitle: Int32,
        rectangleCount: UInt32,
        _ name: String
    ) throws {
        do {
            _ = try output(
                bytesConsumed: bytesConsumed,
                packetSize: packetSize,
                gotSubtitle: gotSubtitle,
                rectangleCount: rectangleCount)
            throw SubtitleTimingPolicyTestFailure.failed(name + ": invalid receipt was accepted")
        } catch let failure as SubtitleTimingPolicyTestFailure {
            throw failure
        } catch let failure as SubtitleEmbeddedExtractor.TimingWindowFailure {
            guard case .invalidTextPayload = failure else {
                throw SubtitleTimingPolicyTestFailure.failed(name + ": wrong failure")
            }
        } catch {
            throw SubtitleTimingPolicyTestFailure.failed(name + ": unexpected failure")
        }
    }

    private static func requireOutput(
        bytesConsumed: Int32,
        packetSize: Int32,
        gotSubtitle: Int32,
        rectangleCount: UInt32,
        expected: Bool,
        _ name: String
    ) throws {
        let actual: Bool
        do {
            actual = try output(
                bytesConsumed: bytesConsumed,
                packetSize: packetSize,
                gotSubtitle: gotSubtitle,
                rectangleCount: rectangleCount)
        } catch {
            throw SubtitleTimingPolicyTestFailure.failed(name + ": unexpected throw")
        }
        try require(actual == expected, name)
    }

    private static func movText(
        codecID: AVCodecID,
        packetSize: Int32,
        bytes: [UInt8]?
    ) -> Bool {
        guard let bytes else {
            return SubtitleEmbeddedExtractor.timingPacketIsMovTextClear(
                codecID: codecID, packetSize: packetSize, data: nil)
        }
        return bytes.withUnsafeBufferPointer { buffer in
            SubtitleEmbeddedExtractor.timingPacketIsMovTextClear(
                codecID: codecID, packetSize: packetSize, data: buffer.baseAddress)
        }
    }

    private static func requireMovText(
        codecID: AVCodecID = AV_CODEC_ID_MOV_TEXT,
        packetSize: Int32,
        bytes: [UInt8]?,
        expected: Bool,
        _ name: String
    ) throws {
        try require(movText(codecID: codecID, packetSize: packetSize, bytes: bytes) == expected, name)
    }

    private static func run() throws {
        precondition(policyOtherCodec != AV_CODEC_ID_MOV_TEXT)

        // Every got/rectangle state must reject zero, partial and oversize receipts.
        for consumed in [Int32(0), Int32(1), Int32(5)] {
            for gotSubtitle in [Int32(0), Int32(1)] {
                for rectangleCount in [UInt32(0), UInt32(1)] {
                    try requireInvalidOutput(
                        bytesConsumed: consumed,
                        packetSize: 4,
                        gotSubtitle: gotSubtitle,
                        rectangleCount: rectangleCount,
                        "consumed=\(consumed), got=\(gotSubtitle), rects=\(rectangleCount)")
                }
            }
        }
        try requireInvalidOutput(
            bytesConsumed: -1, packetSize: 4, gotSubtitle: 1, rectangleCount: 1,
            "negative consumed bytes")
        try requireInvalidOutput(
            bytesConsumed: 4, packetSize: -1, gotSubtitle: 1, rectangleCount: 1,
            "negative packet size")

        try requireInvalidOutput(
            bytesConsumed: -1, packetSize: -1, gotSubtitle: 1, rectangleCount: 1,
            "negative packet and consumed bytes")

        // Full consumption is the only path allowed to inspect output state.
        try requireOutput(bytesConsumed: 4, packetSize: 4, gotSubtitle: 0, rectangleCount: 0,
                          expected: false, "fully consumed empty")
        try requireOutput(bytesConsumed: 4, packetSize: 4, gotSubtitle: 1, rectangleCount: 0,
                          expected: false, "fully consumed without rectangles")
        try requireOutput(bytesConsumed: 4, packetSize: 4, gotSubtitle: 0, rectangleCount: 2,
                          expected: false, "fully consumed without subtitle")
        try requireOutput(bytesConsumed: 4, packetSize: 4, gotSubtitle: 2, rectangleCount: 3,
                          expected: true, "fully consumed positive output")
        try requireOutput(bytesConsumed: 0, packetSize: 0, gotSubtitle: 0, rectangleCount: 0,
                          expected: false, "zero-sized fully consumed empty")
        try requireOutput(bytesConsumed: 0, packetSize: 0, gotSubtitle: 1, rectangleCount: 1,
                          expected: true, "zero-sized fully consumed positive")

        // MOV_TEXT's exactly-two-zero-byte clear marker is the sole predecoder clear.
        try requireMovText(packetSize: 2, bytes: [0, 0], expected: true, "MOV_TEXT size=2 zero marker")
        try requireMovText(codecID: policyOtherCodec, packetSize: 2, bytes: [0, 0], expected: false,
                           "wrong codec")
        try requireMovText(packetSize: 0, bytes: [0, 0], expected: false, "size=0")
        try requireMovText(packetSize: 1, bytes: [0, 0], expected: false, "size=1")
        try requireMovText(packetSize: 3, bytes: [0, 0, 0], expected: false, "size=3")
        try requireMovText(packetSize: -1, bytes: [0, 0], expected: false, "negative size")
        try requireMovText(packetSize: 2, bytes: [1, 0], expected: false, "first byte nonzero")
        try requireMovText(packetSize: 2, bytes: [0, 1], expected: false, "second byte nonzero")
        try requireMovText(packetSize: 2, bytes: [1, 1], expected: false, "both bytes nonzero")
        try requireMovText(packetSize: 2, bytes: nil, expected: false, "nil data")
        try requireMovText(packetSize: 5, bytes: [0, 0, 0, 0, 0], expected: false,
                           "larger zero-prefix guard")
    }

    static func main() throws {
        try run()
        print("PASS subtitle timing helpers: full-consumption and MOV_TEXT clear policy")
    }
}
