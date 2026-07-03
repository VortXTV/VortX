import Foundation

/// Content-key + release-fingerprint helpers for VortX's community-subtitle system.
///
/// The pool at `subtitles.vortx.tv` keys everything on a `content_key` (the title/episode) plus, for the
/// learned SYNC OFFSET, a `fingerprint` (the specific RIP). The point of the fingerprint: an offset learned on
/// one encode (e.g. a WEB-DL that starts 900 ms after the black frame) must NOT be applied to a different rip
/// of the same episode (a BluRay remux with a different intro), or it would push everyone's subtitles OUT of
/// sync. So two streams share a fingerprint only when they are plausibly the same underlying media: same
/// frame-rate, same runtime (bucketed), same release-quality tokens.
///
/// This is FOUNDATION-only pure logic: no network, no state, deterministic. The integration pass supplies the
/// real inputs (duration from the player once known, release text from the chosen stream); every input is
/// optional so a caller that knows little still gets a stable, if coarser, fingerprint.
enum SubtitleReleaseFingerprint {

    // MARK: - content_key

    /// The pool `content_key` for a title or episode.
    ///
    ///   - movie:   `imdb:tt<id>`                    e.g. `imdb:tt0111161`
    ///   - episode: `imdb:tt<id>:<season>:<episode>` e.g. `imdb:tt0903747:1:1`
    ///
    /// `imdbId` may arrive with or without the leading `tt` and with or without an `imdb:`/`tt` prefix; it is
    /// normalized to the bare numeric-plus-tt core so the key is stable regardless of the caller's format.
    /// Returns nil when no usable IMDb id is present (the whole feature no-ops without a content key).
    static func contentKey(imdbId: String?, season: Int? = nil, episode: Int? = nil) -> String? {
        guard let tt = normalizedImdb(imdbId) else { return nil }
        if let season, let episode {
            return "imdb:\(tt):\(season):\(episode)"
        }
        return "imdb:\(tt)"
    }

    /// Reduce any of `tt0111161`, `0111161`, `imdb:tt0111161`, `imdb:tt0111161:1:2` to the bare `tt0111161`
    /// core, or nil when there is no `tt<digits>` / bare-digits id to be found.
    private static func normalizedImdb(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else {
            return nil
        }
        // Take the first `tt<digits>` occurrence if present.
        if let range = raw.range(of: #"tt\d+"#, options: .regularExpression) {
            return String(raw[range])
        }
        // Otherwise accept a bare run of digits (some sources pass the numeric id only) and re-prefix `tt`.
        if let range = raw.range(of: #"\d+"#, options: .regularExpression) {
            return "tt\(raw[range])"
        }
        return nil
    }

    // MARK: - release fingerprint

