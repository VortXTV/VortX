import Foundation

@main
enum CinemaRailLayoutTests {
    static func main() throws {
        for viewport: CGFloat in [280, 320, 393, 600, 768, 1024, 1440, 1980, 2560] {
            let width = CinemaRailLayout.episodeWidth(viewport: viewport, inset: 20, spacing: 20)
            precondition(width > 0 && width <= 340 && width <= viewport - 40)
            let visible = CinemaRailLayout.visibleEpisodes(viewport: viewport, cardWidth: width, inset: 20, spacing: 20)
            precondition(visible > 0)
            precondition(CGFloat(visible) * width + CGFloat(visible - 1) * 20 <= viewport - 40 + 0.01)
            for count in [0, 1, 2, 10, 1000] {
                for current in [0, 1, 9, 999] {
                    for direction in [-1, 1] {
                        let page = CinemaRailLayout.pageStart(current: current, direction: direction, visible: visible, count: count)
                        precondition(page >= 0 && page <= max(0, count - visible))
                    }
                }
            }
        }
        for viewport: CGFloat in [600, 768, 1024, 1180, 1440, 1980, 2560] {
            let grid = CinemaRailLayout.episodeGrid(viewport: viewport, inset: 20, spacing: 20)
            let row = CGFloat(grid.columns) * grid.cardWidth + CGFloat(grid.columns - 1) * 20
            precondition(abs(row - (viewport - 40)) < 0.01, "Grid rows fill the width exactly")
            precondition(grid.columns == 1 || grid.cardWidth >= 260, "Cards never shrink below the readable minimum")
            precondition(grid.cardWidth < 260 * 2 + 20, "Another column is added before a card doubles")
        }
        for size in [CGSize(width: 320, height: 568), CGSize(width: 393, height: 852),
                     CGSize(width: 600, height: 400), CGSize(width: 768, height: 1024),
                     CGSize(width: 1024, height: 600), CGSize(width: 1440, height: 900),
                     CGSize(width: 2880, height: 1800)] {
            let frame = CinemaRailLayout.quickViewFrame(viewport: size)
            precondition(frame.width > 0 && frame.height > 0)
            precondition(frame.width <= size.width && frame.height <= size.height,
                         "Preview never escapes a small window or landscape phone")
            precondition(frame.width <= 1180 && (size.width < 600 || frame.height <= 820),
                         "A large desktop keeps an intentional floating panel")
            if size.width < 600 {
                precondition(frame.width == size.width && frame.height == size.height,
                             "Phone content has the full available width and scrollable height")
            } else {
                precondition(frame.width < size.width && frame.height < size.height,
                             "Desktop and tablet preserve a visible catalogue behind the popup")
            }
        }
        func source(_ path: String) throws -> String { try String(contentsOfFile: path, encoding: .utf8) }
        let detail = try source("app/SourcesiOS/iOSDetailView.swift")
        let mac = detail.components(separatedBy: "private func macDetailBody(")[1]
            .components(separatedBy: "    #endif")[0]
        precondition(mac.components(separatedBy: "ScrollView {").count == 2, "One vertical scrolling region")
        precondition(mac.range(of: "ScrollView {")!.lowerBound < mac.range(of: "heroBanner(")!.lowerBound,
                     "Hero scrolls away so a full episode card can be seen")
        precondition(detail.contains("episodeList(viewportWidth: geo.size.width, pageProxy: proxy)"),
                     "Episode rail retains the live viewport and its parent scroll proxy")
        precondition(detail.contains("ScrollView(.horizontal, showsIndicators: true)"))
        precondition(detail.contains(".id(\"episode-rail-\\(season)\")"),
                     "Each season gets its own rail, so a season switch never inherits the old scroll offset")
        precondition(detail.contains("episodeRailFirstVisible = 0   // the fresh season rail starts at its first episode"))
        precondition(detail.contains("episodePageButton(forward: false") && detail.contains("episodePageButton(forward: true"))
        precondition(detail.contains("Actions for \\(episodeCoordinate(v))") && detail.contains("Mark as Unwatched"))
        let quickView = try source("app/SourcesiOS/CinemaPresentation.swift")
        precondition(quickView.contains("cinema-quick-view-close") && quickView.contains(".onTapGesture { presenter.close() }"))
        precondition(quickView.contains(".id(presentation.id)"), "New presentation retires an old title's state")
        precondition(quickView.contains("let requestedMembership = !isWatchlisted"))
        precondition(quickView.contains("present: requestedMembership, target: target"))
        let root = try source("app/SourcesiOS/iOSRootView.swift")
        let search = root.components(separatedBy: "struct iOSSearchView: View {")[1]
            .components(separatedBy: "struct iOSDiscoverView: View {")[0]
        precondition(search.contains("PosterRail(") && search.contains("CinemaSearchCollections(query: query)"))
        precondition(search.contains("core.prepareSearch(q)") && search.contains("core.suggestSearch(q)"))
        precondition(search.contains("iOSCategoryBrowse(target: target, path: $path)"))
        let tvSearch = try source("app/SourcesTV/SearchView.swift")
        precondition(tvSearch.contains("core.prepareSearch(value)"))
        print("PASS cinema layout: bounded complete episode cards, full-width paging, centered profiles, modal dismissal, native watchlist tap intent, live search rails")
    }
}
