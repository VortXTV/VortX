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

| Concern | Native apps / desktop | This web client |
| --- | --- | --- |
| Add-on protocol | embedded `stremio-core` engine (Rust) | `src/lib/addon.ts` - direct `fetch()` |
| Catalogs / meta | engine `board` / `meta_details` models | Cinemeta + installed add-ons over HTTPS |
| Stream ranking | `StreamRanking.swift` / `desktop/src/streamRanking.ts` | `src/lib/streamRanking.ts` (ported) |
| Series / episodes | `desktop/src/engine.ts` helpers | `src/lib/series.ts` (ported) |
| Player | libmpv (Apple) / libmpv via Tauri (desktop) | HTML5 `<video>` + `hls.js` (`src/lib/player.ts`) |
| Torrents | in-process streaming server | not supported (no server) |

The ranking, series handling, and detail UX are ports of the desktop frontend
(`desktop/src/detail.ts`, `streamRanking.ts`, `engine.ts`) so behaviour and look match the apps. The
transport and player are the parts that differ, because the browser has neither the Rust engine nor a
streaming server.

## Add-ons

Cinemeta (catalogs + metadata) is installed by default, so Home and Detail work out of the box. To get
playable streams, open **Add-ons** and install a stream add-on by its `manifest.json` URL. The list is
stored in the browser (`localStorage`); there is no account on the web client.

## Develop

```bash
cd webapp
npm install
npm run dev        # Vite dev server
npm run typecheck  # tsc --noEmit
npm run build      # tsc && vite build -> dist/
npm run preview    # serve the production build locally
```

Requirements: Node 18+ and npm.

## Deploy (Cloudflare Pages -> web.vortx.tv)

The site is a static SPA deployed to Cloudflare Pages.

**One-shot deploy from a machine with Wrangler authenticated:**

```bash
cd webapp
npm run deploy     # build + wrangler pages deploy dist --project-name=vortx-web
```

**Git-connected Pages project (recommended):** point the Pages project `vortx-web` at this repo with:

- Root directory: `web`
- Build command: `npm run build`
- Build output directory: `dist`

Then attach the custom domain `web.vortx.tv` to the project in the Cloudflare dashboard.

`public/_redirects` provides the SPA fallback (every path serves `index.html`) and `public/_headers`
sets the production CSP and hardening headers. Both are copied verbatim into `dist/` by Vite.

## Browser support

Chrome, Firefox, Edge, and Safari (current versions). HLS uses `hls.js` where Media Source Extensions
are available and native HLS on Safari. Playback of any individual stream still depends on the
browser's codec support for that file.
