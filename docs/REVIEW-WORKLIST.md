# StremioX — Full A-Z Review Work-List

Generated 2026-06-13 from the 7-area audit (layout, code, player, theming, server, parity, a11y) — 97 raw issues synthesized. Sequenced across builds; tick as shipped.

## Systemic root causes (fix once)

- **S1 — VIEWPORT CLIPPING** — a plain VStack placed as the direct child of a vertical ScrollView sizes to its WIDEST child, so any over-wide child (a fixed .frame(width: N) > ~360pt, or an un-wrapped horizontal chip/color HStack that reports intrinsic width up) makes th
  - Screens: Profile editor (Name/avatar/PIN fields + Background chips), launch Profile picker, Search tab, PIN gate; (Home/Discover/Library already fixed; Detail/Addons/Live/Settings already safe).
  - Fix: (a) Convert remaining plain VStacks that are direct children of a vertical ScrollView to LazyVStack: ProfilesView.swift:299, iOSRootView.swift:381 (Search), iOSSignInView.swift:29. (b) Replace every fixed .frame(width: 600|360) with .frame(maxWidth: …) on touch — ProfilesView.swift:307,319,377 and :

- **S2 — MAC PLAYER IS A SHEET INSIDE A NAVIGATIONSTACK** — platformFullScreenPlayerCover degrades to .sheet with a fixed content .frame on macOS, attached on views inside a per-tab NavigationStack that carries .searchable + wordmark/nav title. A macOS sheet renders below the titlebar and inside the
  - Screens: macOS player and trailer, presented from iOSDetailView / iOSEpisodeStreams / iOSRootView.
  - Fix: PlatformModifiers.swift:49 — present the macOS player at the window root, not as a NavigationStack sheet. Drive it from a shared @Published 'now playing' on an ObservableObject and route all play actions there; open with .windowStyle(.hiddenTitleBar)/.windowResizability + toggleFullScreen. Interim: 

