import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Native iOS root: a CUSTOM bottom-tab shell over the shared engine. A native `TabView` collapses
/// the 5th+ tabs into a system "More" tab on iPhone, burying Add-ons and Settings; instead we drive
/// the visible screen with a `@State` selection and render our own brand-styled bar so all SEVEN tabs
/// stay visible at once (matching the tvOS pill bar). Surfaces are filled in one at a time during the
/// 0.3.0 rebase; Home is the first real one (poster rails from CoreBridge).
struct iOSRootView: View {
    /// The seven destinations, in display order: Home · Discover · Live · Library · Search · Add-ons
    /// · Settings (Live sits after Discover; Add-ons beside Settings, mirroring tvOS).
    private enum Tab: Int, CaseIterable {
        case home, discover, live, library, search, addons, settings

        var title: String {
            // Localized: rendered via Text(item.title) and used as accessibility labels, where a plain
            // String does NOT auto-localize (only Text("literal")/LocalizedStringKey does). String(localized:)
            // routes the value through the String Catalog at runtime AND gets the key extracted into it.
            switch self {
            case .home: return String(localized: "Home")
            case .discover: return String(localized: "Discover")
            case .live: return String(localized: "Live")
            case .library: return String(localized: "Library")
            case .search: return String(localized: "Search")
            case .addons: return String(localized: "Add-ons")
            case .settings: return String(localized: "Settings")
            }
        }

        var icon: String {
            switch self {
            case .home: return "house.fill"
            case .discover: return "safari.fill"
            case .live: return "dot.radiowaves.left.and.right"
            case .library: return "books.vertical.fill"
            case .search: return "magnifyingglass"
            case .addons: return "puzzlepiece.extension.fill"
            case .settings: return "gearshape.fill"
            }
        }

        /// The unfilled twin of `icon`, shown when the tab is inactive so the active tab reads as
        /// filled-and-tinted against outline neighbours (#22). Symbols without a fill variant (Live's
        /// waves, Search's glass) keep their single glyph.
        var inactiveIcon: String {
            switch self {
            case .home: return "house"
            case .discover: return "safari"
            case .library: return "books.vertical"
            case .addons: return "puzzlepiece.extension"
            case .settings: return "gearshape"
            case .live, .search: return icon
            }
        }

        /// A stable key for the shared scroll-to-top signal (re-tapping an active tab scrolls it up).
        /// Kept as a plain string so `TabScrollToTop` never has to know about this platform's `Tab` type.
        var scrollKey: String {
            switch self {
            case .home: return TabScrollKeys.home
            case .discover: return TabScrollKeys.discover
            case .live: return TabScrollKeys.live
            case .library: return TabScrollKeys.library
            case .search: return TabScrollKeys.search
            case .addons: return TabScrollKeys.addons
            case .settings: return TabScrollKeys.settings
            }
        }
    }

    @State private var tab: Tab = .home
    /// First-visit lazy mount (#24): a tab's screen is built only once it has been SELECTED at least
    /// once, then stays mounted (opacity-switched) so its state survives switches exactly as before.
    /// Launch no longer pays for ~6 unvisited screens' engine subscriptions, heroes, and image loads.
    @State private var visitedTabs: Set<Int> = [Tab.home.rawValue]
    #if os(macOS)
    /// macOS keyboard browse: the focused bottom tab-strip item (its own focus space, traversed with
    /// Left/Right and Tab; Enter switches to it). nil = no tab in the strip is focused. Keyed by raw value.
    @FocusState private var tabFocus: MacBrowseFocus?
    /// The persistent top-bar search field's text (macOS only; submits into the search flow).
    @State private var macQuery = ""
    /// Focus for the top-bar search field so ⌘F (menu "Go ▸ Search") lands the cursor in it.
    @FocusState private var macSearchFocused: Bool
    #endif
    /// A new release found by the once-per-foreground check, surfaced as a prominent top banner so users
    /// learn about it without opening Settings. Dismissing it remembers the version, so it reappears only
    /// when a still-newer build ships.
    @ObservedObject private var updates = UpdateChecker.shared
    #if !os(tvOS)
    /// Offline downloads (#30), observed so the Library tab can carry a live count badge of in-flight
    /// downloads — the persistent "downloads are running, find them here" signal away from the detail page.
    @ObservedObject private var downloads = DownloadStore.shared
    #endif
    @AppStorage("stremiox.update.dismissedVersion") private var dismissedUpdateVersion = ""
    /// Hide the Live TV tab for users who do not use it (Settings toggle). The Live screen is not mounted
    /// and the tab is dropped from the bar; selection falls back to Home if it was on Live.
    @AppStorage("stremiox.hideLiveTab") private var hideLiveTab = false
    /// Merge Discover + Search into one surface (Settings toggle, default OFF, reversible). When ON the
    /// Search tab is dropped from the bar and Discover hosts an inline search field; OFF keeps them separate.
    @AppStorage("vortx.mergeDiscoverSearch") private var mergeDiscoverSearch = false
    @Environment(\.openURL) private var openURL

    /// Whether a tab's screen should be mounted: only after its first selection (#24). The active tab
    /// is always mounted (covers the initial Home and any programmatic switch before onChange lands).
    private func isMounted(_ item: Tab) -> Bool {
        tab == item || visitedTabs.contains(item.rawValue)
    }

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            // Persistent brand + search strip across the whole window (in-content SwiftUI, NEVER a
            // toolbar/NSToolbar, which is the Beta 7 crash class). Fills the black full-size-content
            // band under the hidden titlebar: wordmark left of center, search right, with a leading
            // inset clearing the floating traffic lights.
            macTopBar
            #endif
            // Selected screen fills the space above the bar. Screens mount LAZILY on first visit (#24)
            // and then stay in this ZStack so each screen's own state (scroll position, search query,
            // engine subscriptions) survives a tab switch instead of being torn down and rebuilt.
            ZStack {
                // `isActive` gates each browse screen's `.principal` wordmark: on macOS a principal
                // toolbar item is hoisted into the shared window titlebar, and every mounted
                // NavigationStack would otherwise stamp its own — tiling "StremioX" once per screen.
                // Only the visible tab contributes its wordmark (#46 regression).
                iOSHomeView(isActive: tab == .home).opacity(tab == .home ? 1 : 0)
                if isMounted(.discover) { iOSDiscoverView(isActive: tab == .discover).opacity(tab == .discover ? 1 : 0) }
                if !hideLiveTab, isMounted(.live) { iOSLiveView().opacity(tab == .live ? 1 : 0) }
                if isMounted(.library) { iOSLibraryView(isActive: tab == .library).opacity(tab == .library ? 1 : 0) }
                if !mergeDiscoverSearch, isMounted(.search) { iOSSearchView(isActive: tab == .search).opacity(tab == .search ? 1 : 0) }
                if isMounted(.addons) { AddonsView().opacity(tab == .addons ? 1 : 0) }
                if isMounted(.settings) { iOSSettingsView().opacity(tab == .settings ? 1 : 0) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            customTabBar
        }
        .onChange(of: tab) { visitedTabs.insert($0.rawValue) }   // lazy mount: remember every visit (#24)
        .safeAreaInset(edge: .top, spacing: 0) { updateBanner }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .tint(Theme.Palette.accent)
        .animation(.easeOut(duration: 0.25), value: updates.available?.build)
        .animation(.easeOut(duration: 0.25), value: dismissedUpdateVersion)
        // What's New is no longer shown on launch; it lives in Settings > What's New (the full changelog).
        // Automatic update popup: appears once per launch when a newer build exists (and again when the
        // hourly re-check finds a still-newer one), so users learn about updates without opening Settings.
        .sheet(item: $updates.prompt) { release in
            UpdatePromptView(release: release) { updates.dismissPrompt() }
        }
        .onChange(of: hideLiveTab) { hidden in
            if hidden, tab == .live { tab = .home }   // never leave the bar pointing at a hidden screen
        }
        .onChange(of: mergeDiscoverSearch) { merged in
            // Search folds into Discover: if the bar was pointing at the now-hidden Search tab, land on Discover.
            if merged, tab == .search { tab = .discover }
        }
        .onAppear {
            updates.startMonitoring()   // launch check + hourly re-check while open
        }
        #if os(macOS)
        // macOS menu-bar commands (the "Go" menu + ⌘-shortcuts) post here, since they live at the
        // Scene level and can't set this @State directly. The raw value mirrors Tab's order.
        .onReceive(NotificationCenter.default.publisher(for: MacCommands.tabRequest)) { note in
            guard let raw = note.userInfo?["tab"] as? Int, let dest = Tab(rawValue: raw) else { return }
            // ⌘F lands the cursor in the persistent top-bar search field. In merged mode the
            // standalone Search tab does not exist, so route to Discover (submit searches there).
            if dest == .search {
                macSearchFocused = true
                tab = mergeDiscoverSearch ? .discover : .search
                return
            }
            tab = dest
        }
        #endif
    }

