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
        let rootChrome = root.components(separatedBy: "private struct CinemaNavigationArtworkBackground: View {")[1]
            .components(separatedBy: "/// The Apple TV visual hierarchy adapted")[0]
        let home = root.components(separatedBy: "private var homeNavigation: some View {")[1]
            .components(separatedBy: "private var homeHistoryObservers")[0]
        let whitespaceFreeHome = String(home.filter { !$0.isWhitespace })
        let library = root.components(separatedBy: "struct iOSLibraryView: View {")[1]
            .components(separatedBy: "private struct iOSLibraryHubCard: View {")[0]
        let discover = root.components(separatedBy: "struct iOSDiscoverView: View {")[1]
            .components(separatedBy: "struct iOSDiscoverFilterPanel: View {")[0]
        let tabs = detail.components(separatedBy: "private var sourceAddonTabs: some View {")[1]
            .components(separatedBy: "@ViewBuilder\n    private func sourceAddonTab")[0]
        let chip = detail.components(separatedBy: "private struct AddonFilterChip: View {")[1]
            .components(separatedBy: "/// Add-on names are the primary Cinema source navigation")[0]
        let sourceLabel = detail.components(separatedBy: "struct iOSStreamLabel: View {")[1]
            .components(separatedBy: "@ViewBuilder private func badge")[0]
        let episodeCard = detail.components(separatedBy: "struct CinemaEpisodeRailCard: View {")[1]
            .components(separatedBy: "// MARK: - Per-episode source list")[0]
        let rowStyle = detail.components(separatedBy: "private struct iOSSourceRowFocusStyle: ButtonStyle {")[1]
            .components(separatedBy: "struct iOSSourceList: View {")[0]
        let scrollTracking = root.components(separatedBy: "struct CinemaHeroScrollOffsetTracking: ViewModifier {")[1]
            .components(separatedBy: "/// Mutable presentation data")[0]
        func owningHeroScrollHasNamedSpace(_ source: String) -> Bool {
            guard let scroll = source.range(of: "ScrollView {")?.lowerBound,
                  let hero = source.range(of: "FeaturedHeroView(model: hero, onOpen: { path.append($0) })")?.lowerBound,
                  let space = source.range(of: ".coordinateSpace(name: CinemaDetailHeroScrollOffsetKey.coordinateSpace)")?.lowerBound
            else { return false }
            return scroll < hero && hero < space
        }
        let stepButton = tabs.components(separatedBy: "private func sourceAddonStepButton")[1]
            .components(separatedBy: "@ViewBuilder")[0]

        precondition(whitespaceFreeHome.contains("homeFeaturedHero.scrollToTopAnchor()"),
                     "the hero itself remains the Home top-scroll target")
        precondition(!home.contains("Color.clear.frame(height: 0).scrollToTopAnchor()"),
                     "a zero-height LazyVStack sibling must not reserve spacing above Home art")
        precondition(home.contains("LazyVStack(alignment: .leading, spacing: Theme.Space.lg)"),
                     "normal Home rail spacing remains unchanged")

        precondition(tabs.contains("sourceAddonStepButton(forward: false)")
                     && tabs.contains("sourceAddonStepButton(forward: true)"),
                     "both bounded source-tab controls remain present")
        precondition(tabs.contains("ScrollView(.horizontal, showsIndicators: false)"),
                     "trackpad and swipe scrolling remain available")
        precondition(tabs.contains("ScrollViewReader { proxy in")
                     && tabs.contains(".id(SourceAddonTabAnchor.all)")
                     && tabs.contains(".id(SourceAddonTabAnchor.addon(group.id))")
                     && tabs.contains("groups.first(where: { $0.addon == addon })")
                     && tabs.contains("return .addon(group.id)")
                     && !tabs.contains(".id(SourceAddonTabAnchor.addon(group.addon))")
                     && tabs.contains(".onChange(of: selectedSourceAddon)")
                     && tabs.contains("proxy.scrollTo(sourceAddonTabAnchor(addon), anchor: .center)")
                     && tabs.contains("withAnimation(reduceMotion ? nil : Theme.Motion.state)"),
                     "selecting an offscreen source tab reveals it while honoring Reduce Motion")
        precondition(tabs.contains("selectSourceAddon(next == 0 ? nil : groups[next - 1].addon)"),
                     "tab stepping uses the existing All-first group order and selection path")
        precondition(tabs.contains(".disabled(disabled)"),
                     "previous and next controls expose disabled bounds")
        precondition(stepButton.contains(".frame(width: 28, height: 28)")
                     && stepButton.contains(".frame(width: 44, height: 44)"),
                     "source arrows remain visually compact inside a 44-point hit area")
        precondition(chip.contains(".vortxGlassChip(selected: selected)"),
                     "selected filters use the shared muted tinted-glass chip treatment")
        precondition(!chip.contains("Capsule().fill(selected ? Theme.Palette.accent"),
                     "selected filters do not become a solid accent slab")
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
        precondition(root.contains("heroFrame.frame(in: .named(CinemaDetailHeroScrollOffsetKey.coordinateSpace)).minY")
                     && detail.contains(".frame(height: CinemaArtworkGeometry.expandedHeight(band: height, navigation: navigationArtworkInset))")
                     && detail.contains(".offset(y: -navigationArtworkInset)"),
                     "the real detail hero reports its scroll edge while preserving the shared origin crop")
        precondition(detail.components(separatedBy: ".cinemaHeroScrollOffsetTracking(enabled: navigationArtworkInset > 0)").count - 1 == 4
                     && scrollTracking.contains("if enabled") && scrollTracking.contains("GeometryReader")
                     && scrollTracking.contains("else {\n            content"),
                     "macOS and top-navigation iPad hero branches report offsets while compact phones add no geometry reader")
        precondition(featured.contains(".cinemaHeroScrollOffsetTracking(enabled: navigationArtworkInset > 0)")
                     && whitespaceFreeHome.contains("homeFeaturedHero.scrollToTopAnchor()")
                     && whitespaceFreeHome.contains(".coordinateSpace(name:CinemaDetailHeroScrollOffsetKey.coordinateSpace)"),
                     "Home's real moving hero reports through its owning scroll view only when the top artwork copy exists")
        precondition(owningHeroScrollHasNamedSpace(library) && owningHeroScrollHasNamedSpace(discover),
                     "Library and Discover heroes report through the same actual owning scroll views")
        precondition(root.contains("@State private var navigationArtwork = CinemaNavigationArtworkPresentation()")
                     && root.contains("navigationArtwork.updateDetailHero(minY: minY, navigationHeight: navigationHeight)")
                     && rootChrome.contains("@ObservedObject var presentation")
                     && rootChrome.contains("Theme.Palette.canvas.opacity(1 - presentation.detailHeroOpacity)"),
                     "detail scroll fade redraws only the navigation artwork leaf, not root-owned SwiftUI state")

        print("UI screenshot seam contracts passed")
    }
}
