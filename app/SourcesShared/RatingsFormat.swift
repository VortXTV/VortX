import Foundation

/// ONE consistent formatting for cross-provider ratings across every VortX surface: the landscape card
/// badge (`CardRatingBadge`), the detail hero's primary rating position (`iOSDetailView` / tvOS
/// `DetailView`), and the server-side baked poster (mirrored in the `cloudflare-poster` worker's
/// `buildSvg`). Change the labels/order/number format here and every Apple surface moves together, so the
/// card, the detail row, and the baked poster never disagree about how a score reads.
///
/// The model is `MDBListRatings` (the shared decode target for both the keyless VortX ratings service and a
/// user's own MDBList key): IMDb on its native 0-10 scale, Rotten Tomatoes / TMDB as 0-100 percentages, and
/// Metacritic as a 0-100 metascore (no percent sign, matching how the score is conventionally printed).
enum RatingsFormat {
    /// A single provider score as a label + value, e.g. ("RT", "84%"). `isIMDb` marks the primary score that
    /// leads with a star glyph on the badges (its label is dropped there in favor of the star), while the
    /// detail row prints the label verbatim.
    struct Token: Equatable {
        let label: String
        let value: String
        let isIMDb: Bool
    }

    /// IMDb on its native 0-10 scale, one decimal ("8.3"). Matches the baked poster's `imdb.toFixed(1)`, so
    /// the card, the detail row, and the poster all print the IMDb number identically.
    static func imdb(_ v: Double) -> String { String(format: "%.1f", v) }

    /// Ordered tokens for every score present, IMDb -> RT -> MC -> TMDB. Empty when nothing is present.
    /// `limit` caps how many tokens a size-constrained surface renders (nil = all four): a small card asks
    /// for two (star + RT), a tvOS card or the detail row for all of them. Per-score fail-soft by
    /// construction: a title carrying only IMDb yields exactly one token, so it renders only IMDb.
    static func tokens(_ r: MDBListRatings, limit: Int? = nil) -> [Token] {
        var out: [Token] = []
        if let v = r.imdb { out.append(Token(label: "IMDb", value: imdb(v), isIMDb: true)) }
        if let v = r.rottenTomatoes { out.append(Token(label: "RT", value: "\(v)%", isIMDb: false)) }
        if let v = r.metacritic { out.append(Token(label: "MC", value: "\(v)", isIMDb: false)) }
        if let v = r.tmdb { out.append(Token(label: "TMDB", value: "\(v)%", isIMDb: false)) }
        if let limit, limit >= 0, out.count > limit { return Array(out.prefix(limit)) }
        return out
    }

    /// The joined detail-row string ("IMDb 8.3  ·  RT 84%  ·  MC 69  ·  TMDB 81%"), or nil when no score is
    /// present. The one string every detail surface prints, so tvOS and iOS/Mac never diverge.
    static func joined(_ r: MDBListRatings) -> String? {
        let parts = tokens(r).map { "\($0.label) \($0.value)" }
        return parts.isEmpty ? nil : parts.joined(separator: "  \u{00B7}  ")
    }
}
