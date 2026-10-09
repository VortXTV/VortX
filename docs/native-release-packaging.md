# Native release packaging

The 0.5 shipping paths select the native engine by default and fail closed when its required
state or artifacts are unavailable. Source selection does not itself establish migration parity,
physical playback, signing or publication. The retained `app/project.yml` still generates the
legacy comparison project; the shipping workflow uses the native generator below. All migration,
independent review, full-build and artifact gates remain required before publication.

## Pinned shipping inputs

The checkout and post-checkout equality assertion in `release-tvos.yml`, `android.yml` and
`android-release.yml` must select one identical, reviewed native source revision. Their current
source contract is `a722eef43f80bd82226215cf460bba2e02869777`. Updating this pin does not establish
private CI, fresh cross-platform SDK, app, signing or release acceptance; those gates must pass
against the final combined public source before shipping. The retained Stremio comparison pin is
`31c66611822043e089f5819ad232a5df93975873`; native packages must not contain its engine or Node runtime.

Apple shipping and secretless validation use the same fresh player archive:

- URL: `https://github.com/VortXTV/VortX/releases/download/vendor-mpvkit-dvfel-2/mpvkit-dvfel-artifacts-ffmpeg9-20261008.zip`
- SHA-256: `ccccc9a3faa84276bf10625d652dd4c9eea04c6a0abdc8e26cb1b35f147514fb`

The FFmpeg9/SecureTransport content and architecture/floor gates remain required after extraction.
The retired FFmpeg8/GnuTLS digest stays explicitly rejected; an override cannot bypass that rejection.
Only public dependency downloads have broad Cargo cache fallback. Native Apple SDK caches are
exact-key-only and content-addressed to the fetched private source and build helper, and Android's
private build cache prefix includes its fetched source contents. Warm artifacts still undergo ABI,
floor, link-input and packaged-content verification; an older run's SDK or APK/IPA is not proof for
the replacement private pin.

The tagless `android.yml` candidate supplies Full and Play debug APKs plus, when signing is
provisioned, a production-signed Full APK and Full AAB. It does not replace `android-release.yml`,
which binds to an existing release tag and verifies production-signed Full/Play universal APKs,
the Play AAB, normalized native payloads, signer, version, GPL boundary and retained provenance
before draft attachment. Android cannot publish; the Apple coordinator retains the cross-platform
draft/feed/publication gates.

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

The protected Apple workflow defaults `native_only` to true and uses the same effective native
selection on push events, where dispatch inputs are absent. Explicit false is an artifact-only
comparison: it cannot target or publish a release, including through coordinator resume. Native
builds use the pinned reviewed MPV archive and SHA-256; an optional override must supply both and
still passes the content gate. ABI, aggregate deployment/OSO, simulator launch/dSYM, signing,
immutable handoff, feed and draft publication gates continue to run. Input, app and final package
receipts travel in the immutable app handoff. The coordinator retains publication authority.

## Android

Absent overrides select `vortx.nativeEngine=true` and a matching resource-host default. An explicit
Gradle property takes precedence over the environment; false or blank retains comparison mode,
and malformed values fail configuration. `vortx.nativeEngine=true` requires the resolved
`vortx.nativeResourceHost=true`; both the repository selection in BuildConfig and the Cargo
resource-host feature follow these decisions. Native mode excludes
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
