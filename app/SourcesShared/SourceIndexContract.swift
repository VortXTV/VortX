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
    /// A FLOOR-OF-FLOORS sanity bound on a served row. It is deliberately the lowest value any worker policy
    /// could use, NOT a statement of the worker's current policy.
    ///
    /// **The WORKER is the authority on corroboration and has already applied its own floor before sending.**
    /// The client's only job is to never be STRICTER than the worker: this constant previously sat at 2 and so
    /// re-filtered the response, discarding rows the worker had deliberately served. Whatever the worker's real
    /// threshold is (the reviewed design requires two LIVE, unexpired witnesses -- see `MIN_LIVE_WITNESSES` and
    /// the `HAVING >= 2` witness-identity contract), a client bound of 1 can never exceed it, so the client
    /// stops second-guessing policy while the real threshold stays backend-tunable with no app release.
    ///
    /// Kept rather than removed purely as defence against a malformed or ABSENT count: a row arriving with 0 or
    /// no corroboration is anomalous under every worker policy. **Raising this is a bug** -- to tighten real
    /// policy, change the worker (which is also where it is reviewable and where it can be tuned without a build).
    static let minimumServedCorroboration = 1
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
    ///
    /// IMDb ONLY, both platforms, movie / series / live (decision REQ-260721-33). This is the single gate that
    /// every pool read, pool write, cache token, publication token, and merge token passes through, so the rule
    /// is enforced here once rather than restated at each call site.
    ///
    /// WHY TMDB IS REFUSED AS A KEY: themoviedb reuses its numeric ids across the movie and tv namespaces, so
    /// `/movie/11` and `/tv/11` are two different titles, and the worker's `content_id` carries no entity type
    /// to tell them apart. Admitting `tmdb:11` therefore merges two unrelated titles into one pool bucket in
    /// BOTH directions. A TMDB id may still be used to RESOLVE an IMDb id upstream; it never becomes a key.
    static func canonicalContentID(_ raw: String) -> String? {
        guard raw.range(
            of: #"^tt[0-9]{6,10}(:[0-9]{1,4}:[0-9]{1,4})?$"#,
            options: .regularExpression
        ) != nil else { return nil }
        return raw
    }

    /// The TITLE portion of a possibly episode-scoped id: "tt0903747:1:1" -> "tt0903747", "tmdb:1399:2:3" ->
    /// "tmdb:1399", "tt0903747" -> itself. nil when the value carries no canonical title id.
    ///
    /// This is a REDUCER, not a key gate: it deliberately still accepts the tmdb namespace, because comparing
    /// two ids for "same title" (the resume fence) and resolving an IMDb id from a TMDB-keyed page both need
    /// the head of a tmdb value. Nothing here makes a value usable as a pool key; `canonicalContentID` is the
    /// only gate that does, and it is IMDb-only.
    ///
    /// A meta's `behaviorHints.defaultVideoId` is often the EPISODE id on series (see CommunityTrickplay.ttPrefix),
    /// and every series call site passes that value in as the show id. A caller that then appends its own `:S:E`
    /// MUST reduce first, or it composes "tt...:1:1:3:5", which `canonicalContentID` rejects -- silently removing
    /// the whole title from the pool in BOTH directions (no contribute, no serve).
    static func canonicalTitleID(_ raw: String?) -> String? {
        guard let raw,
              let head = raw.range(of: #"^(tt[0-9]{6,10}|tmdb:[0-9]{1,10})"#, options: .regularExpression)
        else { return nil }
        let tail = String(raw[head.upperBound...])
        // Anything after the title must be exactly an episode suffix; an arbitrary trailing tail is not an id.
        guard tail.isEmpty ||
              tail.range(of: #"^:[0-9]{1,4}:[0-9]{1,4}$"#, options: .regularExpression) != nil else { return nil }
        return String(raw[head])
    }

    /// Recover a torrent infohash from a `sources` entry, accepting ONLY the exact documented `dht:<40hex>` form.
    ///
    /// SECURITY (load-bearing, do NOT relax to a substring scan): `sources` also carries full `tracker:` URLs
    /// (see DebridResolver.swift, `sources.filter { $0.hasPrefix("tracker:") }`), and PRIVATE tracker URLs
    /// commonly embed a 40-hex PASSKEY. A generic "any isolated 40-hex run" scan therefore misclassifies a
    /// user's private tracker credential as an infohash and uploads it into the shared pool. Whole-string
    /// exact-schema matching is the only safe shape here. Anything not exactly `dht:<40hex>` is refused.
    static func infoHashFromSourceEntry(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count == 44, s.lowercased().hasPrefix("dht:") else { return nil }
        return normalizeInfoHash(String(s.dropFirst(4)))
    }

    // REMOVED DELIBERATELY: `infoHashFromBingeGroup`. Do not reintroduce it without real captured evidence.
    //
    // It accepted ANY whole 40-hex pipe component of `behaviorHints.bingeGroup`, which is unconstrained
    // add-on-authored text. "provider|user|<40-hex-token>" was therefore admitted, so a hostile or merely
    // sloppy add-on could get a CREDENTIAL-SHAPED value uploaded into the shared pool, and (before the
    // precedence fix in SourceIndexClient.descriptor) could even override a real DHT hash with it.
    //
    // The documented rescue would have been a FULLY ANCHORED provider schema at a FIXED position. The repo
    // does not support one: the only trace of a hash-bearing bingeGroup anywhere is a single prose example
    // in a comment ("comet|torbox|<40hex>"), with no captured sample, no add-on spec, and no worker contract.
    // Meanwhile the field is demonstrably free-form in this very codebase (MediaServerSource writes
    // "vortx-ms-<uuid>"). An anchored pattern invented from one sentence is a guess, and a guess here admits
    // attacker-chosen bytes into a public pool. Losing one recovery path is strictly the cheaper loss: a
    // debrid row that declares its public hash at all still declares it as `dht:<40hex>` in `sources`, which
    // `infoHashFromSourceEntry` accepts.

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

    // MARK: - Provider tags (debrid cached-fact, closed enum)

    /// The closed set of debrid provider tags a contribution may carry, matching the worker's PROVIDER_BITS.
    /// A tag is a FACT about the media ("this provider had the source cached"), never a user identity.
    static let providerTags: Set<String> = ["rd", "tb", "pm", "ad"]

    /// Validate a provider tag against the closed enum. Anything else (nil, empty, unknown, an account id,
    /// arbitrary text) is nil, so a contribution simply carries no provider fact rather than a rejected row.
    static func normalizeProviderTag(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return providerTags.contains(s) ? s : nil
    }

    // MARK: - Non-torrent pooled id (client-side credential strip)

    /// Upper bound on a pooled http/usenet reference, mirroring the worker's MAX_LINK_LEN.
    static let maxPooledLinkLen = 2048
    private static let maxDecodeRounds = 3
    private static let maxBlobDepth = 2

    /// Query field names that can directly carry a credential, compared after bounded percent-decoding and
    /// removal of punctuation (so apiKey, api_key, API-KEY, and plural apiKeys all converge). Mirrors the
    /// worker's CREDENTIAL_FIELD_NAMES set exactly.
    private static let credentialFieldNames: Set<String> = [
        "apikey", "apikeys", "rdapikey", "debridapikey", "token", "tokens", "accesstoken", "refreshtoken",
        "password", "passwd", "passkey", "apipass", "secret", "clientsecret", "auth", "authorization",
        "credential", "credentials", "key", "keys", "config", "r",
    ]

    /// Credential/configuration material nested inside an otherwise innocuous value. Word-boundary anchored so
    /// ordinary words such as "monkey" or "tokenized" are not treated as credentials. Mirrors the worker's
    /// SENSITIVE_MATERIAL_RE.
    private static let sensitiveMaterialPattern =
        #"(?:^|[^a-z0-9])(?:api[ ._-]*keys?|access[ ._-]*tokens?|refresh[ ._-]*tokens?|password|passwd|passkey|api[ ._-]*pass|secret|authorization|credentials?|debrid[ ._-]*(?:api[ ._-]*)?key|config)(?:$|[^a-z0-9])"#
    private static let percentEscapePattern = #"%[0-9a-f]{2}"#

    private static func matchesRegex(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Original value plus at most three percent-decoded forms. A malformed encoding (or one still bearing an
    /// escape after the decode rounds) fails closed to nil, matching the worker's `decodedForms`.
    private static func decodedForms(_ input: String) -> [String]? {
        guard input.utf8.count <= maxPooledLinkLen else { return nil }
        var forms = [input]
        var current = input
        var round = 0
        while round < maxDecodeRounds, matchesRegex(current, percentEscapePattern) {
            guard let next = current.removingPercentEncoding else { return nil }
            if next.utf8.count > maxPooledLinkLen { return nil }
            if next == current { break }
            forms.append(next)
            current = next
            round += 1
        }
        if matchesRegex(current, percentEscapePattern) { return nil }
        return forms
    }

    private static func normalizedFieldName(_ input: String) -> String? {
        guard let last = decodedForms(input)?.last else { return nil }
        return last.lowercased().replacingOccurrences(
            of: "[^a-z0-9]", with: "", options: .regularExpression
        )
    }

    /// Decode one bounded base64 / base64url candidate as UTF-8, or nil when it is ordinary path material.
    private static func decodeBase64Text(_ input: String) -> String? {
        guard input.count >= 4, input.utf8.count <= maxPooledLinkLen,
              input.range(of: #"^[A-Za-z0-9+/_-]+={0,2}$"#, options: .regularExpression) != nil,
              input.count % 4 != 1 else { return nil }
        var b64 = input.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let pad = (4 - b64.count % 4) % 4
        b64 += String(repeating: "=", count: pad)
        guard let data = Data(base64Encoded: b64), let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    private static func base64Candidates(_ text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: #"[A-Za-z0-9+/_-]{4,}={0,2}"#) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    /// Detect credential/config material in plain text, percent-encoded text, JSON, base64, or base64url. Any
    /// object/array encoded inside a shared reference is treated as a private configuration blob and rejected.
    /// Length, decode-round, recursion-depth, and candidate-count bounded; never throws. Mirrors the worker's
    /// `componentCarriesPrivateMaterial`.
    static func componentCarriesPrivateMaterial(_ input: String, depth: Int = 0) -> Bool {
        guard let forms = decodedForms(input) else { return true }
        for form in forms {
            let trimmed = form.trimmingCharacters(in: .whitespacesAndNewlines)
            if matchesRegex(trimmed, sensitiveMaterialPattern) { return true }
            if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") { return true }
            if depth >= maxBlobDepth { continue }
            for candidate in base64Candidates(trimmed).prefix(64) {
                if let decoded = decodeBase64Text(candidate),
                   componentCarriesPrivateMaterial(decoded, depth: depth + 1) { return true }
            }
        }
        return false
    }

    /// One strict non-torrent normalizer shared by contribution filtering and served-row reconstruction, a
    /// faithful port of the worker's `normalizePooledNonTorrentId`. It is the CLIENT-SIDE credential strip:
    /// nothing sensitive even leaves the device on an http/usenet contribution (the worker re-screens too).
    /// Existing 64-hex digests and bounded opaque usenet ids remain valid for contract compatibility;
    /// resolvable references must be public http(s) URLs without userinfo, fragment, credential query keys, or
    /// private material in any decoded path/query component. Returns nil for anything else.
    static func normalizePooledNonTorrentID(kind: String, raw: String) -> String? {
        guard kind == "http" || kind == "usenet", !raw.isEmpty, raw.utf8.count <= maxPooledLinkLen else { return nil }
        if raw.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil { return raw }
        if kind == "usenet",
           !matchesRegex(raw, #"^https?:"#),
           raw.range(of: #"^[A-Za-z0-9:._@-]{1,128}$"#, options: .regularExpression) != nil { return raw }
        guard let comps = URLComponents(string: raw),
              let scheme = comps.scheme?.lowercased(), scheme == "http" || scheme == "https",
              comps.host?.isEmpty == false,
              comps.user == nil, comps.password == nil, comps.fragment == nil else { return nil }
        for segment in comps.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: true) {
            if componentCarriesPrivateMaterial(String(segment)) { return nil }
        }
        if let rawQuery = comps.percentEncodedQuery {
            for part in rawQuery.split(separator: "&", omittingEmptySubsequences: true) {
                let piece = String(part)
                let eq = piece.firstIndex(of: "=")
                let key = eq.map { String(piece[..<$0]) } ?? piece
                let value = eq.map { String(piece[piece.index(after: $0)...]) } ?? ""
                guard let normalized = normalizedFieldName(key), !credentialFieldNames.contains(normalized) else { return nil }
                if !value.isEmpty, componentCarriesPrivateMaterial(value) { return nil }
            }
        }
        for item in comps.queryItems ?? [] {
            guard let normalized = normalizedFieldName(item.name), !credentialFieldNames.contains(normalized) else { return nil }
            if let value = item.value, !value.isEmpty, componentCarriesPrivateMaterial(value) { return nil }
        }
        guard let out = comps.string, !out.isEmpty, out.utf8.count <= maxPooledLinkLen else { return nil }
        return out
    }

    /// A pooled http/usenet id that is PLAYABLE: a public http(s) URL. Legacy sha256(url) digests and opaque
    /// usenet ids pass `normalizePooledNonTorrentID` for contract compatibility but cannot be turned back into
    /// a link, so a served row using one is unplayable and dropped. Returns the URL string or nil.
    static func playableRemoteURL(kind: String, id: String) -> String? {
        guard let normalized = normalizePooledNonTorrentID(kind: kind, raw: id),
              matchesRegex(normalized, #"^https?://"#) else { return nil }
        return normalized
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
