# VortX AltStore / SideStore source

`source.json` is an [AltStore](https://altstore.io) / [SideStore](https://sidestore.io)
source manifest for sideloading VortX with **one-tap updates** instead of
re-downloading an IPA by hand each release.

It is generated from the GitHub releases (the `VortX-iOS-v*-ci.ipa` assets), so
each entry points straight at a real release download URL with its size and
release notes.

## Use it

1. Use the stable JSON route `https://vortx.tv/altstore.json` (the compatibility
   alias `https://vortx.tv/vortx-altstore.json` serves the identical document).
   Both routes ignore query strings and return JSON with bounded caching; do not
   substitute a website URL that returns HTML.
2. In AltStore or SideStore: **Browse → Sources → +** and paste that URL.
3. VortX then shows up with an **Update** button whenever a newer release lands.

## Edge route contract

The private edge deployment owns these explicit JSON paths:

- `/altstore.json` is the canonical source and must mirror `altstore/source.json`.
- `/vortx-altstore.json` is a compatibility alias and must return byte-equivalent JSON.
- `/appcast.json` is the in-app update manifest. It must carry the same Apple tag, build,
  asset URLs, sizes, and SHA-256 values as the release source. Its Android entry stays `null`
  until a signed Android artifact and version-code metadata are published.

All three paths must return HTTP 200 with an `application/json` content type for a valid
published release, ignore query strings when selecting a generation, and use a bounded cache
header. The release workflow checks the normal path and a query variant, rejects HTML or stale
data, and rolls back the source commit if the public contract is not met. A private deployment
must be live before publishing the release-triggered workflow pass.

## Regenerate after a release

Re-run the generator (it reads the latest releases via `gh`):

```sh
# from the repo root, after a new release is published; release metadata must
# come from the immutable tag and uploaded asset checksums.
node scripts/update-altstore-source.mjs \
  --file altstore/source.json --tag v0.3.14-beta.19 --build 221 \
  --date 2026-08-20 --name "0.3.14 Beta 19" \
  --ios-size 123 --tvos-size 123 \
  --ios-sha256 <64-hex-digest> --tvos-sha256 <64-hex-digest> \
  --ios-url "https://github.com/VortXTV/VortX/releases/download/v0.3.14-beta.19/VortX-iOS-v0.3.14-beta.19-ci.ipa" \
  --tvos-url "https://github.com/VortXTV/VortX/releases/download/v0.3.14-beta.19/VortX-tvOS-v0.3.14-beta.19-ci.ipa"

# Verify the generated document before committing it:
node scripts/release-feed.mjs verify-source \
  --file altstore/source.json --tag v0.3.14-beta.19 --build 221 \
  --ios-size 123 --tvos-size 123 \
  --ios-sha256 <64-hex-digest> --tvos-sha256 <64-hex-digest>
```

For a metadata-only backfill, `python3 scripts/gen-altstore-source.py` also
requires exact asset digests and reads each build from the immutable tag. The
protected release workflow remains authoritative because it verifies the public
routes and performs rollback on a failed check.

The bundle id is `com.stremiox.app.native` (the internal StremioX identifier is
deferred past 0.4; the user-facing name is VortX).
