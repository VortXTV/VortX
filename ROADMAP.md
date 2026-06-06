# Roadmap

Where StremioX is headed next. This is a community build with no fixed schedule, but this is the plan, in rough priority order. Done items are at the bottom so you can see what already landed.

## Planned

1. **iOS on stremio-core.** Right now the iPhone and iPad app hosts the real stremio-web interface inside a web view. The plan is to rebuild it as a native client on stremio-core, the same way the Apple TV app already works, so it is faster and behaves the same on every Apple device. This is the big one.

2. **Live playback progress.** The watched marker already flips near the end of a video, and resume reads from the engine library. What is missing is partial progress mid-watch, which only reaches the engine on the next sync today. Wiring the engine's player model will make Continue Watching update the moment you pause and back out.

3. **Search and Add-ons on the engine (Apple TV).** Search still uses the older Cinemeta client, and the Add-ons screen is read only. Moving both onto the engine will let you install and remove addons inside the app and search across everything you have installed.

4. **Apple TV Top Shelf.** Surface Continue Watching on the Apple TV home screen, the way the official app does.

5. **Keychain for the sign-in token.** It currently lives in UserDefaults. Moving it into the Keychain is a small but worthwhile security upgrade.

6. **Player and UI polish.** Subtitles pulled from addons (OpenSubtitles and similar), cleaner empty and error states, and localization.

7. **Tests and CI.** A set of characterization tests around the Swift to Rust bridge, and a GitHub Action that builds the IPAs on each release tag.

## Done

- Apple TV rebased onto stremio-core: Home, Discover, Library, Detail, and the per-addon stream list.
- Watched and unwatched markers, with the option to mark by episode, by season, or for a whole series.
- Engine-sourced resume, and a watched hook near the end of playback.
- Sign-in seeds the engine immediately, and sign-out clears it.
- Both apps shipped as unsigned IPAs in the releases.