    #if os(macOS)
    /// The persistent macOS top strip: brand wordmark left, an always-visible search field right. Pure
    /// in-content SwiftUI, NEVER `.toolbar`/`.searchable`/`navigationTitle`, which bridge into the
    /// shared window NSToolbar and crash (`_insertNewItemWithItemIdentifier`, the Beta 7 class). The
    /// leading inset clears the floating traffic lights over the hidden titlebar's full-size content.
    private var macTopBar: some View {
        HStack(spacing: Theme.Space.md) {
            VortXWordmark(fontSize: 20)
            Spacer(minLength: Theme.Space.md)
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textSecondary)
                TextField(text: $macQuery) {
                    Text("Search movies or series").foregroundStyle(Theme.Palette.textTertiary)
                }
                .textFieldStyle(.plain)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textPrimary)
                .focused($macSearchFocused)
                .onSubmit { submitMacSearch() }
                if !macQuery.isEmpty {
                    Button {
                        macQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.Palette.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, Theme.Space.sm)
            .padding(.vertical, 5)
            .frame(maxWidth: 340)
            .background(Theme.Palette.surface1, in: Capsule())
            .overlay(Capsule().stroke(Theme.Palette.surface2, lineWidth: 1))
        }
        // 84pt leading clears the traffic lights (~70pt of buttons + breathing room) restored by
        // MacWindowChrome over the hidden titlebar.
        .padding(.leading, 84)
        .padding(.trailing, Theme.Space.md)
        .frame(height: 52)
        .frame(maxWidth: .infinity)
        .background {
            Theme.Palette.canvas
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Theme.Palette.hairline).frame(height: 0.5)
                }
                .ignoresSafeArea(edges: .top)
        }
    }

    /// Submit the top-bar query into the engine search flow: hand it to `MacSearchBridge` (consumed by
    /// the Search tab, or Discover in merged mode, possibly mounting for the first time) and switch there.
    private func submitMacSearch() {
        let q = macQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        MacSearchBridge.shared.pending = q
        tab = mergeDiscoverSearch ? .discover : .search
    }
    #endif

    /// Brand-styled bottom bar: seven equal items, each a small SF Symbol over a caption label. The
    /// selected item is tinted with the app accent; the rest read as tertiary text. A hairline +
    /// surface fill separates it from the content, and it respects the safe-area bottom inset.
    /// Tabs shown in the bar; the Live tab is dropped when the user hides it in Settings.
    private var visibleTabs: [Tab] {
        Tab.allCases.filter {
            if hideLiveTab, $0 == .live { return false }
            // Merged mode folds Search into Discover, so drop the standalone Search tab.
            if mergeDiscoverSearch, $0 == .search { return false }
            return true
        }
    }

    private var customTabBar: some View {
        HStack(spacing: 0) {
            ForEach(visibleTabs, id: \.rawValue) { item in
                tabButton(item)
            }
        }
        #if os(macOS)
        // Group the tab items so native directional focus walks Left/Right across the strip; Tab / Full
        // Keyboard Access reaches it via the standard key-view loop. Enter on a focused tab switches to it.
        .focusSection()
        #endif
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tabs")
        .padding(.top, Theme.Space.xs)
        .background(alignment: .top) {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(Theme.Palette.hairline)
                    .frame(height: 0.5)
                Theme.Palette.surface1
            }
            .ignoresSafeArea(edges: .bottom)
        }
    }

    /// Prominent accent bar shown across every tab when a newer release is available and not yet
    /// dismissed for that version. Tapping opens the downloads page; the × remembers this version.
    @ViewBuilder private var updateBanner: some View {
        // Suppress while the modal popup is pending so the user isn't nagged twice; the banner is the quiet
        // fallback for after the popup is dismissed (dismissing it sets dismissedUpdateVersion, so the banner
        // then stays hidden for that build too).
        if let u = updates.available, u.key != dismissedUpdateVersion, updates.prompt == nil {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill").font(.system(size: 18, weight: .semibold))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Update available").font(.system(size: 14, weight: .semibold))
                    Text("\(u.name) · tap to get it")
                        .font(.system(size: 12)).foregroundStyle(Theme.Palette.onAccent.opacity(0.85)).lineLimit(1)
                }
                Spacer(minLength: 8)
                Button { dismissedUpdateVersion = u.key } label: {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .bold))
                        .padding(8).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss update notice")
            }
            .foregroundStyle(Theme.Palette.onAccent)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Theme.Palette.accent)
            .contentShape(Rectangle())
            .onTapGesture { openReleasesPage() }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Update available: \(u.name). Opens the downloads page.")
            .accessibilityAddTraits(.isButton)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    /// Open the GitHub releases page (where the signed IPA / dmg lives) in the browser. Cross-platform
    /// via SwiftUI's openURL, so no UIKit/AppKit import is needed here.
    private func openReleasesPage() {
        guard let url = URL(string: "https://github.com/VortXTV/VortX/releases/latest") else { return }
        openURL(url)
    }

    #if !os(tvOS)
    /// Number of downloads currently in flight (state == .downloading), driving the Library tab badge so
    /// the user can see work is running and where it lives. Excludes completed/failed/queued/paused.
    private var activeDownloadCount: Int {
        downloads.records.reduce(0) { $0 + ($1.state == .downloading ? 1 : 0) }
    }

    /// A small accent notification badge carrying the active-download count, overlaid on the Library tab.
    /// Subtle by design: the ember accent circle with onAccent ink, capped at "9+" so a long queue stays
    /// a compact pill. Offset up-and-out so it reads as a badge on the glyph rather than over it.
    private func downloadCountBadge(_ count: Int) -> some View {
        Text(count > 9 ? "9+" : "\(count)")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(Theme.Palette.onAccent)
            .padding(.horizontal, 5)
            .frame(minWidth: 16, minHeight: 16)
            .background(Theme.Palette.accent, in: Capsule())
            .offset(x: 6, y: -6)
            .accessibilityLabel("\(count) active downloads")
    }
    #endif

    private func tabButton(_ item: Tab) -> some View {
        let selected = tab == item
        let base = Button {
            // Re-tapping the ALREADY-active tab scrolls that screen to the top (a per-tab signal the
            // mounted screen observes); tapping an inactive tab just switches to it as before.
            if selected {
                TabScrollToTop.shared.bump(item.scrollKey)
            } else {
                tab = item
            }
        } label: {
            VStack(spacing: 3) {
                // Active tab: filled glyph in an accent-soft capsule so the selection reads at a
                // glance; inactive tabs are an outline glyph with no pill (#22).
                Image(systemName: selected ? item.icon : item.inactiveIcon)
                    .font(.system(size: 20, weight: .semibold))
                    .frame(height: 22)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 2)
                    .background {
                        if selected {
                            Capsule().fill(Theme.Palette.accent.opacity(0.18))
                        }
                    }
                    // #30: a small accent count badge on the Library tab while downloads are in flight, so
                    // the user knows work is running and where to find it. Hidden when zero / on other tabs.
                    #if !os(tvOS)
                    .overlay(alignment: .topTrailing) {
                        if item == .library, activeDownloadCount > 0 {
                            downloadCountBadge(activeDownloadCount)
                        }
                    }
                    #endif
                Text(item.title)
                    .font(.system(size: 11, weight: selected ? .semibold : .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(selected ? Theme.Palette.accent : Theme.Palette.textTertiary)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        .accessibilityHint("Switches to \(item.title) tab")
        .accessibilityAddTraits(selected ? [.isSelected] : [])

        #if os(macOS)
        // macOS keyboard browse: each tab item is focusable so arrows/Tab walk the strip and the focus
        // ring shows where you are; Enter fires the Button (switches tab). Additive + gated, so iOS is
        // unchanged. The ring uses the control radius (the pill is capsule-ish at this small size).
        return base
            .focusable()
            .focused($tabFocus, equals: .tab(item.rawValue))
            .macFocusRing(tabFocus == .tab(item.rawValue), cornerRadius: Theme.Radius.control)
        #else
        return base
        #endif
    }
}

/// Home: Continue Watching + each installed catalog as a horizontal poster rail, from the shared
/// engine, under the interactive featured hero. Signed-out shows a sign-in prompt; the rails populate
/// as the engine hydrates.
struct iOSHomeView: View {
    /// True only when this is the visible tab — gates the macOS window-titlebar wordmark (#46).
    var isActive: Bool = true
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var account: StremioAccount
    @EnvironmentObject private var theme: ThemeManager   // observe textScale so Theme.Typography repaints live
    @EnvironmentObject private var profiles: ProfileStore   // gate Continue Watching on the active profile's own history
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showSignIn = false
    @StateObject private var hero = FeaturedHeroModel()
    @StateObject private var topPicks = TopPicksModel()   // local recommendations from this profile's history
    @StateObject private var releaseCalendar = ReleaseCalendarModel()   // "Upcoming Episodes" from the series library (next 45 days)
    @StateObject private var curated = CuratedCollectionsModel()   // editorial Cinemeta-backed rails (B3)
    @AppStorage("vortx.home.showCuratedRails") private var showCuratedRails = true   // owner-toggleable: hide the built-in editorial rails
    @ObservedObject private var collectionsHub = CollectionsHubModel.shared   // Collections hub (shared singleton)
    @AppStorage("vortx.home.showCollectionsHub") private var showCollectionsHub = true   // toggle the hub on Home (needs a TMDB key)
    @State private var path = NavigationPath()
    /// A Continue-Watching card's direct resume launches the player straight from Home (#11).
    @State private var player: iOSPlayerLaunch?
    #if os(macOS)
    /// macOS keyboard browse: which Home poster card is focused. Passed to each rail so its cards become
    /// `.focusable()` and join native arrow traversal; nil on iOS (this whole member is macOS-only).
    @FocusState private var macFocus: MacBrowseFocus?
    /// Debounces the focus -> hero feature: focus churns rapidly as the rails enrich, so we wait for ~300ms
    /// of focus stability before cross-fading the billboard (otherwise the hero flickers every 0.3-0.5s).
    @State private var macFocusDebounceTask: Task<Void, Never>?
    #endif

    /// All Home rail items in display order (Continue Watching first, then catalog rows), as
    /// `RailItem`s carrying the catalog preview fields so the hero seeds richly. CW entries also
    /// carry their in-progress `video_id` so a direct resume can confirm the remembered link
    /// still matches the episode the engine is parked on. The owner profile rides the account's
    /// engine history; an overlay profile rides its own private synced overlay (never the account).
    private var continueWatchingItems: [RailItem] {
        let source = profiles.activeUsesEngineHistory ? core.continueWatching : profiles.cwItems
        return source.map {
            RailItem(id: $0.id, type: $0.type, name: $0.name, poster: $0.poster, progress: $0.progress,
                     cwVideoId: $0.state.videoId, resumeSeconds: $0.resumeSeconds)
        }
    }

    #if os(macOS)
    /// Every Home rail item flattened, for the keyboard-browse hero coupling: a focused card id resolves
    /// to its `RailItem` so the hero can feature it. Mirrors the same sources the rails render from.
    private var allRailItems: [RailItem] {
        var out = continueWatchingItems
        out += topPicks.items.map { RailItem(id: $0.id, type: $0.type, name: $0.name, poster: $0.poster, progress: 0) }
        out += core.boardRows.flatMap { $0.items }.map {
            RailItem(id: $0.id, type: $0.type, name: $0.name, poster: $0.poster, progress: 0,
                     background: $0.background, description: $0.description, releaseInfo: $0.releaseInfo,
                     imdbRating: $0.imdbRating, genres: $0.genres)
        }
        if showCuratedRails {
            out += curated.collections.flatMap { $0.items }.map { RailItem(id: $0.id, type: $0.type, name: $0.name, poster: $0.poster, progress: 0) }
        }
        return out
    }

    /// The Home rails as (title, item-ids) in display order, keyed by the SAME titles the cards focus on
    /// (`MacBrowseFocus.card(rail:item:)`), so arrow nav can step within a row and between rows.
    private var macRails: [(title: String, ids: [String])] {
        var rails: [(String, [String])] = []
        if !continueWatchingItems.isEmpty { rails.append(("Continue Watching", continueWatchingItems.map(\.id))) }
        if !topPicks.items.isEmpty { rails.append(("Top Picks for you", topPicks.items.map(\.id))) }
        for row in core.boardRows where !row.items.isEmpty { rails.append((row.title, row.items.map(\.id))) }
        if showCuratedRails {
            for c in curated.collections where !c.items.isEmpty { rails.append((c.title, c.items.map(\.id))) }
        }
        return rails
    }

    /// Translate an arrow key into a focus move across `macRails`: Left/Right within a row, Up/Down between
    /// rows (keeping the column where possible). Seeds the first card when nothing is focused yet. This is
    /// what makes arrows actually MOVE on macOS - `.focusable()` + `.focusSection()` join the Tab loop but
    /// never bind arrows to focus movement the way tvOS does, so the ring used to show on a clicked card and
    /// then sit there dead.
    private func advanceMacFocus(_ direction: MoveCommandDirection) {
        let rails = macRails
        guard !rails.isEmpty else { return }
        var r = 0, i = 0
        if case let .card(railTitle, itemID) = macFocus,
           let ri = rails.firstIndex(where: { $0.title == railTitle }),
           let ii = rails[ri].ids.firstIndex(of: itemID) {
            r = ri; i = ii
        } else {
            macFocus = .card(rail: rails[0].title, item: rails[0].ids[0]); return
        }
        switch direction {
        case .left:  i = max(0, i - 1)
        case .right: i = min(rails[r].ids.count - 1, i + 1)
        case .up:    if r > 0 { r -= 1; i = min(i, rails[r].ids.count - 1) }
        case .down:  if r < rails.count - 1 { r += 1; i = min(i, rails[r].ids.count - 1) }
        @unknown default: break
        }
        macFocus = .card(rail: rails[r].title, item: rails[r].ids[i])
    }

    /// Changes whenever the Home rails gain/lose content, so focus-seeding can retry once rails hydrate.
    private var macRailSeedKey: Int {
        continueWatchingItems.count + topPicks.items.count + core.boardRows.count
            + (showCuratedRails ? curated.collections.count : 0)
    }

    /// Seed keyboard focus onto the first card once the rails exist, so a card is the first responder and the
    /// ScrollView's `.onMoveCommand` actually receives arrows. Without a seeded responder macOS has nothing
    /// focused at launch and arrows do nothing (the "Mac arrow-key nav dead" report). Idempotent: seeds only
    /// when nothing is focused yet, once rails have hydrated.
    private func seedMacFocusIfNeeded() {
        guard macFocus == nil, let first = macRails.first, let firstID = first.ids.first else { return }
        macFocus = .card(rail: first.title, item: firstID)
    }
    #endif

    /// The hero's rotation pool: the first ~2-3 of Continue Watching, then the first items of the top
    /// catalog row, capped by the model. These are the titles a Home visitor sees first.
    private var heroCandidates: [FeaturedHeroItem] {
        // A Continue-Watching entry carries only name + poster (no rating / year / genres), so a
        // CW-sourced hero is bare until the slow background HTTP enrichment lands — and when that fetch
        // is unreliable, the hero's meta row stays empty (the reported "no metadata on the backdrop").
        // If the same title is ALSO in a loaded catalog row, seed from that CoreMeta instead: it carries
        // the links-derived rating/year/genres (and a synopsis), so the hero shows its meta immediately,
        // no network round-trip. Falls back to the bare CW seed + enrichment for titles not in a catalog.
        let metaByID = Dictionary(core.boardRows.flatMap { $0.items }.map { ($0.id, $0) },
                                  uniquingKeysWith: { first, _ in first })
        // Overlay profiles seed from their own watch overlay, never the account's CW.
        let cwSource = profiles.activeUsesEngineHistory ? core.continueWatching : profiles.cwItems
        var items: [FeaturedHeroItem] = cwSource.prefix(3).map { cw in
            if let meta = metaByID[cw.id] { return FeaturedHeroItem.from(meta: meta) }
            return FeaturedHeroItem.from(cw: cw)
        }
        if let row = core.boardRows.first(where: { !$0.items.isEmpty }) {
            items += row.items.prefix(3).map(FeaturedHeroItem.from(meta:))
        }
        return items
    }

    var body: some View {
        NavigationStack(path: $path) {
            // The hero is the first scrolling element (an ambient billboard header), not a
            // behind-the-scroll backdrop: that keeps its Play / Trailer buttons + the tappable poster
            // cards reachable (a ScrollView layered over a hero would otherwise eat the hero's taps).
            // Its bottom fades cleanly into canvas with a small gap before the first rail (#52) — the
            // old negative-overlap tuck made the hero bleed into Continue Watching.
            ScrollView {
                // In-flow hero: the band is the FIRST scrolling child of the column (not a pinned section
                // header). Pinning put it ON TOP of the rails on macOS, where it intercepted every tap;
                // as a normal first child it scrolls with the content and its own controls stay hit-tested.
                LazyVStack(alignment: .leading, spacing: Theme.Space.lg) {
                    Color.clear.frame(height: 0).scrollToTopAnchor()   // re-tap Home tab -> scroll here
                    FeaturedHeroView(model: hero, onOpen: { path.append($0) })
                    if !continueWatchingItems.isEmpty {
                        // A CW card tap resumes the exact last-played stream straight into the player
                        // (#11), falling back to opening detail when no remembered link fits. Long-press
                        // offers the engine's "Remove from Continue Watching" (#14).
                        homeRail(PosterRail(title: "Continue Watching", items: continueWatchingItems,
                                            onTap: handleContinueWatchingTap, menu: .continueWatching,
                                            onDetails: { path.append(FeaturedHeroItem.from(rail: $0)) }))
                    }
                    // Collections hub (Discover cards, Streaming-service tiles, Genre tiles), right after
                    // Continue Watching per the owner's row order. Each tile pushes a sub-catalog browse grid.
                    // Needs a TMDB key; hidden without one. Replaces the old flat streaming rails + nested groups.
                    if showCollectionsHub, CollectionsHubModel.isAvailable {
                        iOSCollectionsHub(model: collectionsHub)
                    }
                    // Local recommendations seeded from this profile's recent watch history (#0.3.9).
                    // Hidden when there's no TMDB key, no history to seed from, or no results.
                    if !topPicks.items.isEmpty {
                        homeRail(PosterRail(title: "Top Picks for you",
                                            items: topPicks.items.map {
                                                RailItem(id: $0.id, type: $0.type, name: $0.name,
                                                         poster: $0.poster, progress: 0)
                                            },
                                            onTap: handleTap))
                    }
                    // "Upcoming Episodes": the next-airing episode of each series in the library within the
                    // next 45 days, soonest first (see ReleaseCalendarModel). Each card is the SERIES (so a
                    // tap opens its detail page like any catalog card) with an "S2E5 · Jun 30" caption.
                    // Hidden when there is nothing upcoming, so the default path renders nothing.
                    if !releaseCalendar.upcoming.isEmpty {
                        homeRail(PosterRail(title: "Upcoming Episodes",
                                            items: releaseCalendar.upcoming.map {
                                                RailItem(id: $0.seriesId, type: "series", name: $0.seriesName,
                                                         poster: $0.video.thumbnail, progress: 0,
                                                         caption: "\($0.episodeLabel) · \($0.airDateLabel)")
                                            },
                                            onTap: handleTap))
                    }
                    // "Upcoming Movies": library movies with a future release date in the next 45 days, soonest
                    // first; hidden when nothing is upcoming. Each card routes to the movie detail like any card.
                    if !releaseCalendar.upcomingMovies.isEmpty {
                        homeRail(PosterRail(title: "Upcoming Movies",
                                            items: releaseCalendar.upcomingMovies.map {
                                                RailItem(id: $0.id, type: "movie", name: $0.name,
                                                         poster: $0.poster, progress: 0, caption: $0.releaseDateLabel)
                                            },
                                            onTap: handleTap))
                    }
                    ForEach(core.boardRows) { row in
                        if !row.items.isEmpty {
                            homeRail(PosterRail(title: row.title,
                                                items: row.items.map {
                                                    RailItem(id: $0.id, type: $0.type, name: $0.name,
                                                             poster: $0.poster, progress: 0,
                                                             background: $0.background, description: $0.description,
                                                             releaseInfo: $0.releaseInfo, imdbRating: $0.imdbRating,
                                                             genres: $0.genres)
                                                },
                                                onTap: handleTap,
                                                // #95: horizontal infinite scroll for THIS catalog row.
                                                onReachEnd: { core.loadBoardRowNextPage(engineIndex: row.engineIndex) }))
                                // Vertical infinite scroll: reaching the last populated catalog row loads the
                                // next page of Home catalogs (no-op past the end / while one is in flight).
                                .onAppear {
                                    if row.id == core.boardRows.last(where: { !$0.items.isEmpty })?.id {
                                        core.loadBoardNextPage()
                                    }
                                }
                        }
                    }
                    // Editorial collections (B3, Nuvio-style): hand-curated rails backed by public
                    // Cinemeta catalogs, rendered BELOW the add-on catalog rows. They give Home an
                    // opinionated shape even with no extra catalog add-ons installed, and each fails soft
                    // (an empty collection is dropped; an empty section renders nothing, no error state).
                    if showCuratedRails {
                        ForEach(curated.collections) { collection in
                            homeRail(PosterRail(title: collection.title,
                                                items: collection.items.map {
                                                    RailItem(id: $0.id, type: $0.type, name: $0.name,
                                                             poster: $0.poster, progress: 0)
                                                },
                                                onTap: handleTap))
                        }
                    }
                    // Use the profile-aware CW source so an overlay profile WITH history never reads as
                    // empty, and one with none still shows the empty state honestly.
                    if core.boardRows.isEmpty && continueWatchingItems.isEmpty {
                        emptyState
                    }
                }
                .padding(.bottom, Theme.Space.md)
            }
            // A scroll gesture quiets the ambient hero rotation (resumes after inactivity) — the
            // billboard never yanks the page while the user is browsing (#53).
            .scrollDismissesHeroRotation(model: hero)
            // Re-tapping the active Home tab scrolls back to the top anchor above the hero.
            .scrollToTopOnBump(TabScrollKeys.home)
            #if os(macOS)
            // Arrow keys MOVE the keyboard-browse selection. These live on the ScrollView (not the
            // NavigationStack) because on macOS the inner ScrollView is first responder and swallows arrow
            // keys, so onMoveCommand attached to the stack never fired (the "Mac arrow-key nav dead" report).
            // On plain SwiftUI/macOS, .focusable() + .focusSection() join the Tab loop but do NOT bind arrows
            // to focus movement (unlike tvOS). advanceMacFocus walks the rails and sets macFocus.
            .onMoveCommand { advanceMacFocus($0) }
            // Escape steps focus up a level: drop the focused card so the keyboard browse returns to a
            // neutral state (the bottom tab strip is its own focus space, reachable via Tab / arrows).
            .onExitCommand { macFocus = nil }
            // Keyboard browse drives the hero: the focused poster features in the billboard (the tvOS
            // focused-card-hero behaviour, adapted for the Mac). Focus leaving the cards lets it resume.
            // Debounced ~300ms: focus churns as the rails enrich, so feature only once focus settles.
            .onChange(of: macFocus) { newValue in
                macFocusDebounceTask?.cancel()
                macFocusDebounceTask = Task {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    guard !Task.isCancelled else { return }
                    if case let .card(_, itemID) = newValue, let item = allRailItems.first(where: { $0.id == itemID }) {
                        hero.feature(FeaturedHeroItem.from(rail: item))
                    } else {
                        hero.noteInteraction()
                    }
                }
            }
            // Seed focus onto the first card so a responder exists and arrows start moving: once on appear,
            // and again when the rails first hydrate (boardRows / CW arrive async after onAppear).
            .onAppear { seedMacFocusIfNeeded() }
            .onChange(of: macRailSeedKey) { _ in seedMacFocusIfNeeded() }
            #endif
            .background(Theme.Palette.canvas.ignoresSafeArea())
            .stremioWordmarkTitle(String(localized: "Home"), isActive: isActive)
            // iOS-only: a runtime insert/remove of this trailing toolbar item when sign-in flips also
            // trips the shared-window NSToolbar on macOS (same crash class as the principal item). On
            // macOS sign-in lives in Settings -> Account ("VortX account & sync").
            #if os(iOS)
            .toolbar {
                if !account.isSignedIn {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Sign In") { showSignIn = true }
                    }
                }
            }
            #endif
            .sheet(isPresented: $showSignIn) { iOSSignInView() }
            .navigationDestination(for: FeaturedHeroItem.self) { item in
                // Thread the hub card's already-resolved art so the detail hero never blanks while (or if)
                // Cinemeta meta is nil for a new/unreleased title.
                iOSDetailView(id: item.id, type: item.type, title: item.name,
                              seedBackdrop: item.backdrop, seedLogo: item.logo)
            }
            .navigationDestination(for: HubTarget.self) { target in
                iOSCategoryBrowse(target: target, path: $path)
            }
            .iOSPlayerCover($player, account: account, core: core)
        }
        // Re-tapping the active Home tab pops any pushed detail back to root (#22); the scroll-to-top
        // above then lands on the root anchor. Switching tabs never bumps, so pushes survive switches.
        .popToRootOnBump(TabScrollKeys.home, path: $path)
        // Hidden tabs stay mounted (opacity-switched) and never hit onDisappear, so quiet the ambient
        // hero rotation while this is not the visible tab and re-arm it on return (#24 main-thread work).
        .onChange(of: isActive) { active in
            if active { hero.seed(heroCandidates, reduceMotion: reduceMotion) } else { hero.stop() }
        }
        // Reseed the pool as content arrives; the model ignores no-op reseeds so rotation isn't reset
        // by routine engine re-emits.
        .onAppear {
            // Populate the board on appear (mirrors Discover/Library) so the default Cinemeta catalogs
            // fill Home even when SIGNED OUT — the landing screen shows a real backdrop hero + rails
            // instead of a bare empty state. The Sign In button stays in the toolbar. Guarded on empty
            // so a signed-in session (board already loaded at bootstrap) isn't re-fetched.
            if core.boardRows.isEmpty { core.loadBoard() }
            FeaturedHeroModel.configureMetaSources(core.addons)
            hero.seed(heroCandidates, reduceMotion: reduceMotion)
            refreshTopPicks()
            refreshReleaseCalendar()
            // Editorial rails are global (Cinemeta-backed), so build them once; the model no-ops while
            // already loaded or in flight, and retries on the next appearance if the first fetch failed.
            if showCuratedRails { curated.load() }
            if showCollectionsHub { collectionsHub.load() }
        }
        // Hero reseeds are gated on the visible tab: `seed` re-arms the rotation timer, which would
        // defeat the hidden-tab pause above on every engine re-emit. The isActive onChange reseeds on return.
        .onChange(of: core.revision) { _ in if isActive { hero.seed(heroCandidates, reduceMotion: reduceMotion) }; refreshTopPicks(); refreshReleaseCalendar() }
        .onChange(of: profiles.activeID) { _ in refreshTopPicks() }
        // The Upcoming Episodes bases come from `account.addons`, which loads async after sign-in; rebuild
        // once they arrive (same input set as the notification sweep).
        .onChange(of: account.addons.count) { _ in refreshReleaseCalendar() }
        // Editorial-rails toggle: build them when turned on, drop them when turned off (the "extra
        // catalogs I can't remove from Home" report). The render + hero pool are gated on the same flag.
        .onChange(of: showCuratedRails) { show in if show { curated.load() } else { curated.clear() } }
        .onChange(of: showCollectionsHub) { show in if show { collectionsHub.load() } else { collectionsHub.clear() } }
        // Addons hydrate ASYNC, after onAppear — so configureMetaSources(core.addons) above often ran with
        // an empty set, leaving tmdb:/tvdb:/kitsu: hero items un-enriched (no rating/logo/backdrop on Home,
        // Discover, Library CW). Re-configure + re-seed once addons arrive so enrichment can reach the
        // installed meta add-on, and rebuild Upcoming Episodes (its sweep also needs the meta add-ons).
        // tvOS already does this (HomeView/LiveView .onChange(of: core.addons.count)).
        .onChange(of: core.addons.count) { _ in FeaturedHeroModel.configureMetaSources(core.addons); if isActive { hero.seed(heroCandidates, reduceMotion: reduceMotion) }; refreshReleaseCalendar() }
        .onDisappear { hero.stop() }
    }

    /// Inject the macOS keyboard-focus binding into a Home rail so its cards become arrow-navigable
    /// (`.focusable()` + native traversal). On iOS this is a transparent pass-through, so iPhone / iPad
    /// rails are byte-for-byte unchanged. Returns the (possibly reconfigured) `PosterRail` directly so
    /// the `@ViewBuilder` parents see a plain View, not a `()` from a mutating statement.
    private func homeRail(_ rail: PosterRail) -> PosterRail {
        #if os(macOS)
        var configured = rail
        configured.macFocus = $macFocus
        return configured
        #else
        return rail
        #endif
    }

    /// Tapping a poster opens that title's detail through normal navigation — it does NOT "feature" it
    /// in the hero. The hero is a decoupled ambient billboard (#53); the only side effect of a tap is
    /// quieting its rotation for a beat.
    private func handleTap(_ item: RailItem) {
        hero.noteInteraction()
        path.append(FeaturedHeroItem.from(rail: item))
    }

    /// Recompute the "Top Picks for you" rail from the profile-aware Continue Watching + library.
    /// The model no-ops when the seed set is unchanged, so this is cheap to call on every re-emit.
    private func refreshTopPicks() {
        let cw = profiles.activeUsesEngineHistory ? core.continueWatching : profiles.cwItems
        let library = profiles.activeUsesEngineHistory ? (core.library?.catalog ?? []) : profiles.libraryItems
        topPicks.refresh(profileID: profiles.activeID, cw: cw, library: library)
    }

    /// Recompute "Upcoming Episodes" from the series library + the installed meta add-on bases — derived
    /// EXACTLY like the new-episode notification sweep (series-typed library ids + names, `providesMeta`
    /// add-on base URLs). The model no-ops when the series set is unchanged, so this is cheap to re-call.
    private func refreshReleaseCalendar() {
        let catalog = core.library?.catalog ?? []
        let bases = account.addons.filter { $0.providesMeta }.map(\.baseUrl)
        let series = catalog.filter { $0.type == "series" }
        let names = Dictionary(series.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        releaseCalendar.refresh(seriesIDs: series.map(\.id), seriesNames: names, metaBases: bases)
        let movies = catalog.filter { $0.type == "movie" }
        let movieNames = Dictionary(movies.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let moviePosters = Dictionary(movies.compactMap { m in m.poster.map { (m.id, $0) } }, uniquingKeysWith: { a, _ in a })
        releaseCalendar.refreshMovies(movieIDs: movies.map(\.id), movieNames: movieNames, moviePosters: moviePosters, metaBases: bases)
    }

    /// Continue-Watching one-tap direct resume (#11): play the exact last-played stream straight away
    /// when one is remembered for this title/episode; otherwise fall back to opening the detail page so
    /// the user picks a source. (Direct resume needs a remembered link, which the player records as it
    /// plays; the first watch from the detail page seeds it.)
    private func handleContinueWatchingTap(_ item: RailItem) {
        hero.noteInteraction()
        // Computing the resume offset may await the account, so resolve the direct-resume launch in a
        // Task; fall back to opening detail when no remembered link fits.
        Task {
            if let launch = await iOSDirectResume(for: item, core: core, account: account) {
                player = launch
            } else {
                path.append(FeaturedHeroItem.from(rail: item))
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        // Route through the shared compat empty state for one consistent layout (#44). Signed-out gets
        // a primary Sign In CTA (the in-house PrimaryActionStyle, not the stock .borderedProminent — #42);
        // signed-in is the bare loading line while catalogs hydrate.
        if account.isSignedIn {
            ContentUnavailableViewCompat(title: "Loading your catalogs…", systemImage: "popcorn",
                message: "Your add-ons' rows fill in as the engine hydrates.")
                .frame(minHeight: 420)
        } else {
            ContentUnavailableViewCompat(title: "Sign in to get started", systemImage: "person.crop.circle",
                message: "Sign in to load your add-ons and library.",
                cta: (title: "Sign In", action: { showSignIn = true }))
                .frame(minHeight: 420)
        }
    }
}

/// Library: the user's saved titles from the engine, as a poster grid, under the interactive featured
/// hero. Refreshes as the library changes; reloads while empty since it syncs asynchronously after
/// sign-in.
struct iOSLibraryView: View {
    /// True only when this is the visible tab — gates the macOS window-titlebar wordmark (#46).
    var isActive: Bool = true
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var theme: ThemeManager   // observe textScale so Theme.Typography repaints live
    @EnvironmentObject private var profiles: ProfileStore   // gate the Library on the active profile's own history
    @EnvironmentObject private var account: StremioAccount  // progress-recording wiring for play-from-local (#30)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var hero = FeaturedHeroModel()
    // NavigationPath (not `[FeaturedHeroItem]`): the Downloads pill pushes a `LibraryRoute` VALUE, and a
    // heterogeneous path needs the type-erased container. A typed `[FeaturedHeroItem]` binding also
    // DISABLES any view-destination `NavigationLink` in the subtree (SwiftUI can't encode it into the
    // typed path); that is the root cause of the dead Downloads pill (#25).
    @State private var path = NavigationPath()
    #if !os(tvOS)
    @ObservedObject private var downloads = DownloadStore.shared   // offline downloads section (#30)
    @State private var downloadPlayer: iOSPlayerLaunch?            // play-from-local cover
    #endif

    /// Non-detail Library pushes (value-routed so they work alongside the typed detail destinations).
    enum LibraryRoute: Hashable {
        case downloads
    }

    /// The owner profile's Library is the account library (engine); an overlay profile's Library is its
    /// own private watch overlay (every watched title), never the account.
    private var libraryItems: [RailItem] {
        let source = profiles.activeUsesEngineHistory ? (core.library?.catalog ?? []) : profiles.libraryItems
        return source.map {
            RailItem(id: $0.id, type: $0.type, name: $0.name, poster: $0.poster, progress: $0.progress)
        }
    }

    /// True when there is at least one offline download — keeps the empty-Library placeholder from
    /// showing when a user has downloads but no saved titles. Always false on tvOS (downloads deferred).
    private var hasDownloads: Bool {
        #if os(tvOS)
        return false
        #else
        return !downloads.records.isEmpty
        #endif
    }

    /// The hero pool: the first few saved titles. Library entries carry no backdrop field, so (like
    /// tvOS) the hero derives 16:9 art from metahub for IMDB ids and enriches the rest in the background.
    private var heroCandidates: [FeaturedHeroItem] {
        let source = profiles.activeUsesEngineHistory ? (core.library?.catalog ?? []) : profiles.libraryItems
        return source.prefix(5).map(FeaturedHeroItem.from(cw:))
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                Color.clear.frame(height: 0).scrollToTopAnchor()   // re-tap Library tab -> scroll here
                #if !os(tvOS)
                // Downloads is reachable ONLY through this single pill inside Library (owner's final
                // directive): no inline DownloadsView mount at the top, no Home/Discover hub tile. The pill
                // shows only when there is at least one download and pushes the standalone screen.
                if !downloads.records.isEmpty {
                    iOSLibraryDownloadsPill(count: downloads.records.count)
                        .padding(.horizontal, Theme.Space.md)
                        .padding(.bottom, Theme.Space.lg)
                }
                #endif
                // The owner profile's Library is the account library (engine), with its type/sort filter
                // chips; an overlay profile's Library is its own private watch overlay, with no engine
                // `selectable` so the filter chips are omitted. Both gate on the profile-aware
                // `libraryItems`, so an overlay profile WITH history shows its grid (not "empty").
                if !libraryItems.isEmpty {
                    // Hero is an ambient billboard scroll-header above the grid (shown only when there
                    // are saved titles), so its Play / Trailer buttons stay tappable. Type + sort
                    // filter chip rows (#15) sit between the hero and the grid, mirroring the Discover
                    // chips and the tvOS Library filters; long-press on a card offers the engine's
                    // library actions (#14). A clean gap separates the hero from the chips (#52).
                    // LazyVStack (not VStack): the nested horizontal filter-chip ScrollView would let a
                    // plain VStack adopt the chips' wider-than-screen content width and shift the whole
                    // column left/clipped (the beta7 "weird viewport"). Greedy-width LazyVStack pins it
                    // to the viewport, matching Home. See the iOSDiscoverView note for the full rationale.
                    // In-flow hero: FIRST scrolling child of the column, not a pinned section header.
                    // Pinning put it on top of the grid on macOS and ate every tap; as a normal first
                    // child it scrolls with the content and its own controls stay hit-tested.
                    LazyVStack(alignment: .leading, spacing: Theme.Space.lg) {
                        FeaturedHeroView(model: hero, onOpen: { path.append($0) })
                        VStack(alignment: .leading, spacing: Theme.Space.xs) {
                            if profiles.activeUsesEngineHistory, let lib = core.library {
                                filterChips(lib.selectable)
                            }
                            PosterGrid(items: libraryItems, onTap: handleTap, menu: .library)
                        }
                    }
                    .padding(.bottom, Theme.Space.md)
                    // Pin the column to the viewport width (same fix as Discover): the adaptive PosterGrid
                    // can report an over-wide ideal that the LazyVStack adopts, shifting the column left.
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else if !hasDownloads {
                    // Only show the "Library empty" placeholder when there are ALSO no downloads — a user
                    // with downloads but no saved titles still sees their offline section above.
                    ContentUnavailableViewCompat(title: "Library", systemImage: "books.vertical",
                        message: "Titles you add to your library in Stremio show up here.")
                        .frame(minHeight: 420)
                }
            }
            .scrollDismissesHeroRotation(model: hero)
            // Re-tapping the active Library tab scrolls back to the top.
            .scrollToTopOnBump(TabScrollKeys.library)
            .background(Theme.Palette.canvas.ignoresSafeArea())
            .stremioWordmarkTitle(String(localized: "Library"), isActive: isActive)
            .navigationDestination(for: FeaturedHeroItem.self) { item in
                // Thread the hub card's already-resolved art so the detail hero never blanks while (or if)
                // Cinemeta meta is nil for a new/unreleased title.
                iOSDetailView(id: item.id, type: item.type, title: item.name,
                              seedBackdrop: item.backdrop, seedLogo: item.logo)
            }
            #if !os(tvOS)
            // Value-routed Downloads push (#25): the pill appends `LibraryRoute.downloads`.
            .navigationDestination(for: LibraryRoute.self) { route in
                switch route {
                case .downloads: iOSDownloadsScreen()
                }
            }
            .iOSPlayerCover($downloadPlayer, account: account, core: core)
            #endif
            .onAppear { if core.library?.catalog.isEmpty != false { core.loadLibrary() } }
        }
        // Re-tapping the active Library tab pops any pushed detail/Downloads back to root (#22).
        .popToRootOnBump(TabScrollKeys.library, path: $path)
        // Quiet the ambient hero while this tab is hidden (mounted but opacity 0, so onDisappear never
        // fires); re-arm on return. Reseeds below are gated the same way so re-emits can't re-arm it.
        .onChange(of: isActive) { active in
            if active { hero.seed(heroCandidates, reduceMotion: reduceMotion) } else { hero.stop() }
        }
        .onAppear {
            FeaturedHeroModel.configureMetaSources(core.addons)
            hero.seed(heroCandidates, reduceMotion: reduceMotion)
        }
        .onChange(of: core.revision) { _ in if isActive { hero.seed(heroCandidates, reduceMotion: reduceMotion) } }
        // Addons hydrate ASYNC, after onAppear — so configureMetaSources(core.addons) above often ran with
        // an empty set, leaving tmdb:/tvdb:/kitsu: hero items un-enriched (no rating/logo/backdrop on Home,
        // Discover, Library CW). Re-configure + re-seed once addons arrive so enrichment can reach the
        // installed meta add-on. tvOS already does this (HomeView/LiveView .onChange(of: core.addons.count)).
        .onChange(of: core.addons.count) { _ in FeaturedHeroModel.configureMetaSources(core.addons); if isActive { hero.seed(heroCandidates, reduceMotion: reduceMotion) } }
        .onDisappear { hero.stop() }
    }

    /// Tapping a card opens its detail (decoupled hero, #53); it only quiets the billboard rotation.
    private func handleTap(_ item: RailItem) {
        hero.noteInteraction()
        path.append(FeaturedHeroItem.from(rail: item))
    }

    /// Type + sort chip rows (#15), mirroring the tvOS `LibraryView.filters`: each chip carries the
    /// engine's own `request` and dispatches it back via `core.selectLibrary` on tap. The library
    /// re-emits and the grid + hero refresh on their own.
    @ViewBuilder private func filterChips(_ selectable: CoreLibrarySelectable) -> some View {
        // Route through the shared ChipButtonStyle (like Search's link button): a selected chip is a
        // soft-accent pill with accent ink, so on-chip text follows onAccent and stays legible on
        // light accents (#39) — the old solid-accent + hardcoded-white chip went invisible.
        chipScroll { ForEach(selectable.types) { t in
            Button(AddonTerms.localize(t.label)) { core.selectLibrary(t.request) }
                .buttonStyle(ChipButtonStyle(selected: t.selected)) } }
        chipScroll { ForEach(selectable.sorts) { s in
            Button(AddonTerms.localize(s.label)) { core.selectLibrary(s.request) }
                .buttonStyle(ChipButtonStyle(selected: s.selected)) } }
    }

    private func chipScroll<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Space.sm) { content() }
                .padding(.horizontal, Theme.Space.md).padding(.vertical, Theme.Space.xs)
        }
    }
}

#if !os(tvOS)
/// The offline-downloads section shown at the top of the Library tab (#30). Lists every download with
/// live progress, plays a completed one from its LOCAL file (so it works offline), and offers
/// pause/resume/cancel/delete plus a total-storage footer. Device-local only; nothing here syncs or
/// touches the account library.
struct DownloadsView: View {
    /// Hand a ready-to-play local-file launch up to the Library view, which presents the player cover.
    let onPlay: (iOSPlayerLaunch) -> Void

    @ObservedObject private var store = DownloadStore.shared
    private let manager = DownloadManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack {
                Text("Downloads")
                    .font(Theme.Typography.cardTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Spacer(minLength: 0)
                Text(store.formattedTotalSize())
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            ForEach(store.records) { record in
                row(record)
            }
        }
    }

    @ViewBuilder private func row(_ record: DownloadRecord) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.md) {
            leadingGlyph(record)
            VStack(alignment: .leading, spacing: 4) {
                Text(record.displayTitle)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(2)
                subtitle(record)
                if record.state == .downloading || record.state == .paused {
                    ProgressView(value: record.fractionComplete)
                        .tint(Theme.Palette.accent)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
            controls(record)
        }
        .padding(Theme.Space.sm)
        .background(Theme.Palette.surface1.opacity(0.6),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        // No whole-row .onTapGesture: it swallowed the taps meant for the Play / Pause / Resume / Delete
        // buttons inside the row (none of them fired). The dedicated Play button handles playback.
    }

    @ViewBuilder private func leadingGlyph(_ record: DownloadRecord) -> some View {
        let symbol: String = {
            switch record.state {
            case .completed: return "play.circle.fill"
            case .failed:    return "exclamationmark.triangle.fill"
            case .paused:    return "pause.circle"
            default:         return "arrow.down.circle"
            }
        }()
        let glyph = Image(systemName: symbol)
            .font(.system(size: 26))
            .foregroundStyle(record.state == .failed ? Theme.Palette.textTertiary : Theme.Palette.accent)
            .frame(width: 34, height: 34)
            .contentShape(Rectangle())
        // For a finished download the leading glyph is a real Play affordance (it read as the obvious
        // tap target but did nothing before); other states keep it decorative.
        if record.state == .completed {
            Button { play(record) } label: { glyph }
                .buttonStyle(.plain)
                .accessibilityLabel("Play")
        } else {
            glyph
        }
    }

    @ViewBuilder private func subtitle(_ record: DownloadRecord) -> some View {
        let parts: [String] = {
            switch record.state {
            case .completed:
                let size = ByteCountFormatter.string(fromByteCount: max(record.bytesDone, record.bytesTotal), countStyle: .file)
                return [record.qualityText, size].compactMap { $0 }
            case .downloading:
                let pct = Int(record.fractionComplete * 100)
                return [String(localized: "Downloading \(pct)%")]
            case .paused:
                return [String(localized: "Paused")]
            case .failed:
                return [record.errorText ?? String(localized: "Failed")]
            case .queued:
                return [String(localized: "Queued")]
            }
        }()
        if !parts.isEmpty {
            Text(parts.joined(separator: "  ·  "))
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textTertiary)
                .lineLimit(1)
        }
    }

    @ViewBuilder private func controls(_ record: DownloadRecord) -> some View {
        HStack(spacing: Theme.Space.sm) {
            switch record.state {
            case .downloading:
                iconButton("pause.fill", "Pause") { manager.pause(id: record.id) }
            case .paused, .failed:
                iconButton("arrow.clockwise", "Resume") { manager.resume(id: record.id) }
            case .completed:
                iconButton("play.fill", "Play") { play(record) }
            case .queued:
                EmptyView()
            }
            iconButton("trash", "Delete") { manager.cancel(id: record.id) }
        }
    }

    private func iconButton(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())   // hit-test the full 34x34 box, not the glyph silhouette (the Mac/iOS dead-zone that ate Play/Delete taps)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// Play a completed download from its LOCAL file. Rebuilds the engine `PlaybackMeta` so progress /
    /// Continue Watching record exactly as for a streamed source; `isTorrent: false` because a finished
    /// file plays directly (never back through the loopback torrent server). Fail-soft if the file is
    /// missing (purged out from under us) — drop the row.
    private func play(_ record: DownloadRecord) {
        guard record.state == .completed, store.fileExists(for: record) else {
            if record.state == .completed { manager.cancel(id: record.id) }   // file gone → clean up the stale row
            return
        }
        let url = store.fileURL(for: record)
        let launch = iOSPlayerLaunch(url: url, title: record.displayTitle, headers: nil,
                                     resume: 0, meta: record.playbackMeta,
                                     qualityText: record.qualityText, isTorrent: false)
        onPlay(launch)
    }
}

/// The single Downloads entry point: a full-width pill inside the Library tab (owner's final directive).
/// Shown only when there is at least one download. Replaces both the old top-of-Library inline mount and
/// the Home/Discover hub tile. VALUE-based link (#25): Library's NavigationStack drives an explicit path
/// binding, and a view-destination `NavigationLink { destination }` under an explicit typed path is
/// silently DISABLED by SwiftUI (untappable, the "Downloads can't be opened" report). The value routes
/// through `iOSLibraryView`'s `navigationDestination(for: LibraryRoute.self)`.
#if !os(tvOS)
struct iOSLibraryDownloadsPill: View {
    let count: Int
    var body: some View {
        NavigationLink(value: iOSLibraryView.LibraryRoute.downloads) {
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.Palette.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Downloads")
                        .font(Theme.Typography.cardTitle)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text(count == 1 ? "1 item saved offline" : "\(count) items saved offline")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            .padding(.horizontal, Theme.Space.md)
            .padding(.vertical, Theme.Space.sm)
            .frame(maxWidth: .infinity)
            .background(Theme.Palette.surface1, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
#endif

/// A standalone Downloads screen: the same `DownloadsView` list, plus its own player cover, so it can be
/// pushed from the Library tab's Downloads pill. Pulls account/core from the environment to host the
/// local-file player.
struct iOSDownloadsScreen: View {
    @EnvironmentObject private var account: StremioAccount
    @EnvironmentObject private var core: CoreBridge
    @State private var downloadPlayer: iOSPlayerLaunch?

    var body: some View {
        ScrollView {
            DownloadsView(onPlay: { launch in downloadPlayer = launch })
                .padding(.horizontal, Theme.Space.md)
                .padding(.vertical, Theme.Space.lg)
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        #if os(iOS)
        .navigationTitle("Downloads")
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .macBackAffordance()   // macOS in-content Back + Esc / Cmd-[ (no toolbar back exists)
        .iOSPlayerCover($downloadPlayer, account: account, core: core)
    }
}
#endif

/// Search across every installed add-on, on the engine (debounced). Mirrors the tvOS `SearchView`:
/// results are grouped into Movies / Series / Other rail sections (#16) rather than one flat grid, a
/// "Play a link or magnet" entry sits at the top (the touch/Mac `OpenLinkView`), search suggestions
/// feed `.searchSuggestions`, and the empty / "No results" state is gated at ≥2 characters (the
/// engine's `CoreBridge.search` hard-gates at 2 chars, so a single-char query would otherwise read as
/// a misleading empty state).
struct iOSSearchView: View {
    /// True only when this is the visible tab — gates the macOS window-titlebar wordmark (#46).
    var isActive: Bool = true
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var account: StremioAccount   // passed to the lifted paste-a-link player
    @EnvironmentObject private var theme: ThemeManager   // observe textScale so Theme.Typography repaints live
    @EnvironmentObject private var profiles: ProfileStore   // per-profile recent searches (#90, ported from tvOS)
    @State private var query = ""
    @State private var searchTask: Task<Void, Never>?
    @State private var searchDebouncePending = false
    @State private var path: [FeaturedHeroItem] = []
    @State private var showOpenLink = false
    @State private var pastedPlayer: iOSPlayerLaunch?   // paste-a-link player, presented from here (not the sheet)
    @State private var pendingLaunch: iOSPlayerLaunch?  // staged while the link sheet dismisses, presented in onDismiss
    @State private var history: [String] = []           // recent searches for the active profile (#90)
    @AppStorage(PlaybackSettings.Key.directLinksOnly) private var directLinksOnly = false

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                // LazyVStack: greedy on width so result rails / the link button can't push the column
                // past the viewport and clip both edges (systemic fix S1).
                LazyVStack(alignment: .leading, spacing: Theme.Space.lg) {
                    Color.clear.frame(height: 0).scrollToTopAnchor()   // re-tap Search tab -> scroll here
                    // Stremio's "paste a link" feature, at the top like tvOS.
                    Button { showOpenLink = true } label: {
                        Label(directLinksOnly ? "Play a direct link" : "Play a link or magnet", systemImage: "link")
                    }
                    .buttonStyle(ChipButtonStyle(selected: false))
                    .padding(.horizontal, Theme.Space.md)

                    // macOS search lives in the PERSISTENT window top bar (iOSRootView.macTopBar), NOT in
                    // a toolbar `.searchable`: a toolbar search item is realized as an NSToolbarItem on the
                    // single shared window toolbar and crashes in _insertNewItemWithItemIdentifier (the Mac
                    // crash class the wordmark/sign-in toolbar items are #if os(iOS)-gated for). The old
                    // in-content field here was invisible to the owner: it only existed inside this tab's
                    // scroll content (and vanished entirely in merged Discover+Search mode, which drops the
                    // Search tab), so the top bar replaces it and hands the query over via MacSearchBridge.

                    if !history.isEmpty && !isTyping { historySection }

                    results
                }
                .padding(.vertical, Theme.Space.md)
            }
            // Re-tapping the active Search tab scrolls back to the top.
            .scrollToTopOnBump(TabScrollKeys.search)
            .background(Theme.Palette.canvas.ignoresSafeArea())
            .stremioWordmarkTitle(String(localized: "Search"), isActive: isActive)
            .navigationDestination(for: FeaturedHeroItem.self) { item in
                // Thread the hub card's already-resolved art so the detail hero never blanks while (or if)
                // Cinemeta meta is nil for a new/unreleased title.
                iOSDetailView(id: item.id, type: item.type, title: item.name,
                              seedBackdrop: item.backdrop, seedLogo: item.logo)
            }
            #if os(iOS)
            .searchable(text: $query, prompt: "Movies or series")
            .searchSuggestions {
                ForEach(suggestionTitles, id: \.self) { title in
                    Text(title).searchCompletion(title)
                }
            }
            // `.onSubmit(of: .search)` registers search-submit plumbing into the single shared window
            // toolbar on macOS (the same NSToolbar-insert crash class as the wordmark/.searchable). It is
            // only meaningful paired with `.searchable` (iOS). The macOS inline TextField above carries its
            // own `.onSubmit { ... }`, so search-submit stays covered. So this is iOS-only.
            .onSubmit(of: .search) {
                searchTask?.cancel()
                searchDebouncePending = false
                core.suggestSearch(query)
                core.search(query)
            }
            #endif
            .onAppear {
                core.loadSearchSuggestions()
                history = SearchHistoryStore.load(profileID: profiles.activeID)
            }
            .onChange(of: query) { value in scheduleSearch(value) }   // iOS 16 single-param onChange
            .onChange(of: profiles.activeID) { _ in
                history = SearchHistoryStore.load(profileID: profiles.activeID)
            }
            .onDisappear { searchTask?.cancel() }
            .sheet(isPresented: $showOpenLink, onDismiss: {
                // Present the player only AFTER the link sheet has fully dismissed. On macOS a still-open
                // sheet draws over the window-root player; on iOS presenting mid-dismiss silently drops the
                // cover. Driving it from onDismiss (not a timed delay) is race-free across devices/OS.
                if let launch = pendingLaunch {
                    pendingLaunch = nil
                    pastedPlayer = launch
                }
            }) {
                iOSOpenLinkView { launch in
                    pendingLaunch = launch
                    showOpenLink = false   // triggers onDismiss above, which presents the player
                }
            }
            // Present the paste-a-link player HERE (the Search tab is not a sheet) so the macOS root player
            // fills the window cleanly. On iOS this is a fullScreenCover; on macOS it hoists to MacPlayerHost.
            .iOSPlayerCover($pastedPlayer, account: account, core: core)
        }
        // Re-tapping the active Search tab pops a pushed detail back to root (#22).
        .popToRootOnBump(TabScrollKeys.search, path: $path)
        #if os(macOS)
        // Consume a query submitted from the persistent top bar (a published value, not a notification,
        // so a submit that lazily mounts this screen still lands: onReceive gets the pending value on
        // subscribe). Runs the engine search exactly like a local submit, then clears the handoff.
        .onReceive(MacSearchBridge.shared.$pending) { pending in
            guard let q = pending, !q.isEmpty else { return }
            searchTask?.cancel()
            searchDebouncePending = false
            query = q
            core.suggestSearch(q)
            core.search(q)
            MacSearchBridge.shared.pending = nil
        }
        #endif
    }

    /// Below ≥2 chars the engine never searches, so the page reads as "start typing"; once the query
    /// is long enough it groups the results into rail sections, falling back to a loading / no-results
    /// line. Gating at ≥2 chars stops a single-char query showing a misleading "No results".
    @ViewBuilder private var results: some View {
        if !hasSearchQuery {
            ContentUnavailableViewCompat(title: "Search", systemImage: "magnifyingglass",
                message: "Search across everything your add-ons cover.").frame(minHeight: 360)
        } else if core.searchResults.isEmpty {
            ContentUnavailableViewCompat(
                title: isWaitingForCurrentQuery ? "Searching…" : "No results",
                systemImage: "magnifyingglass",
                message: isWaitingForCurrentQuery ? "" : "Nothing matched what you typed.")
                .frame(minHeight: 360)
        } else {
            // Search has no hero; cards tap straight through to detail and long-press offers the
            // catalog actions (#14).
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                ForEach(resultSections, id: \.title) { section in
                    PosterRail(title: section.title,
                               items: section.items.map {
                                   RailItem(id: $0.id, type: $0.type, name: $0.name, poster: $0.poster, progress: 0)
                               },
                               onTap: { saveToHistory(query); path.append(FeaturedHeroItem.from(rail: $0)) },
                               menu: .catalog)
                }
            }
        }
    }

    /// Group results into Movies / Series / Other, dropping empty sections — the tvOS `resultSections`.
    private var resultSections: [(title: String, items: [CoreMeta])] {
        let movies = core.searchResults.filter { $0.type == "movie" }
        let series = core.searchResults.filter { $0.type == "series" }
        let other = core.searchResults.filter { $0.type != "series" && $0.type != "movie" }
        return [("Movies", movies), ("Series", series), ("Other", other)].filter { !$0.items.isEmpty }
    }

    private var suggestionTitles: [String] { core.searchSuggestionTitles(for: query) }

    /// Recent searches (per profile, sync-backed) shown when the field is empty — the touch/Mac twin of
    /// the tvOS SearchView history row (#90). Tap a chip to re-run it; Clear wipes the list.
    private var historySection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("Recent Searches")
                .font(Theme.Typography.sectionTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
                .padding(.horizontal, Theme.Space.md)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.sm) {
                    ForEach(history, id: \.self) { term in
                        Button { query = term } label: { Label(term, systemImage: "clock") }
                            .buttonStyle(ChipButtonStyle(selected: false))
                    }
                    Button {
                        SearchHistoryStore.clear(profileID: profiles.activeID)
                        history = []
                    } label: { Label("Clear", systemImage: "trash") }
                        .buttonStyle(ChipButtonStyle(selected: false))
                }
                .padding(.horizontal, Theme.Space.md)
            }
        }
    }

    /// True while the user is typing a query, so the recent-searches row hides during an active search.
    private var isTyping: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Record a query the user actually engaged with (opened a result for), mirroring tvOS.
    private func saveToHistory(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return }
        SearchHistoryStore.add(trimmed, profileID: profiles.activeID)
        history = SearchHistoryStore.load(profileID: profiles.activeID)
    }

    private var hasSearchQuery: Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
    }

    private var isWaitingForCurrentQuery: Bool {
        hasSearchQuery && (searchDebouncePending || core.searchIsLoading)
    }

    private func scheduleSearch(_ value: String) {
        searchTask?.cancel()
        let q = value.trimmingCharacters(in: .whitespaces)
        searchDebouncePending = q.count >= 2
        guard !q.isEmpty else { searchDebouncePending = false; core.search(""); return }
        searchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            core.suggestSearch(q)
            core.search(q)
            searchDebouncePending = false
        }
    }
}

