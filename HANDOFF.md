# StremioX Engineering Handoff (v1.0 push)

Last updated: 2026-06-09 (late). Author: previous Claude Code session. Audience: the next agent (or this one after a memory loss).

> **STATUS SUPERSEDE (2026-06-09, latest): v0.2.2 SHIPPED (build 22, commit 10543ba); v0.2.1 was a broken intermediate, all four of its regressions are fixed and sim-verified.** The Section 8 dynamic backdrop is now BUILT and shipped: Home uses a bottom-strip rail viewport (rows tuck under the hero; the focus engine centers rows inside the strip only) plus a bottom-anchored details block (`BrowseHeroBackdrop.detailsBottom`, immune to the ~130pt top safe-area shift the visible tab bar causes). Hero details enrich through the user's own meta add-ons (every id scheme incl. `tmdb:`), with a persistent `hero-cache.json` and a Continue Watching `warm()` prefetch. The hero details block is a focusable Button: it opens the title and bridges focus rail -> hero -> tab bar (the 0.2.1 "cannot go up" bug is dead). The quality picker is two-level (4K/1080p/720p/Others, then flavor-deduped variants). **The user ordered a PAUSE after this ship; do not resume building until they say go. Queued next: README/wiki gallery of ALL pages and settings (app + player panels) with images, Discover/Library bottom-strip treatment, skip v2 (AniSkip etc.), then 0.3.0 iOS/iPadOS port (CHECKPOINT architecture with the user first).**
>
> **STATUS (older, 2026-06-09 night): v0.2.0 SHIPPED.** Skip intro/outro Layers 1+2a are LIVE and sim-verified end to end (the pill appeared on GoT S1E2/E3 from TheIntroDB data and Select skipped past the boundary). The launch bug was id schemes: Stremio metas from TMDB-based catalog add-ons use `tmdb:1399`-style ids, so the service maps `tt`/`tmdb:`/`tvdb:` prefixes to the matching API parameter (TheIntroDB's canonical key is the TMDB id). Implementation lives in `app/Sources/Player/SkipSegments.swift` (widened model + pure resolver), `app/Sources/Player/SkipTimestampService.swift` (client + disk cache), and the TVPlayerView duration-event hook; os.log instrumentation under subsystem `com.stremiox.app`, categories `tvplayer` and `skiptimes`. Also shipped in 0.2.0: full-bleed cinematic movie/episode pages, accent-colored focused tab, reachable Sources button. **NEW VERSION LADDER (user-decreed): 0.3.0 = iOS/iPadOS native port; further 0.x = remaining features (skip L2b AniSkip + L3/L4/L5 per Section 7, profiles, downloads, Trakt, etc.); v1.0 = our OWN core + server, at which point the app gets a NEW NAME.** Sections 7 and 8 below remain the implementation specs for the skip layers and the browse-page dynamic backdrop (the backdrop feature is still unbuilt and is high on the user's wish list).

This document is self-contained. Read it top to bottom before touching code. It covers: what the app is, how to build and ship it, hard constraints you must not violate, the codebase map, and full implementation specs for the two features the user wants next (bulletproof skip intro/outro, and the dynamic focused backdrop on the browse pages). Nothing here is hand-wavy on purpose; where a number or endpoint matters it is written down.

---

## 0. How to use this doc

