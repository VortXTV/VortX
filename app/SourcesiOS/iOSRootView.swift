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
    }

    @State private var tab: Tab = .home
    #if os(macOS)
    /// macOS keyboard browse: the focused bottom tab-strip item (its own focus space, traversed with
    /// Left/Right and Tab; Enter switches to it). nil = no tab in the strip is focused. Keyed by raw value.
    @FocusState private var tabFocus: MacBrowseFocus?
    #endif
    /// A new release found by the once-per-foreground check, surfaced as a prominent top banner so users
    /// learn about it without opening Settings. Dismissing it remembers the version, so it reappears only
    /// when a still-newer build ships.
    @ObservedObject private var updates = UpdateChecker.shared
    @AppStorage("stremiox.update.dismissedVersion") private var dismissedUpdateVersion = ""
    @Environment(\.openURL) private var openURL
    /// Post-update highlights, shown once when the build increases (never on a fresh install). See WhatsNew.
    @State private var showWhatsNew = false

    var body: some View {
        VStack(spacing: 0) {
            // Selected screen fills the space above the bar. We keep all six in a ZStack so each
            // screen's own state (scroll position, search query, engine subscriptions) survives a
            // tab switch instead of being torn down and rebuilt every time.
            ZStack {
                // `isActive` gates each browse screen's `.principal` wordmark: on macOS a principal
                // toolbar item is hoisted into the shared window titlebar, and every mounted
                // NavigationStack would otherwise stamp its own — tiling "StremioX" once per screen.
                // Only the visible tab contributes its wordmark (#46 regression).
                iOSHomeView(isActive: tab == .home).opacity(tab == .home ? 1 : 0)
                iOSDiscoverView(isActive: tab == .discover).opacity(tab == .discover ? 1 : 0)
                iOSLiveView().opacity(tab == .live ? 1 : 0)
                iOSLibraryView(isActive: tab == .library).opacity(tab == .library ? 1 : 0)
                iOSSearchView(isActive: tab == .search).opacity(tab == .search ? 1 : 0)
                AddonsView().opacity(tab == .addons ? 1 : 0)
                iOSSettingsView().opacity(tab == .settings ? 1 : 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            customTabBar
        }
        .safeAreaInset(edge: .top, spacing: 0) { updateBanner }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .tint(Theme.Palette.accent)
        .animation(.easeOut(duration: 0.25), value: updates.available?.build)
        .animation(.easeOut(duration: 0.25), value: dismissedUpdateVersion)
        .sheet(isPresented: $showWhatsNew) { WhatsNewView { showWhatsNew = false; WhatsNew.markSeen() } }
        // Automatic update popup: appears once per launch when a newer build exists (and again when the
        // hourly re-check finds a still-newer one), so users learn about updates without opening Settings.
        .sheet(item: $updates.prompt) { release in
            UpdatePromptView(release: release) { updates.dismissPrompt() }
        }
        .onAppear {
            WhatsNew.recordFreshInstallIfNeeded()
            if WhatsNew.shouldShow() {
                // iOS 16 keeps only the first .sheet on a view, so don't arm the update popup while What's New
                // claims the sheet slot; it'll appear next launch (once-per-launch resets). A build increase
                // means the user just updated anyway, so there's no pending update to show this launch.
                showWhatsNew = true
            } else {
                updates.startMonitoring()   // launch check + hourly re-check while open
            }
        }
        #if os(macOS)
        // macOS menu-bar commands (the "Go" menu + ⌘-shortcuts) post here, since they live at the
        // Scene level and can't set this @State directly. The raw value mirrors Tab's order.
        .onReceive(NotificationCenter.default.publisher(for: MacCommands.tabRequest)) { note in
            if let raw = note.userInfo?["tab"] as? Int, let dest = Tab(rawValue: raw) { tab = dest }
        }
        #endif
    }

    /// Brand-styled bottom bar: seven equal items, each a small SF Symbol over a caption label. The
    /// selected item is tinted with the app accent; the rest read as tertiary text. A hairline +
    /// surface fill separates it from the content, and it respects the safe-area bottom inset.
    private var customTabBar: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.rawValue) { item in
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

    private func tabButton(_ item: Tab) -> some View {
        let selected = tab == item
        let base = Button {
            tab = item
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
    @StateObject private var curated = CuratedCollectionsModel()   // editorial Cinemeta-backed rails (B3)
    @State private var path: [FeaturedHeroItem] = []
    /// A Continue-Watching card's direct resume launches the player straight from Home (#11).
    @State private var player: iOSPlayerLaunch?
    #if os(macOS)
    /// macOS keyboard browse: which Home poster card is focused. Passed to each rail so its cards become
    /// `.focusable()` and join native arrow traversal; nil on iOS (this whole member is macOS-only).
    @FocusState private var macFocus: MacBrowseFocus?
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
                     cwVideoId: $0.state.videoId)
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
        out += curated.collections.flatMap { $0.items }.map { RailItem(id: $0.id, type: $0.type, name: $0.name, poster: $0.poster, progress: 0) }
        return out
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
                LazyVStack(alignment: .leading, spacing: Theme.Space.lg) {
                    FeaturedHeroView(model: hero, onOpen: { path.append($0) })
                    if !continueWatchingItems.isEmpty {
                        // A CW card tap resumes the exact last-played stream straight into the player
                        // (#11), falling back to opening detail when no remembered link fits. Long-press
                        // offers the engine's "Remove from Continue Watching" (#14).
                        homeRail(PosterRail(title: "Continue Watching", items: continueWatchingItems,
                                            onTap: handleContinueWatchingTap, menu: .continueWatching,
                                            onDetails: { path.append(FeaturedHeroItem.from(rail: $0)) }))
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
                                                onTap: handleTap))
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
                    ForEach(curated.collections) { collection in
                        homeRail(PosterRail(title: collection.title,
                                            items: collection.items.map {
                                                RailItem(id: $0.id, type: $0.type, name: $0.name,
                                                         poster: $0.poster, progress: 0)
                                            },
                                            onTap: handleTap))
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
            #if os(macOS)
            // Escape steps focus up a level: drop the focused card so the keyboard browse returns to a
            // neutral state (the bottom tab strip is its own focus space, reachable via Tab / arrows).
            .onExitCommand { macFocus = nil }
            // Keyboard browse drives the hero: the focused poster features in the billboard (the tvOS
            // focused-card-hero behaviour, adapted for the Mac). Focus leaving the cards lets it resume.
            .onChange(of: macFocus) { newValue in
                if case let .card(_, itemID) = newValue, let item = allRailItems.first(where: { $0.id == itemID }) {
                    hero.feature(FeaturedHeroItem.from(rail: item))
                } else {
                    hero.noteInteraction()
                }
            }
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
                iOSDetailView(id: item.id, type: item.type, title: item.name)
            }
            .iOSPlayerCover($player, account: account, core: core)
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
            // Editorial rails are global (Cinemeta-backed), so build them once; the model no-ops while
            // already loaded or in flight, and retries on the next appearance if the first fetch failed.
            curated.load()
        }
        .onChange(of: core.revision) { _ in hero.seed(heroCandidates, reduceMotion: reduceMotion); refreshTopPicks() }
        .onChange(of: profiles.activeID) { _ in refreshTopPicks() }
        // Addons hydrate ASYNC, after onAppear — so configureMetaSources(core.addons) above often ran with
        // an empty set, leaving tmdb:/tvdb:/kitsu: hero items un-enriched (no rating/logo/backdrop on Home,
        // Discover, Library CW). Re-configure + re-seed once addons arrive so enrichment can reach the
        // installed meta add-on. tvOS already does this (HomeView/LiveView .onChange(of: core.addons.count)).
        .onChange(of: core.addons.count) { _ in FeaturedHeroModel.configureMetaSources(core.addons); hero.seed(heroCandidates, reduceMotion: reduceMotion) }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var hero = FeaturedHeroModel()
    @State private var path: [FeaturedHeroItem] = []

    /// The owner profile's Library is the account library (engine); an overlay profile's Library is its
    /// own private watch overlay (every watched title), never the account.
    private var libraryItems: [RailItem] {
        let source = profiles.activeUsesEngineHistory ? (core.library?.catalog ?? []) : profiles.libraryItems
        return source.map {
            RailItem(id: $0.id, type: $0.type, name: $0.name, poster: $0.poster, progress: $0.progress)
        }
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
                } else {
                    ContentUnavailableViewCompat(title: "Library", systemImage: "books.vertical",
                        message: "Titles you add to your library in Stremio show up here.")
                        .frame(minHeight: 420)
                }
            }
            .scrollDismissesHeroRotation(model: hero)
            .background(Theme.Palette.canvas.ignoresSafeArea())
            .stremioWordmarkTitle(String(localized: "Library"), isActive: isActive)
            .navigationDestination(for: FeaturedHeroItem.self) { item in
                iOSDetailView(id: item.id, type: item.type, title: item.name)
            }
            .onAppear { if core.library?.catalog.isEmpty != false { core.loadLibrary() } }
        }
        .onAppear {
            FeaturedHeroModel.configureMetaSources(core.addons)
            hero.seed(heroCandidates, reduceMotion: reduceMotion)
        }
        .onChange(of: core.revision) { _ in hero.seed(heroCandidates, reduceMotion: reduceMotion) }
        // Addons hydrate ASYNC, after onAppear — so configureMetaSources(core.addons) above often ran with
        // an empty set, leaving tmdb:/tvdb:/kitsu: hero items un-enriched (no rating/logo/backdrop on Home,
        // Discover, Library CW). Re-configure + re-seed once addons arrive so enrichment can reach the
        // installed meta add-on. tvOS already does this (HomeView/LiveView .onChange(of: core.addons.count)).
        .onChange(of: core.addons.count) { _ in FeaturedHeroModel.configureMetaSources(core.addons); hero.seed(heroCandidates, reduceMotion: reduceMotion) }
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
            Button(t.label) { core.selectLibrary(t.request) }
                .buttonStyle(ChipButtonStyle(selected: t.selected)) } }
        chipScroll { ForEach(selectable.sorts) { s in
            Button(s.label) { core.selectLibrary(s.request) }
                .buttonStyle(ChipButtonStyle(selected: s.selected)) } }
    }

    private func chipScroll<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Space.sm) { content() }
                .padding(.horizontal, Theme.Space.md).padding(.vertical, Theme.Space.xs)
        }
    }
}

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
                    // Stremio's "paste a link" feature, at the top like tvOS.
                    Button { showOpenLink = true } label: {
                        Label(directLinksOnly ? "Play a direct link" : "Play a link or magnet", systemImage: "link")
                    }
                    .buttonStyle(ChipButtonStyle(selected: false))
                    .padding(.horizontal, Theme.Space.md)

                    if !history.isEmpty && !isTyping { historySection }

                    results
                }
                .padding(.vertical, Theme.Space.md)
            }
            .background(Theme.Palette.canvas.ignoresSafeArea())
            .stremioWordmarkTitle(String(localized: "Search"), isActive: isActive)
            .navigationDestination(for: FeaturedHeroItem.self) { item in
                iOSDetailView(id: item.id, type: item.type, title: item.name)
            }
            .searchable(text: $query, prompt: "Movies or series")
            .searchSuggestions {
                ForEach(suggestionTitles, id: \.self) { title in
                    Text(title).searchCompletion(title)
                }
            }
            .onSubmit(of: .search) {
                searchTask?.cancel()
                searchDebouncePending = false
                core.suggestSearch(query)
                core.search(query)
                // On macOS the search bar is visible in the toolbar on every tab (all tabs stay
                // mounted). Switch to the Search tab so results are actually visible.
                #if os(macOS)
                if !isActive { MacCommands.go(.search) }
                #endif
            }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var hero = FeaturedHeroModel()
    @State private var path: [FeaturedHeroItem] = []

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
                    if let discover = core.discover {
                        // Hero is an ambient billboard scroll-header above the chips + grid, shown once
                        // a catalog has loaded; its Play / Trailer buttons stay tappable. It fades
                        // cleanly into the chip rows below — no negative overlap, so the filter pills
                        // no longer ride up into the hero's title/synopsis band (#52, #7).
                        FeaturedHeroView(model: hero, onOpen: { path.append($0) })
                        // The filter rows are their own vertically-stacked band: each chip row gets its
                        // own line with consistent spacing so a row's pills can never be drawn on top
                        // of the row above it (#7).
                        VStack(alignment: .leading, spacing: Theme.Space.xs) {
                            chipScroll { ForEach(discover.selectable.types) { t in
                                Button(t.type.capitalized) { core.selectDiscover(t.request) }
                                    .buttonStyle(ChipButtonStyle(selected: t.selected)) } }
                            chipScroll { ForEach(discover.selectable.catalogs) { c in
                                Button(c.catalog) { core.selectDiscover(c.request) }
                                    .buttonStyle(ChipButtonStyle(selected: c.selected)) } }
                            if let genre = discover.selectable.extra.first(where: { $0.name.caseInsensitiveCompare("genre") == .orderedSame }),
                               !genre.options.isEmpty {
                                chipScroll { ForEach(genre.options) { o in
                                    Button(o.label) { core.selectDiscover(o.request) }
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
            .background(Theme.Palette.canvas.ignoresSafeArea())
            .stremioWordmarkTitle(String(localized: "Discover"), isActive: isActive)
            .navigationDestination(for: FeaturedHeroItem.self) { item in
                iOSDetailView(id: item.id, type: item.type, title: item.name)
            }
            .onAppear { if core.discover == nil { core.loadDiscover() } }
        }
        .onAppear {
            FeaturedHeroModel.configureMetaSources(core.addons)
            hero.seed(heroCandidates, reduceMotion: reduceMotion)
        }
        // The grid changes whenever a different type/catalog/genre is selected, which bumps revision —
        // reseed so the hero pool tracks the visible catalog.
        .onChange(of: core.revision) { _ in hero.seed(heroCandidates, reduceMotion: reduceMotion) }
        // Addons hydrate ASYNC, after onAppear — so configureMetaSources(core.addons) above often ran with
        // an empty set, leaving tmdb:/tvdb:/kitsu: hero items un-enriched (no rating/logo/backdrop on Home,
        // Discover, Library CW). Re-configure + re-seed once addons arrive so enrichment can reach the
        // installed meta add-on. tvOS already does this (HomeView/LiveView .onChange(of: core.addons.count)).
        .onChange(of: core.addons.count) { _ in FeaturedHeroModel.configureMetaSources(core.addons); hero.seed(heroCandidates, reduceMotion: reduceMotion) }
        .onDisappear { hero.stop() }
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
    /// Series only: the season's ordered episodes + a resolver, so a Continue-Watching resume gets the
    /// same in-player Next / Prev / episode-list as the detail page. Empty/nil for movies + paste-a-link.
    var episodes: [PlayerEpisodeRef] = []
    var loadEpisode: ((String) async -> PlayerEpisodeStream?)? = nil
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
                 ? "A direct video URL (mp4, mkv, m3u8 and friends), a debrid or usenet link your service resolved to http(s), or a live Twitch channel link."
                 : "A direct video URL (mp4, mkv, m3u8 and friends), a debrid or usenet link your service resolved to http(s), a live Twitch channel link, or a magnet link.")
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
            playMagnet(magnet)
            return
        }
        // Recognise a streaming-service link (0.3.9 Phase 1: Twitch resolves in-app to HLS; YouTube is
        // detected but not yet resolved). Everything else falls through to the existing direct-link path.
        switch LinkResolver.detect(text) {
        case .twitch(let channel):
            playTwitch(channel: channel)
            return
        case .youtube:
            status = "YouTube links are coming soon. Twitch and direct video links work today."
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

    private func playMagnet(_ magnet: OpenLinkMagnet.Magnet) {
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
            case .choose(let files):
                status = nil
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
private struct PosterGrid: View {
    let items: [RailItem]
    let onTap: (RailItem) -> Void
    /// Which long-press context menu each card shows on this surface (#14). `.none` for surfaces
    /// where no engine action applies.
    var menu: iOSPosterMenu = .none
    /// Called when the LAST card appears — the infinite-scroll hook for paginated grids (Discover).
    /// The grid stays generic; the caller decides whether and what to load next. nil = no pagination.
    var onReachEnd: (() -> Void)? = nil
    @EnvironmentObject private var theme: ThemeManager   // observe textScale so Theme.Typography repaints live
    // Center the adaptive tracks so the cards distribute evenly across the available width instead of
    // packing to the leading edge. Min track matches the 120pt card + a little breathing room.
    private let columns = [GridItem(.adaptive(minimum: 116), spacing: Theme.Space.sm, alignment: .center)]
    var body: some View {
        LazyVGrid(columns: columns, alignment: .center, spacing: Theme.Space.md) {
            ForEach(items) { item in
                Button { onTap(item) } label: {
                    PosterCardiOS(id: item.id, name: item.name, poster: item.poster, fallbackArt: item.background, imdbRating: item.imdbRating,
                                  progress: item.progress, menu: menu)
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

private struct PosterRail: View {
    let title: String
    let items: [RailItem]
    let onTap: (RailItem) -> Void
    /// Which long-press context menu each card shows on this surface (#14).
    var menu: iOSPosterMenu = .none
    /// Opens a card's detail page (used by the Continue Watching menu's Details item, since a CW tap resumes).
    var onDetails: ((RailItem) -> Void)? = nil
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
            #if os(macOS)
            // Group the rail's cards so native directional focus resolves Left/Right WITHIN the row and
            // Up/Down BETWEEN rows geometrically, only when this rail opts into keyboard focus (Home).
            .modifier(MacRailFocusSection(enabled: macFocus != nil))
            #endif
        }
        .onHover { hovering = $0 }
    }

    /// One rail card. The touch/iOS body is identical across platforms; on macOS, when the rail opts in,
    /// the card additionally becomes `.focusable()` + shows the accent ring while focused and auto-scrolls
    /// into view, all additive modifiers so touch / VoiceOver / the existing tap + long-press are unchanged.
    @ViewBuilder private func railCard(_ item: RailItem, proxy: ScrollViewProxy) -> some View {
        let base = Button { onTap(item) } label: {
            PosterCardiOS(id: item.id, name: item.name, poster: item.poster, fallbackArt: item.background, imdbRating: item.imdbRating,
                          progress: item.progress, menu: menu,
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

private struct PosterCardiOS: View {
    let id: String
    let name: String
    let poster: String?
    /// Backdrop to fall back to when an add-on item carries no `poster` (AIOMetadata sometimes omits it),
    /// so the tile shows the title's art cropped to the card instead of a blank surface. Nil = no fallback.
    var fallbackArt: String? = nil
    /// IMDb rating to show as a small star badge on the poster, when the catalog item carries one. Nil hides it.
    var imdbRating: String? = nil
    let progress: Double
    /// Which long-press menu to attach (#14). `.none` attaches none.
    var menu: iOSPosterMenu = .none
    /// Per-card "open details" action, wired into the Continue Watching menu's Details item.
    var onDetails: (() -> Void)? = nil
    @EnvironmentObject private var theme: ThemeManager   // observe textScale so Theme.Typography repaints live
    var body: some View {
        card.modifier(PosterContextMenu(id: id, menu: menu, onDetails: onDetails))
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottom) {
                // Cached, self-retrying loader (not raw AsyncImage, which cancels on cell recycle and never
                // retries, the blank-poster cause). scaledToFill inside CachedPosterImage keeps the source
                // proportions and CROPS to the card, so non-2:3 add-on posters fill cleanly (F37), and a
                // missing poster falls back to the title's backdrop before a plain film placeholder.
                CachedPosterImage(url: XRDB.imageURL(id: id, fallback: poster ?? fallbackArt))
                    .frame(width: 120, height: 180)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    .overlay(alignment: .topTrailing) {
                        // When the poster service is on, the rating is baked into the image, so skip the
                        // native overlay to avoid a double badge.
                        if let rating = imdbRating, !rating.isEmpty, !XRDB.isEnabled {
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
                if progress > 0.01 {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(.black.opacity(0.4))
                            Rectangle().fill(Theme.Palette.accent).frame(width: geo.size.width * progress)
                        }
                    }
                    .frame(height: 4)
                }
            }
            .frame(width: 120, height: 180)
            Text(name)
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(1).frame(width: 120, alignment: .leading)
        }
        // One contiguous tap + long-press target over the whole card (poster, the 6pt gap, and title).
        // Without it the .buttonStyle(.plain) label hit-tests as the UNION of its subview shapes, so the
        // inter-child gap and rounded-corner regions are dead zones that fall through to the adjacent
        // grid cell — the reported "tap a card in row 1, the row-2 item opens". Rectangle (not the
        // poster's RoundedRectangle) so the title and gap are inside the target and corners aren't dead.
        .frame(width: 120, alignment: .leading)
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
    func stremioWordmarkTitle(_ pageTitle: String, isActive: Bool = true) -> some View {
        navigationTitle(pageTitle)
            .navigationBarTitleDisplayModeInlineCompat()
            // The brand wordmark in the navigation bar's PRINCIPAL slot is iOS-only. On macOS a
            // `.principal` item is hoisted into the single shared window titlebar, and all seven tab
            // screens stay mounted at once (opacity-switched to preserve state), so every browse screen
            // would stamp its own wordmark into the one principal slot and NSToolbar crashes inserting a
            // duplicate principal item (EXC_BREAKPOINT in _insertNewItemWithItemIdentifier, the Beta 7 Mac
            // crash; the old `isActive` content-toggle did not stop the four ITEMS coexisting). Compile-
            // gating the whole toolbar out on macOS removes the collision; the Mac keeps the native
            // `navigationTitle(pageTitle)` in its titlebar. A compile-time gate (not a runtime branch)
            // leaves the NavigationStack's structural identity unchanged, so there is no scroll/path reset.
            #if os(iOS)
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
            #endif
    }

    /// A scroll/drag on a browse screen quiets the ambient hero rotation; the model resumes it after a
    /// spell of inactivity (#53). Implemented as a non-blocking `simultaneousGesture` so it observes
    /// the drag without intercepting the ScrollView's own scrolling.
    func scrollDismissesHeroRotation(model: FeaturedHeroModel) -> some View {
        simultaneousGesture(
            DragGesture(minimumDistance: 8)
                .onChanged { _ in model.noteInteraction() }
        )
    }

    /// `.navigationBarTitleDisplayMode(.inline)` is unavailable on macOS; no-op there.
    @ViewBuilder fileprivate func navigationBarTitleDisplayModeInlineCompat() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

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
