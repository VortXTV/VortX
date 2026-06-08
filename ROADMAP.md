# Roadmap

A community build, no fixed schedule. This is the plan in priority order. The full feature checklist is in
[docs/FEATURE-PARITY.md](docs/FEATURE-PARITY.md); the iOS plan in [docs/REBASE-iOS.md](docs/REBASE-iOS.md).

## In progress

### Phase 1: player quality
Bring the player to the top of its class. Done so far: a redesigned cinematic player UI, a live metadata
line (resolution, HDR, audio), reliable focus controls, aggressive caching, and broad subtitle script
coverage. Building next:

- HDR and Dolby Vision passthrough, plus HDR to SDR tonemapping with a target-nits setting.
- Full subtitle styling (font, outline, box, margin, alignment), dual subtitle tracks, per-title delay.
- Smart track selection: auto audio and subtitle by language, forced-subtitle override, rejection lists.
- Skip intro and outro with an on-screen button.
- Anime upscaling shaders with quality presets and content auto-detection.
- A smooth-motion (judder reduction) toggle.

### Native iPhone and iPad client
Rebuild iOS as a native client on the engine, like the Apple TV app, so it no longer depends on a hosted
web UI. Done: the engine compiles for iOS. Next: share the engine and design layers into the iOS target,
build the touch screens, then a native touch player. Retire the web host at parity.

## Next

### Stream selection and sources
- Add debrid API keys directly in the app, across multiple services, with a uniform cache check.
- Smart stream ranking that filters fakes and mislabeled sources and floats the best cached, high-quality
  source to the top, with a safety filter.
- Direct torrent streaming without a debrid account.

### Our own streaming server
Replace the bundled server with our own, unlocking Usenet, live TV, full background caching, and
transcoding. Shipped behind an opt-in branch so current users are undisturbed.

## Planned

### Metadata and tracking
Rich metadata and ratings, watch-history tracking and scrobbling with automatic episode tracking, a hero
banner with daily recommendations and Discover rails, add/remove Library on the detail page, and a
last-used source per title.

### Look and feel (customizable)
A customizable theme (accent color and full color theming, multiple presets and layouts, custom fonts), a
customizable player layout, profiles with parental PIN, localization, and remote remapping.

### Casting
AirPlay first, then Chromecast, DLNA, and Roku.

### Live TV
Playlist and provider sources, a channel browser with logos and favorites, an EPG guide grid, catchup,
and recording.

### Social and advanced
Watch together (synced playback, chat, on-screen cursors, draw-over-video), multiview, and webhooks.

### More platforms
macOS first, since it shares the SwiftUI and engine code, then Windows and Linux.

### Apple TV extras and infrastructure
Top Shelf Continue Watching (subject to sideloading constraints), an external-player handoff, interface
scaling, and an acknowledgements screen. Bridge tests and a CI build (which unblocks once our own server
lands; engine code scanning is already wired up).

## Done

### Apple TV (native on the engine)
- Home (real Continue Watching and every catalog), Discover, Library, Detail, the full source list, Search,
  and Add-ons, all driven by the engine.
- Watched markers by episode, season, or whole series; engine-sourced resume; live progress.
- A cinematic UI redesign on a shared design system, plus a redesigned player.
- Reliability fixes: sign-in seeds the engine; Discover and Library load; full-screen player; reliable
  detail loading; Back returns to the tab; first rows load their posters; aggressive caching; broad
  subtitle script coverage.

### Cross-platform
- Sign-in token in the Keychain with a fallback; the engine builds for both tvOS and iOS.

### Project
- Unsigned, sideloaded builds with checksums; a security policy, private vulnerability reporting,
  Dependabot, secret scanning with push protection, and engine code scanning.

### iPhone and iPad (interim)
- Hosts a web UI with a native libmpv player and an external-player handoff, being replaced by the native
  client above.
