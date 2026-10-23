# VortX web (web.vortx.tv)

A browser client for VortX, the native streaming app. This is the web counterpart to the
Apple apps, the Android app, and the Tauri desktop shell: same product, same engine concepts, but it
runs entirely in the browser with no native shell and no streaming server.

It talks **directly to the Stremio add-on protocol and Cinemeta over HTTPS from the browser**, ranks
the returned sources the same way the apps do, and plays them in a plain HTML5 `<video>` element
(`hls.js` for `.m3u8`).

## Direct / debrid / HLS-first (important)

The web app has **no streaming server**, so it cannot play torrents.

- **Plays:** direct HTTP(S) links, debrid links (RealDebrid, AllDebrid, Premiumize, ...), and HLS
  (`.m3u8`) streams. These play in `<video>`, with `hls.js` attaching Media Source Extensions for HLS
  in Chrome / Firefox / Edge and native HLS used in Safari.
- **Does not play:** torrent (`infoHash`) sources. They still show up in the source list, badged
  `TORRENT`, but are not playable here. Torrents need the embedded streaming server that only the
  native apps and the desktop shell ship. To stream torrents on the web, install a stream add-on
  backed by a **debrid** service so it returns direct links, or open the title in the VortX app.

This is why the detail page leads with "Watch" only when a playable (direct/debrid/HLS) source exists,
and explains the empty state when the only sources found are torrents.

## How it maps to the rest of the repo

| Concern | Native apps | This web client (also the desktop app's UI) |
| --- | --- | --- |
| Add-on protocol | the VortX engine (vortx-core) | `src/lib/addon.ts` - direct `fetch()` |
| Catalogs / meta | the VortX engine's resource host | Cinemeta + installed add-ons over HTTPS |
| Stream ranking | `StreamRanking.swift` / Android ranking | `src/lib/streamRanking.ts` (ported) |
| Series / episodes | native series views | `src/lib/series.ts` (ported) |
| Player | libmpv | HTML5 `<video>` + `hls.js` (`src/lib/player.ts`); native mpv for torrents in the desktop app |
| Torrents | in-process VortX streaming server | browser: not supported; desktop app: the shell's in-process VortX streaming server |

## The desktop app

The VortX desktop app (`desktop/`, Tauri) loads this web client and adds what a browser cannot have: the
VortX streaming server running in the app process, so torrent sources play, and the native mpv player.
`src/lib/desktop.ts` is the whole bridge; in a browser it is inert. The shell exposes only its server
and player commands, and only to the `https://web.vortx.tv` origin.

## Add-ons

Cinemeta supplies default catalogs/metadata. To get playable streams, open **Add-ons** and install
a compatible stream add-on by its `manifest.json` URL. Browser storage also retains local state.

## Account and sync

Use the client locally, or sign into a VortX account with its encrypted account vault. Sign-in and
page load pull supported account add-ons, library, Continue Watching, profiles, settings and metadata
keys. Supported settings, add-on and active-profile watch-progress changes made here sync back.
This does not promise continuous realtime updates without a reload, identical native-player
behavior or synchronization of every device-local field.

Never share browser storage, an account backup or an unredacted network export in a public issue.
See [Help and diagnostics](../docs/SUPPORT.md).

## Develop

```bash
cd webapp
corepack install
corepack npm ci
corepack npm run dev        # Vite dev server
corepack npm run typecheck  # tsc --noEmit
corepack npm run build      # tsc && vite build -> dist/
corepack npm run preview    # serve the production build locally
```

Requirements: Node 22.23.3+ with Corepack. `package.json` pins npm 12.2.0, and the project
rejects installs and scripts run with a different Node or npm version.

## Deploy (Cloudflare Pages -> web.vortx.tv)

The site is a static SPA deployed to Cloudflare Pages.

**One-shot deploy from a machine with Wrangler authenticated:**

```bash
cd webapp
corepack npm run deploy     # build + wrangler pages deploy dist --project-name=vortx-web
```

**Git-connected Pages project (recommended):** point the Pages project `vortx-web` at this repo with:

- Root directory: `webapp`
- Build command: `corepack install && corepack npm ci && corepack npm run build`
- Build output directory: `dist`
- Build environment variable, in both Production and Preview:
  `SKIP_DEPENDENCY_INSTALL=1`

Then attach the custom domain `web.vortx.tv` to the project in the Cloudflare dashboard.

`SKIP_DEPENDENCY_INSTALL` is a Pages build-system setting. It stops Pages' bundled npm from
attempting dependency installation and failing before the build command can select the npm version
pinned in `package.json`. The Git root, build command, and this build variable must be set in the
Pages dashboard; `wrangler.toml` cannot configure those Git-connected build settings.

`public/_redirects` provides the SPA fallback (every path serves `index.html`) and `public/_headers`
sets the production CSP and hardening headers. Both are copied verbatim into `dist/` by Vite.

## Browser support

Chrome, Firefox, Edge, and Safari (current versions). HLS uses `hls.js` where Media Source Extensions
are available and native HLS on Safari. Playback of any individual stream still depends on the
browser's codec support for that file.
