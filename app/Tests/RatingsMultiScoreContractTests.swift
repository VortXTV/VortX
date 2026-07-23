// RatingsMultiScoreContractTests: a standalone, runnable verification of the MULTI-SCORE ratings surface
// the CEO reported broken: cards and the detail hero showed a single IMDb number even though the backend
// returns IMDb + RT + Metacritic + TMDB, and add-on posters that already carry baked ratings were being
// replaced by our single-score art.
//
// VortX's Apple app has no Xcode unit-test bundle (verification is build + on-device, per CLAUDE.md), so,
// exactly like app/Tests/RatingsDisplayContractTests.swift, this is a self-contained Swift executable run
// with the system toolchain:
//
//     swift app/Tests/RatingsMultiScoreContractTests.swift
//
// SCOPE: asserts DESIGN PROPERTIES against faithful mirrors of two small decision surfaces, NOT the shipped
// SwiftUI/types directly (a standalone script cannot link the app target):
//   1) RatingsFormat.tokens / .joined / .imdb  (app/SourcesShared/RatingsFormat.swift) -- the ONE format the
//      card badge, the detail hero's primary rating, and the baked poster all share.
//   2) PosterArtwork.isWrappableRawArt + the poster pass-through decision (app/SourcesShared/ERDBConfig.swift)
//      -- wrap only raw, id-derivable art (metahub / TMDB); pass an add-on's own poster through untouched.
// The mirrors below MUST stay in lockstep with the shipped code they cite; the real proof the shipped code
// compiles/links is the Xcode build gate.

import Foundation

var failures = 0
func check(_ cond: Bool, _ label: String) {
    if cond { print("  ok   \(label)") } else { print("  FAIL \(label)"); failures += 1 }
}

// MARK: - Mirror of MDBListRatings (the shared decode model) + RatingsFormat

struct Ratings: Equatable {
    let imdb: Double?
    let rottenTomatoes: Int?
    let metacritic: Int?
    let tmdb: Int?
}

struct Token: Equatable { let label: String; let value: String; let isIMDb: Bool }

/// Mirror of RatingsFormat.imdb: IMDb on its 0-10 scale, one decimal. Same as the baked poster's toFixed(1).
func imdbText(_ v: Double) -> String { String(format: "%.1f", v) }

/// Mirror of RatingsFormat.tokens: ordered IMDb -> RT -> MC -> TMDB, optionally capped by `limit`.
func tokens(_ r: Ratings, limit: Int? = nil) -> [Token] {
    var out: [Token] = []
    if let v = r.imdb { out.append(Token(label: "IMDb", value: imdbText(v), isIMDb: true)) }
    if let v = r.rottenTomatoes { out.append(Token(label: "RT", value: "\(v)%", isIMDb: false)) }
    if let v = r.metacritic { out.append(Token(label: "MC", value: "\(v)", isIMDb: false)) }
    if let v = r.tmdb { out.append(Token(label: "TMDB", value: "\(v)%", isIMDb: false)) }
    if let limit, limit >= 0, out.count > limit { return Array(out.prefix(limit)) }
    return out
}

/// Mirror of RatingsFormat.joined: the detail-row string, or nil when empty.
func joined(_ r: Ratings) -> String? {
    let parts = tokens(r).map { "\($0.label) \($0.value)" }
    return parts.isEmpty ? nil : parts.joined(separator: "  \u{00B7}  ")
}

// The EXACT scores ratings.vortx.tv returns for tt0460649 (curl-verified 200).
let hmym = Ratings(imdb: 8.3, rottenTomatoes: 84, metacritic: 69, tmdb: 81)

func testTokens() {
    print("A. RatingsFormat.tokens (card badge + detail primary, shared)")
    let t = tokens(hmym)
    check(t.count == 4, "all four scores present -> 4 tokens (observed \(t.count))")
    check(t.map { $0.label } == ["IMDb", "RT", "MC", "TMDB"], "order is IMDb, RT, MC, TMDB")
    check(t.first?.isIMDb == true && t.dropFirst().allSatisfy { !$0.isIMDb }, "only IMDb is the star token")
    check(t[0].value == "8.3" && t[1].value == "84%" && t[2].value == "69" && t[3].value == "81%",
          "values: 8.3 / 84% / 69 (no %) / 81%")

    // Card-size cap: a small tile asks for two (star + RT), a larger card for all four.
    check(tokens(hmym, limit: 2).map { $0.label } == ["IMDb", "RT"], "limit 2 -> IMDb + RT (small card)")
    check(tokens(hmym, limit: 4).count == 4, "limit 4 -> all four (large/tvOS card)")

    // Per-score fail-soft: a title carrying only IMDb yields exactly one token (shows only IMDb).
    check(tokens(Ratings(imdb: 7.0, rottenTomatoes: nil, metacritic: nil, tmdb: nil)) == [Token(label: "IMDb", value: "7.0", isIMDb: true)],
          "IMDb-only -> one IMDb token (fail-soft)")

    // A title missing IMDb still surfaces the scores it has; the first token is NOT the star.
    let noImdb = tokens(Ratings(imdb: nil, rottenTomatoes: 90, metacritic: nil, tmdb: 77))
    check(noImdb.map { $0.label } == ["RT", "TMDB"] && noImdb.first?.isIMDb == false, "no IMDb -> RT + TMDB, no star")

    check(tokens(Ratings(imdb: nil, rottenTomatoes: nil, metacritic: nil, tmdb: nil)).isEmpty, "nothing present -> no tokens")
}

