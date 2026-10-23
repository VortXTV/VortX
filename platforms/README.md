# VortX on TV (LG webOS + Samsung Tizen)

**Development targets, not current native release downloads.** These wrappers are retained in
source. Packaging requires the relevant SDK/signing setup and physical-TV validation; this page
does not establish a store release or verified playback on a particular LG/Samsung model.

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

Prereq: the Node/npm versions declared by `../webapp/package.json` (currently Node
22.23.3+ and npm 12.2.0) and a pinned `npm ci` in `../webapp` (done once). The builder
checks those declared engine requirements before building or replacing a stage.

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

Packaged files do not receive Cloudflare Pages `_headers`. After copying the shared output,
the builder injects the authoritative CSP from `webapp/public/_headers` into the staged
HTML before scripts/resources. Missing/unsafe CSP stops the builder before any packaging
command. This preserves arbitrary HTTPS provider/media hosts, HLS blob workers
and the YouTube no-cookie trailer frame, while keeping executable scripts local. The
Tizen manifest retains dynamic network access but no longer permits arbitrary top-level
navigation. Source contract tests do not replace signed-package or physical-TV validation.
The TV-only derivation additionally permits `http:` in image, media and connect directives,
preserving existing HTTP posters/direct/HLS providers on a packaged origin. It does not
add HTTP authority to scripts, frames or workers, or alter the HTTPS Pages policy.

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

- **Packaging is a separate gate.** Manifest validation or staged files are not an accepted `.ipk`
  or `.wgt`. Record actual SDK/signing versions, package identity and content when producing one.
- **Real hardware needs its own receipt.** An in-browser `?tv=1` test cannot establish remote input,
  exit behavior or codec support on an LG/Samsung model. Record the exact model/firmware and source
  when testing; this documentation update makes no new hardware-acceptance claim.
- **Store assets are minimal.** One icon per platform is generated. Store submission needs the full icon
  set, splash/background art, screenshots, and store metadata.
- **Tizen signing profile / package id.** `config.xml` uses package id `VortXtv001`; it must match the
  certificate profile used to sign. webOS `appinfo.json` uses `com.vortx.tv`.
- **Player focus polish.** During playback the D-pad is handed to the player's existing key shortcuts
  rather than moving focus between on-screen controls; spatial focus inside the player chrome is a
  follow-up.
