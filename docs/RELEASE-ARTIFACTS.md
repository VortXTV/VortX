# VortX release artifacts and naming

This page is the canonical dimension reference for every artifact the release workflows stage.
It exists because of audit finding REL-02: release staging used to label the Android builds by
device class ("phone" and "tv") when those labels did not describe any real property of the
artifacts.

## The real dimensions

An Android artifact name answers exactly three questions:

| Dimension | Values | Meaning |
|---|---|---|
| Flavor (engine and distribution) | `full-mpv`, `play-media3` | Which playback engine is packaged and where the build is meant to ship. `full` carries the GPLv3 libmpv native engine and is sideloaded from GitHub releases. `play` carries only the Media3/ExoPlayer engine with no GPL native code and is bound for Google Play. |
| ABI | `universal` | One APK packages every shipped ABI (`arm64-v8a`, `armeabi-v7a`, and `x86_64`). The 32-bit ARM slice supports older Fire TV hardware. There are no per-ABI splits today; if splits land, each gains an explicit ABI segment in its name. |
| Package type | `.apk`, `.aab` | Sideloadable APK or Play App Bundle. |

### What a flavor is NOT

The flavor is never a device split. Both `full-mpv` and `play-media3` contain the phone AND the Android TV activities (including the LEANBACK launcher entry), so one install of either variant serves both device classes. Nothing about a device can be inferred from the flavor, and no artifact is labeled phone or TV on purpose.

## Canonical names

Staged by `.github/workflows/android-release.yml` after signer verification:

| Artifact | Old (misleading) name | Contents |
|---|---|---|
| `VortX-x.y.z-full-mpv-universal.apk` | `VortX-x.y.z-phone.apk` | Sideload build, GPL mpv engine primary player, Media3 fallback, phone + TV UI, all three ABIs |
| `VortX-x.y.z-play-media3-universal.apk` | `VortX-x.y.z-tv.apk` | Play-bound build, Media3 only, GPL native free, phone + TV UI, all three ABIs |
| `VortX-x.y.z-play-media3.aab` | `VortX-x.y.z-play.aab` | Play App Bundle form of the `play-media3` build |

Consumers that fetch "the newest APK" (for example the `dl.vortx.tv` redirect worker) match on
the `.apk` extension or read staged metadata, not on these labels, so renames are safe for them;
anything pinning the old names must move to the canonical ones above.

## Signing and provenance

Android release signing stays fail-closed on four secrets (`VORTX_KEYSTORE_PATH`,
`VORTX_KEYSTORE_PASSWORD`, `VORTX_KEY_ALIAS`, `VORTX_KEY_PASSWORD`, referenced by name only).
Before anything uploads, `scripts/verify-android-release-signing.sh` requires APK Signature
Scheme v2, exactly one signer, rejects any Android Debug certificate, and pins the production
certificate SHA-256. Each release ships `SHA256SUMS` (per-artifact SHA-256) and
`SIGNING_PROVENANCE.txt` (signer verification output plus release tag commit, source commit, and
workflow run URL) so every published byte is traceable to a tag and a run.

## Secretless pull-request validation

`.github/workflows/release-packaging-validation.yml` runs on every pull request with zero secret
access and exercises as much of the packaging path as a runner allows:

- Android: the exact release task set (`assembleFullRelease`, `assemblePlayRelease`,
  `bundlePlayRelease`) against an ephemeral run-local keystore, then strict signature checks (v2
  scheme, single signer, ephemeral-certificate binding, explicit Android Debug rejection),
  `jarsigner -verify -strict` on the AAB, the GPL boundary scan, and native-lib merge proof.
- Apple: fixture-driven contract tests for `release-feed.mjs`, `gen-altstore-source.py`, and
  `repackage-ipa.sh`, plus a numeric project-build parse of the real Xcode manifest.

What this lane deliberately cannot validate, and which lane does instead:

| Not validable secretlessly | Why | Validated by |
|---|---|---|
| Engine-linked APKs (`libstremiox_core.so`, `libvortx_ffi.so`) | Engines live in private repos behind `ENGINE_REPO_TOKEN` | Privileged push and release lanes with `VORTX_REQUIRE_ENGINE=1` |
| Production signer pin | The pinned certificate must never appear in a secretless job | Release workflow via `verify-android-release-signing.sh` |
| Apple signed archives and notarization | Requires paid Apple identities | Protected release stage in `release-tvos.yml` |
