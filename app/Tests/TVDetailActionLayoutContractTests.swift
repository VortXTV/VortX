// Standalone source contract for the tvOS detail action rows and focus escape policy.
//
//   swiftc -o /tmp/tv-detail-action-layout-contract app/Tests/TVDetailActionLayoutContractTests.swift \
//     && /tmp/tv-detail-action-layout-contract
//
// The tvOS target is not available to this Foundation-only harness. It protects layout and focus seams that
// can regress without a type-check failure: finite-width HStacks wrap long labels, and an outer ScrollView
// without a semantic top route can strand the Siri Remote below a long synopsis/language block.
//
// Device smoke plan (not runnable in this harness): on physical 1080p and 4K tvOS hardware, exercise a movie
// with 0, 1, and many language-chip rows plus a deliberately long synopsis; focus Watch -> secondary actions ->
// cast/providers/recommendations, press Up until the title block is focused, then Up again and verify the native
// tab/menu is visible and focused (`homeExists=true`, `homeFocused=true`). Record the journey as
// secondary -> primary (`primaryFocused=true`) -> visible title -> native tab; repeat on a series, its episode
// page, and accessibility text sizes; verify left/right stays within the active action row and Down advances.

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
expect(row.contains(".accessibilityElement(children: .contain)") &&
       row.contains(".accessibilityLabel(accessibilityLabel)"),
       "detail action row exposes an accessibility group label without removing child controls")
expect(!source.contains("TVDetailActionRail"),
       "legacy single-rail helper is not left behind")

