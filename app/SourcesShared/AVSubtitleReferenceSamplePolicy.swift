import Foundation

/// Pure value boundary for AVFoundation's encoded text samples. This proves text presence and
/// whole occurrence timing; it grants no player, selected-track or account authority.
enum AVSubtitleReferenceSamplePolicy {
    static let tx3g: UInt32 = 0x7478_3367
    static let maximumSampleBytes = 65_536
    static let maximumCopiedBytes = 4 * 1024 * 1024
    static let maximumSamples = 50_000
    static let maximumTimings = 1_024

    struct Sample: Sendable {
        let count: Int
        let subtype: UInt32
        let presentationSeconds: Double
        let durationSeconds: Double
        let numericEpochZero: Bool
        let bytes: Data
    }

    struct Timing: Sendable, Equatable {
        let startMs: UInt64
        let endMs: UInt64
    }

    enum Failure: Error, Sendable, Equatable {
        case unsupportedFormat, malformedSample, invalidTiming, nonMonotonic, budget
    }

    struct Window: Sendable {
        private(set) var timings: [Timing] = []
        private(set) var copiedBytes = 0
        private(set) var samples = 0
        private var previousStart: Double?

        mutating func consume(_ sample: Sample) throws {
            guard samples < maximumSamples,
                  sample.bytes.count <= maximumSampleBytes,
                  sample.bytes.count <= maximumCopiedBytes - copiedBytes else { throw Failure.budget }
            samples += 1
            copiedBytes += sample.bytes.count
            // AVAssetReader permits zero-sample markers. A marker contains no dialogue evidence.
            guard sample.count != 0 else { return }
            guard sample.count == 1 else { throw Failure.malformedSample }
            guard sample.subtype == tx3g else { throw Failure.unsupportedFormat }
            // A defined empty clear has no dialogue timing. In particular its harmless zero
            // duration at the end of a track must not invalidate a complete reference prefix.
            guard try tx3gContainsText(sample.bytes) else { return }
            let start = sample.presentationSeconds
            let end = start + sample.durationSeconds
            guard sample.numericEpochZero, start.isFinite, end.isFinite,
                  sample.durationSeconds.isFinite, sample.durationSeconds > 0, start >= 0 else {
                throw Failure.invalidTiming
            }
            guard previousStart.map({ start >= $0 }) ?? true else { throw Failure.nonMonotonic }
            previousStart = start
            // Preserve WHOLE occurrences. The reader may return a boundary-intersecting sample;
            // cropping it at 1080 would invent evidence. Out-of-envelope and defined empty text
            // remain non-evidence, while every in-envelope occurrence (including ties) is kept.
            guard end <= 1_080 else { return }
            guard timings.count < maximumTimings else { throw Failure.budget }
            let startMs = (start * 1_000).rounded()
            let endMs = (end * 1_000).rounded()
            guard startMs >= 0, endMs <= 1_080_000, startMs < endMs else {
                throw Failure.invalidTiming
            }
            timings.append(.init(startMs: UInt64(startMs), endMs: UInt64(endMs)))
        }
    }

    /// ISO/IEC 14496-17 timed text: a two-byte BE text length followed by the text and optional
    /// sample modifier boxes. The initial adapter supports UTF-8 plus bounded `styl`/`tbox` boxes;
    /// UTF-16, karaoke, hyperlinks and other representations remain honestly unavailable.
    static func tx3gContainsText(_ bytes: Data) throws -> Bool {
        guard bytes.count >= 2, bytes.count <= maximumSampleBytes else { throw Failure.malformedSample }
        let input = [UInt8](bytes)
        let length = Int(input[0]) << 8 | Int(input[1])
        guard length <= input.count - 2,
              let text = String(bytes: input[2..<(2 + length)], encoding: .utf8),
              !text.contains("\0") else { throw Failure.malformedSample }
        var cursor = 2 + length
        while cursor < input.count {
            guard input.count - cursor >= 8 else { throw Failure.malformedSample }
            let size = Int(input[cursor]) << 24 | Int(input[cursor + 1]) << 16
                | Int(input[cursor + 2]) << 8 | Int(input[cursor + 3])
            let kind = UInt32(input[cursor + 4]) << 24 | UInt32(input[cursor + 5]) << 16
                | UInt32(input[cursor + 6]) << 8 | UInt32(input[cursor + 7])
            guard size >= 8, size <= input.count - cursor else { throw Failure.malformedSample }
            switch kind {
            case 0x7374_796C: // styl: uint16 record count, then exactly 12 bytes per style record.
                guard size >= 10 else { throw Failure.malformedSample }
                let records = Int(input[cursor + 8]) << 8 | Int(input[cursor + 9])
                guard records <= (maximumSampleBytes - 10) / 12,
                      size == 10 + records * 12 else { throw Failure.malformedSample }
            case 0x7462_6F78: // tbox: four int16 rectangle coordinates.
                guard size == 16 else { throw Failure.malformedSample }
            default: throw Failure.unsupportedFormat
            }
            cursor += size
        }
        let presence = text.hasPrefix("\u{feff}") ? String(text.dropFirst()) : text
        return !presence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
