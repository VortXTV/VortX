import Foundation

/// Client for the crowd-sourced language-availability index at `subtitles.vortx.tv/lang`.
///
/// The index answers "which AUDIO and SUBTITLE languages have real users actually seen for this title?" so the
/// UI can, later, surface a badge like "Audio: EN, ES · Subs: EN, FR" before playback. It is populated purely
/// from language CODES that clients contribute (from a file's track titles / the release name) -- never any
/// user data, never the media itself.
///
/// This is the FOUNDATION client: fail-soft, self-contained, callable. The integration pass wires the read into
/// the detail screen and the contribute call into the post-open path.
///
/// FAIL-SOFT: any network / decode / signing error returns nil (read) or is a silent no-op (contribute).
/// A disabled feature (`features.languageIndex` off) is a hard no-op that never touches the network.
///
/// GATING (VortX-only): like the sub pool, EVERY request to `subtitles.vortx.tv` is HMAC-signed with
/// `VortXEdgeAuth.sign`, including the GET read, so the index can be gated to real VortX builds when the worker
/// flips to enforce mode. Signing is a safe no-op without a provisioned secret (observe mode allows it).
enum LanguageIndexClient {

    // MARK: - Public model

    /// Aggregated language availability for a content key. Maps ISO-ish code -> number of times seen.
    struct LanguageAvailability: Equatable, Sendable {
        let audioLangs: [String: Int]
        let subLangs: [String: Int]
        let seenCount: Int
    }

    // MARK: - Read: GET /lang/<content_key>

