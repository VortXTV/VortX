# Changelog

All notable changes to StremioX, newest first. StremioX is Apple TV first, with an iPhone and iPad build alongside it. Dates are when each version was published.

What is planned next is in [ROADMAP.md](ROADMAP.md). To request a feature or report a bug, start a [GitHub Discussion](https://github.com/mamaclapper/StremioX/discussions) or [open an issue](https://github.com/mamaclapper/StremioX/issues).

## 0.3.0 beta 6 (prerelease) - 2026-06-13

A stability and polish pass over the native iPhone, iPad, and Mac apps, fixing the issues reported on beta 5.

### Fixed
- **The player can no longer trap you.** On a slow or dead source the controls used to auto-hide behind the spinner with no way out, so a stuck load meant force-quitting the app. There is now an always-present close button (and Escape on Mac) until playback starts, the controls stay on screen while loading, and every exit cleanly cancels in-flight work.
- **Torrent movies that hung at "loading" now start.** The player warms up a cold torrent (waiting for peers and the first few megabytes) before handing it to the engine instead of buffering forever, shows the live peer count while it does, and still fails over or errors out if the torrent is genuinely dead. The torrent prime also retries while the streaming server is still starting up.
- **Trailers play again.** The old in-app YouTube embed failed with "Error 153"; the Trailer button now opens the trailer reliably (and a real, non-YouTube trailer stream plays in the built-in player).
- **Settings no longer look unfinished.** The section cards use the app's dark surface and the accent colour instead of the system grey, on iPhone, iPad, and Mac.
- **The wordmark fits its pill.** The "StremioX" title in the Mac window bar no longer spills past its rounded background, and renders once instead of repeating.
- **A signed-out Home is now a real landing screen.** It shows the default Cinemeta catalogs with a full backdrop hero and rails, with the Sign In button still in place, instead of an empty "please sign in" page.
- **QR / link sign-in is safer.** A rejected or expired link code is rejected instead of flipping the app into a broken signed-in state.

### Changed
- **The featured hero is an ambient billboard.** It rotates through top titles on its own, never auto-selects or rings a catalog item, and pauses the moment you interact; tapping a poster just opens it.
- **Player polish toward Apple TV parity:** the Audio panel opens for any audio track (not only when there is more than one), and the screen stays awake during playback.

### Housekeeping
- Local builds now go to a single output location, so development builds stop registering several duplicate app copies with the system.

## 0.3.0 beta (prerelease) - 2026-06-13

The native iPhone, iPad, and Mac apps reach Apple TV parity, and StremioX expands to desktop and Android. iPhone, iPad, and Mac now run the same stremio-core engine and libmpv player as the Apple TV app, with no web host.

### Added
- **Native iPhone, iPad, and Mac apps at Apple TV parity.** The cinematic detail page with the backdrop, the per-add-on source list with the two-level quality picker, full Settings (Profiles, Account, Playback, Streams, Streaming Server, Appearance, Audio and Subtitles, Subtitle Style), and a custom bottom tab bar so iPhone shows every tab instead of collapsing them into "More".
- **An interactive featured hero on Home, Library, and Discover.** It auto-rotates the top titles, shows the logo, rating, year, runtime, genres, and synopsis over the artwork, and plays a muted trailer behind it; tap a poster to feature it, tap again to open. Reduced-motion aware.
- **Trailers on every Apple device.** A Trailer button on the detail page and the muted in-hero autoplay; Apple TV plays trailers through the embedded server, iPhone, iPad, and Mac through an in-app player. (Full build only.)
- **Series done right on iPhone, iPad, and Mac.** Tapping an episode opens its own ranked source list with the quality picker; watched ticks, progress stripes, mark-watched (episode, season, whole series), a Resume S#E# button, and the first-unwatched season selected on open.
- **Torrents on Mac.** The Mac app bundles the streaming server, so it plays torrents, not just debrid and direct links.
- **Continue Watching one-tap resume** straight into the player at your saved position, poster long-press menus, Library type and sort filters, and grouped search with suggestions and a "play a link or magnet" entry.
- **Desktop (Windows, Linux, Mac) and Android in active development.** A native Tauri desktop app on the shared engine (detail page, ranked sources, the quality picker, and its own embedded torrent server) and an Android app scaffold.

### Fixed
- **macOS:** torrent and episode playback (the client now primes the streaming server before requesting a stream and carries add-on proxy headers); the window opens at a proper size and the player fills it in-app instead of a tiny floating panel; the keychain permission prompt is gone (the token is stored in a file on macOS); and the embedded server is shut down on quit instead of leaking.

## 0.2.49 (prerelease) - 2026-06-13

### Fixed
- Torrents play again, and the streaming server stops going offline. Auto-failover was leaving each tried torrent's engine running on the embedded server; a few hops piled up engines until the server's memory ballooned and it stopped responding, which broke torrent and direct-server playback until a relaunch. The player now cleanly shuts down a torrent's engine the moment it switches source, fails over, advances an episode, or closes, so only one runs at a time and the server stays healthy.
- App text size now actually changes, live. Settings, Appearance has a Smaller / Larger stepper (percent shown); it repaints the whole app immediately instead of doing nothing.
- Navigating into a title and back out no longer traps a tab. Returning to Search (or any tab) lands on its own page, not the detail page you opened earlier.
- Fake "4K" files are filtered out. A source that claims 4K (or 1080p) but is far too small to be real video is pushed below every genuine source, so a mislabelled tiny file is never auto-picked. Lower resolutions, where small files are normal, are left alone.

### Added
- Subtitle fine-size control. A Smaller / Bigger stepper in Settings and in the player's subtitle options nudges subtitle size around the chosen preset; the size follows your profile.
- The external-player handoff lists more players (Infuse, VLC, Sen Player, OutPlayer, nPlayer, MX Player), and if none are detected it shows the full list so you can still pick the one you have.
- Header-gated add-on streams route through the embedded streaming server. Some add-ons front CDNs that only answer requests carrying a specific referer or browser identity and reject plain players; those streams now play by going through the same server-side proxy the official app uses. (Full build only; the Lite build keeps the direct path.)
- Language-aware ranking. When a source clearly advertises a foreign audio language and you have a preferred audio language set, it ranks below a same-quality-tier source in your language, so a 1080p English source can be chosen over a 4K source in another language. Cached and your source-type order still come first.

## 0.2.48 - 2026-06-12

The 0.2.45 through 0.2.48 prereleases, consolidated.

### Added
- Auto-failover between sources. When a stream times out, keeps stalling, or dies before starting, the player hops to the next-best source on its own (up to four hops) and keeps your position, instead of dropping you at an error screen. A deliberate source pick or episode change resets the budget.
- Player settings panel. A gear button on the left of the control bar holds the player-wide tools: handoff of the playing stream to an installed external player app, a hardware/software decoder switch for clips whose video misbehaves, the playback info overlay, and the QR link share. The speed button now holds only speed.
- Live streams play properly. Live TV and event streams no longer end a few seconds in at each segment boundary: the player tunes its buffering for live playlists and reconnects over the brief gaps live providers produce. Contributed by [OrigamiSpace](https://github.com/OrigamiSpace).
- Subtitles from add-ons. The player's subtitles panel lists subtitles offered by your installed subtitle add-ons next to the file's embedded tracks; pick one and it loads on the spot, labelled with the add-on it came from.
- Swipe to navigate in the player. The remote's touch surface moves the selection across the controls and panels, exactly like the arrow presses.
- Source type priority in Settings, Streams. A reorderable list puts debrid, Usenet, torrent, or direct streams at the top (default Debrid, Usenet, Torrent, Direct). Your order is the top-level ranking key; cached streams get a strong boost within each type, so cached always beats uncached of the same type without overriding your order.
- Use add-on ranking order toggle. Passes stream order through unchanged, useful if a ranking add-on already sorts sources the way you want.
- Smarter ranking signals. Theatrical rips and fake upscales (CAM, telesync, screener families) sink below every legitimate stream and are labelled in the source list; AV1 video is demoted at 4K where the hardware cannot decode it; 3D releases, broadcast captures, and hardcoded-subtitle rips rank below clean releases; raw torrent health (seeder count) breaks ties within the torrent tier.
- Subtitle font choice. A new Modern style (clean sans with a thin outline and soft shadow) is the default; Classic keeps the previous heavier look. In Settings and in the player's subtitle options.
- App text size setting. UI text sits one step larger by default, and Settings, Appearance has a Smaller / Default / Larger control; takes effect after a relaunch.
- Languages follow the profile. Audio language, subtitle language, and the subtitle style belong to each profile, apply on switch, and sync across devices. Requested by [heinzgruber](https://github.com/heinzgruber).
- Profile edit guardrail. A profile with a PIN asks for that PIN before anyone else can edit it, so a kids profile cannot rename the parent profile or strip its PIN.
- Browse backdrops restored on all hardware. The moving artwork on the Home and catalog pages is no longer suppressed on the Apple TV HD; only the player-side buffers and animation rate remain lighter on that model.

### Fixed
- Add to Library genuinely works now. The save action was silently doing nothing (a wrong key when reading the page state), which is why no profile could save. Both the save and the immediate button update now happen everywhere.
- Stream ranking stops picking failures. Cached debrid streams no longer lose to uncached torrents of the same quality; cache tags are detected across every major add-on's format, including a variation-selector emoji form that previously never matched; uncached results that resolve through a debrid are no longer mistaken for cached ones; and debrid streams with unbracketed tags no longer fall into the direct tier and lose to raw torrents.
- The Watch button tells the truth. An explicit resolution in the name beats marketing tokens, so a 1080p encode of a UHD disc no longer reads or ranks as 4K, and the label carries the full picture, like "Watch in 4K · HDR · Remux", derived from the exact stream it plays.
- Streams that require special request headers now play. Some add-ons front servers that reject requests without a specific referer or browser identity; the player sends the headers the add-on declares, the same way the official clients do. Fixes "This source didn't load" on add-ons whose streams play fine elsewhere.
- Subtitles can no longer silently vanish. Both subtitle styles name fonts bundled with the app; naming a system-only font could fail on some devices and render no subtitles at all.
- The Continue Watching long-press menu is back on secondary profiles, and removing a title there touches only that profile's own history, never the main account's library.
- The detail page stays inside the TV-safe area. On TVs that crop the picture edges (overscan), the top of the detail page could be cut off; content now respects the safe margins while the backdrop artwork still fills the screen.
- Two rare crash paths in the player and engine teardown are hardened: a remote-control event arriving at the exact moment the player closes, and an engine event racing app shutdown, can no longer touch freed memory.

### Performance
- Ranking patterns compile once and each stream's score is computed once and remembered; a long source list re-ranked on every refresh had been doing thousands of pattern compilations on the thread that drives the remote. Detail pages also stop re-ranking on every periodic progress save, and an idle sources panel does no work at all.

### Changed
- The CJK subtitle font is trimmed to its practically-used coverage: 7.6 MB instead of 16 MB, with identical rendering for real-world subtitles. Every build gets smaller, and every build keeps full CJK subtitle support.
- Vendor downloads in the build script are now checksum-pinned, so a tampered or corrupted dependency fails the build instead of shipping.

## 0.2.44 - 2026-06-11

### Fixed
- Torrents no longer take the streaming server down. A torrent streams from the local server, which already buffers the file, so the player's large read-ahead was double-buffering it in memory until the system killed the app. Read-ahead is now sized to the source: small for local torrent playback, full for debrid and direct streams.

### Added
- Automatic performance mode for older Apple TVs. The app detects a memory-constrained Apple TV (the Apple TV HD) and switches to a lighter path on its own so the remote stays responsive: the play head updates less often, the moving backdrop is dropped on browse, and buffers are kept tight. Every Apple TV 4K is unaffected. Settable by hand under Settings, Appearance, Performance.

### Changed
- The Lite build's identifier is now `com.stremiox.tv.lite`, and the CI artifacts follow. Installing 0.2.44 Lite over the previous Lite build creates a fresh app rather than updating in place. The Full build is unaffected.

## 0.2.43 - 2026-06-11

### Added
- Watch Now picks the genuinely best source. Ranking now weighs file size (a bitrate proxy) and lossless audio (Atmos, TrueHD, DTS-HD), so it stops settling for a basic 4K from whichever add-on answered first.
- Smooth, predictable scrubbing. Holding to seek glides across the timeline at an even pace instead of jumping by varying amounts.

### Fixed
- Audio reaches the TV and soundbars over HDMI eARC. The player now claims a movie-playback audio session, which fixes setups with no sound and lets multichannel audio reach a receiver.
- In Settings and the profile editor, pressing Down moves to the next row even when the focused item sits off to one side.

### Changed
- The slimmer Apple TV build is now StremioX Lite (it was StremioX Direct).

## 0.2.41 - 2026-06-11

A large consolidated release.

### Added
- Add to Library and Watch Later from any movie or series page and from Continue Watching.
- A Details action in the Continue Watching long-press menu.
- A stream-link QR code in the player to keep watching on your phone.
- A richer source list with size and quality per source, capped per add-on so one provider cannot bury the rest.
- An HDR and Dolby Vision compatibility toggle for displays that show a remux green or purple.

### Fixed
- Add-on torrents now receive the same TCP and TLS trackers as pasted magnets, so they can find peers where plain UDP discovery is blocked.
- The sources panel no longer freezes the player when opened.
- No more brief home screen flash before the profile picker on launch.
- Marking a whole series unwatched clears every episode tick.

## 0.2.35 - 2026-06-11

### Added
- A Direct Links Only mode and a separate lighter build (later renamed Lite) for debrid and direct links only.
- Per-series quality memory, so a series reopens in the quality you last played.
- HTTPS torrent trackers for peer discovery without UDP.

### Fixed
- Binge auto-next stays on the same release group, so quality never jumps mid-season.

## 0.2.24 to 0.2.27 - 2026-06-11

### Added
- Seamless watching: Continue Watching resumes the exact stream and position, the next episode is preloaded and warmed before the credits, and the embedded server wakes itself after sleep.
- A Relaunch button in Settings, playback speed, a live playback-info overlay, and a richer source picker.
- Paste any link to play it (magnet, direct URL, resolved debrid or usenet).

### Changed
- Profile PINs are stored as a salted hash and never shown.
- The update checker rechecks on a sensible schedule and surfaces new releases in Settings.

## 0.2.0 to 0.2.23 - 2026-06-09 to 2026-06-10

### Added
- The native Apple TV client on the engine: Home, Discover, Library, Detail, the full per-add-on source list, Search, and add-on management.
- Skip intro and outro from crowd-sourced timestamps merged with the file's chapters.
- The cinematic full-bleed redesign and the living backdrop on Home, Discover, and Library.
- The two-level quality picker and ranked Watch Now with instant preloaded auto-play next.
- Profiles: a "Who's watching?" picker, per-profile themes and history, an optional PIN, and per-profile accounts.
- Real HDR and Dolby Vision output, and the embedded streaming server for torrents.
- Brand identity, an animated splash, and QR sign-in.

### Fixed
- A device crash while a popular title's large source list loaded.
- A crash a fixed number of seconds into heavy 4K playback.

## 0.1.7.5 to 0.1.7.15 - 2026-06-08 to 2026-06-09

The player foundations.

### Added
- Smart audio and subtitle selection, language-grouped track pickers, subtitle styling and sync, and bundled fonts for every script.
- Long-press library menus, in-player source switching, and player auto-recovery on a stall.
- Eight accent themes plus a true-black OLED mode.
- Skip intro and outro from chapter markers, a seekable scrubber with hold-to-seek, and a screensaver hold-off during playback.
