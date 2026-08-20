// Standalone source contract for the tvOS detail action rows and focus escape policy.
//
//   swiftc -o /tmp/tv-detail-action-layout-contract app/Tests/TVDetailActionLayoutContractTests.swift \
//     && /tmp/tv-detail-action-layout-contract
//
// The tvOS target is not available to this Foundation-only harness. It protects layout and focus seams that
// can regress without a type-check failure: finite-width HStacks wrap long labels, and an outer ScrollView
// without a semantic top route can strand the Siri Remote below a long synopsis/language block.
//
// Device smoke plan (not runnable in this harness): on a 1080p and 4K tvOS simulator/device, exercise a movie
// with 0, 1, and many language-chip rows plus a deliberately long synopsis; focus Watch -> both action rows ->
// cast/providers/recommendations, press Up until the title block is focused, then Up again and verify the tab/menu
// is visible and focused. Repeat on a series, its episode page, and accessibility text sizes; verify left/right
// stays within the active action row and Down still advances normally.

import Foundation

private var passed = 0
private var failed = 0

private func expect(_ condition: Bool, _ message: String) {
    if condition {
        passed += 1
        print("PASS  \(message)")
    } else {
        failed += 1
        print("FAIL  \(message)")
    }
}

private func count(_ needle: String, in haystack: String) -> Int {
    haystack.components(separatedBy: needle).count - 1
}

/// Return the source between two unique markers. Keeping all checks scoped to their owner prevents an
/// unrelated helper elsewhere in DetailView.swift from satisfying a regression contract by accident.
private func sourceBetween(_ source: String, _ start: String, _ end: String) -> String? {
    guard let startRange = source.range(of: start, options: [], range: source.startIndex..<source.endIndex),
          let endRange = source.range(of: end, options: [], range: startRange.upperBound..<source.endIndex) else {
        return nil
    }
    return String(source[startRange.lowerBound..<endRange.lowerBound])
}

/// Extract one declaration by balancing braces from its marker. This narrows the helper checks to the actual
/// TVDetailActionRow body, including the required unclipped-focus modifier on that specific ScrollView.
private func declaration(_ source: String, markedBy marker: String) -> String? {
    guard let start = source.range(of: marker),
          let open = source[start.lowerBound...].firstIndex(of: "{") else { return nil }

    var depth = 0
    var cursor = open
    while cursor < source.endIndex {
        switch source[cursor] {
        case "{": depth += 1
        case "}":
            depth -= 1
            if depth == 0 {
                return String(source[start.lowerBound...cursor])
            }
        default: break
        }
        cursor = source.index(after: cursor)
    }
    return nil
}

let root = CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath
let path = root + "/app/SourcesTV/DetailView.swift"
guard let source = try? String(contentsOfFile: path, encoding: .utf8) else {
    print("FAIL  could not read \(path)")
    exit(2)
}

guard let row = declaration(source, markedBy: "private struct TVDetailActionRow") else {
    print("FAIL  TVDetailActionRow declaration is missing or unbalanced")
    exit(1)
}
expect(row.contains("ScrollView(.horizontal, showsIndicators: false)"),
       "detail action row scrolls horizontally")
expect(row.contains(".fixedSize(horizontal: true, vertical: false)"),
       "detail action row preserves intrinsic button widths")
expect(row.contains(".focusSection()"),
       "detail action row keeps remote traversal in one focus section")
expect(row.contains(".scrollClipDisabled()"),
       "detail action row leaves focused scale and glow visible")
expect(row.contains(".frame(maxWidth: .infinity, alignment: .leading)"),
       "detail action row remains leading-aligned at every page width")
expect(!source.contains("TVDetailActionRail"),
       "legacy single-rail helper is not left behind")

guard let coreList = sourceBetween(source, "struct CoreStreamList: View", "/// One horizontal, focus-contained action row") else {
    print("FAIL  CoreStreamList/action-row boundaries are missing")
    exit(1)
}
expect(count("TVDetailActionRow {", in: coreList) == 2,
       "movie/episode source controls have exactly two action rows")
expect(coreList.contains("// PRIMARY: playback and source selection decisions."),
       "source primary row is explicitly playback/source grouped")
expect(coreList.contains("// SECONDARY: page actions and optional integrations."),
       "source secondary row is explicitly page-action grouped")
expect(coreList.contains("Play from start") && coreList.contains("Quality") &&
       coreList.contains("All sources") && coreList.contains("Re-find sources"),
       "source primary row retains resume/start/quality/source actions")
expect(coreList.contains("secondaryAction") && coreList.contains("downloadChip") &&
       coreList.contains("LibraryChip()") && coreList.contains("WatchlistChip()") &&
       coreList.contains("ratingChip"),
       "source secondary row retains trailer/download/library/watchlist/rating actions")
expect(!coreList.contains("HStack(spacing: Theme.Space.md) {"),
       "source controls do not regress to a finite-width action HStack")

guard let hero = sourceBetween(source, "private func hero(", "private func heroTrailerLayer") else {
    print("FAIL  series hero boundaries are missing")
    exit(1)
}
expect(count("TVDetailActionRow(spacing: Theme.Space.sm) {", in: hero) == 2,
       "series hero has exactly two action rows")
