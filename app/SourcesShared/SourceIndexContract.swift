import Foundation

/// Pure torrent-only source-index contract shared by the production client and standalone tests.
enum SourceIndexContract {
    static let maxSafeSizeBytes: Int64 = 9_007_199_254_740_991
    static let maxSeeders = 1_000_000
    /// A legitimate response is at most 100 rows x roughly 300 bytes, or about 30 KiB. 64 KiB is more than
    /// twice that bound while remaining small enough to contain a regressed or hostile first-party response.
    /// Re-derive this value if the accepted row shape or row cap changes.
    static let maxResponseBodyBytes = 64 * 1024
    static let maxServedSources = 100
    static let minimumCorroboration = 2
    static let postResponseDrainBytes = 512

    static func parsedContentLength(_ raw: String) -> Int? {
        guard !raw.isEmpty,
              raw.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = Int(raw) else { return nil }
        return value
    }

    /// Incremental response collector shared by the live URLSession stream and deterministic tests. A declared
    /// length is only a fast rejection hint; the actual bytes remain capped when the header is absent or lies.
    struct BoundedBodyAccumulator {
        private(set) var data: Data

        init?(contentLength: String?) {
            if let contentLength {
                guard let declared = SourceIndexContract.parsedContentLength(contentLength),
                      declared <= maxResponseBodyBytes else { return nil }
                data = Data(capacity: declared)
            } else {
                data = Data()
            }
        }

        mutating func append(_ byte: UInt8) -> Bool {
            guard data.count < SourceIndexContract.maxResponseBodyBytes else { return false }
            data.append(byte)
            return true
        }

        mutating func append(_ chunk: Data) -> Bool {
            guard chunk.count <= SourceIndexContract.maxResponseBodyBytes - data.count else { return false }
            data.append(chunk)
            return true
        }
    }

    /// Pure harness for exact-cap, cap-plus-one, absent, malformed, and dishonest Content-Length cases.
    static func boundedResponseData(
        chunks: [Data],
        contentLength: String?,
        didRead: () -> Void = {},
        cancel: () -> Void = {}
    ) -> Data? {
        guard var accumulator = BoundedBodyAccumulator(contentLength: contentLength) else {
            cancel()
            return nil
        }
        for chunk in chunks {
            didRead()
            guard accumulator.append(chunk) else {
                cancel()
                return nil
            }
        }
        return accumulator.data
    }

    /// Pure model of the POST response sink. It stores no bytes, reads fewer than the fixed drain bound, and
    /// always cancels. Reaching the bound is a failure because the ignored response is larger than expected.
    static func discardResponseBody(
        bytes: [UInt8],
        contentLength: String?,
        didRead: () -> Void = {},
        cancel: () -> Void = {}
    ) -> Bool {
        if let contentLength {
            guard let declared = parsedContentLength(contentLength),
                  declared < postResponseDrainBytes else {
                cancel()
                return false
            }
        }
        var read = 0
        for _ in bytes {
            guard read < postResponseDrainBytes else {
                cancel()
                return false
            }
            read += 1
            didRead()
        }
        cancel()
        return read < postResponseDrainBytes
    }

    /// The exact title key accepted by the source-index worker. It is a public catalog identity, never a user
    /// or account identifier.
    static func canonicalContentID(_ raw: String) -> String? {
        guard raw.range(
            of: #"^(tt[0-9]{6,10}|tmdb:[0-9]{1,10})(:[0-9]{1,4}:[0-9]{1,4})?$"#,
            options: .regularExpression
        ) != nil else { return nil }
        return raw
    }

    /// Normalize a client-side torrent identity. Mixed-case 40-hex input is accepted and returned lowercase;
    /// every non-hex or wrong-length identifier is rejected.
    static func normalizeInfoHash(_ raw: String?) -> String? {
        guard let normalized = raw?.lowercased(), normalized.utf8.count == 40,
              normalized.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (97...102).contains(byte)
              }) else { return nil }
        return normalized
    }

    /// Validate a stored/served identity without repairing it. Worker responses must already contain the
    /// canonical lowercase form, so uppercase and otherwise noncanonical rows fail closed.
    static func canonicalStoredInfoHash(_ raw: String?) -> String? {
        guard let raw, normalizeInfoHash(raw) == raw else { return nil }
        return raw
    }

    /// Match the worker's closed quality vocabulary. Known aliases normalize; arbitrary contributor text is
    /// replaced with Other before it can cross the network boundary.
    static func normalizeQuality(_ raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "4k", "2160p", "uhd": return "4K"
        case "1440p": return "1440p"
        case "1080p": return "1080p"
        case "720p": return "720p"
        case "576p": return "576p"
        case "540p": return "540p"
        case "480p", "sd": return "480p"
        default: return "Other"
        }
    }

    /// Poll a fail-soft producer until it yields at least one eligible item or the bounded attempt count ends.
    /// The injected sleeper keeps the decision surface deterministic in standalone tests.
    @MainActor
    static func firstNonEmpty<Element>(
        attempts: Int,
        pollIntervalNanoseconds: UInt64,
        produce: @MainActor () async -> [Element],
        sleep: (UInt64) async -> Void = { nanoseconds in
            try? await Task<Never, Never>.sleep(nanoseconds: nanoseconds)
        }
    ) async -> [Element] {
        let boundedAttempts = max(1, attempts)
        for attempt in 0..<boundedAttempts {
            let values = await produce()
            if !values.isEmpty { return values }
            if attempt < boundedAttempts - 1 { await sleep(pollIntervalNanoseconds) }
        }
        return []
    }
}
