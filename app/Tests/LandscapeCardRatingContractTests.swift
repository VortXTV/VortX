// Standalone checks for landscape-card rating placement and formatting.
// Run with `swift app/Tests/LandscapeCardRatingContractTests.swift`.

import Foundation

var failures = 0
@MainActor
func check(_ cond: Bool, _ label: String) {
    if cond { print("  ok   \(label)") } else { print("  FAIL \(label)"); failures += 1 }
}

@MainActor
func testCardArtworkIndependence() throws {
    let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let ios = try String(contentsOf: app.appendingPathComponent("SourcesiOS/iOSRootView.swift"), encoding: .utf8)
    let posterPolicy = try String(contentsOf: app.appendingPathComponent("SourcesShared/ERDBConfig.swift"), encoding: .utf8)
    let tv = try String(contentsOf: app.appendingPathComponent("SourcesTV/SharedUI.swift"), encoding: .utf8)
    let iosCard = ios.components(separatedBy: "private struct LandscapeArtiOS: View {")[1]
        .components(separatedBy: "struct CinemaPosterCardPresentation")[0]
    let tvCard = tv.components(separatedBy: "struct LandscapeArt: View {")[1]
        .components(separatedBy: "struct PosterCard: View {")[0]

    check(iosCard.contains("LandscapePosterFallback(image:"), "Mac/iOS fallback uses the framed poster renderer")
    check(iosCard.contains(".overlay(alignment: .topLeading)"), "Mac/iOS rating draws above the artwork")
    check(iosCard.contains("active: PosterArtwork.bakesRatings(forID: id) && !usesRatedPoster,"),
          "Mac/iOS suppress the native badge only for a displayed rated-renderer poster")
    check(iosCard.contains("visiblePoster?.url == request.ratedPoster"), "Mac/iOS compare the displayed candidate")
    check(iosCard.contains("PosterArtwork.landscapePosters("), "Mac/iOS use the shared fallback policy")
    check(tvCard.contains("LandscapePosterFallback(image:"), "tvOS fallback uses the framed poster renderer")
    check(tvCard.contains(".overlay(alignment: .topLeading) { ratingBadge }"), "tvOS rating draws above the artwork")
    check(tvCard.contains("active: PosterArtwork.bakesRatings,"), "tvOS rating activation follows settings")
    check(tvCard.contains("if let id, id.hasPrefix(\"tt\")"), "tvOS displays the native badge for supported titles")
    check(tvCard.contains("PosterArtwork.landscapePosters("), "tvOS uses the shared fallback policy")
    let policy = posterPolicy.components(separatedBy: "static func landscapePosters")[1]
        .components(separatedBy: "static func isWrappableRawArt")[0]
    check(policy.contains("ArtworkFallbackPolicy.candidates(originals + [metahub]), nil"),
          "IMDb card fallbacks use plain posters and leave ratings to the card")
    check(policy.contains("poster(id: id, fallback: nil)"), "other rated candidates keep the original art as a separate fallback")

    let grid = ios.components(separatedBy: "struct PosterGrid: View {")[1]
        .components(separatedBy: "struct iOSGroupHeader")[0]
    check(grid.contains("landscape: catalogPrefs.landscapeCards)"), "grid tracks follow the same orientation as the cards")
    check(!grid.contains("hasTMDB"), "grid track sizing does not depend on a custom TMDB key")
}

// Rating lookup and formatting mirrors

/// Mirror of CardRatingStore's format: one decimal, matching the baked poster's IMDb badge.
func formatImdb(_ v: Double) -> String { String(format: "%.1f", v) }
/// Mirror of the `.task` gate + VortXRatingsClient.ratings id guard: only tt ids are looked up.
func fetchesRating(id: String, active: Bool) -> Bool { active && id.hasPrefix("tt") }

@MainActor
func testFormattingAndFetchGate() {
    print("Rating formatting and lookup")
    check(formatImdb(7.0) == "7.0", "7.0 -> \"7.0\" (one-decimal round-trip)")
    check(formatImdb(8.34) == "8.3", "8.34 -> \"8.3\" (one decimal)")
    check(formatImdb(6.849) == "6.8", "6.849 -> \"6.8\"")
    check(fetchesRating(id: "tt0111161", active: true), "tt id + active -> looks up rating")
    check(!fetchesRating(id: "tt0111161", active: false), "inactive -> no network")
    check(!fetchesRating(id: "tmdb:603", active: true), "non-tt id -> no lookup (VortX ratings is imdb-only)")
    check(!fetchesRating(id: "kitsu:1", active: true), "kitsu id -> no lookup")
}

print("LandscapeCardRatingContractTests")
try testCardArtworkIndependence()
testFormattingAndFetchGate()
if failures == 0 { print("\nALL PASSED") } else { print("\n\(failures) FAILED"); exit(1) }