    /// A short, stable fingerprint of the PLAYING RIP, used only to scope the learned sync offset to media that
    /// is plausibly the same encode. Deterministic: the same inputs always produce the same string.
    ///
    /// Inputs (all optional; the integration pass fills what the player/stream actually knows):
    ///   - `frameRate`:    the video frame-rate if the player has surfaced it (e.g. 23.976, 25, 29.97). Rounded
    ///                     to 3 dp so 23.976023976… and 23.976 collapse together. Absent when unknown.
    ///   - `durationSecs`: the media runtime in seconds (from the player once the file is open). Bucketed to the
    ///                     nearest `durationBucketSecs` (default 30 s) so two rips of the same episode that
    ///                     differ by a couple of seconds of black frames still match, but a different cut does
    ///                     not. Absent when unknown.
    ///   - `releaseName`:  the stream's release / quality text (title + tags, e.g.
    ///                     "Show.S01E01.1080p.WEB-DL.x264-GRP"). Distilled to a sorted set of strong quality
    ///                     tokens (1080p / 2160p / web-dl / bluray / remux / x264 / x265 / hdr / …). The title
    ///                     words are dropped so only the ENCODE signature contributes.
    ///
    /// Fallback: when frame-rate is unknown, the fingerprint is built from the duration bucket plus the
    /// normalized release name so it is still stable and rip-specific. When nothing at all is known it returns a
    /// fixed sentinel ("unknown") so callers never have to branch on nil.
    ///
    /// The result is `<12-hex>`: a truncated FNV-1a hash of the normalized component string, short enough for a
    /// URL query value and stable across launches (it does NOT use Swift's per-process-seeded `hashValue`).
    static func releaseFingerprint(frameRate: Double? = nil,
                                   durationSecs: Double? = nil,
                                   releaseName: String? = nil,
                                   durationBucketSecs: Int = 30) -> String {
        var components: [String] = []

        if let frameRate, frameRate > 0, frameRate.isFinite {
            components.append("fps:\(String(format: "%.3f", frameRate))")
        }

        if let durationSecs, durationSecs > 0, durationSecs.isFinite {
            let bucket = max(1, durationBucketSecs)
            let bucketed = Int((durationSecs / Double(bucket)).rounded()) * bucket
            components.append("dur:\(bucketed)")
        }

        let tokens = qualityTokens(releaseName)
        if !tokens.isEmpty {
            components.append("src:\(tokens.joined(separator: "-"))")
        } else if let releaseName, !releaseName.isEmpty {
            // No strong quality token parsed: fall back to a normalized form of the whole name so the
            // fingerprint is still rip-specific rather than collapsing every untagged rip together.
            components.append("nm:\(normalizeName(releaseName))")
        }

        guard !components.isEmpty else { return "unknown" }
        return shortHash(components.joined(separator: "|"))
    }

    // MARK: - helpers

    /// Strong, unambiguous release-quality tokens, lowercased and SORTED so token order in the source name is
    /// irrelevant (the same rip described in a different word order fingerprints identically). Deliberately
    /// conservative: only encode/quality signatures, never title words.
    private static let qualityMarkers: [String] = [
        "2160p", "1080p", "720p", "480p", "4k", "uhd",
        "web-dl", "webdl", "webrip", "bluray", "blu-ray", "bdrip", "brrip", "hdrip", "dvdrip", "remux",
        "x264", "x265", "h264", "h265", "hevc", "avc", "av1", "xvid",
        "hdr", "hdr10", "dolby", "dovi", "hlg", "sdr", "10bit", "8bit",
        "atmos", "truehd", "dts", "ddp", "aac", "ac3", "flac",
    ]

    /// The sorted, de-duplicated set of quality tokens present in `name` (word-boundary matched so "1080p" in
    /// "S1080P" is not mismatched and "hdr" inside a title word is not a false hit). Empty when none present.
    static func qualityTokens(_ name: String?) -> [String] {
        guard let name = name?.lowercased(), !name.isEmpty else { return [] }
        var found = Set<String>()
        for marker in qualityMarkers {
            // Escape regex metacharacters (only "-" and "." appear in the markers) and require non-alphanumeric
            // boundaries so tokens embedded in a longer word do not match.
            let escaped = NSRegularExpression.escapedPattern(for: marker)
            let pattern = "(?<![a-z0-9])\(escaped)(?![a-z0-9])"
            if name.range(of: pattern, options: .regularExpression) != nil {
                found.insert(marker)
            }
        }
        return found.sorted()
    }

    /// Lowercase, strip everything but alphanumerics, collapse to a bounded-length core. Used only for the
    /// no-quality-token fallback so an untagged rip still yields a stable, deterministic string.
    private static func normalizeName(_ name: String) -> String {
        let lowered = name.lowercased()
        let kept = lowered.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        let str = String(String.UnicodeScalarView(kept))
        return String(str.prefix(64))
    }

    /// A stable 12-hex-char FNV-1a hash of `input`. Deterministic across launches and processes (unlike
    /// `String.hashValue`, which is per-process seeded and must NOT be used for a persisted/shared key).
    private static func shortHash(_ input: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325   // FNV offset basis
        let prime: UInt64 = 0x0000_0100_0000_01b3   // FNV prime
        for byte in input.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return String(format: "%012llx", hash & 0xffff_ffff_ffff)
    }
}