- **S3 — iOS/macOS PLAYER PRESENTER CONTRACT IS TRUNCATED** — every iOS/macOS call site builds PlayerLaunch/iOSPlayerLaunch and PlayerScreen WITHOUT episodes/hasNext/onNext/bingeGroup (PlayerScreen defaults hasNext:false, onNext:{}). So the player structurally cannot do next/prev episode, an episodes 
  - Screens: iOS+macOS series playback: iOSDetailView (lines 133-139/883-891), iOSEpisodeStreams (883-890), iOSRootView iOSPlayerCover (666-681).
  - Fix: Extend the launch contract once: add episodes:[CoreVideo] + bingeGroup/startVideoId to PlayerLaunch + iOSPlayerLaunch, thread into PlayerScreen, add episodeIndex/hasNextEpisode/hasPrevEpisode/playNext/playPrevious mirroring TVPlayerView.swift:1461-1470. The presenters (iOSEpisodeStreams + series det

- **S4 — PLAYER LIBRARY-COMPLETION SIDE EFFECTS WERE NOT PORTED** — PlayerScreen copied transport/panels/recovery from TVPlayerView but never invokes core.markPlaybackWatched (at ~90%) or core.finishedWatching (on EOF). Both APIs exist on CoreBridge and are used by tvOS; iOS/macOS call them 0 times (verifie
  - Screens: iOS+macOS player — all playback (movies + episodes).
  - Fix: In PlayerScreen.handleProperty timePos branch (~PlayerScreen.swift:280-290) add a markedWatched latch that calls core.markPlaybackWatched(recordMeta) once when !isLive && currentTime/duration >= 0.9; and on terminal endFileEof (PlayerScreen.swift:324) call core.finishedWatching(libraryId:) before cl

- **S5 — onAccent INK IS A HARDCODED WARM-BROWN LITERAL** — Theme.Palette.onAccent is rgb(0.106,0.067,0.043) (verified Theme.swift:28), NOT derived from ThemeManager like accent/canvas/accentSoft. So every primary-button label, on-accent spinner, and the profile 'current' checkmark keeps a warm/oran
  - Screens: Every primary CTA app-wide (Watch/Play/Sign In/Save/etc.), on-accent ProgressViews, profile current-check badge.
  - Fix: Make onAccent adaptive in ThemeManager (derive ink from the chosen accent's luminance: near-black neutral for light/mid fills, near-white for dark fills; keep warm-brown only for the Ember accent) and change Theme.swift:28 to { ThemeManager.shared.onAccent }. One change repaints all 13 call sites.

- **S6 — SOURCE EMPTY/FAILURE STATE CONFLATES THREE DISTINCT CAUSES** — empty/loading derives ONLY from streamLoadProgress() (count of stream add-on loadables). It has no awareness of (a) embedded server dead, (b) zero stream add-ons installed, or (c) Direct-Links-Only filtered all torrents out. All three colla
  - Screens: iOS/macOS detail source list (movie/live/episode), Watch button, PlayerScreen load-error + torrent warm-up.
  - Fix: Inject serverOffline + the add-on total + rawHadSources into iOSSourceList and branch the empty state into 4 cases (no stream add-ons / server offline / Direct-Links-Only filtered / per-title none). In PlayerScreen handleLoadFailure + warmUpTorrent, probe StremioServer.isOnline()/NodeServer.exitCode

- **S7 — SETTLE TIMEOUT WIRED ONLY ON EPISODES** — settleTimedOut (the 12s fallback that flips a hung resolution from spinner to terminal empty state) is passed only in iOSEpisodeStreams (verified 848/865/880); the movie sourceSection, live liveSourceSection, and the movie Watch button (mov
  - Screens: iOS/macOS movie detail + Watch button, live detail.
  - Fix: Add @State settleTimedOut + .task { sleep 12s; settleTimedOut = true } to iOSDetailView, pass settleTimedOut into iOSSourceList at the movie (:476-480) and live (:641-645) call sites, and gate movieLabel/movieReady on settle so it shows 'No sources found' instead of a perpetual spinner. Mirrors tvOS

- **S8 — ZERO SIZE-CLASS / DEVICE ADAPTATION** — grep horizontalSizeClass over SourcesiOS+SourcesShared = 0 hits (verified). The single universal target (family 1,2) and the macOS target render the iPhone layout verbatim — 120x180 cards on a flat 20pt gutter, a stretched 7-item bottom tab
  - Screens: All browse/detail/settings on iPad (regular width incl. Split View/Slide Over) and macOS.
  - Fix: Introduce ONE regular-width adaptation layer: add @Environment(\.horizontalSizeClass) to iOSRootView; make poster card size + grid minimum + heroHeight + screenInset Theme tokens keyed on size class (≈120 compact / ≈170-190 regular cards, ≈480-560 hero, ≈40-64 inset), and move the tab bar to a side 

- **S9 — CoreBridge IS NOT @MainActor BUT MUTATES STATE FROM THE RUST CALLBACK THREAD** — CoreBridge is a plain final class (verified) whose handleEvent (called on a Rust worker thread) writes awaitingAuthMigration/switchInFlight/switchFromUID/addonNamesCache directly, while the same vars are read/written on the main thread. Und
  - Screens: All platforms — auth bootstrap, account switch, board load.
  - Fix: Annotate CoreBridge @MainActor final class and hop to the main actor in coreEventCallback before touching instance state (Task { @MainActor in self.handleEvent(bytes) }), peeling heavy decode off before the hop. Also add guard !switchInFlight in the scheduleSessionRepair closure. Resolves the race s

- **S10 — isSignedIn ASSIGNED UNCONDITIONALLY** — signIn and signInWithAuthKey set isSignedIn = true without the change-guard that the beta8 fix added to reloadForActiveProfile, so a no-op true→true still publishes and can re-enter observers (the QR/link sign-in path through shared LinkLog
  - Screens: Sign-in flow (password + QR/link) iOS/macOS/tvOS.
  - Fix: StremioAccount.swift:210 and :225 — replace 'isSignedIn = true' with 'if !isSignedIn { isSignedIn = true }', matching reloadForActiveProfile. Two-line change.

- **S11 — UNGUARDED URL(string** — )! FORCE-UNWRAPS IN PRODUCTION NETWORKING: 7 sites (verified) use URL(string:)!, most dangerously where a runtime path is interpolated into the base (StremioAccount.post/postRaw, ProfileSync.post). Violates the no-force-unwrap rule and can 
  - Screens: All networking — account API, profile datastore sync, web view loopback.
  - Fix: In StremioAccount.post/postRaw and ProfileSync.post add 'guard let url = URL(string: "\(api)/\(path)") else { throw URLError(.badURL) }'; make StremioWebView.swift:87/100 literals static lets. One guard pattern per private helper.

- **S12 — FILE-SCOPE accessibility GAPS SHARE A FEW HELPERS** — icon-only player buttons (iconButton/seekButton/play-pause/panel-close), poster cards (PosterRail/PosterGrid Button), filter chips (chip helper x2 + season chip), and decorative hero/QR images all lack labels/hints/values; the custom Typogr
  - Screens: Player, all browse surfaces, Discover/Library/Detail chips, hero, tab bar — iOS+macOS VoiceOver/Dynamic Type users.
  - Fix: Fix at the shared helpers: add a label param to iconButton + .accessibilityLabel at each call site; add label/hint/value to the poster Button in PosterRail+PosterGrid and .accessibilityHidden to the progress stripe; add .accessibilityAddTraits(.isSelected) in the chip helpers; .accessibilityHidden(t

## Prioritized issues

- [ ] **#1 [critical] S1-layout-clipping (merges layout-profileeditor-fixedwidth-fields, parity-profileeditor-fixed-600pt-fields, layout-search-plain-vstack, layout-signin-plain-vstack, layout-pingate-fixed360)** (high) — Profile editor (+ Add Profile), Search tab, Sign In sheet, PIN gate — 
  - Editor column renders wider than the screen and clips both edges ('ile'/'ED Black'); Search can clip when results load; PIN field clips on 320pt phones. The exact bug the user just reported.
  - Fix: ProfilesView.swift:299 → LazyVStack; .frame(width:600)@:307,319,377 and width:360@:154 → .frame(maxWidth:); wrap ProfileBackgroundPicker HStack:511 in horizontal ScrollView; iOSRootView.swift:381 (Search) + iOSSignInView.swift:29 → LazyVStack.
- [ ] **#2 [critical] S2-mac-player-sheet (macos-player-sheet-titlebar-navchrome-leak)** (high) — macOS player + trailer
  - Player opens as a fixed floating panel that doesn't cover the titlebar; the underlying search bar + nav title bleed in above the video; cannot be moved/resized — never a real full-window player.
  - Fix: PlatformModifiers.swift:49 — present at window root via a shared now-playing ObservableObject + hiddenTitleBar/fullscreen window, OR interim NSViewRepresentable that hides titlebar + inserts .fullSizeContentView and attach cover outside the searchable Navigati
- [ ] **#3 [critical] crash-force-unwrap-groupedtrackrows** (high) — Player Subtitles/Audio panel — iOS/macOS
  - App crashes opening the Subtitles or Audio panel when a language group has >1 track (typical dual-audio case).
  - Fix: PlayerScreen.swift:1058 — replace 'let ts = groups[code]!' with 'guard let ts = groups[code] else { continue }'.
- [ ] **#4 [critical] S11-url-force-unwrap (crash-force-unwrap-url-string-production)** (high) — All networking — account API, profile sync, webview
  - Process can crash if an interpolated runtime path yields a malformed URL in StremioAccount/ProfileSync post paths.
  - Fix: guard-let URL(string:) else { throw URLError(.badURL) } in StremioAccount.post/postRaw (333/379) + ProfileSync.post (195); static lets for StremioWebView literals (87/100).
- [ ] **#5 [critical] S3-player-episode-contract (player-missing-next-prev-episode-and-episode-list)** (high) — iOS/macOS series playback
  - No Next/Previous Episode and no Episodes list in the player; only way to next episode is to back all the way out.
  - Fix: Extend PlayerLaunch/iOSPlayerLaunch with episodes:[CoreVideo]+bingeGroup, thread into PlayerScreen, add playNext/playPrevious + an .episodes Panel mirroring TVPlayerView:1461-1470; presenters supply the season list.
- [ ] **#6 [critical] a11y-player-icon-buttons-no-label** (high) — Player top bar + seek buttons — iOS/macOS
  - VoiceOver announces nothing for dismiss/next/landscape/info/handoff/seek/play-pause/panel-close — a blind user cannot operate the player.
  - Fix: Add a label param to iconButton (PlayerScreen.swift:841) + .accessibilityLabel at call sites 712/719/726/733/734; label seekButton:759, play-pause:748, panel close:931.
- [ ] **#7 [high] S6-emptystate-conflation (merges emptystate-conflates-serverdown-noaddons, player-failure-never-names-server-down, directlinksonly-empty-state-misleading)** (high) — iOS/macOS detail source list + PlayerScreen failure
  - Server-down, no-stream-addons, and Direct-Links-Only-filtered all show 'None of your add-ons returned a playable source'; player blames the torrent/link when the real fix is relaunch the app.
  - Fix: Inject serverOffline+addon total+rawHadSources into iOSSourceList; branch into 4 messages. PlayerScreen handleLoadFailure/warmUpTorrent probe StremioServer.isOnline()/NodeServer.exitCode and name 'server offline — relaunch'.
- [ ] **#8 [high] S7-settle-timeout (movie-live-no-settle-timeout-infinite-spinner)** (high) — iOS/macOS movie + live detail, Watch button
  - Movie/live with no returning add-on spins 'Finding sources…' forever; Watch button stuck on 'Loading sources…' permanently.
  - Fix: Add settleTimedOut @State + 12s .task to iOSDetailView; pass into iOSSourceList at movie (:476) and live (:641); gate movieLabel on settle. Mirrors tvOS DetailView:815.
- [ ] **#9 [high] S5-watched-completion (merges player-no-autoadvance-eof-leaves-title-stuck-in-cw, player-no-mark-watched-at-90-percent)** (high) — iOS/macOS player — EOF + ~90% of all playback
  - Titles never flip to watched; finished titles linger in Continue Watching forever; episodes don't auto-advance.
  - Fix: PlayerScreen: markedWatched latch calling core.markPlaybackWatched at >=0.9 (timePos branch ~285); on endFileEof:324 call core.finishedWatching then playNext-or-close. Mirrors TVPlayerView:180/205.
- [ ] **#10 [high] S9-corebridge-mainactor (merges race-corebride-handleevent-mutable-state, actor-reentrancy-corebridgeseedstate-after-await)** (high) — All — auth/account-switch/board load
  - Data races on awaitingAuthMigration/switchInFlight/switchFromUID written from the Rust thread; repair can double-fire Authenticate during a concurrent switch.
  - Fix: Annotate CoreBridge @MainActor; hop in coreEventCallback (Task{@MainActor in handleEvent}); add guard !switchInFlight in scheduleSessionRepair (~:140).
- [ ] **#11 [high] S10-issignedin-guard (double-fire-issignedin-signinwithAuthKey)** (high) — Sign-in (password + QR/link)
  - Unconditional isSignedIn=true can re-publish and re-enter observers on the shared QR/link path.
  - Fix: StremioAccount.swift:210 and :225 — 'if !isSignedIn { isSignedIn = true }'.
- [ ] **#12 [high] state-never-reset-appliedinitialresume-on-source-switch** (high) — Player — user source switch
  - After the first source, a deliberate clean source switch starts the new file at 0:00 because appliedInitialResume is never reset.
  - Fix: Add 'appliedInitialResume = false' to the switchStream reset block at PlayerScreen.swift:642.
- [ ] **#13 [high] player-mac-keyboard-shortcuts-missing** (high) — macOS player (+ iPad hardware keyboard)
  - No spacebar/arrows/F/N/P; once playing the only Esc shortcut (on the pre-start close button) is gone — keyboard is dead.
  - Fix: Add always-present .onKeyPress/hidden keyboardShortcut buttons on the macOS player root: space=togglePause, arrows=seek/volume, F=fullscreen, N/P=playNext/Prev, Esc=leavePlayback. Depends on S3 for N/P.
- [ ] **#14 [high] player-no-persistent-close-on-mac-after-start** (high) — macOS player after start
  - After playback starts the always-visible close button is removed and there is no keyboard Esc — user can feel trapped.
  - Fix: On macOS keep an always-attached .keyboardShortcut(.cancelAction) hidden close (and optional visible corner close) regardless of hasStartedPlaying.
- [ ] **#15 [high] blocking-main-actor-keychain-file-sync** (high) — Sign-in + profile switch — macOS
  - macOS Keychain uses queue.sync disk I/O read/written from @MainActor authKey accessors; main thread can stall tens-hundreds of ms on slow disks.
  - Fix: Add async Keychain variants on macOS (withCheckedContinuation over the queue); use await in async init/methods; keep sync authKey only for the cached in-memory copy.
- [ ] **#16 [high] silenced-error-datastoreput** (high) — Progress saving — all platforms
  - saveProgress network errors swallowed via try?; watch progress silently lost on flaky connections.
  - Fix: StremioAccount.swift:327 — let datastorePut throw; log via os.Logger + optional single retry in saveProgress.
- [ ] **#17 [high] S8-ipad-mac-layout (merges parity-no-ipad-layout, parity-ios-multitasking-no-adaptation)** (high) — All screens — iPad regular width + Split View/Slide Over + macOS
  - Entire app is the iPhone UI scaled up: tiny cards on a 20pt gutter, stretched bottom tab bar, phone-height hero; Split-Over panes render even more cramped.
  - Fix: Add @Environment(\.horizontalSizeClass) layer; size-class Theme tokens for card/grid/hero/inset + type ramp; side rail/NavigationSplitView on regular width. Either implement adaptation or set UIRequiresFullScreen on StremioXiOSNative as a stopgap.
- [ ] **#18 [high] S1b-profilepicker-overflow (merges layout-profilepicker-hstack, parity-profilepicker-hstack-overflow)** (high) — 'Who's watching?' picker — iPhone/iPad
  - 3+ profile cards (230pt each) in a non-scrolling HStack overflow and clip; the 64pt hero title can clip.
  - Fix: Wrap the card HStack (ProfilesView.swift:74) in horizontal ScrollView on touch (#if os(tvOS) keep HStack); shrink card geometry on compact width; clamp the hero title with minimumScaleFactor/lineLimit.
- [ ] **#19 [high] leak-unstructured-task-preparetorrent** (high) — Detail/Episode prepareTorrentStream — iOS/macOS
  - Fire-and-forget torrent-prime Task is never cancelled; backing out mid-prepare keeps retrying ~10s and tasks accumulate on rapid open/close.
  - Fix: Return the Task from prepareTorrentStream, store in @State, cancel in onDisappear / on new selection — or use a cancellable URLSession dataTask.
- [ ] **#20 [high] leak-unstructured-task-refreshSoon-player** (high) — Player panels — iOS/macOS
  - refreshSoon() raw asyncAfter touches panel/panelRows after the player is torn down (use-after-free of SwiftUI state storage).
  - Fix: PlayerScreen.swift:1181 — replace asyncAfter with a cancellable Task stored in @State, cancelled in onDisappear and on panel close.
- [ ] **#21 [high] S5b-accent-onAccent-warm-ink (accent-onaccent-warm-ink-systemic)** (high) — Every primary CTA + on-accent spinner + profile current-check
  - After switching accent to pink, text/icons ON filled buttons stay warm/orange — app reads 'still partly orange'.
  - Fix: Make onAccent adaptive in ThemeManager (ink from accent luminance, white-vs-near-black-neutral); Theme.swift:28 → { ThemeManager.shared.onAccent }. Repaints 13 sites.
- [ ] **#22 [high] dq-tabbar-cramped-undesigned (merges parity-ios-tabbar-7items-cramped-compact)** (high) — Bottom tab bar — iPhone
  - 7 equal ~55pt tabs with 10pt labels that truncate/scale; only selection treatment is a color swap — reads as a generic strip.
  - Fix: iOSRootView tabButton (~88-110): accent-soft capsule/indicator behind active item, label 11pt + scale/weight bump, filled icon when active; consider grouping Add-ons+Settings under More on the narrowest widths.
- [ ] **#23 [high] a11y-text-scale-not-dynamic-type** (high) — All screens — iOS/macOS
  - App ignores system Dynamic Type entirely; internal slider caps at 1.4x vs WCAG 2.0x — fails SC 1.4.4.
  - Fix: Base Theme.Typography on Dynamic Type text styles scaled by textScale; raise textScaleRange to 0.80...2.00 (ThemeManager.swift:49); use ScaledMetric for the hero.
- [ ] **#24 [high] a11y-tab-bar-no-button-role** (high) — Custom tab bar — iOS/macOS
  - VoiceOver can't discover there are 7 tabs or that activating switches content.
  - Fix: Add .accessibilityHint("Switches to \(title) tab") in tabButton:109 and .accessibilityElement(children:.contain)+label on the bar HStack:71.
- [ ] **#25 [high] a11y-poster-card-no-label** (high) — Poster cards — Home/Discover/Library/Search
  - VoiceOver reads only the name; no button role, no 'opens detail', no progress %.
  - Fix: On the Button in PosterRail:935 + PosterGrid:910 add label/hint/value; .accessibilityHidden(true) on the progress stripe (PosterCardiOS:977).
- [ ] **#26 [high] a11y-hero-backdrop-not-hidden** (high) — FeaturedHeroView — Home/Discover/Library
  - VoiceOver lands on decorative backdrop/logo images; metadata tokens read one-by-one.
  - Fix: FeaturedHeroView.swift:62 backdrop .accessibilityHidden(true); logo:139 .accessibilityLabel(hero.name); metaRow:165 .accessibilityElement(children:.combine).
- [ ] **#27 [high] a11y-source-list-collapse-no-label** (high) — Source list section headers — Detail/Episode
  - Collapsible add-on headers give VoiceOver no expanded/collapsed state or toggle hint.
  - Fix: iOSDetailView.swift after :1219 add .accessibilityLabel/.accessibilityHint/.accessibilityValue keyed on isCollapsed.
- [ ] **#28 [high] a11y-watched-opacity-only-indicator** (high) — Episode list — iOS/macOS (+ tvOS)
  - Watched is signalled only by 0.55 opacity; VoiceOver never says 'watched'.
  - Fix: NavigationLink iOSDetailView:728 .accessibilityValue(isWatched ?"Watched":""); .accessibilityHidden on the checkmark:749; same in tvOS DetailView:552.
- [ ] **#29 [high] a11y-contrast-text-tertiary-on-canvas** (medium) — Tab labels, captions, chips, air dates, eyebrows
  - textTertiary (#8C8273) on warm canvas at 10pt can fall below 4.5:1 on lighter accents (Ocean/Forest) — fails SC 1.4.3.
  - Fix: Raise Theme.Palette.textTertiary (Theme.swift:23) to ~rgb(0.62,0.58,0.52); verify across all 8 accents; bump 10pt tab label to 11pt/.caption.
- [ ] **#30 [high] a11y-player-panel-close-small-target** (high) — Player panel close + top-bar icons
  - Panel close hit target is ~27pt (icon buttons ~39pt) — below the 44pt HIG target.
  - Fix: PlayerScreen.swift:934 add .frame(width:44,height:44).contentShape(Circle()); same on iconButton:841.
- [ ] **#31 [medium] a11y-player-auto-hide-controls-trap** (high) — Player auto-hide — iOS VoiceOver/Switch
  - When controls auto-hide, the reveal tap target is invisible to VoiceOver and controls are removed from the tree — player becomes unreachable.
  - Fix: Label the clear tap layer (:180) + .accessibilityAction; render controls with .opacity/.allowsHitTesting instead of an if branch (:187) so they stay in the tree.
- [ ] **#32 [medium] player-scrubber-live-binding-jitter** (medium) — Player scrubber — iOS/macOS
  - Slider can fight the user mid-drag and snap back on slow streams.
  - Fix: Introduce scrubTarget @State; bind Slider to scrubTarget while scrubbing, commit on edit-end (PlayerScreen:781). Mirrors TVPlayerView:567.
- [ ] **#33 [medium] player-no-restart-control** (medium) — Player transport — iOS/macOS
  - No restart-from-0:00 control (tvOS has one).
  - Fix: Add a restart button to centerTransport calling seek(to:0). Mirrors TVPlayerView.restart().
- [ ] **#34 [medium] player-no-metadata-line** (high) — Player title area — iOS/macOS
  - No resolution/HDR/codec line; users can't tell if they got the 4K HDR stream.
  - Fix: Add a caption under the title from videoParams/audio-codec/sigPeak (handleProperty); reuse TVPlayerView.computeMetadataLine.
- [ ] **#35 [medium] player-no-decoder-toggle-no-settings-panel** (high) — Player settings — iOS/macOS
  - No hardware/software decoder toggle to rescue green-frame/artifact clips.
  - Fix: Add a .playerSettings Panel + gear exposing Decoder (coordinator.player?.setHardwareDecoding) + Info. Mirrors TVPlayerView.playerSettingsRows.
- [ ] **#36 [medium] player-no-next-preload-binge** (medium) — Player series auto-next — iOS/macOS
  - Auto-advance will block on a fresh resolve each episode; no sticky binge continuity.
  - Fix: After S3, thread bingeGroup into nextUntriedStream binge: arg and port preloadNextIfNeeded (~50%). Depends on S3.
- [ ] **#37 [medium] onappear-double-fire-detail** (medium) — Detail meta loading — iOS/macOS
  - onAppear can fire twice under memory pressure; second loadMeta resets metaDetails and flickers the source list to a spinner.
  - Fix: iOSDetailView:128 — gate: if core.metaDetails?.meta?.id != id { core.loadMeta(...) }.
- [ ] **#38 [medium] S2b-accent-tint-presentations (accent-tint-not-crossing-presentations)** (medium) — SignIn/OpenLink sheets, ProfileEditor cover, search Cancel
  - System chrome inside sheets/covers renders system blue, not the app accent.
  - Fix: Add .tint(Theme.Palette.accent) at the WindowGroup root in StremioXiOSApp.swift:40.
- [ ] **#39 [medium] accent-inline-chip-white-divergence** (high) — Discover + Library filter chips
  - Filter pills use solid-accent fill + white text, unlike every other chip; white nearly invisible on light accents.
  - Fix: Delete the inline chip helpers (iOSRootView ~349 + ~597) and route through ChipButtonStyle(selected:).
- [ ] **#40 [medium] accent-danger-too-warm** (medium) — Remove/Log Out/Use Embedded/error/LIVE/offline dot
  - Warm red-orange danger reads as leftover orange next to a cool accent.
  - Fix: Cool Theme.swift:29 danger to ~rgb(0.847,0.275,0.310) (single token updates all sites).
- [ ] **#41 [medium] accent-splash-offbrand-purple** (high) — Launch splash — tvOS only
  - Splash flashes legacy Stremio purple regardless of chosen accent.
  - Fix: Rebrand SplashView to canvas/accent tokens (SplashView.swift:17-31). tvOS scope.
- [ ] **#42 [medium] accent-home-emptystate-system-button** (high) — Home signed-out empty state
  - 'Sign In' uses .borderedProminent (system style), not the brand PrimaryActionStyle.
  - Fix: iOSRootView.swift:252 → .buttonStyle(PrimaryActionStyle()).
- [ ] **#43 [medium] dq-screen-title-inconsistency** (medium) — Add-ons/ServerConfig vs Home/Discover vs Settings/Live
  - Three different title patterns (serif screenTitle, wordmark, plain navTitle) — ad hoc hierarchy.
  - Fix: Promote iOSRailHeader eyebrow+title into a shared ScreenHeader and apply to Add-ons/ServerConfig/Live/Settings.
- [ ] **#44 [medium] dq-empty-states-inconsistent** (high) — Empty states across Home/Library/Discover/Search/Live/Add-ons
  - 3+ separate empty-state implementations with differing sizes/alignment/CTA.
  - Fix: Standardize on ContentUnavailableViewCompat (add optional CTA closure); route Home:244, Live:47, Add-ons:55 through it.
- [ ] **#45 [medium] parity-macos-no-menu-commands** (high) — macOS app shell
  - No menu-bar commands/keyboard nav: no Cmd-F, no tab shortcuts, near-empty menu bar.
  - Fix: Add .commands{} to the macOS WindowGroup (StremioXiOSApp.swift:38): Cmd-F→Search, Cmd-1..7→tabs (lift tab selection into shared state). Pairs with S2/keyboard work.
- [ ] **#46 [medium] parity-macos-no-hover-states** (high) — All controls — macOS
  - No hover feedback on poster cards/chips/rows/tabs; controls feel dead until clicked.
  - Fix: Add .onHover-driven state (#if os(macOS)) into CardFocusContent/RowFocusContent (Theme.swift:130-205) feeding the same scale/glow used by isFocused.
- [ ] **#47 [medium] silenced-error-loadaddons** (high) — Addon loading after sign-in
  - loadAddons failure swallowed silently; signed-in user sees empty add-ons with no error.
  - Fix: StremioAccount.swift:261 — log the error; optionally expose addonsLoadError for Settings.
- [ ] **#48 [medium] retain-cycle-iOSDetailView-task-closures** (medium) — Detail/Root playback launch closures
  - Unstructured Tasks capture account strongly; reference kept alive during rapid navigation.
  - Fix: Add [weak account] (or capture value-type params) on the saveProgress Tasks in iOSDetailView:136/137/886/887 + iOSRootView:672.
- [ ] **#49 [medium] print-logging-nslog-production** (high) — CoreBridge — all platforms
  - NSLog is synchronous/unbuffered and runs on the Rust worker thread, slowing it.
  - Fix: Add os.Logger to CoreBridge; replace NSLog with log.info/error.
- [ ] **#50 [medium] cache-cap-512mb-iphone-tuning** (medium) — Engine config — iPhone torrent cache
  - 512MB cache + UV_THREADPOOL_SIZE=16 tuned for tvOS; may jetsam-kill the server mid-playback on small-RAM iPhones (root of the 'server offline' symptoms).
  - Fix: #if os(iOS) cap=256MB (StremioServer.swift:146); lower UV_THREADPOOL_SIZE to ~8 on iOS (NodeServer:71); validate via the [hb] rss heartbeat.
- [ ] **#51 [medium] applyserverconfig-precap-window-jetsam-risk** (medium) — Engine config — cache cap timing (iOS)
  - Default 2GB cache is live up to ~18s before the 512MB POST lands; a torrent created in that window can spike memory and jetsam.
  - Fix: Write cacheSize into APP_PATH settings.json before node_start, or shorten the poll to ~0.3s (StremioServer:156) and gate the first /create until the cap applies.
- [ ] **#52 [medium] a11y-chip-filter-no-role** (high) — Discover/Library/Detail-season chips
  - VoiceOver doesn't announce which filter is selected.
  - Fix: Add .accessibilityAddTraits(selected ?[.isSelected]:[]) in the chip helpers (iOSRootView:349/597) + season chip (iOSDetailView:679).
- [ ] **#53 [medium] a11y-custom-tab-bar-invisible-to-voiceover-when-inactive** (high) — All tabs — VoiceOver
  - All 7 tab screens stay in the a11y tree (opacity switching); VoiceOver can wander into inactive tabs.
  - Fix: Add .accessibilityHidden(tab != .X) to each child in the ZStack (iOSRootView:51-57).
- [ ] **#54 [medium] a11y-mac-keyboard-nav-player-panel** (high) — Player panel — macOS
  - Tab reaches buttons behind the open panel scrim; no focus trap.
  - Fix: Disable controls when panel != nil (PlayerScreen:187); .accessibilityElement(children:.contain) on the panel VStack (:924).
- [ ] **#55 [medium] a11y-qr-image-no-alt-text** (high) — Sign-In QR panel
  - QR rendered Image(decorative:) hides the sign-in URL from VoiceOver.
  - Fix: LinkLoginView:64 — Image(qrImage,label:Text("QR code for sign-in URL: …")).
- [ ] **#56 [medium] a11y-live-indicator-color-only** (high) — Player LIVE indicator + detail LIVE badge
  - LIVE conveyed by a red dot (color-only, SC 1.4.1); VoiceOver reads only the time.
  - Fix: PlayerScreen:817 .accessibilityElement(.ignore)+label "Live stream"; iOSDetailView:628 label "Live"; hide the dot.
- [ ] **#57 [medium] a11y-addons-remove-button-label** (high) — Add-ons rows
  - Remove button announces 'Remove' with no add-on name.
  - Fix: AddonsView:45 — .accessibilityLabel("Remove \(addon.manifest.name)").
- [ ] **#58 [medium] a11y-scrubber-no-accessibility-value** (high) — Player scrubber
  - Slider has no label/time value for VoiceOver.
  - Fix: PlayerScreen:781 — .accessibilityLabel("Playback position")+.accessibilityValue(time of duration).
- [ ] **#59 [medium] a11y-profile-picker-no-announce** (high) — Profile picker
  - Active profile not announced; checkmark read as raw image.
  - Fix: ProfilesView:192 .accessibilityValue(isCurrent ?"Currently active":"")+hint; hide checkmark:221.
- [ ] **#60 [medium] a11y-poster-card-fixed-size-breaks-large-type** (high) — Poster cards under large text
  - 120pt fixed card + 1-line label clips titles at higher text scale.
  - Fix: iOSRootView:990 — lineLimit(2)+fixedSize(vertical) + maxWidth:120 (keep image 120x180).
- [ ] **#61 [medium] size-ceiling-iOSRootView** (high) — Code health — iOSRootView.swift (1130 lines)
  - Monolith holds every browse screen + grid/rails/menus/tab shell.
  - Fix: Split each browse view + PosterGrid/PosterRail/PosterCardiOS/OpenLinkMagnet into own files; leave the tab shell. (Do alongside S1 Search/S8 edits.)
- [ ] **#62 [medium] size-ceiling-PlayerScreen** (high) — Code health — PlayerScreen.swift (1226 lines)
  - Player + panels + recovery + skip in one struct.
  - Fix: Extract PlayerPanels.swift + a recovery extension. (Do alongside S3/S5 player work.)
- [ ] **#63 [medium] size-ceiling-iOSDetailView** (high) — Code health — iOSDetailView.swift (1361 lines)
  - Detail + iOSEpisodeStreams + iOSSourceList in one file.
  - Fix: Extract iOSEpisodeStreams.swift + iOSSourceList.swift. (Do alongside S6/S7.)
- [ ] **#64 [medium] size-ceiling-CoreBridge** (high) — Code health — CoreBridge.swift (940 lines)
  - Board assembly + watched mutations + event handler in one file.
  - Fix: Extract CoreBridge+Board.swift + CoreBridge+Watched.swift. (Do alongside S9.)
- [ ] **#65 [low] parity-ios-search-no-signin-gate** (medium) — Search tab signed-out
  - Signed-out search is a dead end with permanent 'No results' and no hint.
  - Fix: Add account gate / sign-in hint to iOSSearchView matching tvOS SearchView:15-17.
- [ ] **#66 [low] parity-ios-about-missing-server-row** (medium) — Settings → About / server diagnostics
  - iOS About omits the Server row + offline node diagnostics tvOS shows.
  - Fix: Add the Server LabeledContent + serverOnline==false diagnostics block to iOSSettingsView (524/286).
- [ ] **#67 [low] player-info-control-discoverability-mac** (low) — macOS player controls
  - Top-bar controls auto-hide with no pointer-hover reveal.
  - Fix: Add .onContinuousHover to reveal controls on macOS (after S2).
- [ ] **#68 [low] player-sync-property-reads-on-main-thread-stall-risk** (low) — Player Info/track reads
  - Synchronous mpv_get_property reads on main can hitch/hang on a stalled core.
  - Fix: Throttle Info refresh when panel closed; move bulk reads onto the mpv queue and emit back.
- [ ] **#69 [low] dq-poster-rail-spacing-rhythm** (medium) — Rail section titles
  - Rail titles lack eyebrow/scale contrast — flat hierarchy.
  - Fix: Apply ScreenHeader rhythm or bump rail titles to sectionTitle+tracking. (Bundle with dq-screen-title.)
- [ ] **#70 [low] dq-settings-form-default-look** (low) — Settings
  - Uses system .secondary gray footers — most template-like screen.
  - Fix: Replace .foregroundStyle(.secondary)/.footnote with Theme textSecondary/textTertiary + Typography.label.
- [ ] **#71 [low] parity-ios-live-no-hero-detail-parity** (low) — Live tab — iOS
  - Live is the only browse tab with no hero.
  - Fix: Optionally mount FeaturedHeroView seeded from the first live row (iOSLiveView:23).
- [ ] **#72 [low] accent-success-green-hardcoded** (high) — Server Online dot / Reachable label
  - Success green is a raw literal duplicated in 3 files.
  - Fix: Add Theme.Palette.success token; replace the 3 literals.
- [ ] **#73 [low] a11y-settings-reorder-buttons-no-label** (high) — Settings stream-type reorder
  - chevron up/down buttons unlabelled.
  - Fix: iOSSettingsView:258/268 — .accessibilityLabel("Move \(type) up/down in ranking").
- [ ] **#74 [low] a11y-server-status-dot-color-only** (high) — Settings server status dot
  - Decorative status Circle traversed by VoiceOver (redundant) — but text label present so not color-only.
  - Fix: iOSSettingsView:289 — .accessibilityHidden(true) on the Circle.
- [ ] **#75 [low] userdefaults-for-email-lowsensitivity** (medium) — Email storage
  - Account email in UserDefaults (unencrypted, in iCloud backup).
  - Fix: Store email in the per-account Keychain slot, or exclude the plist from backup.
- [ ] **#76 [low] no-access-control-internal-types** (high) — Code health — browse layer
  - File-local types default to internal, widening module surface.
  - Fix: Mark RailItem/iOSPosterMenu/iOSPlayerLaunch/PosterGrid/etc. private; do during the iOSRootView split.
- [ ] **#77 [low] duplicate-fetchskiptimestamps-guard** (high) — Player skip intro/outro
  - Unreachable 'if key != skipFetchKey' branch after the guard.
  - Fix: PlayerScreen:892 — remove the redundant if; clear candidates unconditionally after the guard.
- [ ] **#78 [low] magic-number-playerprogress-5s** (high) — Player progress/resume thresholds
  - Three identical-looking '5' literals with different meanings.
  - Fix: Define progressReportInterval + minimumResumeThreshold constants (PlayerScreen:288/578/649).
- [ ] **#79 [low] missing-sendable-featuredHeroItem** (high) — Hero / cross-actor models
  - FeaturedHeroItem (+ WatchEntry/PlaybackMeta/CoreStreamSourceGroup) cross actor boundaries without Sendable.
  - Fix: Add Sendable conformance to these all-value-type structs.
- [ ] **#80 [low] dead-stremioserver-prepare-resolveurl-drift** (high) — Code health — StremioServer
  - StremioServer.prepare/resolveURL are dead duplicates of the live torrent-prime path; drift risk.
  - Fix: Delete the dead methods (StremioServer:104-134) or consolidate the live path onto the retry-capable version.
- [ ] **#81 [low] hls-v2-disabled-correct-for-libmpv** (high) — Engine config — HLS_V2_DISABLED
  - Working-as-designed: libmpv bypasses /hlsv2; beta8 flags are correct.
  - Fix: No change; add a one-line comment near NodeServer.swift:82 so a future maintainer doesn't re-enable it.
- [ ] **#82 [low] WORKING-AS-DESIGNED-cluster (layout-detail/addons/live/settings-safe, serverconfig-buttonrow)** (high) — Detail, Add-ons, Live, Settings, ServerConfig layout
  - No clipping — already safe (width anchors / LazyVStack / Form / screenInset). Listed only so the S1 pass doesn't regress them.
  - Fix: No change required. Do NOT add .fixedSize(horizontal:) to serif hero titles; keep backdrop width anchors. Optional LazyVStack for blanket consistency.

## Build plan

Implement systemic fixes first (one fix repaints/repairs many screens), then the dependent UI, then polish. Verify on the platform that exhibits each bug.

PHASE 0 — Crashes & data safety (fast, low-risk, ship even if nothing else lands):
1. crash-force-unwrap-groupedtrackrows (PlayerScreen:1058 guard let). 2. S11 URL force-unwraps (StremioAccount/ProfileSync guard-let). 3. S10 isSignedIn guard (StremioAccount:210/225). 4. state-never-reset-appliedinitialresume (PlayerScreen:642). 5. duplicate-skip-guard + magic-number constants + Sendable conformances (trivial).
Verify: open a dual-audio title's Audio panel on iPhone + Mac (no crash); sign in via password AND QR (no freeze); switch source mid-play and confirm resume position carries.

PHASE 1 — S1 viewport clipping (THE user-reported bug) + S1b picker:
LazyVStack conversions (ProfilesView:299, iOSRootView:381, iOSSignInView:29), .frame(width→maxWidth) at ProfilesView 307/319/377/154, wrap ProfileBackgroundPicker + ProfilePickerView HStacks in horizontal ScrollView (#if os(tvOS) keep HStack), clamp the hero title.
Verify on iPhone SE (320pt) + iPhone 15 + iPad portrait + Slide Over: Add/Edit Profile shows full 'Profile' title and un-clipped fields/chips; 'Who's watching?' with 3+ profiles scrolls instead of clipping; Search with results doesn't shift. Re-check Home/Discover/Library/Detail/Add-ons/Settings did NOT regress (WORKING-AS-DESIGNED cluster).

PHASE 2 — S2 macOS player presentation (blocks the whole Mac player UX) + dependent Mac controls:
Re-present the macOS player at the window root (or interim NSViewRepresentable titlebar fix) OUTSIDE the searchable NavigationStack; then player-mac-keyboard-shortcuts, player-no-persistent-close-on-mac, parity-macos-no-menu-commands, parity-macos-no-hover-states, a11y-mac-keyboard-nav-player-panel.
Verify on macOS: open a title → player fills the window, no search bar/nav title bleed, titlebar handled; space/arrows/F/Esc work; Cmd-F focuses Search; hover lights up cards/chips; Tab can't reach controls behind an open panel.

PHASE 3 — S3 player episode contract → unlocks S5 completion + auto-advance + S-preload:
Extend PlayerLaunch/iOSPlayerLaunch (episodes/bingeGroup), thread into PlayerScreen, add playNext/playPrevious + .episodes panel; then S5 markPlaybackWatched(>=0.9)+finishedWatching(EOF)+auto-advance, then player-no-next-preload-binge, restart, metadata line, decoder/settings panel, scrubber scrubTarget. Split PlayerScreen.swift + iOSDetailView.swift here (size-ceiling) since these files are already open.
Verify on iPhone + Mac with a multi-episode series: Next/Prev/Episodes work; finishing an episode auto-advances; a title watched to ~90% flips to watched and leaves Continue Watching; decoder toggle rescues a bad clip; scrubber doesn't snap back mid-drag.

PHASE 4 — S6 + S7 source-state truth (depends on server accessors) + S5b/S2b/accent design:
S7 settle timer (iOSDetailView movie/live), S6 4-way empty state + PlayerScreen server-offline messaging, cache-cap-512mb + applyserverconfig-precap (engine memory — validate with [hb] rss heartbeat), then S5b onAccent adaptive (Theme:28), S2b root .tint, accent-inline-chip, danger/success tokens, splash, home empty-state button.
Verify: on a device with zero stream add-ons → 'no stream add-ons' message (not a forever spinner); kill the server (or low-RAM iPhone torrent) → 'server offline — relaunch' in both detail and player; Direct-Links-Only + torrent-only title → the filter message; switch accent to pink → primary-button INK and current-profile check go neutral (no orange), filter chips match the rest, danger reads as true red.

PHASE 5 — S9 CoreBridge @MainActor + NSLog→Logger + leaks + Keychain async + silenced errors:
Annotate @MainActor + hop in coreEventCallback + scheduleSessionRepair guard; os.Logger; cancel prepareTorrent/refreshSoon Tasks; macOS async Keychain; datastorePut/loadAddons error surfacing; split CoreBridge.swift.
Verify on all platforms (build under Swift 6 strict concurrency clean): sign-in/account-switch/board-load with no races; macOS sign-in doesn't stall; watch progress survives a flaky connection (logged).

PHASE 6 — S8 iPad/Mac size-class layer + S12 accessibility sweep + remaining design polish:
S8 horizontalSizeClass token layer (cards/grid/hero/inset/type ramp + side rail) — fixes iPad+Split View+Mac at once; a11y systemic (text scale→Dynamic Type + textScaleRange 2.0, poster/chip/tab labels, decorative hidden, contrast textTertiary, 44pt targets, auto-hide trap, tab a11yHidden) + the per-screen a11y leaves; dq-screen-title/empty-states/tabbar/settings polish; parity About server row + search sign-in gate.
Verify: iPad portrait + landscape + Split View and a resized Mac window show a real regular-width layout (bigger cards, side rail, taller hero), not a stretched phone; VoiceOver pass on player + Home + Profiles announces every control; Larger Text at 200% reflows; Increase Contrast / all 8 accents keep text ≥4.5:1.

Notes: items 80-82 (dead code, access-control, working-as-designed) fold into whichever phase touches those files. Anything tagged tvOS-only (splash) is independent and can ship anytime. The user-reported clipping is Phase 1 — if a single hotfix is wanted, ship Phase 0 + Phase 1 together.

## macOS-specific (added 2026-06-14, dedicated macOS audit — beyond S2/S8/#13/#14/#15)
- [ ] **[high] mac-intel-no-torrent-engine** — Intel Macs lose ALL torrent playback: bundled `node` is arm64-only (`fetch-node-macos.sh:14-19`, `MacNodeServer` resolves `node-darwin-arm64` with no x86_64 fallback). Fix: lipo a universal node, OR pin ARCHS=arm64 + runtime "torrent server unavailable on Intel" state (not an infinite spinner).
- [ ] **[high] mac-window-close-does-not-quit** — red-close/Cmd-W closes the window but the app + node server keep running headless (port 11470 held), no way back. `MacAppDelegate` (StremioXiOSApp.swift:79-83) lacks `applicationShouldTerminateAfterLastWindowClosed -> true`. Trivial fix.
- [ ] **[med] mac-cursor-never-hides-during-playback** — arrow cursor floats over the video forever (no `NSCursor.setHiddenUntilMouseMoves`). Pair with controls auto-hide.
- [ ] **[med] mac-no-pointing-hand-cursor** — cards/chips/rows/tabs (all `.buttonStyle(.plain)`) show the arrow, not the hand → nothing reads clickable. Add `.pointerStyle(.link)`/onHover NSCursor on shared wrappers.
- [ ] **[med] mac-multiple-searchable-toolbars** — opacity-ZStack mounts all 7 tab NavigationStacks at once, so the Search tab's `.searchable` leaks into the window titlebar regardless of active tab (only the wordmark was `isActive`-gated). Compounds S2. Gate `.searchable` by isActive or mount only the active stack.
- [ ] **[med] mac-no-return-to-submit** — Return doesn't submit Sign-In / Open-Link / Server-URL fields (no `.onSubmit`); Mac users have only a hardware keyboard.
- [ ] **[med] mac-no-double-click-fullscreen** — no double-click→fullscreen and (with S2) no way at all to make the video truly fullscreen on Mac. Fix with S2.
- [ ] **[low] mac-no-scroll-wheel-trackpad-player** — no scroll-to-seek / pinch-aspect / wheel-volume over the video.
- [ ] **[low] mac-keychain-disk-read-on-main** — sharpens #15: `Keychain.string()` does a synchronous `Data(contentsOf:)` of credentials.plist on EVERY call on the main thread (no in-memory cache). Add a cache, not just an async variant.

## User-reported (2026-06-14) — fold into the right phase
- [ ] **[high] cw-hero-no-metadata** — the featured backdrop hero shows NO rating/year/genres/synopsis for CONTINUE WATCHING items (e.g. Game of Thrones, a `tt` id) — only title + Play. Catalog heroes (Disclosure Day/Obsession, from(meta:)) are rich; CW heroes (from(cw:)) carry only name+poster and rely on FeaturedHeroModel.enrichIfNeeded, which isn't landing (apply-race: hero rotates during the ~6s fetch, and/or configureMetaSources only runs at onAppear before addons load). Fix: reconfigure meta sources on `core.addons.count` change + de-dup in-flight enrich fetches + apply when the id still matches (mirror tvOS FocusedItemModel). NOT core.loadMeta (single shared slot the detail page owns). This is the recurring "#54" CW-backdrop-metadata bug.
- [ ] **[high] ios-detail-view-scaling** (redditor, beta7) — "Home scales properly but the DETAIL view has the same [scaling] issue" on iPhone. The A-Z layout audit marked Detail "safe" — a real user disagrees, so RUNTIME-VERIFY the iPhone detail page (open a title) and find what scales/clips. May be type-scale or a fixed width in iOSDetailView not yet caught.
- [x] **[critical] tvos-server-dies-after-one-torrent** (issue #56, Apple TV HD 2GB) — SHIPPED beta11: extended NO_HTTPS_SERVER+HLS_V2_DISABLED to tvOS + device-aware 256/512MB cache cap. Memory-jetsam after the cache allocates on the first torrent. Stutter likely the same memory pressure; re-verify on a real Apple TV HD; if it persists, tune mpv read-ahead next.

## Shipped
- [x] **[critical] server-crash-real-cause-EADDRINUSE** (corrected) — NOT memory/jetsam (sim log: rss stable 150-410MB, never climbs; reporter on 8GB iPhone 17 Pro Max). Real cause: the 11471 web-proxy's `listen()` reports EADDRINUSE (a previous instance holds the port on fast relaunch/force-quit) as an async 'error' EVENT, which the try/catch can't catch -> UNCAUGHT exception crashes the whole node runtime incl. the 11470 streaming server. server.js handles 11470 EADDRINUSE itself ([warn]); only our 11471 proxy was unguarded. FIXED: the 11471 gate (build 96) removes the proxy from native iOS/tvOS entirely + an 'error' handler added so it can't crash even on the web-host. (beta11/12 device-cache changes are harmless but were NOT the fix.)
- beta10 (build 93): S4 mark-watched/finished (CW clears), mac-window-close-quits, mac Return-to-submit (sign-in + server URL), cooler danger red, poster-card VoiceOver labels.
- beta9 (build 92): S1 viewport clipping (all screens), S5b adaptive onAccent, #3/#4 crash guards, S10 isSignedIn guard.
- (false positive) #12 appliedInitialResume: NOT a bug — intentionally not reset (switches resume via nudgeResume; resetting would yank a mid-playback switch to 0:00). Working as designed.