/// Discover, driven by the stremio-core engine (CatalogWithFilters): type, catalog, and genre
/// chips carrying the engine's own request, dispatched back on tap, over a poster grid — under the
/// interactive featured hero (shown once a catalog has loaded).
struct iOSDiscoverView: View {
    /// True only when this is the visible tab — gates the macOS window-titlebar wordmark (#46).
    var isActive: Bool = true
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var account: StremioAccount
    @EnvironmentObject private var theme: ThemeManager   // observe textScale so Theme.Typography repaints live
    @AppStorage("stremiox.hideLiveTab") private var hideLiveTab = false   // also hide Live types from the Discover type filter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var hero = FeaturedHeroModel()
    @ObservedObject private var collectionsHub = CollectionsHubModel.shared
    @AppStorage("vortx.discover.showCollectionsHub") private var showCollectionsHub = true   // toggle the hub on Discover (needs a TMDB key)
    /// Merge Discover + Search into one surface (Settings toggle, default OFF, reversible). When ON the root
    /// drops the Search tab and Discover shows an inline search field at the top; an active query (≥2 chars)
    /// swaps the catalog browse for grouped search results. OFF = Discover is unchanged and Search is its own tab.
    @AppStorage("vortx.mergeDiscoverSearch") private var mergeDiscoverSearch = false
    @State private var searchQuery = ""
    @State private var searchTask: Task<Void, Never>?
    @State private var searchDebouncePending = false
    @State private var path = NavigationPath()

