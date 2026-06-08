# StremioX features and what is missing

The full feature target for StremioX, and where each piece stands. The goal is the most complete,
best-looking media client on every platform. Status: **Have** (shipped), **Building** (in progress),
**Planned** (designed, not started).

## Platforms

- **Apple TV** native on the engine. **Have.**
- **iPhone and iPad** native client on the engine. **Building** (a web host runs in the meantime).
- **macOS** native, sharing the same SwiftUI and engine code. **Planned.**
- **Windows and Linux.** **Planned** (longer term).

## Player

- Native libmpv player, wide codec and container support. **Have.**
- Aggressive read-ahead caching so big streams do not stall. **Have** (disk caching and tuning ongoing).
- Reliable on-screen controls and a redesigned, cinematic player UI. **Building.**
- Live metadata line (resolution, HDR, audio). **Have.**
- **Customizable player**: user-arranged controls and on-screen layout. **Planned.**
- HDR and Dolby Vision passthrough, plus HDR to SDR tonemapping with a target-nits setting. **Planned.**
- Full subtitle styling: font, size, color, outline, box, margin, alignment; dual subtitle tracks;
  per-title delay; custom font upload; broad script coverage including CJK. **Building.**
- Extra subtitle sources with download. **Planned.**
- Smart track selection: auto audio and subtitle by language, forced-subtitle override, per-language and
  per-keyword rejection lists, per-show memory. **Planned.**
- Audio: codec and channel detection, passthrough, optional night and voice-clarity modes, audio delay.
  **Planned.**
- Anime upscaling shaders with quality presets and content auto-detection. **Planned.**
- Smooth-motion (judder reduction) toggle. **Planned.**
- Skip intro and outro, with an on-screen skip button. **Planned.**
- Trickplay scrub previews on the seek bar. **Planned.**
- In-player source switcher and Next Up. **Planned.**
- A/B loop, sleep timer, frame grab, stats overlay, picture-in-picture, seek-step setting, an ends-at clock.
  **Planned.**
- Resume and watched sync, auto-advance, auto-retry, decode-error fallback. **Have.**

## Sources and stream selection

- Catalogs, search, and add-ons through the engine. **Have.**
- **Add debrid API keys directly in the app** (multiple services), with a uniform cache check. **Planned.**
- Smart stream ranking: parse quality, audio, and language; filter fakes and mislabeled or low-quality
  sources; read cache hints; float the best cached high-quality source to the top. **Planned.**
- A safety filter (strict / balanced / off) and a fresh-release fake-filter window. **Planned.**
- Direct torrent streaming without a debrid account. **Planned.**

## Metadata and tracking

- Real Continue Watching and library from the engine. **Have.**
- Rich metadata and posters, multi-source ratings, and award highlights. **Planned.**
- Watch-history tracking and scrobbling with automatic episode tracking. **Planned.**
- Hero banner with daily recommendations, taste-based Discover rails, and a calendar. **Planned.**
- Add to and remove from Library on the detail page; last-used source per title. **Planned.**

## Look and feel

- Cinematic, designed UI on a shared design system. **Have.**
- **Customizable theme**: accent color and full color theming, multiple presets and layouts, custom fonts.
  **Planned.**
- Profiles with parental PIN and content hiding. **Planned.**
- Localization and remote / keyboard remapping. **Planned.**

## Casting

- AirPlay (native). **Planned.**
- Chromecast, DLNA, and Roku. **Planned.**
- Transcode-for-cast via the StremioX server. **Planned.**

## Live TV

- Playlist and provider sources (M3U, Xtream, XMLTV). **Planned.**
- Channel browser with logos and now-playing, favorites, and categories. **Planned.**
- EPG guide grid with a now indicator, catchup / timeshift, and recording. **Planned.**

## Social and advanced

- Watch together: synced playback, chat, on-screen cursors, draw-over-video. **Planned.**
- Multiview (more than one stream at once). **Planned.**
- Webhooks and rich-presence integrations. **Planned.**

## Foundations

- Our own streaming server (replacing the bundled one), unlocking Usenet, live TV, full background caching,
  and transcoding. **Planned.**
- Shipped as unsigned, sideloaded builds with checksums; manual updates. **Have.**
