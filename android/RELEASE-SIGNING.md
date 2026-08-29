# VortX Android release signing

Every VortX Android release APK/AAB is signed under one persistent upload identity so consecutive
builds share the same signing certificate. This document explains how the signing config is wired,
how to generate the keystore, and how the values are supplied on a dev box and in CI.

The keystore and its passwords are secrets. They are NEVER committed (the tree is public). The
`android/.gitignore` blocks `*.jks` and `*.keystore`. Back the keystore up
somewhere durable and private (a password manager or an encrypted vault): if it is lost, sideload
updates can no longer install over an existing VortX install, because Android refuses an update
signed by a different certificate.

## How the build resolves the signing inputs

`android/app/build.gradle.kts` reads exactly four environment variables:

| Input                     | Meaning                                                                 |
| ------------------------- | ----------------------------------------------------------------------- |
| `VORTX_KEYSTORE_PATH`     | Absolute path to the decoded keystore file used by Gradle.             |
| `VORTX_KEYSTORE_PASSWORD` | The store password.                                                     |
| `VORTX_KEY_ALIAS`         | The key alias inside the keystore.                                      |
| `VORTX_KEY_PASSWORD`      | The private-key password.                                               |

When any Release task is requested, all four values are mandatory. A missing value, a missing or
empty keystore, or an invalid credential fails configuration before packaging. Release tasks never
fall back to an unsigned artifact or the debug signing identity. Debug builds remain independent and
continue to use the generated debug keystore.

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

`keytool` prompts for the credentials. Record both the store password and the private-key password,
even when they are intentionally the same. Gradle requires both inputs and does not infer one from
the other. The alias here is `vortx-upload`; use the alias actually stored in the keystore as
`VORTX_KEY_ALIAS`.

## Local dev signing

Supply the four signing variables only in the process environment. Do not put credentials in Gradle
properties, source files, shell startup files, or command-line arguments:

```bash
export VORTX_KEYSTORE_PATH=/private/path/vortx-upload.jks
export VORTX_KEYSTORE_PASSWORD='from-your-secret-store'
export VORTX_KEY_ALIAS='vortx-upload'
export VORTX_KEY_PASSWORD='from-your-secret-store'
./gradlew assembleFullRelease
./gradlew bundleFullRelease
```

Outputs land at `android/app/build/outputs/apk/full/release/*.apk` and
`android/app/build/outputs/bundle/fullRelease/*.aab`. Verify the signature with the SDK's
`apksigner`:

```bash
"$ANDROID_HOME"/build-tools/*/apksigner verify --verbose \
  android/app/build/outputs/apk/full/release/*.apk
```

## CI signing (GitHub Actions)

Keep signing secrets in the protected `engine-ci` GitHub environment. Do not store them as
repository-wide secrets. The dedicated `.github/workflows/android-release.yml` consumes the
authoritative `VORTX_*` names directly. `VORTX_KEYSTORE_PATH` is intentionally the base64 keystore
blob at the workflow boundary; Gradle receives the path of the decoded temporary file.

The ordinary `.github/workflows/android.yml` uses the parallel `ANDROID_*` names so it can decide
whether to add an optional signed-release proof to its mandatory debug build. If
`ANDROID_KEYSTORE_BASE64` is absent, only those signed-release proof steps are skipped. A requested
Gradle Release task itself still fails closed when any of its four mapped inputs is missing.

Set both naming sets in `engine-ci` from the same verified credential source:

| Dedicated release secret   | Ordinary CI secret              | Value                              |
| -------------------------- | ------------------------------- | ---------------------------------- |
| `VORTX_KEYSTORE_PATH`      | `ANDROID_KEYSTORE_BASE64`       | Base64 of the keystore binary.     |
| `VORTX_KEYSTORE_PASSWORD`  | `ANDROID_KEYSTORE_PASSWORD`     | The verified store password.       |
| `VORTX_KEY_ALIAS`          | `ANDROID_KEY_ALIAS`             | The alias present in the keystore. |
| `VORTX_KEY_PASSWORD`       | `ANDROID_KEY_PASSWORD`          | The verified private-key password. |

Produce the base64 blob for `ANDROID_KEYSTORE_BASE64`:

```bash
# macOS
base64 -i vortx-upload.jks | pbcopy

# Linux (no line wrapping)
base64 -w0 vortx-upload.jks
```

The ordinary CI workflow maps its GitHub secrets onto the Gradle env vars:
`ANDROID_KEYSTORE_PASSWORD` -> `VORTX_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS` -> `VORTX_KEY_ALIAS`,
`ANDROID_KEY_PASSWORD` -> `VORTX_KEY_PASSWORD`, and the decoded keystore path ->
`VORTX_KEYSTORE_PATH`.

Both release APKs and the Play AAB must pass `scripts/verify-android-release-signing.sh`. That verifier
requires the pinned production certificate, rejects the Android Debug identity, requires APK
Signature Scheme v2 for APKs, and performs strict signed-entry verification for the AAB.

## Rotating or replacing the keystore

Because sideloaded updates must be signed by the same certificate, replacing the keystore breaks
in-place updates for existing installs (users would have to uninstall and reinstall). Rotate only when
you accept that break, or use the Android signing key rotation flow (`apksigner rotate`) if you have
adopted an APK Signature Scheme v3 rotation lineage. Update the pinned certificate, both protected
environment naming sets, and the private recovery copy together whenever the keystore changes. A
successful CI build is not sufficient proof unless the produced APKs and AAB pass the pinned-signer
verification step.