    /// The hero pool: the first few items of the currently selected catalog. Catalog metas carry their
    /// own `background` + preview fields, so the hero is rich immediately and enriches for logo/trailer.
    private var heroCandidates: [FeaturedHeroItem] {
        (core.discover?.items.prefix(5).map(FeaturedHeroItem.from(meta:))) ?? []
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                // LazyVStack (not VStack): a vertical ScrollView proposes the viewport width, but a
                // plain VStack sizes to its WIDEST child — and the nested horizontal chip ScrollViews
                // below let it adopt their (wider-than-screen) content width, pushing the whole column
                // off-axis so the hero + chips + grid render shifted-left and clipped on both edges
                // (the intermittent beta7 "weird viewport" on Discover/Library). LazyVStack is greedy
                // on the cross axis — it always takes the full viewport width — so it can't overflow.
                // Home already uses LazyVStack and never exhibited the shift.
                LazyVStack(alignment: .leading, spacing: Theme.Space.md) {
                    // In-flow hero: FIRST scrolling child so it leads UNCONDITIONALLY (the model tolerates
                    // an empty pool and re-seeds on addons/revision) and scrolls with the chips/grid. Not a
                    // pinned section header: pinning put it on top on macOS and ate every tap.
                    Color.clear.frame(height: 0).scrollToTopAnchor()   // re-tap Discover tab -> scroll here
                    // Merged mode: an inline search field sits above the Discover browse so the two surfaces
                    // share one tab (owner: less clutter on mobile). Fail-soft — the flag defaults OFF, so the
                    // field is absent and Discover is byte-for-byte unchanged unless the user opts in.
                    if mergeDiscoverSearch { mergedSearchField }
                    if mergeDiscoverSearch, hasSearchQuery {
                        mergedSearchResults
                    } else {
                    FeaturedHeroView(model: hero, onOpen: { path.append($0) })
                    if showCollectionsHub, CollectionsHubModel.isAvailable {
                        iOSCollectionsHub(model: collectionsHub)
                    }
                    if let discover = core.discover {
                        // The filter rows are their own vertically-stacked band: each chip row gets its
                        // own line with consistent spacing so a row's pills can never be drawn on top
                        // of the row above it (#7).
                        VStack(alignment: .leading, spacing: Theme.Space.xs) {
                            chipScroll { ForEach(hideLiveTab ? discover.selectable.types.filter { !LiveTypes.contains($0.type) } : discover.selectable.types) { t in
                                Button(t.type.capitalized) { core.selectDiscover(t.request) }
                                    .buttonStyle(ChipButtonStyle(selected: t.selected)) } }
                            chipScroll { ForEach(discover.selectable.catalogs) { c in
                                Button(c.catalog) { core.selectDiscover(c.request) }
                                    .buttonStyle(ChipButtonStyle(selected: c.selected)) } }
                            if let genre = discover.selectable.extra.first(where: { $0.name.caseInsensitiveCompare("genre") == .orderedSame }),
                               !genre.options.isEmpty {
                                chipScroll { ForEach(genre.options) { o in
                                    Button(AddonTerms.localize(o.label)) { core.selectDiscover(o.request) }
                                        .buttonStyle(ChipButtonStyle(selected: o.selected)) } }
                            }
                        }
                        // De-dup by id: paginated catalogs can repeat a title across pages, and the grid's
                        // ForEach is keyed by id, so duplicates would trip SwiftUI's "id occurs multiple
                        // times" warning and silently drop the later cells (mirrors the search path).
                        PosterGrid(items: dedupedMetasById(discover.items).map {
                            RailItem(id: $0.id, type: $0.type, name: $0.name, poster: $0.poster, progress: 0,
                                     background: $0.background, description: $0.description,
                                     releaseInfo: $0.releaseInfo, imdbRating: $0.imdbRating, genres: $0.genres)
                        }, onTap: handleTap, onReachEnd: { core.loadDiscoverNextPage() })
                    } else if account.isSignedIn {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 100)
                    } else {
                        ContentUnavailableViewCompat(title: "Discover", systemImage: "safari",
                            message: "Sign in to browse your add-ons' catalogs.").frame(minHeight: 420)
                    }
                    }   // end !hasSearchQuery browse branch (merged mode)
                }
                .padding(.top, core.discover != nil ? 0 : Theme.Space.md)
                .padding(.bottom, Theme.Space.md)
                // Pin the column to the viewport width. The adaptive PosterGrid can report an over-wide
                // ideal that the LazyVStack adopts (LazyVStack is NOT inherently viewport-pinned as the
                // note above assumed), shifting the hero/chips/grid off the left edge — the Discover
                // clipping report. Home has only self-bounding horizontal rails, so it never needed this.
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDismissesHeroRotation(model: hero)
            // Re-tapping the active Discover tab scrolls back to the top.
            .scrollToTopOnBump(TabScrollKeys.discover)
            .background(Theme.Palette.canvas.ignoresSafeArea())
            .stremioWordmarkTitle(String(localized: "Discover"), isActive: isActive)
            .navigationDestination(for: FeaturedHeroItem.self) { item in
                // Thread the hub card's already-resolved art so the detail hero never blanks while (or if)
                // Cinemeta meta is nil for a new/unreleased title.
                iOSDetailView(id: item.id, type: item.type, title: item.name,
                              seedBackdrop: item.backdrop, seedLogo: item.logo)
            }
            .navigationDestination(for: HubTarget.self) { target in
                iOSCategoryBrowse(target: target, path: $path)
            }
            .onAppear { if core.discover == nil { core.loadDiscover() } }
        }
        // Re-tapping the active Discover tab pops a pushed detail/category browse back to root (#22).
        .popToRootOnBump(TabScrollKeys.discover, path: $path)
        // Quiet the ambient hero while this tab is hidden (mounted but opacity 0, so onDisappear never
        // fires); re-arm on return. Reseeds below are gated the same way so re-emits can't re-arm it.
        .onChange(of: isActive) { active in
            if active { hero.seed(heroCandidates, reduceMotion: reduceMotion) } else { hero.stop() }
        }
        .onAppear {
            FeaturedHeroModel.configureMetaSources(core.addons)
            hero.seed(heroCandidates, reduceMotion: reduceMotion)
            if showCollectionsHub { collectionsHub.load() }
        }
        .onChange(of: showCollectionsHub) { show in if show { collectionsHub.load() } else { collectionsHub.clear() } }
        // The grid changes whenever a different type/catalog/genre is selected, which bumps revision —
        // reseed so the hero pool tracks the visible catalog.
        .onChange(of: core.revision) { _ in if isActive { hero.seed(heroCandidates, reduceMotion: reduceMotion) } }
        // Addons hydrate ASYNC, after onAppear — so configureMetaSources(core.addons) above often ran with
        // an empty set, leaving tmdb:/tvdb:/kitsu: hero items un-enriched (no rating/logo/backdrop on Home,
        // Discover, Library CW). Re-configure + re-seed once addons arrive so enrichment can reach the
        // installed meta add-on. tvOS already does this (HomeView/LiveView .onChange(of: core.addons.count)).
        .onChange(of: core.addons.count) { _ in FeaturedHeroModel.configureMetaSources(core.addons); if isActive { hero.seed(heroCandidates, reduceMotion: reduceMotion) } }
        #if os(macOS)
        // Merged Discover+Search mode: the Search tab is dropped, so the persistent top bar's submit
        // routes here. Consume the pending query into the inline merged search (same engine contract).
        .onReceive(MacSearchBridge.shared.$pending) { pending in
            guard mergeDiscoverSearch, let q = pending, !q.isEmpty else { return }
            searchTask?.cancel()
            searchDebouncePending = false
            searchQuery = q
            core.suggestSearch(q)
            core.search(q)
            MacSearchBridge.shared.pending = nil
        }
        #endif
        // Merged search: debounce the query into the engine (same contract as iOSSearchView), and clear the
        // field/results when the user turns the merge off so Discover returns to the plain catalog browse.
        .onChange(of: searchQuery) { value in if mergeDiscoverSearch { scheduleMergedSearch(value) } }
        .onChange(of: mergeDiscoverSearch) { on in if !on { searchTask?.cancel(); searchQuery = ""; core.search("") } }
        .onDisappear { hero.stop(); searchTask?.cancel() }
    }

    // MARK: Merged Discover + Search (opt-in)

    /// True once the merged-mode query is long enough for the engine to search (≥2 chars, matching the
    /// engine's hard gate). Below this the normal Discover browse shows beneath the field.
    private var hasSearchQuery: Bool {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
    }

    /// Inline search field shown at the top of Discover in merged mode. Mirrors the macOS search field in
    /// iOSSearchView: a magnifier glyph + plain TextField on a surface capsule, submit + clear.
    private var mergedSearchField: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.Palette.textSecondary)
            TextField(text: $searchQuery) {
                Text("Search movies or series").foregroundStyle(Theme.Palette.textTertiary)
            }
            .textFieldStyle(.plain)
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.Palette.textPrimary)
            .onSubmit { core.suggestSearch(searchQuery); core.search(searchQuery) }
            if !searchQuery.isEmpty {
                Button { searchQuery = ""; core.search("") } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .font(.system(size: 16, weight: .semibold))
                        .padding(8).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.sm)
        .background(Theme.Palette.surface1, in: Capsule())
        .overlay(Capsule().stroke(Theme.Palette.surface2, lineWidth: 1))
        .padding(.horizontal, Theme.Space.md)
    }

    /// Grouped Movies / Series / Other rails for the merged-mode query, reusing the same engine results +
    /// rail layout as iOSSearchView so behavior is identical whether search lives in its own tab or here.
    @ViewBuilder private var mergedSearchResults: some View {
        if core.searchResults.isEmpty {
            ContentUnavailableViewCompat(
                title: (searchDebouncePending || core.searchIsLoading) ? "Searching…" : "No results",
                systemImage: "magnifyingglass",
                message: (searchDebouncePending || core.searchIsLoading) ? "" : "Nothing matched what you typed.")
                .frame(minHeight: 360)
        } else {
            let movies = core.searchResults.filter { $0.type == "movie" }
            let series = core.searchResults.filter { $0.type == "series" }
            let other = core.searchResults.filter { $0.type != "series" && $0.type != "movie" }
            let sections = [("Movies", movies), ("Series", series), ("Other", other)].filter { !$0.1.isEmpty }
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                ForEach(sections, id: \.0) { section in
                    PosterRail(title: section.0,
                               items: section.1.map {
                                   RailItem(id: $0.id, type: $0.type, name: $0.name, poster: $0.poster, progress: 0)
                               },
                               onTap: { path.append(FeaturedHeroItem.from(rail: $0)) },
                               menu: .catalog)
                }
            }
        }
    }

    /// Debounce the merged query into the engine (350ms), matching iOSSearchView.scheduleSearch.
    private func scheduleMergedSearch(_ value: String) {
        searchTask?.cancel()
        let q = value.trimmingCharacters(in: .whitespaces)
        searchDebouncePending = q.count >= 2
        guard !q.isEmpty else { searchDebouncePending = false; core.search(""); return }
        searchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            core.suggestSearch(q)
            core.search(q)
            searchDebouncePending = false
        }
    }

    /// Tapping a card opens its detail (decoupled hero, #53); it only quiets the billboard rotation.
    private func handleTap(_ item: RailItem) {
        hero.noteInteraction()
        path.append(FeaturedHeroItem.from(rail: item))
    }

    private func chipScroll<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Space.sm) { content() }
                .padding(.horizontal, Theme.Space.md).padding(.vertical, Theme.Space.xs)
        }
    }
}

