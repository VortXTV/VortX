# Android TV: match the Apple TV experience

Status: active implementation and acceptance record. The September 30 follow-up below is current;
older dated sections preserve their historical release boundary, not a claim of completed parity.

## September 30 implementation follow-up

The current follow-up is based on reviewed main `6c74ae048`, not the preserved September 3 prototype.
Android now has per-engine replacement ownership, pause-intent-preserving source transitions, and a
single owned next-episode preparation task with bounded retry. Prepared detail sources are also fenced
by the exact profile, account, title/episode request, and generation; a cancelled fetch cannot populate
another profile's cache. Continue Watching episode targeting avoids unwatched specials unless explicitly
selected, TV episode Up has an explicit previous-row/season boundary, and the source audio picker derives
its language options from the actual list. Custom relation content types retain their routes.

Intro/recap/credits/preview skipping now uses a playback-position countdown on both form factors. Settings
offers Off, 5, 10, 15, and 30 seconds; new users default to 5 seconds and an existing explicit Off remains
Off. Skip is immediate, X suppresses that segment for the episode, and remote Left/Right selects Skip/X.
Pause, buffering, seek, source replacement, cast/PiP, lock, and exit cannot spend stale countdown time.
Audio and subtitle default selections wait for their own inventories independently; explicit choices
and subtitle Off cannot be replaced by a later inventory event.

Watched-download cleanup is now wired only when exact durable watch evidence and complete outer-player
resource release are available. It stays Off by default and fails closed for engine-backed history without
a durable per-video receipt. Index/file cleanup is recoverable; corrupt or incomplete persisted indexes
cannot authorize deletion. Watch-based recommendation seeds are scoped to the active history owner.

Full passed 1,374 tests and Play passed 1,301, with no failures, errors, or skipped tests. Both debug APKs
were rebuilt with the exact workflow-pinned native engines; all twelve packaged engine libraries have
the correct ELF architecture and required JNI exports across the three supported ABIs. Play also passes
its GPL-library exclusion check. This is source/build evidence, not a claim of complete Apple-style
visual parity, a signed public release, or physical Shield/Fire TV playback proof.
Signing/update continuity, screenshots, remote focus, sustained playback,
HDR/audio output, and process-death recovery remain mandatory acceptance gates below. Do not replace this
boundary with the historical percentage estimates in older runbooks.

## September 11 follow-up (bundled in Beta 14)

Phone and TV now show add-on-declared Prequel, Sequel, and Related rails through the normal detail navigation. They use the currently loaded metadata, preserve movie/series IDs (including namespaced anime IDs on series routes), reject external/malformed links, remove self-links and duplicates, and remain hidden for live content. Both Android variants compile and pass their unit suites; physical TV focus testing remains required.

Beta 13 remained an unpublished draft; this follow-up is included in Beta 14. TMDB collection results also supply previous/next movie cards explicitly labeled **Release Order**, using the existing fetch and only valid dated parts. The full collection rail remains unchanged. At that release, custom `anime`/other content-type routing without coercing types to movies was outstanding; the September 30 follow-up now implements those routes. Full visual and remote-navigation acceptance remains below.

Also outstanding: rapid title selection can race asynchronous TMDB-to-IMDb lookups in phone and TV detail navigation. A later selection needs to cancel and supersede the earlier lookup, including direct relation selection; verify reversed completion order and page disposal before shipping that change.

Beta 14 publication follow-up: the signed Android artifacts are public, but the appcast inherits Beta 1 Android entries while the active receipt has Android null. The augmentation workflow currently compares the inherited public appcast against the canonical null-Android receipt and rejects it. Its worker also derives the Android build from the Apple manifest (247), not the actual Android versionCode (237). Correct both with explicit artifact-bound Android version evidence and tests for inherited entries before augmenting the feed; do not weaken receipt, signer, checksum, or rollback checks. Apple feeds and release packages remain independently verifiable.

The Home/Discover Collections visibility switches now belong to each profile on Apple and Android, including roster sync and backup projection handling. Explicit off values survive round trips; an unset legacy profile gets visible defaults on selection without overwriting an active profile during a partial sync. Apple screens use the shared observable catalog owner, and Android refreshes an already-open settings screen and captures edits immediately. Verification: 25 Apple isolation checks, both Android unit suites, and full iOS arm64 simulator/tvOS Release builds pass. This addresses the remaining two global switches in issue #215; it does not claim every profile or cross-device behavior is physically verified.