- Sections 1 to 6 are orientation and operations (what, where, how to build and ship).
- Section 7 is the SKIP INTRO/OUTRO research and architecture (the user's top priority: "works 99% of the time even with no API, no chapters, no audio cues, no subtitles"). It is long because it has to be.
- Section 8 is the DYNAMIC BACKDROP feature for Home/Discover/Library (the "HOPPERS" screenshot the user sent).
- Section 9 is the rest of the v1.0 roadmap.
- Section 10 is gotchas. Section 11 is links.

---

## 1. What StremioX is

A third-party, fully native Stremio client for Apple TV (tvOS), with iOS/iPadOS planned. Apple removed Stremio from the App Store, official Apple development stopped, so this is a from-scratch native client built on Stremio's own open engine.

- **Engine:** `stremio-core` (Rust), vendored as `Vendor/StremioXCore.xcframework` (a static lib with a C ABI). All catalog, addon, library, and stream logic goes through it as JSON dispatch. We do not reimplement Stremio logic in Swift.
- **Player:** libmpv via the **MPVKit** Swift package (`MPVKit-GPL`), rendering into a Metal view. This is what plays the video. No AVPlayer for playback.
- **Streaming server:** an embedded **nodejs-mobile** runtime (`Vendor/nodejs-mobile/NodeMobile.xcframework`) running Stremio's `server.js` locally, for torrent streaming and the local HTTP bridge.
- **UI:** SwiftUI, an editorial dark design system (serif display type, an "ember" warm accent, OLED option, 8 accent themes).

Content is identified the Stremio way: an **IMDB id** (`ttXXXXXXX`) plus `season`/`episode` for series, sourced from Cinemeta. Keep that in mind for everything in Section 7, it is the join key to every external timestamp database.

- **Repo:** https://github.com/mamaclapper/StremioX (gh user `mamaclapper`), branch `main`.
- **Code root:** `/Users/daksh/stremio-apple/app`
- **tvOS bundle id:** `com.stremiox.tv`. iOS bundle id: `com.stremiox.app`.
- **Current shipped version:** tvOS **0.1.7.15** (build 18), released 2026-06-09. Latest release is the stream-screen layout fix described in Section 4.

---

## 2. Build, run, and ship recipe (exact)

Always set the toolchain first:

```bash
cd /Users/daksh/stremio-apple/app
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

**Regenerate the Xcode project** (after editing `project.yml` or adding files):

```bash
xcodegen generate
```

**Simulator build (Debug).** The Mac is Apple Silicon. The vendored `libstremiox_core` and `NodeMobile` only ship an **arm64** simulator slice, not x86_64. If you build with a plain `generic/platform=tvOS Simulator` destination it will try to also build the x86_64 slice and fail at link with `Undefined symbols ... _stremiox_core_* ... for architecture x86_64`. That is NOT a code error. Pin arm64:

```bash
xcodebuild -scheme StremioXTV -sdk appletvsimulator -configuration Debug \
  -derivedDataPath build/dd-sim -destination 'generic/platform=tvOS Simulator' \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO build
```

**Install + launch on the sim** (UDID below is the project's standard sim, Apple TV 4K 3rd gen, tvOS 26.5, already signed into a Stremio account with addons and debrid configured):

```bash
SIM=67640D6F-C574-4511-94C8-8AAE4CFF299D
xcrun simctl boot "$SIM"   # ignore error if already booted
open -a Simulator
APP=$(find build/dd-sim/Build/Products/Debug-appletvsimulator -maxdepth 1 -name "StremioXTV.app" | head -1)
xcrun simctl install "$SIM" "$APP"
xcrun simctl launch "$SIM" com.stremiox.tv
xcrun simctl io "$SIM" screenshot /tmp/shot.png   # capture live Metal video too
```

**Device IPA (Release, unsigned, for sideload):**

```bash
xcodebuild -scheme StremioXTV -sdk appletvos -configuration Release \
  -derivedDataPath build/dd ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build
APP=$(find build/dd/Build/Products/Release-appletvos -maxdepth 1 -name "StremioXTV.app" | head -1)
rm -rf /tmp/payload && mkdir -p /tmp/payload/Payload && cp -R "$APP" /tmp/payload/Payload/
( cd /tmp/payload && zip -ry /tmp/StremioX-tvOS-<version>.ipa Payload >/dev/null )
```

**Release** (the user authorizes releases explicitly; do not publish without that):

```bash
gh release create vX.Y.Z "/tmp/StremioX-tvOS-X.Y.Z.ipa" --target main \
  --title "tvOS X.Y.Z (short summary)" --notes-file notes.md
```

Asset naming convention is `StremioX-tvOS-<version>.ipa`. `gh release upload --clobber` only replaces an asset of the **same filename**; if you upload under a different name you get duplicate assets (this bit me once, clean up with `gh release delete-asset`).

---

## 3. Hard constraints (do not violate)

These are user rules. They override defaults.

1. **No em dashes anywhere** in repo docs, commits, or release notes. No "long dash" and no `--` either. Use commas, colons, semicolons, periods, or parentheses. (This document follows that rule.)
2. **Never name competitor Stremio frontends** in repo docs, commits, or release notes. The user keeps the specific list (he has named them in chat); do not enumerate them in any file under the repo. Discussing them in chat or the private Brain wiki is fine. NOTE: Jellyfin, Plex, Emby, Infuse, Netflix, comskip, AniSkip, TheIntroDB are NOT competitors (they are media servers, services, or public APIs), so they are fine to name, and Section 7 does.
3. **Security:** never enter credentials or sign into anything in the sim or on device. Never curl or probe the user's debrid endpoints or API keys (TorBox, Real-Debrid, etc.). Do not run `gh auth login`. Keychain for any secret, never `UserDefaults`.
4. **Brain wiki:** never write to `wiki/archived/`, never modify anything in `raw/`. The session Stop hook writes session notes automatically.
5. **Commits:** conventional-commits style (`feat(tvos): ...`, `fix(tvos): ...`), no attribution/co-author line (the user disabled it globally; existing history has none).

---

## 4. What just shipped (0.1.7.15, build 18)

The user reported the stream screen looked like "a black bar and two buttons in the middle." Root cause and fix:

- `CoreStreamList` (in `app/SourcesTV/DetailView.swift`) is a `VStack(alignment: .leading)`. A SwiftUI VStack sizes to its widest child; `.leading` only aligns children inside that width, it does not fill the parent. In the new "Watch Now first" design, while sources are still loading the only children are the two buttons plus a status line, all intrinsic width, so the column collapsed to button width and the enclosing `ScrollView` centered it. That is the black strip.
- Fix part 1: `.frame(maxWidth: .infinity, alignment: .leading)` on the `CoreStreamList` root VStack so it always fills width.
- Fix part 2: `CoreEpisodeStreams` (the series-episode stream screen, which has no movie hero above it) got a cinematic header that mirrors the movie hero: the episode still bleeding to the top edge with a canvas gradient, the show name eyebrow, the episode title, `S{n} . E{n}`, air date, and overview. Verified on the sim with Game of Thrones S1E1: full-bleed still, "GAME OF THRONES" eyebrow, "Winter is Coming", "Watch in 4K" and "All sources . 193" left-aligned.

Also in 0.1.7.15 (from the prior held commit `1b7bebe`): `StreamRanking.swift` (resolution + remux/bluray + HDR + cached-first scoring) and the Watch-Now button (one press plays the best source, long-press picks a resolution, full list behind "All sources").

---

## 4b. Open punch-list from the user's bug testing (smaller polish items)

These were reported in an earlier bug-test pass and are still open. The user is testing again as of this handoff, so expect more. Treat this as partial.

1. **Player "Sources" button is visible but unreachable.** The `.sources` control is drawn in `TVPlayerView` (gated on `hasAlternateSources`) but is missing from the `buttonRow` focus-navigation array (around L225-237), so the remote can never focus it. Fix: add `.sources` to `buttonRow` under the same guard, and give it a clearer icon than `rectangle.stack`.
2. **Top-nav focused tab is white**, the user wants it recolored to the active accent. This is tvOS TabView focus styling, likely needs a `UITabBarAppearance` or a custom bar.
3. **"Warm" chrome should follow the accent.** Today the warm (non-OLED) canvas is a fixed warm near-black; the user wants it tinted toward the chosen accent hue (OLED stays pure black). Derive `ThemeManager.canvas`/`surface1-3` tints from the accent hue.
4. **Watched ticks should be accent-colored.** The episode checkmark and the thumbnail tick badge in `DetailView` are grey/white; make them use `Theme.Palette.accent`.
5. **Watch-Now redesign** (largely shipped in 0.1.7.15): "Watch in {res}" plays the best source with a long-press resolution dropdown, "All sources" reveals the full ranked list. If the user wants the source list auto-expanded or a different default, that is a tuning follow-up.

---

## 5. Codebase map (the files that matter)

All under `app/`.

- `SourcesTV/CoreBridge.swift` : the Swift to Rust FFI. `dispatchCtx(["action":..,"args":..])`, `streamGroups() -> [CoreStreamSourceGroup]`, `metaDetails`, library/watched actions. `metaDetails` stays loaded during playback (DetailView does NOT unloadMeta on disappear), which is what enables the in-player source switcher.
- `SourcesTV/CoreModels.swift` : `CoreMetaItem` (id, name, poster, background, description, videos, ...), `CoreVideo` (id, title, released, overview, thumbnail, season, episode), `CoreStream`, `CoreStreamSourceGroup`.
- `SourcesTV/DetailView.swift` : meta detail. `DetailView` (movie or series), `hero(...)` (the reusable cinematic backdrop+metadata band, template for Section 8), `CoreSeasonedEpisodes` (season selector + episode rows), `CoreEpisodeStreams` (one episode's streams + the new header), `CoreStreamList` (the per-addon ranked stream list + Watch-Now).
- `SourcesTV/TVPlayerView.swift` : the player UI. UIKit `RemoteCatcher` for input, a `@State` machine, `handlePress`, the options panel (audio/subtitle/aspect/episodes), skip intro/outro pill, in-player source switcher, auto-recovery. Holds `meta: PlaybackMeta?`, `curMeta` (the current episode, changes on Next/Prev), `episodes: [CoreVideo]`, `duration`, `skipSegments`, `refreshSkipSegments()` (called in the duration observer), `currentSkip`, `skipTo(_:)`.
- `Sources/Player/MPVMetalViewController.swift` : the libmpv wrapper. Scalar getters `getInt/getString/getDouble/getFlag`, `tracks(ofType:)`, `chapters()` (reads `chapter-list/N/{title,time}`). Cache config around L180-187 (currently 512MiB demuxer-max-bytes / 300s readahead on tvOS, flagged as oversized; watch for OOM).
- `Sources/Player/SkipSegments.swift` : the skip-segment model and detector. `MPVChapter{title,start}`, `SkipSegment{kind:.intro/.outro, start, end, label}`, `SkipSegments.detect(chapters:duration:)`. THIS IS LAYER 1 of the skip system in Section 7, and the seam everything else plugs into.
- `SourcesTV/StreamRanking.swift` : stream scoring + Watch-Now selection (`rankedGroups`, `best`, `resolutionOptions`, `qualityLabel`, `isCached`).
- `SourcesTV/ThemeManager.swift` + `Theme.swift` : the theme system. `ThemeManager.shared` (ObservableObject, 8 accents + OLED, persisted). `Theme.Palette/Typography/Space/Radius`. IMPORTANT SwiftUI lesson baked in here: a parent re-render does NOT re-run unchanged child view structs, so custom ButtonStyle content views and separate row structs that read static palette tokens stay stale on a theme change unless they themselves `@EnvironmentObject var theme: ThemeManager`. Fix is observers on those views, NOT a `.id()` rebuild (which drops focus). You will hit the same principle in Section 8.
- `SourcesTV/{HomeView,DiscoverView,LibraryView,AddonsView,SearchView,SettingsView}.swift` : the tabs. `RootTabView` is the shell. `SharedUI.swift` has `PosterCard`, `RailHeader`, the focus styles, and the long-press context menus.
- `SourcesTV/StremioAccount.swift` : `PlaybackMeta{libraryId, videoId, type, name, poster, season, episode}`, `StremioAccount` (auth, addons, stream sources), `PlayerPresenter` (root-replacement player presentation, the only reliable tvOS focus isolation).
- `project.yml` : xcodegen spec. `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` live here (two targets: `StremioX` iOS, `StremioXTV` tvOS), bump both.

**Core dispatch contract:** `ActionCtx` is `#[serde(tag="action", content="args")]` with no `rename_all`, so struct-variant fields are snake_case. Verified actions in use: `RemoveFromLibrary(id)`, `RewindLibraryItem(id)` (zeroes time_offset), `AddToLibrary(<MetaItemPreview>)`, `MetaItemMarkAsWatched {meta_item, is_watched}`, `LibraryItemMarkAsWatched {id, is_watched}`. `is_in_continue_watching()` = `type != "other" && (!removed||temp) && time_offset > 0` (does not check the watched flag).

---

## 6. The sim, for verification

- UDID `67640D6F-C574-4511-94C8-8AAE4CFF299D`, Apple TV 4K (3rd gen), tvOS 26.5, signed in, ~24 addons, ~15 stream sources (Debridio/TorBox).
- Drive it with computer-use: click the title bar to give the window key focus, then arrow keys move tvOS focus and Return selects, Escape is Menu/Back. `xcrun simctl io <udid> screenshot` captures the live Metal video frame (a synthetic Escape does NOT dismiss a tvOS contextMenu, terminate+relaunch if stuck).
- SourceKit in this environment throws false "Cannot find type CoreBridge/Theme/..." diagnostics on edited files because the standalone indexer lacks the whole module and the xcframework. `xcodebuild` is the source of truth, not the editor squiggles.

---

## 7. FEATURE: bulletproof skip intro / outro

The user's bar: skip intro AND outro (credits) reliably, about 99% of the time, including when there is no crowd API entry, no chapter markers, and we cannot pre-process the file on a server. This section is the synthesis of four research passes (crowd APIs, audio fingerprinting, on-device signal heuristics, and a field survey). All endpoints, constants, and repos below were verified on 2026-06-09.

### 7.1 The shape of the solution: layered candidate producers + one resolver

Do NOT build a single detector. Build **layers that each emit candidates**, plus one pure function that votes. Keep today's `SkipSegment` as the output type; widen it.

First refactor (Build Step 0, do this before anything else):

```swift
// Widen the existing model in Sources/Player/SkipSegments.swift
struct SegmentCandidate {
    enum Kind { case intro, recap, preview, credits }   // was just intro/outro
    enum Source { case chapter, crowdApi, audioFingerprint, heuristic, manual, sharedCache }
    let kind: Kind
    let start: Double          // seconds
    let end: Double            // seconds
    let source: Source
    let confidence: Double     // 0.0 - 1.0, calibrated per source (table below)
}

// Pure, unit-testable, no I/O. This is the integration contract.
enum SegmentResolver {
    static func resolve(_ candidates: [SegmentCandidate], duration: Double) -> [SkipSegment]
}
```

Every layer becomes "a thing that produces `[SegmentCandidate]`." The existing chapter detector is Layer 1, refactored to emit candidates through the resolver. The resolver is pure so you can unit-test it with Swift Testing and no network.

### 7.2 The layers, with realistic coverage

| Layer | Producer | Keyed by | When it runs | Realistic hit rate | Base confidence |
|---|---|---|---|---|---|
| **L1 Chapters** | existing `SkipSegments.detect` (mpv `chapter-list`, title token match) | embedded in file | on play, free | ~15 to 30% of files have named chapters; near-100% precise when titled | 0.8 if title token matched, 0.3 if positional only |
| **L2 Crowd API** | TheIntroDB (live action) + AniSkip (anime) | IMDB/TMDB/TVDB id + S/E; MAL id + ep for anime | on play (about 1.2s timeout) + prefetch | live action ~50 to 65% (often intro XOR credits, not both); anime ~85 to 95% | 0.9 |
| **L3 On-device audio fingerprint** | Chromaprint-style cross-episode matcher | imdb:season (needs 2+ episodes) | background prefetch | ~90%+ for series once 2 to 3 episodes seen; 0% for movies and the first-ever episode | 0.85 |
| **L4 On-device heuristics** | black frame + silence + credits OCR | imdb:season:episode (per file) | progressive during playback or short look-ahead | credits ~70 to 85%; intro alone ~40 to 50%; rises with signal agreement | 0.6 single signal, 0.8 when signals agree |
| **L5 Manual + shared cache** | user "set start/end" + content-hash shared store | imdb:S:E (+ file hash for shared) | instant, persisted | 100% where set | 1.0 manual, 0.95 shared |

**Single highest-leverage path:** L2. It is one HTTPS GET, reuses the IMDB id we already have, needs no DSP, and is exactly how Infuse (the only comparable native Apple TV client) gets to "works almost always" on mainstream content. Steps 1 and 2 below replicate Infuse-level coverage in roughly a week. L3 and L4 are what take the long tail of series and all movies toward 99%.

### 7.3 L2 crowd APIs (verified)

**TheIntroDB** (live action TV and movies). Primary for everything non-anime.
- `GET https://api.theintrodb.org/v3/media`
- Query: `tmdb_id` OR `imdb_id` (`^tt[0-9]{7,8}$`) OR `tvdb_id`; for TV add `season` and `episode`; for movies omit both. Optional `duration_ms` selects the closest release version (the per-release mechanism). Reads are anonymous (a Bearer key only boosts your own submissions).
- Priority when multiple ids given: tmdb_id, then tvdb_id, then imdb_id. IMDB and TVDB are resolved to TMDB server-side.
- Response: top-level `tmdb_id`, `type` ("tv"/"movie"), and up to four arrays, each `{start_ms, end_ms}`: `intro` (start_ms may be null = from 0), `recap`, `credits` (end_ms null = runs to end of file, the outro case), `preview`. Absent types are omitted.
- Verified example: `GET /v3/media?imdb_id=tt0903747&season=1&episode=1` (Breaking Bad) returns `{"tmdb_id":1396,"type":"tv","intro":[{"start_ms":228694,"end_ms":245250}],"credits":[{"start_ms":3431000,"end_ms":null}]}`.
- Limits: 30 req/10s; 500 `/media`/day per IP unauthenticated. Watch `X-RateLimit-*` and `X-UsageLimit-*` headers. Batch-prefetch the next N episodes in a session (well within budget).
- Errors: 400 (no id), 404 ("media not found"), 429 (limit).
- Coverage is hit or miss and frequently one-sided (intro XOR credits). That gap is for L3/L4 to fill.

**AniSkip** (anime). Primary for anime.
- `GET https://api.aniskip.com/v2/skip-times/{malId}/{episodeNumber}?types=op&types=ed&types=recap&episodeLength={seconds}`
- `animeId` is a **MyAnimeList id**, `episodeNumber` is the per-cour absolute number. `episodeLength=0` is accepted as unknown.
- Skip type enum: `op, ed, mixed-op, mixed-ed, recap`. Map op to intro, ed to credits/outro, recap to recap.
- Times are **seconds (float)** in `interval.startTime/endTime` (note: differs from TheIntroDB ms). Each result echoes its own `episodeLength`, use it to rescale to the real file duration.
- Verified: `GET /v2/skip-times/9253/1?types=op&types=ed&episodeLength=0` (Steins;Gate ep1) returns op `[638.489, 728.489]` and ed `[1331.713, 1421.713]`. Not found returns `{"found":false,"results":[],"statusCode":404}`.
- No auth. Rate limit header `X-RateLimit-Limit: 120`. Source is MIT (`github.com/aniskip/aniskip-api`).

**The IMDB to MAL bridge** (required for AniSkip, because Stremio gives IMDB id + S/E but AniSkip wants MAL id + absolute episode, and the mapping is many-to-one and offset-shifted, each cour is its own MAL id):
1. Runtime: arm-server, `GET https://arm.haglund.dev/api/v2/imdb?id=tt5370118` (also `/themoviedb`, `/thetvdb`). No auth.
2. Offline fallback: bundle Fribb/anime-lists `https://raw.githubusercontent.com/Fribb/anime-lists/master/anime-list-full.json` (each entry maps imdb_id, mal_id, anilist_id, kitsu_id, tvdb_id, themoviedb_id + a season hint). Self-updates daily.
3. Episode-number resolution: Jikan `https://api.jikan.moe/v4/anime/{malId}/episodes` for per-cour episode counts.
Cache the resolved `(imdb,S,E) -> (malId,ep)` tuple aggressively, it never changes. Validate a bridge hit by sanity-checking the returned `episodeLength` against the file before trusting it.

**Not usable as sources** (do not waste time): Plex markers (account-scoped, no by-IMDB query), Jellyfin Intro Skipper (purely local, it is the on-device approach you would build yourself, not a queryable DB), Trakt and TVTime (scrobbling only, no timestamps), MythTV/comskip (local ad cutlists). Intro Hater (`api.introhater.com`) exists but mostly re-aggregates TheIntroDB + AniSkip, treat as an optional opaque fallback only.

**Normalization:** convert everything to one unit internally (ms is fine). Treat `credits.end_ms == null` (TheIntroDB) or an AniSkip `ed.endTime` near `episodeLength` as "to end of file," clamp to the libmpv-reported duration. ALWAYS rescale remote timestamps to the actual local duration (`t * localDur / sourceDur`), rips differ from the submitter's runtime.

### 7.4 L3 on-device audio fingerprinting (the Jellyfin Intro Skipper method)

This is what makes series intros work with zero API and zero chapters. It fingerprints the audio of sibling episodes and finds the longest shared run = the intro.

**Two parts:** fingerprint generation (Chromaprint, off-the-shelf, MIT) and the matcher (custom, you reimplement in Swift, about 150 lines).

**Chromaprint (generation):** the Jellyfin plugin shells FFmpeg `-f chromaprint -fp_format raw` to get a stream of **uint32, one per about 0.128 s**. You do not have ffmpeg on tvOS, so instead **build libchromaprint with the vDSP FFT backend** (`cmake -DFFT_LIB=vdsp`, MIT license, links `Accelerate.framework`; do NOT use the FFTW3 backend, it is GPL). Use the `leetal/ios-cmake` toolchain which supports tvOS (`-DPLATFORM=TVOSCOMBINED`). C API: `chromaprint_new(CHROMAPRINT_ALGORITHM_DEFAULT)` (DEFAULT = TEST2, must match), `chromaprint_start(ctx, 11025, 1)`, `chromaprint_feed(ctx, int16*, size)`, `chromaprint_finish`, `chromaprint_get_raw_fingerprint`. Feed it **int16, 11025 Hz, mono** PCM.

**Where the PCM comes from on tvOS** (you cannot read mpv's decoded PCM through the public client API): run a **second, headless libmpv instance** to decode just the window you need, faster than realtime, to a temp WAV:

```
--no-video --vo=null --ao=pcm --ao-pcm-file=<tmp.wav>
--start=0 --length=<analyzeSeconds> --untimed
--audio-samplerate=11025 --audio-channels=mono
```

`--untimed` decodes at max CPU speed (not realtime). `--length` bounds it. This handles every container Stremio throws at it (MKV, EAC3, etc.) and does its own HTTP range reads, so you never download the whole file. (AVAssetReader is an alternative for MP4/HLS/debrid but does NOT demux MKV, which Stremio content frequently is, so headless mpv is the uniform path.) Decode only the intro window (first ~10 min) and credits window (last ~4 to 6 min), never the whole file. The temp WAV for 10 min mono 11025 is about 13 MB, delete it right after feeding Chromaprint.

**The matcher (port to Swift), exact constants:**

```swift
enum SkipConst {
    static let sampleDuration = 0.128      // seconds per fingerprint point (authoritative)
    static let maxPointDifferences = 6     // bits out of 32 (popcount of XOR)
    static let invertedIndexShift = 2      // fuzz on the point value when indexing
    static let maxTimeSkip = 3.5           // seconds, contiguity gap tolerance
    static let minIntroDuration = 15.0
    static let maxIntroDuration = 120.0
    static let minCreditsDuration = 15.0
    static let analysisPercent = 0.25      // intro search = first 25% of runtime
    static let analysisLengthLimitMin = 10.0   // capped at first 10 minutes
    static let creditsTailMinutes = 4.0
    static let startSnapThreshold = 5.0    // intro start <= 5s snaps to 0
}
```

Algorithm per episode pair (LHS, RHS): build a `[UInt32: Int]` inverted index of each fingerprint, discover candidate alignment shifts by looking up each LHS point in the RHS index with +/- `invertedIndexShift` fuzz (shift = rhsIndex - lhsIndex), then for each candidate shift XOR-walk both fingerprints in lockstep, mark positions where `(lhs ^ rhs).nonzeroBitCount < 6` as matching, convert matching indices to time (`index * 0.128`), group matches within `maxTimeSkip` (3.5s) into contiguous ranges, take the longest range >= 15s and <= 120s, snap start <= 5s to 0. Compare 3 sibling episodes (E, E-1, E+1) and keep the longest (longest-wins, the plugin does not average). Cache offsets AND raw fingerprints per `imdb:S:E` so re-detection when a new sibling appears does not re-decode.

**Movies and the first episode have no sibling**, so L3 produces nothing for them, fall through to L4.

### 7.5 L4 on-device signal heuristics (covers movies and where L2/L3 miss)

The pivotal finding: **you can pull already-decoded frames straight from libmpv with the `screenshot-raw` command (flag `video`)**, no second decode, no second network fetch. It returns an `MPV_FORMAT_NODE_MAP` with `w`, `h`, `stride` (use stride, rows are padded), `format` (e.g. `bgr0`), and `data` (BYTE_ARRAY). At 1080p one frame is about 8 MB, grab it, downsample immediately with `vImageScale_ARGB8888` to about 32x18, discard. **Sample at 1 to 2 Hz** (gate on `time-pos`), that is enough to bracket boundaries to about +/- 0.5 s.

- **Black frame** (highest precision, lowest cost): mean luma (Rec.709 `Y = 0.0722B + 0.7152G + 0.2126R`) over the downsampled frame via vDSP; a frame is black if no pixel exceeds a max brightness AND mean luma is below a low threshold (comskip's defaults are a good start: per-pixel max about 60/255, mean about 10 to 16/255). Coalesce consecutive black samples into intervals; a black interval near the start is an intro edge, near the end is a credits edge.
- **Silence** (most reliable single signal): two ways. Transport-agnostic, run live at the playhead via the mpv filter `af add @sd:lavfi=[silencedetect=n=-30dB:d=0.3]` and parse the results from mpv's log stream (`mpv_request_log_messages("v")`, then `MPV_EVENT_LOG_MESSAGE`, scrape `silence_start`/`silence_end`). Or, for look-ahead on range-friendly HTTP/debrid URLs, decode audio with AVAssetReader to float PCM and compute RMS per ~20 to 50 ms window with `vDSP_rmsqv`, threshold about -30 dB for >= 0.3 s.
- **Scene change** (supporting only): per-channel histogram on the same downsampled frame, frame-to-frame L1 distance, threshold about 0.35 to 0.45. Shares the screenshot pipeline, near-free.
- **Credits via Vision OCR** (strongest direct outro cue): gate to `p >= 0.80`, sample every 2 to 5 s, `screenshot-raw video` -> `CGImage` -> `VNRecognizeTextRequest` with `.fast` and `usesLanguageCorrection = false` and a modest `minimumTextHeight`. Signal = count of text observations plus vertical drift of their bounding boxes across samples (rolling credits drift upward; burned-in subtitles are 1 to 2 static lines, distinguish by count and motion). Both current Apple TV chips have a Neural Engine so a `.fast` pass is tens of ms. Keep on a background `.utility` queue.
- **Chapters** (L1, reused here as a high-weight prior with a title regex `/(intro|opening|^op$|credits|ending|^ed$|preview|recap)/i`).
- **Logo / aspect-ratio** (comskip-style): skip it, it targets broadcast content with channel bugs and ad breaks, not our case. The only near-free bonus is reading mpv `video-params/aspect` for a rare AR change.

**Transport caveat:** the AVFoundation second-decode (for look-ahead PCM or `AVAssetImageGenerator`) works on direct HTTP and debrid URLs (they honor byte ranges) but is unreliable on HLS and torrent URLs (out-of-order pieces, variant issues). So the robust core is entirely mpv-native (`screenshot-raw` + `silencedetect` filter-log + OCR), all of which work regardless of transport because mpv already owns the demux. AVFoundation is a bonus accelerator, never a dependency.

### 7.6 The resolver (fusion), confidence and graceful degradation

`SegmentResolver.resolve` is pure and deterministic:
1. Gather candidates from whatever layers produced results.
2. Validate-and-clamp each (these guards are how you kill false skips, borrowed from Plex/Jellyfin): intro/recap duration in [5s, 150s] and end <= min(0.25 * runtime, 600s) and start <= runtime/2; credits duration in [15s, 300s] and start in the last 25%; drop degenerate spans (end <= start + 1).
3. Cluster same-kind candidates that overlap (IoU > 0.5).
4. Within a cluster pick the winner by **priority then confidence** (a verified id-keyed answer beats a fuzzy local guess): manual 1.0 > crowd 0.9 / shared 0.95 > fingerprint 0.85 > named chapter 0.8 > heuristic <= 0.8 > positional chapter 0.3.
5. **Agreement boost** (this is what turns ~90% into ~99%): if two independent sources agree within +/- 2 s, take the higher-confidence boundaries and raise confidence to >= 0.95. **Boundary snap:** if a black-frame or silence (L4) sits within +/- 1.5 s of an L2/L3 reported end, snap to it (crowd timestamps are often a beat off; the local hard cut is frame-accurate).
6. Combine available signals with noisy-OR: `score = 1 - product(1 - w_k * s_k)`. Missing signals contribute 0 and simply drop out, so nothing is mandatory. Emit a `SkipSegment` only if score >= 0.55 (show the pill) and arm auto-skip only if >= 0.85.

Degradation ladder: titled chapter -> instant 0.95. Typical chapterless rip -> black + silence + (outro) OCR -> 0.7 to 0.9. Hard-cut content -> silence + scene + position -> 0.5 to 0.7, button shown only if it clears threshold. Pathological -> position prior only -> low confidence, button suppressed (the correct failure is "no offer," never a wrong skip).

### 7.7 When each layer runs

- **On play (synchronous, under ~150 ms, never block the first frame):** L1 chapters (already parsed free), L5 cache lookup (instant), fire L2 with a ~1.2s timeout, render the pill if any candidate clears 0.55. Kick off L4 outro look-ahead without blocking.
- **Background prefetch (the high-leverage offline play):** when a season opens or an episode starts, enqueue the next 1 to 3 episodes: L2-prefetch their timestamps, and run the L3 fingerprint job (decode the intro and credits windows of the current + cached siblings, match, cache per imdb:S:E). Background QoS, cancellable when the foreground decoder/CPU is needed, cap to 1 to 2 headless mpv instances.
- **Progressive during playback (L4, only when L1/L2/L3 left a gap):** as playback enters the last 25%, sample frames at ~2 Hz, detect black + silence, run one OCR pass on a black+silence boundary to confirm credits, emit the candidate, re-resolve, show the pill.

### 7.8 Caching and the optional shared store (L5)

- Key per-episode results `imdb:season:episode` (timestamps + winning layer + confidence). Separate `imdb:season` namespace for the learned intro fingerprint template (episode N reuses the season's known intro span). Store via an `actor`-backed on-disk JSON/SQLite. Cache raw fingerprints (re-resolution after a settings change is then free) and negative results with a ~7-day TTL (crowd DBs grow, do not re-hit forever).
- Optional shared store (Plex's privacy model): on a confident L3/L4 result or a manual set, submit `{contentHash, kind, start, end}` with NO IMDB id or title to a small StremioX-owned endpoint, and read others' hashes on play. `contentHash` = hash of (file size + a few sampled byte ranges) so the same release matches across users. Ship behind a default-off toggle.

### 7.9 The skip-pill UX (match Infuse, which users already know)

- Settings per Intro and per Credits, four modes: Off, On (manual button), Auto (3s delay), Auto (instant).
- Show the pill when `now` is in `[seg.start, seg.start + min(segLength, 10s)]` and confidence >= 0.55. Bottom-trailing, focusable, auto-focused so one click on the remote skips. Hide once past the window or once used.
- Auto-skip only when confidence >= 0.85 AND a validation guard passed. On Auto (delay) show a 3s "Skipping intro... [Cancel]" countdown (a false positive is then one click to abort). Never auto-skip an L4-only candidate below 0.8. Never skip the final segment if it would leave < 3s (avoid skipping into a post-credits scene; flag `preview`/post-credit separately and do not auto-skip those). Persist "user cancelled this skip" per imdb:S:E and stop re-offering auto for it.

### 7.10 Prioritized build order (effort = rough eng-days)

| # | Deliverable | Effort |
|---|---|---|
| 0 | Widen the model, add the pure `SegmentResolver` + guards, refactor L1 to emit candidates, unit-test the resolver | 1.5 to 2 |
| 1 | L2a TheIntroDB client (on-play + cache + negative TTL) + pill rendering. Highest leverage, mainstream TV and movies start working | 2 to 3 |
| 2 | L2b AniSkip client + the IMDB to MAL bridge (arm-server, Fribb fallback). Big anime win | 2 to 3 (+1 if mapping is fiddly) |
| 3 | Skip-pill UX polish, auto-skip arming, cancel countdown, per-episode "don't re-offer" | 2 |
| 4 | L4 black-frame + silence credits detector (screenshot-raw + vImage luma + silencedetect filter-log), boundary snap. Covers movies and sparse-API credits | 4 to 6 |
| 5 | L3 cross-episode audio fingerprint (libchromaprint vDSP + headless-mpv PCM + Swift matcher + prefetch). Long-tail series toward 99% | 8 to 12 |
| 6 | L5 shared/remembered cache + manual set editor | 3 to 5 client + small backend |
| 7 | OCR confirmation pass (optional precision boost on L4) | 2 to 3 |

Steps 1 and 2 alone (about a week) equal Infuse-level coverage. Steps 4 and 5 plus the resolver's agreement boost close the gap to ~99% across the whole catalog.

---

## 8. FEATURE: dynamic focused backdrop on Home / Discover / Library

The user sent a reference (the "HOPPERS" screen) and asked: on Home, Discover, and Library, when you land on a movie or show it should fill the background with all its details. This is the "focused item becomes the page hero" pattern (the same language as our existing movie detail hero).

**Target behavior:** as focus moves across the poster cards in a rail or grid, the page background crossfades to the focused title's backdrop image (full-bleed, right-weighted), and the left side shows an eyebrow (catalog/section name or "FEATURED"), the title in the serif display face, a metadata row (year, runtime, rating, genres), and the synopsis. The poster rails sit at the bottom over a gradient. This is essentially the `DetailView.hero(...)` band, but bound to whatever poster is currently focused, on the browse pages.

**Implementation plan (the upgraded agent should build this):**

1. Extract the hero band. `DetailView.hero(...)` already renders backdrop + gradients + serif title + metadata + synopsis. Pull the visual into a reusable `HeroBackdrop(meta: CoreMetaItem, eyebrow: String)` view in `SharedUI.swift`. It must read theme tokens via `@EnvironmentObject var theme: ThemeManager` (see the re-render lesson in Section 5, a static read will not recolor on theme change).

2. Add a per-page focus model:

```swift
@MainActor final class FocusedItemModel: ObservableObject {
    @Published var item: CoreMetaItem?
    @Published var eyebrow: String = ""
    private var debounce: Task<Void, Never>?
    func focus(_ item: CoreMetaItem, eyebrow: String) {
        debounce?.cancel()
        debounce = Task {
            try? await Task.sleep(for: .milliseconds(150))   // avoid thrash on fast scroll
            guard !Task.isCancelled else { return }
            self.item = item; self.eyebrow = eyebrow
        }
    }
}
```

3. Each page (`HomeView`, `DiscoverView`, `LibraryView`) wraps its content in a `ZStack`: the `HeroBackdrop` bound to `model.item` at the back (`.id(model.item?.id)` + `.transition(.opacity)` + `.animation(.easeOut, value: model.item?.id)` for the crossfade), the existing rails/grid in front over a bottom gradient. Provide one `FocusedItemModel` per page via `@StateObject` and `.environmentObject`.

4. `PosterCard` reports focus. tvOS gives focus state through the focusable modifier; on focus gained, call `model.focus(card.meta, eyebrow: railTitle)`. Do this WITHOUT rebuilding the rail (no `.id()` churn on the rail, that drops focus mid-scroll, same trap as the theme work). The background layer observes the model and updates independently; the rails stay stable.

5. Performance: the 150 ms debounce coalesces fast scrolls into one image load. `AsyncImage` uses URLCache; consider prefetching the backdrop for the focus-adjacent items. Only one backdrop in flight. Animate opacity only (compositor-friendly), never layout.

6. Initial state: seed the model with the first item of the first rail (or a "featured" pick) so the page is never empty. On Library (a grid), the same model + HeroBackdrop apply; the grid sits lower.

Files to touch: `SharedUI.swift` (new `HeroBackdrop` + `FocusedItemModel`, `PosterCard` focus callback), `HomeView.swift`, `DiscoverView.swift`, `LibraryView.swift`. Effort: roughly 2 to 4 days to do all three pages well with the focus and crossfade tuned. Verify on the sim at each page, watching for focus loss on scroll and image-load jank.

This was specified rather than built in this session because the user asked to pause active building after the bug fix and hand off, and because doing it well across three pages with tvOS focus correctness is exactly the kind of architectural work meant for the upgraded agent. It is ready to implement from this spec.

---

## 9. The rest of the v1.0 roadmap

Tracked epics (the user wants a finished v1.0.0):
1. **Player Core (tvOS)** mostly done: episode nav, smart track selection, long-press library actions, auto-recovery, in-player source switcher, skip intro/outro (L1 today, Section 7 is the upgrade). Remaining device-only: HDR/Dolby-Vision and audio passthrough verification, dual subtitle tracks, seek-preview thumbnails.
2. **iOS/iPadOS native shell** on stremio-core. The tvOS app is the reference; the iOS target exists in `project.yml` (`com.stremiox.app`) but is the older web-host approach. CHECKPOINT with the user on architecture before building (the user explicitly wants to be consulted here).
3. **Stream intelligence:** ranking + Watch-Now shipped; remaining is prebuilt debrid handling (Real-Debrid, AllDebrid, Premiumize, TorBox), and DO NOT touch the user's real keys or endpoints during testing.
4. **Personalization:** themes shipped (8 accents + OLED). Profiles is the unified model the user chose ("both"): one Profiles concept where each profile carries local view settings (name, avatar, theme, parental PIN + rating) plus a Stremio-account binding. Account switching needs multiple Keychain authKeys + engine re-init (CoreBridge is currently single-account).
5. **Discovery + sync + offline.**
6. **Cross-device QA + ship 1.0.0.**

Plus the two features in Sections 7 and 8.

---

## 10. Gotchas (learned the hard way)

- **arm64-only simulator builds.** Vendored static libs lack an x86_64 sim slice. Always `ARCHS=arm64`. (Section 2.)
- **SwiftUI does not re-run unchanged child structs.** Custom ButtonStyle content views and separate row structs that read static palette tokens go stale on theme change. Make them observe `ThemeManager`. Do not `.id()`-rebuild to force it, that drops tvOS focus. (Same trap will appear in the dynamic backdrop.)
- **VStack(.leading) does not fill width.** It sizes to the widest child; a ScrollView then centers it. Add `.frame(maxWidth: .infinity, alignment: .leading)`. (This was the 0.1.7.15 bug.)
- **The options panel renders rows eagerly.** A title with 2000+ sources OOM-crashed the Apple TV when a plain VStack built them all; use `LazyVStack`. Same caution anywhere you list streams.
- **tvOS focus isolation for the player** is done by replacing the whole root (PlayerPresenter), not a fullScreenCover over the TabView (the tab bar focus engine pre-empts directional presses).
- **SourceKit false positives** in this environment. Trust `xcodebuild`.
- **The sim contextMenu** cannot be dismissed by a synthetic Escape; terminate + relaunch if stuck.

---

## 11. Links (verified 2026-06-09)

Skip intro/outro:
- TheIntroDB API `https://api.theintrodb.org/v3/media`, spec `https://theintrodb.org/openapi.yaml`, docs `https://theintrodb.org/docs`
- AniSkip `https://api.aniskip.com/v2/skip-times/{malId}/{ep}`, docs `https://api.aniskip.com/api-docs`, source (MIT) `https://github.com/aniskip/aniskip-api`
- IMDB to MAL: arm-server `https://arm.haglund.dev/api/v2/imdb?id=` (`https://github.com/BeeeQueue/arm-server`), Fribb maps `https://github.com/Fribb/anime-lists`, Jikan `https://api.jikan.moe/v4/anime/{malId}/episodes`
- Jellyfin Intro Skipper (port target for L3) `https://github.com/intro-skipper/intro-skipper` and original `https://github.com/ConfusedPolarBear/intro-skipper`
- Chromaprint `https://github.com/acoustid/chromaprint`, algorithm writeup `https://oxygene.sk/2011/01/how-does-chromaprint-work/`
- tvOS CMake toolchain `https://github.com/leetal/ios-cmake`
- comskip (L4 black/silence thresholds reference) `https://github.com/erikkaashoek/Comskip`, tuning `http://www.kaashoek.com/files/tuning.htm`
- Plex credits detection (privacy-safe shared-cache model) `https://support.plex.tv/articles/credits-detection/`
- Infuse skip UX reference `https://firecore.com/blog/infuse-84-extras-intros-and-favorites`
- mpv input/commands (`screenshot-raw`, vf/af, log messages) `https://mpv.io/manual/stable/`
- Apple: `VNRecognizeTextRequest` `https://developer.apple.com/documentation/vision/vnrecognizetextrequest`, `vDSP_rmsqv` `https://developer.apple.com/documentation/accelerate/1450655-vdsp_rmsqv`, `AVAssetReader` `https://developer.apple.com/documentation/avfoundation/avassetreader`

Project:
- Repo `https://github.com/mamaclapper/StremioX`, latest release `https://github.com/mamaclapper/StremioX/releases/tag/v0.1.7.15`
- stremio-core `https://github.com/Stremio/stremio-core`, MPVKit `https://github.com/mpvkit/MPVKit`

---

End of handoff.
