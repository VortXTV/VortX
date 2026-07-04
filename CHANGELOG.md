# Changelog

All notable changes to VortX, newest first. VortX is Apple TV first, with an iPhone and iPad build alongside it. Dates are when each version was published.

What is planned next is in [ROADMAP.md](ROADMAP.md). To request a feature or report a bug, start a [GitHub Discussion](https://github.com/VortXTV/VortX/discussions) or [open an issue](https://github.com/VortXTV/VortX/issues).

## 0.3.10 - build 151

A hotfix over 0.3.9 that ends the "tried several sources, none worked" flash on a source that was actually still loading, restores instant playback, makes trailers actually play (video and audio, straight from your device), plays dual-layer Dolby Vision as true DV, clears finished titles out of Continue Watching, gives the Streaming Services row full brand-colored tiles, sharpens the community source list, and hardens account sync. In-place update, nothing resets.

### Fixed

- **"Tried several sources, none worked" no longer flashes over a source that is still loading.** A start timer meant to give up on a truly dead source was firing the instant it was replaced instead of after its full wait, so opening a title could race through every source in a fraction of a second and show "tried several sources" even though the source you picked was seconds from playing (and it then played anyway). The timer now only acts when it genuinely times out, so a source that needs a few seconds to warm up is given those seconds and plays cleanly, with no false failure. iPhone, iPad, Mac, and Apple TV.
- **Playback starts instantly again.** A change in a late 0.3.8 beta began resolving every source through your debrid account before handing it to the player, so a tap could load for up to half a minute and show "source failed" before it played (and it hit TorBox and Real-Debrid alike, even a source you picked yourself). Playback now starts right away: a confirmed-cached pick still resolves to the fast direct link, but any other pick plays its own link immediately instead of waiting out the resolve, and a not-ready TorBox source now gives up in a couple of seconds like Real-Debrid already did. Separately, when a source is routed to Apple's player and mounts but never produces a frame, it now falls back to the built-in player on the same source in about five seconds instead of stalling and hopping to a lower-quality one; HLS and genuinely-playing Dolby Vision streams are never demoted, so your quality selector and true DV are preserved. Mirrored on iPhone, iPad, Mac, and Apple TV.
- **Trailers play, from your own device.** A trailer now resolves and plays straight from your device through YouTube at up to 1080p, playing the separate video and audio streams together (modern YouTube no longer serves a trailer as one combined file, which is why many used to show "this source didn't load"). A trailer that genuinely cannot be found shows "Trailer unavailable" instead of quietly starting the movie. The muted ambient trailer behind the hero uses the same path. Movies and series, on iPhone, iPad, Mac, and Apple TV.
- **Streaming Services logos are legible for every provider.** Each brand logo now fills its pill instead of sitting as a tiny mark on a big plate, so marks like Apple TV+ and Paramount+ read clearly. A provider with no available logo shows its full name (for example "Hulu", "Peacock", or "BBC iPlayer"), wrapping to two lines, and never a single-letter initial or a blank box. On iPhone, iPad, Mac, and Apple TV.
- **Landscape catalog art loads reliably on Apple TV.** The wide 16:9 catalog cards and the living hero backdrop now use the same dedicated image cache and off-main decoding as the portrait posters, so they no longer come back blank or stutter.
- **Poster Style works on Apple TV.** The poster width, corner radius, and hide-labels controls added on iPhone, iPad, and Mac now appear on Apple TV and actually change the grid, and the portrait/landscape choice no longer overlaps cards in the category grid.
- **Hub section headers are translated.** "Streaming Services", "Browse by Genre", and the related Discover headers now show in your language instead of English.
- **Continue Watching clears finished titles.** A movie you watched to the end, marked as watched, or finished on another device no longer lingers in the row. A series you are partway through still shows so you can pick up the next episode.
- **Singularity sources show up.** The toggle used to check the wrong sign-in, so community-corroborated sources never loaded. Sign in to VortX, turn on Singularity sources in Settings, and they now appear in the source list alongside your own, on iPhone, iPad, Mac, and Apple TV.
- **Account sync no longer drops a simultaneous change.** When two devices saved at the same moment one change could be silently lost; the app now detects the conflict, re-merges onto the latest version, and retries. Your add-on order also stays consistent across your devices and the web dashboard.
- **Posters load reliably and the app is snappier on open.** Catalog and hero artwork used to be fetched through a tiny shared image cache with no limit on how many loaded at once, so on a full Home or Discover page many posters came back blank and decoding them on the main thread made the whole app lag on open (on iPhone, iPad, and the M-series Mac). Artwork now uses a dedicated large on-disk image cache, loads a handful at a time in the background, and decodes off the main thread, so posters stay filled and scrolling stays smooth. A blank card also retries once instead of latching the film placeholder. Toggling the Collections hub on Home or Discover on or off no longer starves the rows below it into losing their art. Home-screen catalog rows are also now rebuilt once per burst of engine updates instead of on every update, cutting main-thread work on launch.
- **The source you pick is the source that plays, including on resume.** The exact source you choose is now played by re-resolving that same debrid file directly, not by re-running the cross-source auto-pick, so picking up a title from Continue Watching replays the source you were watching instead of hunting for a new one and flashing a "tried several sources / this source did not load" cascade on a source that plays fine. When a pick is still starting, the player retries that exact source in place with extra first-buffer grace (and extends further while bytes are still arriving), so a specific 4K, HDR, or 1080p source no longer silently drops to a cached 480p or gets given up on mid-fill, and only surfaces a clear "choose another source" message if it genuinely fails. Where an automatic hop off a truly dead source is still needed it is capped so it never lands more than one resolution tier below a cached higher-quality option, preferring cached sources first, and the "tried several sources" overlay no longer flashes while a hop or a resolve is still in flight. Mirrored on iPhone, iPad, Mac, and Apple TV.
- **Scrub-preview thumbnails build and share from Mac and iPhone playback again, including 4K, HDR, and Dolby Vision.** On the built-in libmpv engine (the default for most 4K/HDR/DV playback on Mac and iPhone) the frame-capture callback ran on a background thread while the code that collects and shares those frames runs on the main thread, so a device could generate previews locally yet never contribute them to the shared pool. The capture now always hands off on the main thread on every engine and platform. A separate near-black-frame filter that could misread a wide-gamut or 10-bit frame and silently discard every capture is now format-aware, and both it and the hand-off are traceable in the logs, so timeline previews come together from all your devices.

### Changed

- **Streaming Services tiles match the Apple TV app.** Each tile is now filled edge to edge with the service's own brand color, with its bundled logo centered on top, instead of the logo sitting on a uniform near-white card. Netflix is a white tile with its red wordmark, Disney+, Prime Video, and Paramount+ are blue, Apple TV+, Starz, MUBI, and AMC+ are black, Hulu is black with its green logo, Crunchyroll is orange, Max is blue-into-purple, and more; the logo is rendered white on the dark and saturated tiles and kept its own color on the light ones. A service without a curated brand color keeps its logo or full name on a neutral tile. On iPhone, iPad, Mac, and Apple TV.
- **Trailer clips use no server storage.** Trailers and the ambient hero clip resolve on demand from your own device, so nothing is pre-cut or stored on VortX's side.

## 0.3.9 - build 150

Build 149 adds offline HLS downloads on iPhone and iPad (adaptive .m3u8 sources now download properly as a system-managed bundle and play back offline, instead of failing), a fleet of reliability fixes from an adversarial code-review sweep of the 147 changes (a catalog category that could get stuck on an endless spinner when you switched between pills; a hub tile that could open twice on a slow connection; a hub detail whose action buttons could disagree with its body), and a hardened Discover edge cache that no longer freezes a missing rating from a transient upstream hiccup and no longer stampedes the shared key when a popular row goes stale.


This build is finished and in final testing across every device; the release is cut once that pass is clean. A big, cross-cutting release: your language everywhere (over 100 languages, and titles, posters, and logos localized across every catalog), a Discover you can shape to your region and taste, a cleaner and more cinematic look on iPhone, iPad, and Mac, community subtitles with an "also available in" language row, Dolby Vision from MKV files, TorBox usenet and search, install add-ons by scanning a QR code, and a wave of player and detail-page polish. In-place update, nothing resets.

### Added

- **Over 100 languages.** The interface now speaks more than 100 languages (up from 64), with an in-app language picker and right-to-left layout for Arabic, Hebrew, Persian, and Urdu. Choose a specific language in Settings or follow your device automatically.
- **Titles, posters, and logos in your language.** Metadata now localizes across every catalog: a title's name, poster, and logo show in your language when the source has them, drawn from VortX's own localized-metadata service so it works without your own key.
- **A Discover you can shape.** New personalization controls put your region and taste first: order catalogs by your region, turn individual Discover categories on or off, and localize the rows to your language. Set it all in Settings.
- **Community subtitles, fast and in sync.** Subtitles now load quickly from a shared community pool and stay in sync, and every title shows an "also available in" row of the other languages a subtitle exists in, so you can tell at a glance what a title offers.
- **A working subtitle-sync control.** Nudge subtitles earlier or later in the player when a track runs ahead of or behind the audio, and the offset sticks for that title.
- **Dolby Vision from MKV files, including dual-layer Profile 7.** A Dolby Vision MKV now plays with true DV passthrough on a DV-capable display, alongside the MP4, MOV, and HLS containers that already did. Dual-layer Profile 7 files (the format most 4K Blu-ray rips use) are converted to Profile 8.1 on the fly so they play as true Dolby Vision instead of tone-mapping to HDR10. Turn it on in Settings, Playback; it still falls back to HDR10 automatically when a file genuinely cannot take that path.
- **TorBox usenet and search.** TorBox now resolves usenet (NZB) sources and runs its built-in search, so a TorBox key surfaces more cached and searchable results, not just torrents.
- **A debrid cache indicator.** A source that is already cached on your debrid account shows a clear "cached" marker in the list and ranks higher, so instant-playing sources are obvious at a glance.
- **Install add-ons by QR code.** Scan a QR code with your phone to install an add-on to your account, no typing on the TV. It syncs to your other devices like any other add-on.
- **Pick a trailer's language.** Choose which language a title's trailer prefers, so the in-hero and detail-page trailer matches how you watch.
- **Resume timestamps.** Continue Watching and the detail page now show where you left off as a timestamp, so you can see how far in you are before you resume.
- **Poster Style settings, with a live preview.** Settings -> Appearance -> Poster Style lets you set poster card width (Compact through Large, Balanced is the default), corner radius (Sharp through Pill, Rounded is the default), landscape 16:9 art, and hiding the title labels, with a sample poster that updates as you change each option. Defaults match today's look, so nothing changes unless you opt in. iPhone, iPad, and Mac.
- **Cast & Crew is now a tap-to-expand section on the title page.** It stays collapsed by default so the page reads cleaner, and expands smoothly to show the cast, director, and writer when you tap it. iPhone, iPad, and Mac.
- **Hide poster labels from Settings -> Appearance.** The toggle used to live only inside Poster Style; it is now surfaced in the main Appearance section too, and it applies consistently across every poster row (Discover, Home, Continue Watching, and More Like This). iPhone, iPad, and Mac.
- **Combine Discover and Search into one tab.** A new Settings -> Appearance toggle (off by default) folds Search into Discover, with a search field above the browse, so the tab bar is less crowded on phones. Turn it off any time to get the separate Search tab back. iPhone, iPad, and Mac.
- **A buffered-ahead indicator on the player scrubber.** A light grey track now sits behind the playhead showing how far playback has loaded ahead, just like YouTube. It works on every device and both playback engines, and stays out of the way of the seek-bar styles, chapter ticks, and skip markers. Apple TV, iPhone, iPad, and Mac.

### Changed

- **A cleaner, more cinematic look across the app.** Title pages now lead with full-bleed artwork that fades smoothly into the background, a circular back and more button over the art, a big high-contrast Play button, and a more spacious layout. The home billboard gets a rounded "View Details" pill, pager dots, and the same smooth artwork fade, and Continue Watching cards get a tidier progress bar. iPhone, iPad, and Mac.
- **Mac now uses the full width of the window.** A larger hero, a roomier reading column for the synopsis and cast, and the wordmark tucked clear of the window controls, so the Mac app reads as a desktop layout rather than a stretched phone.
- **Tap the active tab again to jump back to the top.** On Apple TV and on iPhone, iPad, and Mac, selecting the tab you are already on scrolls that screen back to the top.
- **The muted trailer behind the hero is now the real full trailer.** On Home and title pages, the quiet looping clip that plays behind the artwork now uses the same full trailer as the Trailer button (the app's native trailer resolver), instead of a separate short billboard snippet. It plays muted and loops, and when a title has no trailer the still artwork stays exactly as before. Apple TV, iPhone, iPad, and Mac.

### Fixed

- **The "More Like This" row on a title page now follows your poster style.** It was locked to portrait posters even when you had chosen landscape 16:9 art; it now matches the orientation, size, and label settings of every other poster row. iPhone, iPad, and Mac.
- **Add-ons page no longer clips at the edges or stacks an add-on's name one letter per line.** On a narrow phone the action buttons were squeezing the name and details into a sliver; each add-on now lays its icon and text across the full width, with the action buttons on their own row beneath.
- **Continue Watching resumes faster and more reliably, straight from your debrid account,** so picking up where you left off no longer stalls or asks you to choose a source again when the saved link has expired.
- **Apple TV focus fixes,** so moving through Home, Discover, and the Collections hub steps row by row in order; pressing down from the first hub row no longer skips the Streaming Services row.
- **Hardened how VortX fetches remote resources** so a malicious add-on or link cannot make the app reach an unintended internal address (SSRF protection).
- **Trending, genre, and streaming-service tiles now open to a full title page on iPhone, iPad, and Mac.** Tapping one of these hub tiles now resolves it to the same title the rest of the app uses, so the artwork, ratings, cast, and a working Play button all appear, the way they already did on Apple TV.
- **Catalogs keep showing posters and art even when a source is busy.** The catalog service now serves the last good response while it refreshes in the background, and keeps serving it if the upstream is rate-limited or down, so rows no longer go blank or stick on "Nothing here yet".
- **The synopsis no longer appears twice on a title page.** The full description below the action row now shows only when it is meaningfully longer than the excerpt already shown on the hero.
- **Apple TV now shows full language names in the "also available in" row** (English, Français, and so on) instead of two-letter codes, matching iPhone, iPad, and Mac.
- **More reliable downloads.** The Downloads folder is now created and verified before a file is saved, closing one cause of a "couldn't save this download" error. Thanks to a community member for contributing the fix.
- **Pause and Cancel keep working on a download after you quit and reopen the app.** A download that kept running in the background survived the app being killed, but the reopened app had lost its handle on it, so Pause and Cancel did nothing. On launch VortX now reconnects to those still-running transfers (both regular file downloads and offline HLS), so their controls act on the real download again; a download that could not be reconnected is left paused and resumable rather than stranded, and never deleted. iPhone and iPad.
- **Downloads now fail clearly on sources that can't be saved as a file.** A source that streams in segments (HLS) or resolves through a web page (some add-ons, for example ok.ru) no longer produces a broken few-KB file or an opaque error; it now reports plainly that it can't be saved for offline. True offline HLS download is planned. Thanks to the same community member for flagging it.
- **Scrub-preview thumbnails now generate correctly on Mac** during 4K and Dolby Vision playback.
- **Scrub-preview thumbnails now build and share from every title,** including plays started from Streaming Services, Trending, and genre collection tiles, and short watches now count toward the shared previews instead of being discarded.
- **Trailers play directly from your device at up to 1080p.** The app now resolves a title's trailer on the spot from your own connection and plays it straight, instead of routing through a server, so trailers start faster and look sharper; the ambient trailer behind the hero uses the same path, and a server fallback keeps trailers working if the direct resolve cannot.
- **Cached sources reach a playable one much faster.** RealDebrid retired the check that let VortX confirm a source was cached on your account, so a source could look cached (from the add-on's own label) yet not be ready; tapping it used to wait out a long timeout. The player now detects that within a couple of seconds and moves on, so a run of not-actually-cached sources no longer stalls you before one plays. Watch Now goes further: it now resolves the top few cached sources at once and plays the first one that is genuinely ready on your account, so instead of trying dead sources one at a time you land on a working cached source in a couple of seconds. Choosing a specific source yourself still resolves exactly that one. Apple TV, iPhone, iPad, and Mac.
- **What's New now has a page on Apple TV too,** under Settings, rendering the full changelog, matching iPhone, iPad, and Mac.

## 0.3.8 Beta 16 - 2026-06-30 (pre-release)

A fix-focused build over Beta 15 (build 138). The Mac crash is fully closed, brand-new releases show their sources from the hub, scrub previews capture on every kind of stream, downloads survive an app relaunch, and a batch of Apple TV playback fixes are in. In-place update, nothing resets. Please install it and report anything off, especially the Apple TV playback notes on real hardware.

### Fixed

- **Mac no longer crashes when you open Downloads, a title, a browse grid, or sign in.** Beta 15 fixed the search bar; this closes every remaining screen that built a window toolbar, so the Mac app is stable as you move through it.
- **Brand-new releases now show their sources from the Collections hub.** A title too new to be in the metadata catalog still loads its artwork and its streams from its IMDb id, instead of opening to an empty page with no sources.
- **Scrub-preview thumbnails capture on debrid and other direct streams.** They keyed off a length signal that some direct files never send, so those titles captured nothing; previews now start from the title's runtime and refine once playback reports the real length, on Apple TV, iPhone, iPad, and Mac.
- **A finished download saves even if the app was relaunched while it ran.** A background download that completed after the app restarted could not find where to save and failed; it now recovers the destination, so the file lands in your library.
- **Apple TV plays Dolby Vision through the right engine, keeps audio at 48 kHz, and restores the full streaming read-ahead buffer,** so large 4K files buffer well ahead again instead of stalling early.

### Changed

- **Downloads is one pill inside Library.** It is no longer a separate catalog and no longer sits on Home, Discover, or the top of Library, just a single pill in Library that opens your downloads.
- **Mac browsing has a visible search field and a Back button.** Search is easy to find, and Back, or the Escape key, returns you from any screen.
- **Catalog cards and hub pills share one size** so rows line up cleanly.

## 0.3.8 Beta 15 - 2026-06-29 (pre-release)

A big one: a Collections hub (Discover cards, Streaming Services with their logos, and Genres) on Home and Discover with a tap-to-browse grid, native debrid playback that plays cached torrents instantly, budget and box office on movies, spoiler-blurred unwatched episodes, an in-player AirPlay button, a download queue, upcoming-movie release dates, and the Apple TV 47-second crash plus the Mac crash fixes from your reports. In-place update, nothing resets. Please install it and report anything off, especially the Apple TV stability and the new hub on real hardware. Thanks to OrigamiSpace, whose open SkipDB and in-player editor several of these features build on.

### Fixed

- **Apple TV no longer crashes about 47 seconds into playback when the streaming cache is on.** The on-disk cache budget was being held as an in-memory buffer and pushed the Apple TV past its memory limit; it is now capped to a device-safe amount of RAM, so the cache can be on without the crash.
- **Mac no longer crashes from the search bar.** The macOS search field lived in the window toolbar, which could throw under rapid UI updates; macOS now uses an inline search field instead.
- **Title logos show for titles from any catalog.** A show or movie coming from a TMDB (or other non-IMDb) catalog now resolves its logo via the title's IMDb id, on the detail page and the Home hero, not only IMDb-catalog titles.
- **A series detail page no longer crops the hero image.** Series that only ship a portrait poster now fit the hero band instead of cropping with black bars, on Apple TV, iPhone, iPad, and Mac.
- **A finished download no longer fails with "cannot create file"** (the downloads folder is created before the file is saved).
- **Mac: arrow keys move focus on Home,** and the Home hero no longer flickers through titles when focus changes.
- **Video upscaling is now per-device** (standard on Apple TV, scaled on Mac if you choose) and no longer syncs over.
- **The streaming cache is Off by default** (the picker used to show 2 GB while it was actually off).

### Added

- **Scrub-preview thumbnails now generate on every player engine.** They previously did not capture when a title played through the AVPlayer engine (Dolby Vision and HLS on Auto), so those titles produced no previews; they are captured and contributed now, on Apple TV, iPhone, iPad, and Mac.
- **A Download button beside Quality** on the detail page (movies and episodes) downloads the auto-selected quality, with Download, Downloading, and Downloaded states and a Library badge that shows active downloads, on iPhone, iPad, and Mac.
- **Apple TV: an in-player skip-segment editor.** Mark and submit intro, recap, outro, and preview times right from the Apple TV player; submissions go to VortX's open skip database and the community SkipDB. Thanks to OrigamiSpace, whose iPhone and Mac editor this is the Apple TV version of.
- **Apple TV: offline downloads.** Download movies and episodes on Apple TV, with a note that the system can reclaim the space when storage runs low.
- **A Collections hub on Home and Discover.** A new band high on the screen with three rows: Discover cards (Trending, Popular, Latest, Upcoming), Streaming Services shown with their logos (Netflix, Disney+, Prime, and the services available in your region, including anime, K-drama, and regional ones), and Genres. Tap any tile to browse its catalogs, Movies, Shows, New Movies, New Shows, Top This Week, Month, and Year, and Trending, and every title plays through VortX as usual. You can reorder the streaming services, turn the hub on or off for Home and Discover separately, and choose how often it refreshes. Needs a TMDB key (Settings, Metadata). It replaces the older grouped streaming and genre rails. On Apple TV, iPhone, iPad, and Mac.
- **Budget and box office on a movie's page.** A movie now shows its budget, box office, and profit under the ratings. Movies only, needs a TMDB key, and you can hide it in Settings. On Apple TV, iPhone, iPad, and Mac.
- **Spoiler-safe episodes.** Episode thumbnails you have not watched yet are blurred so a future episode's art does not spoil you. Watched episodes stay clear; turn it off in Settings. On Apple TV, iPhone, iPad, and Mac.
- **AirPlay from the player.** iPhone and iPad now show an AirPlay button in the player overlay, so you can start AirPlay without leaving the app.
- **Download queue.** Downloads now run a few at a time and the rest wait in line, starting automatically as each one finishes, so queueing a season no longer hammers your connection all at once.
- **Player haptics on iPhone and iPad** for play/pause, accepting a skip, and copying a link.
- **Cached debrid torrents play instantly.** Add your Real-Debrid, TorBox, AllDebrid, or Premiumize key under Settings, Debrid, and a cached torrent now plays straight from your debrid account instead of starting the torrent, with more than one service checked at once.

## 0.3.8 Beta 14 - 2026-06-29 (pre-release)

The big one: the Apple TV crash/hang fix you asked for, offline downloads, our own skip database with an in-player editor, community scrub-preview thumbnails, grouped Home collections, a configurable streaming cache, and a wave of sync and add-on improvements. In-place update, nothing resets. Please install it and report anything off, especially the Apple TV stability on real hardware.

### Fixed

- **Apple TV no longer hangs the whole device after finishing or stopping a title and opening another.** This is the main crash, and it hit debrid (and direct-link) playback, not just torrents. When you left a title, the player kept its full video buffer and decoder alive until the system happened to clean it up later, so the moment you opened the next title there were briefly two players running, which pushed a 2 GB Apple TV past its memory limit and the system killed the whole app (menu bar frozen, Back drops to Home, server shown offline on reopen). The player now shuts down immediately when you leave a title, before the next one starts, so the two never overlap. The 2 GB Apple TV also keeps a smaller rewind buffer for extra headroom.
- **Apple TV no longer hangs the whole device after watching a torrent.** A separate path: the streaming server keeps a memory cap that protects the Apple TV from running out of memory, but it was only set once at startup, with no confirmation it actually took. On a slow start it could silently miss, and the server then ran with a 2 GB cache that pushes the app past the Apple TV's memory limit. The cap is now confirmed and retried until it sticks, and re-applied right before each torrent starts.
- **A finished movie leaves Continue Watching on every profile.** A movie watched to the end could stay pinned in Continue Watching, most often on a second profile. It clears now.
- **Smoother second profile.** Watch progress was nudging the cross-device sync on every tick while you watched; it now waits until you pause or stop, which keeps a second profile from feeling laggy.
- **Apple TV: a movie's page opens on Watch Now again, not the Trailer button.** When you opened a movie while its sources were still loading, the focus landed on the Trailer chip instead of Watch Now. The page now seats focus on Watch Now from the moment it appears and keeps it there as the sources settle.
- **The player's top-right now shows the episode title, not just the season and episode number.**
- **Mac: arrow keys move focus on Home again.**

### Added

- **Upcoming Episodes on Home.** A new rail shows the next episode of the shows in your library that air within the next 45 days, soonest first, on Apple TV, iPhone, iPad, and Mac. It uses the same air-date data the new-episode reminders already gather, routes to the show when you open a card, and simply does not appear when nothing is upcoming.
- **Offline downloads.** Download movies and episodes to your iPhone, iPad, or Mac and play them with no connection, from debrid, direct links, or torrents. Downloads live in their own section with progress, pause and resume, and storage management.
- **Self-hosted skip database with an in-player editor.** Skip-intro, recap, and credits times are now fetched first from VortX's own database, then the open community sources. You can mark and submit segments yourself from a built-in player editor, and a submission goes to VortX and the open SkipDB at the same time. You can also add an API key for any other compatible provider to contribute there too. Thanks to OrigamiSpace, who created the open SkipDB and contributed the in-player editor this builds on (#98, #100).
- **Community scrub-preview thumbnails.** Seek-preview thumbnails are now shared across devices: once anyone has generated a title's previews, everyone else sees them instantly with no local work. It always falls back to your device's own capture, so there is never a regression. Thanks to OrigamiSpace, who contributed the original scrub-preview thumbnails.
- **Play straight from a cached debrid link.** If a source is already cached on your debrid account (Real-Debrid, AllDebrid, Premiumize, or TorBox), VortX now plays it directly from the cached link instead of starting the torrent, and cached sources show a "cached" chip and rank higher in the list. Without a debrid key nothing changes.
- **Grouped Home collections.** Home rails are now grouped (streaming services, genres, top new, and just new) for a cleaner browse, with a browse-by-streaming-service view.
- **Configurable streaming cache.** A new Settings option lets you set an on-disk streaming cache size (default off), so seeking back in a long title stays instant.
- **Add-on improvements.** Removing an add-on on one device now removes it everywhere, like settings sync. Add-ons also gained a Configure button, a change-URL option, drag-to-reorder on iPhone, iPad, and Mac, and better compatibility with manager add-ons (logo, order, and update-on-reinstall).
- **Logos on more art.** fanart.tv clearlogos now show across Apple TV, iPhone, and Mac.

### In progress

- **Trailers and hero clips** play where they resolve today; broader coverage is still rolling out.
- **Jellyfin media-server support** is groundwork only and not usable yet.

## 0.3.8 Beta 13 - 2026-06-28 (pre-release)

The big bug-fix wave, plus the cinematic catalog rebuilt the right way. Trailers play again, Home rows keep loading, the catalog goes wide and cinematic, and a batch of Apple TV audio and HDR fixes are in that I need your help testing on real hardware. In-place update, nothing resets. This is a beta, so please install it and report anything off, especially the Apple TV sound and HDR notes at the bottom.

### Fixed

- **Trailers play again, on Apple TV, iPhone, iPad, and Mac.** The in-app trailer resolver used a YouTube path that YouTube quietly shut off, so trailers silently failed. It now uses a current path that returns the actual video and plays it inline in the app's own player. The same fix makes trailer add-ons (like Streailer) playable, and a trailer can never be picked as the movie's source by mistake.
- **Home catalog rows keep loading.** A catalog row on Home (for example MyTraktSync) stopped after about 20 titles instead of scrolling on. It now loads more as you reach the end of the row, the same as the Discover grid already does (#95).
- **The Live TV filter is gone when Live TV is off.** Turning Live TV off left a stray "Channel" type filter on the Discover screen. With Live TV off, its content types no longer appear there.

### Added

- **Cinematic landscape catalog cards.** Catalog rows and the Discover and Library grids now show wide 16:9 cards built from clean, textless TMDB artwork, across Apple TV, iPhone, iPad, and Mac. It is on by default, with a switch in Settings, Appearance, "Cinematic catalog cards," to return to the classic portrait posters any time. It uses your TMDB key (set one under API keys); without a key the catalog stays on portrait posters so it never falls back to a worse-looking card. When a title has no TMDB backdrop, the card fills with a softly blurred copy of the poster behind a fit copy, so the frame still looks intentional.

### Please test on your Apple TV (fixes I cannot verify without the hardware)

- **No sound under Dolby Atmos.** If you set the Apple TV audio to Dolby Atmos or Best Available and a title was silent, this build has the fix. Please test it, and if it is still silent, send me the Console log line that starts with `[#78 audio]`.
- **HDR10 plus Dolby Vision.** A file that carries both should now play Dolby Vision, not just HDR10. Please confirm the Dolby Vision badge shows on your TV.
- **AirPods Spatial Audio.** Head-tracked Spatial Audio with AirPods should work in the player now. Please confirm.

## 0.3.8 Beta 12 - 2026-06-28 (pre-release)

The Beta 11 follow-up. A focused pass on the bugs you reported: trailers that actually play, Continue Watching that behaves, a Home you can tidy up, sharper resolution labels, and working keyboard navigation on the Mac. In-place update, nothing resets. This is a beta, so please install it and report anything off.

### Fixed

- **Trailers play the real trailer again, on iPhone, iPad, and Mac.** The Trailer button was loading a fragile path that often failed and then fell through to playing the actual movie. It now plays the official YouTube trailer inside the app the way the rest of the ecosystem does, and it finds a trailer for many more titles (it also looks them up on TMDB now). Apple TV is unchanged.
- **Finished titles leave Continue Watching.** A movie or episode watched to the end and then closed by hand used to stay in the row at its end position. It clears now, the same as when it plays out on its own.
- **Resuming from Continue Watching works far more often.** A title resumed straight from the Continue Watching row often showed "sources didn't load" and made you reopen it and pick a source again, most often with debrid, whose links expire between sessions. The resume now loads fresh sources in the background and, if the saved link has expired, switches to a working one on its own.
- **The resolution label is right on widescreen 4K.** A cinematic 4K film (a wide 2.40:1 frame) was labeled 1440p because the label read the picture height. It reads the width now, so 4K shows as 4K.
- **A tiny file can no longer pose as 4K.** A small stream that merely carries "2160p" or "4K" in its title is no longer trusted as real 4K, so it stops topping the source list and showing a 4K badge it cannot back up.
- **Mac: arrow keys move the selection on Home.** The keyboard highlight used to appear on a clicked card and then sit there; the arrow keys now move it across a row and between rows.

### Added

- **Hide the built-in Home rows.** The editorial rows (Critically Acclaimed, Hidden Gems, Modern Classics, Award Winners) are built in and used to show no matter what. A new switch in Settings, Appearance, "Show editorial Home rows," turns them off.
- **SkipDB for skip timestamps.** A new open skip-segment source you can pick in Settings, Playback, "Skip timestamps source," alongside the existing one. Thanks to OrigamiSpace for contributing this (#98).

## 0.3.8 Beta 11 - 2026-06-25 (pre-release)

The Beta 10 fixes release. It works through the reports that came back from Beta 10. In-place update, nothing resets.

### Fixed

- **The catalog goes back to poster cards.** The wide landscape cards from Beta 10 showed cropped and sometimes wrong art, so the catalogs return to the reliable poster grid while a proper cinematic treatment is built on a dependable art source.
- **The ERDB and fanart toggles stay off.** Turning them off used to flip back on within a second, because an incoming sync could overwrite a setting you just changed. Your toggle sticks now.
- **Title logos are back on the hero and detail pages.** They had dropped to plain text; with the toggles fixed, the add-on logos return.
- **Duplicate and reappearing profiles are cleaned up.** A second copy that a delete could not clear is removed and stays removed, and a deleted profile no longer comes back from a sync. Your main account profile stays non-deletable by design; you can rename it instead.
- **Settings sync no longer fights you.** The cause behind the toggles and the profiles was a sync change that could re-apply your account's old values over a change you just made; the guard that protects an in-flight edit is restored.
- **The Settings screen is fully translated** across all supported languages.

### Note

- **Dolby Vision plays through the built-in player on Apple TV,** confirmed on device, so you do not need anything else for true Dolby Vision.

## 0.3.8 Beta 10 - 2026-06-25 (pre-release)

The Beta 9 cleanup release. Beta 9 landed the account and playback wave, and this release works through the report that came back from it. The headline is a cinematic redesign of the catalogs into wide landscape cards on every platform, plus trailers that now play inside the app on iPhone, iPad, and Mac, settings that sync across your devices again, and a batch of Apple TV navigation and focus fixes. In-place update, nothing resets. This is a beta, so please install it and report anything off.

### Changed

- **Landscape catalog cards everywhere.** The catalog rows changed from tall portrait posters to wide, cinematic landscape cards on Apple TV, iPhone, iPad, and Mac. Each card shows the title backdrop, and titles that ship only a poster fall back to a clean blurred composite so the row always looks intentional.

### Fixed

- **Settings sync across your devices again.** Toggling a setting such as the Stremio mirror or the player engine on one device now reaches your other devices. A device was echoing every applied change straight back, which starved its own sync so a peer's settings never took; that loop is closed, and a strictly newer change always wins.
- **Trailers play inside the app on iPhone, iPad, and Mac.** The detail Trailer button no longer flashes an error and jumps out to the YouTube app; it plays the trailer in the built-in player. The home hero now autoplays a muted clip for the featured title after a short settle, the same as Apple TV. (#44)
- **Apple TV: Back returns to Home before it exits.** Pressing Menu on a non-Home tab used to drop you out to the tvOS home screen. It now returns to the VortX Home tab first, and only exits from Home. Pushed pages still step back one level at a time.
- **Apple TV: the Log Out button is reachable.** Moving down through the account settings no longer skips past Log Out.
- **Apple TV: the poster and ratings settings labels are readable.** Those toggles drew their label in the accent color over an accent fill, so the text vanished when unfocused. They are normal switches with a readable label now.
- **Apple TV: the Discover add-ons list takes focus and looks right.** Pressing down from the search field now moves into the results instead of getting stuck, and the focused row uses the app's own highlight rather than a plain white block.
- **Apple TV: the built-in player steps in faster.** When AVPlayer accepts a stream but never starts (some Dolby Vision debrid streams), it now hands off to the built-in player within a few seconds instead of stalling for about half a minute.
- **iPhone: a few screens stopped clipping.** What's New no longer cuts off at the top and bottom, debrid and source names read on one line instead of stacking a couple of letters per line, and the Discover add-ons screen no longer runs off both edges.
- **Catalog row names translate.** Compound names such as "Popular Movies" and "Top Series" now localize using the existing per-word vocabulary, so far fewer rows read as English in other languages.

### Added

- **ERDB posters with no token.** The optional VortX poster, backdrop, and logo art is now a simple on or off toggle. Our service is keyless, so you no longer need to paste a token; a token is only for a self-hosted setup. It stays opt-in.
- **Use fanart posters.** With ERDB on, a new toggle pulls posters from fanart.tv instead of the default source. It uses your own fanart key from the metadata key settings if you have set one, otherwise our service key.
- **The Show Live TV tab control is easier to find.** It now sits near the top of Appearance on iPhone, iPad, and Mac, and reads "Show Live TV tab" on Apple TV.

### What we're working on now

- Localizing the Settings labels across every language (the catalog names are done; the settings strings are next).
- Household sharing of add-ons and library across separate accounts, and finishing the two-way real-time sync.
- The precise Dolby Atmos fix that needs an on-device log capture.

## 0.3.8 Beta 9 - 2026-06-25 (pre-release)

The account and playback release. Two big steps land here. First, your VortX account now genuinely owns your add-ons, library, and sources, so the app loads them straight from your account and no longer goes empty or traps you when your Stremio session is logged out or slow. Second, Apple TV gets a first-class AVPlayer with the full player chrome, so true Dolby Vision, AirPlay, and Picture-in-Picture play through it on Auto, with the built-in player as a true fallback. Plus trailers play again on iPhone, iPad, and Mac, an Apple TV in-hero trailer on the detail page, posters now served by our own art service, and a batch of fixes. In-place update, nothing resets. This is a beta, so please install it and report anything off.

### Added

- **Your account owns your add-ons, library, and sources.** The app now hydrates them from your VortX account into the engine, so a logged-out or degraded Stremio session no longer shows zero sources and add-ons, and it no longer blocks you from logging out. Your full add-on list is held in your encrypted account, and the first time you import from Stremio it takes a snapshot. New per-category "Mirror from Stremio" toggles let you choose whether your add-ons, library, and Continue Watching stay in step with Stremio; they default off, so VortX keeps its own copy.
- **A first-class player on Apple TV.** The same player that runs on the other platforms now runs on Apple TV under the full player chrome. On Auto, Dolby Vision and HLS play through it with AirPlay, Picture-in-Picture, and true Dolby Vision, and the built-in player steps in only as a last resort. The old bare Apple TV playback path is gone.
- **A trailer on the Apple TV detail page.** The detail page now plays a muted trailer in the hero, so you get a moving preview while you decide. (#44)
- **Posters from our own art service.** The optional poster, backdrop, and logo art now comes from VortX's own service at erdb.vortx.tv instead of a third party. It stays opt-in and you set it up the same way.
- **A fanart.tv key.** You can add a fanart.tv API key in Settings for richer artwork; it syncs across your devices alongside your TMDB and MDBList keys.

### Fixed

- **Trailers play again on iPhone, iPad, and Mac.** YouTube began requiring a real referrer in July 2025, which silently broke embedded trailers. VortX now serves the embed so a proper referrer reaches YouTube, and trailers play again. Apple TV was never affected.
- **Your synced TMDB key no longer disappears.** Signing in on another device could blank out the TMDB key you had saved. Synced keys are now merged in rather than overwritten, so the key sticks.
- **Profile deletes stick across devices.** Deleting a profile could see it reappear after a sync from another device. Deletes are now durable tombstones that survive the merge, so a deleted profile stays gone. Your main account profile is never removed.
- **A saved magnet reopens the right file.** A saved magnet or playlist now reopens the exact file you saved, instead of fuzzy-matching and landing on the wrong show. (#81)
- **Apple TV stays audible under Dolby Atmos, and never freezes.** Multichannel audio is now driven by what your output device reports, with a safety net so the video never freezes if an audio route cannot open. A diagnostic log is in place to pin down the precise Atmos fix from an on-device capture. (#78)
- **Discover keeps paginating past a tricky catalog.** A catalog whose cursor went empty partway through a list (for example MyTraktSync) could stop loading more in Discover; it now keeps paginating. (#95)

### What we're working on now

- The remaining Apple TV audio work: a precise fix for Dolby Atmos that needs an on-device log capture.
- Carrying the account-owns-everything work the rest of the way, so the library is complete on the account and the same model reaches the dashboard, Android, and desktop.
- A home-screen hero trailer on Apple TV, and per-rail "load more" on the home screen.
- More of the in-app player and discovery experience landing on the web and desktop apps.

## 0.3.8 Beta 8 - 2026-06-25 (pre-release)

The Beta 7 cleanup release. Beta 7 shipped a big playback and discovery wave, and with it a batch of bugs. This release fixes them: the Mac crash, Apple TV playback, the add-on store, the duplicate "Main" profile, the language setting, the invisible buttons, and the trailer. It also makes the seek-bar styles actually come alive and brings the player-engine choice to Apple TV and Mac. In-place update, nothing resets.

### Fixed

- **Mac no longer crashes.** The Mac app could quit the instant you switched tabs, resized the window, or changed the language. Several browse screens were each trying to place the VortX wordmark into the single shared window title bar at once. The wordmark is now iPhone and iPad only; the Mac keeps its native title and the crash is gone. This also unsticks Mac language changes and keyboard navigation, which the crash had been swallowing.
- **Apple TV plays again.** Some streams opened to a black screen with no way out. When the native AVPlayer cannot open a stream, VortX now hands it straight to the built-in player instead of dead-ending, so playback always starts. You can also force the built-in player from Settings (see Added).
- **The duplicate "Main" profile is gone.** Signing in or reinstalling could leave a second "Main" profile behind, and it kept coming back. The account owner now has one fixed identity across every device and install, so it can never be duplicated again, and any existing duplicate is cleaned up automatically on launch. Your real profiles and your synced data are untouched; this was a profile-identity bug in the app.
- **The add-on store scrolls on Apple TV.** The Discover add-ons list could get stuck at the top because the already-installed rows that head the list were not focusable. Every row is reachable now, so the list scrolls all the way down.
- **Add-on names read normally on iPhone.** In the add-on store, long names like "Torrentio" could stack one letter per line. Names now stay on a single line beside their type tags and the Install button.
- **The language setting works, and you can find it.** Picking a language such as Hindi appeared to do nothing, because the app must relaunch to switch language and never offered to. It now offers to quit and reopen so the change actually applies, the picker sits near the top of Settings on iPhone, iPad, and Mac, and Apple TV finally has a language picker too, under Appearance.
- **Invisible buttons are visible again.** The "Install all add-ons" button and the update prompt's "Get the update" button showed white text on the gold accent, so the labels vanished. They now use the correct on-accent color.
- **Trailers play.** The in-hero and detail trailer errored within half a second and fell back to the still image for almost every title. It now ignores the transient errors that fire under the hood and only falls back when a video genuinely cannot be embedded.

### Added

- **A player-engine choice on Apple TV and Mac.** Settings, Playback now lets you choose how streams play: Auto, Always built-in, or Prefer AVPlayer for HLS and Dolby Vision. If a stream will not start in one engine, switch to Always built-in. iPhone and iPad already had this; now every platform does.
- **Seek-bar styles that actually move.** The fourteen seek-bar styles were nearly identical and sat still. They are genuinely distinct and animated now: the Wave flows, the Equalizer bounces, the Comet trails a glow, the Heartbeat sweeps like a monitor, Liquid sloshes, Ripple rings out from the playhead, and more. Pick yours in Settings, Playback, Seek bar style; each preview animates the real design.

### Dashboard (vortx.tv/dashboard)

- **One "Main" on the dashboard too.** The dashboard now collapses any leftover duplicate owner profile on sight, so your account shows a single "Main" while your devices update to the fixed app.

### What we're working on now

- True Dolby Vision and the full player chrome reaching more places, and the remaining Apple TV audio work.
- Bringing your add-ons, library, and sources fully into your VortX account so the app works from your account alone, independent of a live Stremio session.
- More of the in-app player and discovery experience landing on the web and desktop apps.

## 0.3.8 Beta 7 - 2026-06-21 (pre-release)

The playback and discovery release. The headline: the "Prefer AVPlayer (HLS/DV)" engine, with its true Dolby Vision and clean adaptive HLS, now reaches Apple TV and Mac, and on Apple TV it brings in-player Episodes and Sources panels so you can change what you are watching without leaving the player. There is also a new in-app add-on store, source pinning, a plain-language reason for every auto-picked source, and ratings baked onto your posters with no key to set up. In-place update, nothing resets. This is a beta, so please install it and report anything off.

### Added

- **Prefer-AVPlayer player on Apple TV and Mac.** The "Prefer AVPlayer (HLS/DV)" engine that iPhone and iPad already use for true Dolby Vision and clean adaptive HLS now reaches the other two platforms. On Mac, HLS and true Dolby Vision play through the same full player chrome as the rest of the app. On Apple TV, the player gains two in-player panels: swipe down on the Siri remote to jump to any episode of the show, or to switch to a different source or quality, all without leaving the player. Both resolve through the engine exactly as Play does, so your pinned source and preferred quality carry over. (#46)
- **Discover add-ons in the app.** A new browsable store (Add-ons, then Discover add-ons) lists the community add-on collection so you can find and install add-ons without ever leaving VortX. Each one shows whether it is reachable right now (Online, Slow, or Unreachable), search narrows the list by name, type, or description, and one tap installs it to your account so it syncs to your other devices. (#25)
- **Pin a source.** Long-press any source on a movie or show and pin it for just this title, for the whole show (every episode then prefers the same provider and quality), or for everything. A pinned source jumps to the top of one-press Watch and the source list, the next episode keeps using it, and automatic failover still moves on if it ever goes down. Clear pins anytime from Settings, Streams. (#15)
- **Know why a source was picked.** When VortX auto-picks the recommended source, a short line under Watch now explains the reason in plain terms, for example that it was picked for instant playback from cache or because it matches your preferred source type. (#16)
- **Ratings without setup.** IMDb, Rotten Tomatoes, Metacritic, and more now come straight from VortX, so there is no key to find or paste. Ratings appear on the detail screen automatically, and they are also baked right onto your posters, on by default, so you can see a title's score at a glance while you browse.
- **Smarter recommendations.** "More Like This" now leans on shared genres rather than raw popularity, so the suggestions feel closer to what you are actually watching, and "Top Picks" pulls from across your recent watches for more variety.
- **Your language, everywhere.** Add-on category and genre headers (Popular, Trending, Top, and the full list of genres and types) are now translated across all 64 languages, so the rows that organize your catalogs read in your language too.

### Fixed

- **Live TV no longer shows up empty.** When a live-TV add-on was installed and online, the Live tab could still look empty because its catalogs loaded outside the default Home window. VortX now reaches for those catalogs so live channels appear as expected. Fixed across iPhone, iPad, Mac, and Apple TV.
- **The whole interface now follows your language.** The tab bar and screen titles (Home, Live, Search) could stay in English even after you switched languages. They now translate properly along with the rest of the app.

- **Why a source was picked.** The recommended source now shows a short reason beneath Watch, so it is clear why it was chosen over the rest: that it plays instantly from your debrid cache, and that it is your preferred kind of source. (#16)

- **Ratings now come from VortX, no key needed.** Posters and the detail page show IMDb, Rotten Tomatoes, and Metacritic from VortX's own ratings service, so you no longer need your own MDBList key. The rating is baked onto your posters out of the box (on by default); you can still point at your own instance or turn it off in Settings.

- **Smarter recommendations.** "More like this" now ranks by how many genres a title actually shares with what you are viewing (and keeps same-series entries on top) instead of by raw popularity, so the suggestions are genuinely related rather than just whatever is most popular in the genre. "Top Picks for you" now mixes across the different shows you have been watching rather than piling up look-alikes of the most recent one.

### Fixed

- **Live TV add-ons now show up.** A Live TV add-on (for example MediaFusion) could report online yet leave the Live tab empty, because its channel catalog only loaded if you had scrolled the Home screen far enough first. The Live tab now pulls in every installed add-on's channels directly, so they appear as soon as you open it.

- **The whole interface is localized now, not just Settings.** The menus (Home, Discover, Search, Library, Live), the screen titles, and the category and genre headers your add-ons provide (Popular, Action, Top Movies, and the rest) are translated across all 64 languages. An add-on category we do not yet have a translation for is shown in its original wording.

### Web (web.vortx.tv)

The browser app is live at [web.vortx.tv](https://web.vortx.tv) and updates continuously, separate from the app betas. Recent additions: each local profile now keeps its own library and Continue Watching, so what one profile watches stays separate from the rest while your account library stays clean. The profile editor also got a polish pass so the avatar color swatches no longer spill out of the Settings card, and a security pass tightened how your encryption key is held in the browser, clamped key-derivation settings, and stopped the recovery code from ever leaving your device.

### Dashboard (vortx.tv/dashboard)

- **Add-on health you can trust.** The Add-ons page now checks each add-on through VortX, so the Online, Slow, and Unreachable status is accurate even for add-ons your browser could not reach directly.
- **Households just work.** Creating or joining a family now heals itself if an old membership was left behind, so you no longer get told you are "not in a family" while also being told you "already" are. A failed check now offers Retry instead of dropping you back to the create form.
- **Steadier syncing and cleaner polish.** Saving metadata and debrid settings from the web no longer races itself when two changes land close together, profile editors and add-on rows no longer overflow on small screens, status messages are announced to screen readers, touch targets are larger, and small text across the landing and login pages is easier to read.

### What we're working on now

- True Dolby Vision and the full player chrome reaching more places, and the remaining Apple TV audio work.
- Bringing your library and watch history into a single cross-device sync that keeps every profile in step.
- More of the in-app player and discovery experience landing on the web and desktop apps.

## 0.3.8 Beta 6 - 2026-06-21 (pre-release)

A fix-and-polish beta. The headline is that managing your account from [vortx.tv/dashboard](https://vortx.tv/dashboard) now works the way it should: your whole household, your profiles, and almost every per-profile setting are editable from the web and sync straight to your devices. In-place update, nothing resets. This is a beta, so please install it and report anything off.

### Fixed

- **Continue Watching tracks reliably again.** Progress now records and finished titles clear, even when you resume straight from the Continue Watching rail or after navigating away mid-playback. Two underlying causes are fixed: the engine player is now linked to the right library entry even when the played URL was proxied or routed through AVPlayer (so progress is no longer silently dropped), and a finished movie is marked watched through the library directly (so it leaves Continue Watching instead of lingering).
- **The duplicate "Main" profile is gone.** "Use online account data" could leave two account profiles (a real one plus a leftover "Main") that you could not remove. VortX now keeps a single account profile and quietly retires any leftover, so it becomes an ordinary profile you can delete from the dashboard. This also stops the duplicate from being created in the first place, and never drops your real account profile during the merge.
- **The family contradiction is fixed.** The household card could say you were "not in a family" while creating one said you "already" were. That mismatch (a leftover membership after a household was deleted) now heals itself, and deleting a household fully cleans up so it cannot happen again.

### Dashboard (vortx.tv/dashboard)

- **Every per-profile control is now on the web**, applied to your devices on the next sync: source priority, Kids Mode, stream filters (safe sources, max quality, max file size, instant-only, hide dead torrents, HDR/Dolby Vision only, skip AV1, hide/require words with regex), per-profile add-ons, and your debrid keys.
- **Add-on health at a glance.** The Add-ons page now shows an Online / Slow / Unreachable status for each add-on.
- **Cleaner Library and safer keys.** Library titles no longer appear twice (your VortX and imported Stremio copies are merged), and the metadata API-key fields are masked.

## 0.3.8 Beta 5 - 2026-06-20 (pre-release)

Building on the 0.3.8 account work. The headline is that VortX now speaks **40 languages**, alongside a wave of per-profile and power-user controls: per-profile add-ons, in-app debrid keys, Kids Mode, one-tap quality presets, regex source filters, library export and import, Import from Stremio, Where to Watch, anime skipping, an in-player frame grab, true Dolby Vision on iPhone and iPad, and poster ratings. In-place update, nothing resets. This is a beta, so please install it and report anything off.

### Added

- **Automatic update notifications on every device.** When a newer build is available, VortX now shows a popup once per launch (on iPhone, iPad, Apple TV, and Mac) instead of only flagging it in Settings, and it re-checks once an hour while the app is open so you learn about a release without relaunching. "Get the update" takes you straight to the install. (#90)
- **64 languages.** The interface is now fully localized across 64 languages on top of English, adding Amharic, Armenian, Georgian, Kazakh, Khmer, Nepali, Punjabi, and Swahili to the existing set (Afrikaans, Albanian, Arabic, Azerbaijani, Basque, Bengali, Bulgarian, Catalan, Chinese Simplified and Traditional, Croatian, Czech, Danish, Dutch, Estonian, Filipino, Finnish, French, Galician, German, Greek, Gujarati, Hebrew, Hindi, Hungarian, Icelandic, Indonesian, Italian, Japanese, Kannada, Korean, Latvian, Lithuanian, Macedonian, Malay, Malayalam, Marathi, Norwegian, Persian, Polish, Portuguese, Romanian, Russian, Serbian, Slovak, Slovenian, Spanish, Swedish, Tamil, Telugu, Thai, Turkish, Ukrainian, Urdu, and Vietnamese). Choose a specific language in Settings, Language, or follow your device automatically; Arabic, Hebrew, Persian, and Urdu lay out right-to-left.
- **Per-profile add-ons.** Turn individual add-ons on or off per profile without removing them from your account, so one profile can drop sources another keeps (Add-ons).
- **Add-on health.** Each add-on shows an Online / Slow / Unreachable dot from a live check, with a Re-check button (Add-ons).
- **Kids Mode.** Mark a profile as a Kids profile to always hide adult and CAM/fake sources from it, however its filters are set (Profiles). Pair it with a PIN on your own profile for a full lock.
- **In-app debrid keys.** Add your Real-Debrid, AllDebrid, Premiumize, or TorBox key once; it's stored in your encrypted account and used everywhere, with no separate configuration site (Settings, Debrid services).
- **One-tap quality presets.** Best Quality, Balanced, and Data Saver set the source-type order and quality caps together, so you can pick a taste without tuning each control (Settings, Streams).
- **Regex source filters.** The Hide / Require words can now be full case-insensitive regular expressions (Settings, Streams).
- **Export and import a profile's library.** Save a profile's titles and watch progress to a file and bring it to another device or profile, no account needed (Settings, Backup & Restore).
- **Import from Stremio.** A guided screen that points you to sign-in (which pulls your add-ons, library, and history) and installs several add-ons at once from a list of manifest URLs (Settings).
- **Where to Watch.** The detail page shows where a title streams legally in your region, with provider logos and a link (needs a TMDB key).
- **Anime skip.** Intro, ending, and recap skipping now covers anime via AniSkip (keyed by MAL id), alongside the existing crowd timestamps.
- **In-player frame grab.** A Grab button captures the current frame at full quality and opens the share sheet to save or send it (iPhone, iPad, Mac).
- **True Dolby Vision on iPhone, iPad, Apple TV, and Mac.** A Dolby Vision stream in an MP4, MOV, or HLS container now plays through Apple's AVPlayer for true DV passthrough on a DV-capable display, instead of being tone-mapped to SDR. On iPhone and iPad it routes to the full-chrome AVPlayer surface; on Apple TV to a native AVPlayer screen; on Mac to a native video surface. Direct and debrid sources benefit; MKV releases and torrents stay on the built-in player (which has no Matroska path in AVPlayer), and an AVPlayer load failure falls back to it automatically. Force either engine in Settings, Playback. (#76)
- **Ratings on posters (XRDB).** Optionally overlay ratings, quality badges, and provider logos on your posters from an XRDB instance (Settings).
- **Fourteen seek-bar styles** for how the scrubber looks during playback — Classic, Gradient, Glow, Wave, Heartbeat, Pulse, Dots, Equalizer, Minimal, Neon, Ribbon, Comet, Segments, and Ladder (Settings).
- **One-tap sideload updates.** An AltStore / SideStore source so a sideloaded VortX updates in place.

### Fixed

- **Saved magnets and pasted links attach to the right title**, with a confidence-gated match so a save never lands on the wrong show. (#81)
- **Better audio over AirPods and Bluetooth**, with multichannel handled safely so spatial audio works and stereo-only routes don't drop out. This now applies on both player engines, so a Dolby Vision or HLS stream playing through the system AVPlayer (including on Apple TV) advertises multichannel for Dolby Atmos passthrough and AirPods head-tracked Spatial Audio too, instead of a stereo downmix. (#88, #78)

## 0.3.8 - 2026-06-19 (pre-release)

The big one: a free, end-to-end-encrypted **VortX account**. Sign in and your profiles and settings follow you between devices, the server only ever holds ciphertext. This build fixes the headline problem from the first beta: your devices now actually sync to each other. Plus in-app add-on management, a catalog manager, optional TMDB-powered recommendations, and a batch of fixes. This is a pre-release for testing; QR sign-in on Apple TV and one-tap Stremio sign-in are coming in 0.3.9.

### Added

- **VortX account (optional, end-to-end encrypted).** Create an account, sign in, or recover it from Settings; your password derives the encryption key on-device, so the server can never read your data. Your **profiles and settings sync** across devices, pulled automatically each time you open the app. Manage it (backup/restore, two-factor, change password, connect Stremio, library and add-ons) at [vortx.tv/dashboard](https://vortx.tv/dashboard).
- **Install add-ons in the app.** Paste an add-on's manifest URL in Add-ons to install it, no more leaving for the Stremio app.
- **Catalog manager.** Show, hide, and reorder the catalog rows on Home, per profile (Add-ons, Customize catalogs).
- **Smarter "More like this".** With your own TMDB key (Settings, Metadata), detail-page recommendations blend in TMDB's; without a key it uses the built-in genre and franchise matching. Builds on the new section contributed by [OrigamiSpace](https://github.com/OrigamiSpace). (#89)
- **Save magnets and pasted links for later**, per profile. A saved multi-file torrent reopens its file picker. (#81)
- **A max file-size limit** in Settings under Streams, alongside the max-quality cap. Ask for "1080p but not a 20 GB file."
- **Recent searches on Apple TV.** Contributed by [OrigamiSpace](https://github.com/OrigamiSpace). (#90)

### Fixed

- **Profiles and settings now sync between your devices live, without a relaunch.** Open the app and it pulls and applies the latest from your account, so a profile or setting you change on one device shows up on the others. An earlier beta pulled the data but did not apply it to the running app, so profiles could appear to flip back; that is fixed.
- **Two-factor no longer shows as off in the app** after you enable it; it refreshes its status from the server.
- **The sign-in field reads "Email or username,"** since either one works.
- **Your TMDB and MDBList keys are masked** in Settings instead of shown in plain text.
- **The catalog manager lists your catalogs in their current Home order,** not alphabetically.
- **A macOS crash tied to the window toolbar is fixed** (a conditional toolbar item that could crash during a view update).
- **Playback no longer dies when you lock the screen or leave the app on iPhone/iPad.** Keeping it playing also keeps the streaming server alive, so a torrent survives. Toggle in Settings, Playback. (#74)
- **The Apple TV top menu bar returns reliably** after you scroll a series and press Back. Contributed by [OrigamiSpace](https://github.com/OrigamiSpace). (#75, #91)
- **A macOS crash during trickplay in the background is fixed.** Contributed by [OrigamiSpace](https://github.com/OrigamiSpace). (#93)

## 0.3.7 - 2026-06-16

A small release: a multi-file magnet picker, a macOS search fix, and the move to the VortXTV GitHub organization.

### Added

- **Pick which file to play from a multi-file magnet.** Paste a season pack or playlist and choose a video from the list (name and size), on iPhone, iPad, Mac, and Apple TV. A single-video torrent still auto-plays the best file. (#81)

### Fixed

- **Searching from the home header on Mac now opens the Search tab.** Contributed by [OrigamiSpace](https://github.com/OrigamiSpace). (#80, #82)
- **Apple TV's smart search suggestions now also apply on iPhone, iPad, and Mac**, so a show you are typing surfaces sooner.

### Notes

- The project moved to the **VortXTV** GitHub organization. Old links redirect; stars, forks, issues, and releases carried over.

## 0.3.6 - 2026-06-15

The curvy vortex X everywhere, the VortX gold theme by default, and a macOS custom-server fix.

### Added

- **The curvy vortex X** (two swirling ribbons and a cream center) is now the app icon, the launch screen, and the in-app wordmark on every platform.
- **VortX gold is the default accent** for new installs. If you already picked a theme, it stays.

### Fixed

- **Plain-HTTP custom streaming servers now connect on macOS** (for example a server reached over Tailscale). The Mac build was missing the transport-security exception the iPhone and Apple TV builds already had. (#58)
- **Mac, iPhone, and iPad wait for all sources** before auto-playing the best one, matching Apple TV, so the genuinely best release wins instead of the first to arrive.

### Notes

- Remaining "StremioX" labels in Settings are now "VortX".

## 0.3.5 - 2026-06-15

StremioX is now VortX. This release puts on the new name, a new gold-on-obsidian icon, and an animated VortX intro, and it adds Backup & Restore so your settings can travel with you. It is an in-place update: your library, add-ons, history, and settings stay exactly as they are. A handful of player and Apple TV fixes ride along too, including a smarter best-stream picker.

### Added

- **The app is now VortX.** A new name, a new gold-on-obsidian app icon, and an animated VortX launch screen on iPhone, iPad, Mac, and Apple TV. Same app and same account underneath, so nothing resets.
- **Backup & Restore on iPhone, iPad, and Mac.** In Settings you can save your profiles, theme, and playback preferences to a file and restore them later. It is built for the road ahead: your library and watch history always return when you sign in, and this carries your local settings across too. On Apple TV a scan-with-your-phone backup is on the way; for now signing in restores your library there.

### Fixed

- **The Apple TV "Up Next" prompt shows reliably at the end of an episode.** It now takes the corner the moment the credits begin, in place of the old Skip Credits button, so Play Now and Watch Credits are always there when you reach for them, and the buttons no longer wrap or look uneven.
- **The streaming server holds up better under load.** The in-app server gets a larger background worker pool, so busy moments (a torrent and subtitles fetching at once) are less likely to stall it.
- **Best stream is smarter: a true remux now beats a merely bigger file.** The picker ranks source type (remux over Blu-ray over web) and HDR/Dolby Vision and audio above raw file size, with size only breaking ties, so the highest-quality source wins instead of just the largest.
- **The Apple TV "All sources" list scrolls all the way down again** even when the first entry is a non-playable one (like a Ratings add-on).
- **The Apple TV top menu bar comes back reliably** after returning from the Home screen or switching profiles, instead of occasionally staying hidden.
- **Apple TV search suggestions interleave movies and series** instead of listing every movie before the first series, so a show you are typing surfaces sooner. Contributed by [OrigamiSpace](https://github.com/OrigamiSpace).

### Notes

- Next up is VortX in full: the repository and docs move to the new name, with a website, a subreddit, and a Discord to follow.

## 0.3.4 - 2026-06-15

A focused fix pass on top of 0.3.3, across iPhone, iPad, Mac, and Apple TV, clearing the issues found in 0.3.3 testing.

### Added

- **The Quality picker is now in the Apple TV player too.** Swap resolution (4K to 1080p to 720p) at your current position, the same one-tap switch the iPhone, iPad, and Mac player already had.
- **A default external-player picker on Mac and Apple TV.** Choose IINA or Infuse on Mac, or Infuse, VLC, and the others on Apple TV, and direct and debrid streams open straight there.

### Fixed

- **The Skip step setting now shows your choice and takes effect** on iPhone, iPad, and Mac. It was reading the saved value in the wrong format, so the control looked blank.
- **Mac Settings shows the real audio and subtitle labels again,** instead of every row collapsing to "Size".
- **A source with no readable resolution now reads "Other", not "Best",** so a small file is never dressed up as the top pick. A file far too small to be 4K is also no longer tagged 4K.
- **The Apple TV player controls are rebalanced.** Aspect, speed, and source switching moved to the left next to the gear, so the right side is no longer crowded and the skip and audio buttons no longer overlap.
- **The Apple TV "Ends at" clock no longer cuts off** after its first couple of digits.

### Notes

- Landing next: an A/B loop, a frame grab to Photos, sharing a title, copy-all-source-links, a What's New sheet, and haptics.

## 0.3.3 - 2026-06-15

The big player and browse update on top of 0.3.1, across iPhone, iPad, Mac, and Apple TV. A new in-player quality picker, native adaptive-stream playback, a default external-player engine, new-episode alerts, smarter HDR, a full set of source filters, and a long list of on-device fixes (the subtitle freeze and blank posters among them).

### Added

- **An in-player Quality picker.** One tap swaps the resolution (4K to 1080p to 720p and back) at your current position, without reopening the source list.
- **Adaptive streams now play in AVPlayer on iPhone, iPad, and Apple TV.** An OK.ru-style HLS source ramps to the best quality your connection holds, instead of getting stuck at the lowest rendition.
- **A default external-player engine.** Pick Infuse, VLC, Outplayer, Sen Player, nPlayer, or MX Player, and direct and debrid streams open straight there. A pre-flight check catches a dead link before the hand-off, and you can copy a torrent's magnet link from the same menu.
- **New-episode alerts.** Get notified when a show in your library has a new episode airing. On by default, scheduled on-device, no background tracking.
- **An Up Next band with a countdown** at the end of an episode on every platform, plus next-episode preload on iPhone, iPad, and Mac so the next one starts fast.
- **Smarter HDR and Dolby Vision.** An Auto / On / Off tone-mapping control that checks whether your display actually handles HDR, plus a Dolby Vision profile-7 to profile-8 fallback so more 4K remuxes play instead of failing.
- **Source filters and sorting.** Keyword include and exclude, a safety filter, and new toggles for Instant sources only, Hide dead torrents, HDR only, Hide AV1, and a Max quality cap. Sort the Sources list by Best, Size, or Seeders, and it remembers your choice.
- **A Chapters navigator** in the player with chapter ticks on the seek bar, an "Ends at" clock, and a configurable skip step (10, 15, or 30 seconds).
- **Lock Screen and Control Center controls** on iPhone and iPad (play, pause, skip, scrub, title and artwork), and **keyboard controls in the macOS player** (Space and arrows).
- **Auto-landscape on iPhone and iPad.** The player rotates to landscape the moment a stream opens, even with rotation lock on (with a toggle to turn it off).
- **A richer Playback Info sheet** (what is playing, the add-on it came from, the full release name and filename), a **Cast, Director, and Writer row** on the detail page, and **IMDb rating badges on catalog posters**.
- **Home catalog pagination**, so a large set of catalogs keeps loading as you scroll instead of stopping at the first batch, and **a more prominent update banner** on iPhone and Mac.
- **Seek-while-hidden on Apple TV.** With the controls hidden, Left/Right seek 10 seconds directly with a brief time pill. The options panel also closes after a one-shot pick so you land back on the video, and the Apple TV player buttons gained a frosted Liquid Glass look.

### Fixed

- **Add-on subtitles no longer freeze the app.** A slow or on-demand subtitle source (Submaker, or a laggy OpenSubtitles) used to lock the player while it downloaded. The download now runs in the background with a timeout.
- **Catalog posters no longer go blank.** Tiles that scrolled offscreen and back dropped their image with no retry; they now cache and reload reliably, on Apple TV too.
- **Plain-http custom streaming servers work,** including a server reached over a Tailscale address, which the network layer used to block.
- **The iPhone streaming server stays alive when the screen locks,** so audio keeps playing and the stream survives.
- **Add-on posters that are not 2:3 no longer look squished** on Home, and the Discover grid no longer drops cells when a catalog repeats a title across pages.

### Notes

- Landing next: an A/B loop, a frame grab to Photos, sharing a title, copy-all-source-links, a What's New sheet, and haptics.

## 0.3.1 - 2026-06-15

A bug-fix and polish pass on top of 0.3.0, driven by on-device testing across iPhone, iPad, Mac, and Apple TV. The headline wins: movies query every add-on again, and the embedded streaming server holds up on iPhone and Apple TV (debrid and torrent).

### Fixed

- **Movies now query ALL your add-ons (iPhone and Mac).** A title from a TMDB-based catalog carries a TMDB id, and stream add-ons keyed to IMDB ids were silently skipped for it, so only a couple answered. StremioX now resolves the title's IMDB id (the same one official Stremio uses) before requesting sources, so every add-on is queried. Apple TV was unaffected. If a movie still shows only a couple of add-ons, the Sources list names the ones that errored or returned nothing.
- **The embedded streaming server is harder to kill on iPhone and Apple TV, on debrid too.** On these platforms the server runs inside the app, and its memory footprint includes the player's read-ahead buffer, so even a debrid (direct) stream could push the whole app past the iOS/tvOS limit. The read-ahead is now smaller (128 MB, 96 MB on the 2 GB Apple TV HD) and the seek-back buffer trimmed, on top of the raised memory ceiling, fewer torrent connections, and the one-tap server restart in Settings.
- **Watched episodes tick again across a binge on Apple TV.** Auto-advancing through a season marked only the session's first episode watched; every episode now marks (the detail-page ticks update accordingly).
- **Source rows show the release filename again**, so you can tell "Part 1" from "Part 2" instead of just the quality tags.
- **HDR no longer washes out after an in-place episode switch.** Auto-advancing or skipping between two HDR episodes re-applies the HDR output reliably, instead of occasionally staying in SDR until a fresh replay.
- **Continue Watching, Next, and Previous now pick the best source, not the first to answer.** The player waits for add-ons to settle before choosing, so resuming or switching episodes lands on the quality you were watching (the 4K, not a stray 1080p), and the in-player Sources button reliably appears on a Continue Watching resume.
- **Continue Watching resume gets the in-player episode controls** (Next, Previous, and the episode list), the same as playing from the detail page.
- **Source rows no longer show the resolution twice** when an add-on is named after a quality.

### Added

- **Audio Passthrough**, now reachable both in Settings (Audio Output) and from the in-player Audio control: bitstream Dolby and DTS to an AV receiver that decodes them. Surround mode still decodes them to multichannel PCM, the fix for a soundbar that drops DTS to stereo.
- **Richer source rows**: the HDR variant (Dolby Vision, HDR10+, HDR10), audio (Atmos, TrueHD, DTS-HD), channel layout, and codec, matching what Stremio shows.
- **Local scrub-preview thumbnails**, captured while you watch, so dragging the seek bar shows a frame preview even without a server storyboard. Contributed by OrigamiSpace.
- **Scroll arrows on catalog rows** (Mac, and iPad with a pointer), so a long row is easy to page through without a trackpad swipe.
- **A bigger iPhone hero billboard**, and a sticky release group across episodes. Both iPhone and Mac keep the 0.3.0 translucent top bar (the immersive bleed treatments tried on each were reverted).
- **Binge continuity on Continue Watching**: resuming a series, and its in-player Next / Previous, now keep the same release group across episodes, not just the same resolution.

### Also fixed

- **The iPhone hero billboard rotates again** instead of occasionally freezing on one title after switching tabs.

### Notes

- A wave of new player and browse features (an in-player quality picker, a default external-player engine, an Up Next autoplay band, and more) is landing next.

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

The one that fixes the phone. beta 7's real-device testing surfaced an app-freezing sign-in bug and a cluster of iPhone-only layout breakage, and this is the fix pass for all of it.

### Fixed

- **QR / link sign-in no longer freezes and crashes the app.** On iPhone and iPad, finishing a QR sign-in could hang the whole app (no buttons, the phone itself lagging) and then crash. Root cause: the sign-in handler wrote a value that re-triggered itself in an unbounded loop on the main thread. It now runs exactly once. (macOS was unaffected: it has no main-thread watchdog, which is why it only showed on the phone.)
- **Discover and Library no longer render shifted off the left edge.** On iPhone the whole screen (hero, filter chips, poster grid) could be pushed left and clipped on both edges, intermittently. The content column now pins to the screen width instead of stretching to its widest row. Verified on device.
- **The streaming server stops crashing seconds after launch on iPhone.** The embedded server was starting subsystems the phone build never needs (a second HTTPS server and its certificate stack), inflating its memory footprint until iOS killed it. The iPhone/iPad build now runs the same lean configuration the official Stremio iOS app uses.
- **The Add-ons screen and Streaming Server screen fit the phone.** They were using the 10-foot Apple TV screen inset and a fixed 1000pt-wide field, so content spilled off the edge and the "Remove" button was squeezed to one letter per line. They now use a phone-appropriate inset, the field fits, and the button keeps its width.
- **The featured hero no longer shows a flat black band** while its backdrop loads or if that image fails. It falls back to the poster art underneath.

### Notes

- "None of the add-ons returned a playable source": this means no streaming or debrid add-on is installed. Metadata-only add-ons do not provide playable streams. Install a stream or debrid add-on from the Stremio web or mobile app and it syncs down.

## 0.3.0 beta 7 (prerelease) - 2026-06-13

The one that actually plays. beta 6 shipped with a macOS player deadlock, and this fixes it.

### Fixed

- **The macOS player no longer freezes the whole app.** Starting a video could hang the entire app (spinning beachball, even Quit dead) and require a force-quit. Root cause: mpv's video-output thread set the layer's HDR/EDR flag via a blocking hop to the main thread _while holding the Metal layer lock_, exactly as the main thread tried to take that same lock to size the drawable, a hard deadlock at the first frame. The EDR flag now updates without blocking the render thread, so playback starts cleanly. Verified end-to-end (open → play → controls → close) with a real video stream.

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
