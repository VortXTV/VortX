# Roadmap

Where StremioX is headed next. This is a community build with no fixed schedule, but this is the plan, in rough priority order. Done items are at the bottom so you can see what already landed.

## Planned

1. **iOS on stremio-core.** Right now the iPhone and iPad app hosts the real stremio-web interface inside a web view. The plan is to rebuild it as a native client on stremio-core, the same way the Apple TV app already works, so it is faster and behaves the same on every Apple device. This is the big one.

2. **Apple TV Top Shelf.** Surface Continue Watching on the Apple TV home screen, the way the official app does. This one is exploratory: a Top Shelf extension needs a shared app group, which can be awkward to keep working across the kind of re-signing sideloading relies on, so it may not survive every install method.

3. **Open-source streaming server.** The released IPAs currently bundle Stremio's proprietary `server.js`. Replacing it with an open-source streaming server (for example perpetus/stream-server) would remove the one proprietary piece and let CI build the IPAs end to end. Unproven inside nodejs-mobile on iOS and tvOS, so it needs investigation.

4. **More player and UI polish.** Subtitles pulled from addons (OpenSubtitles and similar), a load-failure state on detail pages, a bundled licenses/acknowledgements screen, and localization. (Clear sign-in states on the main tabs already landed.)

5. **Tests and CI.** A set of characterization tests around the Swift to Rust bridge, and a GitHub Action that builds the IPAs on each release tag (this becomes possible once the streaming server is open-source, since the proprietary `server.js` cannot live in CI).

## Done

- Apple TV rebased onto stremio-core: Home, Discover, Library, Detail, and the per-addon stream list.
- Search across every installed addon, on the engine.
- Add-ons screen on the engine, with remove for non-default addons.
- Watched and unwatched markers, with the option to mark by episode, by season, or for a whole series.
- Engine-sourced resume, and a watched hook near the end of playback.
- Live playback progress through the engine Player, so Continue Watching updates mid-session.
- Clear sign-in states on the main tabs instead of an endless spinner.
- Full UI redesign on a shared design system (warm editorial-cinema direction, crafted remote focus, poster-forward layout), captured in DESIGN.md for the iOS client to inherit.
- Sign-in token stored in the Keychain, with a one-time migration from the old storage.
- Sign-in seeds the engine immediately, and sign-out clears it.
- Both apps shipped as unsigned IPAs in the releases.
