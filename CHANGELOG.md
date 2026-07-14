# Changelog

All notable changes to VortX, newest first. VortX is Apple TV first, with an iPhone and iPad build alongside it. Dates are when each version was published.

What is planned next is in [ROADMAP.md](ROADMAP.md). To request a feature or report a bug, start a [GitHub Discussion](https://github.com/VortXTV/VortX/discussions) or [open an issue](https://github.com/VortXTV/VortX/issues).

## 0.3.13 - 2026-07-11

The community release, and the roll-up of the whole 0.3.12 test line (builds 167 to 174). Its headline is a player reliability series contributed by jbecker-it, his second contribution to VortX and his biggest yet, field-tested on real hardware: the pause-shortly-after-start crash is gone, watch progress saves on streams that never report a length, heavy scrubbing can no longer lose your place or falsely mark an episode watched, audio no longer distorts after big seeks or track changes, and Continue Watching updates the moment you stop watching. Alongside it, the Dolby Vision recovery line from builds 167 to 173, the launch profile picker and Liquid Glass from build 173, and a set of community-reported fixes: add-on HTTP and HLS streams now appear (#122), removed add-ons no longer ghost the Home customize list (#121), the diagnostic log saves without a QR code (#113), stream rows fit narrow iPhones (#118), and where-to-watch logos are legible everywhere (#95). In-place update, nothing resets.

### Added (pending next build)

- **Dolby Vision player parity, plus a mid-play engine switch.** Titles that route to the dedicated Dolby Vision player (the AVPlayer path) now reach feature parity with the built-in player: real scrubbing, periodic progress saves, resume from your last position, watched-at-the-end marking, skip intro or outro, and audio and subtitle track selection. The root cause of the missing behaviors was that a Dolby Vision remux serves an open-ended stream whose length the player could not read, so it treated the whole session as live and disabled everything length-dependent; the player now synthesizes the real duration from the remuxer. A new Player engine control in the in-player settings switches between the built-in player and the Dolby Vision player mid-title, carrying over position, track choices, and speed. Reviewed across six rounds. Apple TV, iPhone, iPad, and Mac.
- **Media servers: Plex, Jellyfin, and Emby.** Connect your servers (Plex PIN link, Jellyfin Quick Connect or password, Emby password) and their movie and show libraries join Home and Discover as catalog rows, while matched titles list your server's own copies as direct-play sources, ranked alongside everything else and badged per server. App-native by design: playback streams directly from your server, credentials stay in the Keychain and the encrypted sync channel, and with no server connected the feature is invisible and makes zero network calls. Matching is deliberately conservative (id-based with a guarded title-and-year fallback) so a wrong file can never impersonate a match. Direct play only for now; transcode negotiation is a later phase. Apple TV, iPhone, iPad, and Mac.
- **A real macOS surface pass.** The profile picker fits and centers all profiles, the Home hero scales to the window and the title-page hero reads near-fullscreen with the artwork pinned while episodes and sources scroll independently, the hero trailer autoplays again, and the player gained an in-app fullscreen toggle (Ctrl-Cmd-F) with a truly edge-to-edge picture. Mac.
- **Play from start on Apple TV.** Replays the exact same source from 0:00, never re-running source selection. Apple TV.
- **Watched badges on iPhone, iPad, and Mac.** The per-profile check badge and dimmed cover from Apple TV now appear on every Home rail and browse grid. iPhone, iPad, and Mac.
- **Batch downloads retry themselves.** A failed episode swaps in the next-best source automatically, once per episode, with honest status. iPhone, iPad, and Mac.
- **Decade catalog cover art**, picked daily from inside each list, served by the catalogs service. Apple TV, iPhone, iPad, and Mac.
- **Android: Phase A foundation, contributed by jbecker-it (#128), his fourth contribution.** The Android app went from a branded skeleton to a real engine-driven client: account sign-in, real catalogs and Continue Watching, add-on management, Discover, Library, Search, and full movie and series detail pages, all over the shared engine bridged through JNI, with a two-flavor build that keeps the Play-Store flavor GPL-clean (verified by APK inspection). Landed adapted onto the com.vortx.android identity with main-thread and credential-logging hardening. Android.
- **Smart Source Selection.** One panel in Settings > Streams gathers source filtering as chips: Prefer words (float matches up), Only words (keep nothing else), and Avoid words with a per-user choice of hiding matches or ranking them down, plus an opt-in auto-pick that starts the best match and a live preview that reorders a real source list as you type. Filters are per-profile and sync with the roster; Kids profiles always hard-hide avoided words regardless of the avoid behavior; the previously scattered filter rows folded into the panel. Apple TV, iPhone, iPad, and Mac.
- **Live TV playlists: M3U and Xtream.** Add an M3U playlist URL or an Xtream portal login and its channels appear in the Live tab with their XMLTV program guide, served through a hosted converter so the app treats them like any other live source. Registration validates the playlist up front, and removing a playlist revokes it everywhere. Apple TV, iPhone, iPad, and Mac.
- **External watch-state sync groundwork (dormant).** The plumbing for syncing watched history and progress with external tracking services ships in this build but stays entirely invisible and makes zero network calls until service credentials are configured in a later build.

### Fixed (pending next build)

- **A malformed source can no longer crash the app during ranking.** An add-on stream whose name advertised an absurd size or seeder count (far beyond any real release) could overflow an internal calculation and take the app down while a source list was being sorted, which happens on every source screen. Those figures are now clamped at the point they are read, so a single garbage or hostile entry ranks harmlessly instead of crashing. Scoring is unchanged for every realistic value. Apple TV, iPhone, iPad, and Mac.
- **Huge source lists stopped nudging the interface.** The debrid cache-check merge (which grows with services times sources) ran on the interface thread; it now runs in the background with the same ordering, so titles with thousands of sources scroll smoothly while their cached badges resolve. Artwork requests to VortX services also carry signatures now, groundwork for tightening the edge without breaking a single image. Apple TV, iPhone, iPad, and Mac.
- **The embedded streaming server survives Dolby Vision sessions.** Dolby Vision playback stacks a second full media pipeline into the same memory budget the in-app streaming server lives in, and 0.3.13's DV reliability work made that stack real for the first time: a demoted DV attempt could keep holding up to 128MB for another ten to twenty seconds while the built-in player re-opened the same 4K stream on top of it, and the process footprint ratcheted upward after every DV era, so the system could quietly kill the server (or the whole app) on a later torrent play. Cancelling a DV attempt now aborts its network reads within milliseconds and frees its buffer immediately, an attempt still being judged holds far less memory up front, the server re-trims its caches after every DV session, and a server death is now recorded into the exportable diagnostics log (URLs scrubbed) so a field report can finally show one. From a fleet report against 0.3.13. Apple TV, iPhone, iPad, and Mac.
- **The app no longer force-closes at launch when a catalog title contains a percent sign.** The Home hero's diagnostic logging passed addon-supplied titles straight into the log's format position, so a title carrying a % was read as format specifiers and crashed the app before anything drew (EXC_BAD_ACCESS in the hero's enrichment, the exact stack a community crash report captured). All three hero log sites now pass content as values, never as format, and a sweep of the same pattern across the whole app is underway. Fixes #127; thanks to konrepo for converting and attaching the crash log that pinned it. iPhone, iPad, and Mac.

### Fixed (build 176)

- **Scrub-preview uploads stop spamming doomed attempts.** A field log showed 15+ upload failures in one session; the server was healthy and the real watches stored fine, but the client fired an upload every minute from the second frame onward, each predictably declined below the sharing threshold and logged as a failure. The client now predicts the threshold with the server's exact formula and skips only what would certainly be declined, failing open whenever the duration is unknown; the log distinguishes a skip from a real failure. From the same field log as the Dolby Vision series. Apple TV, iPhone, iPad, and Mac.

- **Live channels and sport events can always navigate back on iPhone, iPad, and Mac.** Live-type detail pages had no back affordance (the hero chrome was only overlaid on movie and series pages), edge swipe-back was dead on every hidden-bar detail page, and the Live tab ignored the re-tap that pops other tabs to their root; the only escape was force-quitting. Live pages now wear the standard back chrome, a guarded swipe-back gate restores the edge gesture on all detail pages (refusing during running transitions so it can never corrupt the stack), and the Live tab pops to root on re-tap. Fixes #125. iPhone, iPad, and Mac.
- **The Dolby Vision reliability series from a field diagnostic log (#76).** Five fixes, each pinned by a viewer's exported log: a stalled packaging step (an audio track the muxer cannot parse starving the stream header, previously a silently discarded error) now fails over in about a second instead of twenty; a failed source no longer locks the remaining sources of the title out of Dolby Vision when the viewer picks another (automatic hops stay conservative); an instantly rejected healthy stream gets one automatic retry, with the startup playlists now answered atomically and every serve logged; MP4 files with hev1 or dvhe sample entries are repaired through the remux lane (rewritten to the form Apple's player renders) instead of playing audio over a black screen; and the TV display-mode switch fires only after a stream is confirmed Dolby Vision, with a teardown guard so an abandoned load can never switch the panel after exit. Apple TV, iPhone, and iPad.
- **Raw subtitle metadata no longer appears at the start of subtitle lines.** Builds 0.3.9 and 0.3.10 uploaded community-pool subtitles where comma-less cues fell back to the raw event row (the "0,0,Default" prefixes a viewer reported), and nonstandard subtitle formats could leak fresh; the extractor now splits by each file's own declared format, the display pass strips all seven known leak shapes behind a conservative per-file vote (verified with zero residual against the actual affected pool files), and the verification harness ships in the repo. A server-side cleanup of the old pool entries is prepared separately. Part of #76. Apple TV, iPhone, iPad, and Mac.
- **The Apple TV Home screen loads the whole catalog board.** Home never requested more of the engine's board beyond the first window, capping users with many add-on catalogs at about thirty rows; scrolling near the last section now pages the rest in, in both rails and the poster wall. Apple TV.
- **Source filters follow their profile faithfully.** Filter edits are captured to the active profile as they happen (previously only order changes were), live settings are captured before any profile switch can touch them, and switching to a profile that never recorded a filter applies the documented default instead of silently inheriting the previous profile's values. Apple TV, iPhone, iPad, and Mac.
- **The Android debug build compiles and ships artifacts again.** A dependency's newer Kotlin metadata crashed the compiler, which had masked a real error in the ExoPlayer fallback engine, and the CI artifact glob silently matched nothing after the flavor split; all three fixed. Contributed by jbecker-it in #124, his third contribution. Android.

### Added (build 175)

- **Watched badges on Home and catalog covers (build 175).** The Library's check badge and dimmed cover now appear on every Home rail and browse grid on Apple TV, per profile: the owner reads the engine's own watched bookkeeping (including titles marked watched straight from a catalog), overlay profiles read only their private history, and the lookup is a read-only index that never writes anywhere. Requested in #111's follow-up. Apple TV.
- **Batch season and episode-range downloads (build 175).** Download Season, multi-select, and per-episode badges on the episode list; a sequential resolver picks each episode's best source with the exact ranking a manual download uses, including the debrid search and community pool through their existing rate-limit-safe paths, one resolution in flight at a time; skips are honest and listed, an interrupted batch reports what was left, and Stop works mid-resolve. Fixes #119. iPhone, iPad, and Mac.
- **Offline mode (build 175).** A shared connectivity monitor drives a quiet offline banner on every platform, and an offline launch lands on Downloads (iPhone, iPad, Mac, with Settings as the no-downloads fallback) or the Library (Apple TV). The launch verdict is confirmed before it can route (a Wi-Fi still reassociating at cold launch can never misroute a healthy session), the routing never fires once you have navigated, and mid-session changes only show the banner. Fixes #120. Apple TV, iPhone, iPad, and Mac.
- **Source filters: minimum quality floor, hide unknown quality, preferred audio languages only (build 175).** The floor drops only sources whose parsed quality is known and below it; unknown-quality sources are kept unless the new hide-unknown toggle is on; the audio filter drops only releases that positively advertise a different audio language (subtitle-only labels like korsub or vostfr never trigger it), and the footnote says exactly that. All three sync per profile and to the dashboard like the existing filters. Part of #117. Apple TV, iPhone, iPad, and Mac.
- **Compact source rows (build 175).** A display toggle shows the parsed quality line instead of raw release names, on both the phone and TV source lists. Part of #117. Apple TV, iPhone, iPad, and Mac.
- **Tab bar customization (build 175).** Live, Discover, Library, and Search can each be hidden; Home, Add-ons, and Settings are always present. Hidden tabs unmount (their background work stops), selection heals to Home if the active tab is hidden, the Mac search shortcuts and the offline landing never route to a hidden tab, and the old Show Live TV toggle migrates in. Part of #117. Apple TV, iPhone, iPad, and Mac.
- **A poster-wall layout option for Home on Apple TV (build 175).** Each catalog renders as a vertical poster grid with its header kept, paging in more titles as focus nears the end; Continue Watching stays a rail in both layouts, and each wall is its own focus section so the remote steps predictably between sections. The rails stay the default. Fixes #105. Apple TV.
- **A trailer that cannot play in-app offers the YouTube app on Apple TV (build 175).** The failure path hands the same trailer id to the YouTube app (long-press the trailer button to go straight there), the language-preferred id carries over, and the unavailable note only shows when both paths fail. Part of #95. Apple TV.

### Fixed (build 175)

- **Streaming services no longer vanish when a region lists them under an ad-supported or free tier (build 175).** The catalog queries now cover subscription, ads, and free monetization together (rent and buy stay excluded), verified live against the catalog source: the query can only ever add titles, and free services like Tubi and Pluto TV stop showing near-empty catalogs. Hardens the #114 case beyond the 0.3.13 id-family fix. Apple TV, iPhone, iPad, and Mac.
- **The Home section headers are localized in every app language (build 175).** Sixteen header strings (Continue Watching, Top Picks for you, Upcoming Episodes, Streaming, Genres, Top New, and the rest) were defined as raw English and rendered verbatim; they are now defined through the localization catalog with translations in all 106 app languages, reconciled against the terms the app already uses (the Continue Watching shelf keeps its established name in every language), and the Discover hub headers took the same fix. Part of #95. Apple TV, iPhone, iPad, and Mac.
- **A native Dolby Vision title that plays audio over a black screen now falls back to the built-in player (build 175).** A watchdog on the Dolby Vision lane demotes after 8 seconds of advancing audio with zero video frames, corroborated by the player layer's own displayed-frame signal so a slow first frame can never false-trigger, once per title, and the next episode always gets a fresh shot at true Dolby Vision. The demote records its evidence in the exportable diagnostics log. Part of #76. Apple TV, iPhone, and iPad.
- **Audio no longer defaults to a random dub when your language is missing (build 175).** A title with no audio track in your chosen languages now falls back to English before giving up to the container's first-listed track, on both player engines; commentary tracks are excluded from the fallback, and subtitles still auto-enable in your language over the fallback audio. From an Apple TV field report. Apple TV, iPhone, iPad, and Mac.

### Fixed (build 174)

- **Pausing a video shortly after starting it no longer crashes the app.** mpv keeps filling its forward cache while paused, so a pause right after start parked the app at peak memory exactly when the tvOS screensaver started its own 4K pipeline, and the system reaped it. After 60 seconds of continuous pause the player trims its read-ahead and frees the buffered data (restored the moment you resume), and it now answers the system memory warning on both player lanes, with every step in the exportable diagnostics log. The freed cache is re-anchored with an exact seek so the paused picture never moves. Contributed by jbecker-it in #123. Apple TV, iPhone, and iPad.
- **Watch progress now saves on streams that never report a duration.** Many debrid direct-HTTP MKVs never deliver the duration event, and resume, the periodic saves, watched-at-the-end, and Up Next all gate on it, so exactly those titles always restarted from 0:00. The duration is now polled from the engine once playback ticks and routed through the same handling. Contributed by jbecker-it in #123. Apple TV, iPhone, iPad, and Mac.
- **Heavy scrubbing can no longer save a stale position, wipe an episode's progress, or falsely mark it watched.** Committed scrubs hold their target until the player lands there (stale position ticks from before the seek are ignored), the scrub clamp lands a few seconds before the end so only natural playback reaches the finished-episode path, and the watched mark needs a few settled seconds near the end instead of a fly-by. Contributed by jbecker-it in #123. Apple TV.
- **Audio no longer distorts, with playback lagging, after a big seek or an audio or subtitle track change.** Resuming instantly on an emptied forward cache made the audio output underrun repeatedly; the player now takes one short honest buffering pause scoped to exactly those seeks (ordinary playback starts are untouched and stay fast), plus a little extra audio buffer slack. Contributed by jbecker-it in #123, scoped to seeks and track changes on our side. Apple TV.
- **A watched toggle or background sync no longer resurrects an ancient playback position.** The engine's own progress copy is now kept in step at pause and at scrub commits, so an engine-side push can never carry a stale position over newer saves. Contributed by jbecker-it in #123. Apple TV, iPhone, iPad, and Mac.
- **Continue Watching updates right after you exit playback, and an immediate reopen resumes at the right place.** The exit flush now completes the final save and then refreshes the engine's library in order, and a resume where the engine has no usable answer consults the account record, which matches the exact episode. Contributed by jbecker-it in #123. Apple TV, iPhone, iPad, and Mac.
- **Add-on HTTP and HLS streams now appear in the source list.** stremio-core exposes two stream surfaces, and streams embedded in the catalog entry itself (the shape live-TV style add-ons use) were never read, so those add-ons listed zero sources. Both surfaces are now decoded and merged, with exact duplicates dropped and everything else preserved. Fixes #122. Apple TV, iPhone, iPad, and Mac.
- **A removed add-on no longer ghosts in the Home customize list.** Removing an add-on records a durable tombstone but deliberately leaves the account collection intact, and the customize list enumerated the raw engine profile, so the removed add-on's catalogs persisted forever with no way to clear them. The list and the Home rows now honor the tombstones, hidden and order preferences are preserved so a reinstall restores your arrangement, and the catalog loading window now also covers rows sitting behind a profile-disabled add-on. Fixes #121. Apple TV, iPhone, iPad, and Mac.
- **Stream-row badges no longer overflow the screen on narrow iPhones**; the quality and add-on badges scroll instead, with wide layouts unchanged. Fixes #118. iPhone.
- **Where-to-watch service logos now sit on a light plate on every platform**, so dark marks no longer vanish into the dark background; both platforms share the same inset token. Part of #95. Apple TV, iPhone, iPad, and Mac.

### Added and Changed (build 174)

- **Save or share the diagnostic log directly, no QR code or second device.** Settings on iPhone, iPad, and Mac gained a Save or share log control next to the existing QR export: straight to Files, AirDrop, or Mail, and it works whenever the log has content, even after Diagnostic logging is switched back off. Apple TV keeps the QR flow. Fixes #113.
- **Signed-out sessions skip the exit library sync**, so a device without an account no longer issues a dead sync request after every playback.

### Added (build 173)

- **Who's watching, the profile picker, now appears on iPhone, iPad, and Mac (build 173).** Apple TV already asked which profile to use at cold launch when you keep more than one; iPhone, iPad, and Mac had the profiles and the switcher but never presented that launch picker, so a shared device opened straight into whoever was last active. The same shared picker now presents at launch on iPhone and iPad as a full-screen cover and on Mac as a centered sheet, gated on having more than one profile and nothing playing, and the rest of the app is held hidden behind the brand canvas until a profile settles, so no one's Continue Watching or library flashes before the choice is made. Selecting a profile routes through the same path Apple TV uses, so the owner profile keeps reading and writing its history through the engine and account while each overlay profile keeps its own private local history and never touches the account library. Switch Profile in Settings re-presents the picker, unchanged. iPhone, iPad, and Mac.
- **Liquid Glass on the floating controls, on the systems that support it (build 173).** On the latest Apple systems the floating chrome that sits over content, the player transport buttons, the back and options discs on a title's hero, and the in-player pills, now uses Apple's Liquid Glass material instead of a frosted panel. Every use is gated to the newest systems and falls back to the current frosted material and tint on earlier ones, and it falls back the same way whenever Reduce Transparency is turned on, so the controls stay readable for everyone. Glass is applied only to chrome that floats over content, never to posters, cards, lists, or a page background, and layout and behavior are unchanged. Apple TV, iPhone, iPad, and Mac.

### Fixed (build 172)

- **Streaming brands now show their full catalog, and you can choose which services appear (build 172).** A brand can be listed under several ids at once (regional variants and paid tiers, for example Paramount+ plus its Premium and Essential tiers, or a service listed under a different id in one country than another), and only a single id was being queried, so a brand like Paramount+ returned a handful of stragglers or dropped out of the region list entirely. Each brand now derives its whole family of ids automatically by inverting the id-alias table, and asks for the family together, so the full catalog fills in, in every region, and a brand that a country lists under a non-default id (Prime Video in the Netherlands and India, Discovery+ in Great Britain) is no longer empty. The same family is used on the Home streaming rails, so the Home row for a brand matches its hub. A new list in the streaming section lets you pick exactly which services appear and reorder them; leaving it untouched keeps the automatic region list byte-for-byte as before. Closes the reported missing-Paramount+ case. Apple TV, iPhone, iPad, and Mac.
- **Continue Watching now advances the right title after you play a download or a pasted link (build 172).** Those plays never load the engine's playback model, and it was not being torn down between titles, so their progress ticks landed on the previous title you still had open and moved its position. Closing one of those players now tells the engine to unload the playback model, so each title keeps its own place. Apple TV, iPhone, iPad, and Mac.
- **A removed title or add-on is even less likely to come back after an update or on a device that was offline for a while (build 172).** The list that keeps a removal now carries a timestamp per item, so when two devices disagree the most recent action wins by the clock instead of one blindly overriding the other, and a device returning after a long gap can no longer resurrect something a newer removal already took out. Installed add-ons are stamped as present before any stale web-side removal is folded in, so upgrading a device that still has an add-on the account removed elsewhere no longer reinstalls it, and a fresh install of an add-on is no longer undone by an old web removal. Adding something again clears its removal, unchanged. Your other titles and cross-device Continue Watching are untouched. Apple TV, iPhone, iPad, and Mac.
- **Sources are ordered more accurately (build 172).** A release that advertises only foreign subtitles (labels like korsub, vostfr, legendado) was being read as foreign audio and demoted, even though it is usually the original audio with those subtitles; it now keeps its place while those labels still drive subtitle selection. A torrent whose title contains a word like Instant (as in the film Instant Family) no longer shows a false Cached badge, and a trailer no longer leaks into the quality picker. The ranking weights that decide source order are otherwise unchanged. Apple TV, iPhone, iPad, and Mac.
- **The in-player fixes on Apple TV: switching source now plays the source you switched to, and a few edge cases are tightened (build 172).** When a Dolby Vision source mounted but could not show its first frame and the player stepped down to the built-in engine, it was reloading the title you originally opened rather than the source you had switched to in the meantime, so it could play the wrong stream; it now reloads the source that is actually selected, at your position. Exiting a Dolby Vision title whose resume was intentionally started from the beginning no longer moves your saved resume point backward. The automatic source-recovery time limit is no longer reset by the app's own automatic source hops (only by a source you pick yourself), pressing Next twice quickly can no longer start two episode loads at once, and a runtime value from a misbehaving add-on can no longer overflow. Apple TV.
- **Dolby Vision holds its stream better on long plays (build 172).** The Dolby Vision lane keeps a small window of already-delivered video in memory so the player can re-read the current position; that window is now held to at least two full segments and captured once when playback starts, so a long title can no longer evict a segment the player is still reading (which would drop the picture to HDR10 partway through), and the window setting is no longer re-read on the hot path. The Dolby Vision display-mode step also settles immediately when the TV is already in the right mode, instead of waiting out a timeout on every start. Apple TV.
- **Smaller fixes (build 172).** iPhone Home now refreshes on real Continue Watching and library changes instead of on background-sync churn; browse posters load through the shared image pipeline; the tvOS browse category spinner no longer strands after a switch; an iPhone hero image no longer holds on after leaving a category; and on Mac you can now remove a service from your chosen list. Apple TV, iPhone, iPad, and Mac.

### Fixed (build 171)

- **Opening a title with several thousand sources no longer freezes or closes the app (build 171).** The most popular titles can return a few thousand sources across add-ons, debrid, and the community pool. The ranked source list itself is built off the main thread, but the text cache underneath the ranking (the one that holds each source's normalised name for scoring, quality, size, and language) was capped at 4096 entries while the score cache above it had already been raised to 32768. Past about 4096 unique sources that cache cleared and refilled on every pass, turning every per-source text read into a full rebuild and saturating the main thread until the system's watchdog closed the app: the difference between a two-thousand-source title that only lagged and a four-thousand-source title that crashed. The text cache now matches the score cache at 32768, and a related score-cache path that skipped memoisation for debrid-cached sources now caches both variants under distinct keys instead of re-scoring every cached source on each pass. Deeper structural work to keep very large lists smooth (moving language detection off the main thread, coalescing per-add-on refreshes, and windowing the rendered rows) follows in the next build. Apple TV, iPhone, iPad, and Mac.
- **More Dolby Vision MKVs now play as true Dolby Vision instead of falling back to HDR10: large hybrid Atmos remuxes, and sources whose debrid link errors on the very first open (build 171).** Build 170 fixed the player's variant filter, but two narrower paths still dropped a Dolby Vision MKV to HDR10. First, on some 4K hybrid TrueHD/Atmos Dolby Vision remuxes the rebuilt stream's header (its `moov` box, which carries the video and audio setup) grew past the in-memory buffer the muxer holds it in, and because that buffer could not be rewritten in place once the header had spilled out of it, the header shipped with an unwritten length field: the local Dolby Vision stream never finished starting, so the player waited out the timeout and demoted. The remux now gives the muxer a real seek-and-patch path over the produced bytes (a write-seekable custom stream), so the header's length fields are always corrected no matter how large the header grows, and the setup segment is now read back from the produced bytes rather than a fixed-size scratch copy, so header size is no longer a ceiling at all. Second, a debrid link that answered the very first open with a transient HTTP 400 (a CDN still pulling the file into cache) was given up on at once, even though the same link opens on an immediate retry; the single warm-up retry that already covered a first-open timeout now covers that transient HTTP error too. Both stay fully fail-soft: a source that genuinely cannot play as Dolby Vision still steps aside to the built-in player, and the exportable diagnostics log now records the actual header size on the rare occasion the setup segment still cannot be indexed. Apple TV.
- **Crashes now write a report into the exportable diagnostic log, so they can be diagnosed without a Mac (build 171).** A sideloaded Apple TV has no reachable way to hand its `.ips` crash reports to anyone, so until now a crash just made the app vanish with nothing in the log to explain it. The app now installs its own handlers for uncaught exceptions and the fatal signals (SIGABRT, SIGSEGV, SIGILL, SIGBUS, SIGFPE, SIGTRAP; SIGPIPE is ignored). When one fires, a tiny marker with the signal name, the time, and a stack backtrace is written into the app container using only crash-safe operations (a pre-opened file, raw writes, and the system's signal-safe symbolizer, with no memory allocation on the dying process), and then the crash is re-raised so the operating system still records its own report. The next launch folds that marker into the same rolling diagnostic log you already export over Wi-Fi and QR on Apple TV and iPhone, or into Downloads on Mac, tagged as a crash with its backtrace, and clears it so it reports once. The capture itself always runs; folding it into the exportable log follows your Diagnostic logging setting, exactly like the rest of that log, and a crash captured while logging was off is kept for a later run with it on. Apple TV, iPhone, iPad, and Mac.
- **Community (Singularity) sources now reliably appear in the source list (build 171).** The community pool answered in about half a second, but the screen component that requested it was often replaced before the answer landed (a title's details still settling, the player opening over the page, or a navigation away and back), and the fetched sources were discarded along with it, so the Singularity group never showed even when the pool had corroborated sources for the title. Fetched community sources are now kept for the whole app session, keyed to the exact title they belong to: the list that is actually on screen receives them, and reopening a title paints its community sources instantly while a fresh fetch still refreshes them in the background. A source for one title can never appear on another, the sign-in and Singularity toggles gate everything exactly as before, and each source still resolves through your own debrid or TorBox account. Apple TV, iPhone, iPad, and Mac.
- **On Apple TV, the Watch button now holds one position on every movie, and focus can always move back up to the top bar from it (build 171).** The movie detail page sizes its first screen to one TV viewport and pins the Watch and sources band to the bottom of it, so the button is fully visible on open. That pin only held while the content above it fit one screen: a long synopsis grew the title block past a full viewport, which pushed the Watch button further down than on a short-synopsis title, and once the page had grown that tall the band scrolled into a region the tvOS focus engine could not project back up from, so pressing Up from Watch no longer reached the navigation bar (the same upward focus-trap class an earlier build had already closed, reopened here by the overflow). The synopsis is now held to a fixed three-line height whatever its real length, so the block above the band no longer changes size with the title and the first screen can no longer overflow into that scrolled state. The Watch button lands in the same spot on every title, it keeps initial focus as before, and the upward path from Watch to the tabs is preserved. The clamp is line-limited and non-focusable, so nothing about focus or playback changes. Apple TV.
- **Ratings now show on the details page on Apple TV, with Metacritic added on every surface (build 171).** Apple TV had its ratings row wired to the optional MDBList key only, so unless you had set your own key it showed nothing, while iPhone, iPad, and Mac already read VortX's own keyless ratings service. Apple TV now uses that same keyless service first (IMDb, Rotten Tomatoes, Metacritic, and TMDB, with no setup) and only reaches for your MDBList key to fill anything it did not return, so an IMDb, Rotten Tomatoes, and Metacritic line appears under the title for everyone. Metacritic is new on every surface: the shared ratings model and both the VortX and MDBList clients had been passing the Metacritic score through unread, so it is now decoded and shown on iPhone, iPad, and Mac too. The row is display-only and sits in the meta area, so it never disturbs the Watch button or its focus. Apple TV, iPhone, iPad, and Mac.
- **A title you remove from Continue Watching stays gone after an update, instead of coming back (build 171).** When you dismissed a title from Continue Watching (or removed it from your Library), the removal synced to your account, but a later sideloaded update could bring it back. On an update the local engine can come up empty for a moment, and the account then re-adds every title it remembers, with no record that some of them had been removed, so a dismissed title reappeared with its old progress. Removals are now recorded in a durable list that syncs with your account (the same mechanism that already keeps a removed add-on from coming back), so a removed title is subtracted from what the account re-adds and is skipped when a fresh device rebuilds your library, on every device. Removing a title on one device now also pushes that removal right away, and finishing or rewinding a title does too, so the change is saved before an update can interrupt it, and it is given a short grace window to finish when the app moves to the background. Adding the same title again later clears its removal, so nothing is stuck out of your library. Your other titles and cross-device Continue Watching are untouched. Apple TV, iPhone, iPad, and Mac.

### Fixed (build 170)

- **True Dolby Vision now plays on Apple TV instead of always falling back to HDR10, because the local stream is no longer rejected by the player's variant filter (build 170).** The app streams Dolby Vision to Apple's player as local HLS, and that stream listed a single video option tagged with an explicit Dolby Vision (HDR) range. Apple's player filters out any explicitly-HDR option when it cannot yet prove the output is in an HDR mode at the instant it reads the list, and with only one option that left zero it could play, so it failed the whole stream with an unsupported-URL error and dropped to HDR10 on the built-in player. This was the real cause behind the "loads then just plays HDR" reports, and it was pinned down with a byte-exact off-device reproduction: the range tag alone triggered the failure, while an untagged copy of the very same stream was accepted, and neither the bitrate nor the codec tier mattered. The stream now offers a second, plain (untagged) option pointing at the identical video and segments, so a playable option always survives the filter, while the Dolby Vision picture, its in-frame dynamic metadata, and VortX's own request to switch the TV into Dolby Vision still drive what you see. Because an accepted stream now has to finish opening before its first frame, the player also waits a little longer, about twenty seconds, for a Dolby Vision remux specifically, before falling back. It stays fully fail-soft: a source that genuinely cannot play as Dolby Vision still steps aside to the built-in player quickly, with the reason recorded in the exportable diagnostics log, and every Dolby Vision HLS request is now written to that log too. Match Dynamic Range must be on in tvOS Settings, Video and Audio, Match Content. Apple TV.

### Fixed (build 169)

- **The next episode auto-plays again after you resume a show from Continue Watching on Apple TV (build 169).** An episode would play to the end and then exit to Home instead of rolling into the next one. On the Continue Watching direct-resume path the player was launched without its episode list and had to backfill it in the background; on this build the heavier Dolby Vision startup work could win that race, leaving the list empty at the end of the episode, so a mid-season episode looked like a series finale and the player exited. The list is now fetched before the player starts (the same way iPhone, iPad, and Mac already did it), so auto-advance always knows the next episode. A last-chance re-check at the end of an episode covers a genuinely slow list, and a second match on season and episode covers a resume whose saved id no longer matches the freshly loaded list. The last episode still ends the title, movies still stop when they finish, Watch Credits still plays out then stops, and a live stream still reconnects. Apple TV.
- **Add-on and community subtitles now auto-select in your language, including on titles opened from the VortX catalogs (build 169).** When a video carried no built-in track in your first or fallback subtitle language, an installed subtitle add-on (or a matching community subtitle) that did have it was fetched but never turned on, so subtitles stayed off. Three things were at fault: titles opened from our own catalogs are keyed by a `tmdb:` id that OpenSubtitles-class add-ons cannot answer, so the add-on query came back empty; they are now resolved to their `tt` identity (using the same cached resolver the trickplay feature uses) before subtitles are fetched. Community-pooled subtitles were also running under a wrong identity for those titles and never re-checked your language when they arrived; they now resolve to the right identity and take the language chain too. And a subtitle you pick yourself, or Off, is now always kept: a list that lands a moment later can no longer override your manual choice. Fully fail-soft: an unresolvable title behaves exactly as before. Apple TV, iPhone, iPad, and Mac.

### Fixed (build 168)

- **Back on the Siri Remote steps back one screen at a time on Apple TV, instead of jumping to Home from any depth (build 168).** The shell installed a single Back handler on the tab container that fired at every push depth on a non-Home tab and ran "go to Home", which discarded the whole navigation stack (an earlier fix had assumed a pushed page kept a deeper responder to pop one level first; none existed). Back is now depth-aware: when the active tab has a page pushed it pops exactly one level, the same step the system already performs on the Home tab, and it returns to Home only from a tab's first screen. Back at the Home root still leaves the app, and re-selecting a tab still scrolls to top. Fixes #112. Apple TV.
- **Watched titles now show it on their poster in your Library (build 168).** A watched title gets a check badge and a dimmed cover, matching the episode list, so Mark as Watched from a long-press (or finishing a title) now has visible feedback and Mark as Unwatched clears it. It reads the engine's own watched bookkeeping for the owner profile and each overlay profile's private history for its own, so every profile sees only its own marks and an overlay profile never touches the account library. Other rails and the catalog grids are unchanged. Fixes #111. Apple TV.
- **Back now dismisses the Skip Intro pill instead of exiting the player (build 168).** With the Skip Intro, Skip Recap, or Skip Credits pill showing, pressing Back exited the whole player to stream selection, because the Back handler never checked whether a pill was up (only Select did). Back now dismisses a visible pill and keeps playing, the same dismiss-not-exit precedent as the Up Next band; a second Back with no pill up exits exactly as before, and seeking back into the intro brings the pill back. Apple TV.

### Fixed (build 167)

- **Dolby Vision from an MKV now actually reaches the screen as true Dolby Vision (build 167).** Build 166's local-HLS delivery was correct in shape but stumbled at the last step on real files: it advertised the video at a codec tier Apple's player rejects for Dolby Vision, so the player refused the stream and dropped to HDR10 on most 4K Dolby Vision files; and on some files the rebuilt header outgrew an internal buffer and shipped invalid. Both are fixed (the codec signaling now uses the tier Apple accepts, and the buffer is large enough that the header is always written correctly), so a Dolby Vision MKV now plays as true Dolby Vision instead of tone-mapping to HDR10. Fully fail-soft as before. Apple TV.
- **The streaming server no longer strands your session Offline after a fast relaunch (build 167).** When the previous instance was still shutting down, the embedded server could quietly move to a nearby port, but the app only ever looked at the original one, so Settings showed Offline and torrents were refused even though the server was healthy. The app now discovers and follows the server's real port and heals a stuck session on its own, and it raises its own open-file limit so a heavy torrent session no longer causes instant "load failed" errors. Apple TV.
- **Lower memory use during playback (build 167).** Apple's player was keeping an unbounded read-ahead buffer of the Dolby Vision stream, a large hidden contributor to the memory pressure that could get the app killed on Apple TV mid-session. It is now capped.

## 0.3.12 - 2026-07-08

The Dolby Vision and reliability release. It rolls up the whole 0.3.11 test line (builds 155 to 166). Headline: Dolby Vision from an MKV now plays as true Dolby Vision through Apple's player, delivered as local HLS, the only delivery Apple TV accepts for Dolby Vision, after the root cause turned out to be the delivery format rather than any header repair. Alongside it: the Apple TV playback stutter is gone, a slow Dolby Vision source now falls back fast instead of making you wait, audio and subtitle languages gained a fallback chain, and the reliability, security, and add-on work from the 0.3.11 betas. In-place update, nothing resets.
### Added

- **Dolby Vision from an MKV now plays as true Dolby Vision through Apple's player, delivered as local HLS (build 166).** Dolby Vision on the Apple TV had been failing for a structural reason no header fix could solve: tvOS and AVFoundation only decode Dolby Vision through HLS, never through a progressive file, and the app was handing Apple's player a progressive fragmented MP4. On real devices that meant the player either refused the stream ("Cannot Open") or accepted it and never produced a picture, then dropped to HDR10 after a wait, which is exactly what testers saw. The app now serves the same rebuilt video to the player as a local Dolby Vision HLS presentation from 127.0.0.1 (the init segment, one-second segments, and a playlist carrying the Dolby Vision codec, supplemental-codec, and PQ range that the file classifies to), which is the only delivery Apple TV accepts for Dolby Vision. It is fully fail-soft: if the local server cannot start, the remux fails, or the player never produces a frame within about ten seconds, it falls back to the built-in player (HDR10) exactly as before, and a remote switch can disable the new lane instantly. Dolby Vision still requires Match Dynamic Range ON in tvOS Settings, Video and Audio, Match Content. Apple TV.
- **A slow Dolby Vision source now falls back fast instead of making you wait (build 166).** An earlier build tried to give a still-loading Dolby Vision stream up to a minute before giving up, which just made you wait a full minute for the same HDR10 fallback. The player now steps aside to the built-in player in about ten seconds when the Dolby Vision lane is not producing a picture, so opening a stream feels fast again. Apple TV.
- **Audio and subtitle default languages gained a fallback chain, and add-on subtitles are auto-picked by language (build 166).** Each of the Audio language and Subtitle language settings now takes a first choice and a fallback, in any language, so when a title has no track in your first language the player uses your second choice instead of loading nothing. The subtitle fallback applies to both embedded tracks and add-on subtitles, and add-on subtitles are now auto-selected by your language chain (they were not before). A "Match audio to subtitle languages" option drives both from one list. Turkish, Dutch, Polish, and Swedish were also added to the language lists. iPhone, iPad, Mac, and Apple TV.
- **Playback on Apple TV no longer stutters or slows the whole app down over a long session (build 165).** The tvOS player re-decided which engine to mount (libmpv vs Apple's player) inside the SwiftUI view body, which re-evaluates several times a second during playback, and it wrote a diagnostic route line on every pass. On a long 4K session that piled up into hundreds of identical log lines plus real main-thread cost under memory pressure, felt as stutter and general sluggishness (reported on #76 for builds 163 and 164). The engine is now latched once when a stream starts, exactly the fix iPhone, iPad, and Mac already shipped, so the route is computed and logged one time per stream instead of once per render. Apple TV only; the routing decision itself is unchanged.
- **A Dolby Vision MKV that mounted and then failed with "Cannot Open" now plays as true Dolby Vision, or steps aside instantly with the reason recorded.** Apple's player requires an HEVC video's setup data (its parameter sets) to ride in the stream's header, but some rips, typically web-sourced single-layer Dolby Vision files, carry that data only inside the video frames themselves, and the on-device remux silently produced a header with an empty setup record: the movie mounted, Apple's player refused it with "Cannot Open", and only after that failed mount did playback drop to HDR10. The remux now validates the header up front; when the setup data lives in-band it rebuilds the header from the first video frame, so those files play true Dolby Vision now, and when no usable setup data exists at all it fails over to the built-in player immediately (the same fast, clean fallback a wrong-profile file already gets) instead of after the failed mount. The Dolby Vision configuration box on stream-copied Profile 5 and 8 files also has its structural markers normalized to the shape Apple's player validates (repairing the malformed enhancement-layer and level markers a hybrid rip can carry), while the copied video's own Dolby Vision metadata is left exactly as the source wrote it, so the box never disagrees with the untouched bitstream. The exportable diagnostics log now records the produced video header's exact shape on every Dolby Vision play, so one export pins any remaining refusal. Files that play today pass through byte-for-byte untouched. Apple TV, iPhone, iPad, and Mac.
- **The Dolby Vision display-mode request now asks the Apple TV for real Dolby Vision, not HDR10.** Two long-hidden causes are fixed. First, the request itself was wrong: it was built with a mode number from years-old tvOS data, and on current tvOS that number means HDR10 (and the number used for HDR10 means HLG), so even a healthy true-Dolby-Vision session was literally asking the TV for HDR10. The request is now built through Apple's public display-criteria API with a genuine Dolby Vision video descriptor (readback-verified: Dolby Vision reads back as its own mode), with the old integer path kept only as a corrected fallback. Second, the request now fires BEFORE the video is attached, the order Apple's player guidance requires, and it now covers every true-Dolby-Vision route: a native Dolby Vision MP4, MOV, or HLS stream, which previously never asked the TV to switch at all, now switches too. Match Dynamic Range must be on in tvOS Settings, Video and Audio, Match Content. Plain HDR10 and SDR content is unchanged. Apple TV only.
- **Resuming a Dolby Vision title no longer silently downgrades it to HDR10 with plain surround.** The true-Dolby-Vision lane rebuilds the movie on the fly and can only produce it from the beginning for now, but a Continue-Watching resume immediately jumped the player into a position that had not been produced yet: no picture could ever arrive, and after twenty seconds the player silently fell back to the built-in player, HDR10 video and plain multichannel audio instead of Dolby Vision and Atmos, on every second and later watch of the same title. A resumed Dolby Vision title now starts from the beginning with a short on-screen note, your saved resume point is kept safe (progress saves cannot regress it until playback passes it again), and the exportable log records the exact reason any time this lane still falls back. Native resume on this lane is a planned follow-up.
- **The built-in player is honest about Dolby Vision now.** An earlier cut on this line made the built-in (libmpv) player flip the TV into Dolby Vision mode for Dolby Vision files it plays. That badge was not real Dolby Vision: this lane decodes and tone-maps the picture, so lighting the panel's Dolby Vision mode over it mislabels the output. The built-in player now requests HDR10 for those files and the player shows a short "Dolby Vision title, HDR10 output" note, so what the TV badges is what you are actually getting. True Dolby Vision plays through the dedicated lane in Apple's player, which now asks for the right mode (above).
- **The real Dolby Atmos track wins on the true-Dolby-Vision lane.** Within your language, the lane now prefers the E-AC3 track that actually carries Dolby Atmos (detected from the bitstream itself) ahead of raw channel count, so an eight-channel non-Atmos track can never shadow the six-channel Atmos bed, which is the only shape the Apple TV lights Atmos from. The picked track's Atmos signaling in the produced stream is also verified and logged once per play, so a single diagnostics export can prove the audio side end to end.
- **The silent ways Dolby Vision gets defeated now say so.** If Match Dynamic Range is off on the Apple TV (it is off by default on every Apple TV), the player now shows the exact setting to turn on instead of failing silently. If the Player engine override is set to Always libmpv, a Dolby Vision play now says the override is disabling the true-Dolby-Vision lane. And the engine route, remux mount, and any fallback reason are now always recorded in the exportable diagnostics log, not only in internal builds, so one export pins the cause.
- **A Dolby Vision MKV no longer errors out with "can't play this file."** A debrid link whose web address happened to contain an ".mp4" fragment (a CDN id, a query token) could be misread as an MP4 and sent to AVPlayer, which cannot demux Matroska, so the Dolby Vision MKV failed with "AVPlayer can't play this file (likely Dolby Vision in MKV) ... pick an MP4 source" and dropped to HDR10. The container check now reads only the real file name and query, and a Matroska hint always wins, so those Dolby Vision MKVs take the true-Dolby-Vision remux lane, where the picture is real Dolby Vision and a Dolby Digital Plus / Atmos track passes straight through to your receiver. An honest note: a Dolby Vision file that must stay on the built-in player (mainly torrents) still shows multichannel surround rather than the Atmos badge; lighting the Atmos badge there needs a player-engine rebuild landing in a later build.
- **Dolby Atmos and surround are no longer dropped when a Dolby Vision file lists a stereo or commentary track first.** A 4K Dolby Vision rip often carries several audio tracks: the real multichannel bed (frequently Dolby Digital Plus with Atmos) alongside a stereo downmix or a director's-commentary track, and some rips order a stereo or commentary track first. The player lane that carries true Dolby Vision used to map whichever audio track appeared first, so on those files it silently played the stereo or commentary track and you lost Atmos and surround. It now scans every audio track and maps the real one: staying inside the source's original language (so it never swaps in a foreign dub), it prefers the track with the most channels (a commentary or stereo track is one or two channels, the main bed is six or eight), and when two tie it prefers the E-AC3 track, because Dolby Atmos rides inside E-AC3 (Dolby Digital Plus). The same order now also picks the track fed to the on-fly converter for a lossless-only file. So the movie's main surround or Atmos bed plays, in the right language, not a stereo dub. Files that already mapped the right track are unchanged, and a probe log records the exact track and channel count chosen. This is the likeliest reason a Dolby Vision file with a Dolby Digital Plus / Atmos bed was still playing in stereo. Builds on all schemes; needs a real Apple TV plus a receiver to verify end to end.
- **Dolby Vision with lossless audio now plays as true Dolby Vision.** A 4K Dolby Vision file whose only audio is TrueHD or DTS (including DTS-HD MA, the shape of most premium 4K files) used to fall back to HDR10, because the player lane that carries true Dolby Vision cannot decode those audio formats. That lane now converts the one audio track on the fly, while the video is stream-copied untouched, into a multichannel format it plays natively, so you get true Dolby Vision video plus full surround sound instead of an HDR10 tone-map. Sources that already carry a compatible track (AC3, E-AC3, AAC, FLAC, ALAC, MP3) still pass through byte-for-byte, and any file the converter cannot handle falls back exactly as before, so nothing that plays today can regress. The converter is built codec-forward: a later cut upgrades its output to Dolby Digital Plus so a receiver lights its Dolby badge. Alongside it, the built-in player now asks the system to open the sound route at your receiver's real channel count (up to 7.1) and logs the negotiated layout, so 5.1 content is far less likely to be quietly downmixed to stereo. Builds on all schemes; needs a real Apple TV plus a receiver to verify end to end.
- **Apple TV can sign in to your VortX account by QR, not only Stremio.** The Apple TV sign-in screen now leads with VortX: it shows a QR code and a short code, you scan it with your phone (or open vortx.tv/approve in a browser) on a device already signed in to VortX, approve, and the TV signs into your VortX account, the one that owns your add-ons, library, and sync. Your account's data key is wrapped to that specific TV with an end-to-end key exchange (X25519 + ECDH), so the relay that carries it never sees your key, and the session the TV receives is useless without it. Connecting a Stremio account (its own QR link, or email and password) is still there, now as a secondary "bring your Stremio library" step. A phone or the web can act as the approving device. Builds on all schemes; the two-device handoff needs a real Apple TV plus a phone or browser to exercise end to end, and the vortx.tv/approve page must be deployed.
- **Cached sources on your own AllDebrid or Premiumize account now resolve natively, the same way TorBox already did.** The app can already ask your TorBox account whether a torrent is instantly cached and, if so, play it as a direct link straight through your account. It now does the same for AllDebrid (its `magnet/instant` check) and Premiumize (its `cache/check`): a torrent your AllDebrid or Premiumize account has cached gets the instant badge, ranks alongside the other cached sources, and plays through your own account without waiting on an add-on to resolve it. Real-Debrid permanently removed its cache-check endpoint upstream in late 2024, so Real-Debrid sources keep resolving through your add-ons as before. No change unless you have an AllDebrid or Premiumize key, and any hiccup in the check falls back to exactly today's behavior (it can only help, never regress). This is also the groundwork the community source pool needs to resolve per-user.
- **Community sources now play through your own debrid or TorBox, every kind.** With community sources turned on and signed in, pooled torrent, usenet, and direct sources all surface now (before, only torrents showed and none were checked against your account). Each one is now checked against, and resolved through, your OWN account: a torrent through your debrid (TorBox, AllDebrid, or Premiumize), a usenet source through your TorBox usenet, a direct link played as-is. So a community source you can play badges as cached and plays straight through your account with no add-on in the middle. Only a source's public identity is ever shared (an infohash, an nzb link, or a plain link); the playable link is always re-created on your own device with your own keys.
- **Apple TV: Back after continuous play returns to the episode you are now on.** When auto-play carried you from one episode into the next (or into the next season) and you pressed Back/Menu, the Details page still showed the season and episode you originally launched, not where you ended up. It now reads the engine's current resume episode when the player closes, switches to that season if it moved, and focuses that episode row (tvOS auto-scrolls it into view). Built and run-verified on the tvOS 26.5 simulator; the exact play-through-and-back flow needs a signed-in Apple TV to exercise end to end.
- **Reorder your add-ons right in the app.** Add-ons now has a Reorder add-ons screen: drag any add-on up or down to set the order. That order is the priority spine, which add-on's catalogs and sources come first, and it is pushed to your account the instant you finish, so it converges with your other devices and the web dashboard, the same `doc.addonOrder` a dashboard drag writes. The Add-ons list re-sorts live the moment you return (the applied order also seeds the engine's add-on order at the next hydrate, so source priority follows too). iPhone, iPad, and Mac (tvOS ordering stays on the dashboard, since the drag needs the touch/pointer gesture tvOS lacks). Device-verified on macOS: drag, immediate sync push (ok), and live re-sort without relaunch. Also on this screen: a configurable add-on's action chips (Configure, link, hide, Remove) now wrap instead of clipping Remove off the right edge on iPhone.
- **A back-to-top button on Home and Discover.** Once you scroll past the hero, a small circular button appears in the bottom-trailing corner (clear of the tab bar); tapping it scrolls smoothly back to the top and the button fades away. It reuses the same scroll-to-top path as re-tapping the active tab, so both do exactly the same thing. Reduced-motion is respected. Device-verified on macOS. iPhone, iPad, and Mac (tvOS uses focus/Menu to return to the top, so it is not needed there).

### Security

- **Sign-in and recovery now reject a downgraded password-hardening work factor.** The number of hashing rounds used to turn your password into your encryption key was taken verbatim from the (pre-authentication) server response with no floor, so a spoofed or man-in-the-middle server could have returned a tiny value and weakened the protection on your stored key. The app now refuses any value below a safe minimum before deriving the key. No effect on normal sign-in.
- **Add-on status checks no longer probe private or local-network addresses.** The "Online / Slow / Unreachable" reachability ping followed an add-on's URL with no safety check, so a malicious add-on synced from another surface could have used it to poke at devices on your home network. It now runs the same private-address guard as installing an add-on (your own on-device local add-on at 127.0.0.1 is exempt and still shows its real status). Device-verified on macOS.
- **Hardening.** A synced add-on order is now length-capped before it is stored, and the metadata API-key request sites are annotated so a key is never written into an exportable diagnostic log.
- **Groundwork to stop a tampered server from rolling your account back in time.** Your encrypted account backup is now readable in a new version-bound format that ties each saved copy to its version number, so a malicious backup server can't quietly serve an old copy (resurrecting add-ons or profiles you removed) by relabelling it as newer. This ships as read-only for now across the apps and the website so nothing breaks while every device updates; the protection is switched on in a later step. Also fixes a latent bug where the website, if it ever failed to decrypt your backup, could overwrite it with an empty one.

## 0.3.11 - build 155 (pre-release)

A stability and playback pre-release over build 153 that ends the Mac source-list freeze that could force you to quit the app, stops a related Mac crash when opening a title while its sources load, makes Continue Watching and Play from start start on the exact source you expect, lights true Dolby Vision on Apple TV, and fixes iPhone/iPad downloads that failed with a storage or file-creation error. In testing; becomes the 0.3.12 release once verified. In-place update, nothing resets.

### Fixed

- **On Mac, opening a title while its sources are still loading no longer crashes the app.** Once the source list was assembled off the main thread (the freeze fix below), macOS 26 could turn a routine SwiftUI window-toolbar rebuild, which fires when a movie detail refreshes as its sources stream in, into an unhandled system exception that force-quit the whole app (owner-reported crash, EXC_BREAKPOINT in NSToolbar; the crash report's symbol was a nearest-export artifact for the real toolbar insert). Every app-authored toolbar item on Mac was already suppressed, so this is purely the system's own navigation chrome; the app now installs a guard around the exact system insert calls, so the throw is absorbed instead of crashing. The window toolbar is hidden and unused on Mac, so the guard has no visible effect. Device-verified on macOS 26.5 through 2,600+ and 5,000+ source titles, re-ranking, rapid open/close, and playback. Mac only.
- **The Mac app no longer freezes or force-quits while a title's source list loads.** On a popular title with a thousand-plus sources, the app rebuilt and re-ranked the entire source list on the main thread several times a second as sources streamed in, which could lock the window hard enough that you had to force-quit it from the system (owner-reported). The whole list is now assembled and ranked off the main thread and published once per real change, so the window stays responsive and keyboard navigation keeps working while sources load. This also fixes a rare crash risk where changing a source filter in Settings during that rebuild could race the ranking. iPhone, iPad, Mac, and Apple TV.
- **Play from start replays the source you were watching, never a different one.** Starting a movie over from the beginning used to re-run source selection across every add-on and could jump to a different source; it now restarts the exact same source from 0:00. Watch Now and picking a source yourself are unchanged. iPhone, iPad, and Mac.
- **Continue Watching resumes instantly when you come back soon.** A resume re-minted a fresh debrid link on every play, a short wait before the player appeared. If you resume within about twenty minutes of last playing, the still-valid stored link is used immediately so playback begins at once; older resumes re-mint as before, and a dead link still falls back to a fresh source. iPhone, iPad, Mac, and Apple TV.
- **Downloads on iPhone and iPad no longer fail with a false "not enough storage" or a cannot-create-file error.** A nearly finished download that resumed was checked against its full size instead of the little that still had to be written, so it failed for storage with plenty of space free; and a download that completed while the device was locked could not create its file (a -3000 error). The space check now counts only the remaining bytes and uses the capacity the system actually frees for a user write, and the download folder is prepared to allow a locked-device write before the transfer starts. Large downloads now finish even overnight with the screen locked. iPhone and iPad.
- **Dolby Vision now switches your Apple TV into its Dolby Vision mode, not just HDR10.** Even when a true Dolby Vision stream was playing, the player lane that carries real Dolby Vision never asked the TV to light its Dolby Vision mode, so the TV stayed in HDR10. It now requests Dolby Vision for those streams and returns to your default mode afterward. Match Dynamic Range must be on in tvOS Settings, Video and Audio, Match Content. On Mac, Dolby Vision plays as system HDR, which is the ceiling there (macOS has no Dolby Vision display switch). Apple TV.
- **Removing an add-on now also removes its sources right away.** A deleted add-on disappeared from your add-ons list, but the sources it had already loaded kept showing in open source lists until the next stream load. Deleting an add-on now clears its sources from every source list immediately too, on top of hiding it from the list. iPhone, iPad, Mac, and Apple TV.
- **Community (Singularity) sources render inline only, sortable with your other sources.** The duplicate pinned block above the source list was removed on every platform; the community group now flows through the ranked list like any add-on and sorts with your chosen order. iPhone, iPad, Mac, and Apple TV.

## 0.3.11 - build 153

A follow-up to 0.3.10 that ends the Apple TV playback lag and audio crackle that built up minutes into a stream, fixes a Dolby Vision crash a few minutes into a movie, stops trailers from cutting out partway through, moves the community (Singularity) sources back inside the source list on Apple TV where they belong, and makes the Apple TV login field work with the Continuity keyboard. In-place update, nothing resets.

### Fixed

- **The Add-ons screen no longer bogs the app down, especially on Mac.** Opening Add-ons with a full account's worth of add-ons could balloon memory toward a gigabyte and make the whole app crawl (owner-reported "unusable" on Mac), because every add-on logo was decoded at its full source resolution before being shrunk to the small icon shown. Each logo is now decoded at the size it is actually displayed at, so the screen stays light and responsive no matter how many add-ons you have. iPhone, iPad, Mac, and Apple TV.
- **On Apple TV you can scroll down through your whole installed add-ons list.** Focus used to stop at the "Re-check status" button and never reach the add-ons beneath it, because that button sat pinned to the far right, off the downward path of the left-aligned rows. It is repositioned on Apple TV so pressing Down steps into the list and continues through every add-on. Apple TV.
- **Removing an add-on always takes effect now.** An add-on that was visible in your list but had arrived from a sync (without the underlying engine record) made the Remove button do nothing at all. Remove now records the removal first and hides the add-on immediately in that case too, still without touching your Stremio account. iPhone, iPad, Mac, and Apple TV.
- **Dolby Vision engages on Apple TV instead of always falling back to HDR10.** A Dolby Vision file from debrid needs several seconds to open and start its on-device remux, but Apple TV gave up after only five seconds and dropped to HDR10 before the Dolby Vision conversion had even begun; the longer wait that iPhone, iPad, and Mac already used was never carried over to Apple TV. Apple TV now waits long enough, so Dolby Vision titles, including the dual-layer Profile 7 files most 4K Blu-ray rips use, actually get to play as Dolby Vision. A genuinely dead source still falls back cleanly. Apple TV.
- **Foreign-dialogue (forced) subtitles turn on by themselves again.** When a film is in your audio language but has a few lines in another language, the small track that translates only those lines now appears automatically. It had only ever been matched by the literal word "forced" in the track's name, which real forced tracks almost never carry; the app now reads the track's actual forced flag, so it works on debrid and streamed sources too. iPhone, iPad, Mac, and Apple TV.
- **Exporting the diagnostic log now clears it afterward, so your next export is fresh.** On Mac the log is copied to Downloads and the live log is reset; on Apple TV and iPhone it resets once the download completes. iPhone, iPad, Mac, and Apple TV.
- **A torrent and a debrid file downloading at the same time no longer cross wires.** The two use separate download engines that both number their tasks starting from 1, and the app tracked all of them in one table keyed by that number, so two simultaneous downloads that happened to share a number could mis-report each other's progress and move a finished file to the wrong download's destination. Each engine's tasks are now tracked in their own namespace, so concurrent downloads stay correctly separated. iPhone, iPad, Mac, and Apple TV.
- **A broad reliability and security hardening pass.** Dozens of smaller fixes from a full code audit: the source list can no longer hang if the engine renames an internal status; a Dolby Vision file that cannot be remuxed now falls back to the built-in player immediately instead of waiting for Apple's player to time out; the poster image cache no longer captures unrelated requests like sync and ratings; a deleted add-on or profile can no longer be resurrected by an out-of-date sync from another device, and a device whose clock has drifted backward can still save its changes; a rapid double-tap of Next no longer starts two overlapping episode loads; several player, trailer, and server resources are released more reliably; and API keys and tokens are kept out of request URLs. Under the hood, across all four apps.
- **Continue Watching resume no longer gets stuck loading when its saved source has expired.** Resuming a title, especially the next episode, plays the exact source you last used, but a debrid link expires after a while. When that stale link failed to open, the player treated it like a source you had hand-picked and stopped instead of moving on, so it could sit loading for a minute or two until you backed out. A resume now still tries your exact source first, and if that stored link has expired it reloads and re-selects the SAME source with a fresh link, so you stay on the source you chose; only if that source is genuinely gone does it move to another. Playback starts instead of hanging. iPhone, iPad, Mac, and Apple TV.
- **The next episode prewarms again on titles that don't report a length.** While you watch an episode, the app quietly prefetches and pre-heats the next one so pressing Next starts it almost instantly. That only kicked in once you passed the halfway point, which is measured from the title's length, but many 4K remuxes from debrid never report a length, so the prewarm never started for them and the next episode cold-started. It now also begins prewarming after a couple of minutes of playback when no length is known, so the next episode is ready to go. iPhone, iPad, Mac, and Apple TV.
- **Dolby Vision plays from MKVs that carry the Dolby Vision signal inside the video stream.** Some Dolby Vision .mkv files describe their DV in the video bitstream itself rather than in a separate container tag, so the app read the container tag, saw "no Dolby Vision here", and fell back to HDR10 even though other players show these as Dolby Vision. It now also reads the DV signal from the video stream (with no rewind, so it still works over a debrid link), so these files play as true Dolby Vision; files that genuinely are not DV still fall back to HDR10 cleanly. Turn on "Dolby Vision for MKV (Beta)" in Settings. iPhone, iPad, Mac, and Apple TV.
- **Community scrub-preview thumbnails stop failing to upload on every watch.** A preview sheet needs at least two frames to build, but the app tried to send one the instant the very first frame was captured, which could never build a sheet and was dropped with a misleading "compose failure" every session. It now waits until it has at least two frames, so previews are shared as intended. iPhone, iPad, Mac, and Apple TV.
- **The source list is smoother while sources are still loading on iPhone, iPad, and Mac.** As sources streamed in, the app re-sorted the whole list on every update, and the iPhone/iPad/Mac detail screen ran that sort several times per refresh, so a long list could stutter. The sorted list is now reused until something that actually affects the order changes, matching the Apple TV fix from earlier in this release. iPhone, iPad, and Mac.
- **On Apple TV, the audio and subtitle track you pick is check-marked instantly.** The check mark used to wait for the player to confirm the switch, so it lagged a beat behind your tap. It now moves the moment you choose a track, then reconciles with the player. Apple TV.
- **More small reliability fixes.** A sparse library entry no longer drops your whole Continue Watching list to empty; a cached single-file debrid torrent whose provider omitted filenames now resolves instead of failing; a 576p source is labelled and ranked as 576p instead of 540p; the Apple TV player re-arms its start watchdog after falling back to the built-in player so a stalled re-open can still recover; artwork from Fanart no longer stays blank for the whole session after one failed fetch; a series' episode list rebuilds when its episodes stream in after the page opens; and a garbage stream duration can no longer crash progress saving. iPhone, iPad, Mac, and Apple TV.
- **Continue Watching resumes without a long pause or needing you to reopen the title.** 0.3.11 stopped the app from re-sending detail data that had not changed, to cut redundant work, but a progress update no longer counted as a change worth acting on, so a resume could sit for about ten seconds, or need you to leave and reopen the title, before it played. Your progress, resume point, and the episode you are on now always count as a change, so Continue Watching resumes right away again. iPhone, iPad, Mac, and Apple TV.
- **The Streaming Services row no longer shows a service twice or drops one.** Apple TV+ could appear two times while another service went missing, because a handful of services are listed under two different provider IDs upstream and the row counted them as separate before trimming to a fixed number of tiles. Those duplicates are now merged to a single tile before the row is built, so each service appears once and the row stays complete. iPhone, iPad, Mac, and Apple TV.
- **Dolby Vision keeps playing through a slow debrid stretch instead of stopping early.** A Dolby Vision remux that had already started and shown its first frame could stop partway through when the debrid server delivered a slow chunk, because a brief read stall was treated as the end of the file. A stalled read is now retried a few times before giving up (the reconnect logic re-establishes the connection the same way the built-in player tolerates), so the movie plays through; a genuinely dead link still ends cleanly and falls back to the built-in player. iPhone, iPad, Mac, and Apple TV.
- **More reliable playback and sign-in under the hood.** A set of robustness fixes from a full fault sweep across all three apps: on iPhone and iPad an HLS stream that fails on Apple's player now falls back to the built-in player the same way it already did on Apple TV and Mac; a rare crash when the built-in player was torn down at the wrong moment is closed; a sign-in and profile-switch race is closed; and embedded subtitle styling that contains commas now parses correctly. iPhone, iPad, Mac, and Apple TV.
- **The ambient hero trailer no longer keeps playing behind the player.** Since the hero clip became the real full trailer in 0.3.9, starting playback left that muted looping 1080p clip decoding and re-downloading underneath the whole movie, because the browse screen (and its clip) stays alive under the fullscreen player. That caused constant micro stutter, audio crackle, a brief speed-up after pause and unpause, and doubled bandwidth on every stream started while a hero clip was up. The clip now stops the moment the player opens and comes back fresh when playback closes. Reported and fixed by @jbecker-it. Apple TV, iPhone, iPad, and Mac.
- **Streamed remuxes no longer build up frame drops and distorted audio minutes into playback.** Since 0.3.9, starting a stream whose file carries embedded text subtitles (remuxes, mostly) kicked off a background job that re-downloaded and demuxed the entire file alongside the player to share those subtitles with the community pool; on a 20+ GB remux that second full-rate stream starved playback, restarting or switching episodes stacked another copy, and it only ran smooth again once a copy finished during a long pause. Embedded subtitles are now shared from downloaded files only, where reading them is a quick local pass; streamed plays skip the job entirely, and nothing else about community subtitles changes. Reported and fixed by @jbecker-it. Apple TV, iPhone, iPad, and Mac.
- **Dolby Vision no longer crashes the app a few minutes into a movie.** True Dolby Vision playback could run for a few minutes and then crash the whole app. The on-device buffer that feeds Apple's player was reading past the end of its own memory once it began dropping already-watched data to stay small (which is why it only happened after a few minutes, never at the very start). It now reads from the correct place and reclaims that memory properly, so a Dolby Vision movie plays straight through. iPhone, iPad, Mac, and Apple TV.
- **Dolby Vision for MKV actually plays now.** Turning on "Dolby Vision for MKV (Beta)" in Settings and playing a Dolby Vision .mkv from debrid now plays it as true Dolby Vision through Apple's player, instead of silently falling back to HDR10. Several things were fixed end to end: the source now opens reliably on a slow debrid link, the on-device remux produces a valid Dolby Vision stream that Apple's player accepts, and the player now waits long enough for that remux to start (a Dolby Vision remux takes a little longer to show its first frame over debrid, and it was previously being dropped to the built-in player too early). The setting is also now per-device, so switching it on actually sticks instead of being reverted by sync. When a specific file genuinely cannot be remuxed it still falls back to HDR10 cleanly. iPhone, iPad, Mac, and Apple TV.
- **Trailers are steadier on Apple TV and no longer add to the memory pressure that can knock out the streaming server.** A trailer is a short clip, but a trailer played through the fallback resolver was being given the same large network read-ahead buffer as a full 4K movie. On Apple TV that extra buffer stacks toward the memory ceiling that can jetsam the whole app (which shows up as the streaming server going offline), after which the next thing you open can fail to load until you reopen the app. Trailers now use a small read-ahead like the on-device path already did, so they never contribute to that pressure. Trailers themselves have always resolved and played independently of the streaming server, on every build including the no-server Lite one.
- **Timeline scrub-preview thumbnails upload reliably for long movies and full series.** A long watch produced a preview sprite-sheet larger than the 3 MB upload limit, so it was silently dropped before it was ever sent and the server never stored it (short clips were unaffected, which is why the problem was easy to miss). The sheet is now unconditionally size-bounded: it decimates evenly across the whole duration and, if a dense sheet is still too large, re-decimates to fewer tiles until it fits, so a legitimate long capture is never dropped for size. The per-sheet tile budget was also lowered so the common case fits on the first try, and every previously-invisible drop (a compose or encode failure) is now logged. iPhone, iPad, Mac, and Apple TV.
- **Trailers no longer cut out partway through.** A trailer plays its picture and sound as two separate streams pulled from YouTube in small pieces, and a single hiccup on one of those pieces used to end that stream early, so the video or the audio would stop halfway while the other kept playing. Each piece is now retried a few times before giving up, so trailers play through to the end. Apple TV, and everywhere trailers play.
- **On Apple TV, community (Singularity) sources are back inside the source list.** With Singularity sources turned on, they were appearing pinned above the Watch button before you opened the source list, instead of nested inside "All sources" with your other add-ons. They now sit in the source list where the rest of the sources are, matching iPhone, iPad, and Mac.
- **The Apple TV login field works with the Continuity keyboard.** The email and password fields on the Apple TV sign-in screen were asking the system for saved-password autofill, which stalled the Continuity keyboard handshake, so an iPhone or Mac would be detected but never actually type into the field. That autofill request is gone, so the Continuity keyboard connects and types. You can still sign in by QR code or link, which remains the easiest path.
- **The Collections hub no longer blanks on one screen when you turn it off on the other.** The Collections hub on Home and on Discover shared a single set of data, so turning it off on one screen also cleared it on the other until a refresh. Turning it off on one screen now leaves the other untouched.
- **Downloads recover from a transient "couldn't save" error on iPhone and iPad.** When the system's background download service briefly failed to create a download's file (an error that could appear even with plenty of free space), the download failed outright. It is now retried once automatically before showing an error, so a passing glitch no longer loses the download.

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
- **Fourteen seek-bar styles** for how the scrubber looks during playback: Classic, Gradient, Glow, Wave, Heartbeat, Pulse, Dots, Equalizer, Minimal, Neon, Ribbon, Comet, Segments, and Ladder (Settings).
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
