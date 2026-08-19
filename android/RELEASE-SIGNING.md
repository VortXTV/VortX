# VortX Android release signing

Every VortX Android release APK/AAB is signed under one persistent upload identity so consecutive
builds share the same signing certificate. This document explains how the signing config is wired,
how to generate the keystore, and how the values are supplied on a dev box and in CI.

The keystore and its passwords are secrets. They are NEVER committed (the tree is public). The
`android/.gitignore` blocks `keystore.properties`, `*.jks`, and `*.keystore`. Back the keystore up
somewhere durable and private (a password manager or an encrypted vault): if it is lost, sideload
updates can no longer install over an existing VortX install, because Android refuses an update
signed by a different certificate.

## How the build resolves the signing inputs

`android/app/build.gradle.kts` reads four inputs, each looked up first in a gitignored
`android/keystore.properties`, then in an environment variable of the same name:

| Input                     | Meaning                                                                 |
| ------------------------- | ----------------------------------------------------------------------- |
| `VORTX_KEYSTORE_FILE`     | Path to the keystore. Relative paths resolve against `android/`; absolute paths are used as-is. |
| `VORTX_KEYSTORE_PASSWORD` | The store password.                                                     |
| `VORTX_KEY_ALIAS`         | The key alias inside the keystore.                                      |
| `VORTX_KEY_PASSWORD`      | The key password. Falls back to the store password when one password was used at generation. |

When all four resolve, a `release` signing config is registered and the `release` build type uses it.
When any input is missing, no `release` signing config exists and the release build stays UNSIGNED, so
a fresh or public clone (and the existing debug CI) keeps building unchanged. The debug build type is
never affected; it keeps the auto-generated debug keystore.

## Generate the upload keystore (one time)

Run this once and keep the output file safe. A 4096-bit RSA key with a long validity is the standard
upload key shape.

```bash
keytool -genkeypair -v \
  -keystore vortx-upload.jks \
  -storetype PKCS12 \
  -alias vortx-upload \
  -keyalg RSA -keysize 4096 -validity 10000 \
  -dname "CN=VortX, OU=VortX, O=VortX, C=US"
```

`keytool` prompts for a store password (reused as the key password with `-storetype PKCS12`, which is
why `VORTX_KEY_PASSWORD` falls back to `VORTX_KEYSTORE_PASSWORD` when only one was set). Record the
password you choose. The alias here is `vortx-upload`; use whatever you set as `VORTX_KEY_ALIAS`.

## Local dev signing

Put a gitignored `android/keystore.properties` next to `android/local.properties`:

```properties
VORTX_KEYSTORE_FILE=vortx-upload.jks
VORTX_KEYSTORE_PASSWORD=the-store-password
VORTX_KEY_ALIAS=vortx-upload
VORTX_KEY_PASSWORD=the-key-password
```

Then a release assemble produces a signed APK:

```bash
./gradlew assembleFullRelease            # signed release APK
./gradlew bundleFullRelease              # signed release AAB
```

Outputs land at `android/app/build/outputs/apk/full/release/*.apk` and
`android/app/build/outputs/bundle/fullRelease/*.aab`. Verify the signature with the SDK's
`apksigner`:

```bash
"$ANDROID_HOME"/build-tools/*/apksigner verify --verbose \
  android/app/build/outputs/apk/full/release/*.apk
```

## CI signing (GitHub Actions)

`.github/workflows/android.yml` builds the signed release when the keystore secrets are set, and
skips signing gracefully when they are absent (the debug build and its engine checks always run). The
workflow base64-decodes the keystore secret to a temporary file, then hands the four `VORTX_*` env
vars to Gradle.

Set these repository (or environment) secrets in GitHub. The keystore secret is the base64 of the
keystore binary:

| Secret name                | Value                                                             |
| -------------------------- | ----------------------------------------------------------------- |
| `ANDROID_KEYSTORE_BASE64`  | Base64 of `vortx-upload.jks` (see below).                         |
| `ANDROID_KEYSTORE_PASSWORD`| The store password.                                               |
| `ANDROID_KEY_ALIAS`        | The key alias (`vortx-upload`).                                   |
| `ANDROID_KEY_PASSWORD`     | The key password (same as the store password if only one was set).|

Produce the base64 blob for `ANDROID_KEYSTORE_BASE64`:

```bash
# macOS
base64 -i vortx-upload.jks | pbcopy

# Linux (no line wrapping)
base64 -w0 vortx-upload.jks
```

The workflow maps the GitHub secrets onto the Gradle env vars:
`ANDROID_KEYSTORE_PASSWORD` -> `VORTX_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS` -> `VORTX_KEY_ALIAS`,
`ANDROID_KEY_PASSWORD` -> `VORTX_KEY_PASSWORD`, and the decoded keystore path -> `VORTX_KEYSTORE_FILE`.
If `ANDROID_KEYSTORE_BASE64` is unset, the signed-release steps are skipped and nothing else changes.

## Rotating or replacing the keystore

Because sideloaded updates must be signed by the same certificate, replacing the keystore breaks
in-place updates for existing installs (users would have to uninstall and reinstall). Rotate only when
you accept that break, or use the Android signing key rotation flow (`apksigner rotate`) if you have
adopted an APK Signature Scheme v3 rotation lineage. Update the local `keystore.properties` and the
GitHub secrets together whenever the keystore changes.
