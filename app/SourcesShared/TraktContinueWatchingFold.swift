import Foundation

/// A provider-neutral value produced from one Trakt `/sync/playback` row.
///
/// This file stays Foundation-only so its identity and ordering contract can be tested with the system
/// Swift toolchain, without linking an app target or making a network request.
struct TraktContinueWatchingSeed: Codable, Equatable, Sendable {
    let id: String
    let type: String
    let name: String
    let progress: Double
    let pausedAt: String
    let runtimeMinutes: Double?
    let videoID: String?
    /// Artwork already held by the app for the same title. Trakt's documented rows do not provide
    /// artwork, and folding one must not trigger a new metadata request; this is non-nil only when
    /// the Trakt response itself supplied an HTTPS image URL (validated by `TraktArtworkPolicy`).
    var poster: String?
    /// Every OTHER stable id form Trakt supplied for this title — typed `tmdb:tv:<n>` /
    /// `tmdb:movie:<n>` and untyped `tmdb:<n>` — deduped, never containing `id`. The artwork join in
    /// `TraktPlaybackShadow` uses these to reuse locally cached artwork when the local row is keyed
    /// by a different id form than the primary. Optional (and defaulted) so caches written before
    /// this field existed still decode, with nil aliases meaning "primary id only".
    var aliases: [String]? = nil

    var durationSeconds: Double? {
        guard let runtimeMinutes, runtimeMinutes.isFinite, runtimeMinutes > 0 else { return nil }
        return runtimeMinutes * 60
    }

    /// The exact offset represented by the percentage shown on the card.
    var resumeSeconds: Double? {
        guard let durationSeconds, progress.isFinite, progress > 0 else { return nil }
        return durationSeconds * progress / 100
    }
}

/// Movie and episode pause activity are independent Trakt cursors. Collapsing them with `max()` loses a
/// change on the older side whenever the newer side's timestamp stays unchanged.
struct TraktPlaybackActivityStamps: Codable, Equatable, Sendable {
    let movies: String?
    let episodes: String?

    /// Kept in the cache as a downgrade-compatible copy for app versions that only know one cursor.
    var legacyMaximum: String? {
        [movies, episodes].compactMap { $0 }.max()
    }
}

enum TraktContinueWatchingFold {
    /// Convert Trakt's mixed movie and episode playback rows into one ordered title row per movie/show.
    ///
    /// The newest paused episode wins when a show has more than one paused episode. Rows at or beyond
    /// 95 percent are excluded because VortX treats that region as completion/credits rather than a useful
    /// resume point.
    static func fold(_ rows: [[String: Any]]) -> [TraktContinueWatchingSeed] {
        let candidates = rows.compactMap(seed)
            .sorted {
                if $0.pausedAt != $1.pausedAt { return $0.pausedAt > $1.pausedAt }
                return $0.id < $1.id
            }

        // Trakt can return the same show more than once with different subsets of ids (for
        // example one row with imdb+tmdb and another with tmdb only).  Dedupe on the complete
        // identity union, rather than only the selected primary id, so one show still produces
        // one card and the newest paused episode wins.  Type remains part of the match: a movie
        // and series are never collapsed merely because they share a TMDB number.
        var kept: [TraktContinueWatchingSeed] = []
        for candidate in candidates {
            let candidateIDs = Set([candidate.id] + (candidate.aliases ?? []))
            let duplicateIndices = kept.indices.filter { index in
                let existing = kept[index]
                return existing.type == candidate.type &&
                    !candidateIDs.isDisjoint(with: Set([existing.id] + (existing.aliases ?? [])))
            }
            guard let duplicateIndex = duplicateIndices.first else {
                kept.append(candidate)
                continue
            }
            // Preserve the newest row's progress/name/artwork, but accumulate every identity
            // seen across duplicate rows so transitive A-B-C aliases cannot yield duplicate cards.
            var winner = kept[duplicateIndex]
            winner.aliases = TraktArtworkPolicy.dedupedAliases(
                (winner.aliases ?? []) + [candidate.id] + (candidate.aliases ?? [])
                    + duplicateIndices.flatMap { [kept[$0].id] + (kept[$0].aliases ?? []) },
                primary: winner.id
            )
            kept[duplicateIndex] = winner
            // A late bridge row can connect two previously disjoint identities. Keep only the
            // newest component representative, not a second card with the newly discovered alias.
            for index in duplicateIndices.dropFirst().reversed() { kept.remove(at: index) }
        }
        return kept
    }