/// One catalog row's tappable poster. Beyond the poster + progress the card needs, it carries the
/// catalog preview fields (`background`, `description`, `releaseInfo`, `imdbRating`, `genres`) so the
/// detail route opened on tap arrives with rich seed data — they're present on `CoreMeta` but were
/// previously dropped at the `.map`. Continue Watching / Library entries lack a `background`, so the
/// hero derives 16:9 art from metahub-by-IMDB-id (see `FeaturedHeroItem.from`).
/// Keep the first occurrence of each meta id, dropping later duplicates. Paginated catalogs can repeat a
/// title across pages, and a grid `ForEach` keyed by id would otherwise warn and silently drop the later
/// cells (the search path already de-dups the same way).
private func dedupedMetasById(_ metas: [CoreMeta]) -> [CoreMeta] {
    var seen = Set<String>()
    return metas.filter { seen.insert($0.id).inserted }
}

struct RailItem: Identifiable {
    let id: String
    let type: String
    let name: String
    let poster: String?
    let progress: Double
    var background: String? = nil
    var description: String? = nil
    var releaseInfo: String? = nil
    var imdbRating: String? = nil
    var genres: [String]? = nil
    /// The Continue-Watching entry's in-progress video id (`state.video_id`), carried so a
    /// direct resume can confirm the remembered link still matches the episode the engine
    /// is parked on (mirrors the tvOS `directResume` series guard). Nil for catalog/library cards.
    var cwVideoId: String? = nil
    /// A small secondary caption shown UNDER the card title (e.g. "S2E5 · Jun 30" on the Upcoming
    /// Episodes rail). Nil on every other rail, so their cards are byte-for-byte unchanged.
    var caption: String? = nil
    /// The saved resume position in seconds, so a Continue Watching card can show the "1:03" resume
    /// timecode badge. Nil on every non-CW rail, so their cards are byte-for-byte unchanged.
    var resumeSeconds: Double? = nil
}

// MARK: - Poster context menu (#14, ported from tvOS PosterCard.menuItems)

/// Which long-press (context) menu a `PosterCardiOS` shows, mirroring the tvOS `PosterMenu`.
/// `.continueWatching` offers a dismiss; `.catalog` offers add-to-library plus mark watched /
/// unwatched; `.library` swaps add for remove-from-library; `.none` attaches no menu at all. The
/// actions fire straight at the engine (`CoreBridge.shared`); Continue Watching and the catalogs
/// both refresh on their own when the engine re-emits the affected fields.
enum iOSPosterMenu { case none, continueWatching, catalog, library }

// MARK: - Direct resume + paste-a-link playback (#11 / #16, the iOS player launch path)

/// A resolved stream ready to hand to `PlayerScreen`, the value the iOS browse screens pass into
/// `iOSPlayerCover`. Mirrors `iOSDetailView.PlayerLaunch` so the launch path is identical: the same
/// native `PlayerScreen` over the same `platformFullScreenCover`, with progress saved through the
/// account just like the detail page. Used by Continue-Watching direct resume and the paste-a-link
/// flow (both reach playback WITHOUT routing through the detail page / re-resolving sources).
struct iOSPlayerLaunch: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
    var headers: [String: String]? = nil
    var resume: Double = 0
    /// nil for a paste-a-link play (no library item to record progress against).
    var meta: PlaybackMeta? = nil
    /// Quality signature + torrent flag of the launching stream, re-recorded into LastStreamStore on
    /// playback start so a CW resume refreshes its memory. Carried from the remembered entry on a CW
    /// direct-resume; nil for paste-a-link (which has no `meta`, so nothing is recorded anyway).
    var qualityText: String? = nil
    /// The launching stream's release group (behaviorHints.bingeGroup), carried from the remembered CW
    /// entry so a resume's prev/next keeps the same release across episodes (binge continuity).
    var bingeGroup: String? = nil
    var isTorrent: Bool = false
    /// When a natively-resolved debrid link launched this, its provenance so the play-record can store enough
    /// to reresolve a fresh link on a later CW resume. Carried on a CW debrid-reresolve; nil for torrent/direct.
    var debridRef: DebridPlaybackRef? = nil
    /// Series only: the season's ordered episodes + a resolver, so a Continue-Watching resume gets the
    /// same in-player Next / Prev / episode-list as the detail page. Empty/nil for movies + paste-a-link.
    var episodes: [PlayerEpisodeRef] = []
    var loadEpisode: ((String) async -> PlayerEpisodeStream?)? = nil
    /// yt-direct adaptive pair (pasted YouTube links): the separate AUDIO stream mpv mounts alongside the
    /// video-only `url` (`--audio-file` sidecar). Forces the libmpv engine in PlayerScreen.
    var audioSidecarURL: URL? = nil
}

extension View {
    /// Present `PlayerScreen` for an `iOSPlayerLaunch` over the browse screen, saving progress to
    /// the account (the same wiring `iOSDetailView` uses) when the launch carries a `PlaybackMeta`.
    @ViewBuilder func iOSPlayerCover(_ launch: Binding<iOSPlayerLaunch?>,
                                     account: StremioAccount, core: CoreBridge) -> some View {
        platformFullScreenPlayerCover(item: launch) { item in
            PlayerScreen(
                url: item.url, title: item.title, headers: item.headers, resumeSeconds: item.resume,
                recordMeta: item.meta, recordQualityText: item.qualityText,
                recordBingeGroup: item.bingeGroup, recordIsTorrent: item.isTorrent,
                audioSidecarURL: item.audioSidecarURL,
                episodes: item.episodes, loadEpisode: item.loadEpisode,
                // Feed the engine Player so Continue Watching updates live + watched time is tracked (the
                // direct-resume / paste-a-link path was missing this, like the detail covers). It's keyed off
                // the engine's loaded Player, so it runs regardless of `item.meta` and no-ops if none is loaded.
                onProgress: { pos, dur in
                    core.reportProgress(timeSeconds: pos, durationSeconds: dur)
                    guard let meta = item.meta else { return }
                    Task { [weak account] in await account?.saveProgress(for: meta, positionSeconds: pos, durationSeconds: dur) }
                },
                onSeek: { pos, dur in
                    core.reportProgress(timeSeconds: pos, durationSeconds: dur)
                    guard let meta = item.meta else { return }
                    Task { [weak account] in await account?.saveProgress(for: meta, positionSeconds: pos, durationSeconds: dur) }
                },
                onClose: { launch.wrappedValue = nil }
            )
            .ignoresSafeArea()
        }
    }
}

