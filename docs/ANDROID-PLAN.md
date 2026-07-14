# VortX Android — Master Build Plan (governing document)

**Status: living document.** This is the single source of truth for building the VortX Android app
(phone first, Android TV after) from its current skeleton up to parity with the Apple apps. It is
maintained by the **governing session** on branch `claude/vortx-android-plan-kiyl9y`; **worker
sessions** each execute exactly one session block below, on their own branch, and report back.
Supersedes the section references to the old internal "Android plan" found in
`android/app/build.gradle.kts` comments.

North star: **as genuine to the Apple apps as possible** (feature set, hierarchy, cinematic look per
`docs/DESIGN-SYSTEM.md`) while **feeling native on Android 16/17** (Material 3 Expressive motion and
components, predictive back, edge-to-edge, themed icons, MediaSession, PiP — Android idiom for
interaction, VortX idiom for look).

---

## 0. Ground truth (read before any session)

### What exists today
- `android/` — a ~2,500-line Compose skeleton: 6-tab shell (`ui/StremioXApp.kt`), mock
  `PreviewCatalogRepository`, Home/Detail/Discover/Search/Library/Settings placeholder screens,
  Material 3 default theme, Stremio/StremioX branding.
- **Engine seam (real, wired, unproven at runtime):** `engine/StremioXCore.kt` JNI onto
  `core/` (Rust cdylib `libstremiox_core.so`, `core/src/android_jni.rs`), JSON contract identical to
  the Apple `CoreBridge`. `EngineStremioRepository` translates engine state → UI models. A
  `cargoNdkBuild` gradle task cross-compiles when Rust+NDK exist (CI: `.github/workflows/android.yml`).
- **Player seam:** `player/PlayerEngine.kt` interface, `ExoPlayerEngine` (Media3 1.9.4),
  `PlayerEngineRouter`, and in the `full` flavor `mpv/` (dev.jdtech.mpv:libmpv 1.0.0, `MpvConfig`
  ported from the Apple player) with per-flavor `MpvEngineFactory`.
- **Debrid seam:** `debrid/DebridKeys.kt` (EncryptedSharedPreferences), `DebridResolver.kt`.
- Apple reference implementation: `app/SourcesShared/` (~110 files, all features),
  `app/SourcesiOS/` (phone/tablet screens — primary reference for Android phone),
  `app/SourcesTV/` (10-ft screens — primary reference for Android TV).