    private static func seed(_ row: [String: Any]) -> TraktContinueWatchingSeed? {
        guard let progress = number(row["progress"]),
              progress > 0, progress < 95 else { return nil }
        let pausedAt = row["paused_at"] as? String ?? ""

        switch row["type"] as? String {
        case "movie":
            guard let movie = row["movie"] as? [String: Any],
                  let ids = movie["ids"] as? [String: Any],
                  let id = identityForms(ids, isSeries: false).first else { return nil }
            let name = movie["title"] as? String ?? ""
            guard !name.isEmpty else { return nil }
            return TraktContinueWatchingSeed(
                id: id,
                type: "movie",
                name: name,
                progress: progress,
                pausedAt: pausedAt,
                runtimeMinutes: positiveNumber(movie["runtime"]),
                videoID: nil,
                poster: TraktArtworkPolicy.artwork(fromRowMedia: movie),
                aliases: aliasForms(ids, isSeries: false, primary: id)
            )

        case "episode":
            guard let episode = row["episode"] as? [String: Any],
                  let show = row["show"] as? [String: Any],
                  let ids = show["ids"] as? [String: Any],
                  let id = identityForms(ids, isSeries: true).first,
                  let season = nonNegativeInt(episode["season"]),
                  let number = nonNegativeInt(episode["number"]) else { return nil }
            let name = show["title"] as? String ?? ""
            guard !name.isEmpty else { return nil }
            return TraktContinueWatchingSeed(
                id: id,
                type: "series",
                name: name,
                progress: progress,
                pausedAt: pausedAt,
                runtimeMinutes: positiveNumber(episode["runtime"]),
                videoID: "\(id):\(season):\(number)",
                poster: TraktArtworkPolicy.artwork(fromRowMedia: show),
                aliases: aliasForms(ids, isSeries: true, primary: id)
            )

        default:
            return nil
        }
    }

    /// Primary identity precedence is unchanged: imdb when Trakt supplies it, else the typed tmdb
    /// form. These are now derived from the full form list so the primary and the aliases can never
    /// disagree about which identity forms exist.
    private static func identityForms(_ ids: [String: Any], isSeries: Bool) -> [String] {
        var forms: [String] = []
        if let imdb = ids["imdb"] as? String, !imdb.isEmpty { forms.append(imdb) }
        if let tmdb = positiveInt(ids["tmdb"]) {
            forms.append(isSeries ? "tmdb:tv:\(tmdb)" : "tmdb:movie:\(tmdb)")
            forms.append("tmdb:\(tmdb)")
        }
        return forms
    }

    /// Secondary id forms for the same title: every form Trakt supplied except the primary, deduped
    /// (never containing the primary itself). Typed forms keep their type, and the untyped form is
    /// only ever joined downstream against rows of the SAME type, so movie and series ids sharing a
    /// tmdb number never cross-match.
    private static func aliasForms(
        _ ids: [String: Any],
        isSeries: Bool,
        primary: String
    ) -> [String] {
        TraktArtworkPolicy.dedupedAliases(
            Array(identityForms(ids, isSeries: isSeries).dropFirst()),
            primary: primary
        )
    }

    private static func positiveInt(_ value: Any?) -> Int? {
        guard let n = number(value), n.isFinite, n.rounded() == n else { return nil }
        // Double(Int.max) rounds up to 2^63; strict inequality excludes that trapping value.
        guard n < Double(Int.max), n >= Double(Int.min) else { return nil }
        let i = Int(n)
        return i > 0 ? i : nil
    }

    private static func nonNegativeInt(_ value: Any?) -> Int? {
        guard let n = number(value), n.isFinite, n >= 0, n < Double(Int.max), n.rounded() == n else { return nil }
        let i = Int(n)
        return i >= 0 ? i : nil
    }

    private static func positiveNumber(_ value: Any?) -> Double? {
        guard let n = number(value), n > 0 else { return nil }
        return n
    }

    private static func number(_ value: Any?) -> Double? {
        if let n = value as? Double, n.isFinite { return n }
        if let n = value as? Int { return Double(n) }
        if let n = value as? NSNumber {
            let d = n.doubleValue
            return d.isFinite ? d : nil
        }
        if let value = value as? String, let n = Double(value), n.isFinite { return n }
        return nil
    }
}
