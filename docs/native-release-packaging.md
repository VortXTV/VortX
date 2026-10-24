# Native release packaging

The 0.5.6 shipping paths use only the native engine and fail closed when its required
state or artifacts are unavailable. Source selection does not itself establish migration parity,
physical playback, signing or publication. Both `app/project.yml` and the shipping generator use
the native target roster; the generator binds the reviewed source/player inputs. All migration,
independent review, full-build and artifact gates remain required before publication.

## Pinned shipping inputs

The checkout and post-checkout equality assertions in `release-tvos.yml`, `android.yml` and
`android-release.yml` select the identical reviewed source revision
`2ea2e0f27dd2e53b7b28228435ca35a70f92831f` for future Apple/Android builds. This is a source
candidate, not evidence that its Android ABIs or the other Apple slices have been built. Updating
this pin does not establish private CI, fresh cross-platform SDK, app, signing or release
acceptance; those gates must pass against the final combined public source before shipping.
Desktop's manifest and five resolved lock records retain their separately reviewed
`0c30f4782aee544a2b7e33169ad60d03630d4097` pin. Desktop is not one of the seven Apple/Android
release assets; its later source adoption requires an intentional manifest/lock update and its
own build/runtime gates. The Stremio comparison engine and Node runtime have been removed;
native packages must still reject either payload if it reappears.

For a downloaded release, read its pin from that exact source tag and immutable handoff rather
than assuming a moving documentation page describes every older package.

Apple shipping and secretless validation use the same fresh player archive:

- URL: `https://github.com/VortXTV/VortX/releases/download/vendor-mpvkit-dvfel-ffmpeg9-20261021/mpvkit-dvfel-ffmpeg-9.0.2-candidate.zip`
- SHA-256: `f4e4fcc25a61997ee4e74a7ad155d46192f4d86d7953ce1a352da796b8765672`

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
before draft attachment. The Android lane does not publish on its own. Normal coordinated releases
retain cross-platform draft/feed/publication gates. Separately reviewed direct-download beta
workflows bind their own immutable handoffs and final asset set without automatically changing
stable feeds. See [Release artifacts](RELEASE-ARTIFACTS.md) for the current published layout.

## Apple

`scripts/generate-native-apple-project.rb` generates `app/.native-project.yml` from the retained
spec. It selects native iOS, Mac, Full TV and Lite TV plus Top Shelf, with state/resource/data
bridge and an exact native source revision. Full iOS/TV additionally select the
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

The protected Apple workflow retains `native_only` for dispatch compatibility and requires it to
be true. Push events also use the native selection; explicit false fails before a build. Native
builds use the pinned reviewed MPV archive and SHA-256; an optional override must supply both and
still passes the content gate. ABI, aggregate deployment/OSO, simulator launch/dSYM, signing,
immutable handoff and the applicable distribution gates continue to run. Input, app and final package
receipts travel in the immutable app handoff. Original receipt values, including an empty dispatch
release-tag value, remain unchanged; a separate final manifest must not relabel that receipt.

For direct-download betas, an accepted build and a successful prepare step are still not publication.
Review the actual final provenance before attachment, verify the complete draft by content, then
verify unauthenticated tag-bound public downloads after publication. A historical failed verifier
or release-event check stays a failure in the record. Do not reuse packages from another source/tag
or weaken guards to turn it green.

## Android

Every Android build selects the native repository and `jni,server,resource-host`. The former
`vortx.nativeEngine` and `vortx.nativeResourceHost` selectors are accepted only as explicit true
for script compatibility; false, blank and malformed values fail configuration. There is no
comparison BuildConfig field, legacy repository or legacy Cargo task/output. Packages reject
`libstremiox_core.so`.

The protected Android workflows prove the immutable private source pin before promotion, build
with `jni,server,resource-host`. The native-only archive
checker requires exactly the three supported VortX ABI entries, callable JNI/resource/server
exports and the absence of the legacy library. It compares the packaged code with the freshly
staged output after normalizing both with the pinned NDK strip tool, and records the exact source,
features and per-ABI hashes. Production signer, version, Play GPL boundary and draft gates remain.

Full runtime and its native seam consume the same checksum-addressed Android player AAR declared
in `android/mpv-component.properties`. Its source/provenance manifest records the successful
`5774f40f` producer and original dependency source kit. It aligns mpv/libplacebo with the Apple
player and carries FFmpeg9.0.2. Selecting it is not a device playback or live TLS result; the
final app must still pass the native seam, ABI, signing and packaged-content gates.

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