/// Resume the EXACT link a Continue-Watching title last played, straight into the player, instead of
/// routing through the detail page and re-resolving sources — the touch/Mac twin of the tvOS
/// `CoreContinueWatchingRow.directResume`. Returns nil (caller then opens detail) when no remembered
/// link fits: never played on this device, the link is a torrent while torrents are disabled, or the
/// engine moved the series on to a different episode than the one we remembered.
@MainActor
private func iOSDirectResume(for item: RailItem, core: CoreBridge,
                             account: StremioAccount) async -> iOSPlayerLaunch? {
    let pid = ProfileStore.shared.activeID
    guard let entry = LastStreamStore.entry(for: item.id, profileID: pid) else {
        LastStreamStore.logResume("noEntry", libraryId: item.id, profileID: pid); return nil
    }
    guard let url = URL(string: entry.url) else {
        LastStreamStore.logResume("badURL", libraryId: item.id, profileID: pid); return nil
    }
    if PlaybackSettings.torrentsDisabled && entry.torrent == true {
        LastStreamStore.logResume("torrentDisabled", libraryId: item.id, profileID: pid); return nil
    }
    if item.type == "series", let cwVideo = item.cwVideoId, cwVideo != entry.videoId {
        LastStreamStore.logResume("episodeMoved:\(cwVideo)|\(entry.videoId)", libraryId: item.id, profileID: pid); return nil
    }
    LastStreamStore.logResume("hit", libraryId: item.id, profileID: pid)
    // Re-prime the torrent engine before resuming: the stored loopback URL carries NO trackers, so without
    // this the server opens a peerless DHT-only engine that never sends data (the "sources didn't load" red
    // triangle on most CW torrent resumes). POST /{hash}/create with reachable trackers first; /create is
    // idempotent, so an already-warm engine is untouched. Only loopback torrents (debrid/direct skip it).
    if entry.torrent == true, let hash = url.pathComponents.dropFirst().first, hash.count == 40 {
        StremioServer.primeTorrent(hash: hash.lowercased())
    }
    let meta = PlaybackMeta(libraryId: item.id, videoId: entry.videoId, type: entry.type,
                            name: entry.name, poster: entry.poster,
                            season: entry.season, episode: entry.episode)
    // Resume where the user left off, not 0:00 (#11). The iOS PlayerScreen seeks ONLY to the passed
    // `resume`, so the offset must be computed here — mirroring iOSDetailView.resume(_:):
    // the engine's own offset for engine-history profiles, else the account/overlay offset.
    let resume: Double
    if let engine = core.engineResumeSeconds(for: meta) {
        resume = engine
    } else {
        resume = await account.resumeOffset(for: meta)
    }
    // For a MOVIE, kick off loading the title's streams in the background so a stale stored link (debrid URLs
    // are time-limited and expire between sessions) can AUTO-HOP to a freshly-resolved source instead of
    // dead-ending on the "sources didn't load" overlay (the debrid CW-resume failure). Non-blocking: the
    // stored link still plays immediately; if it fails, the player's failover now has FRESH sources to pick.
    // (Series loads its episode streams below; this gives movies the same hop-on-failure safety net.)
    if entry.type == "movie",
       core.metaDetails?.meta?.id != item.id || core.streamGroups(forStreamId: entry.videoId).isEmpty {
        core.loadMeta(type: "movie", id: item.id, streamType: "movie", streamId: entry.videoId)
    }
    // For a series, give the player the season's episode list + a resolver so the CW resume has the same
    // in-player Next / Prev / episode-list as the detail page. The CW item's videos may not be resident,
    // so wait briefly (~1.5s) for the meta; if it doesn't arrive, the recorded stream still resumes,
    // just without episode nav this session.
    var episodes: [PlayerEpisodeRef] = []
    var loadEpisode: ((String) async -> PlayerEpisodeStream?)? = nil
    if entry.type == "series" {
        // Load the series meta (for the episode list) AND the CURRENT episode's streams, so the in-player
        // Sources button has this episode's alternates. Loading meta-only here had wiped the resident
        // episode streams the Sources list relied on — the "Sources button gone from CW resume" regression.
        let hasEpStreams = core.metaDetails?.streams.contains { $0.request.path.id == entry.videoId } ?? false
        if core.metaDetails?.meta?.id != item.id || (core.metaDetails?.meta?.videos?.isEmpty ?? true) || !hasEpStreams {
            core.loadMeta(type: "series", id: item.id, streamType: "series", streamId: entry.videoId)
            for _ in 0 ..< 6 {
                if core.metaDetails?.meta?.id == item.id, !(core.metaDetails?.meta?.videos?.isEmpty ?? true) { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        let season = entry.season ?? 1
        let seasonVideos = (core.metaDetails?.meta?.videos ?? [])
            .filter { ($0.season ?? 1) == season }
            .sorted { $0.episodeNumber < $1.episodeNumber }
        if seasonVideos.count > 1 {
            episodes = seasonVideos.map { PlayerEpisodeRef(id: $0.id, label: "E\($0.episodeNumber) · \($0.episodeTitle)") }
            loadEpisode = { vid in
                await iOSResolveEpisodeStream(videoId: vid, in: seasonVideos, seriesId: item.id,
                                              seriesName: entry.name, defaultSeason: season,
                                              fallbackPoster: entry.poster, continuity: entry.qualityText,
                                              binge: entry.bingeGroup, core: core, account: account)
            }
        }
    }
    return iOSPlayerLaunch(url: url, title: entry.title, headers: entry.headers,
                           resume: resume, meta: meta,
                           qualityText: entry.qualityText, bingeGroup: entry.bingeGroup,
                           isTorrent: entry.torrent ?? false,
                           episodes: episodes, loadEpisode: loadEpisode)
}

/// Stremio's "paste a link" feature on touch / Mac (#16) — the twin of the tvOS `OpenLinkView`. Plays
/// a direct video URL or a magnet: magnets ride the embedded torrent engine (the `/create` call blocks
/// until the torrent's metadata arrives, then the largest video file plays). The tvOS `OpenLinkView`
/// and its `LinkOpener` live in the tvOS-only target (they depend on `PlayerPresenter`), so this brings
/// its own small parse/resolve built on the shared `TorrentTrackers` + `StremioServer`, and launches
/// the same native `PlayerScreen` the rest of the iOS app uses.
private struct iOSOpenLinkView: View {
    /// Hand the ready-to-play launch to the PARENT (the Search tab), which dismisses this sheet and then
    /// presents the player. On macOS the player is hoisted to the window root (MacPlayerHost); presenting
    /// it from inside this still-open sheet drew the sheet ON TOP of the video. Launching from the parent
    /// (not a sheet) lets the root player fill the window with nothing above it.
    let onPlay: (iOSPlayerLaunch) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var working = false
    @State private var status: String?
    @State private var resolveTask: Task<Void, Never>?   // in-flight magnet resolution; cancelled if the sheet closes
    @State private var fileChoices: [OpenLinkMagnet.TorrentFile]? = nil   // multi-file pack → show the picker
    @State private var magnetLink: String? = nil                         // the magnet the open picker belongs to (#81)
    @State private var saved: [SavedLinksStore.Entry] = []               // saved magnets/links for this profile (#81)
    @AppStorage(PlaybackSettings.Key.directLinksOnly) private var directLinksOnly = false

    var body: some View {
        Group {
            if let choices = fileChoices {
                filePicker(choices)
            } else {
                inputForm
            }
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .onAppear { saved = SavedLinksStore.all(profileID: ProfileStore.shared.activeID) }
        // Closing the sheet mid-resolve must stop the magnet fetch, otherwise it would fire onPlay and
        // present the player after the user already backed out.
        .onDisappear { resolveTask?.cancel() }
    }

    private var inputForm: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            Text("Play a link")
                .font(Theme.Typography.sectionTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
            Text(directLinksOnly
                 ? "A direct video URL (mp4, mkv, m3u8 and friends), a debrid or usenet link your service resolved to http(s), a live Twitch channel link, or a YouTube link."
                 : "A direct video URL (mp4, mkv, m3u8 and friends), a debrid or usenet link your service resolved to http(s), a live Twitch channel link, a YouTube link, or a magnet link.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textSecondary)
            TextField(directLinksOnly ? "https://..." : "https://...  or  magnet:?xt=...", text: $input)
                .font(Theme.Typography.body)
                .disableAutocorrection(true)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: Theme.Space.md) {
                Button(working ? "Working…" : "Play") { play() }
                    .buttonStyle(PrimaryActionStyle())
                    .disabled(working || input.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Save") { saveCurrent() }
                    .buttonStyle(ChipButtonStyle(selected: false))
                    .disabled(working || input.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel") { resolveTask?.cancel(); dismiss() }
                    .buttonStyle(ChipButtonStyle(selected: false))
            }
            if let status {
                Text(status)
                    .font(Theme.Typography.label)
                    .foregroundStyle(working ? Theme.Palette.textSecondary : Theme.Palette.danger)
            }
            if !saved.isEmpty { savedSection }
            Spacer()
        }
    }

    /// Saved magnets and links (#81): tap one to play it again; a pack reopens its file picker.
    private var savedSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("Saved")
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textSecondary)
            ScrollView {
                VStack(spacing: Theme.Space.sm) {
                    ForEach(saved) { entry in
                        HStack(spacing: Theme.Space.md) {
                            Button { playSaved(entry) } label: {
                                HStack(spacing: Theme.Space.md) {
                                    Image(systemName: entry.isMagnet ? "bolt.horizontal.circle" : "link")
                                    Text(entry.name).lineLimit(1)
                                    Spacer(minLength: Theme.Space.md)
                                    Image(systemName: "play.fill")
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Button { removeSaved(entry) } label: { Image(systemName: "trash") }
                                .buttonStyle(.plain)
                                .foregroundStyle(Theme.Palette.textSecondary)
                        }
                    }
                }
            }
            .frame(maxHeight: 280)
        }
    }

    private func saveCurrent() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let isMagnet = text.lowercased().hasPrefix("magnet:")
        let last = URL(string: text)?.lastPathComponent ?? ""
        let name = isMagnet ? (OpenLinkMagnet.parse(text)?.name ?? "Magnet link") : (last.isEmpty ? text : last)
        SavedLinksStore.save(.init(id: text, link: text, name: name, poster: nil, isMagnet: isMagnet, savedAt: Date()),
                             profileID: ProfileStore.shared.activeID)
        saved = SavedLinksStore.all(profileID: ProfileStore.shared.activeID)
        status = "Saved."
    }

    private func playSaved(_ entry: SavedLinksStore.Entry) {
        // #81: a magnet bound to an exact file replays THAT file directly, skipping re-resolution and the
        // Cinemeta re-match (which could land on a different show / re-show the picker / play the biggest
        // file). Direct/debrid links and not-yet-bound magnets fall through to the normal resolve path.
        if entry.isMagnet, !PlaybackSettings.torrentsDisabled,
           let infoHash = entry.infoHash, let fileIdx = entry.fileIdx,
           let url = URL(string: "\(StremioServer.base)/\(infoHash)/\(fileIdx)") {
            if let magnet = OpenLinkMagnet.parse(entry.link) {
                OpenLinkMagnet.warmUp(magnet)   // re-create the torrent on the server so the file endpoint is ready
            }
            onPlay(iOSPlayerLaunch(url: url, title: entry.name, isTorrent: true))
            return
        }
        input = entry.link
        play()
    }

    private func removeSaved(_ entry: SavedLinksStore.Entry) {
        SavedLinksStore.remove(entry.id, profileID: ProfileStore.shared.activeID)
        saved = SavedLinksStore.all(profileID: ProfileStore.shared.activeID)
    }

    private func play() {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("magnet:") {
            guard !PlaybackSettings.torrentsDisabled else {
                status = "Torrenting is disabled. Use a direct or debrid http(s) link."
                return
            }
            guard let magnet = OpenLinkMagnet.parse(text) else {
                status = "That magnet link has no usable info hash."
                return
            }
            playMagnet(magnet, link: text)
            return
        }
        // Recognise a streaming-service link (0.3.9 Phase 1: Twitch resolves in-app to HLS; YouTube is
        // detected but not yet resolved). Everything else falls through to the existing direct-link path.
        switch LinkResolver.detect(text) {
        case .twitch(let channel):
            playTwitch(channel: channel)
            return
        case .youtube(let videoID):
            playYouTube(videoID: videoID)
            return
        case .unsupported(let note):
            if let note { status = note; return }
            // Fall through: an unsupported classification just means "not a service link"; try it as a
            // plain http(s) / bare-host link below so existing direct-link behaviour is unchanged.
        case .direct:
            break
        }
        // A bare host or path with no scheme is almost always meant as https.
        if !text.contains("://"), text.contains(".") { text = "https://" + text }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            status = directLinksOnly
                ? "Not a playable link. Paste a direct http(s) stream link (debrid and usenet links count)."
                : "Not a playable link. Paste a direct http(s) stream link (debrid and usenet links count) or a magnet."
            return
        }
        let title = url.lastPathComponent.isEmpty ? (url.host ?? "Stream") : url.lastPathComponent
        onPlay(iOSPlayerLaunch(url: url, title: title))
    }

    /// Play a pasted YouTube link. DEVICE-DIRECT FIRST (yt-direct: InnerTube resolved on the user's own IP,
    /// full streamingData on a residential IP; an adaptive 1080p+ pair rides mpv's audio-file sidecar), then
    /// the remote resolver (trailer.vortx.tv/yt) EXACTLY as before when the direct resolve misses.
    private func playYouTube(videoID: String) {
        working = true
        status = "Resolving YouTube video…"
        resolveTask = Task { @MainActor in
            defer { working = false }
            let resolved = await YouTubeDirectResolver.resolve(videoID: videoID, maxHeight: 1080)
            guard !Task.isCancelled else { return }   // sheet closed mid-resolve → don't present the player
            if let resolved {
                NSLog("[yt-direct] iOS paste-link: %@ h=%d", resolved.isMuxed ? "direct-muxed" : "direct-pair", resolved.height)
                onPlay(iOSPlayerLaunch(url: resolved.videoURL, title: "YouTube",
                                       audioSidecarURL: resolved.audioURL))
            } else if let url = URL(string: "\(StremioServer.trailerResolverBase)/yt/\(videoID)") {
                NSLog("[yt-direct] iOS paste-link: fallback-worker")
                onPlay(iOSPlayerLaunch(url: url, title: "YouTube"))
            } else {
                status = "Couldn't open that YouTube link."
            }
        }
    }

    /// Resolve a live Twitch channel to its HLS master playlist (best-effort, off-main) and launch the
    /// existing player. A Twitch channel is LIVE, so the resolved `.m3u8` rides the same adaptive-HLS
    /// path as any live stream: PlayerScreen's runtime non-seekable detection treats it as live, and the
    /// paste-a-link launch carries no `meta`, so no Continue Watching entry or progress is ever written.
    private func playTwitch(channel: String) {
        working = true
        status = "Resolving Twitch channel…"
        resolveTask = Task { @MainActor in
            defer { working = false }
            let resolved = await LinkResolver.resolveTwitch(channel: channel)
            guard !Task.isCancelled else { return }   // sheet closed mid-resolve → don't present the player
            guard let url = resolved else {
                status = "Couldn't open that Twitch channel. It may be offline, or Twitch changed its API."
                return
            }
            onPlay(iOSPlayerLaunch(url: url, title: "Twitch: \(channel)"))
        }
    }

    private func playMagnet(_ magnet: OpenLinkMagnet.Magnet, link: String) {
        working = true
        status = "Fetching torrent info… this can take up to a minute"
        resolveTask = Task { @MainActor in
            defer { working = false }
            guard let resolution = await OpenLinkMagnet.resolve(magnet) else {
                if !Task.isCancelled {
                    status = "Could not fetch the torrent. No reachable peers, or a dead magnet."
                }
                return
            }
            guard !Task.isCancelled else { return }   // sheet closed mid-resolve → don't present the player
            switch resolution {
            case .single(let url, let fileName):
                let savedName = magnet.name ?? fileName
                onPlay(iOSPlayerLaunch(url: url, title: savedName))
                Task { await PlayedLinkLibrary.savePlayedTorrent(displayName: savedName) }   // #81
                // #81: if this magnet is in the user's Saved list, bind it to the exact file it just
                // resolved to, so re-opening rebuilds the play URL directly instead of re-resolving.
                SavedLinksStore.bindPlayedFile(magnetLink: link, playURL: url,
                                               profileID: ProfileStore.shared.activeID)
            case .choose(let files):
                status = nil
                magnetLink = link     // remember which magnet this picker belongs to, for the exact-file bind
                fileChoices = files   // a multi-file pack: show the picker, the user taps a file to play
            }
        }
    }

    /// The multi-file magnet picker: each video file in the pack as a tappable row (name + size).
    @ViewBuilder private func filePicker(_ files: [OpenLinkMagnet.TorrentFile]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            Text("Pick a file")
                .font(Theme.Typography.sectionTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
            Text("This magnet has \(files.count) videos. Choose which one to play.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textSecondary)
            ScrollView {
                VStack(spacing: Theme.Space.sm) {
                    ForEach(files) { file in
                        Button {
                            if let link = magnetLink {   // #81: bind the saved magnet to this chosen file
                                SavedLinksStore.bindPlayedFile(magnetLink: link, playURL: file.url,
                                                               profileID: ProfileStore.shared.activeID)
                            }
                            onPlay(iOSPlayerLaunch(url: file.url, title: file.name))
                            Task { await PlayedLinkLibrary.savePlayedTorrent(displayName: file.name) }   // #81
                        } label: {
                            HStack(spacing: Theme.Space.md) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(file.name)
                                        .font(Theme.Typography.body)
                                        .foregroundStyle(Theme.Palette.textPrimary)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    if file.sizeBytes > 0 {
                                        Text(ByteCountFormatter.string(fromByteCount: Int64(file.sizeBytes), countStyle: .file))
                                            .font(Theme.Typography.label)
                                            .foregroundStyle(Theme.Palette.textSecondary)
                                    }
                                }
                                Spacer(minLength: Theme.Space.sm)
                                Image(systemName: "play.fill").foregroundStyle(Theme.Palette.accent)
                            }
                            .padding(Theme.Space.md)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.Palette.surface1,
                                        in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Button("Back") { fileChoices = nil }
                .buttonStyle(ChipButtonStyle(selected: false))
        }
    }
}

/// Magnet parsing + resolution for the iOS `iOSOpenLinkView`, ported from the tvOS-only `LinkOpener`
/// (which can't be shared because it lives in the tvOS target). Builds on the shared `TorrentTrackers`
/// + `StremioServer`, both compiled into the iOS target.
private enum OpenLinkMagnet {
    struct Magnet { let infoHash: String; let name: String?; let trackers: [String] }

    /// One selectable video file inside a multi-file magnet (a season pack / playlist). `id` is the
    /// torrent file index used to build the `/{infoHash}/{idx}` play URL.
    struct TorrentFile: Identifiable { let id: Int; let name: String; let sizeBytes: Double; let url: URL }

    /// A resolved magnet: either one file to auto-play, or several videos for the user to choose from.
    enum Resolution { case single(url: URL, fileName: String); case choose([TorrentFile]) }

    static func parse(_ text: String) -> Magnet? {
        guard let comps = URLComponents(string: text), comps.scheme?.lowercased() == "magnet" else { return nil }
        var hash: String?
        var name: String?
        var trackers: [String] = []
        for item in comps.queryItems ?? [] {
            switch item.name.lowercased() {
            case "xt":
                guard let value = item.value, value.lowercased().hasPrefix("urn:btih:") else { break }
                let raw = String(value.dropFirst("urn:btih:".count))
                if raw.count == 40, raw.allSatisfy(\.isHexDigit) {
                    hash = raw.lowercased()
                } else if raw.count == 32 {
                    hash = base32ToHex(raw)
                }
            case "dn": name = item.value
            case "tr": if let t = item.value, !t.isEmpty { trackers.append("tracker:\(t)") }
            default: break
            }
        }
        guard let hash else { return nil }
        return Magnet(infoHash: hash, name: name, trackers: trackers)
    }

    /// Ask the embedded engine for the torrent; the create call returns once metadata is in (it needs
    /// at least one peer), with the file list. A single-video torrent (a movie plus the usual junk)
    /// auto-plays the one video as before; a multi-video torrent (a season pack / playlist) returns the
    /// list so the user can pick which file to play instead of silently getting just the biggest (#81).
    static func resolve(_ magnet: Magnet) async -> Resolution? {
        guard !PlaybackSettings.torrentsDisabled else { return nil }
        let sources = TorrentTrackers.sources(forHash: magnet.infoHash, streamSources: nil,
                                              addonTrackers: magnet.trackers)
        guard let createURL = URL(string: "\(StremioServer.base)/\(magnet.infoHash)/create") else { return nil }
        var request = URLRequest(url: createURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 75
        let payload: [String: Any] = [
            "torrent": ["infoHash": magnet.infoHash],
            "peerSearch": ["sources": sources, "min": 40, "max": 150],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        struct CreateResponse: Decodable {
            struct File: Decodable { let name: String?; let length: Double? }
            let files: [File]?
        }
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let response = try? JSONDecoder().decode(CreateResponse.self, from: data),
              let files = response.files, !files.isEmpty else { return nil }
        let videoExtensions: Set<String> = ["mp4", "mkv", "avi", "mov", "m4v", "ts", "webm", "wmv", "mpg", "mpeg"]
        func playURL(_ idx: Int) -> URL? { URL(string: "\(StremioServer.base)/\(magnet.infoHash)/\(idx)") }
        let indexed = Array(files.enumerated())
        let videos = indexed.filter { entry in
            let ext = (entry.element.name ?? "").split(separator: ".").last.map { String($0).lowercased() } ?? ""
            return videoExtensions.contains(ext)
        }
        // Multiple videos = a pack/playlist: hand back the list in natural name order (so episodes read
        // 1, 2, 3) for the user to choose from.
        if videos.count > 1 {
            let choices = videos
                .sorted { ($0.element.name ?? "").localizedStandardCompare($1.element.name ?? "") == .orderedAscending }
                .compactMap { entry -> TorrentFile? in
                    guard let url = playURL(entry.offset) else { return nil }
                    return TorrentFile(id: entry.offset, name: entry.element.name ?? "File \(entry.offset + 1)",
                                       sizeBytes: entry.element.length ?? 0, url: url)
                }
            if choices.count > 1 { return .choose(choices) }
        }
        // One video (or none): play the biggest file, exactly as before.
        guard let best = (videos.isEmpty ? indexed : videos).max(by: { ($0.element.length ?? 0) < ($1.element.length ?? 0) }),
              let url = playURL(best.offset) else { return nil }
        return .single(url: url, fileName: best.element.name ?? "Torrent")
    }

    /// #81: re-create the torrent on the embedded server (fire-and-forget) so a saved magnet's already
    /// bound file endpoint `/{infoHash}/{fileIdx}` is ready to serve. The engine ignores peerSearch on a
    /// torrent it already has, so this is a no-op if it's still alive and a cheap re-arm if it was reaped.
    static func warmUp(_ magnet: Magnet) {
        guard !PlaybackSettings.torrentsDisabled,
              let url = URL(string: "\(StremioServer.base)/\(magnet.infoHash)/create") else { return }
        let sources = TorrentTrackers.sources(forHash: magnet.infoHash, streamSources: nil,
                                              addonTrackers: magnet.trackers)
        let payload: [String: Any] = [
            "torrent": ["infoHash": magnet.infoHash],
            "peerSearch": ["sources": sources, "min": 40, "max": 150],
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        URLSession.shared.dataTask(with: request).resume()
    }

    /// RFC 4648 base32 (the older magnet info-hash encoding) to lowercase hex.
    private static func base32ToHex(_ raw: String) -> String? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var bits = 0, value = 0
        var bytes: [UInt8] = []
        for ch in raw.uppercased() {
            guard let idx = alphabet.firstIndex(of: ch) else { return nil }
            value = (value << 5) | idx
            bits += 5
            if bits >= 8 {
                bytes.append(UInt8((value >> (bits - 8)) & 0xFF))
                bits -= 8
            }
        }
        guard bytes.count == 20 else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// A poster grid (Library, Search, Discover) of tappable cards. Cards are `Button`s wired to an
/// `onTap(item)` router (instead of pushing a `NavigationLink` directly), so the SCREEN decides what a
/// tap means — across all three surfaces it now opens the title's detail (the hero is a decoupled
/// ambient billboard, #53), so there is no featured ring here.
///
/// Centering (#47): the adaptive columns are CENTER-aligned and the grid is constrained to the same
/// row width that gives even, balanced columns — a `.leading`-aligned adaptive grid bunched cards to
/// the left and left a ragged right gutter, which read as "left-aligned". Centering the columns and
/// the trailing remainder keeps the grid even across the width at every breakpoint (iPhone → Mac).
struct PosterGrid: View {
    let items: [RailItem]
    let onTap: (RailItem) -> Void
    /// Which long-press context menu each card shows on this surface (#14). `.none` for surfaces
    /// where no engine action applies.
    var menu: iOSPosterMenu = .none
    /// Called when the LAST card appears — the infinite-scroll hook for paginated grids (Discover).
    /// The grid stays generic; the caller decides whether and what to load next. nil = no pagination.
    var onReachEnd: (() -> Void)? = nil
    @EnvironmentObject private var theme: ThemeManager   // observe textScale so Theme.Typography repaints live
    @ObservedObject private var catalogPrefs = CatalogPreferences.shared
    @ObservedObject private var apiKeys = ApiKeys.shared
    @Environment(\.horizontalSizeClass) private var hSize
    // Center the adaptive tracks so the cards distribute evenly across the available width.
    private var columns: [GridItem] {
        // Track width must match the card width (PosterCardiOS.cardW) so grid + cards stay in lockstep and
        // the adaptive column count recomputes from the user's Poster Style preset. `.balanced` (the default)
        // returns today's 224 regular / 116 compact, so the default layout is unchanged.
        #if os(iOS)
        let compact = hSize == .compact
        #else
        let compact = false
        #endif
        let minTrack = iOSPillMetrics.gridPosterWidth(preset: catalogPrefs.posterWidth, compact: compact)
        return [GridItem(.adaptive(minimum: minTrack), spacing: Theme.Space.sm, alignment: .center)]
    }
    var body: some View {
        LazyVGrid(columns: columns, alignment: .center, spacing: Theme.Space.md) {
            ForEach(items) { item in
                Button { onTap(item) } label: {
                    PosterCardiOS(id: item.id, type: item.type, name: item.name, poster: item.poster, fallbackArt: item.background, imdbRating: item.imdbRating,
                                  progress: item.progress, resumeSeconds: item.resumeSeconds, menu: menu)
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(item.name)
                .accessibilityHint("Opens details")
                .accessibilityValue(item.progress > 0 ? "\(Int(item.progress * 100)) percent watched" : "")
                // Infinite scroll: when the last card materializes (LazyVGrid only builds visible
                // cells), ask the caller to load the next page. The engine + CoreBridge guards make
                // this a no-op at the end or while a page is already in flight.
                .onAppear { if item.id == items.last?.id { onReachEnd?() } }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Theme.Space.md)
    }
}

/// The BIG header for a nested collection GROUP (Streaming / Genres / Top New / New) on iOS / Mac: an
/// optional accent eyebrow over a screen-title-weight name with a short accent rule beneath, so a group
/// reads as a tier ABOVE its child rails (whose own headers use `PosterRail`'s `cardTitle`). Mirrors the
/// tvOS `GroupHeader`. `@EnvironmentObject theme` so the fonts repaint live with the text-scale setting.
struct iOSGroupHeader: View {
    var eyebrow: String? = nil
    let title: String
    @EnvironmentObject private var theme: ThemeManager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let eyebrow {
                Text(eyebrow)
                    .font(Theme.Typography.eyebrow).tracking(1.5).textCase(.uppercase)
                    .foregroundStyle(Theme.Palette.accent)
            }
            Text(title)
                .font(Theme.Typography.screenTitle).tracking(-1)
                .foregroundStyle(Theme.Palette.textPrimary)
            Rectangle()
                .fill(Theme.Palette.accent)
                .frame(width: 48, height: 3)
                .clipShape(Capsule())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Space.md)
        .padding(.top, Theme.Space.sm)
    }
}

private struct PosterRail: View {
    let title: String
    let items: [RailItem]
    let onTap: (RailItem) -> Void
    /// Which long-press context menu each card shows on this surface (#14).
    var menu: iOSPosterMenu = .none
    /// Opens a card's detail page (used by the Continue Watching menu's Details item, since a CW tap resumes).
    var onDetails: ((RailItem) -> Void)? = nil
    /// Horizontal infinite scroll: fired when the LAST card appears, so a Home catalog row loads its next
    /// page of items (#95). nil on rails that do not paginate (Continue Watching, editorial collections).
    var onReachEnd: (() -> Void)? = nil
    #if os(macOS)
    /// macOS keyboard browse: when Home passes its `@FocusState` binding, the rail's cards become
    /// `.focusable()` and join the native focus traversal (arrows move within / between rails, Enter
    /// fires the card's tap). Other callers (Search) and all of iOS leave this nil, so their cards are
    /// byte-for-byte unchanged (no `.focusable`, no ring). The rail is keyed by its `title`.
    var macFocus: FocusState<MacBrowseFocus?>.Binding? = nil
    #endif
    @EnvironmentObject private var theme: ThemeManager   // observe textScale so Theme.Typography repaints live
    /// Pointer hovering the rail (#3). Never fires on pure-touch iPhone, so the
    /// scroll arrows reveal only on Mac / iPad-with-trackpad, where swiping a long
    /// row is awkward. On touch the row stays swipe-only.
    @State private var hovering = false
    /// Left-edge index the arrows have paged to, so we can hide the back arrow at the start.
    @State private var pageIndex = 0
    private static let pageStride = 4

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(title).font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
                .padding(.horizontal, Theme.Space.md)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: Theme.Space.sm) {
                        ForEach(items) { item in
                            railCard(item, proxy: proxy)
                                // #95: horizontal infinite scroll. The last card pages the catalog (no-op
                                // on rails without onReachEnd: Continue Watching, editorial collections).
                                .onAppear { if item.id == items.last?.id { onReachEnd?() } }
                        }
                    }
                    .padding(.horizontal, Theme.Space.md)
                }
                .overlay(alignment: .leading) {
                    if showArrows && pageIndex > 0 { railArrow(forward: false) { page(by: -1, proxy) } }
                }
                .overlay(alignment: .trailing) {
                    if showArrows && pageIndex < items.count - 1 { railArrow(forward: true) { page(by: 1, proxy) } }
                }
            }
            // NOTE: the per-rail `.focusSection()` (MacRailFocusSection) was removed - it grouped cards for
            // NATIVE geometric arrow nav, which CONSUMED arrows before they could bubble to the ScrollView's
            // `.onMoveCommand` (advanceMacFocus). With it gone, advanceMacFocus is the single arrow-movement
            // authority and cards stay `.focusable()` only to show the ring. (Mac arrow-key nav; device-verify.)
        }
        .onHover { hovering = $0 }
    }

    /// One rail card. The touch/iOS body is identical across platforms; on macOS, when the rail opts in,
    /// the card additionally becomes `.focusable()` + shows the accent ring while focused and auto-scrolls
    /// into view, all additive modifiers so touch / VoiceOver / the existing tap + long-press are unchanged.
    @ViewBuilder private func railCard(_ item: RailItem, proxy: ScrollViewProxy) -> some View {
        let base = Button { onTap(item) } label: {
            PosterCardiOS(id: item.id, type: item.type, name: item.name, poster: item.poster, fallbackArt: item.background, caption: item.caption, imdbRating: item.imdbRating,
                          progress: item.progress, resumeSeconds: item.resumeSeconds, menu: menu,
                          onDetails: onDetails.map { od in { od(item) } })
        }
        .buttonStyle(.plain)
        .id(item.id)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.name)
        .accessibilityHint("Opens details")
        .accessibilityValue(item.progress > 0 ? "\(Int(item.progress * 100)) percent watched" : "")

        #if os(macOS)
        if let macFocus {
            let target = MacBrowseFocus.card(rail: title, item: item.id)
            base
                .focusable()
                .focused(macFocus, equals: target)
                .macFocusRing(macFocus.wrappedValue == target)
                // Keep the keyboard-focused card on screen as focus walks the row (the same scrollTo the
                // hover arrows use). Driven off focus change so it tracks both arrow moves and Tab landings.
                .onChange(of: macFocus.wrappedValue) { newValue in
                    if newValue == target { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(item.id, anchor: .center) } }
                }
        } else {
            base
        }
        #else
        base
        #endif
    }

    /// Arrows matter only when a pointer is present and the row actually overflows a page.
    private var showArrows: Bool { hovering && items.count > Self.pageStride }

    private func page(by direction: Int, _ proxy: ScrollViewProxy) {
        let next = max(0, min(items.count - 1, pageIndex + direction * Self.pageStride))
        pageIndex = next
        withAnimation(.easeOut(duration: 0.28)) {
            proxy.scrollTo(items[next].id, anchor: .leading)
        }
    }

    @ViewBuilder
    private func railArrow(forward: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: forward ? "chevron.right" : "chevron.left")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 60)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Theme.Space.xs)
        .transition(.opacity)
        .accessibilityLabel(forward ? "Scroll right" : "Scroll left")
    }
}