func testJoinedAndFormat() {
    print("B. RatingsFormat.joined (detail-row variant) + IMDb format")
    check(joined(hmym) == "IMDb 8.3  \u{00B7}  RT 84%  \u{00B7}  MC 69  \u{00B7}  TMDB 81%",
          "detail row joins all four with a middot: \(joined(hmym) ?? "nil")")
    check(joined(Ratings(imdb: 8.3, rottenTomatoes: nil, metacritic: nil, tmdb: nil)) == "IMDb 8.3", "IMDb-only detail row")
    check(joined(Ratings(imdb: nil, rottenTomatoes: nil, metacritic: nil, tmdb: nil)) == nil, "empty -> nil row (hidden)")
    check(imdbText(7.0) == "7.0", "7.0 -> \"7.0\"")
    check(imdbText(8.34) == "8.3", "8.34 -> \"8.3\"")
    check(imdbText(6.849) == "6.8", "6.849 -> \"6.8\"")
}

// MARK: - Mirror of PosterArtwork.isWrappableRawArt + the poster pass-through decision

/// Mirror of PosterArtwork.isWrappableRawArt: metahub / TMDB image hosts (and subdomains) are the raw,
/// id-derivable art we can safely re-render; a blank URL is wrappable (render from id); any other host is
/// the add-on's own art and is passed through.
let wrappableArtHosts = ["metahub.space", "tmdb.org"]
func isWrappableRawArt(_ url: String?) -> Bool {
    guard let raw = url, !raw.isEmpty else { return true }
    guard let host = URL(string: raw)?.host?.lowercased() else { return false }
    for h in wrappableArtHosts where host == h || host.hasSuffix("." + h) { return true }
    return false
}

/// Mirror of PosterArtwork.poster's pass-through guard: a foreign (non-raw) add-on poster is returned
/// UNTOUCHED; otherwise the id is routed through our baking service. Returns "passthrough" or "wrap".
func posterDecision(fallback: String?) -> String {
    if let fb = fallback, !fb.isEmpty, !isWrappableRawArt(fb) { return "passthrough" }
    return "wrap"
}

func testPassThrough() {
    print("C. add-on poster pass-through (respect pre-baked art)")

    // Raw, id-derivable art we source ourselves -> wrapped (our rating baked on, current behavior).
    check(isWrappableRawArt("https://images.metahub.space/poster/medium/tt0460649/img"), "metahub -> wrappable")
    check(isWrappableRawArt("https://image.tmdb.org/t/p/w500/abc.jpg"), "TMDB image CDN -> wrappable")
    check(posterDecision(fallback: "https://images.metahub.space/poster/medium/tt0460649/img") == "wrap", "metahub fallback -> wrap")
    check(posterDecision(fallback: "https://image.tmdb.org/t/p/w500/abc.jpg") == "wrap", "TMDB fallback -> wrap (ambiguity kept)")

    // No add-on art at all -> wrappable (nothing to preserve; render from the id).
    check(isWrappableRawArt(nil) && isWrappableRawArt(""), "nil/empty -> wrappable (render from id)")
    check(posterDecision(fallback: nil) == "wrap", "no add-on poster -> wrap (render from id)")

    // An add-on's OWN poster on a foreign host (a poster-ratings service that BAKES 3-4 scores) -> passed
    // through untouched so its scores survive. Hosts are described by FORM, not brand.
    check(!isWrappableRawArt("https://api.some-poster-ratings-service.com/KEY/imdb/poster-default/tt0460649.jpg"),
          "foreign baked-poster host -> NOT wrappable")
    check(posterDecision(fallback: "https://api.some-poster-ratings-service.com/KEY/imdb/poster-default/tt0460649.jpg") == "passthrough",
          "add-on baked poster -> passthrough (scores survive)")

    // A generic third-party add-on art host (the CEO's log shows one fetched directly) -> passthrough.
    check(posterDecision(fallback: "https://cdn.some-addon.example/art/tt0460649.png") == "passthrough",
          "third-party add-on art host -> passthrough")

    // Subdomains of the raw hosts still count as raw.
    check(isWrappableRawArt("https://artworks.metahub.space/x/img"), "metahub subdomain -> wrappable")
}

print("== RatingsMultiScoreContractTests ==")
testTokens()
testJoinedAndFormat()
testPassThrough()
print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
