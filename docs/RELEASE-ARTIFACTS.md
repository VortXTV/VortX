# VortX release artifacts

Use a named [official release](https://github.com/VortXTV/VortX/releases) as the package boundary. Do not mix files from different tags or assume an update feed/download redirect follows every beta.

## Apple packages

| Package pattern | Device and contents |
| --- | --- |
| `VortX-iOS-<tag>-ci.ipa` | iPhone and iPad, iOS/iPadOS 16+ |
| `VortX-tvOS-<tag>-ci.ipa` | Apple TV, tvOS 18+, embedded native streaming transport and Top Shelf |
| `VortX-tvOS-lite-<tag>-ci.ipa` | Apple TV, tvOS 18+, Direct Links Only, no embedded transport or Top Shelf |
| `VortX-macOS-<tag>-ci.dmg` | Apple-silicon Mac, macOS 14+ |

The IPAs need compatible sideload signing. The Mac app is ad-hoc signed, not notarized. Full and Lite use different application identities; they are not interchangeable in-place updates. Archive sizes are not fixed support guarantees.

## Android dimensions

An Android variant describes its **player/distribution**, not a device split. Both APKs contain phone/tablet and Android TV interfaces, including the TV launcher entry.

Both variants contain the phone AND the Android TV activities; neither is a device-specific build.

| Artifact pattern | Contents |
| --- | --- |
| `VortX-<version>-full-mpv-universal.apk` | Sideload build with native GPL libmpv and Media3 routes |
| `VortX-<version>-play-media3-universal.apk` | Media3/ExoPlayer-only variant, without the GPL MPV payload |
| `VortX-<version>-play-media3.aab` | Distribution App Bundle, not directly installable |

Current APKs support Android 8.0/API 26+ and include `arm64-v8a`, `armeabi-v7a`, and `x86_64`. A Play-oriented filename does not mean a Google Play listing is available. Use the same variant and signer when updating; do not uninstall to work around a rejected update.

There are no current phone-only or TV-only release APKs. Old filenames using those labels were misleading. Any consumer that pins an asset name, digest or channel must be reviewed when naming changes; renaming is not automatically safe for a redirect or feed.

| Historical name | Canonical equivalent |
| --- | --- |
| `VortX-x.y.z-phone.apk` | `VortX-x.y.z-full-mpv-universal.apk` |
| `VortX-x.y.z-tv.apk` | `VortX-x.y.z-play-media3-universal.apk` |
| `VortX-x.y.z-play.aab` | `VortX-x.y.z-play-media3.aab` |

## Checksums, signing and provenance

Release layouts have changed over time. For **0.5.6 beta 2/build 276**, the final package set is:

- Four Apple packages and three Android packages.
- `SHA256SUMS.txt`, listing the seven package hashes.
- `VortX-Hosted-Direct-Beta-Provenance.json`, tying packages to the source, hosted runs and verification evidence.

That release's provenance explicitly records its separately reviewed recovery-verification tooling. Do not rewrite an original receipt or describe an unsuccessful historical verifier run as successful. A future release must pass its own current gates.

Android's original immutable build handoff also retains `SHA256SUMS` and `SIGNING_PROVENANCE.txt`. Those temporary evidence files need not appear as separate final release assets when the reviewed combined provenance carries their evidence.

Before upload, the Android signing checks require APK Signature Scheme v2, one signer, no Android Debug certificate and the project's expected production signer. APK/AAB manifests must match the Gradle version identity and application ID. Packaged native payloads, supported ABIs and the Play GPL exclusion are checked separately. Apple checks include actual native input/link identity, minimum OS, package content and applicable signature validation.

Checksums establish byte identity against a manifest, not safety on their own. A workflow success or artifact filename is not enough: source, run/attempt, immutable handoff, extracted content, versions, signer and final public bytes must agree. See [Native release packaging](native-release-packaging.md).

## Installation note required for Mac releases

After instructing users to drag VortX into Applications, include:

```sh
xattr -dr com.apple.quarantine /Applications/VortX.app
```

Explain that this is only for the official VortX app if macOS blocks it. Removing quarantine does not notarize the app or establish its safety. Publishing this instruction does not authorize executing it on anyone's installed app. See [Installation](INSTALLING.md).

## Release channels and validation

Normal coordinated feed publication and a direct-download beta are different workflows. A direct-download beta does not by itself authorize changing stable feeds, download routing, website deployment or backend state.

Secretless pull-request packaging checks use fixture data and, for Android signing exercises, an ephemeral keystore. They cannot prove private-engine package identity, the production signer or physical-device playback. Privileged release lanes and final public readback must supply the missing evidence. Apple sideload/ad-hoc checks must not be mislabeled as Developer ID notarization or App Store acceptance.

The Apple secretless lane generates the actual native-only project and checks compile/link/bundle
mechanics for all four app targets, including both Lite simulator architectures, using marked,
fail-closed native-engine and Mac-server stand-ins. Those stand-ins are not the private ABI or
server and cannot be consumed by the protected release lane. Native engine/runtime behavior is
tested separately against the reviewed private source; a stub-based build cannot certify it.