// The old image-only `iOSHeroBackdrop` was replaced by the interactive `FeaturedHeroView`
// (FeaturedHeroView.swift) on all three browse screens; its 16:9-art helpers now live on
// `FeaturedHeroItem`.

#if canImport(UIKit)
private typealias PlatformPosterImage = UIImage
#elseif canImport(AppKit)
private typealias PlatformPosterImage = NSImage
#endif

/// In-memory decoded-poster cache on top of the shared URLCache (disk). Keyed by URL, evicted under
/// memory pressure, so a poster shown in several rails decodes once.
private let posterMemoryCacheiOS: NSCache<NSURL, PlatformPosterImage> = {
    let c = NSCache<NSURL, PlatformPosterImage>(); c.countLimit = 400; return c
}()

/// Cached, self-retrying poster image for the iPhone / iPad / Mac rails and grids. Raw `AsyncImage` keeps
/// no cache and CANCELS its request when a Lazy cell recycles on scroll, without retrying, which is exactly
/// the on-device "some posters load, others stay blank" report. This loads via `.task(id:)` (re-runs on
/// every reappear, instant on a cache hit), treats a cancel as not-a-failure so the next appear retries,
/// and shows a film placeholder only on a real failure. Mirrors the tvOS PosterArt loader; the caller keeps
/// its own frame / crop / clip so the 120x180 fill-crop framing (F37) is unchanged.
struct CachedPosterImage: View {
    let url: String?
    @State private var image: PlatformPosterImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                imageView(image).resizable().scaledToFill()
            } else if failed {
                Theme.Palette.surface1.overlay(
                    Image(systemName: "film").font(.system(size: 28)).foregroundStyle(Theme.Palette.textTertiary))
            } else {
                Theme.Palette.surface1
            }
        }
        .task(id: url) { await load() }
    }

    private func imageView(_ img: PlatformPosterImage) -> Image {
        #if canImport(UIKit)
        Image(uiImage: img)
        #else
        Image(nsImage: img)
        #endif
    }

    private func load() async {
        failed = false
        guard let raw = url, !raw.isEmpty, let u = URL(string: raw) else { failed = true; return }
        if let cached = posterMemoryCacheiOS.object(forKey: u as NSURL) { image = cached; return }
        var req = URLRequest(url: u)
        req.cachePolicy = .returnCacheDataElseLoad   // posters are immutable: prefer the shared disk cache
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            guard !Task.isCancelled else { return }
            if let img = PlatformPosterImage(data: data) {
                posterMemoryCacheiOS.setObject(img, forKey: u as NSURL)
                image = img
            } else { failed = true }
        } catch {
            if !Task.isCancelled { failed = true }   // a cancel (scrolled away) is not a failure; the next appear retries
        }
    }
}

