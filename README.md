# StremioX

Stremio for iPhone, iPad, and Apple TV. I built it because the official apps stopped getting updates.

## Why this exists

Apple kept pulling Stremio off the App Store, and after enough rounds of that fight Stremio basically gave up on Apple. The last build we got was v1.3.6, back in February 2026. Everyone on Android and Windows kept moving forward while we sat on an old app that barely worked anymore.

It bugged me for a long time. I couldn't watch anything properly on my Apple TV, and on my iPhone and iPad I was stuck on a stale, limited build while the rest of Stremio moved on. At some point I stopped waiting for someone else to fix it and just did it myself: updated apps for iOS and Apple TV, put out here so other Apple users don't have to put up with the same thing.

One thing I want to be straight about. I didn't write the code. Claude (Anthropic's AI) wrote all of it. My part was the direction and the grind. I ran every build on my own devices, signed into my own account, kept finding the parts that were broken or felt off, and sent it back to redo until it was actually good enough to use every day. So this is "an AI wrote it and a real person beat it into shape," not a one-shot generated repo.

If it keeps even a handful of Apple users on Stremio, that was the whole point.

## What it looks like (Apple TV)

Home, with your real Continue Watching and every catalog from your addons:

![Home](docs/screenshots/home.png)

A title page with the backdrop, a season picker, episodes, and watched markers:

![Detail](docs/screenshots/detail.png)

Every source your addons return, with their exact details, filterable by addon:

![Streams](docs/screenshots/streams.png)

Discover and Library, with proper type, catalog, genre, and sort filters:

![Discover](docs/screenshots/discover.png)

![Library](docs/screenshots/library.png)

## What you get

**iPhone and iPad.** It runs the real stremio-web interface inside a WKWebView, so you get Stremio's current features, and it plays the stream in a native libmpv player (MPVKit-GPL) so codecs and HDR actually work. It also runs Stremio's streaming server through nodejs-mobile for torrents. If you'd rather use a different player, there's a "Play in" hand-off to Infuse or VLC.

**Apple TV.** There's no WebKit on tvOS, so this one is a fully native SwiftUI app. The part I'm proud of is that it runs on stremio-core, the same Rust engine the official apps use, compiled straight into the app. Because the real engine does the work, your catalogs, library, and Continue Watching come out right instead of being stitched together by hand. Same native libmpv player, same embedded server.

A few things the Apple TV app does:

- Continue Watching and catalogs that match the official app. This was the thing that annoyed me most early on, when the first versions only showed one or two items.
- Title pages with a backdrop, a season picker, and episode thumbnails.
- Watched and unwatched markers, and you can mark things watched (or back to unwatched, for a rewatch) by episode, by season, or for a whole series.
- Stream lists grouped by addon, showing each addon's text exactly as it sends it: quality, size, codec, HDR, source.
- The libmpv player: fit by default plus zoom and stretch, audio and subtitle track picking, subtitle styling, speed, and resume.
- Point it at your own streaming server if you run one.

## Installing

The builds are attached to the [latest release](../../releases/latest). They are unsigned on purpose. There's no shared signing identity, and the app uses some private APIs, so the App Store was never the goal. You re-sign them yourself:

- iPhone and iPad: Signulous, AltStore or SideStore, or Sideloadly. A free Apple ID works for personal use.
- Apple TV: Sideloadly or Xcode, or a paid signing service.

## It comes with nothing

You sign in with your own Stremio account and bring your own addons (Cinemeta, your debrid or AIOStreams setup, whatever you already use). No content is bundled and no addons are bundled. What you watch, and whether it's legal where you live, is on you.

## Building it yourself

You'll need macOS with Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen), Node and pnpm (for the iOS web bundle), Rust nightly with rust-src (for the tvOS engine), and a copy of Stremio's free macOS app (the streaming server gets pulled out of it). MPVKit comes in over Swift Package Manager.

```bash
# 1) Streaming-server deps. server.js is not in this repo. Put Stremio's free macOS
#    app at reference/macos/Stremio.app first, then:
./scripts/fetch-server-deps.sh

# 2) iOS only: build the stremio-web bundle
./scripts/build-web.sh

# 3) tvOS only: build the stremio-core engine into an xcframework (needs Rust nightly + rust-src)
./scripts/build-core-xcframework.sh

# 4) Generate the project and build (unsigned, for sideloading)
cd app && xcodegen generate
xcodebuild -scheme StremioX   -sdk iphoneos   -destination 'generic/platform=iOS'  -configuration Release CODE_SIGNING_ALLOWED=NO build
xcodebuild -scheme StremioXTV -sdk appletvos -destination 'generic/platform=tvOS' -configuration Release CODE_SIGNING_ALLOWED=NO build

# 5) Wrap the built .app into an .ipa
./scripts/repackage-ipa.sh <dir-with-Payload> build/StremioX.ipa
```

server.js isn't included here because it's Stremio's own streaming server. It ships free inside their macOS app, so the script pulls it from a copy you provide instead of redistributing it.

## How the tvOS app works

It started out talking to addons by hand, and that kept getting small things wrong. So it was moved onto stremio-core, Stremio's open-source Rust engine. The engine is built as a static library, packaged as StremioXCore.xcframework, and talks to Swift as plain JSON over a C interface (see the `core/` folder). The SwiftUI screens send the engine actions and render whatever state it hands back, which is why the behavior lines up with the official app: it is the official engine. There's more in `docs/REBASE-stremio-core.md`.

## What's next

The plan for upcoming work (native iOS on the engine, live playback progress, Search and Add-ons on the engine, Apple TV Top Shelf, and more) is in [ROADMAP.md](ROADMAP.md).

## Not affiliated

This is an independent community project. It is not affiliated with or endorsed by Stremio, Anthropic, or Apple. All names and trademarks belong to their owners.

## Credits

- [Stremio](https://www.stremio.com/), for stremio-core, the streaming server, and the apps this picks up from.
- [mpv](https://mpv.io/) and [MPVKit](https://github.com/mpvkit/MPVKit), for the player.
- [nodejs-mobile](https://github.com/nodejs-mobile/nodejs-mobile), for the embedded server runtime.
- Claude (Anthropic) wrote the code.

## License

[GPL-3.0](LICENSE), because the app links MPVKit-GPL. Stremio's own pieces (stremio-web, server.js) come from Stremio and stay under their own terms. They are not redistributed here.
