// RatingsDisplayContractTests: a standalone, runnable verification of the ratings DISPLAY decision surface
// the CEO reported broken across every surface (detail row, posters, ERDB/XRDB, add-on catalog metas).
//
// VortX's Apple app has no Xcode unit-test bundle (verification is build + on-device, per CLAUDE.md), so,
// exactly like app/Tests/StreamRankingChipsTests.swift, this is a self-contained Swift executable run with
// the system toolchain:
//
//     swift app/Tests/RatingsDisplayContractTests.swift
//
// It re-implements ONLY the small ratings decision surface, NOT the SwiftUI stack, so it stays focused and
// cheap. The mirrors below MUST stay in lockstep with the shipped code they cite; if those drift, update the
// mirrors so the properties are still asserted against the real design.
//
// SCOPE: asserts DESIGN PROPERTIES against faithful mirrors, NOT the shipped functions directly (a standalone
// script cannot link the app target). The real proof the shipped code compiles/links is the Xcode build gate.

import Foundation

var failures = 0
func check(_ cond: Bool, _ label: String) {
    if cond { print("  ok   \(label)") } else { print("  FAIL \(label)"); failures += 1 }
}

// MARK: - A. VortX ratings response mapping (mirror of VortXRatingsClient.ratings + MDBListRatings)

struct RatingsModel: Equatable {
    let imdb: Double?; let rt: Int?; let mc: Int?; let tmdb: Int?
    var hasAny: Bool { imdb != nil || rt != nil || mc != nil || tmdb != nil }
}
func numeric(_ any: Any?) -> Double? {
    if let d = any as? Double { return d }
    if let i = any as? Int { return Double(i) }
    if let n = any as? NSNumber { return n.doubleValue }
    return nil
}
/// Mirror of VortXRatingsClient's JSON -> MDBListRatings mapping.
func mapVortXRatings(_ root: [String: Any]) -> RatingsModel? {
    let r = RatingsModel(
        imdb: numeric(root["imdb"]),
        rt: numeric(root["rt"]).map { Int($0.rounded()) },
        mc: numeric(root["metacritic"]).map { Int($0.rounded()) },
        tmdb: numeric(root["tmdb"]).map { Int($0.rounded()) }
    )
    return r.hasAny ? r : nil
}
/// Mirror of DetailView.ratingsText (the rendered detail row).
func ratingsText(_ r: RatingsModel) -> String? {
    var parts: [String] = []
    if let v = r.imdb { parts.append("IMDb \(v)") }
    if let v = r.rt { parts.append("RT \(v)%") }
    if let v = r.mc { parts.append("MC \(v)") }
    if let v = r.tmdb { parts.append("TMDB \(v)%") }
    return parts.isEmpty ? nil : parts.joined(separator: "  \u{00B7}  ")
}

func testRatingsMapping() {
    print("A. VortX ratings response mapping (detail row)")
    // The EXACT body ratings.vortx.tv returns for tt0460649 (curl-verified 200).
    let json = "{\"id\":\"tt0460649\",\"imdb\":8.3,\"rt\":84,\"metacritic\":69,\"tmdb\":81,\"sources\":[\"imdb\",\"rt\",\"metacritic\",\"tmdb\"]}"
    let root = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
    check(root != nil, "service JSON parses")
    let m = root.flatMap(mapVortXRatings)
    check(m != nil, "maps to a non-nil ratings model")
    check(m?.imdb == 8.3, "imdb 8.3 maps")
    check(m?.rt == 84, "rt 84 maps (int)")
    check(m?.mc == 69, "metacritic 69 maps")
    check(m?.tmdb == 81, "tmdb 81 maps")
    let present = [m?.imdb != nil, m?.rt != nil, m?.mc != nil, m?.tmdb != nil].filter { $0 }.count
    check(present == 4, "ALL 4 sources present (observed \(present)/4) -> row must show more than IMDb")
    let text = m.flatMap(ratingsText)
    check(text?.contains("RT 84%") == true && text?.contains("MC 69") == true && text?.contains("TMDB 81%") == true,
          "rendered row contains RT+MC+TMDB, not IMDb-only: \(text ?? "nil")")
}

// MARK: - B. renderable-id gates (mirror of XRDB.renderableID + ERDB.renderableID)

func xrdbRenderable(_ id: String) -> Bool { id.hasPrefix("tt") || id.hasPrefix("tmdb:") }
func erdbRenderable(_ id: String) -> Bool {
    if id.hasPrefix("tt") { return true }
    for s in ["tmdb:", "tvdb:", "kitsu:", "anilist:", "mal:", "anidb:", "realimdb:"] where id.hasPrefix(s) { return true }
    return false
}

// MARK: - C. per-id poster-badge suppression (mirror of the FIXED PosterArtwork.bakesRatings(forID:))

