# VortX on TV (LG webOS + Samsung Tizen)

This folder packages the existing VortX webapp (`../webapp`) as installable **LG webOS** and **Samsung
Tizen** TV apps. It is **additive**: it reuses the same `npm run build` output the browser target
(`web.vortx.tv`) ships, wraps that `dist/` with a platform manifest and icons, and turns on a 10-foot
remote-input layer at runtime. The webapp is **not forked** and the web build is unchanged.

Why the webapp fits a TV directly: it is a socketless surface. It talks to the add-on protocol and plays
**direct / debrid / HLS** sources in a plain HTML5 `<video>` (`hls.js` for `.m3u8`) with **no streaming
server** (see `../webapp/README.md`). That is exactly what a webOS/Tizen web runtime can host. Torrents
(`infoHash`) still need the native apps' embedded server and remain unsupported here, same as on the web.

## What was added

| Piece | File | Purpose |
| --- | --- | --- |
| webOS manifest | `webos/appinfo.json` | app id `com.vortx.tv`, `main: index.html`, icons, `handlesRelaunch`, `disableBackHistoryAPI` |
| Tizen manifest | `tizen/config.xml` | widget/app id, `content src=index.html`, `internet` privilege, `screen.size.normal.1080.1920`, `hwkey-event` for BACK |
| Icons | `webos/icon.png` (80), `webos/largeIcon.png` (130), `tizen/icon.png` (117) | rasterized from `webapp/public/favicon.svg` by `gen-icons.mjs` |
| Remote input | `../webapp/src/lib/tvnav.ts` | D-pad spatial focus, OK/Enter activate, BACK (webOS 461 / Tizen 10009), exit-on-Home |
| TV presentation | `../webapp/src/styles/tv.css` | overscan-safe insets, 1080p type, always-on focus ring; scoped under `html.tv` |
| Build/stage/package | `build-tv.sh` | shared build -> stage dist + manifest + icons -> validate -> package (if SDK CLI present) |

The input layer and CSS are gated on `isTvPlatform()` (a webOS/Tizen user agent, the `tizen`/`webOS`
globals, or a `?tv=1` / `localStorage['vortx.tv.force']='1'` override for testing). On a normal browser
nothing activates: no `html.tv` class, no key handler. The web target's runtime behaviour is identical.

## How the remote drives the existing UI

Every browsable element in the webapp is already a native `<a>` / `<button>` / `<input>`, so no view was
rewritten. `tvnav.ts` adds a geometry-based "nearest focusable in the pressed direction" walk over those
existing elements:

- **Arrows (D-pad):** move focus to the nearest focusable up/down/left/right. Rails scroll into view as
  focus travels; the focused poster/tab shows the ember focus ring.
- **OK / Enter:** activates the focused element (synthesizes a click, which the app's delegated click
  handling + native anchors already act on). On a text field, Enter falls through to the on-screen keyboard.
- **BACK:** close the player, else leave Detail, else go Home, else exit to the launcher. Mirrors the
  app's existing Escape handling, extended with the top-level exit.
- **During playback** the layer yields Arrows/OK to the player's own key handler (seek, volume, play/pause
  in `player.ts`) and keeps only BACK, so the HTML5 `<video>` + `hls.js` path is untouched.

For desktop testing without a TV: run the webapp and open it with `?tv=1` (e.g.
`http://localhost:5173/?tv=1`). Backspace stands in for the remote BACK key.

## Build & package

Prereq: Node 18+ and `npm ci` in `../webapp` (done once).

```bash
# From the repo root:
platforms/build-tv.sh webos     # build + stage + validate appinfo.json (+ package if ares-cli is present)
platforms/build-tv.sh tizen     # build + stage + validate config.xml   (+ package if tizen CLI is present)

# Regenerate the icons after the favicon changes:
node platforms/gen-icons.mjs
```

`build-tv.sh` runs the shared `npm run build`, copies `dist/` + the manifest + icons into
`platforms/<p>/.stage/`, and validates the manifest. If the platform SDK CLI is installed it packages the
`.ipk` / `.wgt`; otherwise it stages and prints the exact package command (it never fabricates an artifact).

### webOS (.ipk) — needs the webOS SDK CLI

```bash
npm i -g @webos-tools/cli               # provides ares-package / ares-install
ares-package platforms/webos/.stage -o platforms/webos/out
ares-setup-device                       # add your TV (Developer Mode app must be running on the TV)
ares-install -d <device> platforms/webos/out/*.ipk
ares-launch -d <device> com.vortx.tv
```

### Tizen (.wgt) — needs Tizen Studio + a signing profile

```bash
# In Tizen Studio: create an author + distributor Certificate Profile (Samsung TV) first.
tizen build-web  -- platforms/tizen/.stage
tizen package -t wgt -s <profile> -- platforms/tizen/.stage/.buildResult -o platforms/tizen/out
sdb connect <tv-ip>                     # TV in Developer Mode, host IP allow-listed
tizen install -n platforms/tizen/out/*.wgt -t <tv-target>
```

## Honest gaps / follow-ups

- **Packaging CLIs are not in this environment.** The manifests are validated (JSON parses, XML is
  well-formed) and the apps are staged, but the `.ipk` / `.wgt` must be produced on a machine with the
  webOS SDK CLI / Tizen Studio. No packaged artifact is fabricated here.
- **No real-hardware test.** D-pad focus, BACK, and playback were exercised in-browser via `?tv=1`; they
  have not been run on a physical LG or Samsung TV. Remote key codes (461 / 10009), exit behaviour, and
  codec support per source still need a device pass.
- **Store assets are minimal.** One icon per platform is generated. Store submission needs the full icon
  set, splash/background art, screenshots, and store metadata.
- **Tizen signing profile / package id.** `config.xml` uses package id `VortXtv001`; it must match the
  certificate profile used to sign. webOS `appinfo.json` uses `com.vortx.tv`.
- **Player focus polish.** During playback the D-pad is handed to the player's existing key shortcuts
  rather than moving focus between on-screen controls; spatial focus inside the player chrome is a
  follow-up.
