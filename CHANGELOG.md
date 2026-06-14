# Changelog

All notable changes to StremioX, newest first. StremioX is Apple TV first, with an iPhone and iPad build alongside it. Dates are when each version was published.

What is planned next is in [ROADMAP.md](ROADMAP.md). To request a feature or report a bug, start a [GitHub Discussion](https://github.com/mamaclapper/StremioX/discussions) or [open an issue](https://github.com/mamaclapper/StremioX/issues).

## 0.3.0 - 2026-06-14

StremioX is now a native app on iPhone, iPad, and Mac alongside Apple TV, all on the same stremio-core engine and libmpv player. This milestone retires the old iPhone and iPad web host. The beta entries below list the iPhone polish that led here; the headline additions and fixes are collected here.

### Added
- **In-player next and previous episode, an episode list, and end-of-episode auto-advance** on iPhone, iPad, and Mac (Apple TV already had it). Episodes switch in place, with no reload flash, and carry the resume position and quality forward.
- **Sleep timer.** Pause after 15 to 90 minutes, or stop at the end of the current episode.
- **A native macOS menu bar.** A Go menu with keyboard shortcuts (Command 1 to 5 for the tabs, Command F for Search), Settings on Command comma, and Check for Updates.
- **A translucent, frosted top bar on iPhone browse screens**, so the hero and content read as scrolling under the chrome.
- **A streaming-server log in Settings** (iPhone and iPad), so when the embedded server stops you can see and share why.
- **The launch animation now plays on iPhone, iPad, and Mac**, matching Apple TV.

### Fixed
- **The streaming server is far less likely to be killed mid-playback on iPhone.** Its torrent cache is now scaled to the device instead of a fixed 512 MB; on iPhone the server shares the app's memory, so an oversized cache plus 4K video could push the app past the system limit and force a restart.
- **Finishing one episode of a series no longer clears the whole series from Continue Watching.** Only finishing a movie or the last episode clears it.
- **Series and shows find their sources, not just movies**, and what you watch lands in Continue Watching and resumes where you stopped.
- **Source rows no longer show the resolution twice** and show a fuller release title.
- The iPhone detail and episode pages no longer clip at the screen edges; video fills the iPhone screen correctly; ratings and backdrops appear for TMDB-catalog titles; the featured hero shows one clean backdrop; the accent theme persists across relaunches; and upscaled video is sharp again (all detailed in the betas below).

### Notes
- Up next: next-episode pre-search and sticky release-group auto-play, an animated hero background, an HTTP/HLS quality selector, wider iPad and Mac layouts, a fuller accessibility pass, and more of the quality audit.

## 0.3.0 beta 15 (prerelease) - 2026-06-14

More iPhone polish, all verified on an iOS build.

### Added
- **The launch animation now plays on iPhone, iPad, and Mac**, matching Apple TV, over the engine and streaming-server boot.
- **Continue Watching long-press now offers "Details".** A Continue Watching card plays on tap, so the menu now also opens the detail page where you can pick a different episode or source, alongside "Remove from Continue Watching".
- **A server log in Settings.** Settings > Streaming Server > Server log shows the embedded server's status and recent output (with copy), so when the server stops on a device you can see and share the exact reason.

### Fixed
- **The video fills the screen on iPhone.** A 16:9 stream left thick black bars on the sides in landscape; the iPhone player now fills the screen. iPad, Mac, and Apple TV keep the whole frame (letterboxed), and the player's Aspect control still switches between them.
- **Hero buttons stopped squishing into vertical slivers.** After the iPhone width fix, the Trailer / In Library / Sources chips on a detail page could compress until their labels stacked vertically; they now keep their shape and wrap to a new line when space is tight.

### Notes
- Next: pinning down the streaming server stopping on some devices (the new server log will show why), in-player next/previous episode, an HTTP/HLS quality selector, and the rest of the 100+ item audit.

## 0.3.0 beta 14 (prerelease) - 2026-06-14

The iPhone pass. Every fix below was reproduced and verified on an iOS build, not just the Mac.

### Fixed
- **Series and shows find their sources now, not just movies.** Movies resolved sources but episodes came up empty, because opening an episode pushed a new screen and the detail page behind it tore down the engine's loaded title a fraction of a second later, wiping the streams the episode page had just fetched. The detail page no longer does that, so an episode loads its full ranked source list (one test episode went from "no sources" to 65).
- **The detail and episode pages no longer clip off the screen edges on iPhone.** In portrait, the title, rating line, buttons, and synopsis were cut off on both sides. The page is now hard-pinned to the screen width and the facts line truncates cleanly, so nothing runs off the edge. (Landscape, iPad, and Mac were already fine.)
- **What you watch lands in Continue Watching, and remembers where you stopped.** The iPhone, iPad, and Mac player never told the engine your playback position, so nothing showed up in Continue Watching and resume did nothing. It now reports progress to the engine the same way Apple TV does.
- **Movie pages no longer show the Watch / Quality / Sources controls twice.** The hero already has them, so the source list below now shows just the grouped per-add-on sources.
- **Ratings, logos, and backdrops now appear for TMDB-catalog titles.** On Home, Discover, and Library, titles from a TMDB catalog (including everything in Continue Watching) showed no rating and no backdrop, because the hero looked for that art before your add-ons had finished loading and never tried again. It now refreshes once add-ons are ready, matching Apple TV.
- **The featured hero shows one clean backdrop.** It used to layer a sharp still over a blurred copy of the same image, which read as two overlapping pictures. It is now a single full-bleed backdrop.
- **Your theme color sticks.** Changing the accent color and reopening the app reset it to the default; the chosen color now persists across relaunches.
- **Sharper video.** The player had been forcing a low-quality "fast" scaling profile that softened upscaled video; that override is gone, restoring the crisp image from the 0.1.6 build.

### Notes
- Still sequenced for the next build: surfacing the embedded server's log in Settings to pin down the streaming server dying on some devices, in-player next/previous episode, an HTTP/HLS quality selector, a Continue Watching "Details" option, a startup animation on iPhone/iPad/Mac to match Apple TV, and the rest of the 100+ item audit (docs/REVIEW-WORKLIST.md).

## 0.3.0 beta 13 (prerelease) - 2026-06-14

The build that fixes "no sources", plus the macOS player and the featured hero.

### Fixed
- **Titles find their sources again, on iPhone, iPad, and Mac.** This was the big one: opening an episode (or a movie) often showed "no sources" even with stream add-ons installed and working, because the app was never actually asking the add-ons. When a series was already loaded, tapping an episode skipped the stream request entirely, and movies leaned on a fragile auto-guess. Both now request the right streams every time, so a title that has sources shows them. Game of Thrones S1E1 went from nothing to over 1,800 sources across every installed add-on.
- **The macOS player works.** It crashed the instant you pressed Play (a missing internal dependency once the player was lifted to fill the window), and the "play a link" dialog drew on top of it. The player now opens full-window inside the app, plays, and closes cleanly without resizing the window, with the same controls and engine as Apple TV.
- **The featured hero shows the whole backdrop.** On a wide Mac window the hero art was either zoomed into a sliver or boxed in by bars. It now shows the full still over a soft blurred fill, so nothing important is cut off, and the detail page got a taller, less-cropped band.
- **Shows display their logo as the title.** Where logo artwork exists, the hero uses the show's logo (Game of Thrones and friends) instead of plain text, and it appears right away.
- **"No sources" explains itself.** When nothing loads, the screen now says whether each add-on returned nothing, errored, or whether no stream add-on responded at all, and what to check, instead of a generic dead end.

### Notes
- Still sequenced for upcoming builds: the hero reading ratings and logos for every title from the engine, a translucent top bar so the backdrop flows under it, in-player next/previous episode, an HTTP/HLS quality selector, and the rest of the 100+ item audit (docs/REVIEW-WORKLIST.md).

## 0.3.0 beta 12 (prerelease) - 2026-06-14

The real fix for the streaming server dying, plus Continue Watching metadata.

### Fixed
- **The streaming server no longer dies seconds after launch (issue #56).** This was a crash, not a memory problem: it happened on an 8 GB iPhone with the torrent cache barely touched. Our embedded server starts a small reverse proxy on port 11471 so the older web UI can load over a loopback origin, and that proxy's listen() raised an unhandled EADDRINUSE error event when a previous instance still held the port (a fast relaunch, or force quit then reopen), which crashed the whole node runtime and took the streaming server down with it. The native iPhone, iPad, and Apple TV apps have no web UI, so they no longer start that proxy at all, and it now handles the error where it does run. The server otherwise runs the same configuration Stremio runs (an earlier attempt to disable its HTTPS and transcode subsystems was the wrong lead and has been reverted).
- **Continue Watching titles now show their details in the featured hero.** A title carried in from Continue Watching used to appear in the rotating hero with just its name and a Play button, no rating, year, genres, or synopsis. The hero now fetches that metadata up front, so it is ready before the title rotates into view.

## 0.3.0 beta 10 (prerelease) - 2026-06-14

Working down the full audit, plus a dedicated macOS pass.

### Fixed
- **Finished titles now leave Continue Watching.** The player never told the engine a title was watched, so movies and episodes lingered in Continue Watching at their end position forever. It now marks a title watched at ~90% and, when a movie or the last episode finishes, removes it from the rail, matching the Apple TV app.
- **On macOS, closing the window quits the app.** Before, the red close button / Cmd-W left the app running headless with the streaming server still holding its port and no way to get the window back. Closing the last window now quits cleanly and shuts the server down.
- **Return submits on Mac.** Pressing Return in the password field or the streaming-server URL field now submits, instead of doing nothing.
- **Destructive red no longer reads as orange.** The Remove / Log Out / error red was warm enough to look like a leftover orange accent next to a cool theme; it is now a cooler red.
- **VoiceOver reads poster cards.** Each poster announces its title, that it opens details, and its watch progress.

### Notes
- Still sequenced for upcoming builds (each is a focused, separately-tested change): the macOS player presentation, in-player next/previous episode, an iPad/Mac wide-screen layout, engine thread-safety hardening, and the rest of the accessibility pass. The full list lives in docs/REVIEW-WORKLIST.md.

## 0.3.0 beta 9 (prerelease) - 2026-06-13

The one from the full audit. A 7-area review (layout, code, player, theming, server, parity, accessibility) found 97 issues; this build lands the systemic root-cause fixes and every crash.

### Fixed
- **The viewport clipping is fixed at the source, on every screen.** beta8 fixed Home/Discover/Library; the same root cause (a plain VStack inside a scroll view stretching to its widest row) still clipped the Profile editor, the "Who's watching?" picker, Search, and Sign In. All now pin to the screen width. The Add Profile screen, which rendered cut off on both edges, is verified correct on device.
- **The accent now fully recolors.** Button labels and on-accent text kept a warm/orange tint on top of any accent (the "still looks orange after switching to pink"). The on-accent ink is now derived from the accent itself, so a pink or blue theme is pink or blue throughout. Ember keeps its signature warm ink.
- **Two crashes removed.** Opening the Subtitles/Audio panel on a dual-track title, and any networking path that built a URL from a runtime value, are now guarded instead of force-unwrapped.
- **Sign-in is hardened further.** The signed-in flag is only written when it actually changes, closing the last path that could re-enter an observer (the class of bug behind the beta7 sign-in freeze).

### Notes
- This is the first of several builds working through the full audit. Still queued: the macOS player presentation, in-player next/previous episode, marking titles watched so they leave Continue Watching, an iPad/Mac layout that uses the wider screen, and a full accessibility pass.

## 0.3.0 beta 8 (prerelease) - 2026-06-13

The one that fixes the phone. beta 7's real-device testing surfaced an app-freezing sign-in bug and a cluster of iPhone-only layout breakage — this is the fix pass for all of it.

### Fixed
- **QR / link sign-in no longer freezes and crashes the app.** On iPhone and iPad, finishing a QR sign-in could hang the whole app (no buttons, the phone itself lagging) and then crash. Root cause: the sign-in handler wrote a value that re-triggered itself in an unbounded loop on the main thread. It now runs exactly once. (macOS was unaffected — it has no main-thread watchdog — which is why it only showed on the phone.)
- **Discover and Library no longer render shifted off the left edge.** On iPhone the whole screen (hero, filter chips, poster grid) could be pushed left and clipped on both edges, intermittently. The content column now pins to the screen width instead of stretching to its widest row. Verified on device.
- **The streaming server stops crashing seconds after launch on iPhone.** The embedded server was starting subsystems the phone build never needs (a second HTTPS server and its certificate stack), inflating its memory footprint until iOS killed it. The iPhone/iPad build now runs the same lean configuration the official Stremio iOS app uses.
- **The Add-ons screen and Streaming Server screen fit the phone.** They were using the 10-foot Apple TV screen inset and a fixed 1000pt-wide field, so content spilled off the edge and the "Remove" button was squeezed to one letter per line. They now use a phone-appropriate inset, the field fits, and the button keeps its width.
- **The featured hero no longer shows a flat black band** while its backdrop loads or if that image fails — it falls back to the poster art underneath.

### Notes
- "None of the add-ons returned a playable source": this means no streaming/debrid add-on is installed — the metadata add-ons (Debridio TMDB, AIOMetamax, etc.) don't provide playable streams. Install a stream provider (Torrentio, Comet, MediaFusion, or an AIOStreams config) from the Stremio web/mobile app and it syncs down.

## 0.3.0 beta 7 (prerelease) - 2026-06-13

The one that actually plays. beta 6 shipped with a macOS player deadlock — this fixes it.

### Fixed
- **The macOS player no longer freezes the whole app.** Starting a video could hang the entire app (spinning beachball, even Quit dead) and require a force-quit. Root cause: mpv's video-output thread set the layer's HDR/EDR flag via a blocking hop to the main thread *while holding the Metal layer lock*, exactly as the main thread tried to take that same lock to size the drawable — a hard deadlock at the first frame. The EDR flag now updates without blocking the render thread, so playback starts cleanly. Verified end-to-end (open → play → controls → close) with a real video stream.

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
