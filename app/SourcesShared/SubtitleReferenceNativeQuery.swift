import Foundation

/// Transport-only adapter for the additive pure native query. It grants no player/account/track
/// authority. Call from the bounded subtitle worker, never from a foreground playback tick.
enum SubtitleReferenceNativeQuery {
    /// Estimate from the COMPLETE external 0...900-second scoring window. The
    /// embedded reference's 0...1080-second envelope retains the original prefix
    /// denominator and covers the native offset/drift search margin; it is not
    /// a replacement scoring window or a crop of the external sidecar.
    static let scoringWindowStartMs: UInt64 = 0
    static let scoringWindowEndMs: UInt64 = 900_000
    static let referenceWindowEndMs: UInt64 = 1_080_000

    struct Timing: Codable, Sendable, Equatable {
        let startMs: UInt64
        let endMs: UInt64
    }

    struct RetimedCue: Decodable, Sendable, Equatable {
        let startMs: UInt64
        let endMs: UInt64
        let text: String
    }

    struct RetimedFile: Sendable {
        let originalJob: UUID
        let srt: Data
        /// The exact validated complete output. Render preparation must consume these owned values,
        /// not round-trip through the ordinary permissive parser (which drops unsupported cues).
        let cues: [RetimedCue]
        let offsetMs: Int64
        let driftPpm: Int32
        let confidence: UInt16
    }

    private struct External: Encodable, Sendable {
        let kind = "srt"
        let text: String
    }
    private struct Payload: Encodable, Sendable {
        let version = 1
        let originalJob: String
        let external: External
        let referenceCues: [Timing]
        let windowStartMs = SubtitleReferenceNativeQuery.scoringWindowStartMs
        let windowEndMs = SubtitleReferenceNativeQuery.scoringWindowEndMs
        let allowDrift = true
    }
    private struct Query: Encodable, Sendable {
        let kind = "subtitle_reference"
        let payload: String
    }
    private struct Correction: Decodable, Sendable {
        let offsetMs: Int64
        let driftPpm: Int32
        let confidence: UInt16
        let matched: Int
        let total: Int
    }
    private struct Result: Decodable, Sendable {
        let version: Int
        let status: String
        let originalJob: String
        let correction: Correction
        let medianResidualMs: UInt64
        let workUsed: UInt32
        let cues: [RetimedCue]
    }
    private struct Reply: Decodable, Sendable {
        let kind: String
        let result: Result
    }

    /// A concrete existing-C/JSON-ABI implementation; an older engine's unknown-kind error fails
    /// decoding and returns nil. Never emulate drift with repeated sub-delay nudges or claim an old
    /// native asset supports this query just because its seven legacy C symbols link successfully.
    nonisolated static func align(
        externalSRT: Data,
        reference: [Timing],
        originalJob: UUID,
        resolve: @Sendable (String) throws -> String = resolveWithEphemeralRuntime
    ) -> RetimedFile? {
        guard !externalSRT.isEmpty, externalSRT.count <= 1024 * 1024,
              let text = String(data: externalSRT, encoding: .utf8),
              (8...1024).contains(reference.count) else { return nil }
        // Equal-start dialogue and long whole cues are real evidence. Keep every occurrence;
        // the native estimator separately requires independent temporal evidence.
        var previousReferenceStart: UInt64?
        for cue in reference {
            guard cue.startMs < cue.endMs, cue.endMs <= referenceWindowEndMs,
                  previousReferenceStart.map({ cue.startMs >= $0 }) ?? true else { return nil }
            previousReferenceStart = cue.startMs
        }
        let encoder = JSONEncoder()
        guard let payload = try? encoder.encode(Payload(
            originalJob: originalJob.uuidString, external: External(text: text), referenceCues: reference
        )), payload.count <= 8 * 1024 * 1024,
              let payloadText = String(data: payload, encoding: .utf8),
              let query = try? encoder.encode(Query(payload: payloadText)),
              query.count <= 16 * 1024 * 1024,
              let queryText = String(data: query, encoding: .utf8),
              let raw = try? resolve(queryText), raw.utf8.count <= 16 * 1024 * 1024,
              let reply = try? JSONDecoder().decode(Reply.self, from: Data(raw.utf8)),
              reply.kind == "subtitle_reference", reply.result.version == 1,
              reply.result.status == "aligned", reply.result.originalJob == originalJob.uuidString else {
            return nil
        }
        let correction = reply.result.correction
        guard correction.offsetMs >= -120_000, correction.offsetMs <= 120_000,
              correction.driftPpm >= -50_000, correction.driftPpm <= 50_000,
              (700...1000).contains(correction.confidence), correction.matched >= 8,
              (8...1024).contains(correction.total), correction.total >= correction.matched,
              correction.confidence == UInt16(correction.matched * 1000 / correction.total),
              reply.result.medianResidualMs <= 150,
              (1...40_000_000).contains(reply.result.workUsed),
              (1...12_000).contains(reply.result.cues.count),
              let srt = serialize(reply.result.cues) else { return nil }
        return RetimedFile(originalJob: originalJob, srt: srt, cues: reply.result.cues, offsetMs: correction.offsetMs,
            driftPpm: correction.driftPpm, confidence: correction.confidence)
    }

    /// Empty in-memory runtime only; no hydration, disk checkpoint, migration, account binding or
    /// saved profile is accessed. The resolve entry is pure and the handle closes lexically.
    nonisolated private static func resolveWithEphemeralRuntime(_ query: String) throws -> String {
        let runtime = try VortxNativeRuntime(abi: VortxCABI(), ownerID: "subtitle-reference-query", ownerName: "Subtitle query")
        defer { _ = runtime.close() }
        return try runtime.resolve(query)
    }

    nonisolated private static func serialize(_ cues: [RetimedCue]) -> Data? {
        var result = Data()
        var previous: UInt64?
        for (index, cue) in cues.enumerated() {
            guard cue.endMs <= 91_000_000, cue.startMs < cue.endMs,
                  previous.map({ cue.startMs >= $0 }) ?? true,
                  !cue.text.isEmpty, cue.text.utf8.count <= 16_384, !cue.text.contains("\0") else {
                return nil
            }
            let block = "\(index + 1)\n\(timestamp(cue.startMs)) --> \(timestamp(cue.endMs))\n\(cue.text)\n\n"
            let bytes = Data(block.utf8)
            guard bytes.count <= 8 * 1024 * 1024 - result.count else { return nil }
            result.append(bytes)
            previous = cue.startMs
        }
        return result
    }

    nonisolated private static func timestamp(_ milliseconds: UInt64) -> String {
        String(format: "%02llu:%02llu:%02llu,%03llu", milliseconds / 3_600_000,
               milliseconds / 60_000 % 60, milliseconds / 1000 % 60, milliseconds % 1000)
    }
}
