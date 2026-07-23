// LandscapeCardRatingContractTests: a standalone, runnable verification of the CARD rating-badge decision
// for the cinematic LANDSCAPE cards, the surface the CEO reported broken ("Show ratings on posters" ON, yet
// no star on any card). Live repro proved the cause: landscape is the DEFAULT appearance and fills each cell
// with a CLEAN, textless TMDB backdrop (LandscapeArt / LandscapeArtiOS) that the poster-baking service never
// touches, so the baked rating that portrait 2:3 posters get never appears. The fix surfaces the rating as a
// client badge (CardRatingBadge, fed by the keyless VortXRatingsClient) whenever the visible art is NOT itself
// baked.
//
// VortX's Apple app has no Xcode unit-test bundle (verification is build + on-device, per CLAUDE.md), so,
// exactly like app/Tests/RatingsDisplayContractTests.swift, this is a self-contained Swift executable run with
// the system toolchain:
//
//     swift app/Tests/LandscapeCardRatingContractTests.swift
//
// SCOPE: asserts DESIGN PROPERTIES against faithful mirrors of the small decision surface, NOT the shipped
// SwiftUI views directly (a standalone script cannot link the app target). The mirrors below MUST stay in
// lockstep with the shipped code they cite; the real proof the shipped code compiles/links is the Xcode build.

import Foundation

var failures = 0
func check(_ cond: Bool, _ label: String) {
    if cond { print("  ok   \(label)") } else { print("  FAIL \(label)"); failures += 1 }
}

// MARK: - A. renderable-id + bakesRatings(forID:) mirror (XRDBConfig / ERDBConfig / PosterArtwork)

/// Mirror of XRDB.renderableID: only tt… and tmdb: ids can be baked by the poster service.
func xrdbRenderable(_ id: String) -> Bool { id.hasPrefix("tt") || id.hasPrefix("tmdb:") }
/// Mirror of ERDB.renderableID: tt… plus the tmdb/tvdb/anime schemes.
func erdbRenderable(_ id: String) -> Bool {
    if id.hasPrefix("tt") { return true }
    for s in ["tmdb:", "tvdb:", "kitsu:", "anilist:", "mal:", "anidb:", "realimdb:"] where id.hasPrefix(s) { return true }
    return false
}
/// Mirror of PosterArtwork.bakesRatings(forID:): when ERDB is active it must render the id, else the VortX/XRDB
/// service must; a non-renderable id yields false.
func bakesRatingsForID(_ id: String, erdbActive: Bool, xrdbEnabled: Bool) -> Bool {
    if erdbActive { return erdbRenderable(id) }
    if xrdbEnabled { return xrdbRenderable(id) }
    return false
}
/// Mirror of PosterArtwork.bakesRatings (provider-level: any baker switched on).
func bakesRatings(erdbActive: Bool, xrdbEnabled: Bool) -> Bool { erdbActive || xrdbEnabled }

// MARK: - B. CardRatingBadge `active` gate (mirror of LandscapeArt.ratingBadge / LandscapeArtiOS.ratingBadge)

/// The exact expression both landscape views compute:
///   bakedPosterShown = !usedBackdrop && bakesRatings(forID:)
///   active           = bakesRatings && !bakedPosterShown
/// i.e. draw the client rating when the ratings feature is on AND the visible art is not itself a baked poster.
func badgeActive(usedBackdrop: Bool, id: String, erdbActive: Bool, xrdbEnabled: Bool) -> Bool {
    let bakedPosterShown = !usedBackdrop && bakesRatingsForID(id, erdbActive: erdbActive, xrdbEnabled: xrdbEnabled)
    return bakesRatings(erdbActive: erdbActive, xrdbEnabled: xrdbEnabled) && !bakedPosterShown
}

func testActiveGate() {
    print("B. CardRatingBadge active gate (landscape cards)")
    // DEFAULT install: XRDB enabled (poster.vortx.tv), ERDB off, landscape backdrop on screen.
    check(badgeActive(usedBackdrop: true, id: "tt0111161", erdbActive: false, xrdbEnabled: true),
          "default (XRDB on) + clean TMDB backdrop -> badge SHOWS (the CEO's case)")
    // Ratings feature fully off -> no client badge anywhere.
    check(!badgeActive(usedBackdrop: true, id: "tt0111161", erdbActive: false, xrdbEnabled: false),
          "ratings feature off -> badge hidden")
    // Rare no-backdrop fallback: the baked portrait poster IS on screen for a renderable id -> suppress (no double).
    check(!badgeActive(usedBackdrop: false, id: "tt0111161", erdbActive: false, xrdbEnabled: true),
          "baked poster fallback (renderable id) -> badge suppressed, no double badge")
    // No-backdrop fallback for a NON-renderable id: the shown poster is the raw add-on art (not baked) -> show.
    check(badgeActive(usedBackdrop: false, id: "hive:abc123", erdbActive: false, xrdbEnabled: true),
          "poster fallback for non-renderable id (raw art) -> badge SHOWS")
    // ERDB active also counts as a baker; a renderable id on the baked poster fallback -> suppress.
    check(!badgeActive(usedBackdrop: false, id: "tmdb:603", erdbActive: true, xrdbEnabled: false),
          "ERDB active + baked poster fallback -> suppressed")
    // ERDB active + backdrop on screen (backdrops are TMDB clean, never baked) -> show.
    check(badgeActive(usedBackdrop: true, id: "tmdb:603", erdbActive: true, xrdbEnabled: false),
          "ERDB active + clean backdrop -> badge SHOWS")
}

// MARK: - C. rating lookup + formatting (mirror of CardRatingStore.rating / CardRatingBadge.task gate)

/// Mirror of CardRatingStore's format: one decimal, matching the baked poster's IMDb badge.
func formatImdb(_ v: Double) -> String { String(format: "%.1f", v) }
/// Mirror of the `.task` gate + VortXRatingsClient.ratings id guard: only tt ids are looked up.
func fetchesRating(id: String, active: Bool) -> Bool { active && id.hasPrefix("tt") }

func testFormattingAndFetchGate() {
    print("C. rating formatting + fetch gate")
    check(formatImdb(7.0) == "7.0", "7.0 -> \"7.0\" (one-decimal round-trip)")
    check(formatImdb(8.34) == "8.3", "8.34 -> \"8.3\" (one decimal)")
    check(formatImdb(6.849) == "6.8", "6.849 -> \"6.8\"")
    check(fetchesRating(id: "tt0111161", active: true), "tt id + active -> looks up rating")
    check(!fetchesRating(id: "tt0111161", active: false), "inactive -> no network")
    check(!fetchesRating(id: "tmdb:603", active: true), "non-tt id -> no lookup (VortX ratings is imdb-only)")
    check(!fetchesRating(id: "kitsu:1", active: true), "kitsu id -> no lookup")
}

print("LandscapeCardRatingContractTests")
testActiveGate()
testFormattingAndFetchGate()
if failures == 0 { print("\nALL PASSED") } else { print("\n\(failures) FAILED"); exit(1) }