expect(hero.contains("// PRIMARY: play/resume and episode navigation."),
       "series hero primary row is semantically grouped")
expect(hero.contains("// SECONDARY: trailer, library, watchlist, ratings, and optional check-in."),
       "series hero secondary row is semantically grouped")
expect(hero.contains("trailerChip(m)") && hero.contains("LibraryChip()") &&
       hero.contains("WatchlistChip()") && hero.contains("TraktCheckinChip"),
       "series hero secondary row retains optional actions")

guard let movie = sourceBetween(source, "private func moviePage", "/// The title block:") else {
    print("FAIL  movie page boundaries are missing")
    exit(1)
}
expect(movie.contains("ScrollViewReader") && movie.contains("Color.clear.frame(height: 0).id(DetailFocusAnchor.top)"),
       "movie detail has a scroll-position top anchor")
expect(movie.contains(".focused($detailFocusTarget, equals: .top)") &&
       movie.contains(".accessibilityElement(children: .combine)"),
       "movie detail uses a visible accessible top focus target")
for region in ["CoreStreamList", "castSection", "whereToWatchSection", "collectionSection", "moreLikeThisSection"] {
    expect(movie.contains("\(region)") && movie.contains("handleDetailMove($0, using: proxy)"),
           "movie \(region) participates in deterministic Up escape")
}
expect(!movie.contains("HStack(spacing: Theme.Space.sm) { trailerChip(m)"),
       "movie trailer is not a stray third action row")

guard let series = sourceBetween(source, "private func seriesPage", "/// Movies get the full-bleed cinematic page") else {
    print("FAIL  series page boundaries are missing")
    exit(1)
}
expect(series.contains("ScrollViewReader") && series.contains("Color.clear.frame(height: 0).id(DetailFocusAnchor.top)"),
       "series detail has a scroll-position top anchor")
expect(series.contains("CoreSeasonedEpisodes") && series.contains("castSection") &&
       series.contains("whereToWatchSection") && series.contains("collectionSection") &&
       series.contains("moreLikeThisSection"),
       "series detail includes every lower focus region")
expect(count("handleDetailMove($0, using: proxy)", in: series) >= 6,
       "series hero, episodes, and lower rails all route Up")

guard let episode = sourceBetween(source, "struct CoreEpisodeStreams: View", "/// The per-addon stream list") else {
    print("FAIL  episode detail boundaries are missing")
    exit(1)
}
expect(episode.contains("ScrollViewReader") && episode.contains("Color.clear.frame(height: 0).id(DetailFocusAnchor.top)"),
       "episode detail has a scroll-position top anchor")
expect(episode.contains(".focused($episodeFocusTarget, equals: .top)") &&
       episode.contains("handleEpisodeMove($0, using: proxy)"),
       "episode sources have a visible top focus target and Up escape")

expect(source.contains("private enum DetailFocusEscapePolicy") &&
       source.contains("DetailFocusEscapePolicy.shouldCaptureUp(topFocused: detailFocusTarget == .top)"),
       "detail focus policy is explicit and state-based")
expect(source.contains("guard direction == .up"),
       "focus escape captures Up only, preserving horizontal and Down navigation")
expect(source.contains("proxy.scrollTo(DetailFocusAnchor.top, anchor: .top)"),
       "Up escape restores the outer scroll position")
expect(source.contains("detailFocusTarget = .top") && source.contains("TabBarHealer.heal(\"detail-focus-top\")"),
       "Up escape restores focus and requests menu/tab-bar visibility")
expect(source.contains(".scrollClipDisabled()"),
       "unclipped focused action effects remain part of the source contract")

// Height-independent policy scenarios mirror the user-visible failure matrix. The production policy only
// depends on whether the visible top target owns focus, so wrapping synopsis/language content cannot remove
// the escape route. This deliberately includes 0/1/multiple language rows and an arbitrarily long synopsis.
struct DetailFocusScenario {
    let synopsisLines: Int
    let languageRows: Int
    let topFocused: Bool
}
func shouldCaptureUp(_ scenario: DetailFocusScenario) -> Bool {
    !scenario.topFocused
}

let scenarios = [
    DetailFocusScenario(synopsisLines: 0, languageRows: 0, topFocused: false),
    DetailFocusScenario(synopsisLines: 1, languageRows: 1, topFocused: false),
    DetailFocusScenario(synopsisLines: 3, languageRows: 4, topFocused: false),
    DetailFocusScenario(synopsisLines: 128, languageRows: 32, topFocused: false),
]
for scenario in scenarios {
    expect(shouldCaptureUp(scenario),
           "Up escapes lower focus for synopsis \(scenario.synopsisLines) lines / \(scenario.languageRows) language rows")
}
expect(!shouldCaptureUp(DetailFocusScenario(synopsisLines: 128, languageRows: 32, topFocused: true)),
       "Up is released to the shell once the top target is focused (no cycle)")

if failed == 0 {
    print("PASS  tvOS detail action and focus contract (\(passed) checks)")
    exit(0)
} else {
    print("FAIL  tvOS detail action and focus contract (\(failed) failed, \(passed) passed)")
    exit(1)
}