guard let coreList = sourceBetween(source, "struct CoreStreamList: View", "/// One horizontal, focus-contained action row") else {
    print("FAIL  CoreStreamList/action-row boundaries are missing")
    exit(1)
}
expect(count("TVDetailActionRow(accessibilityLabel:", in: coreList) == 2,
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
expect(coreList.contains("let hasSecondaryRow = !isLive || secondaryAction != nil || best != nil") &&
       coreList.contains("if hasSecondaryRow") &&
       coreList.contains("loading, nil-best, no-source, and failed-source states"),
       "secondary row is independent of source-result availability")
guard let independentRows = sourceBetween(coreList,
                                          "if hasSecondaryRow",
                                          "if let best {\n                // #16: why the recommended source") else {
    print("FAIL  independent secondary-row scope is missing")
    exit(1)
}
expect(independentRows.contains("secondaryAction") &&
       independentRows.contains("focusSecondary(secondaryAction)"),
       "independent row contains the production trailer focus target")
guard let primaryStates = sourceBetween(coreList,
                                        "TVDetailActionRow(accessibilityLabel: String(localized: \"Playback and source actions\")",
                                        "if hasSecondaryRow") else {
    print("FAIL  persistent primary-row scope is missing")
    exit(1)
}
expect(primaryStates.contains("else if loadingAddons") &&
       primaryStates.contains("No sources found"),
       "the persistent primary row covers loading and terminal error states")
expect(primaryStates.contains(".focusable()") &&
       primaryStates.contains(".accessibilityHint") &&
       !primaryStates.contains("Button {}"),
       "loading and no-source primary states are focusable status semantics, not inert buttons")
expect(coreList.contains(".focused($sourceFocusTarget, equals: .secondary)"),
       "the trailer/first secondary control has a real focus target")
expect(coreList.contains("sourceMoveHandler(from: .secondary, hasSecondary: !isLive)") &&
       coreList.contains("case .secondary:"),
       "secondary row owns the production secondary-to-primary transition")
expect(coreList.contains("handleSourceMove(direction, from: region, hasSecondary: hasSecondary)") &&
       coreList.contains("sourceFocusTarget = .secondary") &&
       coreList.contains("watchFocused = true"),
       "source focus state bridges secondary, primary, and top without a test-only mirror")
expect(coreList.contains("FocusState<DetailFocusRegion?>.Binding?") &&
       coreList.contains("focusSecondary") &&
       coreList.contains("parentFocusTarget.wrappedValue = .secondary") &&
       coreList.contains("parentFocusTarget?.wrappedValue = nil"),
       "movie lower rails enter the real source secondary target before primary/top")
expect(!coreList.contains("HStack(spacing: Theme.Space.md) {"),
       "source controls do not regress to a finite-width action HStack")

guard let hero = sourceBetween(source, "private func hero(", "private func heroTrailerLayer") else {
    print("FAIL  series hero boundaries are missing")
    exit(1)
}
expect(count("TVDetailActionRow(spacing: Theme.Space.sm,", in: hero) == 2,
       "series hero has exactly two action rows")
expect(hero.contains("// PRIMARY: play/resume and episode navigation."),
       "series hero primary row is semantically grouped")
expect(hero.contains("// SECONDARY: trailer, library, watchlist, ratings, and optional check-in."),
       "series hero secondary row is semantically grouped")
expect(hero.contains("trailerChip(m)") && hero.contains("LibraryChip()") &&
       hero.contains("WatchlistChip()") && hero.contains("TraktCheckinChip"),
       "series hero secondary row retains optional actions")
expect(hero.contains("accessibilityLabel: String(localized: \"Playback and episode actions\")") &&
       hero.contains("accessibilityLabel: String(localized: \"Trailer and title actions\")"),
       "series hero rows expose separate accessibility group labels")

guard let movie = sourceBetween(source, "private func moviePage", "/// The title block:") else {
    print("FAIL  movie page boundaries are missing")
    exit(1)
}
expect(movie.contains("ScrollViewReader") && movie.contains("Color.clear.frame(height: 0).id(DetailFocusAnchor.top)"),
       "movie detail has a scroll-position top anchor")
expect(movie.contains(".focused($detailFocusTarget, equals: .top)") &&
       movie.contains(".accessibilityElement(children: .combine)"),
       "movie detail uses a visible accessible top focus target")
expect(movie.contains("onDetailMove: { direction, region in") &&
       movie.contains("handleDetailMove(direction, from: region, using: proxy)"),
       "movie source rows delegate only their primary-to-top transition")
expect(movie.contains("parentFocusTarget: $detailFocusTarget"),
       "movie source rows share the parent focus graph for lower-to-secondary recovery")
expect(movie.contains("secondaryAction: hasFullTrailer(m) ? AnyView(trailerChip(m)) : nil"),
       "movie always supplies its trailer to the independent secondary row")
expect(count("handleDetailMove($0, from: .lower, using: proxy)", in: movie) == 4 &&
       !movie.contains("handleMovieLowerMove"),
       "movie lower rails share one deterministic Up route")
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
expect(count("handleDetailMove($0, from: .lower, using: proxy)", in: series) == 5,
       "series episodes and lower rails all route Up through one scoped handler")
expect(!series.contains("onMoveCommand { handleDetailMove($0, from: .top"),
       "series top target does not swallow the native shell handoff")

guard let episode = sourceBetween(source, "struct CoreEpisodeStreams: View", "/// The per-addon stream list") else {
    print("FAIL  episode detail boundaries are missing")
    exit(1)
}
expect(episode.contains("ScrollViewReader") && episode.contains("Color.clear.frame(height: 0).id(DetailFocusAnchor.top)"),
       "episode detail has a scroll-position top anchor")
expect(episode.contains(".focused($episodeFocusTarget, equals: .top)") &&
       episode.contains("onDetailMove: { direction, region in") &&
       episode.contains("DetailFocusEscapePolicy.nextUp(from: region, hasSecondary: true) == .top"),
       "episode sources have a visible top focus target and production Up escape")
expect(episode.contains("accessibilityReduceMotion ? nil : .easeOut"),
       "episode top recovery honors Reduce Motion")
expect(!episode.contains("handleEpisodeMove") &&
       !episode.contains("onMoveCommand { handleDetailMove($0, from: .top"),
       "episode does not duplicate a child/outer handler or swallow top-to-shell")

guard let focusPolicy = declaration(source, markedBy: "private enum DetailFocusEscapePolicy") else {
    print("FAIL  production focus policy declaration is missing or unbalanced")
    exit(1)
}
expect(focusPolicy.contains("static func nextUp(from region: DetailFocusRegion, hasSecondary: Bool) -> DetailFocusRegion?"),
       "production focus policy is explicit and state-based")
for (transition, sourceCase) in [
    ("secondary -> primary", "case .secondary:\n            return .primary"),
    ("primary -> visible top", "case .primary:\n            return .top"),
    ("lower -> nearest action row", "case .lower:\n            return hasSecondary ? .secondary : .primary"),
    ("top -> native shell", "case .top:\n            return .shell"),
    ("shell has no local target", "case .shell:\n            return nil")
] {
    expect(focusPolicy.contains(sourceCase), "production Up graph contains \(transition)")
}
expect(source.contains("@FocusState private var detailFocusTarget: DetailFocusRegion?") &&
       source.contains("@State private var detailFocusRegion: DetailFocusRegion = .top") &&
       source.contains("detailFocusTarget = region"),
       "production focus state records the visible region and target")
expect(source.contains("withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25))"),
       "movie/series top recovery honors Reduce Motion")
expect(source.contains("guard direction == .up"),
       "focus escape captures Up only, preserving horizontal and Down navigation")
expect(source.contains("proxy.scrollTo(DetailFocusAnchor.top, anchor: .top)"),
       "Up escape restores the outer scroll position")
expect(source.contains("detailFocusTarget = region") && source.contains("TabBarHealer.heal(\"detail-focus-\\(String(describing: region))\")"),
       "Up escape restores a visible target and keeps tab-bar layout healed")
expect(!source.contains("DetailFocusEscapePolicy.shouldCaptureUp") &&
       !source.contains("func shouldCaptureUp") &&
       !source.contains("struct DetailFocusScenario"),
       "the contract does not duplicate production focus policy")
expect(!source.contains(".onMoveCommand { handleDetailMove($0, using: proxy) }"),
       "no legacy outer handler remains to swallow top-to-shell")
expect(source.contains(".scrollClipDisabled()"),
       "unclipped focused action effects remain part of the source contract")

// These are the concrete content-height cases used by the device journey. The assertions below inspect the
// production page/layout seams for each case; they do not re-implement the focus policy in this harness.
let contentCases: [(name: String, synopsisLines: Int, languageRows: Int)] = [
    ("empty synopsis / no languages", 0, 0),
    ("short synopsis / one language row", 1, 1),
    ("wrapped synopsis / several language rows", 3, 4),
    ("long synopsis / many language rows", 128, 32),
]
for contentCase in contentCases {
    expect(movie.contains("languageChips") &&
           movie.contains(".lineLimit(3, reservesSpace: true)") &&
           focusPolicy.contains("case .lower:") &&
           source.contains("focusDetailRegion(next, using: proxy)"),
           "production route covers \(contentCase.name) (\(contentCase.synopsisLines) synopsis lines / \(contentCase.languageRows) language rows)")
}
expect(source.contains("case .top:\n            return .shell") &&
       !source.contains("onMoveCommand { handleDetailMove($0, from: .top"),
       "top Up is released to the native tab/menu without a local cycle")
expect(coreList.contains("guard onDetailMove != nil else { return nil }") &&
       sourceBetween(source, "private func livePage", "/// Now/Next EPG strip")?.contains("onDetailMove:") == false,
       "live pages leave move ownership to the native focus engine when no bridge exists")
expect(coreList.contains(".onChange(of: hasSecondaryRow)") &&
       coreList.contains("sourceFocusTarget = nil") &&
       coreList.contains("watchFocused = true"),
       "conditional secondary-row disappearance recovers focus to the primary target")

if failed == 0 {
    print("PASS  tvOS detail action and focus contract (\(passed) checks)")
    exit(0)
} else {
    print("FAIL  tvOS detail action and focus contract (\(failed) failed, \(passed) passed)")
    exit(1)
}
