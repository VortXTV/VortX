import Foundation

/// Pure, Foundation-only policy for repairing Continue Watching artwork WITHOUT a new network call.
///
/// HARD PRIVACY INVARIANT (preserved from the fold's original design): a private Trakt playback row
/// must never drive a new third-party metadata or image request. Artwork may come only from:
/// (a) an HTTPS URL in the Trakt response's documented `images` object (available when the
///     endpoint is requested with `extended=full`; no extra request is made) or
/// (b) artwork already cached locally for the SAME title, joined by exact identity only — never by
///     name, and never across the movie/series divide.
///
/// No CoreBridge, engine, or settings dependency: this file exists so both the fold (writer side)
/// and `TraktPlaybackShadow` (join side) share one set of rules, and so the rules are testable with
/// the system Swift toolchain.
enum TraktArtworkPolicy {
    /// A locally cached row usable for the artwork join (a projection of `CoreCWItem`).
    struct Candidate: Equatable, Sendable {
        let id: String
        /// Engine type vocabulary ("movie" / "series"), used to block cross-type joins.
        let type: String
        let poster: String?
    }

    // MARK: - Source-supplied artwork (no request involved)

    /// Trakt's image payload omits the URL scheme, so accept a valid host/path and normalize it
    /// to HTTPS. Explicit non-HTTPS schemes, userinfo, scheme-relative URLs, relative paths, and
    /// bare filenames are rejected. This performs no lookup or network access.
    static func sourceSuppliedArtwork(_ value: String?) -> String? {
        guard let value,
              !value.isEmpty,
              !value.contains(where: { $0.isWhitespace }) else { return nil }

        let candidate: String
        if value.contains("://") {
            // A supplied scheme is authoritative: only HTTPS is safe to carry forward.
            guard value.lowercased().hasPrefix("https://") else { return nil }
            candidate = value
        } else {
            // Trakt returns scheme-less absolute URLs (for example
            // `walter.trakt.tv/images/poster.webp`). Do not accept `//host`, `/path`, or a
            // bare filename as if they were hosts.
            guard !value.hasPrefix("//"), !value.hasPrefix("/"), value.contains("."), value.contains("/") else {
                return nil
            }
            candidate = "https://" + value
        }

        guard let components = URLComponents(string: candidate),
              components.scheme?.lowercased() == "https",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              let url = components.url,
              url.host != nil else { return nil }
        return candidate
    }

    /// Extract artwork from the documented Trakt `images` object, if present. Trakt image values
    /// are commonly arrays of scheme-less URLs; they are normalized to HTTPS. Flat ad-hoc fields are
    /// intentionally ignored because they are not part of the current API contract.
    static func artwork(fromRowMedia media: [String: Any]?) -> String? {
        guard let media else { return nil }
        guard let images = media["images"] as? [String: Any] else { return nil }
        for key in ["poster", "banner", "background", "clearart", "logo"] {
            if let hit = sourceSuppliedArtwork(images[key] as? String) { return hit }
            if let list = images[key] as? [Any] {
                for entry in list {
                    if let hit = sourceSuppliedArtwork(entry as? String) { return hit }
                }
            }
        }
        return nil
    }

    // MARK: - Identity alias join

    /// Dedupe alias id forms, preserving first occurrence and never including the primary id.
    static func dedupedAliases(_ aliases: [String]?, primary: String) -> [String] {
        var seen: Set<String> = [primary]
        var out: [String] = []
        for alias in aliases ?? [] where !alias.isEmpty && seen.insert(alias).inserted {
            out.append(alias)
        }
        return out
    }

    /// The type-safe identity join used to reuse locally cached artwork.
    ///
    /// The primary id is tried first, then every alias, but a candidate is usable ONLY when its own
    /// type string matches the seed's. The untyped `tmdb:<n>` form is shared by movies and series,
    /// so without the type check the same TMDB number would cross-match a movie library row onto a
    /// series card (and vice versa); the typed forms carry the type but local rows are often keyed
    /// untyped, which is exactly the gap this join closes. There is no name-only matching, ever.
    static func matchedCandidate(
        seedID: String,
        seedAliases: [String],
        seedType: String,
        candidates: [Candidate]
    ) -> Candidate? {
        for key in [seedID] + seedAliases {
            // Keep searching when the first local row with this identity has no artwork. This
            // matters when the Continue Watching rail is first in the pool and a library row
            // for the same title (later in the pool) already has a cached poster.
            if let hit = candidates.first(where: {
                $0.id == key && $0.type == seedType &&
                $0.poster.map { !$0.isEmpty } == true
            }) { return hit }
        }
        return nil
    }
}
