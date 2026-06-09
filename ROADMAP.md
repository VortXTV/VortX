# Roadmap

Where StremioX is headed, roughly in the order we'll build it. No fixed dates; it ships when it's good.

The engine and add-on protocol already work, so the focus is everything around them: the best player and interface we can build, first on Apple TV and then across the rest of our devices.

## Next

1. **Smart track selection.** Pick the right audio and subtitle track automatically from your preferred languages, respect forced subtitles, and let you set reject lists for tracks you never want.
2. **Gestures and zoom.** Aspect, zoom, and fill, pinch to zoom, and gestures for seek, volume, brightness, and hold-to-speed.
3. **HDR and lossless audio.** HDR and Dolby Vision in 10-bit, plus audio passthrough so TrueHD, DTS-HD MA, and Atmos reach your receiver untouched.
4. **Skip and continue.** Skip intro and outro, then roll straight into the next episode.
5. **Downloads and Usenet.** Save a title to watch offline, and pull from Usenet alongside torrents and debrid.
6. **Themes.** Built-in themes and a theme studio for your own colours, a true-black OLED mode, a layout you can rearrange, and a player with motion that has character.
7. **No more buffering.** Heavy caching and pre-processing so playback starts fast and stays smooth, switching audio or subtitle tracks happens instantly instead of restarting the stream, and the next episode loads before you reach it.
8. **iPhone and iPad.** The same native app on iOS and iPadOS, off the web host.
9. **Watch now, or choose.** Rank the sources and auto-play the best one for the quality you prefer, with two buttons on every title: Watch Now for the top stream, or Select Streams for the full list.
10. **Richer detail pages.** Ratings from more than one source (IMDb, TMDB, Trakt, MAL, AniList), cast and crew with photos, studio and network badges, and trailers.
11. **Better search.** Real filters and proper advanced search.
12. **Then the rest,** as each earns its place: casting (AirPlay first), Trakt sync and a release calendar, profiles with a parental PIN, live TV, and watch-together.
13. **Self-hosted source.** Run your own back end instead of leaning only on add-ons.

## Shipped

- **Apple TV, native on the engine.** Home with real Continue Watching and every catalog, plus Discover, Library, Detail, the full per-add-on source list, Search, and add-on management. Watched state, resume, and live progress all run through the engine.
- **The player.** Full-screen libmpv with dependable focus and controls, an options panel split into Audio, Subtitles, Aspect, and Episodes, audio and subtitle sync, aspect modes, language-grouped tracks, and subtitle fonts for every script.
- **The basics.** Sign-in, smooth 4K, posters that load, solid caching, and a player you can always back out of.
- **iPhone and iPad, for now.** A web UI with a native libmpv player and external-player handoff, until the native client replaces it.

## Distribution

A self-hosted update channel is coming early, so the app can update itself rather than expire like an ordinary sideload. First-run setup for add-ons and debrid rides along with it.
