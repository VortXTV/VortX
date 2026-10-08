# Native release packaging

The native build selection is explicit and fail-closed. It is separate from approval of a
default cutover, migration parity, physical playback, signing and publication. The retained
`app/project.yml` still generates the legacy comparison project; production cutover changes
remain subject to the migration, independent review and full build gates.

## Apple

`scripts/generate-native-apple-project.rb` generates `app/.native-project.yml` from the retained
spec. It selects native iOS, Mac, Full TV and Lite TV plus Top Shelf, with state/resource/data
bridge conditions and an exact native source revision. Full iOS/TV additionally select the
real in-process server. Lite keeps its existing no-embedded-server boundary. Mac requires the
separate native daemon and targets the reviewed arm64 SDK. The generated project omits the
legacy core framework, NodeMobile, server.js, Node executable and Node fetch phase.

The generator requires an explicit path to the MPVKit package that passed the existing FFmpeg 9,
dovi_split, architecture and SecureTransport checks. It preserves iOS 16, tvOS 18 and macOS 14
floors. It does not change the version/build numbers from the retained spec.

```sh
ruby scripts/generate-native-apple-project.rb \
  --engine-revision <reviewed-40-hex-native-SHA> \
  --mpvkit <exact-verified-MPVKit-package> --output "$PWD/app/.native-project.yml"
(cd app && xcodegen generate --spec .native-project.yml)
```

After the existing SDK/player content gates pass, `verify-native-apple-package.py snapshot`
captures all five native archives and headers, every rebuilt MPV framework slice, the package
manifest and, for Mac, the daemon. Capture it before app compilation. The `verify` command
requires the app's exact linker map and checks the contributing static archive hashes, native
state/resource/server symbols, source-selection metadata, platform, architecture and deployment
floor. It rejects changed inputs and legacy core/Node contributions. The `verify-archive`
command compares the extracted IPA or mounted DMG with the accepted app payload, allowing only
the existing signing operation; mounted Mac apps must also pass deep, strict signature validation.
The helper requires Python 3.9 or newer and Apple's binary/signing tools.

The protected Apple workflow exposes `native_only` as an explicit, initially off build input.
That path requires an exact reviewed MPV archive URL and SHA-256 and rejects the older published
artifact. ABI, aggregate deployment/OSO, simulator launch/dSYM, signing, immutable handoff, feed
and draft publication gates continue to run. Input, app and final package receipts travel in the
immutable app handoff. The coordinator retains publication authority.

## Android

`vortx.nativeEngine=true` requires `vortx.nativeResourceHost=true`; both the repository selection
in BuildConfig and the Cargo resource-host feature follow these decisions. Native mode excludes
`libstremiox_core.so` and does not attach the legacy Cargo task/output. Explicit non-native
comparison builds retain the legacy route.

The protected Android workflows prove the immutable private source pin before promotion, build
with `jni,server,resource-host`, and check the actual APK/AAB BuildConfig. The native-only archive
checker requires exactly the three supported VortX ABI entries, callable JNI/resource/server
exports and the absence of the legacy library. It compares the packaged code with the freshly
staged output after normalizing both with the pinned NDK strip tool, and records the exact source,
features and per-ABI hashes. Production signer, version, Play GPL boundary and draft gates remain.

Optional Stremio protocol/account import remains a separate host integration requirement. Native
catalog selection must not route that account flow through the legacy data engine or hide it.

## Proportionate checks

```sh
ruby scripts/test-native-apple-project.rb
python3 scripts/tests/test_native_apple_package.py
bash scripts/test-android-native-release-contracts.sh
bash scripts/test-release-orchestration-contracts.sh
```

`test-native-android-artifact-content.py` additionally accepts already built, reviewed JNI libraries
and the pinned NDK tools. It exercises APK/AAB ZIP layouts and negative stale-code, extra-ABI and
legacy-payload cases without compiling native source. Its ZIP fixtures are not installable apps.
Actual optimized app builds and package receipts are still required before cutover or release.