    /// Fetch the language availability for `contentKey`. Signed GET, 8 s timeout. Gated on
    /// `features.languageIndex`. Returns nil on any error, when the feature is off, or when the pool's reported
    /// `seenCount` is below the `langIndex.minSeen` tunable (baked 1) -- too little signal to trust.
    static func fetch(contentKey: String) async -> LanguageAvailability? {
        guard featureLanguageIndex else { return nil }
        // `appendingPathComponent` percent-encodes the whole key as ONE opaque path segment (it escapes `/`),
        // matching the contribute() path build below. A manual `.urlPathAllowed` encode would leave a `/` in a
        // future id form intact and inject extra path segments.
        let url = baseURL.appendingPathComponent("lang").appendingPathComponent(contentKey)

        var req = URLRequest(url: url, timeoutInterval: 8)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "accept")
        VortXEdgeAuth.sign(&req)   // VortX-only gate: sign the read (no-op without a secret)

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            guard let decoded = try? JSONDecoder().decode(LangResponse.self, from: data) else { return nil }
            let seen = decoded.seenCount ?? 0
            guard seen >= RemoteConfig.snapshot.langIndexMinSeen else { return nil }
            return LanguageAvailability(audioLangs: decoded.audioLangs ?? [:],
                                        subLangs: decoded.subLangs ?? [:],
                                        seenCount: seen)
        } catch {
            return nil
        }
    }

    // MARK: - Contribute: POST /lang/contribute (signed)

    /// Best-effort contribution of the audio + subtitle language codes observed for `contentKey`. Signed POST.
    /// Gated on `features.languageIndex` AND the `.contribute` sub-flag. Empty / no-code contributions are
    /// skipped. Result ignored; failures are silent.
    ///
    /// - Parameter provenance: "container" (codes read from the media's own track metadata) or "name" (parsed
    ///   from the release name). Lets the worker weight container-derived codes more than name-guessed ones.
    static func contribute(contentKey: String,
                           audioLangs: [String],
                           subLangs: [String],
                           provenance: String) async {
        guard featureLanguageIndex, featureLanguageContribute else { return }
        let audio = normalize(audioLangs)
        let subs = normalize(subLangs)
        guard !audio.isEmpty || !subs.isEmpty else { return }   // nothing to say

        let body: [String: Any] = [
            "content_key": contentKey,
            "audioLangs": audio,
            "subLangs": subs,
            "provenance": provenance,
        ]
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return }

        var req = URLRequest(url: baseURL.appendingPathComponent("lang").appendingPathComponent("contribute"),
                             timeoutInterval: 8)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = data
        VortXEdgeAuth.sign(&req)
        _ = try? await URLSession.shared.data(for: req)
    }

    // MARK: - Pure helper: language codes from track titles + release name

    /// Extract ISO-ish language codes from a file's subtitle/audio track title strings plus the release name,
    /// with NO duplication of the ranker's token logic: it CALLS `StreamRanking.languageCodesAdvertised`, the
    /// single source of truth for the token map + boundary matching.
    ///
    /// - `trackTitles`: track title/metadata strings (e.g. "English", "Español SDH", "fre"); each is scanned for
    ///   any advertised language code. These are treated as the strongest signal (they describe real tracks).
    /// - `releaseName`: the stream release text; scanned the same way for codes the title hints at.
    ///
    /// Returns `(audio, sub)` code lists. Because a bare track title does not itself say whether the track is
    /// audio or subtitle, this helper conservatively returns the SAME extracted code set for both channels; the
    /// caller (which knows a track's media type) narrows it. Both lists are sorted + de-duplicated. No user data
    /// is produced -- codes only.
    static func languageCodes(fromTrackTitles trackTitles: [String],
                              releaseName: String?) -> (audio: [String], sub: [String]) {
        var codes = Set<String>()
        for title in trackTitles where !title.isEmpty {
            codes.formUnion(StreamRanking.languageCodesAdvertised(in: title))
        }
        if let releaseName, !releaseName.isEmpty {
            codes.formUnion(StreamRanking.languageCodesAdvertised(in: releaseName))
        }
        let sorted = codes.sorted()
        return (sorted, sorted)
    }

    /// Explicit subtitle-context markers. A stream string carrying one of these is describing SUBTITLE
    /// languages (not audio), so its parsed codes are classified as subtitle claims. Lowercased substrings;
    /// deliberately unambiguous (a plain "sub" alone would over-match, so it is boundary-checked by the caller).
    private static let subtitleMarkers: [String] = [
        "subtitle", "subtitles", "vostfr", "korsub", "legendado", "multisub", "multi-sub",
        "esub", "esubs", "msub", "msubs", "hardsub", "softsub", "hc sub", "with subs",
    ]

    /// CLASSIFYING variant of `languageCodes`: splits the parsed codes into AUDIO vs SUBTITLE claims by looking
    /// at each stream string's own context. A string with an explicit subtitle marker (vostfr, "ESubs",
    /// "multisub", ...) contributes its codes as SUBTITLE claims; any other string contributes them as AUDIO
    /// claims (a bare release-name language word like "English" is an audio claim -- exactly the token that must
    /// be verified before it is trusted). A code can land in both channels across different streams (one says
    /// "ENG", another "ENG subs"); the union is intentional.
    ///
    /// This split is what lets the verify DROP a false audio claim without also dropping the (lower-stakes,
    /// genuinely-added) subtitle claims -- the base `languageCodes` returns the same set for both channels,
    /// which cannot express "EN is a false audio claim but a real subtitle".
    static func audioSubCodes(fromNames names: [String]) -> (audio: [String], sub: [String]) {
        var audio = Set<String>()
        var sub = Set<String>()
        for name in names where !name.isEmpty {
            let lowered = name.lowercased()
            let codes = StreamRanking.languageCodesAdvertised(in: lowered)
            guard !codes.isEmpty else { continue }
            if isSubtitleContext(lowered) {
                sub.formUnion(codes)
            } else {
                audio.formUnion(codes)
            }
        }
        return (audio.sorted(), sub.sorted())
    }

    /// True when a stream string is describing subtitles rather than audio. Matches the explicit markers, plus
    /// a boundary-checked bare "sub"/"subs" so "ENG SUB" counts without "subscene"/"subbed-in-title" false hits.
    private static func isSubtitleContext(_ lowered: String) -> Bool {
        if subtitleMarkers.contains(where: { lowered.contains($0) }) { return true }
        // Boundary-checked bare "sub"/"subs" (space- or punctuation-delimited), the most common shorthand.
        return lowered.range(of: #"(?<![a-z])subs?(?![a-z])"#, options: .regularExpression) != nil
    }

    // MARK: - Feature gates

    /// Whether the language-availability feature is on (master gate). Exposed so the detail screens can skip
    /// the whole chip compute -- including the TMDB spoken_languages verification fetch -- when it is off,
    /// instead of relying only on the per-call internal no-ops. Mirrors the same RemoteConfig flag.
    static var isEnabled: Bool { featureLanguageIndex }

    private static var featureLanguageIndex: Bool {
        RemoteConfig.snapshot.isFeatureOn("languageIndex", default: RemoteConfigDefaults.featureLanguageIndex)
    }
    /// Contribute sub-flag under the master `languageIndex` gate: lets pool WRITES be paused remotely without
    /// disabling reads. Defaults ON.
    private static var featureLanguageContribute: Bool {
        RemoteConfig.snapshot.isFeatureOn("languageIndexContribute", default: true)
    }

    // MARK: - Helpers

    /// The index base URL from RemoteConfig, or the baked default.
    private static var baseURL: URL {
        RemoteConfig.snapshot.endpoint("subtitles") ?? URL(string: RemoteConfigDefaults.endpointSubtitles)!
    }

    /// Lowercase, trim, drop empties, de-duplicate, sort. Keeps the contributed list codes-only and stable.
    private static func normalize(_ codes: [String]) -> [String] {
        var seen = Set<String>()
        for raw in codes {
            let code = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !code.isEmpty { seen.insert(code) }
        }
        return seen.sorted()
    }

    // MARK: - Decodable wire shape

    private struct LangResponse: Decodable {
        let audioLangs: [String: Int]?
        let subLangs: [String: Int]?
        let seenCount: Int?
    }

    // MARK: - Display helper (shared by the detail-screen language chips)

    /// Merge the language codes OBSERVED from the loaded stream list with the community `availability`
    /// index into one ordered, display-ready set of chips for the detail screen's "Also available in" row.
    ///
    /// This is pure presentation logic shared by both detail surfaces (iOS + tvOS) so the merge/order/label
    /// rules live in ONE place. Codes only; no user data. Returns `(codes, labels)` where `codes` are the
    /// uppercased ISO-ish codes (e.g. "EN") and `labels` the human names (e.g. "English"), same order.
    ///
    /// - Parameters:
    ///   - observedAudio / observedSub: codes parsed from the stream names via `languageCodes(fromTrackTitles:)`.
    ///   - availability: the community index read (nil when the feature is off / worker down / too little signal).
    ///   - limit: max chips to render (keeps the row tasteful).
    static func availabilityChips(observedAudio: [String],
                                  observedSub: [String],
                                  availability: LanguageAvailability?,
                                  limit: Int = 8) -> [(code: String, label: String)] {
        // Union every code we know about: observed (audio+sub) plus the community index (audio+sub keys).
        var codes = Set<String>()
        codes.formUnion(observedAudio)
        codes.formUnion(observedSub)
        if let availability {
            codes.formUnion(availability.audioLangs.keys)
            codes.formUnion(availability.subLangs.keys)
        }

        // Normalize (lowercase base, strip region/script so "pt-BR" and "pt" collapse) and drop unknowns.
        var seenBase = Set<String>()
        var ordered: [String] = []
        for raw in codes {
            let base = raw.lowercased().split(separator: "-").first.map(String.init) ?? raw.lowercased()
            guard !base.isEmpty, base != "und", base != "unknown" else { continue }
            if seenBase.insert(base).inserted { ordered.append(base) }
        }

        // Order by community seen-count (most-seen first), then alphabetically, so the strongest signal leads.
        func weight(_ base: String) -> Int {
            guard let a = availability else { return 0 }
            return (a.audioLangs[base] ?? 0) + (a.subLangs[base] ?? 0)
        }
        ordered.sort { lhs, rhs in
            let wl = weight(lhs), wr = weight(rhs)
            if wl != wr { return wl > wr }
            return displayLabel(lhs) < displayLabel(rhs)
        }

        return ordered.prefix(limit).map { (code: $0.uppercased(), label: displayLabel($0)) }
    }

    /// Human-readable language name for a base code, falling back to the uppercased code when the locale
    /// database has no name for it.
    static func displayLabel(_ base: String) -> String {
        Locale.current.localizedString(forLanguageCode: base)?.capitalized ?? base.uppercased()
    }

    // MARK: - Verified display helper (drops FALSE audio-language claims)

    /// Like `availabilityChips`, but CROSS-CHECKS the observed AUDIO-language claims against TMDB's real
    /// `spoken_languages` and the community index, and DROPS an audio claim that is positively contradicted by
    /// BOTH. This is the fix for the owner's K-drama case: a release name that says "English audio" but whose
    /// file is Korean-only produces a name-parsed EN audio code; TMDB says the title's spoken languages are
    /// [ko] (no EN) and the community has never seen EN audio for it, so EN is a FALSE claim and is dropped
    /// rather than shown as confident.
    ///
    /// Trust rule for an observed AUDIO code (parsed from stream names / track titles):
    ///   TRUSTWORTHY if EITHER (a) `tmdbSpoken` contains it, OR (b) the community corroborates it above the
    ///   `langIndex.minSeen` floor (audioLangs + subLangs count). It is a FALSE claim, and is DROPPED, ONLY
    ///   when it is contradicted by BOTH sources at once: `tmdbSpoken` is present (non-nil) and does not
    ///   contain it, AND `availability` is present (non-nil) with a corroborating count below the floor.
    ///
    /// FAIL-SOFT: when a signal is MISSING (`tmdbSpoken == nil` or `availability == nil`) it cannot contradict,
    /// so nothing is dropped on missing data -- the observed langs render exactly as `availabilityChips` would.
    ///
    /// SUBTITLE claims are lower-stakes (subs genuinely get added by add-ons), so `observedSub` codes are NEVER
    /// dropped: a code kept as a subtitle stays even if it is not a spoken audio language. Community/TMDB codes
    /// are self-verified (seen or declared spoken) and always kept.
    ///
    /// - Parameters:
    ///   - tmdbSpoken: TMDB `spoken_languages` (+ original_language) base codes, or nil when TMDB was
    ///     unreachable / had no data. nil = "no verification signal", NOT "spoken set is empty".
    static func verifiedAvailabilityChips(observedAudio: [String],
                                          observedSub: [String],
                                          availability: LanguageAvailability?,
                                          tmdbSpoken: Set<String>?,
                                          limit: Int = 8) -> [(code: String, label: String)] {
        // Base-normalize the two verification sources ONCE so "pt-BR"/"pt" and case never cause a spurious miss.
        let spokenBase: Set<String>? = tmdbSpoken.map { Set($0.map(baseCode)) }
        let floor = RemoteConfig.snapshot.langIndexMinSeen

        // A community count for a base code across BOTH channels (audio + sub), base-folded so region variants
        // in the index don't split the tally.
        func communityCount(_ base: String) -> Int {
            guard let a = availability else { return 0 }
            var total = 0
            for (k, v) in a.audioLangs where baseCode(k) == base { total += v }
            for (k, v) in a.subLangs where baseCode(k) == base { total += v }
            return total
        }

        // Keep only the observed AUDIO codes that survive verification. A code is dropped ONLY when BOTH
        // sources are present AND both contradict it (TMDB lacks it AND community is below the floor).
        let survivingAudio = observedAudio.filter { raw in
            let base = baseCode(raw)
            let tmdbContradicts = (spokenBase != nil) && !(spokenBase!.contains(base))
            let communityContradicts = (availability != nil) && communityCount(base) < floor
            // Positively contradicted by BOTH -> false claim -> drop. Otherwise (corroborated by either, or a
            // signal missing) -> keep. This never drops on missing data.
            return !(tmdbContradicts && communityContradicts)
        }

        // Subtitle codes are never dropped; community/TMDB codes are self-verified. Feed the surviving audio +
        // all observed subs into the same merge/order path so ordering + labels stay identical to the
        // unverified row. `availabilityChips` re-unions the community index keys itself.
        return availabilityChips(observedAudio: survivingAudio,
                                 observedSub: observedSub,
                                 availability: availability,
                                 limit: limit)
    }

    /// Lowercase + strip any region/script suffix so "pt-BR" and "pt" collapse to one base code. Mirrors the
    /// normalization inside `availabilityChips` so verification compares on the same key space.
    private static func baseCode(_ raw: String) -> String {
        let lowered = raw.lowercased()
        return lowered.split(separator: "-").first.map(String.init) ?? lowered
    }
}
