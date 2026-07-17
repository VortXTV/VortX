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

        /// Stable, unlocalized route name fed to the VXProbe diagnostic facility (heartbeat + nav
        /// events). Kept separate from `title` so probe output stays constant across locales.
        var probeName: String {
            switch self {
            case .home: return "Home"
            case .discover: return "Discover"
            case .live: return "Live"
            case .library: return "Library"
            case .search: return "Search"
            case .addons: return "Add-ons"
            case .settings: return "Settings"
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
    /// Measured height of the floated top chrome (search strip + nav pill). The content ZStack reserves
    /// exactly this via a top `.safeAreaInset` so Forms / Lists start below the chrome while a full-bleed
    /// hero passes under it. Seeded with a close estimate so the first frame is right before measurement
    /// lands; `MacTopChromeHeightKey` republishes the real value.
    @State private var macTopChromeHeight: CGFloat = 64
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
    /// Live connectivity (#120): drives the quiet "You're offline" strip and the one-shot offline
    /// launch routing below. The monitor debounces changes, so a brief flap never thrashes the shell.
    @ObservedObject private var connectivity = ConnectivityMonitor.shared
    /// One-shot latch for the offline LAUNCH routing (#120): set when the monitor's first verdict is
    /// consumed, so no later connectivity change can ever move tabs (mid-session offline = banner only).
    @State private var offlineLaunchRouted = false
    @AppStorage("stremiox.update.dismissedVersion") private var dismissedUpdateVersion = ""
    /// Per-tab bar visibility (#117): hide Live / Discover / Library / Search from the bar (Settings >
    /// Tab bar). Home, Add-ons, and Settings are not hideable, so the shell always keeps its landing
    /// anchor and the way back to this setting. Live keeps its extra behavior (the screen is not even
    /// mounted while hidden); its value is seeded from the legacy stremiox.hideLiveTab toggle in init.
    /// Selection heals to Home whenever the active tab is hidden (the onChange observers below).
    @AppStorage(TabBarPrefs.hideLive) private var hideLiveTab = false
    @AppStorage(TabBarPrefs.hideDiscover) private var hideDiscoverTab = false
    @AppStorage(TabBarPrefs.hideLibrary) private var hideLibraryTab = false
    @AppStorage(TabBarPrefs.hideSearch) private var hideSearchTab = false
    /// Merge Discover + Search into one surface (Settings toggle, default OFF, reversible). When ON the
    /// Search tab is dropped from the bar and Discover hosts an inline search field; OFF keeps them separate.
    @AppStorage("vortx.mergeDiscoverSearch") private var mergeDiscoverSearch = false
    @Environment(\.openURL) private var openURL
    /// The profile roster + launch-picker gate, shared with every surface. When the roster has more than
    /// one profile and none has been chosen this launch, the "Who's watching?" picker is owed at cold
    /// start (and re-presented from Settings' Switch Profile), exactly as tvOS RootView drives it.
    @EnvironmentObject private var profiles: ProfileStore
    /// Process-wide "a fullscreen player is up" signal. The tvOS launch picker gates on
    /// `presenter.request == nil`; on touch / Mac the player presents from within the shell, so this is
    /// the equivalent "no player cover is presented" guard.
    @ObservedObject private var playbackGate = FullscreenPlaybackGate.shared

    /// Seed the per-tab Live key from the legacy stremiox.hideLiveTab toggle before the first
    /// @AppStorage read, so a user who had hidden Live keeps it hidden across the #117 generalization.
    init() {
        TabBarPrefs.migrateLegacyLiveKey()
    }

    /// Whether a tab's screen should be mounted: only after its first selection (#24). The active tab
    /// is always mounted (covers the initial Home and any programmatic switch before onChange lands).
    private func isMounted(_ item: Tab) -> Bool {
        tab == item || visitedTabs.contains(item.rawValue)
    }

    /// The launch "Who's watching?" picker is owed when the roster has more than one profile and none has
    /// been chosen this launch (ProfileStore.needsPicker), with no fullscreen player up. The tvOS gate is
    /// `splashDone && needsPicker && presenter.request == nil`; iOSRootView has no splash of its own (the
    /// brand splash lives one level up in StremioXiOSApp), so per the shared design it gates on needsPicker
    /// alone here rather than inventing a splash flag.
    private var pickerOwed: Bool { profiles.needsPicker && !playbackGate.playerActive }

    /// The main shell is visible only once a profile has settled: while the picker is owed it is hidden
    /// behind brand canvas so no main-profile content (Continue Watching, Library) shows before a viewer is
    /// chosen. On Mac the picker presents as a centered sheet, so hiding the shell here is what keeps the
    /// owner's rails from showing around it too. Mirrors tvOS RootView.shellVisible.
    private var shellVisible: Bool { !pickerOwed }

    /// Presentation binding for the launch picker: shown while it is owed; dismissing it by any means marks
    /// the launch as picked (pickedThisLaunch), so it never re-appears until Settings' Switch Profile asks.
    /// Mirrors tvOS RootView.pickerPresented.
    private var pickerPresented: Binding<Bool> {
        Binding(
            get: { pickerOwed },
            set: { presented in if !presented { profiles.pickedThisLaunch = true } }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // Selected screen fills the whole window. Screens mount LAZILY on first visit (#24) and then
            // stay in this ZStack so each screen's own state (scroll position, search query, engine
            // subscriptions) survives a tab switch instead of being torn down and rebuilt. On macOS the
            // search strip + nav pill now FLOAT over this region (`macTopNavOverlay`) instead of an opaque
            // in-flow strip, so the Home / Library / Discover hero art bleeds to the window top behind the
            // chrome (no black canvas band); scroll screens reserve the chrome band below via the inset.
            ZStack {
                // `isActive` gates each browse screen's `.principal` wordmark: on macOS a principal
                // toolbar item is hoisted into the shared window titlebar, and every mounted
                // NavigationStack would otherwise stamp its own — tiling "StremioX" once per screen.
                // Only the visible tab contributes its wordmark (#46 regression).
                iOSHomeView(isActive: tab == .home).opacity(tab == .home ? 1 : 0)
                // Hidden tabs UNMOUNT, mirroring Live's long-standing gate (#117): a tab hidden in
                // Settings > Tab bar stops its background work (hero rotation, catalog refresh)
                // instead of idling at opacity 0. Safe because no route can land on a hidden tab
                // (the per-toggle healers + the macOS searchDestination rule fall back to Home).
                if !hideDiscoverTab, isMounted(.discover) { iOSDiscoverView(isActive: tab == .discover).opacity(tab == .discover ? 1 : 0) }
                if !hideLiveTab, isMounted(.live) { iOSLiveView().opacity(tab == .live ? 1 : 0) }
                if !hideLibraryTab, isMounted(.library) { iOSLibraryView(isActive: tab == .library).opacity(tab == .library ? 1 : 0) }
                if !mergeDiscoverSearch, !hideSearchTab, isMounted(.search) { iOSSearchView(isActive: tab == .search).opacity(tab == .search ? 1 : 0) }
                if isMounted(.addons) { AddonsView().opacity(tab == .addons ? 1 : 0) }
                if isMounted(.settings) { iOSSettingsView().opacity(tab == .settings ? 1 : 0) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            #if os(macOS)
            // Reserve the floated top-chrome band (search strip + nav pill, measured via
            // `MacTopChromeHeightKey`) so Forms / Lists (Settings, Add-ons, Library, Discover) start BELOW
            // the chrome instead of under it (the pill-covered-Settings report). Applied BEFORE the overlay
            // so the chrome still draws over the reserved strip. A full-bleed hero calls
            // `.ignoresSafeArea(.container, .top)` (FeaturedHeroView) so it passes UNDER this strip to the
            // window top; only respecting-safe-area scroll screens actually inset.
            .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: macTopChromeHeight) }
            #endif
            // MAC NAV MOVE (CEO greenlit, glass-Browse): macOS drives navigation + search from the floated
            // top chrome (`macTopNavOverlay`: the search strip with the top-center nav pill beneath it)
            // instead of the bottom bar. iOS/iPadOS keep the unchanged bottom tab bar (`bottomTabBarRow`,
            // a no-op on macOS). Both helpers gate on the same `#if os(macOS)` idiom, kept inside
            // @ViewBuilder vars so the conditional never splits a chained-modifier expression (which
            // SwiftUI's ViewBuilder cannot parse across an `#if`/`#else`).
            .overlay(alignment: .top) { macTopNavOverlay }
            #if os(macOS)
            // Feed the measured chrome height back into the reserve above (drift-proof vs a magic number).
            .onPreferenceChange(MacTopChromeHeightKey.self) { macTopChromeHeight = $0 }
            #endif

            bottomTabBarRow
        }
        .onChange(of: tab) { newTab in
            visitedTabs.insert(newTab.rawValue)   // lazy mount: remember every visit (#24)
            // Diagnostic-only: record the current surface for the heartbeat and log the tab switch.
            VXProbeState.shared.setRoute(newTab.probeName)
            VXProbe.event("nav", "tab \(newTab.probeName)")
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            // Offline strip above the update banner: both are shell-wide top inserts, so they stack
            // rather than fight over the one safe-area slot.
            // ORDER-DEPENDENT: this inset must stay applied BEFORE the shell-opacity modifier below
            // (i.e. inside the shell-opacity subtree) so both banners hide with the shell while the
            // profile picker is owed; hoisting it past .opacity(shellVisible) would strand a visible
            // banner floating over the picker.
            VStack(spacing: 0) {
                offlineBanner
                updateBanner
            }
        }
        // Hide the whole shell (screens, tab bar, update banner) behind brand canvas while the launch
        // "Who's watching?" picker is owed, so none of the main profile's rails leak before a viewer is
        // chosen. The canvas background below stays fully opaque behind the faded shell. tvOS twin:
        // RootView wraps RootTabView in the same opacity + disabled gate (shellVisible).
        .opacity(shellVisible ? 1 : 0)
        .disabled(!shellVisible)
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .tint(Theme.Palette.accent)
        .animation(.easeOut(duration: 0.25), value: updates.available?.build)
        .animation(.easeOut(duration: 0.25), value: dismissedUpdateVersion)
        .animation(.easeOut(duration: 0.25), value: connectivity.isOffline)
        // Offline-at-LAUNCH routing (#120): the monitor's FIRST verdict (and only that one) may redirect
        // the initial tab, so an app opened with no connection lands on something usable instead of a
        // dead Home: the Downloads surface when a completed download exists, else Settings. Strictly
        // one-shot and pre-navigation: the latch consumes the verdict, and the `tab == .home` guard
        // skips the redirect if the user already moved on their own (a late first verdict must never
        // yank navigation). Going offline MID-SESSION only shows the banner; when connectivity returns
        // the banner clears and the user stays exactly where they are.
        .onReceive(connectivity.$launchOffline) { verdict in
            guard let verdict, !offlineLaunchRouted else { return }
            offlineLaunchRouted = true
            guard verdict, tab == .home else { return }
            #if !os(tvOS)
            // Never route to a hidden tab (#117 x #120): with Library hidden the offline launch
            // falls through to Settings, which is unhideable.
            if !hideLibraryTab, downloads.records.contains(where: { $0.state == .completed }) {
                // The Downloads screen lives INSIDE the Library tab's NavigationStack (the pill's
                // value route), which the shell cannot reach directly: stage the push for the stack
                // to consume when it mounts, then switch to Library.
                iOSLibraryView.pendingDownloadsPush = true
                tab = .library
                return
            }
            #endif
            tab = .settings
        }
        // What's New is no longer shown on launch; it lives in Settings > What's New (the full changelog).
        // Automatic update popup: appears once per launch when a newer build exists (and again when the
        // hourly re-check finds a still-newer one), so users learn about updates without opening Settings.
        .sheet(item: $updates.prompt) { release in
            UpdatePromptView(release: release) { updates.dismissPrompt() }
        }
        .onChange(of: hideLiveTab) { hidden in
            if hidden, tab == .live { tab = .home }   // never leave the bar pointing at a hidden screen
        }
        // Same healing for the other hideable tabs (#117): hiding the ACTIVE tab lands on Home, so the
        // bar can never point at a screen it no longer shows (the tvOS RootTabView twin does the same).
        .onChange(of: hideDiscoverTab) { hidden in
            if hidden, tab == .discover { tab = .home }
        }
        .onChange(of: hideLibraryTab) { hidden in
            if hidden, tab == .library { tab = .home }
        }
        .onChange(of: hideSearchTab) { hidden in
            if hidden, tab == .search { tab = .home }
        }
        .onChange(of: mergeDiscoverSearch) { merged in
            // Search folds into Discover: if the bar was pointing at the now-dropped Search tab, land
            // on Discover, unless Discover itself is hidden in Settings > Tab bar (#117 rule: never
            // route to a hidden tab, fall back to Home like every other healer).
            if merged, tab == .search { tab = hideDiscoverTab ? .home : .discover }
        }
        .onAppear {
            updates.startMonitoring()   // launch check + hourly re-check while open
        }
        #if os(macOS)
        // macOS menu-bar commands (the "Go" menu + ⌘-shortcuts) post here, since they live at the
        // Scene level and can't set this @State directly. The raw value mirrors Tab's order.
        .onReceive(NotificationCenter.default.publisher(for: MacCommands.tabRequest)) { note in
            guard let raw = note.userInfo?["tab"] as? Int, let dest = Tab(rawValue: raw) else { return }
            // ⌘F lands the cursor in the persistent top-bar search field. The destination follows
            // the #117 rule: never route to a hidden tab, fall back to Home. `searchDestination`
            // resolves the merge fold (Discover when merged, else Search) BEFORE the hidden check,
            // so a hidden destination can never resurface with no tab selected in the bar.
            if dest == .search {
                macSearchFocused = true
                tab = searchDestination
                return
            }
            // Same rule for every other Go-menu destination: a tab hidden in Settings > Tab bar is
            // never routed to; fall back to Home instead of resurrecting a hidden screen.
            tab = hiddenTabs.contains(dest) ? .home : dest
        }
        #endif
        // Launch "Who's watching?" picker: a real modal at cold start when the roster has more than one
        // profile and none has been chosen this launch (ProfileStore.needsPicker), re-presented whenever
        // Settings' Switch Profile flips pickedThisLaunch back to false. `.platformFullScreenCover` is a
        // real fullScreenCover on iPhone / iPad and a sheet on Mac (which has no fullScreenCover). The
        // shell is hidden behind canvas while it is owed (opacity gate above), so nothing of the main
        // profile leaks behind it, matching the tvOS RootView flow. Selecting a profile goes through
        // ProfileStore.select via the shared ProfilePickerView, honoring the per-profile history invariant.
        // On macOS `platformFullScreenRootCover` hosts the picker WINDOW-FILLING at the scene root (via
        // MacProfileCoverHost / MacRootProfileCoverOverlay) instead of a content-sized `.sheet` that
        // clipped the trailing Add Profile circle off the window's right edge. iPhone / iPad keep a real
        // `.fullScreenCover`. The shell behind stays hidden by the opacity gate above.
        .platformFullScreenRootCover(isPresented: pickerPresented) { ProfilePickerView() }
    }

    #if os(macOS)
    /// The persistent macOS top strip: an always-visible search field, right-aligned. Pure in-content
    /// SwiftUI, NEVER `.toolbar`/`.searchable`/`navigationTitle`, which bridge into the shared window
    /// NSToolbar and crash (`_insertNewItemWithItemIdentifier`, the Beta 7 class). The leading inset
    /// clears the floating traffic lights over the hidden titlebar's full-size content. The brand
    /// wordmark used to anchor this strip's leading edge; it now lives on `macNavPill` (MAC NAV MOVE,
    /// glass-Browse), so this strip is search-only to avoid a duplicate mark.
    private var macTopBar: some View {
        HStack(spacing: Theme.Space.md) {
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
            .padding(.vertical, 4)
            .frame(maxWidth: 300)
            // Glass search field (redesign Phase A): the warm liquid-glass material replaces the flat
            // surface1 capsule so the top-bar search affordance matches the Mac home mockup. The field's
            // text, focus, submit, and clear-button behavior are unchanged; appearance only.
            .vortxGlass(in: Capsule(), fillAlpha: VortXGlass.pillFillAlpha, shadow: .pill)
        }
        // 84pt leading clears the traffic lights (~70pt of buttons + breathing room) restored by
        // MacWindowChrome over the hidden titlebar.
        .padding(.leading, 84)
        .padding(.trailing, Theme.Space.md)
        // Compact strip height so the search field reads light at the very top-right. The nav pill now
        // OVERLAPS this strip in the SAME top band (see `macTopNavOverlay`'s top-aligned ZStack), so this
        // height only positions the search field near the very top; it no longer stacks a second line below.
        .frame(height: 32)
        .frame(maxWidth: .infinity)
        .background {
            // The strip now FLOATS over the hero art (not an opaque canvas band that pushed the hero down),
            // so it is transparent except for a soft top-edge scrim that keeps the traffic lights + search
            // field legible over bright artwork; the hero's own top gradient does most of the darkening.
            // Over a scroll screen (Settings, Add-ons) the reserved inset shows canvas behind, so the scrim
            // is invisible there. Bleeds under the hidden-titlebar region so the scrim covers the whole strip.
            LinearGradient(colors: [Theme.Palette.canvas.opacity(0.55), .clear],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
        }
    }

    /// Where a search request lands (#117 rule: never route to a hidden tab, fall back to Home).
    /// Resolve the natural destination FIRST (merged mode folds Search into Discover, so merge on
    /// means Discover, else Search), then apply the hidden state: if the user hid THAT tab in
    /// Settings > Tab bar, land on Home, the same fallback every per-toggle healer uses. This covers
    /// all four hideSearchTab x mergeDiscoverSearch / hideDiscoverTab combinations: merge off routes
    /// to Search (Home when Search is hidden; hiding Discover is irrelevant), merge on routes to
    /// Discover (Home when Discover is hidden; the Search toggle is irrelevant, the tab is folded).
    private var searchDestination: Tab {
        let dest: Tab = mergeDiscoverSearch ? .discover : .search
        return hiddenTabs.contains(dest) ? .home : dest
    }

    /// Submit the top-bar query into the engine search flow: hand it to `MacSearchBridge` (consumed by
    /// the Search tab, or Discover in merged mode, possibly mounting for the first time) and switch there.
    private func submitMacSearch() {
        let q = macQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        // Never route to a hidden tab; fall back to Home (#117). Only queue the pending query when a
        // search surface will actually consume it, so a submit with the destination hidden cannot
        // leave a stale query that fires on a much later visit.
        let dest = searchDestination
        if dest != .home { MacSearchBridge.shared.pending = q }
        tab = dest
    }

    /// MAC NAV MOVE (CEO greenlit): the macOS navigation shell, restructured from the old bottom bar
    /// into a top-center floating glass pill (the Mac mockup): the VortX mark, then the SAME tab items
    /// as the bar (`tabButton`, `visibleTabs`), so tab identity / selection / scroll-to-top / the
    /// macOS keyboard focus-ring wiring carry over UNCHANGED — only the pill's position and the
    /// wordmark move. Structural on macOS ONLY (see the `#if os(macOS)` gate around this whole
    /// extension and around its call site in `body`); iOS/iPadOS keep `customTabBar` at the bottom.
    private var macNavPill: some View {
        HStack(spacing: Theme.Space.md) {
            VortXWordmark(fontSize: 18)
            Divider().frame(height: 20)
            HStack(spacing: Theme.Space.xs) {
                ForEach(visibleTabs, id: \.rawValue) { item in
                    // `tabButton` internally requests `.frame(maxWidth: .infinity)` (right, for the
                    // bottom bar's seven-equal-columns layout on iOS). `.fixedSize()` collapses that
                    // back to the item's intrinsic width here, so the PILL stays compact and centered
                    // instead of stretching to the full window width; `tabButton` itself, and its iOS
                    // callers, are unchanged. A small per-item horizontal pad + the row spacing above
                    // give the compact Mac pill breathing room between tabs.
                    tabButton(item).fixedSize().padding(.horizontal, Theme.Space.xs)
                }
            }
            // Same keyboard-browse focus section as the old bottom bar: arrows/Tab walk the pill,
            // Enter switches tabs.
            .focusSection()
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.xs)
        .vortxGlass(in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tabs")
    }
    #endif

    /// The floated macOS top chrome: the search strip (`macTopBar`) and the top-center nav pill
    /// (`macNavPill`) OVERLAID top-aligned in ONE band (a ZStack, not stacked lines), so the centered pill
    /// rises to sit nearly level with the search bar on the right rather than a full line beneath it (CEO
    /// ask: search + nav read as almost the same horizontal line, the whole cluster hugging the very top).
    /// Pill centered, search right, so on a normal-width window they do not collide. Floats OVER the content
    /// so the Home / Library / Discover hero art bleeds to the window top behind it (no opaque canvas band).
    /// `EmptyView` everywhere else. A
    /// `@ViewBuilder` var (not an inline `#if` inside a modifier chain) so `body` can unconditionally
    /// `.overlay` it without SwiftUI's ViewBuilder choking on an `#if`/`#else` split mid-chain. Its
    /// measured height is published via `MacTopChromeHeightKey` so `body` can reserve exactly this band
    /// (a top `.safeAreaInset`) for the scroll screens that must start below the chrome.
    @ViewBuilder private var macTopNavOverlay: some View {
        #if os(macOS)
        ZStack(alignment: .top) {
            macTopBar
            macNavPill
        }
        .background {
            GeometryReader { g in
                Color.clear.preference(key: MacTopChromeHeightKey.self, value: g.size.height)
            }
        }
        #else
        EmptyView()
        #endif
    }

    /// The iOS/iPadOS bottom tab bar row; a no-op on macOS, which drives navigation from
    /// `macTopNavOverlay` instead (MAC NAV MOVE). Kept as its own `@ViewBuilder` var for the same
    /// #if-inside-a-view-builder reason as `macTopNavOverlay`.
    @ViewBuilder private var bottomTabBarRow: some View {
        #if os(macOS)
        EmptyView()
        #else
        customTabBar
        #endif
    }

    /// Brand-styled bottom bar: seven equal items, each a small SF Symbol over a caption label. The
    /// selected item is tinted with the app accent; the rest read as tertiary text. A hairline +
    /// surface fill separates it from the content, and it respects the safe-area bottom inset.
    /// Tabs shown in the bar; any tab the user hid in Settings > Tab bar is dropped (#117).
    private var visibleTabs: [Tab] {
        Tab.allCases.filter {
            if hiddenTabs.contains($0) { return false }
            // Merged mode folds Search into Discover, so drop the standalone Search tab.
            if mergeDiscoverSearch, $0 == .search { return false }
            return true
        }
    }

    /// The tabs hidden by the per-tab Settings toggles (#117). Only the four hideable tabs can appear
    /// here; Home / Add-ons / Settings have no toggle, so the bar always keeps its anchors.
    private var hiddenTabs: Set<Tab> {
        var hidden: Set<Tab> = []
        if hideLiveTab { hidden.insert(.live) }
        if hideDiscoverTab { hidden.insert(.discover) }
        if hideLibraryTab { hidden.insert(.library) }
        if hideSearchTab { hidden.insert(.search) }
        return hidden
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
        // Floating glass pill (redesign Phase A): the tab items ride VortX's warm liquid-glass material,
        // inset from the screen edges with a soft drop shadow, so the bar reads as a floating element over
        // the canvas instead of a solid attached strip. RE-SKIN ONLY: the bar still holds its own row at
        // the bottom of the shell VStack (content never scrolls under it and is never obscured); only its
        // appearance floats. Selection, tap wiring, a11y, and the offline/update banners are untouched.
        .padding(.horizontal, Theme.Space.sm)
        .padding(.vertical, Theme.Space.xs)
        .vortxGlass(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.xs)
    }

    /// Quiet, persistent "You're offline" strip (#120), shown across every tab while the device has no
    /// network path. Deliberately NOT an alert and NOT the accent update banner: a subdued surface
    /// chip that says the app knows, points at what still works, and clears on its own when
    /// connectivity returns (the monitor's debounced signal, so a brief flap never flashes it).
    /// Signal only: it never navigates, and online surfaces stay reachable for cached browsing.
    @ViewBuilder private var offlineBanner: some View {
        if connectivity.isOffline {
            HStack(spacing: 8) {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 13, weight: .semibold))
                Text("You're offline. Downloads and Settings still work.")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.Palette.textSecondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background {
                Theme.Palette.surface1
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(Theme.Palette.hairline).frame(height: 0.5)
                    }
            }
            .accessibilityElement(children: .combine)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    /// Quiet update strip shown across every tab when a newer release is available and not yet
    /// dismissed for that version. Tapping opens the downloads page; the × remembers this version.
    @ViewBuilder private var updateBanner: some View {
        // Suppress while the modal popup is pending so the user isn't nagged twice; the banner is the quiet
        // fallback for after the popup is dismissed (dismissing it sets dismissedUpdateVersion, so the banner
        // then stays hidden for that build too).
        if let u = updates.available, u.key != dismissedUpdateVersion, updates.prompt == nil {
            // S10: a quiet surface strip with an accent icon/title, not a full solid-accent fill. The accent
            // is contractually focus / selection / primary / progress, not a passive-notice background; this
            // matches the offline strip's treatment (surface fill + bottom hairline) while still reading as
            // actionable via the accent icon and title.
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill").font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.Palette.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Update available").font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.Palette.accent)
                    Text("\(u.name) · tap to get it")
                        .font(.system(size: 12)).foregroundStyle(Theme.Palette.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Button { dismissedUpdateVersion = u.key } label: {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .padding(8).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss update notice")
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background {
                Theme.Palette.surface2
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(Theme.Palette.hairline).frame(height: 0.5)
                    }
            }
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
                    // Ember active pill behind the selected glyph, via the shared VortXGlass active token so
                    // every platform's selected nav item reads identically (redesign Phase A).
                    .background {
                        if selected {
                            Capsule().fill(VortXGlass.activeFill)
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

#if os(macOS)
/// Publishes the measured height of the floated macOS top chrome (search strip + nav pill) up to
/// `iOSRootView.body`, which reserves exactly this band via a top `.safeAreaInset` so Forms / Lists start
/// below the chrome while a full-bleed hero passes under it. `max` reduce so the largest reported band wins
/// (there is a single source, so this is just a safe default).
private struct MacTopChromeHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 64
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
#endif

private extension View {
    /// macOS: reclaim the top container safe area (the window titlebar / traffic-light band) so a
    /// full-bleed root view reaches the physical window top (y=0) instead of starting below the ~20pt
    /// titlebar strip. Applied to the Home NavigationStack so the billboard hero matches the Detail hero's
    /// edge-to-edge top (a scroll view nested inside the stack cannot reclaim past the stack's own frame,
    /// so the ignore has to sit on the stack). No-op on iOS / iPad (no titlebar strip; they already bleed).
    @ViewBuilder func macBleedUnderTitlebar() -> some View {
        #if os(macOS)
        ignoresSafeArea(.container, edges: .top)
        #else
        self
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
    @EnvironmentObject private var vortxSync: VortXSyncManager   // VortX-primary front door: a VortX sign-in unlocks the tabs even with no Stremio account connected
    @EnvironmentObject private var theme: ThemeManager   // observe textScale so Theme.Typography repaints live
    @EnvironmentObject private var profiles: ProfileStore   // gate Continue Watching on the active profile's own history
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showSignIn = false
    @StateObject private var hero = FeaturedHeroModel()
    @StateObject private var topPicks = TopPicksModel()   // local recommendations from this profile's history
    @StateObject private var becauseYouWatched = BecauseYouWatchedModel()   // "Because you watched <title>" rail, seeded from recent watches
    @StateObject private var traktRails = TraktRailsModel()   // Trakt watchlist as a client-side rail (dormant with empty creds)
    @StateObject private var simklRails = SIMKLRailsModel()   // SIMKL plan-to-watch as a client-side rail (dormant with empty creds)
    @StateObject private var mediaServerRails = MediaServerCatalogsModel()   // "Recently added" on connected Plex/Jellyfin/Emby servers (dormant with none)
    @StateObject private var releaseCalendar = ReleaseCalendarModel()   // "Upcoming Episodes" from the series library (next 45 days)
    @StateObject private var curated = CuratedCollectionsModel()   // editorial Cinemeta-backed rails (B3)
    @AppStorage("vortx.home.showCuratedRails") private var showCuratedRails = true   // owner-toggleable: hide the built-in editorial rails
    @ObservedObject private var collectionsHub = CollectionsHubModel.shared   // Collections hub (shared singleton)
    @ObservedObject private var imported = ImportedCatalogs.shared   // user-imported list catalogs, rendered as Home rows
    @ObservedObject private var railPrefs = HomeRailPreferences.shared   // user's Home row order + hidden set (Continue Watching stays pinned first)
    @AppStorage("vortx.home.showCollectionsHub") private var showCollectionsHub = true   // toggle the hub on Home (needs a TMDB key)
    @State private var path = NavigationPath()
    @State private var showCustomizeHome = false   // presents the Home rows reorder/hide editor
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
        // Continue Watching is pinned first (not part of HomeRailPreferences), matching the render order.
        if !continueWatchingItems.isEmpty { rails.append((String(localized: "Continue Watching"), continueWatchingItems.map(\.id))) }
        // Walk the SAME arranged, non-hidden order the body renders so keyboard traversal matches the screen.
        // Only the keyboard-navigable card rails contribute (the hub/upcoming/etc. rails were never in this
        // nav model); the rest are skipped, exactly as before, just now honoring order + hidden.
        for section in railPrefs.arrange(HomeRail.iOSDefaultOrder) where !railPrefs.isHidden(section) {
            switch section {
            case .topPicks:
                if !topPicks.items.isEmpty { rails.append((String(localized: "Top Picks for you"), topPicks.items.map(\.id))) }
            case .addonCatalogs:
                for row in core.boardRows where !row.items.isEmpty { rails.append((row.title, row.items.map(\.id))) }
            case .editorialCollections:
                if showCuratedRails {
                    for c in curated.collections where !c.items.isEmpty { rails.append((c.title, c.items.map(\.id))) }
                }
            default: break
            }
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
            + (showCuratedRails ? curated.collections.count : 0) + railPrefs.hidden.count
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
                    // The redesign mockup's ember "Featured" hero kicker (Home only; Library / Discover pass
                    // no eyebrow so their heroes are unchanged).
                    FeaturedHeroView(model: hero, onOpen: { path.append($0) }, eyebrow: String(localized: "Featured"))
                    // Once this marker (just below the hero) scrolls out of view, the floating
                    // back-to-top button appears; it hides again when you return to the top (#8).
                    // `active: isActive` keeps a hidden (opacity-switched) Home from writing stale state.
                    Color.clear.frame(height: 0).backToTopMarker(key: TabScrollKeys.home, active: isActive)
                    #if os(macOS)
                    // macOS has no navigation-bar toolbar on Home (custom chrome), and this app's shared
                    // NSToolbar is fragile (see the Sign In toolbar note below), so the "Customize Home"
                    // entry lives inline here as a subtle trailing button rather than in a toolbar.
                    HStack {
                        Spacer()
                        Button { showCustomizeHome = true } label: {
                            Label(String(localized: "Customize"), systemImage: "slider.horizontal.3")
                                .font(Theme.Typography.label)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.Palette.textSecondary)
                    }
                    .padding(.horizontal, Theme.Space.md)
                    #endif
                    if !continueWatchingItems.isEmpty {
                        // Continue Watching is PINNED first (not part of HomeRailPreferences): it is a resume
                        // queue stepped through in recency order, not a browse surface. A CW card tap resumes
                        // the exact last-played stream straight into the player (#11), falling back to opening
                        // detail when no remembered link fits. Long-press offers "Remove from Continue Watching".
                        homeRail(PosterRail(title: String(localized: "Continue Watching"),
                                            eyebrow: String(localized: "Pick up where you left off"),
                                            items: continueWatchingItems,
                                            onTap: handleContinueWatchingTap, menu: .continueWatching,
                                            onDetails: { path.append(FeaturedHeroItem.from(rail: $0)) }))
                    }
                    // Every other Home section renders in the user's arranged order, minus the hidden ones
                    // (HomeRailPreferences). Default order + nothing hidden == today's Home exactly, so this is
                    // a no-op until the user customizes via the "Customize Home" editor.
                    ForEach(railPrefs.arrange(HomeRail.iOSDefaultOrder)) { section in
                        if !railPrefs.isHidden(section) {
                            homeSection(section)
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
            // A floating back-to-top button appears once you scroll past the fold (#8); it bumps the same
            // signal as a tab re-tap, so it shares the anchor and animation above.
            .backToTopButton(key: TabScrollKeys.home, active: isActive)
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
            // Home black-band fix: let the Home ScrollView bleed UNDER the floated top chrome so the
            // billboard art reaches the very window top (search strip + nav pill float as glass over it),
            // instead of starting below the shell's reserved chrome band as a bare near-black strip (the
            // CEO's "big fat black bar"). The hero's own `.ignoresSafeArea(.container, .top)` cannot reclaim
            // the shell's top `.safeAreaInset` from INSIDE a scroll view (the ScrollView consumes it into a
            // content inset), so the ScrollView ITSELF must ignore that top region, the same way the Detail
            // hero (a fixed banner) already reaches the top. Scoped to the Home ROOT only: the pushed detail
            // page keeps the shell inset (its pinned banner bleeds on its own), and the list-first /
            // conditional-hero screens (Settings, Add-ons, Library, Discover) keep the inset so their top
            // content still starts below the pill. macOS-only; iOS/iPad already bleed with no shell inset.
            .ignoresSafeArea(.container, edges: .top)
            #endif
            .background(Theme.Palette.canvas.ignoresSafeArea())
            .stremioWordmarkTitle(String(localized: "Home"), isActive: isActive)
            // iOS-only: a runtime insert/remove of this trailing toolbar item when sign-in flips also
            // trips the shared-window NSToolbar on macOS (same crash class as the principal item). On
            // macOS sign-in lives in Settings -> Account ("VortX account & sync").
            #if os(iOS)
            .toolbar {
                // Always-present (never inserted/removed at runtime), so it never trips the NSToolbar churn
                // the conditional Sign In item is guarded against below. iOS uses a UINavigationBar here, so
                // it is safe regardless; the entry point on macOS is the inline button in the rail column.
                ToolbarItem(placement: .primaryAction) {
                    Button { showCustomizeHome = true } label: { Image(systemName: "slider.horizontal.3") }
                        .accessibilityLabel(Text("Customize Home"))
                }
                if !(account.isSignedIn || vortxSync.isSignedIn) {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Sign In") { showSignIn = true }
                    }
                }
            }
            #endif
            .sheet(isPresented: $showSignIn) { iOSSignInView() }
            .sheet(isPresented: $showCustomizeHome) { HomeRailEditorView() }
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
        // Home black-band follow-up: reclaim the last ~20pt window-titlebar strip so the billboard art
        // reaches y=0 like the Detail hero. The ScrollView-level ignore above reclaims the shell's floated
        // chrome band, but the NavigationStack still respects the window titlebar safe area, which a scroll
        // view inside it cannot punch through, so the stack itself ignores that top region. macOS-only.
        .macBleedUnderTitlebar()
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
        // Key Home refreshes off COARSE signals instead of `core.revision`, which bumps on EVERY NewState
        // (background sync, catalog paging, search echoes, meta_details bursts) and so re-ran Top Picks, the
        // Upcoming Episodes calendar, and the hero reseed on idle engine churn.
        //
        // THE RULE per signal: a BOUNDED collection is keyed on its EXACT ordered id set (zero missed changes);
        // an UNBOUNDED one is keyed on a "<first id>#<count>" FINGERPRINT plus a documented bound, because an
        // exact id key would be O(collection) work on EVERY body evaluation, the very storm this removes.
        //   - `profiles.cwItems` is BOUNDED (hard-capped at 30 in Profiles.cwItems `.prefix(30)`), so it keys on
        //     the exact ordered id set joined by a control char no id contains: insert, remove, reorder, AND an
        //     interior swap all fire; a pure progress tick does not.
        //   - `core.continueWatching` is UNBOUNDED: it is the engine `continue_watching_preview`, i.e. every
        //     in-progress library title, bounded only by the (unbounded) library, with no in-app cap. So it
        //     keeps the fingerprint. `core.library` (whole library) is the same case.
        //   - `core.boardRows` is small in practice but keeps the fingerprint too, DELIBERATELY: it feeds only
        //     the hero pool, where a miss is cosmetic and self-heals on the next distinguishing change, so the
        //     cheap key is worth the asymmetry with cwItems.
        // DOCUMENTED BOUND for the fingerprinted signals: a same-count interior swap in a SINGLE emit (one title
        // replaced by another at a non-head position) leaves first-id and count unchanged and does not fire; a
        // per-body content hash is deliberately avoided (this body re-evaluates far too often to hash an
        // unbounded collection each pass). The next real CW / board / profile change, or an app foreground,
        // reconciles it. No key fires on a pure progress tick (the set is unchanged), so the refresh models
        // still no-op and `hero.seed` ignores the no-op reseed. hero.seed stays gated on the visible tab
        // (`isActive`): `seed` re-arms the rotation timer, which a hidden (opacity-switched) Home must not do;
        // the isActive onChange reseeds on return.
        .onChange(of: "\(core.boardRows.first?.id ?? "-")#\(core.boardRows.count)") { _ in
            if isActive { hero.seed(heroCandidates, reduceMotion: reduceMotion) }
        }
        .onChange(of: "\(core.continueWatching.first?.id ?? "-")#\(core.continueWatching.count)") { _ in
            if isActive { hero.seed(heroCandidates, reduceMotion: reduceMotion) }; refreshTopPicks()
        }
        // An overlay profile draws its Continue Watching from `profiles.cwItems` (bounded, exact id-set key
        // above), not the engine, so its own plays must also re-seed the hero and Top Picks (the engine-CW
        // onChange never fires for them).
        .onChange(of: profiles.cwItems.map(\.id).joined(separator: "\u{1}")) { _ in
            if isActive { hero.seed(heroCandidates, reduceMotion: reduceMotion) }; refreshTopPicks()
        }
        .onChange(of: profiles.activeID) { _ in if isActive { hero.seed(heroCandidates, reduceMotion: reduceMotion) }; refreshTopPicks() }
        // Library membership drives both Top Picks (its seed set includes the library) and Upcoming Episodes.
        // Unbounded, so keyed on catalog.count with the same-count-swap bound documented above.
        .onChange(of: core.library?.catalog.count ?? 0) { _ in refreshTopPicks(); refreshReleaseCalendar() }
        // The Upcoming Episodes bases come from `account.addons`, which loads async after sign-in; rebuild
        // once they arrive (same input set as the notification sweep).
        .onChange(of: account.addons.count) { _ in refreshReleaseCalendar() }
        // Editorial-rails toggle: build them when turned on, drop them when turned off (the "extra
        // catalogs I can't remove from Home" report). The render + hero pool are gated on the same flag.
        .onChange(of: showCuratedRails) { show in if show { curated.load() } else { curated.clear() } }
        .onChange(of: showCollectionsHub) { show in if show { collectionsHub.load() } }   // no clear() on toggle-off: the render is already gated on showCollectionsHub, and clear() blanked the shared hub for the OTHER surface (Home vs Discover)
        // Addons hydrate ASYNC, after onAppear — so configureMetaSources(core.addons) above often ran with
        // an empty set, leaving tmdb:/tvdb:/kitsu: hero items un-enriched (no rating/logo/backdrop on Home,
        // Discover, Library CW). Re-configure + re-seed once addons arrive so enrichment can reach the
        // installed meta add-on, and rebuild Upcoming Episodes (its sweep also needs the meta add-ons).
        // tvOS already does this (HomeView/LiveView .onChange(of: core.addons.count)).
        .onChange(of: core.addons.count) { _ in FeaturedHeroModel.configureMetaSources(core.addons); if isActive { hero.seed(heroCandidates, reduceMotion: reduceMotion) }; refreshReleaseCalendar() }
        // Trakt disconnect: drop the watchlist rail immediately rather than waiting for the refresh window.
        .onReceive(NotificationCenter.default.publisher(for: TraktRailsModel.disconnectedNote)) { _ in traktRails.clear() }
        // SIMKL disconnect: same contract as Trakt above, drop the plan-to-watch rail now.
        .onReceive(NotificationCenter.default.publisher(for: SIMKLRailsModel.disconnectedNote)) { _ in simklRails.clear() }
        // A watchlist bookmark toggle feeds the Upcoming rails (refreshUpcoming folds it in), so rebuild them now.
        .onReceive(NotificationCenter.default.publisher(for: LibraryAutoAdd.watchlistChangedNote)) { _ in refreshReleaseCalendar() }
        .onDisappear { hero.stop() }
    }

    /// Render one reorderable Home section. Each case is the section's ORIGINAL block, unchanged, moved
    /// behind a stable `HomeRail` key so `HomeRailPreferences` can order + hide it. Continue Watching is
    /// pinned separately (above), so it has no case here. The internal gates (empty checks, `showCollectionsHub`,
    /// `showCuratedRails`, pagination) all still apply, so a hidden-off section is byte-identical to today.
    @ViewBuilder
    private func homeSection(_ section: HomeRail) -> some View {
        switch section {
        case .collectionsHub:
            // Collections hub (Discover cards, Streaming-service tiles, Genre tiles). Each tile pushes a
            // sub-catalog browse grid. Needs a TMDB key; hidden without one.
            if showCollectionsHub, CollectionsHubModel.isAvailable {
                iOSCollectionsHub(model: collectionsHub)
            }
        case .topPicks:
            // Local recommendations seeded from this profile's recent watch history (#0.3.9). Hidden when
            // there's no TMDB key, no history to seed from, or no results.
            if !topPicks.items.isEmpty {
                homeRail(PosterRail(title: String(localized: "Top Picks for you"),
                                    eyebrow: String(localized: "Based on what you watch"),
                                    items: topPicks.items.map {
                                        RailItem(id: $0.id, type: $0.type, name: $0.name,
                                                 poster: $0.poster, progress: 0)
                                    },
                                    onTap: handleTap, showWatchedBadges: true))
            }
        case .becauseYouWatched:
            // "Because you watched <title>": recommendations named after the most recent seed. Hidden when
            // there's no TMDB key, no eligible history, or no results.
            if let byw = becauseYouWatched.rail {
                homeRail(PosterRail(title: byw.title,
                                    items: byw.items.map {
                                        RailItem(id: $0.id, type: $0.type, name: $0.name,
                                                 poster: $0.poster, progress: 0)
                                    },
                                    onTap: handleTap, showWatchedBadges: true))
            }
        case .traktWatchlist:
            // Trakt watchlist as a client-side rail (opens the normal detail page by imdb id via handleTap).
            // Zero engine writes; hidden until Trakt is connected (dormant with empty creds).
            if !traktRails.items.isEmpty {
                homeRail(PosterRail(title: String(localized: "Trakt Watchlist"),
                                    eyebrow: String(localized: "From Trakt"),
                                    items: traktRails.items.map {
                                        RailItem(id: $0.id, type: $0.type, name: $0.name,
                                                 poster: $0.poster, progress: 0)
                                    },
                                    onTap: handleTap, showWatchedBadges: true))
            }
        case .simklWatchlist:
            // SIMKL plan-to-watch as a client-side rail (opens the normal detail page by imdb id via handleTap).
            // Zero engine writes; hidden until SIMKL is connected (dormant with empty creds). The read-back
            // half of SIMKL: before this the app only ever PUSHED to SIMKL and showed the user nothing.
            if !simklRails.items.isEmpty {
                homeRail(PosterRail(title: String(localized: "SIMKL Watchlist"),
                                    eyebrow: String(localized: "From SIMKL"),
                                    items: simklRails.items.map {
                                        RailItem(id: $0.id, type: $0.type, name: $0.name,
                                                 poster: $0.poster, progress: 0)
                                    },
                                    onTap: handleTap, showWatchedBadges: true))
            }
        case .mediaServers:
            // "Recently added on <server>": client-side rails from the user's own Plex/Jellyfin/Emby
            // servers, imdb-keyed cards that open the normal detail page. Hidden with no server.
            ForEach(mediaServerRails.rails) { rail in
                homeRail(PosterRail(title: rail.title,
                                    items: rail.items.map {
                                        RailItem(id: $0.id, type: $0.type, name: $0.name,
                                                 poster: $0.poster, progress: 0)
                                    },
                                    onTap: handleTap))
            }
        case .upcomingEpisodes:
            // "Upcoming Episodes": the next-airing episode of each series in the library within the next 45
            // days, soonest first. Each card is the SERIES with an "S2E5 · Jun 30" caption. Empty renders nothing.
            if !releaseCalendar.upcoming.isEmpty {
                homeRail(PosterRail(title: String(localized: "Upcoming Episodes"),
                                    eyebrow: String(localized: "Coming soon"),
                                    items: releaseCalendar.upcoming.map {
                                        RailItem(id: $0.seriesId, type: "series", name: $0.seriesName,
                                                 poster: $0.video.thumbnail, progress: 0,
                                                 caption: "\($0.episodeLabel) · \($0.airDateLabel)")
                                    },
                                    onTap: handleTap))
            }
        case .upcomingMovies:
            // "Upcoming Movies": library movies with a future release date in the next 45 days, soonest first;
            // hidden when nothing is upcoming. Each card routes to the movie detail like any card.
            if !releaseCalendar.upcomingMovies.isEmpty {
                homeRail(PosterRail(title: String(localized: "Upcoming Movies"),
                                    eyebrow: String(localized: "Coming soon"),
                                    items: releaseCalendar.upcomingMovies.map {
                                        RailItem(id: $0.id, type: "movie", name: $0.name,
                                                 poster: $0.poster, progress: 0, caption: $0.releaseDateLabel)
                                    },
                                    onTap: handleTap))
            }
        case .addonCatalogs:
            // Each installed add-on catalog as a horizontal rail. Per-catalog order/hiding is owned by
            // CatalogPreferences; this section moves the whole block. #95 horizontal + vertical pagination
            // stay attached exactly as before.
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
                                        onTap: handleTap, showWatchedBadges: true,
                                        onReachEnd: { core.loadBoardRowNextPage(engineIndex: row.engineIndex) }))
                        .onAppear {
                            if row.id == core.boardRows.last(where: { !$0.items.isEmpty })?.id {
                                core.loadBoardNextPage()
                            }
                        }
                }
            }
        case .editorialCollections:
            // Editorial collections (B3, Nuvio-style): hand-curated Cinemeta-backed rails below the add-on
            // rows. Each fails soft (an empty collection is dropped). Gated on the existing showCuratedRails.
            if showCuratedRails {
                ForEach(curated.collections) { collection in
                    homeRail(PosterRail(title: collection.title,
                                        items: collection.items.map {
                                            RailItem(id: $0.id, type: $0.type, name: $0.name,
                                                     poster: $0.poster, progress: 0)
                                        },
                                        onTap: handleTap, showWatchedBadges: true))
                }
            }
        case .importedLists:
            // Imported lists (Integrations -> Import a list): each public Letterboxd / MDBList / Trakt list
            // paints as its own Home row. Items are engine-safe ids, so a tap routes through the engine.
            ForEach(imported.catalogs) { catalog in
                if !catalog.isEmpty {
                    homeRail(PosterRail(title: catalog.title,
                                        items: catalog.items.map {
                                            RailItem(id: $0.id, type: $0.type, name: $0.name,
                                                     poster: $0.poster, progress: 0)
                                        },
                                        onTap: handleTap, showWatchedBadges: true))
                }
            }
        }
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
        becauseYouWatched.refresh(profileID: profiles.activeID, cw: cw, library: library)   // "Because you watched <title>" rail; no-ops on an unchanged seed set
        traktRails.refresh()   // Trakt watchlist rail; internally throttled + dormant with empty creds
        simklRails.refresh()   // SIMKL plan-to-watch rail; internally throttled + dormant with empty creds
        mediaServerRails.refresh()   // "Recently added" on connected media servers; throttled + dormant with none
    }

    /// Recompute "Upcoming Episodes" from the series library + the installed meta add-on bases — derived
    /// EXACTLY like the new-episode notification sweep (series-typed library ids + names, `providesMeta`
    /// add-on base URLs). The model no-ops when the series set is unchanged, so this is cheap to re-call.
    private func refreshReleaseCalendar() {
        let catalog = core.library?.catalog ?? []
        let bases = account.addons.filter { $0.providesMeta }.map(\.baseUrl)
        let series = catalog.filter { $0.type == "series" }
        let seriesNames = Dictionary(series.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let movies = catalog.filter { $0.type == "movie" }
        let movieNames = Dictionary(movies.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let moviePosters = Dictionary(movies.compactMap { m in m.poster.map { (m.id, $0) } }, uniquingKeysWith: { a, _ in a })
        // Fold the local watchlist into both Upcoming rails (refreshUpcoming) so a bookmarked-but-not-in-library
        // title still surfaces its next air / release date; library ids win on name / poster.
        releaseCalendar.refreshUpcoming(librarySeriesIDs: series.map(\.id), librarySeriesNames: seriesNames,
                                        libraryMovieIDs: movies.map(\.id), libraryMovieNames: movieNames,
                                        libraryMoviePosters: moviePosters, metaBases: bases)
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
        if account.isSignedIn || vortxSync.isSignedIn {
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

/// Reorder + hide the Home rows (iPhone / iPad / Mac). Drag to reorder, tap the eye to hide. Mirrors the
/// look of `iOSReorderServicesView` (forced edit mode on iOS, native drag on macOS) and writes straight to
/// `HomeRailPreferences`, so the live Home re-lays out as the user edits. Continue Watching is pinned first
/// and is intentionally not listed. Presented as a sheet, so it carries its own NavigationStack + Done.
struct HomeRailEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var prefs = HomeRailPreferences.shared
    private let defaults = HomeRail.iOSDefaultOrder

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(prefs.arrange(defaults)) { rail in
                        railRow(rail)
                            .listRowBackground(Theme.Palette.surface1)
                            .listRowSeparator(.hidden)
                    }
                    .onMove { prefs.moveRails(fromOffsets: $0, toOffset: $1, defaults: defaults) }
                } header: {
                    Text("Home rows")
                } footer: {
                    #if os(macOS)
                    Text("Drag to reorder. Tap the eye to hide a row. Continue Watching always stays at the top.")
                    #else
                    Text("Drag the handle to reorder. Tap the eye to hide a row. Continue Watching always stays at the top.")
                    #endif
                }

                Section {
                    Button(role: .destructive) { prefs.reset() } label: {
                        Label("Reset to default", systemImage: "arrow.counterclockwise")
                    }
                    .listRowBackground(Theme.Palette.surface1)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.Palette.canvas.ignoresSafeArea())
            #if os(iOS)
            .navigationTitle("Customize Home")
            .navigationBarTitleDisplayMode(.inline)
            .environment(\.editMode, .constant(.active))   // always show drag handles (matches the services editor)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            #endif
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 560)
        .overlay(alignment: .topTrailing) {
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .padding(Theme.Space.md)
        }
        #endif
    }

    private func railRow(_ rail: HomeRail) -> some View {
        let hidden = prefs.isHidden(rail)
        return HStack(spacing: Theme.Space.md) {
            Image(systemName: rail.systemImage)
                .foregroundStyle(hidden ? Theme.Palette.textTertiary : Theme.Palette.accent)
                .frame(width: 26)
            Text(rail.title)
                .font(Theme.Typography.cardTitle)
                .foregroundStyle(hidden ? Theme.Palette.textTertiary : Theme.Palette.textPrimary)
            Spacer(minLength: 0)
            Button { prefs.setHidden(rail, !hidden) } label: {
                Image(systemName: hidden ? "eye.slash" : "eye")
                    .foregroundStyle(hidden ? Theme.Palette.textTertiary : Theme.Palette.accent)
            }
            .buttonStyle(.borderless)   // stays tappable while the list is in edit mode
            .accessibilityLabel(Text(hidden ? "Show row" : "Hide row"))
        }
    }
}

/// Client-side type segmentation for the Library (Movies / TV / Anime). The engine's own type filter
/// only knows movie vs. series and cannot surface Anime, so the type row is derived here from each saved
/// title's meta type — a pure presentation grouping that leaves the engine's SORT chips and every
/// per-item action (open / remove / watched) untouched.
private enum LibrarySegment: String, CaseIterable, Identifiable {
    case all, movies, tv, anime
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: return String(localized: "All")
        case .movies: return String(localized: "Movies")
        case .tv: return String(localized: "TV")
        case .anime: return String(localized: "Anime")
        }
    }

    /// The bucket a saved title falls into. Library entries carry no genre field, so Anime is detected
    /// from an explicit "anime" meta type or an anime-catalog id scheme (Kitsu / AniList / MAL / AniDB);
    /// everything else splits on movie vs. the rest (series / channel / tv fold into TV).
    static func bucket(id: String, type: String) -> LibrarySegment {
        if type == "anime" { return .anime }
        let lower = id.lowercased()
        if ["kitsu:", "anilist:", "mal:", "anidb:"].contains(where: lower.hasPrefix) { return .anime }
        return type == "movie" ? .movies : .tv
    }
}

/// Client-side SMART filters for the Library: saved "smart lists" (Unwatched / In Progress / Watched /
/// Short) evaluated as predicates over each saved title, auto-updating as the library and its watch state
/// change. They read ONLY fields a library entry already carries (the read-only watched signal, engine
/// watch `progress`, and the engine's stored media runtime), so nothing here touches the account or the
/// engine's own type/sort filters. Multi-select and AND-combined, so combinations read as one smart list
/// ("Unwatched" + "Short" = unwatched short films). A field the entry does not carry (e.g. runtime for a
/// title never played) simply does not match, it never crashes.
private enum LibrarySmartFilter: String, CaseIterable, Identifiable {
    case unwatched, inProgress, watched, short
    var id: String { rawValue }
    var label: String {
        switch self {
        case .unwatched:  return String(localized: "Unwatched")
        case .inProgress: return String(localized: "In Progress")
        case .watched:    return String(localized: "Watched")
        case .short:      return String(localized: "Short")
        }
    }

    /// Runtime strictly under this many milliseconds counts as "Short" (100 minutes).
    private static let shortRuntimeMs: Double = 100 * 60 * 1000
    /// The actively-resumable band: played into, but below the engine's own 0.9 finished ceiling.
    private static let inProgressCeil = 0.9

    /// Whether a saved title matches this filter. `watched` is the platform's read-only watched signal;
    /// `progress` is 0…1 watch progress; `durationMs` is the engine's stored media duration (0 when the
    /// title was never played, so its runtime is unknown, so "Short" cannot match it and the title is
    /// simply left out rather than crashing).
    func matches(watched: Bool, progress: Double, durationMs: Double) -> Bool {
        switch self {
        case .unwatched:  return !watched
        case .watched:    return watched
        case .inProgress: return progress > 0 && progress < Self.inProgressCeil
        case .short:      return durationMs > 0 && durationMs < Self.shortRuntimeMs
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
    @ObservedObject private var watchedIndex = WatchedIndex.shared   // read-only watched signal for the smart filters (#143 set refreshes reactively)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var hero = FeaturedHeroModel()
    // NavigationPath (not `[FeaturedHeroItem]`): the Downloads pill pushes a `LibraryRoute` VALUE, and a
    // heterogeneous path needs the type-erased container. A typed `[FeaturedHeroItem]` binding also
    // DISABLES any view-destination `NavigationLink` in the subtree (SwiftUI can't encode it into the
    // typed path); that is the root cause of the dead Downloads pill (#25).
    @State private var path = NavigationPath()
    /// Active client-side type segment (Movies / TV / Anime); `.all` keeps the flat, mixed grid.
    @State private var segment: LibrarySegment = .all
    /// Active client-side smart filters (Unwatched / In Progress / Watched / Short); empty = no filtering.
    /// Multi-select and AND-combined; applied on top of the type segment and the engine's sort.
    @State private var activeFilters: Set<LibrarySmartFilter> = []
    #if !os(tvOS)
    @ObservedObject private var downloads = DownloadStore.shared   // offline downloads section (#30)
    @State private var downloadPlayer: iOSPlayerLaunch?            // play-from-local cover
    #endif

    /// Non-detail Library pushes (value-routed so they work alongside the typed detail destinations).
    enum LibraryRoute: Hashable {
        case downloads
        case queue        // the download-queue manager (reorder / pause / concurrency), pushed from Downloads
    }

    #if !os(tvOS)
    /// One-shot handoff from the offline LAUNCH routing (#120): the Downloads screen lives inside THIS
    /// tab's NavigationStack, which the shell cannot reach directly, so iOSRootView stages the push
    /// here and switches to the Library tab; the freshly-mounted stack consumes it in onAppear.
    /// Main-thread only (set and read on the SwiftUI update path).
    static var pendingDownloadsPush = false
    #endif

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
                    // are saved titles), so its Play / Trailer buttons stay tappable. The client-side
                    // type segment (Movies / TV / Anime) and the engine sort chip row (#15) sit between
                    // the hero and the grid, mirroring the tvOS Library; long-press on a card offers the
                    // engine's library actions (#14). A clean gap separates the hero from the chips (#52).
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
                            // Client-side type segment (Movies / TV / Anime) for BOTH owner and overlay
                            // profiles, replacing the engine's type chips; the engine's SORT chips stay
                            // owner-only (they need the engine `selectable`).
                            segmentBar(libraryItems)
                            if profiles.activeUsesEngineHistory, let lib = core.library {
                                sortChips(lib.selectable)
                            }
                            // Smart filters (Unwatched / In Progress / Watched / Short) sit below the type
                            // segment and sort row. The grid's `RailItem` drops the runtime + watched signal
                            // the predicates need, so they are evaluated on the source `CoreCWItem`s and the
                            // RailItem grid is then narrowed to the matching ids.
                            smartFilterBar(segmentedSource())
                            PosterGrid(items: smartFiltered(segmented(libraryItems), pass: smartPassIDs(segmentedSource())),
                                       onTap: handleTap, menu: .library)
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
                case .queue: DownloadQueueView()
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
            #if !os(tvOS)
            // Offline launch routing handoff (#120), already-mounted case: hidden tabs stay mounted
            // forever (opacity-switched, #24), so a Library visited earlier in the session gets NO
            // fresh onAppear when the shell routes back to it; without this, the staged push would be
            // swallowed silently and the flag stranded true. The onAppear consume below still covers
            // the fresh first mount; the flag flips false on whichever consumes first, so the push
            // can never fire twice.
            if active, Self.pendingDownloadsPush {
                Self.pendingDownloadsPush = false
                path.append(LibraryRoute.downloads)
            }
            #endif
            if active { hero.seed(heroCandidates, reduceMotion: reduceMotion) } else { hero.stop() }
        }
        .onAppear {
            #if !os(tvOS)
            // Offline launch routing handoff (#120), fresh-mount case: land directly on the Downloads
            // screen when the shell staged it (the app opened offline and a completed download exists).
            if Self.pendingDownloadsPush {
                Self.pendingDownloadsPush = false
                path.append(LibraryRoute.downloads)
            }
            #endif
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

    /// The engine's SORT chip row (#15), mirroring the tvOS `LibraryView.sortChips`: each chip carries
    /// the engine's own `request` and dispatches it back via `core.selectLibrary` on tap. The library
    /// re-emits and the grid + hero refresh on their own. The type row is now the client-side
    /// `segmentBar`, so only the sorts are dispatched through the engine here.
    @ViewBuilder private func sortChips(_ selectable: CoreLibrarySelectable) -> some View {
        // Route through the shared ChipButtonStyle (like Search's link button): a selected chip is a
        // soft-accent pill with accent ink, so on-chip text follows onAccent and stays legible on
        // light accents (#39) — the old solid-accent + hardcoded-white chip went invisible.
        chipScroll { ForEach(selectable.sorts) { s in
            Button(AddonTerms.localize(s.label)) { core.selectLibrary(s.request) }
                .buttonStyle(ChipButtonStyle(selected: s.selected)) } }
    }

    /// The client-side type segment chips (All / Movies / TV / Anime), rendered with the shared
    /// `ChipButtonStyle` so they match every other filter chip. Shown only when the library actually
    /// spans two or more buckets — a single-type library keeps the flat grid with no redundant control.
    @ViewBuilder private func segmentBar(_ items: [RailItem]) -> some View {
        let segs = availableSegments(items)
        if !segs.isEmpty {
            let active = effectiveSegment(segs)
            chipScroll { ForEach(segs) { seg in
                Button(seg.label) { segment = seg }
                    .buttonStyle(ChipButtonStyle(selected: seg == active)) } }
        }
    }

    /// `All` plus each bucket that actually holds titles, in a stable Movies / TV / Anime order. Returns
    /// empty (hiding the control) when fewer than two buckets are present.
    private func availableSegments(_ items: [RailItem]) -> [LibrarySegment] {
        var present: Set<LibrarySegment> = []
        for it in items { present.insert(LibrarySegment.bucket(id: it.id, type: it.type)) }
        let ordered = [LibrarySegment.movies, .tv, .anime].filter(present.contains)
        return ordered.count >= 2 ? [.all] + ordered : []
    }

    /// The selected segment clamped to what's on offer, so removing the last title of a kind falls back
    /// to `All` instead of stranding the grid on an empty, now-unavailable segment.
    private func effectiveSegment(_ available: [LibrarySegment]) -> LibrarySegment {
        available.contains(segment) ? segment : .all
    }

    /// Filter the library items to the active segment (`All` passes everything through unchanged).
    private func segmented(_ items: [RailItem]) -> [RailItem] {
        let seg = effectiveSegment(availableSegments(items))
        guard seg != .all else { return items }
        return items.filter { LibrarySegment.bucket(id: $0.id, type: $0.type) == seg }
    }

    /// The owner profile's saved titles are the account library (engine `CoreCWItem`s); an overlay
    /// profile's are its own private watch overlay. This is the SOURCE the smart filters read: the grid's
    /// `RailItem` drops the media runtime + watched signal the predicates need, so they are evaluated here.
    private var sourceItems: [CoreCWItem] {
        profiles.activeUsesEngineHistory ? (core.library?.catalog ?? []) : profiles.libraryItems
    }

    /// The source titles filtered to the active type segment, so the smart-filter chips + predicate track
    /// the current Movies / TV / Anime tab (mirrors what `segmented(libraryItems)` does for the grid).
    private func segmentedSource() -> [CoreCWItem] {
        let seg = effectiveSegment(availableSegments(libraryItems))
        guard seg != .all else { return sourceItems }
        return sourceItems.filter { LibrarySegment.bucket(id: $0.id, type: $0.type) == seg }
    }

    /// The client-side SMART filter chips (Unwatched / In Progress / Watched / Short), rendered with the
    /// shared `ChipButtonStyle` so they match every other filter chip. Only chips that actually SPLIT the
    /// current grid (match some but not all titles) are shown, so there are never dead or no-op controls.
    @ViewBuilder private func smartFilterBar(_ items: [CoreCWItem]) -> some View {
        let applicable = applicableFilters(items)
        if !applicable.isEmpty {
            let active = Set(effectiveFilters(items))
            chipScroll { ForEach(applicable) { f in
                Button(f.label) { toggle(f) }
                    .buttonStyle(ChipButtonStyle(selected: active.contains(f))) } }
        }
    }

    /// The per-profile watched signal, honoring the history invariant: the owner reads the engine's own
    /// watched bookkeeping (plus the derived series-completion set), an overlay reads only its private
    /// overlay, never the account. Read-only.
    private func isWatched(_ item: CoreCWItem) -> Bool {
        if watchedIndex.ids.contains(item.id) { return true }
        return profiles.activeUsesEngineHistory
            ? item.isWatched
            : !profiles.watchedVideoIds(forMeta: item.id).isEmpty
    }

    /// Does a title match this smart filter, reading its already-present fields (the read-only watched
    /// signal, engine watch progress, and the engine's stored media runtime in ms)?
    private func matches(_ f: LibrarySmartFilter, _ item: CoreCWItem) -> Bool {
        f.matches(watched: isWatched(item), progress: item.progress, durationMs: item.state.duration)
    }

    /// Smart filters that meaningfully split the given (type-segmented) list: each matches at least one
    /// title but not all. A filter matching every title, or none, would be a no-op, so it is hidden.
    private func applicableFilters(_ items: [CoreCWItem]) -> [LibrarySmartFilter] {
        let total = items.count
        guard total > 0 else { return [] }
        return LibrarySmartFilter.allCases.filter { f in
            let n = items.reduce(0) { $0 + (matches(f, $1) ? 1 : 0) }
            return n > 0 && n < total
        }
    }

    /// The active filters clamped to what still splits the current grid, so switching type segment (or the
    /// library changing under a selection) never strands the grid on a filter that no longer applies.
    private func effectiveFilters(_ items: [CoreCWItem]) -> [LibrarySmartFilter] {
        applicableFilters(items).filter { activeFilters.contains($0) }
    }

    /// The ids of source titles matching EVERY active-and-applicable smart filter (AND-combined), or nil
    /// when none is active, so the grid then passes through untouched.
    private func smartPassIDs(_ items: [CoreCWItem]) -> Set<String>? {
        let eff = effectiveFilters(items)
        guard !eff.isEmpty else { return nil }
        var ids = Set<String>()
        for it in items where eff.allSatisfy({ matches($0, it) }) { ids.insert(it.id) }
        return ids
    }

    /// Narrow the RailItem grid to the ids that passed the smart filters. `nil` = no active filter, so the
    /// grid is unchanged.
    private func smartFiltered(_ items: [RailItem], pass: Set<String>?) -> [RailItem] {
        guard let pass else { return items }
        return items.filter { pass.contains($0.id) }
    }

    /// Toggle a smart filter. Unwatched and Watched are mutually exclusive, so enabling one clears the
    /// other and the combined predicate never asks for the impossible (a permanently empty grid).
    private func toggle(_ f: LibrarySmartFilter) {
        if activeFilters.contains(f) {
            activeFilters.remove(f)
        } else {
            activeFilters.insert(f)
            if f == .watched { activeFilters.remove(.unwatched) }
            if f == .unwatched { activeFilters.remove(.watched) }
        }
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
            // Grouped: each series is ONE folder holding its episodes sorted season-then-episode (regardless
            // of download order); a movie renders as a standalone row. The grouping is derived from the shared
            // store, so this iOS/Mac screen renders the SAME per-show folders as the Apple TV downloads screen.
            ForEach(store.groupedDownloads()) { group in
                if group.isShow {
                    showFolder(group)
                } else if let movie = group.records.first {
                    row(movie)
                }
            }
        }
    }

    // MARK: Show folder

    /// One show's downloads as a folder (iOS/Mac): a folder header (title + episode count + size) with its
    /// episodes listed beneath, already sorted season-then-episode by the shared store. Mirrors
    /// `TVDownloadsView` so both surfaces render the same per-show folders from `groupedDownloads()`. Each
    /// episode reuses the standard row, titled "S1E2" (the header carries the show name), so the existing
    /// per-item play / retry / delete actions stay intact.
    @ViewBuilder private func showFolder(_ group: DownloadGroup) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            folderHeader(group)
            VStack(spacing: Theme.Space.sm) {
                ForEach(group.records) { record in
                    row(record, title: episodeTitle(record))
                }
            }
            .padding(.leading, Theme.Space.md)   // indent the episodes under their folder
        }
    }

    /// The folder's header: a folder glyph, the show title, and a "N episodes · size" caption. A static label
    /// (the tappable targets are the per-episode rows below it).
    private func folderHeader(_ group: DownloadGroup) -> some View {
        HStack(alignment: .center, spacing: Theme.Space.sm) {
            Image(systemName: "folder.fill")
                .font(.system(size: 20))
                .foregroundStyle(Theme.Palette.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.title)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
                Text(folderCaption(group))
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.xs)
    }

    private func folderCaption(_ group: DownloadGroup) -> String {
        let episodes = group.count == 1
            ? String(localized: "1 episode")
            : String(localized: "\(group.count) episodes")
        return "\(episodes)  ·  \(store.recordedSize(of: group.records))"
    }

    /// The per-episode title inside a folder: "S1E2" (or "E2" with no season), falling back to the full
    /// display title for a record with no episode numbering.
    private func episodeTitle(_ record: DownloadRecord) -> String {
        if let s = record.season, let e = record.episode { return "S\(s)E\(e)" }
        if let e = record.episode { return "E\(e)" }
        return record.displayTitle
    }

    // MARK: Row

    /// `title` overrides the row heading (a show folder titles each episode "S1E2" instead of repeating the
    /// show name); nil uses the record's own display title (movies + standalone rows).
    @ViewBuilder private func row(_ record: DownloadRecord, title: String? = nil) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.md) {
            leadingGlyph(record)
            VStack(alignment: .leading, spacing: 4) {
                Text(title ?? record.displayTitle)
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
        // glass-Browse: a bespoke card row, not routed through a shared row style, so it flips straight
        // to the glass card preset instead of the flat surface1 fill.
        .vortxSettingsCard()
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
                return [String(localized: "Downloading \(pct)%"), record.retryNote].compactMap { $0 }
            case .paused:
                return [String(localized: "Paused"), record.retryNote].compactMap { $0 }
            case .failed:
                // Keep the honest retry note alongside the failure, so a doubly-failed batch episode reads
                // "Failed · Retried with next-best source", not a bare "Failed" that hides the auto-swap (#119).
                return [record.errorText ?? String(localized: "Failed"), record.retryNote].compactMap { $0 }
            case .queued:
                return [String(localized: "Queued"), record.retryNote].compactMap { $0 }
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
                    Text(count == 1 ? "1 item" : "\(count) items")
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
            // glass-Browse: the Downloads pill is bespoke chrome, so it flips straight to the glass card
            // preset instead of the flat surface1 fill.
            .vortxSettingsCard()
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
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                // Header entry into the download-queue manager (reorder / pause / concurrency). VALUE-based
                // link (#25): routes through iOSLibraryView's navigationDestination(for: LibraryRoute.self),
                // never a view-destination NavigationLink (silently disabled under the explicit typed path).
                NavigationLink(value: iOSLibraryView.LibraryRoute.queue) {
                    HStack(spacing: Theme.Space.sm) {
                        Image(systemName: "arrow.up.arrow.down.circle.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(Theme.Palette.accent)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Download Queue")
                                .font(Theme.Typography.cardTitle)
                                .foregroundStyle(Theme.Palette.textPrimary)
                            Text("Reorder, pause, and set how many run at once")
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
                    .vortxSettingsCard()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                DownloadsView(onPlay: { launch in downloadPlayer = launch })
            }
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
                               menu: .catalog, showWatchedBadges: true)
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
    @EnvironmentObject private var vortxSync: VortXSyncManager   // VortX-primary front door: a VortX sign-in unlocks the tabs even with no Stremio account connected
    @EnvironmentObject private var theme: ThemeManager   // observe textScale so Theme.Typography repaints live
    @AppStorage(TabBarPrefs.hideLive) private var hideLiveTab = false   // also hide Live types from the Discover type filter (#117 per-tab key)
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
    @ObservedObject private var catalogPrefs = CatalogPreferences.shared
    /// Presents the advanced filter panel (genre / year / age rating / duration / seasons / upcoming).
    @State private var showFilters = false
    /// Below this many matching cards, while more pages exist, auto-load the next page so a strict filter
    /// still fills the grid instead of stranding a few cards. Bounded: the engine stops handing out
    /// `discoverHasNextPage` at the catalog end. Mirrors the tvOS Discover auto-fill.
    private let filterFillFloor = 18
    /// Current calendar year, used by the year-window + upcoming-only filters.
    private static let currentYear = Calendar.current.component(.year, from: Date())

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
                // S4: Discover stacks its rails at lg (32) so its vertical rhythm matches Home / Library /
                // Search; it was the lone surface at md (20), reading as a tighter, inconsistent column.
                LazyVStack(alignment: .leading, spacing: Theme.Space.lg) {
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
                    // Below the hero: once this marker scrolls away the back-to-top button appears (#8).
                    // This marker lives only in the browse branch, so `active: isActive` suffices here.
                    Color.clear.frame(height: 0).backToTopMarker(key: TabScrollKeys.discover, active: isActive)
                    if showCollectionsHub, CollectionsHubModel.isAvailable {
                        iOSCollectionsHub(model: collectionsHub)
                    }
                    if let discover = core.discover {
                        // The filter rows are their own vertically-stacked band: each chip row gets its
                        // own line with consistent spacing so a row's pills can never be drawn on top
                        // of the row above it (#7).
                        VStack(alignment: .leading, spacing: Theme.Space.xs) {
                            filterBar(discover)
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
                        discoverResults(discover)
                    } else if account.isSignedIn || vortxSync.isSignedIn {
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
            // Floating back-to-top button once you scroll past the fold (#8); bumps the same signal.
            // Suppressed while the inline-search results are up (that mode drops the browse marker), so the
            // button can't strand over search results.
            .backToTopButton(key: TabScrollKeys.discover,
                             active: isActive && !(mergeDiscoverSearch && hasSearchQuery))
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
            // Advanced filter panel. Presented as a sheet (never a `.toolbar` item, which realizes on the
            // single shared macOS window toolbar and crashes in _insertNewItemWithItemIdentifier, the same
            // NSToolbar-insert crash class the wordmark/search items are gated for).
            .sheet(isPresented: $showFilters) {
                if let discover = core.discover {
                    iOSDiscoverFilterPanel(prefs: catalogPrefs,
                                           genreOptions: genreOptions(discover),
                                           showSeasons: isSeriesContext(discover)) { showFilters = false }
                }
            }
        }
        // Re-tapping the active Discover tab pops a pushed detail/category browse back to root (#22).
        .popToRootOnBump(TabScrollKeys.discover, path: $path)
        // Keep the filtered grid full: when a page settles or the filter set changes, pull the next page
        // while too few cards match and more pages exist (loadDiscoverNextPage self-guards duplicate loads).
        .onChange(of: core.discover?.items.count ?? 0) { _ in autoFillFilteredGrid() }
        .onChange(of: catalogPrefs.discoverFilters) { _ in autoFillFilteredGrid() }
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
        .onChange(of: showCollectionsHub) { show in if show { collectionsHub.load() } }   // no clear() on toggle-off: the render is already gated on showCollectionsHub, and clear() blanked the shared hub for the OTHER surface (Home vs Discover)
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
        // glass-Browse: the merged Discover search field is bespoke chrome (not routed through a shared
        // row/chip style), so it flips straight to the glass field preset instead of the flat surface1 fill.
        .vortxGlassField(in: Capsule())
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
                               menu: .catalog, showWatchedBadges: true)
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

    // MARK: Advanced filters (shared DiscoverFilters model)

    /// The Filters entry: an active-count badge, plus a one-tap Clear when a filter is on. Sits above the
    /// engine type/catalog/genre chip rows so it reads as the "advanced" layer over the catalog's own extras.
    private func filterBar(_ discover: CoreDiscover) -> some View {
        let filters = catalogPrefs.discoverFilters
        return HStack(spacing: Theme.Space.sm) {
            Button { showFilters = true } label: {
                Label(filters.isActive ? "Filters (\(filters.activeCount))" : "Filters",
                      systemImage: "line.3.horizontal.decrease.circle")
            }
            .buttonStyle(ChipButtonStyle(selected: filters.isActive))
            if filters.isActive {
                Button { catalogPrefs.discoverFilters = .empty } label: { Text("Clear") }
                    .buttonStyle(ChipButtonStyle(selected: false))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.md)
    }

    /// The visible catalog cards: `discover.items` narrowed by the active filters (shared
    /// `DiscoverFilters.matches`), then de-duped by id (paginated catalogs repeat titles across pages, and a
    /// grid `ForEach` keyed by id would warn and drop later cells). Identical to the old path when no filter
    /// is active, so the unfiltered browse is byte-for-byte unchanged.
    private func shownMetas(_ discover: CoreDiscover) -> [CoreMeta] {
        let filters = catalogPrefs.discoverFilters
        let raw = filters.isActive
            ? discover.items.filter { filters.matches($0, currentYear: Self.currentYear) }
            : discover.items
        return dedupedMetasById(raw)
    }

    /// The results band: a "N shown / Clear" summary while a filter is on, a clear empty state when a filter
    /// matches none of the loaded items, otherwise the poster grid. Mirrors the tvOS Discover results.
    @ViewBuilder private func discoverResults(_ discover: CoreDiscover) -> some View {
        let filters = catalogPrefs.discoverFilters
        let shown = shownMetas(discover)
        if filters.isActive, !discover.items.isEmpty {
            HStack(spacing: Theme.Space.sm) {
                Text("\(shown.count) shown").font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
                Button { catalogPrefs.discoverFilters = .empty } label: { Text("Clear filters") }
                    .buttonStyle(ChipButtonStyle(selected: false))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.md)
        }
        if filters.isActive, shown.isEmpty, !discover.items.isEmpty {
            ContentUnavailableViewCompat(title: "No matches", systemImage: "line.3.horizontal.decrease.circle",
                message: "No results match your filters.").frame(minHeight: 360)
        } else {
            PosterGrid(items: shown.map {
                RailItem(id: $0.id, type: $0.type, name: $0.name, poster: $0.poster, progress: 0,
                         background: $0.background, description: $0.description,
                         releaseInfo: $0.releaseInfo, imdbRating: $0.imdbRating, genres: $0.genres)
            }, onTap: handleTap, showWatchedBadges: true, onReachEnd: { core.loadDiscoverNextPage() })
        }
    }

    /// Load another Discover page when an active filter has left the visible grid thin and the catalog still
    /// has pages. No-op with no filters, at the catalog end, or while a page is already loading.
    private func autoFillFilteredGrid() {
        let filters = catalogPrefs.discoverFilters
        guard filters.isActive, let discover = core.discover, core.discoverHasNextPage else { return }
        let shownCount = discover.items.filter { filters.matches($0, currentYear: Self.currentYear) }.count
        if shownCount < filterFillFloor { core.loadDiscoverNextPage() }
    }

    /// The genre labels offered by the filter panel: the engine's declared genre extra first, then genres
    /// present in the loaded items, then a curated anime supplement when the catalog is anime. Deduped
    /// case-insensitively, first-seen order. Mirrors the tvOS `genreOptions`.
    private func genreOptions(_ discover: CoreDiscover) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        func add(_ g: String) {
            let trimmed = g.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { return }
            out.append(trimmed)
        }
        if let extra = discover.selectable.extra.first(where: { $0.name.caseInsensitiveCompare("genre") == .orderedSame }) {
            for opt in extra.options { if let v = opt.value { add(AddonTerms.localize(v)) } }
        }
        for item in discover.items { for g in (item.genres ?? []) { add(g) } }
        if isAnimeContext(discover) { for g in DiscoverFilterOptions.animeGenres { add(g) } }
        return out
    }

    /// Whether the current catalog is anime (explicit type, an anime id scheme, or an "Anime" genre tag);
    /// drives the anime-genre supplement. Mirrors the tvOS `isAnimeContext`.
    private func isAnimeContext(_ discover: CoreDiscover) -> Bool {
        if discover.selectable.types.first(where: { $0.selected })?.type.caseInsensitiveCompare("anime") == .orderedSame { return true }
        let animeSchemes = ["kitsu:", "anilist:", "mal:", "anidb:"]
        if discover.items.prefix(16).contains(where: { m in animeSchemes.contains { m.id.lowercased().hasPrefix($0) } }) { return true }
        return discover.items.prefix(24).contains { ($0.genres ?? []).contains { $0.caseInsensitiveCompare("anime") == .orderedSame } }
    }

    /// Whether to show the season-count section (series / anime catalogs).
    private func isSeriesContext(_ discover: CoreDiscover) -> Bool {
        guard let t = discover.selectable.types.first(where: { $0.selected })?.type.lowercased() else { return false }
        return t == "series" || t == "anime"
    }
}

// MARK: - Discover filter panel (iOS / macOS)

/// The touch/Mac advanced Discover filter sheet: genre include/exclude (tri-state chips), a release-year
/// window (decade chips read as a range), an upcoming-only switch, age ratings, a runtime window, and a
/// season-count window (series). Every control binds to the shared `CatalogPreferences.discoverFilters`, so a
/// change persists and the grid behind the sheet re-filters live. Mirrors the tvOS `DiscoverFilterPanel` on
/// the same shared model / option catalogs / `ChipButtonStyle`, presented as a sheet (never a `.toolbar`
/// item, which crashes the single shared macOS window toolbar).
struct iOSDiscoverFilterPanel: View {
    @ObservedObject var prefs: CatalogPreferences
    let genreOptions: [String]
    let showSeasons: Bool
    let onClose: () -> Void

    private var f: DiscoverFilters { prefs.discoverFilters }
    private func update(_ change: (inout DiscoverFilters) -> Void) {
        var next = prefs.discoverFilters
        change(&next)
        prefs.discoverFilters = next
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                headerRow
                if !genreOptions.isEmpty { genreSection }
                yearSection
                ageSection
                durationSection
                if showSeasons { seasonSection }
            }
            .padding(.horizontal, Theme.Space.md)
            .padding(.vertical, Theme.Space.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
    }

    // MARK: sections

    private var headerRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.md) {
            Text("Filters").font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
            Spacer(minLength: Theme.Space.md)
            if f.isActive {
                Button { prefs.discoverFilters = .empty } label: { Text("Clear all") }
                    .buttonStyle(ChipButtonStyle(selected: false, accent: Theme.Palette.danger, accentText: Theme.Palette.danger))
            }
            Button { onClose() } label: { Text("Done") }
                .buttonStyle(ChipButtonStyle(selected: true))
        }
    }

    private var genreSection: some View {
        section("Genres", caption: "Tap to include, tap again to exclude.") {
            ForEach(genreOptions, id: \.self) { g in
                let state = f.genreState(g)
                Button { update { $0.cycleGenre(g) } } label: {
                    HStack(spacing: 6) {
                        Text(g).lineLimit(1)
                        if state == .include { Image(systemName: "plus") }
                        else if state == .exclude { Image(systemName: "minus") }
                    }
                }
                .buttonStyle(ChipButtonStyle(
                    selected: state != .off,
                    accent: state == .exclude ? Theme.Palette.danger : Theme.Palette.accent,
                    accentText: state == .exclude ? Theme.Palette.danger : Theme.Palette.accent))
            }
        }
    }

    private var yearSection: some View {
        section("Release years", caption: "Pick a decade, or two to span a range. Upcoming keeps this year and later.") {
            ForEach(DiscoverFilterOptions.decades) { d in
                Button { toggleDecade(d) } label: { Text(d.label) }
                    .buttonStyle(ChipButtonStyle(selected: selectedDecades.contains(d.id)))
            }
            Button { update { $0.upcomingOnly.toggle() } } label: {
                Label("Upcoming only", systemImage: "clock")
            }
            .buttonStyle(ChipButtonStyle(selected: f.upcomingOnly))
        }
    }

    private var ageSection: some View {
        section("Age rating", caption: nil) {
            ForEach(DiscoverFilterOptions.ageRatings, id: \.self) { r in
                Button {
                    update { if $0.ageRatings.contains(r) { $0.ageRatings.remove(r) } else { $0.ageRatings.insert(r) } }
                } label: { Text(r) }
                    .buttonStyle(ChipButtonStyle(selected: f.ageRatings.contains(r)))
            }
        }
    }

    private var durationSection: some View {
        section("Duration", caption: nil) {
            ForEach(DiscoverFilterOptions.durationBuckets) { b in
                Button { toggleDuration(b) } label: { Text(b.label) }
                    .buttonStyle(ChipButtonStyle(selected: f.minMinutes == b.min && f.maxMinutes == b.max && (b.min != nil || b.max != nil)))
            }
        }
    }

    private var seasonSection: some View {
        section("Seasons", caption: nil) {
            ForEach(DiscoverFilterOptions.seasonBuckets) { b in
                Button { toggleSeasons(b) } label: { Text(b.label) }
                    .buttonStyle(ChipButtonStyle(selected: f.minSeasons == b.min && f.maxSeasons == b.max && (b.min != nil || b.max != nil)))
            }
        }
    }

    /// A titled block: an eyebrow label + optional caption over a horizontal chip scroller (the established
    /// Discover chip idiom, so the panel matches the type / catalog / genre rows behind it).
    @ViewBuilder private func section<Content: View>(_ title: String, caption: String?, @ViewBuilder _ chips: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(LocalizedStringKey(title)).eyebrowStyle()
            if let caption {
                Text(LocalizedStringKey(caption)).font(Theme.Typography.label).foregroundStyle(Theme.Palette.textTertiary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.sm) { chips() }
                    .padding(.vertical, Theme.Space.xs)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: decade + bucket selection

    /// Decades fully inside the current [minYear, maxYear] window read as selected, so two far-apart picks
    /// light up the whole span between them (a range).
    private var selectedDecades: Set<Int> {
        guard let lo = f.minYear, let hi = f.maxYear else { return [] }
        return Set(DiscoverFilterOptions.decades.filter { $0.start >= lo && $0.end <= hi }.map(\.id))
    }
    private func toggleDecade(_ d: DiscoverFilterOptions.Decade) {
        var sel = selectedDecades
        if sel.contains(d.id) { sel.remove(d.id) } else { sel.insert(d.id) }
        let chosen = DiscoverFilterOptions.decades.filter { sel.contains($0.id) }
        update {
            $0.minYear = chosen.map(\.start).min()
            $0.maxYear = chosen.map(\.end).max()
        }
    }
    private func toggleDuration(_ b: DiscoverFilterOptions.Bucket) {
        let on = f.minMinutes == b.min && f.maxMinutes == b.max
        update { $0.minMinutes = on ? nil : b.min; $0.maxMinutes = on ? nil : b.max }
    }
    private func toggleSeasons(_ b: DiscoverFilterOptions.Bucket) {
        let on = f.minSeasons == b.min && f.maxSeasons == b.max
        update { $0.minSeasons = on ? nil : b.min; $0.maxSeasons = on ? nil : b.max }
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
    /// True when this launch is the user's exact chosen source (a CW-card-tap that reresolved the SAME debrid
    /// file), so PlayerScreen HONORS it on a start-timeout (retries in place) instead of silently hopping to a
    /// different, lower-quality source. False for a stale-url replay / paste-a-link (which may hop normally).
    var wasExplicitPick: Bool = false
    /// True when this launch is a Continue-Watching RESUME (directResume). Plays the exact stored source first
    /// but hops to a fresh source on a HARD load failure (a stale debrid link) instead of dead-ending.
    var wasResume: Bool = false
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
                // Carry native-debrid provenance + the explicit-pick flag so a CW-card-tap that reresolved the
                // SAME source resumes it as the user's chosen pick (honored on a start-timeout, re-recorded for
                // the next resume), not a stale replay that hops across every source. Defaults keep other
                // launch paths (paste-a-link, downloads) unchanged.
                recordDebridRef: item.debridRef, startedFromExplicitPick: item.wasExplicitPick,
                startedFromResume: item.wasResume,
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
                onClose: {
                    core.unloadEnginePlayer()
                    launch.wrappedValue = nil
                }
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
    // Seed the community pool with the FULL assembled source groups this resume produces. A card resume never
    // opens the detail view, so the detail-view hoard never runs for it; this resume kicks a background loadMeta
    // (below, for both movie and series) that fills streamGroups, and this polls for that then fires the same
    // full-group hoard the detail view uses. The older single-source hoard no-op'd for debrid/direct resumes
    // (the common case), so those playbacks seeded nothing. Fire-and-forget, deduped per content, gated inside
    // SourceIndexClient (consent + fleet flag). No-op when the library id is not a real imdb id or no groups
    // assemble.
    if let cid = SourceIndexClient.contentID(imdbId: item.id, season: entry.season, episode: entry.episode) {
        let streamId = entry.videoId
        Task.detached {
            // Read groups off the shared bridge (not the captured `core`) so the detached task never captures a
            // non-Sendable reference; there is one engine bridge, so this is the same state the resume loads.
            await SourceIndexClient.hoardResumedGroups(contentID: cid) {
                CoreBridge.shared.streamGroups(forStreamId: streamId)
            }
        }
    }
    // Reresolve the EXACT stored source FIRST (same debrid file, fresh link) so the card tap resumes the source
    // the user chose instead of replaying a stale, expired URL and dead-ending into the cross-source auto-pick
    // ("Tried N sources / this source didn't load"). CWResume mints a fresh link for the SAME file when the
    // entry carries debrid provenance; a non-debrid entry returns the stored url unchanged (refreshed == false),
    // so torrent / plain-direct resumes are byte-identical to before.
    let (resolvedURL, refreshed) = await CWResume.resolvedURL(for: entry)
    let playURL = refreshed ? resolvedURL : url
    let hashShort = (entry.infoHash?.prefix(8)).map(String.init) ?? "-"
    var explicitDebridRef: DebridPlaybackRef? = nil
    var wasExplicitPick = false
    if refreshed, let service = entry.debridService.flatMap(DebridService.init(rawValue:)),
       let hash = entry.infoHash, !hash.isEmpty {
        // Fresh link for the SAME source: resume it as an EXPLICIT pick (no silent hop), carrying the debrid
        // provenance so the play-record re-stores it and the NEXT resume can reresolve again.
        explicitDebridRef = DebridPlaybackRef(url: resolvedURL, service: service, infoHash: hash,
                                              torrentId: entry.debridTorrentId, fileId: entry.debridFileId,
                                              fileIdx: entry.fileIdx)
        wasExplicitPick = true
        NSLog("[cw-probe] ios directResume: svc=%@ hash=%@ fileIdx=%@ reresolve=FRESH path=exact-source", service.rawValue, hashShort, entry.fileIdx.map(String.init) ?? "-")
    } else {
        NSLog("[cw-probe] ios directResume: svc=%@ hash=%@ fileIdx=%@ reresolve=NIL path=fallback-stored-url", entry.debridService ?? "-", hashShort, entry.fileIdx.map(String.init) ?? "-")
    }
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
        // Both stream surfaces count as resident: an episode whose sources are meta-embedded (metaStreams,
        // the HTTP/HLS add-on shape, #122) must not force a redundant re-dispatch here.
        let hasEpStreams = core.metaDetails?.allStreamGroups.contains { $0.request.path.id == entry.videoId } ?? false
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
    return iOSPlayerLaunch(url: playURL, title: entry.title, headers: entry.headers,
                           resume: resume, meta: meta,
                           qualityText: entry.qualityText, bingeGroup: entry.bingeGroup,
                           isTorrent: refreshed ? false : (entry.torrent ?? false),
                           debridRef: explicitDebridRef, wasExplicitPick: wasExplicitPick, wasResume: true,
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
                            // glass-Browse: a bespoke file-picker card row, not routed through a shared row
                            // style, so it flips straight to the glass card preset instead of the flat
                            // surface1 fill (matches the Downloads rows).
                            .vortxSettingsCard()
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
    /// #111 (iOS mirror of tvOS): show the per-profile watched check badge + 55% dim on each card. Opt-in so
    /// only catalog/discovery surfaces badge (Home catalog rails, Discover grid), exactly as tvOS scopes it;
    /// Continue Watching and the Library grid keep it off (their cards carry progress / their own treatment).
    /// Declared before `onReachEnd` so the synthesized memberwise init accepts the call-site argument order.
    var showWatchedBadges: Bool = false
    /// Called when the LAST card appears: the infinite-scroll hook for paginated grids (Discover).
    /// The grid stays generic; the caller decides whether and what to load next. nil = no pagination.
    var onReachEnd: (() -> Void)? = nil
    @EnvironmentObject private var theme: ThemeManager   // observe textScale so Theme.Typography repaints live
    @ObservedObject private var catalogPrefs = CatalogPreferences.shared
    @ObservedObject private var apiKeys = ApiKeys.shared
    // Watched check + dim on catalog covers (#111): one shared per-profile id set, O(1) per card.
    @ObservedObject private var watchedIndex = WatchedIndex.shared
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
                                  progress: item.progress, resumeSeconds: item.resumeSeconds, menu: menu,
                                  isWatched: showWatchedBadges && watchedIndex.ids.contains(item.id))
                }
                // S3: the shared card treatment (resting depth shadow, Mac pointer-hover lift, designed
                // press, Reduce-Motion aware) instead of a flat button. scale 1.04 is touch-tuned, gentler
                // than the tvOS 1.08. This is the same style tvOS poster cards use, so the resting shadow
                // comes from the style (no separate shadow, which would double it and diverge from tvOS).
                .buttonStyle(CardFocusStyle(scale: 1.04))
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
    /// An optional dim uppercase kicker above the shelf title (the redesign mockup's "Pick up where you left
    /// off" style eyebrow). Tertiary-toned to match the mockup's shelf eyebrows and the tvOS RailHeader
    /// treatment. Nil on rails that carry no kicker, so their headers are byte-for-byte unchanged.
    var eyebrow: String? = nil
    let items: [RailItem]
    let onTap: (RailItem) -> Void
    /// Which long-press context menu each card shows on this surface (#14).
    var menu: iOSPosterMenu = .none
    /// Opens a card's detail page (used by the Continue Watching menu's Details item, since a CW tap resumes).
    var onDetails: ((RailItem) -> Void)? = nil
    /// #111 (iOS mirror of tvOS): show the per-profile watched check badge + 55% dim on each card. Opt-in so
    /// only catalog/discovery rails badge, exactly as tvOS scopes it; Continue Watching keeps it off (its
    /// cards carry the resume timecode + progress stripe, not a watched badge).
    /// Declared before `onReachEnd` so the synthesized memberwise init accepts the call-site argument order.
    var showWatchedBadges: Bool = false
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
    // Watched check + dim on catalog covers (#111): one shared per-profile id set, O(1) per card.
    @ObservedObject private var watchedIndex = WatchedIndex.shared
    /// Pointer hovering the rail (#3). Never fires on pure-touch iPhone, so the
    /// scroll arrows reveal only on Mac / iPad-with-trackpad, where swiping a long
    /// row is awkward. On touch the row stays swipe-only.
    @State private var hovering = false
    /// Left-edge index the arrows have paged to, so we can hide the back arrow at the start.
    @State private var pageIndex = 0
    private static let pageStride = 4

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            // S2: rail headers read as a section tier ABOVE the card titles below them. cardTitle sat at
            // the same size/weight as a card caption; sectionTitle (via the shared style helper: tracking
            // + textPrimary) restores the hierarchy for Home / Search / Library rails. An optional dim
            // uppercase eyebrow above the title matches the redesign mockup's shelf headers (and tvOS
            // RailHeader), so a shelf like Continue Watching reads "Pick up where you left off / Continue
            // Watching" exactly as the mockup and the tvOS home do.
            VStack(alignment: .leading, spacing: 4) {
                if let eyebrow { Text(eyebrow).eyebrowStyle() }
                Text(title).sectionTitleStyle()
            }
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
                          isWatched: showWatchedBadges && watchedIndex.ids.contains(item.id),
                          onDetails: onDetails.map { od in { od(item) } })
        }
        // S3: shared card treatment (resting shadow, Mac hover lift, designed press, Reduce-Motion aware),
        // matching the browse grid and tvOS poster cards. scale 1.04 is touch-tuned.
        .buttonStyle(CardFocusStyle(scale: 1.04))
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
            // The pointer-reveal scroll affordance floats OVER poster art, so it rides VortX's warm
            // liquid-glass material (redesign) instead of a flat black plate. White chevron for contrast on
            // the warm-dark glass; under Reduce Transparency the primitive stands down to an opaque warm
            // surface, so the control stays legible. Appearance only: the paging action is unchanged.
            Image(systemName: forward ? "chevron.right" : "chevron.left")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 60)
                .vortxGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous), shadow: .disc)
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

/// Cached, self-retrying poster image for the iPhone / iPad / Mac rails and grids. Raw `AsyncImage` keeps
/// no cache and CANCELS its request when a Lazy cell recycles on scroll, without retrying, which is exactly
/// the on-device "some posters load, others stay blank" report. This loads via the shared `PosterImageLoader`
/// (dedicated large URLCache, bounded concurrency, OFF-MAIN ImageIO decode), re-runs on every reappear via
/// `.task(id:)` (instant + synchronous on a decoded-cache hit, so a re-scrolled card never flashes blank),
/// treats a cancel as not-a-failure so the next appear retries, and shows a film placeholder only on a real
/// failure. The caller keeps its own frame / crop / clip so the fill-crop framing (F37) is unchanged.
struct CachedPosterImage: View {
    let url: String?
    @State private var image: VXPosterImage?
    @State private var failed = false

    /// Paint instantly (no task hop, no blank frame) when the decoded image is already in memory. The
    /// `.task` still runs to load a cold poster; on a warm one it returns immediately.
    private var synchronousCache: VXPosterImage? {
        guard let raw = url, let u = URL(string: raw) else { return nil }
        return PosterImageLoader.cached(u)
    }

    var body: some View {
        Group {
            if let image = image ?? synchronousCache {
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

    private func imageView(_ img: VXPosterImage) -> Image {
        #if canImport(UIKit)
        Image(uiImage: img)
        #else
        Image(nsImage: img)
        #endif
    }

    private func load() async {
        failed = false
        guard let raw = url, !raw.isEmpty else { failed = true; return }
        if let img = await PosterImageLoader.load(raw) {
            image = img
            return
        }
        if Task.isCancelled { return }   // scroll-away: leave `failed` false so the recycled cell reloads
        // One quick retry before latching the film placeholder, so a transient network blip on a card that
        // stays on screen (not scrolled away) does not leave it permanently blank, the "posters lose their
        // picture icon" report. Still bounded (a single retry) so a genuinely dead URL settles fast.
        try? await Task.sleep(nanoseconds: 400_000_000)
        if Task.isCancelled { return }
        if let img = await PosterImageLoader.load(raw) {
            image = img
        } else if !Task.isCancelled {
            failed = true
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
        // Shared loader: dedicated large URLCache, bounded concurrency, off-main ImageIO decode. Backdrops are
        // wider than portrait posters, so allow a larger downsample ceiling to keep the 16:9 art crisp.
        await PosterImageLoader.load(u.absoluteString, maxPixel: 1280)
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
    /// Watched state (#111, iOS mirror of the tvOS PosterCard): 55% opacity plus a check badge, exactly the
    /// tvOS treatment. Data-bearing catalog callers (Home rails + browse grids) pass it from the shared
    /// per-profile `WatchedIndex` set; the default keeps every other card pixel-identical.
    var isWatched: Bool = false
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
                        // the native overlay to avoid a double badge. Also skipped on a watched card, whose
                        // topTrailing corner carries the check badge instead (mirror of tvOS PosterCard).
                        if !isWatched, let rating = imdbRating, !rating.isEmpty, !PosterArtwork.bakesRatings {
                            HStack(spacing: 2) {
                                Image(systemName: "star.fill").font(.system(size: 8))
                                Text(rating).font(.system(size: 10, weight: .semibold))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            // glass-Browse: the on-poster badge alpha (never the poster image itself), so
                            // the rating badge reads as VortX chrome instead of a flat black pill.
                            .vortxGlass(in: Capsule(), fillAlpha: VortXGlass.badgeFillAlpha, shadow: .flat)
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
                                // glass-Browse: same on-poster badge alpha as the rating badge above.
                                .vortxGlass(in: Capsule(), fillAlpha: VortXGlass.badgeFillAlpha, shadow: .flat)
                                .padding(5)
                                // Lift clear of the 4pt progress stripe pinned to the very bottom.
                                .padding(.bottom, 4)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        // Watched check badge (#111, exact mirror of tvOS PosterCard's treatment): a filled
                        // accent checkmark in the topTrailing corner. The whole poster dims to 55% below.
                        if isWatched {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title3).foregroundStyle(Theme.Palette.accent)
                                .padding(6).shadow(radius: 3)
                                .accessibilityLabel("Watched")
                        }
                    }
                    .opacity(isWatched ? 0.55 : 1)   // mirror tvOS: a watched poster (and its badges) reads at 55%
                if !isWatched, progress > 0.01 {
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
            // #4 / glass-Browse: a translucent top bar, so the hero and content read as scrolling under
            // a blurred chrome rather than a flat opaque strip. Tinted with the SAME warm VortXGlass fill
            // as the bottom tab bar (VortXGlass.toolbarAppearance()), not a raw system .ultraThinMaterial,
            // so top and bottom chrome read as one glass system. Re-skin only: SwiftUI's
            // `.toolbarBackground` only accepts a ShapeStyle, so the glass tint goes on via the same
            // UIKit appearance-proxy idiom RootTabView already uses for the tvOS tab bar.
            .toolbarBackground(.visible, for: .navigationBar)
            .onAppear { Self.applyVortXNavBarAppearance() }
        #else
        self
        #endif
    }

    #if os(iOS)
    /// Tint the system nav bar's own blur with `VortXGlass.toolbarAppearance()`'s SAME warm fill /
    /// Reduce-Transparency fallback, via the global `UINavigationBar.appearance()` proxy (mirrors the
    /// `UITabBar.appearance()` proxy RootTabView already uses for the tvOS tab bar). `UIToolbarAppearance`
    /// and `UINavigationBarAppearance` both derive from `UIBarAppearance`, so its `backgroundEffect` /
    /// `backgroundColor` carry over directly: ONE glass source of truth for both bar kinds. Idempotent
    /// property assignment, safe to call from every `onAppear`.
    fileprivate static func applyVortXNavBarAppearance() {
        let toolbar = VortXGlass.toolbarAppearance()
        let nav = UINavigationBarAppearance()
        nav.backgroundEffect = toolbar.backgroundEffect
        nav.backgroundColor = toolbar.backgroundColor
        nav.shadowColor = .clear
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
    }
    #endif

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
                        // Floating Back chrome over the detail content on the shared glass primitive: warm
                        // glass + top highlight, Liquid Glass on macOS 26, opaque warm fallback under Reduce
                        // Transparency. Matches the nav / transport discs (CircleIconDisc).
                        .vortxGlass(in: Capsule(), fillAlpha: VortXGlass.pillFillAlpha, shadow: .disc)
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