/// The OLD global flag: baking assumed on for EVERY id whenever a provider is switched on (the bug).
func bakesRatingsGlobal(erdbActive: Bool, xrdbEnabled: Bool) -> Bool { erdbActive || xrdbEnabled }
/// The FIXED per-id flag: baking only when the active provider can actually render THIS id.
func bakesRatings(forID id: String?, erdbActive: Bool, xrdbEnabled: Bool) -> Bool {
    guard let id else { return bakesRatingsGlobal(erdbActive: erdbActive, xrdbEnabled: xrdbEnabled) }
    if erdbActive { return erdbRenderable(id) }
    if xrdbEnabled { return xrdbRenderable(id) }
    return false
}
/// The card draws its own IMDb badge only when the service did NOT bake one (and a rating exists).
func drawsOwnBadge(id: String, hasRating: Bool, erdbActive: Bool, xrdbEnabled: Bool, perID: Bool) -> Bool {
    let baked = perID ? bakesRatings(forID: id, erdbActive: erdbActive, xrdbEnabled: xrdbEnabled)
                      : bakesRatingsGlobal(erdbActive: erdbActive, xrdbEnabled: xrdbEnabled)
    return hasRating && !baked
}

func testPosterBadgeSuppression() {
    print("B/C. poster-badge suppression matrix (default: XRDB on, ERDB off)")
    // Default provider state VortX ships with.
    let erdb = false, xrdb = true

    // Renderable ids: the service bakes the rating, so the local badge is correctly suppressed (no double badge).
    check(bakesRatings(forID: "tt0460649", erdbActive: erdb, xrdbEnabled: xrdb) == true, "tt id -> service bakes, suppress local")
    check(bakesRatings(forID: "tmdb:1418", erdbActive: erdb, xrdbEnabled: xrdb) == true, "tmdb: id -> service bakes, suppress local")

    // Non-renderable add-on id (e.g. an external 'hive:'-style scheme the poster service cannot map).
    // OLD behavior: global flag suppressed the badge for ALL ids -> card showed NO rating (the bug).
    // NEW behavior: per-id flag lets the local IMDb badge render, so the add-on's rating shows.
    let addonID = "hive:abc123"
    check(bakesRatingsGlobal(erdbActive: erdb, xrdbEnabled: xrdb) == true, "OLD global flag = true for a non-renderable id (bug)")
    check(bakesRatings(forID: addonID, erdbActive: erdb, xrdbEnabled: xrdb) == false, "NEW per-id flag = false for a non-renderable id (fixed)")
    check(drawsOwnBadge(id: addonID, hasRating: true, erdbActive: erdb, xrdbEnabled: xrdb, perID: false) == false,
          "OLD: add-on card with a rating drew NO badge (regression the CEO saw)")
    check(drawsOwnBadge(id: addonID, hasRating: true, erdbActive: erdb, xrdbEnabled: xrdb, perID: true) == true,
          "NEW: add-on card with a rating draws its own IMDb badge (fixed)")

    // No baking provider on at all: local badge always drawn for a renderable OR non-renderable id.
    check(bakesRatings(forID: "tt1", erdbActive: false, xrdbEnabled: false) == false, "both providers off -> local badge drawn")

    // ERDB on renders the anime schemes XRDB cannot, so its bake still suppresses the local badge there.
    check(bakesRatings(forID: "kitsu:1", erdbActive: true, xrdbEnabled: false) == true, "ERDB on -> kitsu: bakes")
    check(bakesRatings(forID: "kitsu:1", erdbActive: false, xrdbEnabled: true) == false, "XRDB-only -> kitsu: not bakeable, local badge drawn")
}

// MARK: - D. add-on rating at the Swift decode boundary (mirror of CoreMeta/CoreMetaItem.imdbRating)

struct Link { let name: String; let category: String }
/// Mirror: Swift reads a preview/meta rating ONLY from a links entry with category "imdb".
func imdbRatingFromLinks(_ links: [Link]?) -> String? {
    (links ?? []).first { $0.category.caseInsensitiveCompare("imdb") == .orderedSame }?.name
}

func testAddonStripBoundary() {
    print("D. add-on rating at the Swift decode boundary (documents the engine strip)")
    // Cinemeta-style: links carry an imdb link -> the rating shows (this is why IMDb still renders).
    let withImdb = [Link(name: "8.3", category: "imdb"), Link(name: "Comedy", category: "Genres")]
    check(imdbRatingFromLinks(withImdb) == "8.3", "links WITH imdb link -> rating present (IMDb shows)")
    // Add-on ('hive') that sent its own links (genres) but no imdb link: after the engine's
    // MetaItemPreview::from(Legacy) keeps those links and drops top-level imdbRating, Swift sees no rating.
    let addonNoImdbLink = [Link(name: "Action", category: "Genres"), Link(name: "Drama", category: "Genres")]
    check(imdbRatingFromLinks(addonNoImdbLink) == nil, "links WITHOUT imdb link -> rating nil (VortX shows nothing == the strip)")
    // Proves the fix must land UPSTREAM (engine merges the synthesized imdb link even when links is present):
    // the Swift model has no top-level rating field to recover it from, by construction.
}

// MARK: - run

print("== RatingsDisplayContractTests ==")
testRatingsMapping()
testPosterBadgeSuppression()
testAddonStripBoundary()
print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