- Canonical design spec: `docs/DESIGN-SYSTEM.md` (tokens, components, screen blueprints §4,
  per-platform rules §5: "Android: Kotlin + Compose + Media3… iOS-parity on phone, tvOS-parity on
  Android TV").

### Hard invariants (violating any of these fails review)
1. **`applicationId = "com.vortx.android"` in both flavors.** The package, namespace, and the Kotlin
   engine class (`com.vortx.android.engine.StremioCoreNative`) all carry the VortX identity; the JNI
   symbol names in `core/src/android_jni.rs` derive from that exact package + class, so the two sides
   move together — renaming either alone breaks the dynamic link. (The original plan froze
   `com.stremiox.android` for sideload update continuity; that argument was void — there is no Android
   install base to keep continuous — so the id was moved to `com.vortx.android` at integration.) The
   only frozen identifier is the shared core crate's cdylib name `stremiox_core` (`libstremiox_core.so`),
   which is independent of the app package.
2. **Two flavors, one dimension (`distribution`), licensing boundary only:**
   - `full` = the sideloaded VortX release. libmpv is the **primary** player, Media3/ExoPlayer is the
     DV/Atmos fallback. GPL native libs allowed. Ships first (mirrors the Apple sideload-IPA model).
   - `play` = Play-Store-clean build. **No GPL native libs, ever.** ExoPlayer only. Same features
     otherwise; the router simply never offers mpv. Anything GPL goes behind `fullImplementation` /
     `src/full/` and a seam interface with a `src/play/` no-op twin (pattern already established by
     `MpvEngineFactory`).
3. **The engine is the truth.** Screens render stremio-core state; no hand-rolled add-on protocol
   calls for things the engine models (catalogs, library, continue watching, streams, add-ons).
   Direct HTTP is allowed only for what the Apple apps also do outside the engine (TMDB/Fanart
   enrichment, debrid APIs, SkipDB, trailers).
4. **Design-system rule:** a screen is "done" only when it matches `docs/DESIGN-SYSTEM.md`. The VortX
   palette/type/spacing/components are non-negotiable; Material 3 supplies behavior (ripple,
   predictive back, motion springs, sliders, sheets), not colors. Anti-patterns list in §7 of that
   doc applies verbatim.
5. **Secrets in Keystore-backed storage** (EncryptedSharedPreferences / Android Keystore), never
   plain prefs — account token, debrid keys, profile PIN hashes.
6. **minSdk 26, edge-to-edge, target current SDK** (targetSdk bump is its own reviewed change, S1).
7. **One binary per flavor covers phone, tablet, and TV.** There is no third flavor and no
   dedicated TV APK; see "Form factors & packaging" below.

### Form factors & packaging: no dedicated TV APK
**Decision:** phone and Android TV ship in the **same APK/AAB per flavor**. TV is a **runtime UI
variant** (form-factor detection → TV navigation shell), not a build variant. The flavor dimension
stays `distribution` (full/play) only — a TV split would double the matrix to four artifacts and,
worse, a separate TV applicationId would break invariant #1 and split accounts/settings between a
user's own devices.

Why one binary works and is the right call:
- **Sideload (full flavor):** one `VortX-android-x.y.z.apk` installs on phones, tablets, Google TV,
  and Fire TV alike — the Apple-style "grab the release asset" story stays simple, and an update is
  one artifact. The TV UI code (androidx.tv / Compose for TV) is pure Kotlin/DEX, adds ~no native
  weight; the heavy payload (libmpv `.so`s) is identical on both form factors anyway. Per-ABI split
  APKs (arm64-v8a primary, armeabi-v7a for older Fire TV sticks) are a size optimization in S15,
  orthogonal to form factor.
- **Play (play flavor):** Google explicitly supports one app bundle serving mobile + TV; the TV
  form factor is enabled in the Play Console (TV track + TV quality review), same package name,
  same AAB. Play then delivers the right slices per device.
- **Manifest requirements** (land in S13): a `LEANBACK_LAUNCHER` intent-filter entry point + TV
  banner (320×180 `xhdpi`), `<uses-feature android:name="android.software.leanback"
  android:required="false"/>` and `android.hardware.touchscreen` `required="false"` so one manifest
  is installable everywhere, full D-pad operability, and no TV-blocking requirements (camera,
  telephony, portrait-only) marked required.
- **Runtime routing:** on launch, detect TV (`UiModeManager.currentModeType ==
  UI_MODE_TYPE_TELEVISION` / leanback feature) and enter the TV shell (D-pad focus navigation,
  10-ft layouts per `SourcesTV/`); otherwise the touch shell. Shared: theme/tokens (S02), engine +
  repositories (S03+), ranking (S06), player engines and chrome logic (S07/S08), settings/profiles
  stores (S09). TV-only composables live in their own source folder/module so the boundary stays
  reviewable, but compile into the same artifact.
- **Fire TV:** the same sideloaded full-flavor APK covers it (Amazon Appstore, if ever pursued,
  takes the same binary under its own listing; armeabi-v7a via the S15 split for old sticks).

### Android-native translation table (Apple idiom → Android idiom)
| Apple apps | Android |
|---|---|
| Keychain | Android Keystore + EncryptedSharedPreferences |
| SwiftUI tab bar | M3 NavigationBar (phone) / NavigationRail (tablet/foldable) |
| Swipe back / tvOS Menu | Predictive back gesture (androidx.activity BackHandler + `android:enableOnBackInvokedCallback`) |
| Launch splash (SplashView.swift) | AndroidX SplashScreen API into a Compose VortX splash (honors `Settings.Global.ANIMATOR_DURATION_SCALE`/reduce motion) |
| Reduce Motion | `LocalAccessibilityManager` + animator duration scale checks |
| AVPlayer / MPVKit | Media3 ExoPlayer / libmpv (full) |
| Now Playing (MPNowPlayingInfoCenter) | MediaSession + playback notification (media3-session) |
| AirPlay | Cast output switcher hook (later; optional), PiP is the phone-native equivalent for "keep watching" |
| SF Symbols | Material Symbols, mapped to the DESIGN-SYSTEM §6 icon list |
| New York serif | Bundled OFL serif for hero/wordmark type (pick in S2; candidates: Source Serif 4, Lora — closest to Iowan Old Style; commit the .ttf, license note in THIRD-PARTY-NOTICES.md) |
| Haptics.swift | `HapticFeedback` / `View.performHapticFeedback` on confirm/focus actions |
| App icon | Adaptive icon + **monochrome layer** (themed icons, Android 13+) |

Material You dynamic color: offered as **one optional accent theme** ("Material You") alongside the
eight VortX accents; the default remains VortX gold on warm obsidian. Dynamic color never restyles
layout or surfaces, accent only (same rule as Apple accent themes).

---

## 1. Session map (the build order)

Each session = one worker session = one branch = one PR-sized deliverable. Sessions within a phase
may be parallelized only where marked ∥; everything else assumes the previous session merged.
Worker branches: `claude/android-s<NN>-<slug>`. Every session ends with: builds green for **both
flavors** (`assembleFullDebug` + `assemblePlayDebug`), the session's Definition of Done met, this
plan's status table (§3) update proposed in the PR description.

### Phase A — Foundation (make the skeleton true)

> **✅ PHASE A COMPLETE (2026-07-13)** — S01–S05 merged to fork `main` (@02a6e36) and device-verified. Phase A PR staged: frozen head branch `android-phase-a` on the fork; targets a to-be-created `android` integration branch on `VortXTV/VortX`. PR title/body prepared (see handoff).

**S01 — Rebrand + project hygiene + Android 16 baseline.**
Scope: user-facing VortX identity (app name, adaptive icon w/ monochrome layer from `docs/brand/`,
VortX splash via SplashScreen API per DESIGN-SYSTEM §2 "The mark", strings), keep all internal ids
(invariant #1). Gradle: version catalog (`libs.versions.toml`), targetSdk → 36, edge-to-edge
enforcement, predictive back opt-in, per-app language support (`localeConfig`), baseline lint/detekt,
Compose BOM refresh. Rename user-visible "StremioX" composable/window titles; source symbols may be
renamed **only** where no JNI/persistence contract binds them (StremioXCore stays). CI: make
`android.yml` build + upload both flavor APKs on every PR touching `android/` or `core/`.
DoD: fresh clone → both flavors build in CI; app installs, shows VortX icon/splash/name; no
functional regression to the skeleton screens.

**S02 — Design system in Compose (the VortX theme layer).**
Scope: implement DESIGN-SYSTEM §2–§3 as a `ui/theme` + `ui/components` library: color tokens (all
accent themes + OLED + optional Material You accent), type scale (bundled serif for hero/screen
titles + system sans; wordmark composable), 8pt spacing object, radius/elevation/motion specs
(spring `cubic-bezier(.2,.8,.2,1)` equivalents, 180/320ms, press scale .97, reduced-motion aware),
and the canonical components: PrimaryButton (the one gold CTA), Chip (single selected look),
SurfaceCard, PosterCard (2:3, progress track, watched dim+check), SourceRow, EpisodeRow, state
views (skeleton shimmer loading / composed empty / error with one chip action), icon mapping (§6).
Wire M3 `MaterialTheme` so M3 components inherit VortX colors. Include a debug-only "gallery"
screen rendering every component in every state for visual review.
DoD: gallery screen matches DESIGN-SYSTEM (spot-check against Apple screenshots in
`docs/screenshots/`); all existing screens re-skinned to the theme; zero hardcoded colors outside
the token file.

**S03 — Engine bring-up (the app becomes real).**
Scope: prove and finish the JNI path end-to-end on a device/emulator: `cargoNdkBuild` for
arm64-v8a (+x86_64 for emulator), engine init on app start, event→StateFlow bridge hardening
(threading, backpressure, process death), sign-in (email/password against the account API via the
engine ctx), token in Keystore-backed storage, sign-out, and the first real screen data: Board
(Home catalogs) + Continue Watching rendered from engine state, replacing `PreviewCatalogRepository`
behind the existing repository interface. Image loading via Coil. Keep the mock repository for
`@Preview`s only.
DoD: sign in on a real build, Home shows the account's actual catalogs + Continue Watching; kill
and relaunch restores state from engine persistence; CI builds the .so for both ABIs.

**S04 — Add-on management + Search + Discover + Library (engine breadth). ∥ with S05**
Scope: installed add-ons list/install-by-URL/remove (engine `ctx.addons`), the add-on catalog
browser, Discover with type/catalog/genre filters, Library with type/sort filters and
add/remove-from-library, Search across add-ons (debounced, recent-searches chips). All per the
DESIGN-SYSTEM §4 blueprints. Deep links (`stremio://` add-on install links).
DoD: add-on installed on Android appears on Apple app for the same account and vice versa; every
screen uses S02 components; blueprint layouts verified.

**S05 — Detail screen + metadata pipeline. ∥ with S04**
Scope: movie/series Detail per blueprint (hero banner ≠ full-page wash, dual scrim, meta row, one
gold Watch/Resume CTA + chips cluster, synopsis, credits, season selector + episode list with
watched ticks/progress stripes, per-season/series watched controls in long-press + `…` menu),
Add to Library chip, engine `metaDetails` field. Resume/Play targeting the right episode
(port the `SourcesTV/DetailView.swift` resume logic).
DoD: side-by-side with the iOS detail page for 3 sample titles (movie, in-progress series, unaired
series), same information hierarchy; watched state round-trips to the account.

### Phase B — Watch it (the player is the product)

**S06 — Sources: ranked Watch Now + quality picker.**
Scope: port `StreamRanking.swift` semantics (cached/direct first → resolution → remux → HDR;
Real-Debrid ranks last; per-add-on caps), the greyed Watch Now with live add-on counter until all
add-ons answer, the two-level Quality picker (tier → flavor, sizes, duplicate collapse), the full
ranked "All sources" list using SourceRow, per-series+profile quality memory. Debrid resolution
via `DebridResolver` (RD/TorBox/AllDebrid/Premiumize; keys from S09's settings, hardcode-none).
DoD: same title produces materially the same top pick as the Apple app on the same account; one
press on Watch Now plays (into S07's player).

**S07 — Player I: ExoPlayer end-to-end (both flavors' baseline).**
Scope: full playback path with Media3: HLS + progressive, track selection (audio/subtitle with
preferred-language rules), external subtitles from subtitle add-ons, subtitle styling prefs,
seek/scrub with the VortX chrome per DESIGN-SYSTEM §4 Player (thin top chrome, platform transport,
error → source list, never a dead screen), aspect fit/zoom/stretch, speed control, playback-info
overlay (res/codec/hw-decode/fps/dropped/buffer), MediaSession + notification, PiP, keep-screen-on,
AudioFocus, resume positions + live progress → engine (Continue Watching correct on other devices),
watched flip near the end. SurfaceView, never TextureView.
DoD: a debrid 4K HEVC file, an HLS live stream, and a direct http file all play with tracks,
subs, resume, PiP, and notification controls, in the **play** flavor.

**S08 — Player II: mpv primary (full flavor) + engine router policy.**
Scope: finish `MpvPlayer` to the `PlayerEngine` contract at feature parity with S07 chrome
(one chrome, two engines — the chrome must not know which engine runs), port the Apple mpv option
set (`MpvConfig`), hw-decode via mediacodec, libass subtitles + bundled fallback fonts, router
policy = mpv primary / Exo fallback for DV-profile cases (mirror the Apple AVPlayer↔mpv fallback
logic), in-player engine/source switching, stall recovery (reload in place at position → source
list after repeated stalls). Verify `play` flavor still contains zero GPL bits (APK inspection in CI:
fail if `libmpv.so`/`libplayer.so` appear in a play APK).
DoD: TrueHD/Atmos, DTS-HD MA, EAC3, 4K HDR files play correctly in full flavor via mpv; the same
build falls back to Exo for a DV file; play-flavor APK scan clean.

### Phase C — The VortX experience

**S09 — Settings + profiles + theming.**
Scope: Settings per blueprint (account, appearance: accent swatches + OLED + Material You + text
size, playback prefs: preferred audio/sub language, subtitle style, quality presets, Direct Links
Only toggle, server URL override), debrid keys UI (stored per invariant #5), full Profiles: roster,
"Who's watching?" launch picker (no wrong-profile flash), per-profile theme/history/PIN (salted
hash)/optional own account, instant re-theme on switch. Per-profile add-ons if the engine seam
allows (else stub behind the same interface and note it in §3).
DoD: two profiles with different accents + separate Continue Watching verified; PIN gate works;
Direct Links Only hides every torrent/magnet source app-wide.

**S10 — Home cinema layer: featured hero + living backdrop + Collections.**
Scope: the auto-rotating featured hero (logo, meta, synopsis, Details CTA + Trailer chip, ~6s
cross-fade, pause on background, reduced-motion static), living backdrop treatment adapted to
phone scroll (per iOS, not tvOS focus), Collections hub rails (Discover cards, Streaming Services
w/ logos, Genres → browse grids), reorder/toggle per screen, long-press poster menus everywhere
(dismiss from CW, details, library, watched controls). Trailer playback in-app (YouTube embed path
per `SourcesiOS/InHeroYouTubeTrailerView.swift` equivalent).
DoD: Home side-by-side with the iPhone app reads as the same product; rails reorder + persist.

**S11 — Playback intelligence + Live TV.**
Scope: skip intro/recap/credits via SkipDB (+ chapter merge + sanity guards, contribute-back
submissions), seamless binge (halfway prefetch, release-group lock, provider warm-up), Continue
Watching direct-resume of the exact last stream (LastStreamStore port), Live TV tab from tv/IPTV
add-ons (logo tiles, now/next EPG strip, live-tuned buffering).
DoD: skip buttons appear on a known title; next episode starts without quality jump on the same
release group; a live channel plays past segment boundaries.

**S12 — Data completeness: backup/restore, import, portability, updates.**
Scope: Backup & Restore to a single file via SAF (no tokens in the file — same rule as Apple),
Import from Stremio, library export/import, in-app update check (GitHub releases, full flavor
only; play flavor uses Play), diagnostics log + save-to-file, What's New screen, crash-safe
first-run experience. 40+ language groundwork: externalize all strings (translations themselves
can trail), RTL layout audit.
DoD: backup made on Android restores on a fresh install; strings 100% externalized; RTL smoke
test on ar locale.

### Phase D — Every screen (TV) and shipping

**S13 — Android TV app (tvOS parity, same APK — invariant #7).**
Scope: implement the TV runtime variant inside the existing artifact per "Form factors &
packaging" in §0: manifest work (LEANBACK_LAUNCHER entry, TV banner, leanback + touchscreen
`required="false"`, D-pad operability, no TV-blocking required features), runtime form-factor
routing into a TV shell, TV composables isolated in their own source folder or library module
(worker proposes the structure, governor approves before implementing — but it compiles into the
same APK/AAB, never a separate applicationId or flavor). Compose for TV (androidx.tv), D-pad focus
treatment = the DESIGN-SYSTEM focus glow, 10-ft Home/Detail/Discover/Library/Live per
`SourcesTV/`, QR sign-in (port `OrigamiSpace` LoginView flow), player chrome for remote
(hold-to-seek acceleration), profiles picker. Everything below the UI (engine, ranking, players,
settings/profiles stores, theme tokens) is reused, not duplicated. Same two flavors apply
unchanged.
DoD: the **same APK** installs and runs correctly on a phone and on a Google TV / Fire TV device
or emulator; on TV, full D-pad navigation with no touch-only dead ends and the leanback launcher
shows the VortX banner; on phone, zero regression; side-by-side with Apple TV screenshots.

**S14 — Torrent path (full flavor): embedded streaming server.**
Scope: decide + implement the torrent story for `full` (options, worker evaluates: nodejs-mobile +
`server.js` exactly like Apple full builds, vs. pointing at an external/self-hosted server only).
Direct Links Only stays the play-flavor-like safety switch. Peer-count/speed feedback under the
spinner, TCP/TLS trackers, patience tuning per the Apple server handling. `play` flavor: never
bundles a torrent engine (torrents surface only when a remote server is configured — the web/Lite
model).
DoD: a well-seeded public-domain torrent streams in full flavor; play flavor shows the
server-required state instead.

**S15 — Release engineering + hardening.**
Scope: R8/minify + baseline profiles + startup metrics, per-ABI split APKs for the sideloaded
full flavor (arm64-v8a primary + armeabi-v7a for older Fire TV sticks, plus the universal APK) and
the single AAB for play (serving mobile + TV from one bundle; enable the TV form factor in the
Play Console when that listing happens), signing + versioning scheme aligned with the Apple
release train, SHA-256 checksums + verified
`-ci` build parity in releases, Play pre-launch checklist (data safety, no GPL), accessibility
pass (TalkBack on every screen, touch targets, contrast — tokens already pass 4.5:1), performance
pass (jank on rails, image cache tuning), THIRD-PARTY-NOTICES update, README/ROADMAP update to
declare Android shipped.
DoD: release candidate APKs (full) + bundle (play) produced by CI from a tag; cold start < 1.5s
on a mid-range device; TalkBack walkthrough of Home→Detail→Player clean.

### Later (post-1.0-parity backlog, not scheduled)
Downloads/offline (port DownloadManager), Trakt, cast/output switcher, VortX account E2E sync,
widgets/glance, Wear remote, foldable/tablet two-pane layouts (NavigationRail groundwork lands in
S01), kids mode, channel guide + M3U import — pull from `ROADMAP.md` as the Apple side evolves.

**Deferred polish items (device-test feedback, revisit in S10 or a dedicated polish pass):**
- Discover filter chips render as three stacked rows (type / catalog / genre) which reads cramped,
  especially on narrow/foldable cover screens — redesign into a cleaner single-line or collapsible
  filter affordance (device feedback 2026-07-13, deferred by maintainer).

---

## 2. How worker sessions run (protocol)

1. **Branch**: `claude/android-s<NN>-<slug>` off the current integration state (default branch
   unless the governor says otherwise). One session block per branch. Never push to another
   session's branch.
2. **First acts**: read this file top to bottom, read `docs/DESIGN-SYSTEM.md`, read the Apple
   reference files named in your session block, read the existing Android code you'll touch.
3. **Scope discipline**: deliver the block's Scope, nothing beyond it. If you discover prerequisite
   work missing, do the minimum seam/stub, mark it in your report, don't silently expand.
4. **Both flavors always**: every commit keeps `assembleFullDebug` and `assemblePlayDebug` green.
   GPL isolation (invariant #2) is checked in review on every PR.
5. **Comments carry contracts**, not narration — the existing code's comment style (why + boundary,
   e.g. the licensing notes in `build.gradle.kts`) is the house style.
6. **Report back** (PR description): what shipped, what's stubbed, deviations from this plan +
   why, the proposed §3 status update, and anything the next session must know (this replaces a
   separate handoff file).
7. **The governor** (this session) reviews against the block's DoD + invariants, merges, updates
   §3 below, and cuts the next worker prompt from the template in §4.

## 3. Status board (governor-maintained)

| Session | Title | State | Branch | Notes |
|---|---|---|---|---|
| S01 | Rebrand + hygiene + A16 baseline | **merged** | `claude/android-s01-rebrand-baseline` | merged 2026-07-12; both flavors built + linted clean (real SDK/NDK verified locally); GPL isolation confirmed by APK inspection. Deferred: animated splash sequence (S02/S10), TV banner (S13, lint check disabled until then), predictive-back stack (lands with real navigation), DebridKeys migration off deprecated security-crypto (future session). S02 first target: `ui/theme/Theme.kt` still carries the old palette. |
| S02 | Design system in Compose | **merged** | `claude/android-s02-design-system` | merged 2026-07-12; tokens/typography (Lora OFL serif)/components/debug gallery per DESIGN-SYSTEM §2–3, ported value-for-value from ThemeManager.swift; both flavors build + lint clean; GPL isolation reconfirmed. Deferred: theme persistence → S09 (gallery switcher is local-only); on-device gallery screenshot review pending. API notes for later sessions: use `VortXTheme.colors/type/spacing/...` not raw `MaterialTheme.colorScheme`; `PosterCard`/`EpisodeRow` art slots take Coil `AsyncImage` in S03; `VortXIcons` is the only icon source. |
| S03 | Engine bring-up | ✅ **DONE (device-verified 2026-07-12)** | `claude/android-s03-engine-bringup` | Round 2 root-caused + fixed the silent board load: `EngineActions.loadBoard()`/`loadLibrary()`/`searchLoad()` sent `args: null` for stremio-core `ActionLoad` variants whose `Selected` payload is a REQUIRED struct (not an `Option`), so `serde_json` rejected the whole action envelope before dispatch ever ran — zero events, zero errors, matching the device log exactly. Fixed to mirror Apple `CoreBridge` byte-for-byte (`{"type":null,"extra":[]}` / `{"request":{"type":null,"sort":"lastwatched","page":1}}`). Also hardened the FFI boundary: `dispatch_json`/`get_state_json` (core/src/lib.rs) now log unparseable envelopes via `serde_path_to_error` + the `log` crate, routed to `adb logcat -s StremioXEngine` by `android_logger` (installed in `nativeInit`, core/src/android_jni.rs; Android-gated so the Apple staticlib build is unaffected) — a malformed action can never be silent again. Sign-out CW/board persistence bug: root-caused to a stremio-core quirk (`Ctx::Logout` emits `LibraryChanged(false)`, but `ContinueWatchingPreview::update` only recomputes on `LibraryChanged(true)`) — worked around in `EngineStremioRepository` with a `suppressHomeUntilFreshLoad` flag that forces the CW rail empty from `signOut()` until the next `signIn()`'s real library sync. Series-detail landscape blank: applied the same `heightIn(max=…)` hero clamp pattern as `HomeScreen`'s tablet-portrait fix to `DetailScreen`'s `Backdrop` (260dp cap before the 16:9 aspect ratio) — flagged as the best evidence-based fix available without a landscape-device capture; the worker could not statically explain why movies were unaffected, so this needs device confirmation. Both flavors build + lint clean; both APKs carry `libstremiox_core.so` for arm64-v8a + x86_64; `play` flavor GPL-free. **Prior wins (round 1 + base):** native path proven, JNI symbols verified, engine process-scoped on `VortXApplication`, non-blocking event bridge, engine-ctx auth with Keystore-backed display-email-only cache, CW progress bars, tablet-portrait Home fix, human error messages, 32-bit `abiFilters` fix, Coil 3.3.0 (pinned). **S04 note:** `installed_addons_with_filters` may need adding to `TvosModel` + `get_state_json`; ctx actions dispatch with field=null; the one-event-await pattern is BANNED (use `loadFieldUntil` ready-predicate or the `homeUpdates` continuous-flow pattern). |
| S04 | Add-ons/Search/Discover/Library | ✅ **DONE (device-verified 2026-07-13)** — added `ctxUpdates()` reactive primitive so Library/add-on/sign-in refresh live; fixed Load-more crash (duplicate poster-id → LazyGrid key collision, deduped at parse); Discover chip-row spacing for Fold | `claude/android-s04-breadth` | Fixed the inert-Discover-chips bug (loadDiscover always sent args:null regardless of selection); `loadDiscoverSelect`/`loadLibrarySelect` now echo the engine's own per-chip `request` (mirrors CoreBridge.selectDiscover). Discover type/catalog/genre cascades from engine `selectable` blocks + Load-more; Library type/sort filters + remove badge; Search recent-history chips (plain-prefs store); new AddonsScreen (install-by-URL w/ client-side manifest fetch+validate + SSRF host guard, installed list, remove) off a Settings row. NO core/ change needed — ctx.profile.addons + selectable already carried everything (S03's installed_addons_with_filters flag was unnecessary). `CatalogRepository.discover()/library()` signatures changed to `(requestJson)`→`DiscoverResult`/`LibraryResult`. Governor merge with S05 resolved a duplicate addToLibrary/removeFromLibrary builder collision (both workers added identical fns); combined build verified green + play GPL-free. Deferred: add-on health/QR/reorder/store-browser, stremio:// deep links, long-press poster menus (S10). |
| S05 | Detail + metadata | ✅ **DONE (device-verified 2026-07-13)** — all fixes confirmed on Pixel Fold + Tab S11 Ultra; tablet hero overlap + Discover stale-on-removal resolved in round 2 — Saved chip now reactive via `ctxUpdates()`; whole-series mark-watched now iterates every episode/season both directions (engine aggregate flag never touched the per-video WatchedBitField); tablet Home rail-first ≥840dp + HeroHeader clip/ellipsis | `claude/android-s05-detail` | Full movie/series Detail per §4: hero banner (Coil backdrop + dual scrim, S03 landscape clamp kept), one gold Watch/Resume CTA, Save + Sources chips, synopsis, Cast/Director/Writer credits. Series: season chips (long-press + "…" bulk mark-watched menu), EpisodeRow list (Coil 16:9 thumb, tick/dim, progress stripe, per-ep long-press watched toggle), resume targeting ported from `seriesPrimaryEpisode` (in-progress→first-unwatched→first). Add-to-Library + watched-state round-trip via new Ctx/MetaDetails actions verified vs vendored stremio-core enums + CoreBridge; mutations swap in re-pulled meta so ticks/progress/chip update live. Both flavors build+lint clean; play GPL-free. Deferred: ranked sources+quality picker (S06 — Sources chip shows raw list), cast headshots/TMDB, Trailer chip (S10), spoiler-blur (S09). **S06 handoff:** replace `SourcesSection` (in the Sources SurfaceCard) with the ranked picker; streams already episode-scoped via `selectEpisode`; redirect `bestSource()` to ranked top pick; thread `libraryItem` resume position into resolved `Playable.startPositionMs`. |
| S06 | Ranked sources + quality picker | not started | — | |
| S07 | Player I: ExoPlayer | not started | — | |
| S08 | Player II: mpv primary (full) | not started | — | |
| S09 | Settings + profiles + theming | not started | — | |
| S10 | Hero + backdrop + Collections | not started | — | |
| S11 | Playback intelligence + Live TV | not started | — | |
| S12 | Backup/import/updates/i18n | not started | — | |
| S13 | Android TV (same APK, invariant #7) | not started | — | |
| S14 | Torrents (full flavor server) | not started | — | |
| S15 | Release engineering | not started | — | |

## 4. Worker prompt template (governor cuts one per session)

> You are a worker session building the VortX Android app. Read `docs/ANDROID-PLAN.md` on this
> branch first — it is the governing plan; your assignment is session **S<NN>** exactly as scoped
> there, under its invariants (§0) and protocol (§2). Develop on branch
> `claude/android-s<NN>-<slug>`. Reference the Apple implementation and `docs/DESIGN-SYSTEM.md`
> for every user-facing decision; translate Apple idiom to Android idiom per the table in §0.
> Keep both product flavors building at every commit and never let GPL code into the `play`
> flavor. When the Definition of Done is met, push, and write the report defined in §2.6.
> Context from previous sessions: <governor inserts merged-state summary + any deviations>.
