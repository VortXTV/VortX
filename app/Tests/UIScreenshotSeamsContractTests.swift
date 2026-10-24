import Foundation

/// Source-level regression checks for the build264 Apple UI seams. The production SwiftUI views
/// remain the components under test; these assertions pin the exact layout/selection contracts
/// without requiring an app launch, provider state, or media fixture.
@main
enum UIScreenshotSeamsContractTests {
    static func main() throws {
        let root = try String(contentsOfFile: "app/SourcesiOS/iOSRootView.swift", encoding: .utf8)
        let detail = try String(contentsOfFile: "app/SourcesiOS/iOSDetailView.swift", encoding: .utf8)
        let featured = try String(contentsOfFile: "app/SourcesiOS/FeaturedHeroView.swift", encoding: .utf8)
        let topBar = root.components(separatedBy: "private var cinematicTopBar: some View {")[1]
            .components(separatedBy: "private var horizontalTabBar: some View {")[0]
        let home = root.components(separatedBy: "private var homeNavigation: some View {")[1]
            .components(separatedBy: "private var homeHistoryObservers")[0]
        let whitespaceFreeHome = String(home.filter { !$0.isWhitespace })
        let library = root.components(separatedBy: "struct iOSLibraryView: View {")[1]
            .components(separatedBy: "private struct iOSLibraryHubCard: View {")[0]
        let discover = root.components(separatedBy: "struct iOSDiscoverView: View {")[1]
            .components(separatedBy: "struct iOSDiscoverFilterPanel: View {")[0]
        let tabs = detail.components(separatedBy: "private var sourceAddonTabs: some View {")[1]
            .components(separatedBy: "@ViewBuilder\n    private func sourceAddonTab")[0]
        let sourceLabel = detail.components(separatedBy: "struct iOSStreamLabel: View {")[1]
            .components(separatedBy: "@ViewBuilder private func badge")[0]
        let episodeCard = detail.components(separatedBy: "struct CinemaEpisodeRailCard: View {")[1]
            .components(separatedBy: "// MARK: - Per-episode source list")[0]
        let rowStyle = detail.components(separatedBy: "private struct iOSSourceRowFocusStyle: ButtonStyle {")[1]
            .components(separatedBy: "struct iOSSourceList: View {")[0]
        let stepButton = tabs.components(separatedBy: "private func sourceAddonScrollButton")[1]
            .components(separatedBy: "@ViewBuilder")[0]

        precondition(whitespaceFreeHome.contains("homeFeaturedHero.scrollToTopAnchor()"),
                     "the hero itself remains the Home top-scroll target")
        precondition(!home.contains("Color.clear.frame(height: 0).scrollToTopAnchor()"),
                     "a zero-height LazyVStack sibling must not reserve spacing above Home art")
        precondition(home.contains("LazyVStack(alignment: .leading, spacing: Theme.Space.lg)"),
                     "normal Home rail spacing remains unchanged")

        precondition(tabs.contains("sourceAddonScrollButton(forward: false, proxy: proxy)")
                     && tabs.contains("sourceAddonScrollButton(forward: true, proxy: proxy)"),
                     "both bounded source-row scroll controls remain present")
        precondition(detail.components(separatedBy: "if groups.count > 1 { sourceAddonTabs }").count == 2
                     && !detail.contains("AddonFilterChip") && !detail.contains("private var filterBar"),
                     "one accent add-on row, under All sources, replaces the duplicate plain chip row")
        precondition(tabs.contains("ScrollView(.horizontal, showsIndicators: false)"),
                     "trackpad and swipe scrolling remain available")
        precondition(tabs.contains("ScrollViewReader { proxy in")
                     && tabs.contains(".id(SourceAddonTabAnchor.all)")
                     && tabs.contains(".id(SourceAddonTabAnchor.addon(group.id))")
                     && tabs.contains("groups.first(where: { $0.addon == addon })")
                     && tabs.contains("return .addon(group.id)")
                     && !tabs.contains(".id(SourceAddonTabAnchor.addon(group.addon))")
                     && tabs.contains(".onValueChange(of: selectedSourceAddon)")
                     && tabs.contains("proxy.scrollTo(sourceAddonTabAnchor(addon), anchor: .center)")
                     && tabs.contains("withAnimation(reduceMotion ? nil : Theme.Motion.state)"),
                     "selecting an offscreen source tab reveals it while honoring Reduce Motion")
        precondition(stepButton.contains("proxy.scrollTo(next == 0 ? SourceAddonTabAnchor.all : .addon(groups[next - 1].id), anchor: .leading)")
                     && !stepButton.contains("selectSourceAddon"),
                     "arrows scroll the All-first row for a mouse without changing the selection")
        precondition(tabs.contains(".disabled(disabled)"),
                     "previous and next controls expose disabled bounds")
        precondition(stepButton.contains(".frame(width: 34, height: 34)")
                     && stepButton.contains(".frame(width: 44, height: 44)"),
                     "source arrows remain visually compact inside a 44-point hit area")
        precondition(sourceLabel.contains("let flavors = compactLabels")
                     && sourceLabel.contains("let size = compactLabels ? StreamRanking.sizeText(stream) : nil"),
                     "hidden compact-only flavor and size labels are not parsed for every visible source row")
        precondition(episodeCard.contains(".vortxGlassTintedSurface(")
                     && episodeCard.contains("forceOpaque: reduceTransparency || accessibilityContrast == .increased"),
                     "episode cards use the accessibility-aware contained tinted-glass recipe")
        precondition(rowStyle.contains(".vortxGlassTintedSurface(")
                     && rowStyle.contains(".overlay(") && rowStyle.contains(".animation(reduceMotion ? nil"),
                     "source rows retain focus feedback while using the contained tinted-glass recipe")
        precondition(detail.contains(".id(\"cinema-source-list\")")
                     && detail.contains("private static let sourceWindowInitial = 100")
                     && detail.contains("private static let sourceWindowStep = 100")
                     && detail.contains("LazyVStack(spacing: Theme.Space.sm)"),
                     "large source sets stay lazy and incrementally windowed")
        precondition(!detail.contains("expandedHeight")
                     && detail.components(separatedBy: ".coordinateSpace(name: Self.detailScrollSpace)").count - 1 == 2
                     && detail.contains(".named(Self.detailScrollSpace)"),
                     "detail heroes show their whole image and both layouts keep the episode anchor's scroll space")
        precondition([root, detail, featured, library, discover].allSatisfy {
                        !$0.contains("cinemaHeroScrollOffsetTracking") && !$0.contains("CinemaDetailHeroScrollOffsetKey") }
                     && whitespaceFreeHome.contains("homeFeaturedHero.scrollToTopAnchor()"),
                     "heroes add no scroll-edge geometry readers; Home keeps its scroll-to-top anchor")
        precondition(!root.contains("CinemaNavigationArtworkBackground") && !topBar.contains("Theme.Palette.canvas")
                     && root.components(separatedBy: "CinemaNavigationShell {").count == 3,
                     "Mac and wide-iPad top bars float over scrolling content with no opaque backdrop")

        print("UI screenshot seam contracts passed")
    }
}