/// iOS/Mac cinematic landscape (16:9) catalog art, the touch twin of tvOS `LandscapeArt`: a clean
/// TEXTLESS TMDB backdrop resolved by id via `LandscapeBackdropCache`. With no TMDB backdrop (no key
/// set, or none on TMDB) it does NOT crop a 2:3 poster into an ugly slab: it fills with a heavily
/// blurred + darkened copy of the poster behind a fit copy, so the 16:9 frame always looks intentional.
private struct LandscapeArtiOS: View {
    let id: String
    let type: String
    let title: String
    let poster: String?
    @State private var image: PlatformPosterImage?
    @State private var logo: PlatformPosterImage?
    @State private var usedBackdrop = false
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                if usedBackdrop {
                    imageView(image).resizable().scaledToFill()
                        .overlay { titleLayer }
                } else {
                    imageView(image).resizable().scaledToFill()
                        .blur(radius: 18).opacity(0.55)
                        .overlay(Color.black.opacity(0.35))
                        .overlay(imageView(image).resizable().scaledToFit())
                }
            } else if failed {
                Theme.Palette.surface1.overlay(
                    Image(systemName: "film").font(.system(size: 24)).foregroundStyle(Theme.Palette.textTertiary))
            } else {
                Theme.Palette.surface1
            }
        }
        .task(id: id) { await load() }
    }

    /// The title ON the backdrop: the clean TMDB clearlogo when one resolves, else styled text, over a
    /// bottom scrim. GeometryReader so the logo scales to the (small) card.
    @ViewBuilder private var titleLayer: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                if let logo {
                    imageView(logo).resizable().scaledToFit()
                        .frame(maxWidth: geo.size.width * 0.62, maxHeight: geo.size.height * 0.44, alignment: .bottomLeading)
                        .padding(8)
                } else {
                    Text(title)
                        .font(.system(size: 13, weight: .bold)).lineLimit(2)
                        .foregroundStyle(.white).shadow(color: .black.opacity(0.6), radius: 3, y: 1)
                        .padding(8)
                }
            }
        }
    }

    private func imageView(_ img: PlatformPosterImage) -> Image {
        #if canImport(UIKit)
        Image(uiImage: img)
        #else
        Image(nsImage: img)
        #endif
    }

    private func load() async {
        failed = false; logo = nil
        let backdrop = await LandscapeBackdropCache.backdrop(id: id, type: type)
        usedBackdrop = backdrop != nil
        let raw = backdrop ?? PosterArtwork.poster(id: id, fallback: poster)
        guard let raw, !raw.isEmpty, let u = URL(string: raw) else { failed = true; return }
        guard let img = await fetchImage(u) else { if !Task.isCancelled { failed = true }; return }
        image = img
        // On a real backdrop, resolve the title clearlogo for the overlay (titleLayer falls back to text).
        if usedBackdrop, let lg = await LandscapeBackdropCache.logo(id: id, type: type), let lu = URL(string: lg) {
            logo = await fetchImage(lu)
        }
    }

    private func fetchImage(_ u: URL) async -> PlatformPosterImage? {
        if let cached = posterMemoryCacheiOS.object(forKey: u as NSURL) { return cached }
        var req = URLRequest(url: u)
        req.cachePolicy = .returnCacheDataElseLoad   // immutable art: prefer the shared disk cache
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            guard !Task.isCancelled, let img = PlatformPosterImage(data: data) else { return nil }
            posterMemoryCacheiOS.setObject(img, forKey: u as NSURL)
            return img
        } catch { return nil }
    }
}

/// Reused across rails on every surface: catalog rows, Continue Watching, the browse grid, and the detail
/// page's "More Like This" rail. Because it reads `CatalogPreferences` directly, every rail that uses it
/// honors the poster-orientation (landscape/portrait) and hide-labels settings consistently.
struct PosterCardiOS: View {
    let id: String
    let type: String
    let name: String
    let poster: String?
    /// Backdrop to fall back to when an add-on item carries no `poster` (AIOMetadata sometimes omits it),
    /// so the tile shows the title's art cropped to the card instead of a blank surface. Nil = no fallback.
    var fallbackArt: String? = nil
    /// A small secondary caption under the title (e.g. "S2E5 · Jun 30" on Upcoming Episodes). Nil hides it,
    /// so every other rail's card is unchanged.
    var caption: String? = nil
    /// IMDb rating to show as a small star badge on the poster, when the catalog item carries one. Nil hides it.
    var imdbRating: String? = nil
    let progress: Double
    /// The saved resume position in seconds, shown as a small "1:03" timecode badge on the poster (above
    /// the progress stripe) so Continue Watching cards say where playback resumes. Nil on every non-CW
    /// card, so their tiles are byte-for-byte unchanged.
    var resumeSeconds: Double? = nil
    /// Which long-press menu to attach (#14). `.none` attaches none.
    var menu: iOSPosterMenu = .none
    /// Per-card "open details" action, wired into the Continue Watching menu's Details item.
    var onDetails: (() -> Void)? = nil
    @ObservedObject private var catalogPrefs = CatalogPreferences.shared
    @ObservedObject private var apiKeys = ApiKeys.shared
    @ObservedObject private var l10n = LocalizedMetadataStore.shared   // localized title/poster override
    @EnvironmentObject private var theme: ThemeManager   // observe textScale so Theme.Typography repaints live
    @Environment(\.horizontalSizeClass) private var hSize

    /// The title to show: the pooled localized title in the user's language when available, else the add-on's.
    private var displayName: String { l10n.title(for: id) ?? name }
    /// The poster to show: the pooled localized (language-matched) poster when available, else the add-on's.
    private var displayPoster: String? { l10n.poster(for: id) ?? poster }

    /// Cinematic 16:9 landscape pill vs legacy 2:3 portrait poster, per the Appearance setting. Gated on
    /// a TMDB key so keyless users keep the clean portrait grid (no backdrop = degraded composite).
    private var landscape: Bool { catalogPrefs.landscapeCards && apiKeys.hasTMDB }
    // The Mac reuses these iOS cards on a wide desktop window, where the iPhone-sized constants render
    // far too small. Scale them up on macOS only; iPhone/iPad keep the original sizes.
    #if os(macOS)
    private static let macScale: CGFloat = 1.5
    #else
    private static let macScale: CGFloat = 1.0
    #endif
    // Card WIDTH comes from the user's Poster Style preset (default `.balanced` = today's 224 / 116). The
    // grid derives its adaptive column width from the SAME preset (iOSPillMetrics.gridPosterWidth), so grid
    // + cards stay in lockstep and the responsive column count recomputes from the chosen width. The height
    // follows the card's own aspect (16:9 landscape, 2:3 portrait) so posters aren't distorted.
    private var cardW: CGFloat {
        iOSPillMetrics.gridPosterWidth(preset: catalogPrefs.posterWidth, compact: isCompactWidth)
    }
    /// True on a compact-width class (iPhone portrait), where the preset uses its narrower compact widths.
    private var isCompactWidth: Bool {
        #if os(iOS)
        return hSize == .compact
        #else
        return false
        #endif
    }
    private var cardH: CGFloat { landscape ? cardW * 9.0 / 16.0 : cardW * 3.0 / 2.0 }
    /// The poster clip radius from the user's preset (default `.rounded` = Theme.Radius.card).
    private var cornerRadius: CGFloat { catalogPrefs.posterRadius.radius }

    var body: some View {
        card.modifier(PosterContextMenu(id: id, menu: menu, onDetails: onDetails))
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottom) {
                // Cached, self-retrying loader (not raw AsyncImage, which cancels on cell recycle and never
                // retries, the blank-poster cause). Landscape uses a clean TMDB backdrop (LandscapeArtiOS);
                // portrait crops the poster to the card so non-2:3 add-on posters fill cleanly (F37).
                Group {
                    if landscape {
                        LandscapeArtiOS(id: id, type: type, title: displayName, poster: displayPoster ?? fallbackArt)
                    } else {
                        CachedPosterImage(url: PosterArtwork.poster(id: id, fallback: displayPoster ?? fallbackArt))
                    }
                }
                    .frame(width: cardW, height: cardH)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .overlay(alignment: .topTrailing) {
                        // When a poster service bakes the rating into the image (VortX/XRDB or ERDB), skip
                        // the native overlay to avoid a double badge.
                        if let rating = imdbRating, !rating.isEmpty, !PosterArtwork.bakesRatings {
                            HStack(spacing: 2) {
                                Image(systemName: "star.fill").font(.system(size: 8))
                                Text(rating).font(.system(size: 10, weight: .semibold))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.black.opacity(0.6), in: Capsule())
                            .padding(5)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        // Continue Watching: the resume timecode ("1:03") sits just above the progress
                        // stripe so the card says where playback picks up, not only how far it got.
                        if let resumeSeconds, let timecode = resumeTimecode(resumeSeconds) {
                            Text(timecode)
                                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(.black.opacity(0.6), in: Capsule())
                                .padding(5)
                                // Lift clear of the 4pt progress stripe pinned to the very bottom.
                                .padding(.bottom, 4)
                        }
                    }
                if progress > 0.01 {
                    // A rounded progress track inset from the card edges (a capsule, not a square-cornered
                    // bar flush to the rounded poster) so it reads as an intentional part of the card.
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.black.opacity(0.45))
                            Capsule().fill(Theme.Palette.accent)
                                .frame(width: max(4, geo.size.width * progress))
                        }
                    }
                    .frame(height: 4)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
                }
            }
            .frame(width: cardW, height: cardH)
            // The title label is hidden when the user turns off poster labels in Poster Style (default:
            // shown). The caption (Upcoming Episodes "S2E5 · Jun 30") is a functional date, not a title, so
            // it stays visible even with labels hidden.
            if !catalogPrefs.hidePosterLabels {
                Text(displayName)
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1).frame(width: cardW, alignment: .leading)
            }
            // Optional secondary caption (Upcoming Episodes: "S2E5 · Jun 30"); absent on every other rail.
            if let caption {
                Text(caption)
                    .font(Theme.Typography.eyebrow)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .lineLimit(1).frame(width: cardW, alignment: .leading)
            }
        }
        // One contiguous tap + long-press target over the whole card (poster, the 6pt gap, and title).
        // Without it the .buttonStyle(.plain) label hit-tests as the UNION of its subview shapes, so the
        // inter-child gap and rounded-corner regions are dead zones that fall through to the adjacent
        // grid cell, the reported "tap a card in row 1, the row-2 item opens". Rectangle (not the
        // poster's RoundedRectangle) so the title and gap are inside the target and corners aren't dead.
        .frame(width: cardW, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// The long-press (`.contextMenu`) actions for a poster, ported from the tvOS `PosterCard.menuItems`.
/// Actions fire straight at the engine (`CoreBridge.shared`), exactly like tvOS; the affected rails
/// (Continue Watching / Library / catalog) refresh on their own when the engine re-emits the changed
/// fields. Only the actions that apply to the card's surface are shown. `.none` attaches no menu, so
/// a plain card on a hero-driven rail keeps its tap-only behaviour.
private struct PosterContextMenu: ViewModifier {
    let id: String
    let menu: iOSPosterMenu
    /// Opens the title's detail page. On a Continue Watching card a tap RESUMES the remembered stream,
    /// so the menu offers "Details" to reach the detail page instead (to pick a different episode or
    /// source) — the touch/Mac twin of what the user expects from a long-press on the tvOS row.
    var onDetails: (() -> Void)? = nil

    func body(content: Content) -> some View {
        if menu == .none {
            content
        } else {
            content.contextMenu { items }
        }
    }

    @ViewBuilder private var items: some View {
        switch menu {
        case .none:
            EmptyView()
        case .continueWatching:
            if let onDetails {
                Button { onDetails() } label: {
                    Label("Details", systemImage: "info.circle")
                }
            }
            Button(role: .destructive) {
                CoreBridge.shared.removeFromLibrary(id: id)
            } label: {
                Label("Remove from Continue Watching", systemImage: "minus.circle")
            }
        case .catalog:
            Button {
                CoreBridge.shared.addToLibrary(metaId: id)
            } label: {
                Label("Add to Library", systemImage: "plus.circle")
            }
            Button {
                CoreBridge.shared.setCatalogWatched(metaId: id, true)
            } label: {
                Label("Mark as Watched", systemImage: "checkmark.circle")
            }
            Button {
                CoreBridge.shared.setCatalogWatched(metaId: id, false)
            } label: {
                Label("Mark as Unwatched", systemImage: "circle")
            }
        case .library:
            Button {
                CoreBridge.shared.setLibraryItemWatched(id: id, true)
            } label: {
                Label("Mark as Watched", systemImage: "checkmark.circle")
            }
            Button {
                CoreBridge.shared.setLibraryItemWatched(id: id, false)
            } label: {
                Label("Mark as Unwatched", systemImage: "circle")
            }
            Button(role: .destructive) {
                CoreBridge.shared.removeFromLibrary(id: id)
            } label: {
                Label("Remove from Library", systemImage: "trash")
            }
        }
    }
}

// MARK: - Browse-screen chrome helpers (#46 wordmark, #53 scroll quiets the ambient hero)

extension View {
    /// The accent-tinted brand wordmark in the navigation bar's principal slot — warm-white "Stremio"
    /// with an ember "X", in the serif wordmark face — replacing the plain stock `.navigationTitle`
    /// that fell back to flat white in dark mode (#46). Mirrors the tvOS `HomeView.header` wordmark.
    /// The `pageTitle` is kept only as the bar's inline accessibility identity (and back-button
    /// context); the visible principal item is always the wordmark, applied across Home / Discover /
    /// Library / Search so the brand reads consistently.
    /// `isActive` is the macOS guard: a `.principal` item is hoisted into the shared window titlebar,
    /// and all seven tab screens stay mounted at once (opacity-switched to preserve state), so without
    /// this gate every browse screen stamps its own wordmark and they tile ("StremioX"×4). The
    /// conditional lives *inside* `@ToolbarContentBuilder` — branching the whole view instead would
    /// change the NavigationStack's structural identity and reset its scroll/path on every tab switch.
    @ViewBuilder
    func stremioWordmarkTitle(_ pageTitle: String, isActive: Bool = true) -> some View {
        // navigationTitle itself bridges into the single shared window toolbar on macOS, and with all
        // seven tab screens mounted at once (opacity-switched to preserve state) every browse screen
        // stamps its own title, so NSToolbar crashes inserting duplicate items (EXC_BREAKPOINT in
        // _insertNewItemWithItemIdentifier, the Beta 7 Mac crash). So the WHOLE title+toolbar path is
        // compile-gated to iOS. A compile-time gate (not a runtime branch) leaves the NavigationStack's
        // structural identity unchanged, so there is no scroll/path reset. On macOS the wordmark moves
        // into content (see FeaturedHeroView's macOS overlay); the title is dropped entirely here.
        #if os(iOS)
        navigationTitle(pageTitle)
            .navigationBarTitleDisplayModeInlineCompat()
            .toolbar {
                ToolbarItem(placement: .principal) {
                    if isActive {
                        // Brand lockup: serif "Vort" + the gold vortex mark as the "X" (follows the theme
                        // accent). Sized down for the nav bar; the horizontal padding widens the measured
                        // bounds so the chrome capsule clears the lockup.
                        VortXWordmark(fontSize: 26)
                            .padding(.horizontal, Theme.Space.xs)
                            .accessibilityAddTraits(.isHeader)
                    }
                }
            }
            // #4: a translucent (frosted) top bar, so the hero and content read as scrolling under a
            // blurred chrome rather than a flat opaque strip.
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        #else
        self
        #endif
    }

    /// A scroll/drag on a browse screen quiets the ambient hero rotation; the model resumes it after a
    /// spell of inactivity (#53). Implemented as a non-blocking `simultaneousGesture` so it observes
    /// the drag without intercepting the ScrollView's own scrolling.
    @ViewBuilder
    func scrollDismissesHeroRotation(model: FeaturedHeroModel) -> some View {
        // Arm the drag-observer only on iOS. On AppKit a ScrollView-level simultaneousGesture wins click
        // arbitration over the small .plain Buttons in the subtree (download play/icon buttons, hub /
        // streaming / Discover cards) and swallows their clicks. The hero is already quieted on macOS by
        // focus/move interaction, so dropping the gesture there costs nothing and restores card clicks.
        #if os(macOS)
        self
        #else
        simultaneousGesture(
            DragGesture(minimumDistance: 8)
                .onChanged { _ in model.noteInteraction() }
        )
        #endif
    }

    /// `.navigationBarTitleDisplayMode(.inline)` is unavailable on macOS; no-op there.
    @ViewBuilder fileprivate func navigationBarTitleDisplayModeInlineCompat() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// macOS pushed/detail views have NO toolbar back button (the whole window NSToolbar is removed to
    /// dodge the Beta 7 crash), so a Mac user had no way to go back and the keyboard did nothing. This
    /// overlays an in-content Back affordance in the top-leading corner AND wires Escape + Cmd-[ to pop the
    /// NavigationStack. iOS keeps the system back button, so this is a no-op there.
    @ViewBuilder func macBackAffordance() -> some View {
        #if os(macOS)
        modifier(MacBackAffordance())
        #else
        self
        #endif
    }
}

#if os(macOS)
/// The macOS in-content Back button + Escape / Cmd-[ shortcuts, factored into a modifier so it can read
/// `@Environment(\.dismiss)` (which pops the enclosing NavigationStack on a `navigationDestination`-pushed
/// view). The shortcut buttons are zero-size + hidden so they only register the key equivalents.
private struct MacBackAffordance: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topLeading) {
                Button { dismiss() } label: {
                    Label("Back", systemImage: "chevron.left")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .padding(.horizontal, Theme.Space.sm)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.leading, Theme.Space.md)
                .padding(.top, Theme.Space.md)
            }
            .background(
                // Hidden key-equivalent buttons: Escape and Cmd-[ both pop, matching macOS conventions.
                Group {
                    Button("") { dismiss() }.keyboardShortcut(.cancelAction).hidden()
                    Button("") { dismiss() }.keyboardShortcut("[", modifiers: .command).hidden()
                }
                .frame(width: 0, height: 0)
            )
    }
}
#endif

/// Cross-version empty state (ContentUnavailableView is iOS 17+; the deployment target is 16). An
/// optional `cta` adds a primary action button below the message so empty states across the browse
/// screens share one layout + button treatment (#44).
struct ContentUnavailableViewCompat: View {
    let title: String; let systemImage: String; let message: String
    /// Optional call to action: the button title plus its tap handler. nil = no button (the default).
    var cta: (title: String, action: () -> Void)? = nil
    @EnvironmentObject private var theme: ThemeManager   // observe textScale so Theme.Typography repaints live
    var body: some View {
        VStack(spacing: Theme.Space.md) {
            Image(systemName: systemImage).font(.system(size: 48)).foregroundStyle(Theme.Palette.textTertiary)
            Text(title).font(Theme.Typography.sectionTitle).foregroundStyle(Theme.Palette.textPrimary)
            Text(message).font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
                .multilineTextAlignment(.center)
            if let cta {
                Button(cta.title, action: cta.action).buttonStyle(PrimaryActionStyle())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, Theme.Space.xl)
        .background(Theme.Palette.canvas.ignoresSafeArea())
    }
}
