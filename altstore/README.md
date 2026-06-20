# VortX AltStore / SideStore source

`source.json` is an [AltStore](https://altstore.io) / [SideStore](https://sidestore.io)
source manifest for sideloading VortX with **one-tap updates** instead of
re-downloading an IPA by hand each release.

It is generated from the GitHub releases (the `VortX-iOS-v*-ci.ipa` assets), so
each entry points straight at a real release download URL with its size and
release notes.

## Use it

1. Host `source.json` at a stable URL (e.g. `https://vortx.tv/altstore.json`, a
   Cloudflare Pages route, or the GitHub raw URL of this file).
2. In AltStore or SideStore: **Browse → Sources → +** and paste that URL.
3. VortX then shows up with an **Update** button whenever a newer release lands.

## Regenerate after a release

Re-run the generator (it reads the latest releases via `gh`):

```sh
# from the repo root, after a new release is published
python3 scripts/gen-altstore-source.py   # writes altstore/source.json
```

(If that script is not present yet, the inline generator used to create this file
queries `gh release view` for the recent tags and emits the same shape.)

The bundle id is `com.stremiox.app.native` (the internal StremioX identifier is
deferred past 0.4; the user-facing name is VortX).
