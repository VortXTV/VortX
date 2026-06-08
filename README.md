# StremioX

Stremio for iPhone, iPad, and Apple TV. An independent, updated client for Apple devices, with a native Apple TV app built on stremio-core.

## Why this exists

Apple pulled Stremio from the App Store, and Stremio's answer was to go the sideload route. In February 2026 they released fully featured sideloadable IPAs for iPhone, iPad, and Apple TV, said they were waiting to hear back from Apple about returning to the store, and hinted at more coming in 2026. That February build (v1.3.6) is almost certainly the one most of us are running.

The catch is what happened after. Those Apple builds have not been updated in months, the download links quietly went missing from the site, and meanwhile the Android, Windows, and web apps kept getting features and fixes. On Apple TV the official option is "Stremio Lite," which is deliberately feature limited. So Apple users, and Apple TV users in particular, are stuck on something stale while everyone else moves on.

That is the gap I wanted to close. StremioX is an independent, updated client, built fresh for Apple TV on stremio-core (the same engine Stremio uses) and for iPhone and iPad. It is not a replacement for Stremio, it is not affiliated with them, and it takes nothing away from their apps. It is just a way for Apple users to stop waiting.

One thing I want to be straight about. I didn't write the code. Claude (Anthropic's AI) wrote all of it. My part was the direction and the grind. I ran every build on my own devices, signed into my own account, kept finding the parts that were broken or felt off, and sent it back to redo until it was actually good enough to use every day. So this is "an AI wrote it and a real person beat it into shape," not a one-shot generated repo.

If it keeps even a handful of Apple users on Stremio, that was the whole point.

## What it looks like (Apple TV)

Home, with your real Continue Watching and every catalog from your addons:

![Home](docs/screenshots/home.png)

A cinematic title page: backdrop, synopsis, episodes (or sources), and mark-watched controls:

![Detail](docs/screenshots/detail.png)

Every source your addons return, with their exact details, filterable by quality and addon:

![Streams](docs/screenshots/streams.png)

A clean, full-screen libmpv player with resume, audio, and subtitle controls:

![Player](docs/screenshots/player.png)

Discover and Library, with proper type, catalog, genre, and sort filters:

![Discover](docs/screenshots/discover.png)

![Library](docs/screenshots/library.png)

## What you get

**iPhone and iPad.** It hosts Stremio's live web interface in a WKWebView and plays the stream in a native libmpv player (MPVKit-GPL) so codecs and HDR actually work. It also runs Stremio's streaming server through nodejs-mobile for torrents. There's a "Play in" hand-off to Infuse or VLC. Because it follows the live web, a Stremio web update can occasionally disrupt it; a native iPhone and iPad client on stremio-core, like the Apple TV app, is in progress and will remove that dependency.

**Apple TV.** There's no WebKit on tvOS, so this one is a fully native SwiftUI app. The part I'm proud of is that it runs on stremio-core, the same Rust engine the official apps use, compiled straight into the app. Because the real engine does the work, your catalogs, library, and Continue Watching come out right instead of being stitched together by hand. Same native libmpv player, same embedded server.

A few things the Apple TV app does:

- Continue Watching and catalogs that match the official app. This was the thing that annoyed me most early on, when the first versions only showed one or two items.
- Title pages with a backdrop, a season picker, and episode thumbnails.
- Watched and unwatched markers, and you can mark things watched (or back to unwatched, for a rewatch) by episode, by season, or for a whole series.
- Stream lists grouped by addon, showing each addon's text exactly as it sends it: quality, size, codec, HDR, source.
- The libmpv player: fit by default plus zoom and stretch, audio and subtitle track picking, subtitle styling, speed, and resume.
- Point it at your own streaming server if you run one.

## Installing

The builds are attached to the [latest release](../../releases/latest). They are unsigned because this is a third-party Stremio client distributed outside the App Store, and there is no shared signing identity to ship a signed build. You re-sign them yourself:

- iPhone and iPad: Signulous, AltStore or SideStore, or Sideloadly. A free Apple ID works for personal use.
- Apple TV: Sideloadly or Xcode, or a paid signing service.

What I used myself is Signulous, and it was pretty straightforward. You pay once a year per device, upload the IPA, and it signs and installs within a minute.

## Security and privacy

Reasonable questions for any unsigned build, so here is the straight version:

- It is unsigned on purpose. You re-sign it with your own identity, so nothing here runs under my signature.
- What the Apple TV app talks to: Stremio's official API (api.strem.io) to sign in and sync, the addons you have installed, and whichever streaming server you point it at. Nothing else. It adds no analytics, no telemetry, and no third-party trackers.
- The iPhone and iPad app hosts Stremio's own stremio-web interface, so it behaves like Stremio's official web app and talks to the same places that does.
- Your account token is kept in the device Keychain, not in plain preferences, and it only ever goes to Stremio's own API.
- Each release lists SHA-256 checksums next to the assets, so you can confirm the file you downloaded matches what was published.
- You do not have to take my word for any of this. The full source is here, and you can build the IPA yourself.

## It comes with nothing

You sign in with your own Stremio account and bring your own addons. No content is bundled and no addons are bundled. What you watch, and whether it is legal where you live, is on you.

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

The plan for upcoming work (the native iPhone and iPad client on the engine, our own streaming server with Usenet and live TV, and more) is in [ROADMAP.md](ROADMAP.md).

## Known issues

- **Some subtitles show as blocks.** Subtitles in certain scripts can render as empty boxes. This is a font-coverage issue and a fix is in progress; trying a different subtitle source can help in the meantime.
- **Occasional playback stutter.** Some high-bitrate or 4K streams can hitch depending on the stream and your network. Under investigation.
- **iPhone and iPad follow Stremio's live web.** The iOS app hosts Stremio's live web interface, so a Stremio web update can occasionally disrupt it. The native iOS client on the roadmap removes this dependency.
- **Unsigned builds.** You re-sign the IPA yourself, and depending on the signing method, reinstalling can require signing in again.

## Not affiliated

This is an independent community project. It is not affiliated with or endorsed by Stremio, Anthropic, or Apple. All names and trademarks belong to their owners.

## Credits

- [Stremio](https://www.stremio.com/), for stremio-core, the streaming server, and the apps this picks up from.
- [mpv](https://mpv.io/) and [MPVKit](https://github.com/mpvkit/MPVKit), for the player.
- [nodejs-mobile](https://github.com/nodejs-mobile/nodejs-mobile), for the embedded server runtime.
- Claude (Anthropic) wrote the code.

See [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) for the full list.

## A note on the bundled streaming server

The released IPAs include Stremio's `server.js`, which is Stremio's own streaming server. It is proprietary, and Stremio distributes it for free inside their own apps. StremioX has not modified it and claims no rights to it. It is bundled only so the app works out of the box the way Stremio's own builds do. Swapping it for an open-source streaming server is on the [roadmap](ROADMAP.md), and if Stremio would rather it not be bundled, that is an easy change to make.

## License

[GPL-3.0](LICENSE), because the app links MPVKit-GPL. Stremio's own components, the open-source stremio-web and the proprietary server.js, come from Stremio and remain under their own terms. This source repository does not include them; they are fetched from a copy of Stremio's own app at build time.