Android Discover now uses its own Collections visibility key rather than Home's. Phone Discover also mounts the shared hub and category browse, including a hub header when the ordinary catalog is empty. Both Discover surfaces share disposal, initial/provider/artwork loads and settings-change reloads. A deterministic test injects a settings change during the first provider request; subscription now precedes the initial refresh, preventing that notification from being dropped. Home's independent hub remains unchanged. Both Android variants pass their unit suites; device layout/focus checks remain outstanding.

The Apple TV app is the reference for layout, navigation, information hierarchy, and behavior. Android phone remains a separate touch layout. Reuse Android's existing repositories, player engines, and profile stores; do not port Apple source files or replace current code with an older release.

## 1. Home and hero

- Match the Apple TV hero's backdrop treatment, title/logo placement, metadata, synopsis height, action band, and transition into content rails.
- Match focus entry, rail-to-hero movement, Back behavior, and restoration after returning from Detail or the player.
- Keep hero trailer loading, muting, completion/loop behavior, and cancellation independent of full-screen trailers.
- Check long titles, missing artwork, missing metadata, subtitle languages, and same-title metadata refresh before introducing new caching behavior.

## 2. Detail and sources

- Match the first viewport: artwork, metadata hierarchy, fixed synopsis reservation, bottom actions, and sources beside the primary playback action.
- Keep Watch, Resume, Library, Trailer, player choice, source selection, seasons, and episodes discoverable with a remote.
- Make Quality and Audio refine the actual source list. Auto restores the profile preference; a per-title choice must not silently overwrite that preference.
- Preserve stable focus identities through source refresh, sorting, filtering, episode changes, and playback return.
- Support short viewports and long translations without hiding action buttons or producing a second accidental scroll surface.

## 3. Episodes and binge playback

- Match season selection, episode cards, progress/watched markers, and series/season/episode watched actions.
- Up from episode N must reach N-1; only the first episode may leave the list upward. Returning from playback must restore the current episode.
- Verify previous/next controls, source prewarming, manual pause, end-of-episode admission, and explicit-source failure behavior on both Android engines.

## 4. Shared settings and account behavior

- Audit TV controls against their real consumers, including Collections on Discover, catalog order, filters, trailer preferences, and visibility settings.
- Match phone's existing Stremio-or-VortX account eligibility without introducing a second authentication policy.
- Replace phone-oriented settings surfaces only where remote navigation is inadequate; retain shared storage and profile isolation.
- Audit Search, text input, dialog dismissal, and return focus with a physical remote.

## Preserved prototype and review blockers

The September 3 prototype is preserved separately on `beta/android-tv-parity-followup-0903`, not included in the Beta 1 release. It contains browse eligibility, Discover preference wiring, Detail layout stabilization, and a session-only audio picker.

Before integrating the audio picker:

1. Carry a context revision through source assembly. An old assembly with the same title/request generation must not acknowledge a newer audio choice.
2. Later source emissions and Smart Source auto-pick must read the current request-owned context, not the context captured at load start.
3. Add deterministic tests for an old assembly arriving after a language change, a later source emission, immediate Watch after selection, Auto restoration, and unchanged persistent track preferences.
4. Verify that the user-visible source filtering/ranking behavior matches the Apple TV selector. A tick beside a language alone is not acceptance.

## Acceptance gates

- Compare screenshots and focus journeys against the same title/account on Apple TV, Android TV/Shield, and a representative Fire TV.
- Exercise empty/slow/failing source lists, rapid Re-find, long series, missing artwork, profile changes, and back-to-back playback.
- Run both Full mpv and Play Media3 unit/compile/package checks. Verify production signing and in-place upgrade continuity.
- Validate audio, subtitles, HDR/DV capability fallback, pause, seek, engine switching, and sustained playback on physical hardware.
- Preserve phone/tablet touch navigation and orientation behavior with separate regression checks.

Build success is not a substitute for physical remote or sustained-playback evidence. No Android TV device or configured emulator was available during the September 3 audit.
