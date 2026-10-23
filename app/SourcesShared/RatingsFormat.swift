import Foundation

/// ONE consistent formatting for cross-provider ratings across every VortX surface: the landscape card
/// badge (`CardRatingBadge`), the detail hero's primary rating position (`iOSDetailView` / tvOS
/// `DetailView`), and the server-side baked poster (mirrored in the `cloudflare-poster` worker's
/// `buildSvg`). Change the labels/order/number format here and every Apple surface moves together, so the
/// card, the detail row, and the baked poster never disagree about how a score reads.
///
/// The numbers cannot drift because every surface reaches them the same way: `VortXRatings.swift` and
/// `MDBListClient.swift` both land the aggregators with `Int($0.rounded())`, which is exactly what the
/// worker's `Math.round` does, and both read the same service keys (imdb / rt / metacritic / tmdb). The
/// worker's own unit test asserts the printed runs in this order, so a change on that side is caught; a
/// change on THIS side has no test behind it, so anything edited here must be mirrored by hand.
///
/// What DOES differ, deliberately, is the arrangement. The card draws these tokens as the JEWEL capsule
/// (a glass plate, lettermark beside its value) because it floats in a corner over unpredictable artwork;
/// the baked portrait poster draws them as the MARQUEE block (type straight on the art, lettermark stacked
/// above its value under a rule) because it owns a tall canvas with room for a real composition. That is a
/// design decision, not drift: do not "reunify" the two compositions. Only the tokens are shared.
///
/// The model is `MDBListRatings` (the shared decode target for both the keyless VortX ratings service and a
/// user's own MDBList key): IMDb on its native 0-10 scale, Rotten Tomatoes / TMDB as 0-100 percentages, and
/// Metacritic as a 0-100 metascore (no percent sign, matching how the score is conventionally printed).
/// The audience and community scores (Popcorn, Letterboxd, Trakt, MyAnimeList) are app-only: the baked
/// poster keeps the four headline scores, while cards and the detail row show every score present.
enum RatingsFormat {
    /// A single provider score: which service (`kind`, drawn as that service's mark by `RatingLogo`), the
    /// printed value ("84%"), the service's name for the spoken label, and the raw `score` the marks read
    /// (Rotten Tomatoes turns rotten below 60, the Metacritic square takes its colour from the score).
    struct Token: Equatable {
        enum Kind: Equatable { case imdb, rottenTomatoes, metacritic, tmdb, myAnimeList, kitsu, popcorn, letterboxd, trakt, simkl }
        let kind: Kind
        let label: String
        let value: String
        let score: Double
        var isIMDb: Bool { kind == .imdb }
    }

    /// IMDb on its native 0-10 scale, one decimal ("8.3"). Matches the baked poster's `imdb.toFixed(1)`, so
    /// the card, the detail row, and the poster all print the IMDb number identically.
    static func imdb(_ v: Double) -> String { String(format: "%.1f", v) }

    /// A score on a small native scale (Letterboxd 0-5, MyAnimeList 0-10), one decimal. A value above the
    /// scale is read as the 0-100 form of the same score, so an upstream format change cannot print 88 stars.
    static func scaled(_ v: Double, max scale: Double) -> Double? {
        guard v.isFinite, v > 0 else { return nil }
        let native = v > scale ? v * scale / 100 : v
        return (native * 10).rounded() / 10
    }

    /// Ordered tokens for every score present: the four headline scores first (IMDb -> RT -> MC -> TMDB), the
    /// anime scores next so an anime card keeps them (MAL -> Kitsu), then the audience and community scores
    /// (Popcorn -> Letterboxd -> Trakt -> SIMKL). Empty when nothing is
    /// present. A card badge drops tokens from the END when its card is too narrow, so the order is also
    /// the priority. `limit` caps the count outright for a surface that wants fewer. Per-score fail-soft by
    /// construction: a title carrying only IMDb yields exactly one token, so it renders only IMDb.
    static func tokens(_ r: MDBListRatings, limit: Int? = nil) -> [Token] {
        var out: [Token] = []
        if let v = r.imdb { out.append(Token(kind: .imdb, label: "IMDb", value: imdb(v), score: v)) }
        if let v = r.rottenTomatoes {
            out.append(Token(kind: .rottenTomatoes, label: "Rotten Tomatoes", value: "\(v)%", score: Double(v)))
        }
        if let v = r.metacritic { out.append(Token(kind: .metacritic, label: "Metacritic", value: "\(v)", score: Double(v))) }
        if let v = r.tmdb { out.append(Token(kind: .tmdb, label: "TMDB", value: "\(v)%", score: Double(v))) }
        if let v = r.mal {
            out.append(Token(kind: .myAnimeList, label: "MyAnimeList", value: String(format: "%.1f", v), score: v))
        }
        if let v = r.kitsu { out.append(Token(kind: .kitsu, label: "Kitsu", value: "\(v)%", score: Double(v))) }
        if let v = r.rtAudience { out.append(Token(kind: .popcorn, label: "Popcornmeter", value: "\(v)%", score: Double(v))) }
        if let v = r.letterboxd {
            out.append(Token(kind: .letterboxd, label: "Letterboxd", value: String(format: "%.1f", v), score: v))
        }
        if let v = r.trakt { out.append(Token(kind: .trakt, label: "Trakt", value: "\(v)%", score: Double(v))) }
        if let v = r.simkl { out.append(Token(kind: .simkl, label: "SIMKL", value: String(format: "%.1f", v), score: v)) }
        if let limit, limit >= 0, out.count > limit { return Array(out.prefix(limit)) }
        return out
    }

    /// The joined text form ("IMDb 8.3  ·  Rotten Tomatoes 84%  ·  Metacritic 69"), or nil when no score is
    /// present, for plain-text surfaces that cannot draw the service marks.
    static func joined(_ r: MDBListRatings) -> String? {
        let parts = tokens(r).map { "\($0.label) \($0.value)" }
        return parts.isEmpty ? nil : parts.joined(separator: "  \u{00B7}  ")
    }
}
