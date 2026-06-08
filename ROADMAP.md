# Roadmap

A community build, no fixed schedule. This is the real plan: what is shipping, what is being built now,
and what is next, in rough priority order. Feature-gap detail lives in
[docs/FEATURE-PARITY.md](docs/FEATURE-PARITY.md); the iOS plan in [docs/REBASE-iOS.md](docs/REBASE-iOS.md).

## In progress

### Native iOS / iPadOS client on stremio-core
The iPhone and iPad app currently hosts Stremio's live web UI in a WKWebView, which broke when Stremio
moved the web to v6. The fix is to rebuild iOS the way the Apple TV app already works: native SwiftUI on
stremio-core, reusing the same engine bridge and design system, with no dependency on Stremio's live web.

- Done: stremio-core now compiles for iOS; `StremioXCore.xcframework` ships all four slices (ios-arm64,
  ios-arm64-simulator, tvos-arm64, tvos-arm64-simulator).
- Next: share the engine layer (`CoreBridge`, `CoreModels`, `Theme`, `PlaybackMeta`) into the iOS target,
  then build the touch-adapted screens (Home, Detail, Streams, Discover, Library, Search, Settings) for
  iPhone and iPad, then a native touch player on the libmpv core. Retire the web host at parity.

## Next: a StremioX streaming server

Replace Stremio's proprietary `server.js` with our own streaming server, better than both Stremio's and
the open-source drop-ins. This removes the one proprietary piece, unblocks end-to-end CI, and is where the
features below actually live. Shipped behind a branch so people who prefer stremio-core/server stay there
and others opt in.

- **Usenet support.** Native Usenet streaming (the maintainer uses it).
- **Live TV / IPTV.** Channel playback with an EPG (program guide).
- **Stream proxying** and a configurable cache.

## Planned: player and library (engine already supports these)

- **Add to / remove from Library on the detail page.** Today titles only enter the library via account
  sync; the engine actions exist, we just need to surface them.
- **Last-used stream per title**, for one-click replay instead of re-picking from the source list.
- **Infinite scroll on Home**, lazy-loading more catalogs (replaces the old "scroll forever" feel).
- **Progressive seeking + a seek-step setting** (today it is fixed plus/minus 10s), and an "ends at" clock
  on the player.
- **Automatic subtitle selection** by preferred language, plus a hide-other-languages filter.
- **Addon subtitles** (OpenSubtitles and similar) with download and copy.
- **Trakt integration**: import history and scrobble watch events.
- **HDR / Dolby Vision badge** on stream rows (parsed, not just raw addon text).

## Planned: Apple TV and polish

- **Top Shelf**: Continue Watching on the tvOS home screen. Exploratory, a Top Shelf extension needs a
  shared app group that may not survive the re-signing sideloading relies on.
- **External-player handoff to Infuse** on tvOS (iOS already has it).
- **Interface scaling**, a bundled licenses/acknowledgements screen, and localization.

## Planned: tests and CI

- Characterization tests around the Swift-to-Rust bridge.
- A GitHub Action that builds the IPAs on each release tag. Blocked today because the proprietary
  `server.js` cannot live in CI; it unblocks once the StremioX server above lands. (CodeQL scanning of the
  Rust engine is already wired up.)

## Done

### Apple TV (native, on stremio-core)
- Full rebase onto stremio-core: Home (real Continue Watching + every addon catalog), Discover
  (type / catalog / genre filters), Library (type / sort filters), Detail (cinematic hero, season picker,
  episodes), the complete per-addon stream list, Search, and Add-ons (with remove).
- Watched and unwatched markers, by episode, by season, or whole series.
- Live playback progress through the engine, engine-sourced resume, and a watched hook near the end.
- A full UI redesign on a shared design system (warm editorial-cinema direction, crafted remote focus,
  poster-forward layout), in `Theme.swift` and DESIGN.md, ready for iOS to inherit.
- Reliability fixes: sign-in reliably seeds the engine; Discover and Library load; the player is
  full-screen; detail pages open reliably; Back returns to the tab instead of exiting.

### Cross-platform
- Sign-in token stored in the Keychain (with a one-time migration and a UserDefaults fallback where the
  Keychain is unavailable). Sign-in seeds the engine immediately; sign-out clears it.
- stremio-core engine built for both tvOS and iOS.

### Project
- Shipped as unsigned IPAs with SHA-256 checksums on each release.
- Security: SECURITY.md policy, private vulnerability reporting, Dependabot alerts + security updates +
  version config, secret scanning with push protection, and CodeQL scanning of the Rust engine.
- README corrected to the accurate Stremio history, with a security section and honest AI-authorship note.

### iPhone / iPad (current, interim)
- Hosts Stremio's live web UI in a WKWebView with a native libmpv player and an Infuse / VLC handoff.
  Being replaced by the native client above.
