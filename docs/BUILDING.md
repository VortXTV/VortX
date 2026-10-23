# Build and source boundaries

This public repository contains the application surfaces and integration code. The current shipping engine depends on private source and approved native artifacts. **A complete shipping build is not available from a public clone alone.** Do not copy proprietary engine source into this repository to make it build.

If you want to use VortX, install the [official packages](INSTALLING.md). Contributors can still review public code, documentation, policies and suitable fixture tests without engine access.

## Apple project generation

`app/project.yml` is the native-only project specification. Release packaging uses `scripts/generate-native-apple-project.rb` to bind the exact reviewed engine revision, player package and linker-map provenance before XcodeGen runs. The retired engine, Node runtime and legacy web-host target are not build options.

The generator requires an explicit reviewed engine revision and a verified MPVKit package. It selects native iOS, Mac, Full TV and Lite TV targets and the Full TV Top Shelf extension, while omitting legacy core/Node payloads. Required native SDKs, headers and the Mac daemon must already exist and pass their input gates.

```sh
ruby scripts/generate-native-apple-project.rb \
  --engine-revision <reviewed-40-hex-revision> \
  --mpvkit <verified-player-package-path> \
  --output "$PWD/app/.native-project.yml"
(cd app && xcodegen generate --spec .native-project.yml)
```

This is project generation, not a complete release command. Consult the exact source revision's `.github/workflows/release-tvos.yml` and [native packaging contract](native-release-packaging.md) for SDK preparation, ABI checks, deployment floors, compilation, signing and content verification. Do not edit generated `.xcodeproj` files or silently substitute an SDK/player from an older run.

The main Apple apps are not all migrated to Swift 6. Changing the language-mode flag is not a substitute for integrating and testing actor/storage/caller ownership across the actual targets.

## Android

The Android project is under `android/`. Its Gradle configuration defines Full MPV and Play Media3 variants, each containing phone and TV UI. Shipping native mode requires the exact engine/resource-host outputs and matching JNI payloads for every supported ABI.

Use the toolchain versions and commands in the exact source's `.github/workflows/android.yml` and `.github/workflows/android-release.yml`. A debug APK or an ephemeral test signer is not a production-signed release. See [Release artifacts](RELEASE-ARTIFACTS.md) for version, signer and GPL-boundary checks.

## Browser and TV wrappers

The [browser client](../webapp/README.md) is a separate frontend with browser playback limits. The [webOS/Tizen wrappers](../platforms/README.md) reuse that output and need platform SDKs/signing plus physical-TV validation. Neither is a substitute for proving the native player or private engine.

## Contributing safely

Follow [CONTRIBUTING.md](../CONTRIBUTING.md), keep a change focused and run proportionate checks. Install/check the engine-source guard through `scripts/install-git-hooks.sh`; do not disable it to push a contribution. Keep credentials, raw customer logs, private URLs and generated engine artifacts out of commits.

Source review, fixture tests, full compilation, package inspection, signing, publication and device behavior are different gates. Document which ones actually passed rather than labeling a partial build fully verified.
