#!/usr/bin/env bash
# Focused source contracts and executable dirty-state fixtures for the pinned MPVKit-DVFEL
# builder and release artifact gate. No native artifact build, download or publication runs;
# source verification compiles a bounded production Swift helper.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/scripts/build-mpvkit-dvfel.sh"
PATCH="$ROOT/scripts/mpvkit-dvfel.patch"
REFERENCE_PATCH="$ROOT/scripts/mpv-original-http-reference-recipe.patch"
CANCEL_PATCH="$ROOT/scripts/mpv-original-http-cancel-lifetime.patch"
RESPONSE_PATCH="$ROOT/scripts/ffmpeg-response-witness.patch"
GENERATION_PATCH="$ROOT/scripts/ffmpeg-response-generation.patch"
OBSERVATION_PATCH="$ROOT/scripts/mpv-completed-response-observation.patch"
SENT_FFMPEG_PATCH="$ROOT/scripts/ffmpeg-sent-request-evidence.patch"
SENT_MPV_PATCH="$ROOT/scripts/mpv-sent-request-evidence.patch"
PREFIX_PATCH="$ROOT/scripts/mpv-bounded-prefix-request.patch"
TRANSPORT_FFMPEG_PATCH="$ROOT/scripts/ffmpeg-original-transport-evidence.patch"
TRANSPORT_MPV_PATCH="$ROOT/scripts/mpv-original-transport-evidence.patch"
READER_FFMPEG_PATCH="$ROOT/scripts/ffmpeg-finite-reference-reader.patch"
READER_MPV_PATCH="$ROOT/scripts/mpv-finite-reference-reader.patch"
CONSTRUCTOR_PATCH="$ROOT/scripts/mpv-owned-subtitle-constructor.patch"
PUBLICATION_PATCH="$ROOT/scripts/mpv-owned-subtitle-publication.patch"
EDITION_PATCH="$ROOT/scripts/mpv-upstream-edition-title-lifetime.patch"
VERIFY="$ROOT/scripts/verify-mpvkit-dvfel-artifacts.sh"
WORKFLOW="$ROOT/.github/workflows/release-tvos.yml"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# This mode exercises profile dispatch without a native build, compiler, SDK,
# receipt import or package fixture. A nonexistent TMPDIR also proves retirement
# precedes temporary-file creation, as well as package and receipt path checks.
retired_profile_contracts() (
  fixture="$(mktemp -d)"
  trap 'rm -rf "$fixture"' EXIT
  for version in v3 v4 v5 v6; do
    case "$version" in
      v3) profile=native-upgrades-openssl410-v3 ;;
      v4) profile=native-upgrades-openssl410-crypto-v4 ;;
      v5) profile=native-upgrades-openssl410-crypto-subtitles-v5 ;;
      v6) profile=native-upgrades-openssl410-crypto-subtitles-bluray150-v6 ;;
    esac
    for form in compact complete; do
      args=("$fixture/missing-package" --dependency-profile "$profile")
      if [ "$form" = complete ]; then
        args+=(--shaderc-inputs "$fixture/missing-shaderc" --openssl-builds "$fixture/missing-openssl.json")
        if [ "$version" != v3 ]; then args+=(--crypto-work "$fixture/missing-crypto"); fi
      fi
      if TMPDIR="$fixture/missing-temp-root" /bin/bash "$VERIFY" "${args[@]}" >"$fixture/$version-$form.log" 2>&1; then
        fail "$version/$form historical prototype was accepted"
      fi
      expected="MPVKit-DVFEL ARTIFACT VERIFY FAILED: historical $version prototype requires its frozen historical verifier; select the explicit bluray150 v6 profile for the four-source candidate"
      if [ "$version" = v6 ]; then expected="MPVKit-DVFEL ARTIFACT VERIFY FAILED: historical v6 requires its frozen reader; select the explicit freetype2150/libdovi340 v7 profile"; fi
      [ "$(cat "$fixture/$version-$form.log")" = "$expected" ] ||
        fail "$version/$form did not retire before artifact, receipt and temporary-file checks"
    done
  done
  # Retiring prototypes must not intercept the default, v1/v2, or active v7 API.
  for profile in shipping libplacebo-7.387.0-lcms2.20rc1-source-v1 native-upgrades-dav1d154-shaderc20261-hb150-v2 native-upgrades-openssl410-crypto-subtitles-bluray150-freetype2150-libdovi340-v7; do
    args=("$fixture/missing-package")
    if [ "$profile" != shipping ]; then args+=(--dependency-profile "$profile"); fi
    if [ "$profile" = native-upgrades-dav1d154-shaderc20261-hb150-v2 ] ||
       [ "$profile" = native-upgrades-openssl410-crypto-subtitles-bluray150-freetype2150-libdovi340-v7 ]; then
      args+=(--shaderc-inputs "$fixture/missing-shaderc")
    fi
    if [ "$profile" = native-upgrades-openssl410-crypto-subtitles-bluray150-freetype2150-libdovi340-v7 ]; then
      args+=(--openssl-builds "$fixture/missing-openssl.json" --crypto-work "$fixture/missing-crypto")
    fi
    if /bin/bash "$VERIFY" "${args[@]}" >"$fixture/current.log" 2>&1; then
      fail "$profile accepted a missing package"
    fi
    [ "$(cat "$fixture/current.log")" = "MPVKit-DVFEL ARTIFACT VERIFY FAILED: missing package manifest: $fixture/missing-package/Package.swift" ] ||
      fail "$profile did not retain its current package dispatch"
  done
)

if [ "${1:-}" = --retired-profiles-only ]; then
  [ "$#" -eq 1 ] || fail "usage: test-mpvkit-dvfel-artifact-contracts.sh [--retired-profiles-only]"
  retired_profile_contracts
  echo "PASS: retired v3/v4/v5/v6 reject before artifact checks; shipping/v1/v2/v7 dispatch retained"
  exit 0
fi
[ "$#" -eq 0 ] || fail "usage: test-mpvkit-dvfel-artifact-contracts.sh [--retired-profiles-only]"
retired_profile_contracts

for file in "$BUILD" "$PATCH" "$REFERENCE_PATCH" "$CANCEL_PATCH" "$RESPONSE_PATCH" "$GENERATION_PATCH" "$OBSERVATION_PATCH" "$SENT_FFMPEG_PATCH" "$SENT_MPV_PATCH" "$PREFIX_PATCH" "$TRANSPORT_FFMPEG_PATCH" "$TRANSPORT_MPV_PATCH" "$READER_FFMPEG_PATCH" "$READER_MPV_PATCH" "$CONSTRUCTOR_PATCH" "$PUBLICATION_PATCH" "$EDITION_PATCH" "$VERIFY" "$WORKFLOW"; do
  [ -f "$file" ] || fail "missing required source: $file"
done

grep -Eq '^MPVKIT_REF="[0-9a-f]{40}"' "$BUILD" || fail "builder must retain one full MPVKit source pin"
grep -Fq 'MPVKIT_DIR="${MPVKIT_DVFEL_WORK:-$REPO/../MPVKit}"' "$BUILD" ||
  fail "builder default must use the canonical MPVKit sibling checkout"
grep -Fq 'DEST="${MPVKIT_DVFEL_DEST:-$REPO/_build/MPVKit-DVFEL}"' "$BUILD" ||
  fail "builder must stage by default in canonical _build"
if grep -Fq '$HOME/.cache/vortx-mpvkit-dvfel' "$BUILD"; then
  fail "builder must not silently use a HOME cache as its default source"
fi
if grep -Fq 'git checkout --quiet -- .' "$BUILD"; then
  fail "builder must not reset tracked user changes"
fi
grep -Fq 'git -C "$MPVKIT_DIR" rev-parse HEAD' "$BUILD" || fail "builder must validate an existing checkout HEAD"
grep -Fq 'FRESH_HEAD' "$BUILD" || fail "builder must assert the fresh clone resolved to the exact pin"
grep -Fq 'matches_exact_patch_tree' "$BUILD" || fail "builder must prove the complete approved patch tree"
grep -Fq 'exact MPVKit patch already applied' "$BUILD" || fail "builder must support an explicit exact-patch retry"
grep -Fq 'existing generated patch differs' "$BUILD" || fail "builder must not overwrite a changed generated patch"
grep -Fq 'diff --git a/Sources/BuildScripts/patch/libmpv/0002-revert-build-static.patch b/Sources/BuildScripts/patch/libmpv/0002-revert-build-static.patch' "$PATCH" ||
  fail "approved MPVKit tree must carry the exact Swift frontend recipe correction"
grep -Fq "+    swift_flags = ['-frontend', '-c', '-whole-module-optimization', '-sdk', macos_sdk_path," "$PATCH" ||
  fail "one-object Swift frontend recipe must request whole-module compilation"

# The Swift patch must request command output explicitly: Utility.shell returns an empty string on
# success otherwise, which would make a correct rev/status look absent. It must also reject arbitrary
# dirty state instead of treating a reverse hunk check as a full-tree proof.
grep -Fq 'Utility.shell(command, isOutput: true, currentDirectoryURL: directoryURL)' "$PATCH" ||
  fail "SpikeGit output/success checks must request shell output explicitly"
grep -Fq 'matchesExactPatchTree' "$PATCH" || fail "SpikeGit must compare the complete tree to the approved patch set"
grep -Fq 'git status --porcelain --untracked-files=all' "$PATCH" || fail "SpikeGit must inspect dirty state"
if grep -Fq 'test -z \\\"$(git status --porcelain --untracked-files=all)\\\"' "$PATCH"; then
  fail "SpikeGit must not require an exact applied checkout to have an empty status"
fi
grep -Fq 'git diff --cached --quiet' "$PATCH" || fail "SpikeGit must reject staged changes"
grep -Fq 'git rev-parse HEAD' "$PATCH" || fail "SpikeGit must validate an existing HEAD"
grep -Fq 'expected exact pin' "$PATCH" || fail "SpikeGit must assert the fresh checkout pin"
grep -Fq 'git apply --reverse --check' "$PATCH" || fail "SpikeGit must support an exact already-applied patch"
grep -Fq 'patch neither applies cleanly nor is already applied' "$PATCH" || fail "SpikeGit must fail actionable patch conflicts"

# The next fixed dependency profile retains the shipping verifier and requires
# a source-built dav1d framework plus the two pinned Shaderc input bodies/receipt.
grep -Fq 'native-upgrades-dav1d154-shaderc20261-hb150-v2' "$VERIFY" || fail "v2 verifier profile missing"
grep -Fq 'for library in Libmpv Libavcodec Libavdevice Libavfilter Libavformat Libavutil Libswresample Libswscale Libplacebo lcms2 Libdav1d Libssl Libcrypto gmp nettle hogweed gnutls Libsmbclient Libunibreak Libfribidi Libharfbuzz Libbluray; do' "$BUILD" || fail "combined candidate must require all twenty-two fresh ZIPs"
grep -Fq 'apple-shaderc-inputs "$WORK"' "$BUILD" || fail "Shaderc inputs must be compared before acceptance"
grep -Fq 'private class BuildDav1d: BaseBuild' "$PATCH" || fail "dav1d must use exact source build route"
grep -Fq 'static let dav1dPinnedSHA = "54706fc6bc0cdecab7e9593974a4039cc038fca7"' "$PATCH" || fail "dav1d source pin differs"
grep -Fq '"-Dxxhash_muxer=disabled"' "$PATCH" || fail "dav1d option type changed"
grep -Fq 'return "2026.1.0"' "$PATCH" || fail "Shaderc wrapper selector differs"
grep -Fq '77a3d355993cf53843a394bf58262dab99cdd93f9e6fe31d5ca6e55b03866ce1' "$PATCH" || fail "Shaderc XCFramework hash differs"
grep -Fq 'd213fa58de7886846fb8cb713ea5213b77654a3ad2ba3d89b1f2fe367d945ba5' "$PATCH" || fail "Shaderc all-ZIP hash differs"
grep -Fq 'DEPENDENCY_PROFILE=shipping' "$VERIFY" || fail "default shipping contract changed"
grep -Fq 'apple-shaderc-receipt "$SHADERC_INPUTS"' "$VERIFY" || fail "candidate must require Shaderc receipt"
grep -Fq 'dav1d_version_api' "$VERIFY" || fail "dav1d identity gate missing actual code check"

# The combined crypto profile is opt-in and keeps the helper/source closure explicit. The default
# shipping branch and v1/v2 candidate APIs retain their existing inputs.
grep -Fq 'native-upgrades-openssl410-crypto-subtitles-bluray150-freetype2150-libdovi340-v7' "$BUILD" || fail "combined source profile missing"
grep -Fq 'native-upgrades-openssl410-crypto-v4' "$VERIFY" || fail "combined verifier profile missing"
grep -Fq 'native-upgrades-crypto-chain-v1' "$BUILD" || fail "subordinate crypto capture profile missing"
grep -Fq 'crypto-release-sources.py' "$BUILD" || fail "release source helper invocation missing"
grep -Fq 'crypto-chain-gate.py' "$BUILD" || fail "crypto chain gate invocation missing"
grep -Fq '3c310499d446eed72eb16521b27c16f718f23e7ab1472dec1fad79cc40ed1537' "$BUILD" || fail "builder helper hash binding missing"
grep -Fq '041dd13e48e1821f5d7bf049bb8eb097d3772d6ea867c15a3b7646779a3c015d' "$VERIFY" || fail "verifier helper hash binding missing"
grep -Fq '69a180d417c8295d723ec3eb904d93414d668e55e15d9902f93718bdcfbe0485' "$BUILD" || fail "v6 GNU optimization gate helper binding missing"
grep -Fq '69a180d417c8295d723ec3eb904d93414d668e55e15d9902f93718bdcfbe0485' "$VERIFY" || fail "v6 verifier optimization gate helper binding missing"
grep -Fq 'swift run --jobs 1 --build-path' "$BUILD" || fail "SwiftPM jobs-one guard missing"
grep -Fq 'apple-crypto-source-gmp.tar.xz' "$ROOT/scripts/native-media-hosted/build.sh" || fail "hosted crypto source output missing"
grep -Fq 'apple-crypto-chain.json' "$ROOT/scripts/native-media-hosted/build.sh" || fail "hosted crypto receipt output missing"

# Subtitle source successor is opt-in and keeps the current crypto/TLS/headroom contract. These
# checks bind the four source classes and fixed helper/body boundaries without asserting unbuilt
# ZIP contents or inventing numeric header values.
grep -Fq 'native-upgrades-openssl410-crypto-subtitles-bluray150-freetype2150-libdovi340-v7' "$BUILD" || fail "subtitle candidate profile missing"
grep -Fq 'native-upgrades-openssl410-crypto-subtitles-bluray150-freetype2150-libdovi340-v7' "$VERIFY" || fail "subtitle verifier profile missing"
grep -Fq 'subtitle-release-sources.py' "$BUILD" || fail "subtitle release source helper invocation missing"
grep -Fq 'subtitle-release-sources.py' "$VERIFY" || fail "subtitle verifier helper invocation missing"
grep -Fq 'apple-subtitle-builds' "$BUILD" || fail "subtitle build receipt producer invocation missing"
grep -Fq 'apple-subtitle-receipt' "$BUILD" || fail "subtitle build receipt validation invocation missing"
grep -Fq 'dist/subtitle-builds/vortx-subtitle-builds.json' "$BUILD" || fail "subtitle build receipt output path differs"
grep -Fq 'apple-subtitle-receipt' "$VERIFY" || fail "subtitle build receipt verifier invocation missing"
grep -Fq 'dist/subtitle-builds/vortx-subtitle-builds.json' "$VERIFY" || fail "subtitle build receipt path differs"
grep -Fq 'd09496535e49241575093692846de60b9e5948819d6540c4002047d12b5d37f3' "$BUILD" || fail "subtitle helper hash binding missing"
grep -Fq 'd09496535e49241575093692846de60b9e5948819d6540c4002047d12b5d37f3' "$VERIFY" || fail "subtitle verifier helper hash binding missing"
grep -Fq '9c4fad6e517338a098373acc9f35579ae2c325e6446666fb9ac2666ba15ceba4' "$BUILD" || fail "Unibreak archive digest missing"
grep -Fq '1088508' "$BUILD" || fail "Unibreak archive size binding missing"
grep -Fq '6949dcde27d41cebad1fd741fcafc36d55a1020d2d872d4a6eb3914caabbada2' "$BUILD" || fail "FriBidi archive digest missing"
grep -Fq '968536e9abd782f07f7954044c0c4020199fcdd39b41d221ec42d2a3be4a44df' "$BUILD" || fail "HarfBuzz archive digest missing"
grep -Fq '33554432' "$BUILD" || fail "HarfBuzz archive cap missing"
grep -Fq '1203284' "$BUILD" || fail "FriBidi archive size missing"
grep -Fq '20396372' "$BUILD" || fail "HarfBuzz archive size missing"
grep -Fq 'SUBTITLE_SOURCE_HELPER" capture' "$BUILD" || fail "subtitle source capture missing"
grep -Fq 'SUBTITLE_SOURCE_HELPER" verify-capture' "$BUILD" || fail "subtitle capture revalidation missing"
grep -Fq 'Libunibreak:Libunibreak' "$ROOT/scripts/assemble-mpvkit-dvfel.sh" || fail "Unibreak local assembly mapping missing"
grep -Fq 'Libfribidi:Libfribidi' "$ROOT/scripts/assemble-mpvkit-dvfel.sh" || fail "FriBidi local assembly mapping missing"
grep -Fq 'Libharfbuzz:Libharfbuzz' "$ROOT/scripts/assemble-mpvkit-dvfel.sh" || fail "HarfBuzz local assembly mapping missing"
grep -Fq 'Libunibreak Libfribidi Libharfbuzz' "$VERIFY" || fail "subtitle local target set missing"
grep -Fq 'UNIBREAK_VERSION' "$VERIFY" || fail "Unibreak version macro gate missing"
grep -Fq 'set_linebreaks_utf8' "$VERIFY" || fail "Unibreak public symbol gate missing"
grep -Fq 'set_wordbreaks_utf8' "$VERIFY" || fail "Unibreak word-break symbol gate missing"
grep -Fq 'FRIBIDI_MAJOR_VERSION' "$VERIFY" || fail "FriBidi version macro gate missing"
grep -Fq 'fribidi_version_info' "$VERIFY" || fail "FriBidi public symbol gate missing"
grep -Fq 'HB_VERSION_MAJOR' "$VERIFY" || fail "HarfBuzz version macro gate missing"
grep -Fq 'hb_version_string' "$VERIFY" || fail "HarfBuzz public symbol gate missing"
grep -Fq 'private class BuildUnibreak: PinnedSubtitleReleaseBuild' "$PATCH" || fail "Unibreak source builder class missing"
grep -Fq 'private class BuildFribidi: PinnedSubtitleReleaseBuild' "$PATCH" || fail "FriBidi source builder class missing"
grep -Fq 'private class BuildHarfbuzz: PinnedSubtitleReleaseBuild' "$PATCH" || fail "HarfBuzz source builder class missing"
grep -Fq 'apple-subtitle-source-unibreak.tar.gz' "$ROOT/scripts/native-media-hosted/build.sh" || fail "hosted Unibreak source output missing"
grep -Fq 'apple-subtitle-source-fribidi.tar.xz' "$ROOT/scripts/native-media-hosted/build.sh" || fail "hosted FriBidi source output missing"
grep -Fq 'apple-subtitle-source-harfbuzz.tar.xz' "$ROOT/scripts/native-media-hosted/build.sh" || fail "hosted HarfBuzz source output missing"
grep -Fq 'apple-subtitle-builds.json' "$ROOT/scripts/native-media-hosted/build.sh" || fail "hosted subtitle build receipt output missing"
grep -Fq 'dist/subtitle-builds/vortx-subtitle-builds.json' "$ROOT/scripts/native-media-hosted/build.sh" || fail "hosted subtitle build receipt input path differs"

# v6 is a new schema; unshipped v3/v4/v5 prototypes must not be reinterpreted.
grep -Fq 'historical v3 prototype requires its frozen historical verifier' "$VERIFY" || fail "v3 must fail with its historical API scope"
grep -Fq 'historical v4 prototype requires its frozen historical verifier' "$VERIFY" || fail "v4 must fail with its historical API scope"
grep -Fq 'historical v5 prototype requires its frozen historical verifier' "$VERIFY" || fail "v5 must fail with its historical API scope"
grep -Fq 'subtitle-sources-v3' "$BUILD" || fail "caller must bind the four-member state path"
grep -Fq 'extend-bluray "$WORK" "$stage"' "$BUILD" || fail "fixed legacy-three extension path missing"
grep -Fq '473072' "$BUILD" || fail "official bluray body length missing"
grep -Fq 'f676408e91a5d321abf8b8d4dfdae36205c297dab5c54c3ec519639025f474a2' "$BUILD" || fail "official bluray body digest missing"
grep -Fq 'SRC_BLURAY=$subtitle_work/dist/libbluray-1.5.0-f676408e' "$BUILD" || fail "fourth source must be readonly during native build"
grep -Fq 'private class BuildBluray: PinnedSubtitleReleaseBuild' "$PATCH" || fail "bluray must reuse the pinned release builder"
grep -Fq '"--force-fallback-for=libudfread"' "$PATCH" || fail "bundled UDF selection must be explicit"
grep -Fq '"-Dbdj_jar=disabled"' "$PATCH" || fail "retained BD-J JAR policy missing"
grep -Fq 'Libbluray:Libbluray' "$ROOT/scripts/assemble-mpvkit-dvfel.sh" || fail "bluray local assembly mapping missing"
grep -Fq 'BLURAY_VERSION_STRING' "$VERIFY" || fail "bluray installed release gate missing"
grep -Fq 'udfread_open' "$VERIFY" || fail "embedded UDF code gate missing"
grep -Fq 'apple-bluray-source.tar.xz' "$ROOT/scripts/native-media-hosted/build.sh" || fail "hosted original bluray source output missing"

# OpenSSL latest-stable candidate is an exact source build with an explicit Apple target configuration.
grep -Fq 'private class BuildOpenSSL: BaseBuild' "$PATCH" || fail "OpenSSL must use source route"
grep -Fq 'static let opensslPinnedSHA = "2f4e3a5fec05394068cfa7379890ab552483a8a6"' "$PATCH" || fail "OpenSSL source pin differs"
grep -Fq 'vortx-openssl-target.conf' "$PATCH" || fail "OpenSSL target configuration missing"
grep -Fq '+        let shippingFlags = cFlags(platform: platform, arch: arch).joined(separator: " ") + " -O3"' "$PATCH" || fail "OpenSSL must restore the upstream release optimization explicitly"
grep -Fq '+        environ["CFLAGS"] = shippingFlags' "$PATCH" || fail "OpenSSL C flags must include release optimization"
grep -Fq '+        environ["CXXFLAGS"] = shippingFlags' "$PATCH" || fail "OpenSSL C++ flags must include release optimization"
grep -Fq '"build_sw"' "$PATCH" || fail "OpenSSL software build phase missing"
grep -Fq '"install_sw"' "$PATCH" || fail "OpenSSL software install phase missing"
grep -Fq 'arguments: ["-j1", "build_sw"]' "$PATCH" || fail "new OpenSSL build must use jobs one"
grep -Fq 'arguments: ["-j1", "install_sw"]' "$PATCH" || fail "new OpenSSL install must use jobs one"
grep -Fq 'apple-openssl-builds "$WORK"' "$BUILD" || fail "OpenSSL build evidence missing"
grep -Fq 'PASS openssl-profile openssl-4.1.0-source-v1' "$VERIFY" || fail "OpenSSL latest-stable candidate content receipt missing"

# The new OpenSSL provider must not change the selected Apple FFmpeg backend.
grep -Fq 'arguments += ["--disable-gnutls", "--disable-openssl", "--enable-securetransport"]' "$PATCH" || fail "FFmpeg OpenSSL autodetection must remain disabled"
grep -Fq 'CONFIG_OPENSSL 0' "$ROOT/scripts/verify-mpvkit-dvfel-apple-tls.sh" || fail "real Apple artifact gate must require CONFIG_OPENSSL 0"

# Future producer source contracts are distinct from current shipping binary gates.
RESPONSE_HASH="$(shasum -a 256 "$RESPONSE_PATCH")"
[ "${RESPONSE_HASH%% *}" = "6a2bf6d0feff31280470ac46e9c56b2e0a4522513959784dcb04aaf196334b9b" ] ||
  fail "FFmpeg response-witness carrier differs from the exact reviewed 946 delta"
grep -Fq '"$MPVKIT_DIR/Sources/BuildScripts/patch/FFmpeg/0001-response-witness.patch"' "$BUILD" ||
  fail "Apple must put the response witness in the FFmpeg patch sequence"
grep -Fq 'copy_exact "$RESPONSE_PATCH" "$GENERATED_RESPONSE_PATCH"' "$BUILD" ||
  fail "Apple must preserve exact response-witness patch-copy semantics"
# The separately pinned response delta precedes this complete final composition.
grep -Fq 'd1301474b4389256f9862565a399a8888366a68d2e3630338848289fe8a9c831' "$BUILD" ||
  fail "Apple must require the exact reviewed HTTP source composition"
GENERATION_HASH="$(shasum -a 256 "$GENERATION_PATCH")"
[ "${GENERATION_HASH%% *}" = "ddfb68b5d7ed3779cfa69a75a28e9d4b17bd4f28529cccf26a005e790da03098" ] ||
  fail "FFmpeg response-generation carrier differs from the reviewed delta"
OBSERVATION_HASH="$(shasum -a 256 "$OBSERVATION_PATCH")"
[ "${OBSERVATION_HASH%% *}" = "c038924be4c9b0ef187e1e9336d201b866dfa6f13457817c6e8c2d484e882e8e" ] ||
  fail "MPV completed-response observation carrier differs from the reviewed delta"
grep -Fq 'copy_exact "$RESPONSE_GENERATION_PATCH" "$GENERATED_RESPONSE_GENERATION_PATCH"' "$BUILD" ||
  fail "Apple must preserve exact response-generation patch-copy semantics"
grep -Fq 'copy_exact "$REPO/scripts/mpv-completed-response-observation.patch"' "$BUILD" ||
  fail "Apple must install the owned observation after original-cancel lifetime"
SENT_FFMPEG_HASH="$(shasum -a 256 "$SENT_FFMPEG_PATCH")"
[ "${SENT_FFMPEG_HASH%% *}" = "085b66cb5623ed8087481d3217b65da587b2970cd345a45896e7e87823dec9c9" ] ||
  fail "FFmpeg sent-request carrier differs from the reviewed source"
SENT_MPV_HASH="$(shasum -a 256 "$SENT_MPV_PATCH")"
[ "${SENT_MPV_HASH%% *}" = "e3840084725be1f4948fb90c6fec87c35d55665f8310854713ebff496e1358bf" ] ||
  fail "MPV sent-request carrier differs from the reviewed source"
grep -Fq 'copy_exact "$SENT_FFMPEG_PATCH" "$GENERATED_SENT_FFMPEG_PATCH"' "$BUILD" ||
  fail "Apple must retain the exact FFmpeg sent-request generated copy"
grep -Fq 'copy_exact "$SENT_MPV_PATCH" "$GENERATED_SENT_MPV_PATCH"' "$BUILD" ||
  fail "Apple must retain the exact MPV sent-request generated copy"
grep -Fq 'native-media-hosted/evidence.py" apple-sent-abi "$STAGED_DEST"' "$BUILD" ||
  fail "future Apple component must run its additional real sent-request ABI gate"
PREFIX_HASH="$(shasum -a 256 "$PREFIX_PATCH")"
[ "${PREFIX_HASH%% *}" = "edcfdc7d9d8da7f8a44b19d326a809de844be968cc8061b80744229da801331e" ] ||
  fail "MPV bounded-prefix request carrier differs from the reviewed source"
grep -Fq 'copy_exact "$PREFIX_PATCH" "$GENERATED_PREFIX_PATCH"' "$BUILD" ||
  fail "Apple must retain the exact bounded-prefix generated copy"
TRANSPORT_FFMPEG_HASH="$(shasum -a 256 "$TRANSPORT_FFMPEG_PATCH")"
[ "${TRANSPORT_FFMPEG_HASH%% *}" = "480302686b9fff135cd0665e7af76d635fc21d83f54ee0096578ddd6bd6d83e5" ] ||
  fail "FFmpeg original-transport carrier differs from the reviewed source"
TRANSPORT_MPV_HASH="$(shasum -a 256 "$TRANSPORT_MPV_PATCH")"
[ "${TRANSPORT_MPV_HASH%% *}" = "dad7f2d20ea14eb4661ef853978be78806e1b01fce67653e3ffec9b57d4a0e82" ] ||
  fail "MPV original-transport carrier differs from the reviewed source"
grep -Fq 'copy_exact "$TRANSPORT_FFMPEG_PATCH" "$GENERATED_TRANSPORT_FFMPEG_PATCH"' "$BUILD" ||
  fail "Apple must retain the exact FFmpeg original-transport generated copy"
grep -Fq 'copy_exact "$TRANSPORT_MPV_PATCH" "$GENERATED_TRANSPORT_MPV_PATCH"' "$BUILD" ||
  fail "Apple must retain the exact MPV original-transport generated copy"
READER_FFMPEG_HASH="$(shasum -a 256 "$READER_FFMPEG_PATCH")"
[ "${READER_FFMPEG_HASH%% *}" = "a06f4b8b9eadc12eace93b1b340e0555116061188d0674f063698ea75d953abd" ] ||
  fail "FFmpeg finite-reader carrier differs from the reviewed source"
READER_MPV_HASH="$(shasum -a 256 "$READER_MPV_PATCH")"
[ "${READER_MPV_HASH%% *}" = "42c020f9f6550af5072a8eff1b5860249bb9df5f9418855cb4636cd15854f7f2" ] ||
  fail "MPV finite-reader carrier differs from the reviewed source"
grep -Fq 'copy_exact "$READER_FFMPEG_PATCH" "$GENERATED_READER_FFMPEG_PATCH"' "$BUILD" ||
  fail "Apple must retain the exact finite-reader FFmpeg generated copy"
grep -Fq 'copy_exact "$READER_MPV_PATCH" "$GENERATED_READER_MPV_PATCH"' "$BUILD" ||
  fail "Apple must retain the exact finite-reader MPV generated copy"
grep -Fq 'Sources/BuildScripts/patch/FFmpeg/0005-finite-reference-reader.patch' "$BUILD" ||
  fail "Apple finite-reader FFmpeg patch must follow the original-transport patch"
grep -Fq 'Sources/BuildScripts/patch/libmpv/0019-finite-reference-reader.patch' "$BUILD" ||
  fail "Apple finite-reader MPV patch must follow the original-transport patch"
# These ten producer source hashes do not substitute for applying the full FFmpeg
# sequence to its genuine n9.0.2 source, which remains a separate source-build gate.
for hash in d1301474b4389256f9862565a399a8888366a68d2e3630338848289fe8a9c831 \
  14e3acc5a6715d48edb3dadb2f5248deaa38c36b30ff763e9be4b89edf2b1a0c \
  16bf38abc7a5b5586268c71723041df2b90b7b99a8fbaeb06c8b20926534fe7a \
  cc9c11534ff5017d5931bb06788f95f10e9809953e5ec1cc03114a3a877cdcce \
  0f07be92b62cefb53c6db5552951c658c756fac36ce22b03ccca8a044f1911f2 \
  a8c74f929942423550dba65f738fd4d2ad2d63d975665f64e6da1b00f5001645 \
  e0ccea8466e28169d0882fd664081baa09d3a39626d5351a31804b6dc4bb4e94 \
  adaeb9d58c20ba3305bce4784205c20d6276ba67a758a9ec7207c850c7ba8d87 \
  fa5f8e163d9368b30db6a9c7f0c69ed36e91d6a23ca409b7ba468c7d2282751c \
  0e3201c26657765a1e6e7a15fe9db1bcac5cf96a8cb7e9d691533e0f4bf3f15f; do
  grep -Fq "$hash" "$BUILD" || fail "Apple builder lacks a reviewed finite-reader FFmpeg source hash: $hash"
done

# The artifact verifier must inspect content, not only checksums or mtimes.
grep -Fq 'LIBAVCODEC_VERSION_MAJOR' "$VERIFY" || fail "artifact gate must inspect libavcodec major"
grep -Fq 'LIBAVFORMAT_VERSION_MAJOR' "$VERIFY" || fail "artifact gate must inspect libavformat major"
grep -Fq 'LIBAVCODEC_VERSION_MAJOR[[:space:]]+63' "$VERIFY" || fail "artifact gate must require libavcodec major 63"
grep -Fq 'LIBAVFORMAT_VERSION_MAJOR[[:space:]]+63' "$VERIFY" || fail "artifact gate must require libavformat major 63"
grep -Fq 'verify_ffmpeg_maintenance "$target" "$headers" "$slice"' "$VERIFY" ||
  fail "artifact gate must reject the superseded 63.1.100 artifact in every FFmpeg slice"
grep -Fq '${prefix}_VERSION_MINOR[[:space:]]+1' "$VERIFY" || fail "artifact gate must require maintenance minor 1"
grep -Fq '${prefix}_VERSION_MICRO[[:space:]]+102' "$VERIFY" || fail "artifact gate must require maintenance micro 102"
grep -Fq 'ffmpegPinnedSHA = "946fcce07b6dcd0331c8cc609192aeff5e1924f8"' "$PATCH" ||
  fail "builder must bind the reviewed n9.0.2 commit"
grep -Fq 'ffmpegPinnedBranch = "n9.0.2"' "$PATCH" || fail "builder must fetch the reviewed release tag"
grep -Fq 'Libmpv-GPL; do' "$VERIFY" || fail "artifact gate must validate Libmpv slices"
grep -Fq 'expected_arches' "$VERIFY" || fail "artifact gate must require exact per-slice architectures"
grep -Fq 'tvos-arm64_arm64e' "$VERIFY" || fail "artifact gate must enumerate the tvOS arm64e slice"
grep -Fq 'dovi_split' "$VERIFY" || fail "artifact gate must require dovi_split"
grep -Fq 'if [ "$target" = Libavcodec-GPL ]; then' "$VERIFY" ||
  fail "artifact gate must scope dovi_split to libavcodec"
grep -Fq 'verify-mpvkit-dvfel-apple-tls.sh' "$VERIFY" || fail "artifact gate must retain TLS verification"

# Extract the real fetch step and require the verifier after unzip, before the next workflow step.
fetch_step="$(awk '/^[[:space:]]+- name: Fetch the MPVKit-DVFEL artifacts/{active=1; next}
  active && /^[[:space:]]+- name:/{exit} active{print}' "$WORKFLOW")"
grep -Fq 'unzip -oq /tmp/mpvkit.zip -d "$DEST"' <<<"$fetch_step" ||
  fail "release fetch step must unpack the pinned artifact"
grep -Fq 'bash scripts/verify-mpvkit-dvfel-artifacts.sh "$DEST"' <<<"$fetch_step" ||
  fail "release fetch step must run the real MPV artifact verifier"
unzip_line="$(grep -nF 'unzip -oq /tmp/mpvkit.zip -d "$DEST"' <<<"$fetch_step" | cut -d: -f1)"
verify_line="$(grep -nF 'bash scripts/verify-mpvkit-dvfel-artifacts.sh "$DEST"' <<<"$fetch_step" | cut -d: -f1)"
[ "$verify_line" -gt "$unzip_line" ] || fail "artifact verifier must run after unpack"

# Exercise the production builder preflight against a tiny local Git fixture. The approved patch is
# generated from the fixture's clean base, then the same builder is run for a clean apply, an exact
# patched retry including tracked 0002, unrelated/partial recipe edits, and an unknown untracked
# file. No native build tools are used: the builder exits only after checkout/patch preflight.
TEST_BUILD_ROOT="$ROOT/.build"
mkdir -p "$TEST_BUILD_ROOT"
FIXTURE="$(mktemp -d "$TEST_BUILD_ROOT/mpvkit-contract.XXXXXX")"
TOOLS="$FIXTURE/tools"
SOURCE="$FIXTURE/mpvkit"
FIXTURE_PATCH="$FIXTURE/approved.patch"
mkdir -p "$TOOLS" "$SOURCE"
cleanup_fixture() {
  local status=$?
  if [ "$status" -ne 0 ]; then
    echo "Retained failed contract fixture: $FIXTURE" >&2
    return "$status"
  fi
  rm -rf "$FIXTURE"
  rmdir "$TEST_BUILD_ROOT" 2>/dev/null || true
}
trap cleanup_fixture EXIT

# A verified component ZIP also contains root files such as .gitignore that already
# exist in the vendor directory. Both real consumers must extract without a stdin
# prompt; do not mistake an EOF prompt failure for bad native payload contents.
SHELL_WORKFLOW="$ROOT/.github/workflows/release-packaging-validation.yml"
grep -Fq 'unzip -oq "$RUNNER_TEMP/mpvkit.zip" -d "$DEST"' "$SHELL_WORKFLOW" ||
  fail "secretless consumer must noninteractively unpack the verified artifact"
mkdir -p "$FIXTURE/extract-source/artifacts" "$FIXTURE/extract-destination"
printf 'verified component root\n' > "$FIXTURE/extract-source/.gitignore"
printf 'verified payload\n' > "$FIXTURE/extract-source/artifacts/payload"
printf 'previous vendor root\n' > "$FIXTURE/extract-destination/.gitignore"
(
  cd "$FIXTURE/extract-source"
  zip -q "$FIXTURE/collision.zip" .gitignore artifacts/payload
)
unzip -oq "$FIXTURE/collision.zip" -d "$FIXTURE/extract-destination" < /dev/null
cmp "$FIXTURE/extract-source/.gitignore" "$FIXTURE/extract-destination/.gitignore" ||
  fail "noninteractive unpack did not replace the known existing component file"
cmp "$FIXTURE/extract-source/artifacts/payload" "$FIXTURE/extract-destination/artifacts/payload" ||
  fail "noninteractive unpack lost an artifact entry"

git -C "$SOURCE" init -q
git -C "$SOURCE" config user.name "MPVKit contract fixture"
git -C "$SOURCE" config user.email "fixture@example.invalid"
mkdir -p "$SOURCE/Sources"
printf '%s\n' 'let packageValue = "base"' >"$SOURCE/Package.swift"
printf '%s\n' 'let sourceValue = "base"' >"$SOURCE/Sources/main.swift"
FIXTURE_SWIFT_RECIPE='Sources/BuildScripts/patch/libmpv/0002-revert-build-static.patch'
mkdir -p "$(dirname "$SOURCE/$FIXTURE_SWIFT_RECIPE")"
printf '%s\n' "swift_flags = ['-frontend', '-c', '-sdk', 'fixture-sdk']" >"$SOURCE/$FIXTURE_SWIFT_RECIPE"
cp "$SOURCE/Package.swift" "$FIXTURE/base-package.swift"
cp "$SOURCE/$FIXTURE_SWIFT_RECIPE" "$FIXTURE/base-swift-recipe.patch"
git -C "$SOURCE" add -- Package.swift Sources/main.swift "$FIXTURE_SWIFT_RECIPE"
git -C "$SOURCE" commit -q -m "fixture base"
FIXTURE_REF="$(git -C "$SOURCE" rev-parse HEAD)"

printf '%s\n' 'let packageValue = "approved"' >"$SOURCE/Package.swift"
printf '%s\n' "swift_flags = ['-frontend', '-c', '-whole-module-optimization', '-sdk', 'fixture-sdk']" >"$SOURCE/$FIXTURE_SWIFT_RECIPE"
git -C "$SOURCE" diff --binary -- Package.swift "$FIXTURE_SWIFT_RECIPE" >"$FIXTURE_PATCH"
[ -s "$FIXTURE_PATCH" ] || fail "fixture patch was not generated"
cp "$FIXTURE/base-package.swift" "$SOURCE/Package.swift"
cp "$FIXTURE/base-swift-recipe.patch" "$SOURCE/$FIXTURE_SWIFT_RECIPE"
[ -z "$(git -C "$SOURCE" status --porcelain --untracked-files=all)" ] ||
  fail "fixture must start clean"

# Capture the installed resolver before creating the builder-only tool stubs. The
# target-isolation fixture must exercise real pkg-config metadata resolution.
PKG_CONFIG_EXECUTABLE="$(command -v pkg-config)" || fail "installed pkg-config is required"
case "$PKG_CONFIG_EXECUTABLE" in
  /*) [ -x "$PKG_CONFIG_EXECUTABLE" ] || fail "pkg-config is not executable" ;;
  *) fail "pkg-config must resolve to an absolute installed executable" ;;
esac

for tool in meson ninja cmake pkg-config nasm wget; do
  printf '%s\n' '#!/bin/sh' 'exit 0' >"$TOOLS/$tool"
  chmod +x "$TOOLS/$tool"
done

run_builder() {
  local log="$1"
  MPVKIT_DVFEL_WORK="$SOURCE" \
    MPVKIT_DVFEL_REF="$FIXTURE_REF" \
    MPVKIT_DVFEL_PATCH="$FIXTURE_PATCH" \
    MPVKIT_DVFEL_DEST="$FIXTURE/stage" \
    MPVKIT_DVFEL_PREFLIGHT_ONLY=1 \
    PATH="$TOOLS:$PATH" \
    "$BUILD" >"$log" 2>&1
}

run_builder "$FIXTURE/clean.log" || fail "clean fixture preflight failed: $(cat "$FIXTURE/clean.log")"
grep -Fq 'preflight-only checkout and patch validation passed' "$FIXTURE/clean.log" ||
  fail "clean fixture did not reach the preflight success path"
grep -Fq 'approved' "$SOURCE/Package.swift" || fail "clean fixture did not apply its approved patch"
grep -Fq -- '-whole-module-optimization' "$SOURCE/$FIXTURE_SWIFT_RECIPE" ||
  fail "clean fixture did not carry the approved Swift frontend recipe"
cp "$SOURCE/Package.swift" "$FIXTURE/exact-package.swift"
cp "$SOURCE/$FIXTURE_SWIFT_RECIPE" "$FIXTURE/exact-swift-recipe.patch"

run_builder "$FIXTURE/retry.log" || fail "exact patched retry failed: $(cat "$FIXTURE/retry.log")"
grep -Fq 'exact MPVKit patch already applied' "$FIXTURE/retry.log" ||
  fail "exact patched retry did not use the idempotent path"

# The one newly allowed generated FFmpeg path is accepted only byte-for-byte.
FIXTURE_RESPONSE_PATCH="$SOURCE/Sources/BuildScripts/patch/FFmpeg/0001-response-witness.patch"
mkdir -p "$(dirname "$FIXTURE_RESPONSE_PATCH")"
cp "$RESPONSE_PATCH" "$FIXTURE_RESPONSE_PATCH"
run_builder "$FIXTURE/response-retry.log" ||
  fail "exact generated response-witness copy was rejected: $(cat "$FIXTURE/response-retry.log")"
printf '%s\n' 'unrelated response-witness edit' >>"$FIXTURE_RESPONSE_PATCH"
if run_builder "$FIXTURE/response-conflict.log"; then
  fail "changed generated response-witness copy was accepted"
fi
grep -Fq 'existing generated response-witness patch differs' "$FIXTURE/response-conflict.log" ||
  fail "changed response-witness copy lacked its exact-copy diagnostic"
rm -f "$FIXTURE_RESPONSE_PATCH"
ln -s "$RESPONSE_PATCH" "$FIXTURE_RESPONSE_PATCH"
if run_builder "$FIXTURE/response-symlink.log"; then
  fail "symlinked generated response-witness copy was accepted"
fi
grep -Fq 'generated response-witness patch must not be a symlink' "$FIXTURE/response-symlink.log" ||
  fail "response-witness symlink rejection lacked its ownership diagnostic"
rm -f "$FIXTURE_RESPONSE_PATCH"

# Each generated path has the same exact-file and no-symlink retry contract.
for kind in generation observation sent_ffmpeg sent_mpv prefix transport_ffmpeg transport_mpv reader_ffmpeg reader_mpv; do
  if [ "$kind" = generation ]; then
    canonical="$GENERATION_PATCH"
    generated="$SOURCE/Sources/BuildScripts/patch/FFmpeg/0002-response-generation.patch"
    label="response-generation"
  elif [ "$kind" = observation ]; then
    canonical="$OBSERVATION_PATCH"
    generated="$SOURCE/Sources/BuildScripts/patch/libmpv/0015-completed-response-observation.patch"
    label="completed-response observation"
  elif [ "$kind" = sent_ffmpeg ]; then
    canonical="$SENT_FFMPEG_PATCH"
    generated="$SOURCE/Sources/BuildScripts/patch/FFmpeg/0003-sent-request-evidence.patch"
    label="sent-request evidence"
  elif [ "$kind" = sent_mpv ]; then
    canonical="$SENT_MPV_PATCH"
    generated="$SOURCE/Sources/BuildScripts/patch/libmpv/0016-sent-request-evidence.patch"
    label="sent-request evidence"
  elif [ "$kind" = prefix ]; then
    canonical="$PREFIX_PATCH"
    generated="$SOURCE/Sources/BuildScripts/patch/libmpv/0017-bounded-prefix-request.patch"
    label="bounded-prefix request"
  elif [ "$kind" = transport_ffmpeg ]; then
    canonical="$TRANSPORT_FFMPEG_PATCH"
    generated="$SOURCE/Sources/BuildScripts/patch/FFmpeg/0004-original-transport-evidence.patch"
    label="original-transport evidence"
  elif [ "$kind" = transport_mpv ]; then
    canonical="$TRANSPORT_MPV_PATCH"
    generated="$SOURCE/Sources/BuildScripts/patch/libmpv/0018-original-transport-evidence.patch"
    label="original-transport evidence"
  elif [ "$kind" = reader_ffmpeg ]; then
    canonical="$READER_FFMPEG_PATCH"
    generated="$SOURCE/Sources/BuildScripts/patch/FFmpeg/0005-finite-reference-reader.patch"
    label="finite-reference reader"
  else
    canonical="$READER_MPV_PATCH"
    generated="$SOURCE/Sources/BuildScripts/patch/libmpv/0019-finite-reference-reader.patch"
    label="finite-reference reader"
  fi
  mkdir -p "$(dirname "$generated")"
  cp "$canonical" "$generated"
  run_builder "$FIXTURE/$kind-retry.log" || fail "exact $label retry rejected"
  printf '%s\n' 'unrelated generated patch edit' >>"$generated"
  if run_builder "$FIXTURE/$kind-conflict.log"; then
    fail "changed generated $label patch was accepted"
  fi
  grep -Fq "existing generated $label patch differs" "$FIXTURE/$kind-conflict.log" ||
    fail "changed $label copy lacked its exact-copy diagnostic"
  rm -f "$generated"
  ln -s "$canonical" "$generated"
  if run_builder "$FIXTURE/$kind-symlink.log"; then
    fail "symlinked generated $label patch was accepted"
  fi
  grep -Fq "generated $label patch must not be a symlink" "$FIXTURE/$kind-symlink.log" ||
    fail "$label symlink rejection lacked its ownership diagnostic"
  rm -f "$generated"
done

printf '%s\n' 'let unrelated = true' >>"$SOURCE/Package.swift"
if run_builder "$FIXTURE/unrelated.log"; then
  fail "unrelated same-file edit was accepted"
fi
grep -Fq 'exact approved VortX patch' "$FIXTURE/unrelated.log" ||
  fail "unrelated same-file edit failed without the exact-tree diagnostic"
cp "$FIXTURE/exact-package.swift" "$SOURCE/Package.swift"

printf '%s\n' 'unrelated recipe edit' >>"$SOURCE/$FIXTURE_SWIFT_RECIPE"
if run_builder "$FIXTURE/unrelated-recipe.log"; then
  fail "unrelated edit to the approved tracked Swift recipe was accepted"
fi
grep -Fq 'exact approved VortX patch' "$FIXTURE/unrelated-recipe.log" ||
  fail "unrelated recipe edit failed without the exact-tree diagnostic"
cp "$FIXTURE/exact-swift-recipe.patch" "$SOURCE/$FIXTURE_SWIFT_RECIPE"

cp "$FIXTURE/base-swift-recipe.patch" "$SOURCE/$FIXTURE_SWIFT_RECIPE"
if run_builder "$FIXTURE/partial-recipe.log"; then
  fail "partial approved tree with the Swift recipe missing was accepted"
fi
grep -Fq 'exact approved VortX patch' "$FIXTURE/partial-recipe.log" ||
  fail "partial recipe failed without the exact-tree diagnostic"
cp "$FIXTURE/exact-swift-recipe.patch" "$SOURCE/$FIXTURE_SWIFT_RECIPE"

printf '%s\n' 'untracked fixture data' >"$SOURCE/untracked.txt"
if run_builder "$FIXTURE/untracked.log"; then
  fail "unknown untracked file was accepted"
fi
grep -Fq 'unexpected dirty state' "$FIXTURE/untracked.log" ||
  fail "unknown untracked file failed without the dirty-state diagnostic"
rm -f "$SOURCE/untracked.txt"

[ "$(git -C "$SOURCE" status --porcelain --untracked-files=all)" = "$(printf '%s\n' ' M Package.swift' " M $FIXTURE_SWIFT_RECIPE")" ] ||
  fail "fixture did not retain only the exact approved patch after dirty-state cases"

# Compile actual patched SpikeGit and target pkg-config getters extracted from canonical MPVKit.
# The fixture supplies surrounding types and a Process-backed Utility, retaining production bodies.
CANONICAL_MPVKIT="${MPVKIT_DVFEL_CANONICAL:-/Users/daksh/VortXTV/MPVKit}"
[ -d "$CANONICAL_MPVKIT/.git" ] || fail "canonical MPVKit checkout is unavailable: $CANONICAL_MPVKIT"
CANONICAL_REF="$(git -C "$CANONICAL_MPVKIT" rev-parse HEAD)"
[ "$CANONICAL_REF" = "2103893078c5e339073b11737b86f7f22b9c4491" ] ||
  fail "canonical MPVKit fixture source is not pinned to 2103893: $CANONICAL_REF"

# Verify the new native carrier through real Git application, not string-only
# assertions or a copied C implementation. Only its HTTP/local-witness source
# prerequisites touch these three preimages. Existing constructor/publication
# producer contracts remain intact; this block is not their runtime proof.
NATIVE_SOURCE="${MPVKIT_DVFEL_NATIVE_CONTRACT_SOURCE:-$CANONICAL_MPVKIT/dist/libmpv-master-8c67647b}"
[ -e "$NATIVE_SOURCE/.git" ] || fail "canonical native contract source is unavailable: $NATIVE_SOURCE"
NATIVE_HEAD="$(git -C "$NATIVE_SOURCE" rev-parse HEAD)"
[ "$NATIVE_HEAD" = "8c67647b50059406c5c0444903597281b81516cf" ] ||
  fail "native contract source is not pinned to 8c67647b: $NATIVE_HEAD"
REFERENCE_HASH="$(shasum -a 256 "$REFERENCE_PATCH")"
[ "${REFERENCE_HASH%% *}" = "7d4eaa5236fa8b1b7fb2bd1500ff71aac48fa79fca9e790dfab0dee6d3f0023e" ] ||
  fail "native initial-request carrier differs from the reviewed source"
NATIVE_REAL_INDEX="$(git -C "$NATIVE_SOURCE" rev-parse --path-format=absolute --git-path index)"
[ -f "$NATIVE_REAL_INDEX" ] || fail "native canonical index is unavailable"
NATIVE_INDEX_BEFORE="$(shasum -a 256 "$NATIVE_REAL_INDEX")"
NATIVE_INDEX="$FIXTURE/native-reference.index"
native_git() {
  GIT_INDEX_FILE="$NATIVE_INDEX" git -C "$NATIVE_SOURCE" "$@"
}
check_native_source() {
  local relative="$1" expected="$2" observed
  native_git show ":$relative" >"$FIXTURE/native-reference-${relative##*/}"
  observed="$(shasum -a 256 "$FIXTURE/native-reference-${relative##*/}")"
  [ "${observed%% *}" = "$expected" ] || fail "native source identity mismatch: $relative"
}
native_git read-tree "$NATIVE_HEAD"
native_git apply --cached "$ROOT/scripts/mpv-http-seek-interrupt.patch"
native_git apply --cached "$ROOT/scripts/mpv-original-local-file-witness.patch"
# The new reader also consumes the maintained edition/constructor/publication family.
# Apply those already maintained prerequisites without replacing earlier checks.
EDITION_HASH="$(shasum -a 256 "$EDITION_PATCH")"
[ "${EDITION_HASH%% *}" = "c2b8e1524a384e9a9de92ffc061991590a7220bd80b3f951e52073af9f39cb7a" ] ||
  fail "native edition-title prerequisite differs from the reviewed source"
CONSTRUCTOR_HASH="$(shasum -a 256 "$CONSTRUCTOR_PATCH")"
[ "${CONSTRUCTOR_HASH%% *}" = "21140def002aa67849aa1e502d38e0da0c560b1dd0e90bcf04181fe57bad750f" ] ||
  fail "native constructor prerequisite differs from the reviewed source"
PUBLICATION_HASH="$(shasum -a 256 "$PUBLICATION_PATCH")"
[ "${PUBLICATION_HASH%% *}" = "54b29e4101e4cf7ef95d450462725beb8ac44c2733f7a444961f66b41df78341" ] ||
  fail "native publication prerequisite differs from the reviewed source"
native_git apply --cached "$EDITION_PATCH"
native_git apply --cached "$CONSTRUCTOR_PATCH"
native_git apply --cached "$PUBLICATION_PATCH"
check_native_source stream/stream.h e7c6b69128db214210074d3a88e4291f97e2fc3119e60f34d8601a2085416fef
check_native_source stream/stream.c 9f99d368a9485c6d1977735cc7276eda34b512bf61ee45cfd585a084d677f034
check_native_source stream/stream_lavf.c a162b26af4381e946f9a0fa576b12bc9b29310135b6deb7f134cf6867068c654
if native_git ls-files --error-unmatch -- stream/reference_source.h >/dev/null 2>&1; then
  fail "native reference header unexpectedly exists before carrier application"
fi
NATIVE_PRE_TREE="$(native_git write-tree)"
native_git apply --cached "$REFERENCE_PATCH"
[ "$(native_git diff --cached --name-only "$NATIVE_PRE_TREE" --)" = "$(printf '%s\n' \
  stream/reference_source.h stream/stream.c stream/stream.h stream/stream_lavf.c)" ] ||
  fail "native initial-request carrier changed unexpected source paths"
check_native_source stream/stream.h a5f1b6fd23f58bcb0282e36448f34dde0121768abac95913c29163ae163747c6
check_native_source stream/stream.c 6da9c9c7e1efb4da5a37fe4c7a92188d9f3d4732bdfd4a4c976fe7e9f30145e9
check_native_source stream/stream_lavf.c 15a7a08223efe0db0a33b2bc7b39616dd43fecfc1eca1e0ced23f16c7a839ad9
check_native_source stream/reference_source.h 6330b5056700efacd2655a31b011a88c3e4e8b6424360bfe6ee1d728fd7399a1
# Add only the reviewed ongoing original-cancel lifetime delta AFTER its carrier.
# The demux-owner API is not part of this maintained recipe; do not import its
# unrelated dirty source or the five-path packet's comment-only demux header hunk.
CANCEL_HASH="$(shasum -a 256 "$CANCEL_PATCH")"
[ "${CANCEL_HASH%% *}" = "778b58c05129e397ed2f90408718f6b3a3feca84492485657d89e784bbee5722" ] ||
  fail "native original-cancel lifetime delta differs from the reviewed source"
check_native_source misc/thread_tools.c 3874eb003bb6ca02ca117644ec951799fcf50b7099d3b8d9681172c22f587cf8
check_native_source misc/thread_tools.h 0aa4e23391d2b4ce66938ccfce95dbfa85be4a72da82177697886c7dd89271ad
CANCEL_PRE_TREE="$(native_git write-tree)"
native_git apply --cached "$CANCEL_PATCH"
[ "$(native_git diff --cached --name-only "$CANCEL_PRE_TREE" --)" = "$(printf '%s\n' \
  misc/thread_tools.c misc/thread_tools.h stream/reference_source.h stream/stream_lavf.c)" ] ||
  fail "native original-cancel lifetime delta changed unexpected source paths"
check_native_source misc/thread_tools.c 151102f6fc8584e119317e3526502bbae492353b1c312ae4a8f3aecaee8bdab9
check_native_source misc/thread_tools.h 62c7ea467ef911d9665cc4d7ffe28b2b09ea03f152326964056f62dab24acc7f
check_native_source stream/stream_lavf.c e0c69d92332e29a53d3d4458d4afa582919a9456d0fd63f7703cf342064cd16a
check_native_source stream/reference_source.h ce22ce201e6a41899c8c05b98fb9d9912f565090c5ffa0209492118a2a1a07f8
# Add only the owned observation after the exact cancellation afterimages.
# This exercises real patch composition; it is not a remote response/reader test.
OBSERVATION_PRE_TREE="$(native_git write-tree)"
native_git apply --cached "$OBSERVATION_PATCH"
[ "$(native_git diff --cached --name-only "$OBSERVATION_PRE_TREE" --)" = "$(printf '%s\n' \
  stream/reference_source.h stream/stream_lavf.c)" ] ||
  fail "owned response observation delta changed unexpected source paths"
check_native_source misc/thread_tools.c 151102f6fc8584e119317e3526502bbae492353b1c312ae4a8f3aecaee8bdab9
check_native_source misc/thread_tools.h 62c7ea467ef911d9665cc4d7ffe28b2b09ea03f152326964056f62dab24acc7f
check_native_source stream/stream_lavf.c c99a1956acc13ae3cc36972ec6d8fc8576e4699223c3bfb1db8fb3d171e58819
check_native_source stream/reference_source.h 9543ad2c923fa5fa43f224843a76a4b30a0232b3bb9da2eea1fdc84a28801577
# The next native-only delta retains exact observation/cancel semantics, adds the
# private ABI header and Android-only hidden link roots. No native compilation runs.
if native_git ls-files --error-unmatch -- stream/vortx_http_request.h >/dev/null 2>&1; then
  fail "private sent-request header unexpectedly exists before its carrier"
fi
SENT_PRE_TREE="$(native_git write-tree)"
native_git apply --cached "$SENT_MPV_PATCH"
[ "$(native_git diff --cached --name-only "$SENT_PRE_TREE" --)" = "$(printf '%s\n' \
  meson.build stream/reference_source.h stream/stream_lavf.c stream/vortx_http_request.h)" ] ||
  fail "native sent-request carrier changed unexpected source paths"
check_native_source misc/thread_tools.c 151102f6fc8584e119317e3526502bbae492353b1c312ae4a8f3aecaee8bdab9
check_native_source misc/thread_tools.h 62c7ea467ef911d9665cc4d7ffe28b2b09ea03f152326964056f62dab24acc7f
check_native_source stream/stream_lavf.c 174cdaa923dad4b97926ac9f80ba8cabbba8be9e850824fb6939e317cd9c8f29
check_native_source stream/reference_source.h d48bd6dfd4db3cdbb4fbd3549a4d4cf20ef0f68a1b243f652f4e41de8770649e
check_native_source stream/vortx_http_request.h 81e3c9cd21678cb047812de14a32b7a382bd44e5701e46d58d532b7e89679765
native_git show :meson.build >"$FIXTURE/native-sent-meson.build"
[ "$(grep -c -- '-Wl,--undefined=stream_reference_' "$FIXTURE/native-sent-meson.build")" = 6 ] ||
  fail "Android sent-request carrier must retain exactly six native-only roots"
grep -Fq "if host_machine.system() == 'android'" "$FIXTURE/native-sent-meson.build" ||
  fail "native-only link roots must be conditional on Android"
grep -Fq "gnu_symbol_visibility: 'hidden'" "$FIXTURE/native-sent-meson.build" ||
  fail "native-only helpers must retain hidden visibility"
# Apply material preparation only after the exact sent-request prerequisite.
PREFIX_PRE_TREE="$(native_git write-tree)"
native_git apply --cached "$PREFIX_PATCH"
[ "$(native_git diff --cached --name-only "$PREFIX_PRE_TREE" --)" = "$(printf '%s\n' \
  meson.build stream/reference_source.h stream/stream_lavf.c)" ] ||
  fail "native bounded-prefix carrier changed unexpected source paths"
check_native_source stream/stream_lavf.c 721c0e25e8de5d5207c064d328f577dbdf0f3c345bd8ab4caadf410dcdfb6e83
check_native_source stream/reference_source.h 868b13f385025791ecb2713bda68ed08fce434be8ddb0befdef6633044152933
check_native_source stream/vortx_http_request.h 81e3c9cd21678cb047812de14a32b7a382bd44e5701e46d58d532b7e89679765
native_git show :meson.build >"$FIXTURE/native-prefix-meson.build"
[ "$(grep -c -- '-Wl,--undefined=stream_reference_' "$FIXTURE/native-prefix-meson.build")" = 7 ] ||
  fail "Android material carrier must retain seven native-only roots"
grep -Fq "'-Wl,--undefined=stream_reference_source_prepare_prefix_request'" "$FIXTURE/native-prefix-meson.build" ||
  fail "Android material carrier must retain its private preparation helper"
grep -Fq "if host_machine.system() == 'android'" "$FIXTURE/native-prefix-meson.build" ||
  fail "prefix material link root must remain Android-only"
grep -Fq "gnu_symbol_visibility: 'hidden'" "$FIXTURE/native-prefix-meson.build" ||
  fail "prefix material helper must remain hidden"
# Compose the route observation only after its exact bounded-prefix prerequisite.
# This is genuine source/index composition, not a real transport or reader test.
TRANSPORT_PRE_TREE="$(native_git write-tree)"
native_git apply --cached "$TRANSPORT_MPV_PATCH"
[ "$(native_git diff --cached --name-only "$TRANSPORT_PRE_TREE" --)" = "$(printf '%s\n' \
  stream/reference_source.h stream/stream_lavf.c stream/vortx_http_request.h)" ] ||
  fail "native transport carrier changed unexpected source paths"
check_native_source misc/thread_tools.c 151102f6fc8584e119317e3526502bbae492353b1c312ae4a8f3aecaee8bdab9
check_native_source misc/thread_tools.h 62c7ea467ef911d9665cc4d7ffe28b2b09ea03f152326964056f62dab24acc7f
check_native_source stream/stream_lavf.c 25047d80eb9c12e30ca13476ddd3c3153e5c7bf9ed6857ed197fd956ac70175b
check_native_source stream/reference_source.h 1ab5fae85e71f2f91a915b29c0dc26e19f77269c5dcc8982f9b0eb9fbfef0835
check_native_source stream/vortx_http_request.h d7730cc3492f6eaf6f6f1134fa50331c13e251fb1ddab8e577e1b912b8679dc9
native_git show :stream/stream_lavf.c >"$FIXTURE/native-transport-lavf.c"
native_git show :stream/vortx_http_request.h >"$FIXTURE/native-transport-private.h"
for symbol in avpriv_vortx_http_copy_sent_request_v2 avpriv_vortx_http_sent_request_clear_v2 \
  stream_reference_sent_request_copy_transport; do
  grep -Fq "$symbol" "$FIXTURE/native-transport-lavf.c" || fail "native transport symbol missing: $symbol"
done
if grep -Eq 'avpriv_vortx_http_(copy_sent_request|sent_request_clear)[[:space:]]*\(' \
  "$FIXTURE/native-transport-lavf.c" "$FIXTURE/native-transport-private.h"; then
  fail "native transport carrier retained an unsafe v1 provider/caller fallback"
fi
native_git show :meson.build >"$FIXTURE/native-transport-meson.build"
cmp -s "$FIXTURE/native-prefix-meson.build" "$FIXTURE/native-transport-meson.build" ||
  fail "transport observation changed the existing seven private native roots"
# Fold the exact previously uncarried demux-owner handoff into this reader delta.
# These are genuine maintained baselines, not the already-dirty prototype preimages.
check_native_source demux/demux.c 98bb16cdf1f342a33d2924c09045dff673cd746f5b624be52f8a6edba4381cba
check_native_source demux/demux.h c2db4fdab9fd1c9f71b595b9d6bceb008839678cd4d27f17a9b76f898d025f6c
check_native_source demux/demux_lavf.c 2d29b7e4dd9fd4df4e7e2ee25dce461a4330eb3b2f9f7e79d8a8a70fc9601915
check_native_source meson.build e08f39c00eb3aad5633b0aeffdba01580762db30f53f4a675693db50c3145977
check_native_source player/owned_subtitle.c 875d9f0192cd5f45acca2654765bdc667df5d12dd6eabf9aef5caec5cdec821d
check_native_source player/owned_subtitle.h 2e9e64d92938e41c14c3397c9fbe7d064c2fe8aa5d2dcd05db4b9a74f4bad22e
check_native_source player/command.c 12c87a6e79d3f1a97542a390198a31d69c96259b458018f901e61074aafec4b7
check_native_source sub/owned_text_slot.h b5f99151efb15ba937f630d1c2589c1e6634a4bebb744a161283cb70b3e250b6
check_native_source sub/osd.c c317f4aa5445a950d19f52c8007c8378399523d65a7e360c4267919448a9553e
check_native_source sub/dec_sub.c 31fc5af8a06194484001be3ccc2534d656fce9dbde3def4dee0d9397df473310
check_native_source sub/dec_sub.h 504a5f7020d66da50eed51c28617c1e7d88f03ec4de8113bc153a16febad2008
check_native_source demux/demux_mkv.c 1f726a3fbc4ccadf85dac3af82f59c07ea5ff6bad62cc327e7c4315c4d8e14d7
for relative in demux/reference_reader.c demux/reference_reader.h demux/reference_reader_internal.h \
  stream/vortx_reference_reader_stream.h player/reference_owned.inc demux/reference_mkv.h \
  demux/reference_mkv_reader.c demux/reference_mkv_sparse.h demux/reference_mkv_sparse_planner.c \
  demux/reference_mkv_sparse_planner.h demux/reference_mkv_sparse_worker.c stream/vortx_reference_sparse.h; do
  if native_git ls-files --error-unmatch -- "$relative" >/dev/null 2>&1; then
    fail "finite-reader source unexpectedly exists before its carrier: $relative"
  fi
done
READER_PRE_TREE="$(native_git write-tree)"
native_git apply --cached "$READER_MPV_PATCH"
[ "$(native_git diff --cached --name-only "$READER_PRE_TREE" --)" = "$(printf '%s\n' \
  demux/demux.c demux/demux.h demux/demux_lavf.c \
  demux/demux_mkv.c demux/reference_mkv.h demux/reference_mkv_reader.c \
  demux/reference_mkv_sparse.h demux/reference_mkv_sparse_planner.c demux/reference_mkv_sparse_planner.h \
  demux/reference_mkv_sparse_worker.c demux/reference_reader.c demux/reference_reader.h \
  demux/reference_reader_internal.h meson.build player/command.c \
  player/owned_subtitle.c player/owned_subtitle.h player/reference_owned.inc \
  stream/reference_source.h stream/stream_lavf.c stream/vortx_reference_reader_stream.h \
  stream/vortx_reference_sparse.h sub/dec_sub.c sub/dec_sub.h \
  sub/osd.c sub/owned_text_slot.h)" ] ||
  fail "native finite-reader carrier changed unexpected source paths"
check_native_source demux/demux.c f5a4cd7bf4e29902ef965e43027755c19ded1423129a3fbe9808ad89e64c0e1c
check_native_source demux/demux.h bee52b38477ce7c8efd9a50e778f720ea8c9eec577afab29998682c26ffe75e2
check_native_source demux/demux_lavf.c d945ae1699d383c3d645d2ab963abb166fd0c19f10a4ab144505e7fbfb0408fb
check_native_source demux/demux_mkv.c 1b7cc4d40efa0620bd10669dc44a7d6b32d0236e2ae2be3510a3bac0829e39c2
check_native_source demux/reference_mkv.h 38df7814efc3aa7434e5afe269406a989ab6a5fa22a200aa28149a3ab68e46d9
check_native_source demux/reference_mkv_reader.c 3ac442e8ff489d11f4a5df6b86f8d964457753f66ce5f3eb530d7db3746b6f7c
check_native_source demux/reference_mkv_sparse.h 4b013b6e794257a576bc01f6becb9d120cb878e0851b2e0bdd2225dcf7b18df2
check_native_source demux/reference_mkv_sparse_planner.c e36c6a879138b26e125f647c9254b41674b22b338ab12838376fe8d38bdae056
check_native_source demux/reference_mkv_sparse_planner.h c88597a42186ceb81f45f1f44b3734469cf06889ea3bf91e4853b861943e84fe
check_native_source demux/reference_mkv_sparse_worker.c 5deae68bf3c680aa4898ca6c8e0c0e76aa4628bffa693d0ae2d6dd287d9a5e64
check_native_source demux/reference_reader.c 222ec8920d38971d386470d8172e45a89a52350eb352124ddf954be9409b792b
check_native_source demux/reference_reader.h 59d669fb370bc12f01856031b8f9d908eb1d50a927d955ecb1fe0b4484c2407d
check_native_source demux/reference_reader_internal.h ded5dc02785e98934a966de87df4337e4c6aed0275bce26da2017883917f4c8d
check_native_source meson.build 32c9a1321883f6a980652173061c9c01727ef83b7a0dfe6e8e3a22364b753d47
check_native_source player/command.c e7a19f392bb69e9d208382f157234ac3c908d22a0d4afee5f372ee8f9d33dade
check_native_source player/owned_subtitle.c 014b93845488ef873a4d29c4c8dd4ada69d244626e7a7b38bac82809989c6b29
check_native_source player/owned_subtitle.h 8d2f0ee5c972d1da69213cd80fbe249bcf3f19d9de8a2ef87e241d2f08f06284
check_native_source player/reference_owned.inc 23ac96bfedefcab2234afa2a6f329a36fac6735effca6798b4043d777b060217
check_native_source stream/reference_source.h 1f606a977b55f18fdb9f9fc7f5e4549b5774bef10a06c33b06ab945531909b29
check_native_source stream/stream_lavf.c 650bf7b94771e70a6b934b21e362bc77f66ceb1d23ee684d2b169c6e694544a5
check_native_source stream/vortx_reference_reader_stream.h adaeb9d58c20ba3305bce4784205c20d6276ba67a758a9ec7207c850c7ba8d87
check_native_source stream/vortx_reference_sparse.h fa5f8e163d9368b30db6a9c7f0c69ed36e91d6a23ca409b7ba468c7d2282751c
check_native_source sub/dec_sub.c 6e2137b90fe7f2915a528bdd83426448afbd099229f65342dbfd85d1ba1d347b
check_native_source sub/dec_sub.h cb9b5af7c3f87a8dda584617c1f20a90a9331182d54a50c7e5fb8e64e74b384f
check_native_source sub/osd.c 9b57ccd08e5777e2bc644cbf8001df0301552edf5cf24e36185a54f4cd667195
check_native_source sub/owned_text_slot.h 63c498dd4bdc9fa9c6d128f1be8f37d7cdf377c853888342897f6639601662f6
native_git show :meson.build >"$FIXTURE/native-sparse-meson.build"
[ "$(grep -c -- '-Wl,--undefined=stream_reference_' "$FIXTURE/native-sparse-meson.build")" = 7 ] ||
  fail "native sparse carrier must retain all seven existing private roots"
grep -Fq "if host_machine.system() == 'android'" "$FIXTURE/native-sparse-meson.build" ||
  fail "native sparse roots must remain Android-only"
grep -Fq "gnu_symbol_visibility: 'hidden'" "$FIXTURE/native-sparse-meson.build" ||
  fail "native sparse carrier must retain hidden visibility"
# Unchanged source authority/cancellation remains separate from the reader wave.
check_native_source misc/thread_tools.c 151102f6fc8584e119317e3526502bbae492353b1c312ae4a8f3aecaee8bdab9
check_native_source misc/thread_tools.h 62c7ea467ef911d9665cc4d7ffe28b2b09ea03f152326964056f62dab24acc7f
check_native_source stream/vortx_http_request.h d7730cc3492f6eaf6f6f1134fa50331c13e251fb1ddab8e577e1b912b8679dc9
[ "$(shasum -a 256 "$NATIVE_REAL_INDEX")" = "$NATIVE_INDEX_BEFORE" ] ||
  fail "native canonical index changed during the isolated carrier contract"

PATCHED_INDEX="$FIXTURE/mpvkit-source.index"
PATCHED_SOURCE="$FIXTURE/mpvkit-main.swift"
PATCHED_BASE="$FIXTURE/mpvkit-base.swift"
# Verify the entire approved patch in an isolated index, then emit only these two inputs.
# No source checkout or canonical index/working-tree edit is created.
GIT_INDEX_FILE="$PATCHED_INDEX" git -C "$CANONICAL_MPVKIT" read-tree HEAD
GIT_INDEX_FILE="$PATCHED_INDEX" git -C "$CANONICAL_MPVKIT" apply --cached "$PATCH"
GIT_INDEX_FILE="$PATCHED_INDEX" git -C "$CANONICAL_MPVKIT" show :Sources/BuildScripts/XCFrameworkBuild/main.swift >"$PATCHED_SOURCE"
GIT_INDEX_FILE="$PATCHED_INDEX" git -C "$CANONICAL_MPVKIT" show :Sources/BuildScripts/XCFrameworkBuild/base.swift >"$PATCHED_BASE"
swiftc -j 1 -num-threads 1 -parse "$PATCHED_SOURCE" ||
  fail "actual patched MPVKit BuildScripts source did not parse"
SPIKE_BLOCK="$FIXTURE/spikegit-production.swift"
sed -n '/^enum SpikeGit {/,/^private class BuildOpenSSL: BaseBuild {/p' \
  "$PATCHED_SOURCE" | sed '$d' >"$SPIKE_BLOCK"
[ -s "$SPIKE_BLOCK" ] || fail "could not extract the patched production SpikeGit implementation"
SMB_METADATA_BLOCK="$FIXTURE/smb-metadata-production.swift"
sed -n '/^enum SmbMetadataNormalizer {/,/^private class BuildSmbclient:/p' \
  "$PATCHED_SOURCE" | sed '$d' >"$SMB_METADATA_BLOCK"
[ -s "$SMB_METADATA_BLOCK" ] || fail "could not extract production SmbMetadataNormalizer"
ENVIRONMENT_BLOCK="$FIXTURE/environment-production.swift"
PKG_CONFIG_BLOCK="$FIXTURE/pkgconfig-production.swift"
# These selectors end at the method's four-space closing brace, preserving each
# complete production body without pulling unrelated SDK/build implementation in.
sed -n '/^    func environment(platform: PlatformType, arch: ArchType) -> \[String: String\] {/,/^    }/p' \
  "$PATCHED_BASE" >"$ENVIRONMENT_BLOCK"
sed -n '/^    func pkgConfigPath(arch: ArchType) -> String {/,/^    }/p' \
  "$PATCHED_BASE" >"$PKG_CONFIG_BLOCK"
[ -s "$ENVIRONMENT_BLOCK" ] || fail "could not extract production BaseBuild.environment"
[ -s "$PKG_CONFIG_BLOCK" ] || fail "could not extract production PlatformType.pkgConfigPath"
SDK_SYSTEM_BLOCK="$FIXTURE/sdk-system-production.swift"
sed -n '/^enum SDKSystemMetadata {/,/^class BaseBuild {/p' "$PATCHED_BASE" | sed '$d' >"$SDK_SYSTEM_BLOCK"
[ -s "$SDK_SYSTEM_BLOCK" ] || fail "could not extract production SDKSystemMetadata"
base_build="$(sed -n '/^    func build(platform: PlatformType, arch: ArchType) throws {/,/^    }/p' "$PATCHED_BASE")"
grep -Fq 'var environ = environment(platform: platform, arch: arch)' <<<"$base_build" ||
  fail "actual BaseBuild.build must retain a mutable production environment"
grep -Fq 'try SDKSystemMetadata.append(to: &environ, sdkRoot: URL(fileURLWithPath: platform.isysroot), buildRoot: buildURL)' <<<"$base_build" ||
  fail "actual BaseBuild.build must append selected SDK metadata before launching its tools"
sdk_append_line="$(grep -nF 'try SDKSystemMetadata.append(' <<<"$base_build" | cut -d: -f1)"
first_tool_line="$(grep -nF 'Utility.' <<<"$base_build" | head -1 | cut -d: -f1)"
[ "$sdk_append_line" -lt "$first_tool_line" ] || fail "SDK metadata must precede the actual build tool calls"

SWIFT_PATCH_DIR="$FIXTURE/Sources/BuildScripts/patch/fixture"
mkdir -p "$SWIFT_PATCH_DIR"
cp "$FIXTURE_PATCH" "$SWIFT_PATCH_DIR/0001-approved.patch"
cp "$FIXTURE/base-package.swift" "$SOURCE/Package.swift"
cp "$FIXTURE/base-swift-recipe.patch" "$SOURCE/$FIXTURE_SWIFT_RECIPE"

SWIFT_HELPER="$FIXTURE/spikegit-fixture.swift"
{
  printf '%s\n' \
    'import Foundation' \
    'import Darwin' \
    'import CryptoKit' \
    '' \
    'enum Library: String, CaseIterable {' \
    '    case fixture, FFmpeg, openssl' \
    '}' \
    '' \
    'extension URL {' \
    '    static var currentDirectory: URL {' \
    '        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)' \
    '    }' \
    '' \
    '    static func + (left: URL, right: String) -> URL {' \
    '        left.appendingPathComponent(right)' \
    '    }' \
    '' \
    '    static func + (left: URL, right: [String]) -> URL {' \
    '        right.reduce(left) { $0.appendingPathComponent($1) }' \
    '    }' \
    '}' \
    '' \
    'enum Utility {' \
    '    @discardableResult' \
    '    static func shell(_ command: String, isOutput: Bool = false, currentDirectoryURL: URL? = nil, environment: [String: String] = [:]) -> String? {' \
    '        do {' \
    '            return try launch(executableURL: URL(fileURLWithPath: "/bin/bash"), arguments: ["-c", command], isOutput: isOutput, currentDirectoryURL: currentDirectoryURL, environment: environment)' \
    '        } catch {' \
    '            return nil' \
    '        }' \
    '    }' \
    '' \
    '    @discardableResult' \
    '    static func launch(path: String, arguments: [String], isOutput: Bool = false, isPrint: Bool = true, currentDirectoryURL: URL? = nil, environment: [String: String] = [:]) throws -> String {' \
    '        try launch(executableURL: URL(fileURLWithPath: path), arguments: arguments, isOutput: isOutput, currentDirectoryURL: currentDirectoryURL, environment: environment)' \
    '    }' \
    '' \
    '    @discardableResult' \
    '    static func launch(executableURL: URL, arguments: [String], isOutput: Bool = false, isPrint: Bool = true, currentDirectoryURL: URL? = nil, environment: [String: String] = [:]) throws -> String {' \
    '        let task = Process()' \
    '        task.executableURL = executableURL' \
    '        task.arguments = arguments' \
    '        task.currentDirectoryURL = currentDirectoryURL' \
    '        var mergedEnvironment = ProcessInfo.processInfo.environment' \
    '        environment.forEach { mergedEnvironment[$0.key] = $0.value }' \
    '        task.environment = mergedEnvironment' \
    '        let outputPipe = Pipe()' \
    '        task.standardOutput = outputPipe' \
    '        let errorPipe = Pipe()' \
    '        task.standardError = errorPipe' \
    '        try task.run()' \
    '        task.waitUntilExit()' \
    '        guard task.terminationStatus == 0 else {' \
    '            let diagnostic = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""' \
    '            if !diagnostic.isEmpty { FileHandle.standardError.write(Data(diagnostic.utf8)) }' \
    '            throw NSError(domain: "SpikeGitFixture", code: Int(task.terminationStatus))' \
    '        }' \
    '        guard isOutput else { return "" }' \
    '        return String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .newlines) ?? ""' \
    '    }' \
    '}' \
    ''
  sed -n '1,$p' "$SPIKE_BLOCK"
  cat "$SMB_METADATA_BLOCK"
  cat "$SDK_SYSTEM_BLOCK"
  cat <<'SWIFT_TYPES'

enum ArchType: String { case arm64, x86_64, arm64e }
enum PlatformType: String {
    case xros, xrsimulator, maccatalyst, macos, isimulator, tvsimulator, tvos, ios
SWIFT_TYPES
  cat "$PKG_CONFIG_BLOCK"
  cat <<'SWIFT_BASE'
}

class BaseBuild {
    static let defaultPath = "/usr/bin:/bin:/usr/sbin:/sbin"
    func cFlags(platform: PlatformType, arch: ArchType) -> [String] { ["fixture-cflags"] }
    func ldFlags(platform: PlatformType, arch: ArchType) -> [String] { ["fixture-ldflags"] }
SWIFT_BASE
  cat "$ENVIRONMENT_BLOCK"
  cat <<'SWIFT_ISOLATION'
}

func requireFixture(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
        throw NSError(domain: "TargetIsolationFixture", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: message])
    }
}

func writeModule(_ name: String, version: String = "1.0", requires: String = "", in directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let contents = """
    Name: \(name)
    Description: Synthetic target-isolation contract sentinel
    Version: \(version)
    Requires.private: \(requires)
    Libs: -lvortx_sentinel

    """
    try contents.write(to: directory.appendingPathComponent("\(name).pc"), atomically: true, encoding: .utf8)
}

func runTargetIsolation(executable: String, root: URL) throws {
    let manager = FileManager.default
    try manager.createDirectory(at: root, withIntermediateDirectories: true)
    try requireFixture(manager.changeCurrentDirectoryPath(root.path), "could not enter pkg-config fixture")
    let hostPath = root.appendingPathComponent("host-path")
    let hostLibdir = root.appendingPathComponent("host-libdir")
    try requireFixture(ProcessInfo.processInfo.environment["PKG_CONFIG_PATH"] == hostPath.path,
                       "parent PKG_CONFIG_PATH poison was not supplied")
    try requireFixture(ProcessInfo.processInfo.environment["PKG_CONFIG_LIBDIR"] == hostLibdir.path,
                       "parent PKG_CONFIG_LIBDIR poison was not supplied")
    try writeModule("vortx-host-path-sentinel", in: hostPath)
    try writeModule("vortx-host-libdir-sentinel", in: hostLibdir)
    try writeModule("vortx-transitive-host-sentinel", in: hostPath)
    // A duplicate target identity makes host precedence observable by its version.
    try writeModule("vortx-target-sentinel", version: "9.0", in: hostPath)
    let poison = ["PKG_CONFIG_PATH": hostPath.path, "PKG_CONFIG_LIBDIR": hostLibdir.path]
    for module in ["vortx-host-path-sentinel", "vortx-host-libdir-sentinel"] {
        _ = try Utility.launch(path: executable, arguments: ["--exists", module], environment: poison)
    }

    let cases: [(PlatformType, ArchType)] = [
        (.tvos, .arm64), (.tvos, .arm64e), (.tvsimulator, .x86_64),
        (.ios, .arm64), (.macos, .arm64),
    ]
    for (platform, arch) in cases {
        let environment = BaseBuild().environment(platform: platform, arch: arch)
        let getter = platform.pkgConfigPath(arch: arch)
        try requireFixture(environment["PKG_CONFIG_LIBDIR"] == getter, "environment did not use production target getter")
        try requireFixture(environment["PKG_CONFIG_PATH"] == "", "environment must explicitly clear PKG_CONFIG_PATH")
        let paths = getter.components(separatedBy: ":")
        let suffix = "\(platform.rawValue)/thin/\(arch.rawValue)/lib/pkgconfig"
        let expected = ["fixture", "FFmpeg", "openssl"].map { root.appendingPathComponent("\($0)/\(suffix)").path }
        try requireFixture(paths == expected, "target roots differ, contain host roots, or contain empty segments: \(getter)")
        try requireFixture(paths.count == Library.allCases.count && !paths.contains(""), "target root list is not finite and explicit")
        try requireFixture(paths.allSatisfy { !manager.fileExists(atPath: $0) }, "absent dependency roots were not retained")
        let target = URL(fileURLWithPath: paths[1])
        try writeModule("vortx-target-sentinel", in: target)
        try writeModule("vortx-needs-host-sentinel", requires: "vortx-transitive-host-sentinel", in: target)
        // Positive control proves the host dependency exists and can satisfy the
        // target's private dependency if host search is accidentally permitted.
        var contaminated = poison
        contaminated["PKG_CONFIG_PATH"] = "\(hostPath.path):\(target.path)"
        _ = try Utility.launch(path: executable, arguments: ["--static", "--libs", "vortx-needs-host-sentinel"], environment: contaminated)
        let version = try Utility.launch(path: executable, arguments: ["--modversion", "vortx-target-sentinel"], isOutput: true, environment: environment)
        try requireFixture(version == "1.0", "target metadata was missing or shadowed by the host sentinel")
        for module in ["vortx-host-path-sentinel", "vortx-host-libdir-sentinel"] {
            let result = try? Utility.launch(path: executable, arguments: ["--exists", module], environment: environment)
            try requireFixture(result == nil, "host-only module leaked into target search: \(module)")
        }
        let transitive = try? Utility.launch(path: executable, arguments: ["--static", "--libs", "vortx-needs-host-sentinel"], environment: environment)
        try requireFixture(transitive == nil, "missing target private dependency was satisfied by host metadata")
    }

    // No roots exist for this different platform/architecture. The getter must
    // still set nonempty LIBDIR, and the resolver must fail despite host poison.
    let missing = BaseBuild().environment(platform: .xrsimulator, arch: .arm64e)
    let missingPaths = (missing["PKG_CONFIG_LIBDIR"] ?? "").components(separatedBy: ":")
    try requireFixture(missingPaths.count == Library.allCases.count && !missingPaths.contains(""), "absent roots produced empty LIBDIR")
    try requireFixture(missingPaths.allSatisfy { !manager.fileExists(atPath: $0) }, "missing target fixture unexpectedly exists")
    let absent = try? Utility.launch(path: executable, arguments: ["--exists", "vortx-target-sentinel"], environment: missing)
    try requireFixture(absent == nil, "nonexistent target roots fell back to host metadata")
    print("TARGET ISOLATION FIXTURE PASS")
}

// These observations deliberately reuse production's immutable proof records.
// They exercise policy, not physical ZIP/archive/header validation or provenance.
func smbObserved(_ base: SmbMetadataNormalizer.Snapshot,
                 version: String? = nil, zipHash: String? = nil,
                 headers: [String: String]? = nil, archives: [String: String]? = nil,
                 templates: [String: String]? = nil, requested: Set<String>? = nil,
                 restored: [String: SmbMetadataNormalizer.Restored]? = nil) -> SmbMetadataNormalizer.Snapshot {
    SmbMetadataNormalizer.Snapshot(version: version ?? base.version, zipHash: zipHash ?? base.zipHash,
        headers: headers ?? base.headers, archives: archives ?? base.archives,
        templates: templates ?? base.templates, requested: requested ?? base.requested,
        restored: restored ?? base.restored)
}

func expectSmbRefusal(_ label: String, _ operation: () throws -> Void) throws {
    var rejected = false
    do { try operation() } catch { rejected = true }
    try requireFixture(rejected, "SMB policy accepted \(label)")
}

func runSmbMetadataContract(root: URL) throws {
    typealias Normalizer = SmbMetadataNormalizer
    let manager = FileManager.default
    try manager.createDirectory(at: root, withIntermediateDirectories: true)
    let output = root.appendingPathComponent("output")
    let headers = Normalizer.headerPins.mapValues { $0.1 }
    let archives = Dictionary(uniqueKeysWithValues: Normalizer.rows.compactMap { row in row.archiveHash.map { (row.key, $0) } })
    let templates = Dictionary(uniqueKeysWithValues: Normalizer.rows.map { ($0.key, Normalizer.template($0)) })
    let requested = Set(Normalizer.rows.map { $0.key })
    let restored = Dictionary(uniqueKeysWithValues: Normalizer.rows.map { row in
        (row.key, Normalizer.Restored(text: templates[row.key]!.replacingOccurrences(of: "/path/to/workdir", with: output.path),
                                     archiveHash: row.archiveHash, headers: headers))
    })
    let original = Normalizer.Snapshot(version: Normalizer.version, zipHash: Normalizer.zipHash,
        headers: headers, archives: archives, templates: templates, requested: requested, restored: restored)
    let correctable: Set<String> = ["isimulator/x86_64", "macos/arm64", "macos/x86_64", "tvos/arm64e", "tvsimulator/x86_64"]
    let unchanged: Set<String> = ["ios/arm64", "isimulator/arm64", "tvos/arm64", "tvsimulator/arm64"]
    let unsupported: Set<String> = ["maccatalyst/arm64", "maccatalyst/x86_64", "xros/arm64", "xrsimulator/arm64"]
    try requireFixture(archives.count == 9 && templates.count == 13, "production proof record cardinality changed")
    try requireFixture(requested == correctable.union(unchanged).union(unsupported), "production template keys changed")
    let changes = try Normalizer.plan(original, outputRoot: output)
    try requireFixture(Set(changes.keys) == correctable, "plan must change exactly the five approved GLib declarations")
    for row in Normalizer.rows {
        let before = restored[row.key]!.text
        guard let after = changes[row.key] else {
            try requireFixture(unchanged.contains(row.key) || unsupported.contains(row.key), "approved correction was omitted")
            try requireFixture(Normalizer.template(row, corrected: true) == templates[row.key], "unchanged/unsupported template would be normalized")
            continue
        }
        let exactRemoval = before.replacingOccurrences(of: " -lglib-2.0", with: "")
            .replacingOccurrences(of: "Requires.private: gnutls glib-2.0", with: "Requires.private: gnutls")
        try requireFixture(after == exactRemoval, "correction changed fields beyond the exact two GLib tokens")
        for retained in ["Version: 0.7.0\n", "-lresolv -lpthread -lz -liconv -lgnutls", "-lncurses -lreadline", "Requires.private: gnutls\n", "-lsmbclient"] {
            try requireFixture(after.contains(retained), "correction removed API version, GnuTLS, or system flags")
        }
        try requireFixture(after.contains(" -lpam") == row.pam, "correction changed PAM selection")
        try requireFixture(!after.contains("glib-2.0"), "approved GLib token was retained")
    }
    var afterRestored = restored
    for (key, text) in changes {
        let prior = restored[key]!
        afterRestored[key] = Normalizer.Restored(text: text, archiveHash: prior.archiveHash, headers: prior.headers)
    }
    let afterPlan = try Normalizer.plan(smbObserved(original, restored: afterRestored), outputRoot: output)
    try requireFixture(afterPlan.isEmpty, "exact approved afterimages were not idempotent")
    let completed: Set<String> = ["macos/arm64", "tvos/arm64e"]
    var partial = restored
    for key in completed { partial[key] = afterRestored[key] }
    let partialPlan = try Normalizer.plan(smbObserved(original, restored: partial), outputRoot: output)
    try requireFixture(Set(partialPlan.keys) == correctable.subtracting(completed), "mixed exact before/after states were not recoverable")
    try requireFixture(partialPlan.allSatisfy { changes[$0.key] == $0.value }, "partial recovery changed approved output")
    let active = correctable.union(unchanged)
    let activeRestored = restored.filter { active.contains($0.key) }
    let activePlan = try Normalizer.plan(smbObserved(original, requested: active, restored: activeRestored), outputRoot: output)
    try requireFixture(activePlan == changes, "selecting the nine proven payloads changed correction policy")
    let none = try Normalizer.plan(smbObserved(original, requested: [], restored: [:]), outputRoot: output)
    try requireFixture(none.isEmpty, "wrapper validation planned unrequested writes")

    var failures: [(String, Normalizer.Snapshot)] = [
        ("wrong version", smbObserved(original, version: "4.25.1")),
        ("wrong ZIP fingerprint", smbObserved(original, zipHash: String(repeating: "0", count: 64))),
        ("missing canonical headers", smbObserved(original, headers: [:])),
        ("missing raw archive", smbObserved(original, archives: [:])),
        ("missing raw templates", smbObserved(original, templates: [:])),
        ("missing requested restored row", smbObserved(original, restored: [:])),
        ("extra restored row", smbObserved(original, requested: active)),
    ]
    var badHeaders = headers
    badHeaders["libsmbclient.h"] = "changed-header"
    failures.append(("wrong canonical header", smbObserved(original, headers: badHeaders)))
    var badArchives = archives
    badArchives["macos/arm64"] = "changed-archive"
    failures.append(("wrong raw archive", smbObserved(original, archives: badArchives)))
    badArchives = archives
    badArchives["maccatalyst/arm64"] = archives["macos/arm64"]
    failures.append(("unproven archive observation", smbObserved(original, archives: badArchives)))
    var badTemplates = templates
    badTemplates["macos/arm64"] = templates["macos/arm64"]! + "# unrelated change\n"
    failures.append(("changed raw PC", smbObserved(original, templates: badTemplates)))
    badTemplates = templates
    badTemplates["unknown/arm64"] = "unknown template"
    failures.append(("unknown raw template row", smbObserved(original, templates: badTemplates)))
    let selected = "macos/arm64"
    let prior = restored[selected]!
    var badRestored = restored
    badRestored[selected] = Normalizer.Restored(text: prior.text, archiveHash: "changed-restored-archive", headers: prior.headers)
    failures.append(("wrong restored archive", smbObserved(original, restored: badRestored)))
    badRestored = restored
    badRestored[selected] = Normalizer.Restored(text: prior.text, archiveHash: prior.archiveHash, headers: badHeaders)
    failures.append(("wrong restored header", smbObserved(original, restored: badRestored)))
    badRestored = restored
    badRestored[selected] = Normalizer.Restored(text: prior.text + "# unrelated change\n", archiveHash: prior.archiveHash, headers: prior.headers)
    failures.append(("changed restored PC", smbObserved(original, restored: badRestored)))
    badRestored = restored
    badRestored["unknown/arm64"] = prior
    failures.append(("unknown requested key", smbObserved(original, requested: requested.union(["unknown/arm64"]), restored: badRestored)))
    for (label, observation) in failures {
        try expectSmbRefusal(label) { _ = try Normalizer.plan(observation, outputRoot: output) }
    }
    // The wrapper-name guard runs before payload IO; no 97 MB ZIP is fabricated.
    try expectSmbRefusal("wrong wrapper directory") {
        _ = try Normalizer.snapshot(wrapper: root.appendingPathComponent("unapproved-wrapper"), outputRoot: output,
                                    version: Normalizer.version, requested: [])
    }

    // Exercise actual streaming fileHash only on tiny data, with a known SHA-256.
    let bytes = Data("abc".utf8)
    let small = root.appendingPathComponent("hash-input")
    try bytes.write(to: small)
    let smallHash = try Normalizer.fileHash(small, size: 3)
    try requireFixture(smallHash == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "small streaming hash differs")
    try expectSmbRefusal("wrong small-file size") { _ = try Normalizer.fileHash(small, size: 4) }
    let symlink = root.appendingPathComponent("hash-link")
    try manager.createSymbolicLink(at: symlink, withDestinationURL: small)
    try expectSmbRefusal("small-file symlink") { _ = try Normalizer.fileHash(symlink, size: 3) }
    let remainingBytes = try Data(contentsOf: small)
    try requireFixture(remainingBytes == bytes, "hash/validation changed fixture input bytes")
    let entries = try manager.contentsOfDirectory(atPath: root.path).sorted()
    try requireFixture(entries == ["hash-input", "hash-link"], "pure plan wrote files or fileHash mutated the fixture set")
    // Exact-name cached zero ZIP must refuse without deleting its cache/sibling data.
    let cache = root.appendingPathComponent("libsmbclient-\(Normalizer.version)")
    try manager.createDirectory(at: cache, withIntermediateDirectories: true)
    let zeroZIP = cache.appendingPathComponent("libsmbclient.zip")
    let sibling = cache.appendingPathComponent("keep")
    try Data().write(to: zeroZIP)
    try bytes.write(to: sibling)
    try expectSmbRefusal("cached zero ZIP") { try Normalizer.validateArchive(zeroZIP, version: Normalizer.version) }
    let zeroBytes = try Data(contentsOf: zeroZIP)
    let siblingBytes = try Data(contentsOf: sibling)
    try requireFixture(zeroBytes.isEmpty, "cached zero ZIP was changed or deleted")
    try requireFixture(siblingBytes == bytes, "cached ZIP validation deleted sibling data")
    let absentDirectory = root.appendingPathComponent("fresh-absent")
    try Normalizer.validateFreshDirectory(absentDirectory)
    try requireFixture(!manager.fileExists(atPath: absentDirectory.path), "fresh validation created a cache")
    let emptyDirectory = root.appendingPathComponent("fresh-empty")
    try manager.createDirectory(at: emptyDirectory, withIntermediateDirectories: true)
    try Normalizer.validateFreshDirectory(emptyDirectory)
    let partialDirectory = root.appendingPathComponent("fresh-partial")
    try manager.createDirectory(at: partialDirectory, withIntermediateDirectories: true)
    let retained = partialDirectory.appendingPathComponent("retained")
    try bytes.write(to: retained)
    try expectSmbRefusal("nonempty cache without ZIP") { try Normalizer.validateFreshDirectory(partialDirectory) }
    let retainedBytes = try Data(contentsOf: retained)
    try requireFixture(retainedBytes == bytes, "fresh-cache refusal changed unknown retained data")
    let directoryLink = root.appendingPathComponent("fresh-link")
    try manager.createSymbolicLink(at: directoryLink, withDestinationURL: emptyDirectory)
    try expectSmbRefusal("symlink cache without ZIP") { try Normalizer.validateFreshDirectory(directoryLink) }
    print("SMB METADATA POLICY FIXTURE PASS (synthetic fingerprints; not physical ZIP/payload validation)")
}

func runSDKSystemContract(executable: String, root: URL) throws {
    let manager = FileManager.default
    try manager.createDirectory(at: root, withIntermediateDirectories: true)
    try requireFixture(manager.changeCurrentDirectoryPath(root.path), "could not enter SDK fixture")
    let header = "#define ZLIB_VERSION \"1.2.13\"\n"
    let xmlHeader = "#define LIBXML_DOTTED_VERSION \"2.9.13\"\n"
    let stub = "--- !tapi-tbd\ntbd-version: 4\ntargets: [ arm64-macos ]\ninstall-name: '/usr/lib/libz.1.dylib'\n...\n"
    func tree(_ name: String, header text: String? = nil, stub linker: String? = nil) throws -> (URL, URL) {
        let sdk = root.appendingPathComponent(name + ".sdk"), build = root.appendingPathComponent(name + "-build")
        try manager.createDirectory(at: sdk.appendingPathComponent("usr/include"), withIntermediateDirectories: true)
        try manager.createDirectory(at: sdk.appendingPathComponent("usr/include/libxml2/libxml"), withIntermediateDirectories: true)
        try manager.createDirectory(at: sdk.appendingPathComponent("usr/lib"), withIntermediateDirectories: true)
        try manager.createDirectory(at: build, withIntermediateDirectories: true)
        try (text ?? header).write(to: sdk.appendingPathComponent("usr/include/zlib.h"), atomically: true, encoding: .utf8)
        try (linker ?? stub).write(to: sdk.appendingPathComponent("usr/lib/libz.tbd"), atomically: true, encoding: .utf8)
        try xmlHeader.write(to: sdk.appendingPathComponent("usr/include/libxml2/libxml/xmlversion.h"), atomically: true, encoding: .utf8)
        try stub.replacingOccurrences(of: "/usr/lib/libz.1.dylib", with: "/usr/lib/libxml2.2.dylib").write(to: sdk.appendingPathComponent("usr/lib/libxml2.tbd"), atomically: true, encoding: .utf8)
        return (sdk, build)
    }
    func refused(_ name: String, _ operation: () throws -> Void) throws {
        var rejected = false
        do { try operation() } catch { rejected = true }
        try requireFixture(rejected, "SDK zlib accepted " + name)
    }
    let (sdk, build) = try tree("valid")
    let metadata = try SDKSystemMetadata.prepare(sdkRoot: sdk, buildRoot: build)
    let pc = metadata.appendingPathComponent("zlib.pc")
    let expected = "Name: zlib\nDescription: Target Apple SDK zlib\nVersion: 1.2.13\nLibs: -lz\nCflags:\n"
    let xmlPC = metadata.appendingPathComponent("libxml-2.0.pc")
    let expectedXML = "Name: libxml-2.0\nDescription: Target Apple SDK libxml2\nVersion: 2.9.13\nLibs: -lxml2\nCflags: -I\"\(sdk.path)/usr/include/libxml2\"\n"
    let first = try String(contentsOf: pc, encoding: .utf8)
    let firstXML = try String(contentsOf: xmlPC, encoding: .utf8)
    let metadataNames = try manager.contentsOfDirectory(atPath: metadata.path).sorted()
    try requireFixture(firstXML == expectedXML && metadataNames == ["libxml-2.0.pc", "zlib.pc"], "SDK libxml metadata or exact two-file set differs")
    try requireFixture(metadata.path == build.appendingPathComponent("vortx-sdk-pkgconfig").path && first == expected, "SDK metadata is not the exact deterministic afterimage")
    let repeated = try SDKSystemMetadata.prepare(sdkRoot: sdk, buildRoot: build)
    let repeatedText = try String(contentsOf: pc, encoding: .utf8)
    let repeatedXML = try String(contentsOf: xmlPC, encoding: .utf8)
    try requireFixture(repeated.path == metadata.path && repeatedText == first && repeatedXML == firstXML, "SDK metadata preparation is not idempotent")
    // The actual production dictionary must replace the Process scaffold's poison.
    let host = root.appendingPathComponent("host")
    try manager.createDirectory(at: host, withIntermediateDirectories: true)
    try "Name: zlib\nDescription: Host poison\nVersion: 99.0\nLibs: -lhost_poison\n".write(to: host.appendingPathComponent("zlib.pc"), atomically: true, encoding: .utf8)
    try "Name: libxml-2.0\nDescription: Host poison\nVersion: 99.0\nLibs: -lhost_xml_poison\n".write(to: host.appendingPathComponent("libxml-2.0.pc"), atomically: true, encoding: .utf8)
    try writeModule("vortx-sdk-host-only", in: host)
    try requireFixture(ProcessInfo.processInfo.environment["PKG_CONFIG_PATH"] == host.path && ProcessInfo.processInfo.environment["PKG_CONFIG_LIBDIR"] == host.path, "SDK fixture requires poisoned parent paths")
    _ = try Utility.launch(path: executable, arguments: ["--exists", "vortx-sdk-host-only"])
    var environment = BaseBuild().environment(platform: .tvos, arch: .arm64)
    let existing = environment["PKG_CONFIG_LIBDIR"]!
    try SDKSystemMetadata.append(to: &environment, sdkRoot: sdk, buildRoot: build)
    try requireFixture(environment["PKG_CONFIG_LIBDIR"] == existing + ":" + metadata.path && environment["PKG_CONFIG_PATH"] == "", "SDK metadata must follow the unchanged target roots")
    let paths = environment["PKG_CONFIG_LIBDIR"]!.components(separatedBy: ":")
    try requireFixture(!paths.contains("") && !paths.contains(host.path), "SDK append introduced empty or host search roots")
    let target = URL(fileURLWithPath: paths[0])
    try manager.createDirectory(at: target, withIntermediateDirectories: true)
    try "Name: freetype2\nDescription: Synthetic target transitive dependency\nVersion: 2.13.0\nRequires.private: zlib\nLibs: -lfreetype\nCflags:\n".write(to: target.appendingPathComponent("freetype2.pc"), atomically: true, encoding: .utf8)
    try "Name: libbluray\nDescription: Synthetic target transitive dependency\nVersion: 1.0\nRequires.private: libxml-2.0 >= 2.6\nLibs: -lbluray\nCflags:\n".write(to: target.appendingPathComponent("libbluray.pc"), atomically: true, encoding: .utf8)
    try "Name: vortx-sdk-client\nDescription: Synthetic two-SDK-row client\nVersion: 1.0\nRequires.private: zlib libxml-2.0 >= 2.6\nLibs: -lvortx_sdk_client\n".write(to: target.appendingPathComponent("vortx-sdk-client.pc"), atomically: true, encoding: .utf8)
    let version = try Utility.launch(path: executable, arguments: ["--modversion", "zlib"], isOutput: true, environment: environment)
    let flags = try Utility.launch(path: executable, arguments: ["--cflags", "zlib"], isOutput: true, environment: environment)
    let libs = try Utility.launch(path: executable, arguments: ["--libs", "zlib"], isOutput: true, environment: environment)
    let transitive = try Utility.launch(path: executable, arguments: ["--static", "--libs", "freetype2"], isOutput: true, environment: environment)
    let xmlVersion = try Utility.launch(path: executable, arguments: ["--modversion", "libxml-2.0"], isOutput: true, environment: environment)
    let xmlFlags = try Utility.launch(path: executable, arguments: ["--cflags", "libxml-2.0"], isOutput: true, environment: environment)
    let bluray = try Utility.launch(path: executable, arguments: ["--static", "--libs", "libbluray"], isOutput: true, environment: environment)
    let both = try Utility.launch(path: executable, arguments: ["--static", "--libs", "vortx-sdk-client"], isOutput: true, environment: environment)
    try requireFixture(xmlVersion == "2.9.13" && xmlFlags.trimmingCharacters(in: .whitespacesAndNewlines) == "-I\(sdk.path)/usr/include/libxml2", "SDK libxml version/include path resolved host metadata")
    try requireFixture(bluray.split(whereSeparator: { $0.isWhitespace }).map(String.init) == ["-lbluray", "-lxml2"], "real pkg-config did not resolve target libbluray to SDK libxml")
    try requireFixture(both.split(whereSeparator: { $0.isWhitespace }).map(String.init) == ["-lvortx_sdk_client", "-lz", "-lxml2"], "real pkg-config did not resolve the two fixed SDK rows")
    try requireFixture(version == "1.2.13" && flags.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && libs.trimmingCharacters(in: .whitespacesAndNewlines) == "-lz", "SDK zlib resolved host metadata or added include/library search flags")
    try requireFixture(transitive.split(whereSeparator: { $0.isWhitespace }).map(String.init) == ["-lfreetype", "-lz"], "real pkg-config did not resolve target freetype to SDK zlib")
    let leaked = try? Utility.launch(path: executable, arguments: ["--exists", "vortx-sdk-host-only"], environment: environment)
    try requireFixture(leaked == nil, "poisoned host metadata leaked after SDK append")
    // Exercise the production producer with the same versioned-alias shape as Xcode.
    let selectedSDK = root.appendingPathComponent("selected-version.sdk")
    let selectedBuild = root.appendingPathComponent("selected-version-build")
    try manager.createSymbolicLink(at: selectedSDK, withDestinationURL: sdk)
    try manager.createDirectory(at: selectedBuild, withIntermediateDirectories: false)
    var selectedEnvironment = BaseBuild().environment(platform: .tvos, arch: .arm64)
    try SDKSystemMetadata.append(to: &selectedEnvironment, sdkRoot: selectedSDK, buildRoot: selectedBuild)
    let selectedMetadata = selectedBuild.appendingPathComponent("vortx-sdk-pkgconfig")
    let selectedXML = try String(contentsOf: selectedMetadata.appendingPathComponent("libxml-2.0.pc"), encoding: .utf8)
    let selectedZlib = try String(contentsOf: selectedMetadata.appendingPathComponent("zlib.pc"), encoding: .utf8)
    let selectedFlags = try Utility.launch(path: executable, arguments: ["--cflags", "libxml-2.0"], isOutput: true, environment: selectedEnvironment)
    let selectedVersion = try Utility.launch(path: executable, arguments: ["--modversion", "libxml-2.0"], isOutput: true, environment: selectedEnvironment)
    try requireFixture(selectedSDK.resolvingSymlinksInPath().path == sdk.path &&
        selectedXML == expectedXML.replacingOccurrences(of: sdk.path, with: selectedSDK.path) &&
        selectedZlib == expected && selectedVersion == "2.9.13" &&
        selectedFlags.trimmingCharacters(in: .whitespacesAndNewlines) == "-I\(selectedSDK.path)/usr/include/libxml2",
        "SDK alias metadata lost selected compiler spelling or canonical SDK identity")
    _ = try SDKSystemMetadata.prepare(sdkRoot: selectedSDK, buildRoot: selectedBuild)
    // Alias spelling must retain the producer's PC-path safety policy before any write.
    for (index, name) in ["$selected.sdk", "selected\nversion.sdk"].enumerated() {
        let unsafeSDK = root.appendingPathComponent(name)
        let unsafeBuild = root.appendingPathComponent("unsafe-selected-\(index)-build")
        try manager.createSymbolicLink(at: unsafeSDK, withDestinationURL: sdk)
        try manager.createDirectory(at: unsafeBuild, withIntermediateDirectories: false)
        var rejected = false
        do { _ = try SDKSystemMetadata.prepare(sdkRoot: unsafeSDK, buildRoot: unsafeBuild) }
        catch let error as NSError where error.domain == "VortX.SDKSystemMetadata" && error.code == 1 { rejected = true }
        try requireFixture(rejected && !manager.fileExists(atPath: unsafeBuild.appendingPathComponent("vortx-sdk-pkgconfig").path),
            "Unsafe SDK alias was accepted or wrote metadata before rejection")
    }
    try "Name: zlib\nDescription: Earlier target zlib\nVersion: 7.7.7\nLibs: -ltarget_zlib\n".write(to: target.appendingPathComponent("zlib.pc"), atomically: true, encoding: .utf8)
    let earlier = try Utility.launch(path: executable, arguments: ["--modversion", "zlib"], isOutput: true, environment: environment)
    try requireFixture(earlier == "7.7.7", "SDK zlib shadowed an earlier target dependency")
    try "Name: libxml-2.0\nDescription: Earlier target libxml\nVersion: 7.7.7\nLibs: -ltarget_xml\n".write(to: target.appendingPathComponent("libxml-2.0.pc"), atomically: true, encoding: .utf8)
    let earlierXML = try Utility.launch(path: executable, arguments: ["--modversion", "libxml-2.0"], isOutput: true, environment: environment)
    try requireFixture(earlierXML == "7.7.7", "SDK libxml shadowed an earlier target dependency")
    for (name, value) in [("empty", ""), ("leading", ":" + existing), ("trailing", existing + ":"), ("middle", existing + "::missing")] {
        var invalid = environment; invalid["PKG_CONFIG_LIBDIR"] = value
        try refused(name + " LIBDIR") { try SDKSystemMetadata.append(to: &invalid, sdkRoot: sdk, buildRoot: build) }
    }
    var inherited = environment; inherited["PKG_CONFIG_PATH"] = host.path
    try refused("nonempty PKG_CONFIG_PATH") { try SDKSystemMetadata.append(to: &inherited, sdkRoot: sdk, buildRoot: build) }
    for (name, text) in [("malformed", "#define ZLIB_VERSION \"1.2.13-host\"\n"), ("duplicate", header + header)] {
        let (badSDK, badBuild) = try tree(name, header: text)
        try refused(name + " version") { _ = try SDKSystemMetadata.prepare(sdkRoot: badSDK, buildRoot: badBuild) }
    }
    for (name, text) in [("malformed-xml", "#define LIBXML_DOTTED_VERSION \"2.9.13-host\"\n"), ("duplicate-xml", xmlHeader + xmlHeader)] {
        let (badSDK, badBuild) = try tree(name)
        try text.write(to: badSDK.appendingPathComponent("usr/include/libxml2/libxml/xmlversion.h"), atomically: true, encoding: .utf8)
        try refused(name + " version") { _ = try SDKSystemMetadata.prepare(sdkRoot: badSDK, buildRoot: badBuild) }
    }
    for (name, missing) in [("missing-header", "usr/include/zlib.h"), ("missing-stub", "usr/lib/libz.tbd"), ("missing-xml-header", "usr/include/libxml2/libxml/xmlversion.h"), ("missing-xml-stub", "usr/lib/libxml2.tbd")] {
        let (badSDK, badBuild) = try tree(name)
        try manager.removeItem(at: badSDK.appendingPathComponent(missing))
        try refused(name) { _ = try SDKSystemMetadata.prepare(sdkRoot: badSDK, buildRoot: badBuild) }
    }
    let (invalidSDK, invalidBuild) = try tree("invalid-stub", stub: "not a TAPI zlib stub\n")
    try refused("invalid stub identity") { _ = try SDKSystemMetadata.prepare(sdkRoot: invalidSDK, buildRoot: invalidBuild) }
    let (wrongSDK, wrongBuild) = try tree("wrong-stub", stub: stub.replacingOccurrences(of: "/usr/lib/libz.1.dylib", with: "/usr/lib/libhost.dylib"))
    try refused("wrong TAPI install name") { _ = try SDKSystemMetadata.prepare(sdkRoot: wrongSDK, buildRoot: wrongBuild) }
    let (linkedSDK, linkedBuild) = try tree("linked-stub")
    try manager.moveItem(at: linkedSDK.appendingPathComponent("usr/lib/libz.tbd"), to: linkedSDK.appendingPathComponent("usr/lib/libz.1.tbd"))
    try manager.createSymbolicLink(atPath: linkedSDK.appendingPathComponent("usr/lib/libz.tbd").path, withDestinationPath: "libz.1.tbd")
    let linkedMetadata = try SDKSystemMetadata.prepare(sdkRoot: linkedSDK, buildRoot: linkedBuild)
    let (xmlLinkedSDK, xmlLinkedBuild) = try tree("linked-xml-stub")
    try manager.moveItem(at: xmlLinkedSDK.appendingPathComponent("usr/lib/libxml2.tbd"), to: xmlLinkedSDK.appendingPathComponent("usr/lib/libxml2.2.tbd"))
    try manager.createSymbolicLink(atPath: xmlLinkedSDK.appendingPathComponent("usr/lib/libxml2.tbd").path, withDestinationPath: "libxml2.2.tbd")
    _ = try SDKSystemMetadata.prepare(sdkRoot: xmlLinkedSDK, buildRoot: xmlLinkedBuild)
    let (escapeSDK, escapeBuild) = try tree("escaping-stub")
    let outside = root.appendingPathComponent("outside.tbd"); try stub.write(to: outside, atomically: true, encoding: .utf8)
    try manager.removeItem(at: escapeSDK.appendingPathComponent("usr/lib/libz.tbd"))
    try manager.createSymbolicLink(at: escapeSDK.appendingPathComponent("usr/lib/libz.tbd"), withDestinationURL: outside)
    try refused("escaping stub symlink") { _ = try SDKSystemMetadata.prepare(sdkRoot: escapeSDK, buildRoot: escapeBuild) }
    let keptOutside = try String(contentsOf: outside, encoding: .utf8)
    try requireFixture(keptOutside == stub, "escaping-stub refusal changed its target")
    let (escapeXML, escapeXMLBuild) = try tree("escaping-xml-stub")
    try manager.removeItem(at: escapeXML.appendingPathComponent("usr/lib/libxml2.tbd"))
    try manager.createSymbolicLink(at: escapeXML.appendingPathComponent("usr/lib/libxml2.tbd"), withDestinationURL: xmlLinkedSDK.appendingPathComponent("usr/lib/libxml2.2.tbd"))
    try refused("escaping libxml stub symlink") { _ = try SDKSystemMetadata.prepare(sdkRoot: escapeXML, buildRoot: escapeXMLBuild) }
    for name in ["zlib.pc", "libxml-2.0.pc"] {
        let (badSDK, badBuild) = try tree("prevalidate-" + name)
        let directory = badBuild.appendingPathComponent("vortx-sdk-pkgconfig")
        try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        let unknownPC = directory.appendingPathComponent(name)
        try "unknown\n".write(to: unknownPC, atomically: true, encoding: .utf8)
        try refused("unknown " + name + " before any other row write") { _ = try SDKSystemMetadata.prepare(sdkRoot: badSDK, buildRoot: badBuild) }
        let names = try manager.contentsOfDirectory(atPath: directory.path)
        let kept = try String(contentsOf: unknownPC, encoding: .utf8)
        try requireFixture(names == [name] && kept == "unknown\n", "refusal wrote the missing row or changed unknown metadata")
    }
    try "unknown metadata\n".write(to: pc, atomically: true, encoding: .utf8)
    try refused("unknown existing PC") { _ = try SDKSystemMetadata.prepare(sdkRoot: sdk, buildRoot: build) }
    let unknown = try String(contentsOf: pc, encoding: .utf8)
    try requireFixture(unknown == "unknown metadata\n", "unknown PC was overwritten")
    try expected.write(to: pc, atomically: true, encoding: .utf8)
    let extra = metadata.appendingPathComponent("keep"); try "keep\n".write(to: extra, atomically: true, encoding: .utf8)
    try refused("extra metadata entry") { _ = try SDKSystemMetadata.prepare(sdkRoot: sdk, buildRoot: build) }
    let kept = try String(contentsOf: extra, encoding: .utf8)
    try requireFixture(kept == "keep\n", "unknown metadata entry was changed")
    let (_, aliasBuild) = try tree("symlink-dir")
    try manager.createSymbolicLink(at: aliasBuild.appendingPathComponent("vortx-sdk-pkgconfig"), withDestinationURL: linkedMetadata)
    try refused("symlink metadata directory") { _ = try SDKSystemMetadata.prepare(sdkRoot: sdk, buildRoot: aliasBuild) }
    let alias = try manager.destinationOfSymbolicLink(atPath: aliasBuild.appendingPathComponent("vortx-sdk-pkgconfig").path)
    try requireFixture(alias == linkedMetadata.path, "refused metadata symlink was changed")
    print("SDK SYSTEM FIXTURE PASS (synthetic SDK zlib/libxml metadata and real pkg-config; no native build/link proof)")
}

do {
    if CommandLine.arguments[1] == "--target-isolation" {
        try runTargetIsolation(executable: CommandLine.arguments[2], root: URL(fileURLWithPath: CommandLine.arguments[3]))
    } else if CommandLine.arguments[1] == "--smb-metadata-contract" {
        try runSmbMetadataContract(root: URL(fileURLWithPath: CommandLine.arguments[2]))
    } else if CommandLine.arguments[1] == "--sdk-zlib-contract" {
        try runSDKSystemContract(executable: CommandLine.arguments[2], root: URL(fileURLWithPath: CommandLine.arguments[3]))
    } else {
        let expectedSHA = CommandLine.arguments[1]
        let checkout = URL(fileURLWithPath: CommandLine.arguments[2])
        try SpikeGit.clonePinned(url: "unused", sha: expectedSHA, library: .fixture, into: checkout)
        print("SPIKE FIXTURE PASS")
    }
    exit(0)
} catch {
    print("PRODUCTION FIXTURE FAILURE: \(error.localizedDescription)")
    exit(1)
}
SWIFT_ISOLATION
} >"$SWIFT_HELPER"

SWIFT_BINARY="$FIXTURE/spikegit-fixture"
swiftc -j 1 -num-threads 1 "$SWIFT_HELPER" -o "$SWIFT_BINARY" || fail "actual patched SpikeGit fixture did not compile"

PKG_CONFIG_PATH="$FIXTURE/sdk-zlib-contract/host" PKG_CONFIG_LIBDIR="$FIXTURE/sdk-zlib-contract/host" \
  "$SWIFT_BINARY" --sdk-zlib-contract "$PKG_CONFIG_EXECUTABLE" "$FIXTURE/sdk-zlib-contract" \
  >"$FIXTURE/sdk-zlib-contract.log" 2>&1 ||
  fail "compiled production SDK zlib fixture failed: $(cat "$FIXTURE/sdk-zlib-contract.log")"

# Pure-policy coverage uses synthetic observations of immutable production pins;
# this invocation does not hash or validate the physical wrapper ZIP/payloads.
"$SWIFT_BINARY" --smb-metadata-contract "$FIXTURE/smb-metadata-contract" \
  >"$FIXTURE/smb-metadata-contract.log" 2>&1 ||
  fail "compiled production SMB metadata policy fixture failed: $(cat "$FIXTURE/smb-metadata-contract.log")"

# The Process scaffold deliberately merges its poisoned parent environment, then
# overlays the actual production dictionary. Production Utility.launch instead
# carries HOME/default PATH only; this fixture does not claim it inherits poison.
PKG_CONFIG_PATH="$FIXTURE/pkg-config/host-path" \
  PKG_CONFIG_LIBDIR="$FIXTURE/pkg-config/host-libdir" \
  "$SWIFT_BINARY" --target-isolation "$PKG_CONFIG_EXECUTABLE" "$FIXTURE/pkg-config" \
  >"$FIXTURE/target-isolation.log" 2>&1 ||
  fail "compiled production target-isolation fixture failed: $(cat "$FIXTURE/target-isolation.log")"

run_spike() {
  local expected_sha="$1" log="$2"
  (cd "$SOURCE" && "$SWIFT_BINARY" "$expected_sha" "$SOURCE") >"$log" 2>&1
}

run_spike "$FIXTURE_REF" "$FIXTURE/swift-clean.log" ||
  fail "compiled SpikeGit rejected the initial clean checkout: $(cat "$FIXTURE/swift-clean.log")"
git -C "$SOURCE" apply "$FIXTURE_PATCH"
run_spike "$FIXTURE_REF" "$FIXTURE/swift-retry.log" ||
  fail "compiled SpikeGit rejected the exact patched retry: $(cat "$FIXTURE/swift-retry.log")"

BAD_REF="0000000000000000000000000000000000000000"
if run_spike "$BAD_REF" "$FIXTURE/swift-wrong-sha.log"; then
  fail "compiled SpikeGit accepted a wrong SHA"
fi
grep -Fq 'expected' "$FIXTURE/swift-wrong-sha.log" || fail "wrong SHA lacked the exact-pin diagnostic"

printf '%s\n' 'let unrelated = true' >>"$SOURCE/Package.swift"
if run_spike "$FIXTURE_REF" "$FIXTURE/swift-unrelated.log"; then
  fail "compiled SpikeGit accepted an unrelated same-file edit"
fi
grep -Fq 'conflicting, partial, or unrelated' "$FIXTURE/swift-unrelated.log" ||
  fail "compiled SpikeGit same-file rejection lacked the exact-tree diagnostic"
cp "$FIXTURE/exact-package.swift" "$SOURCE/Package.swift"

printf '%s\n' 'unrelated Swift recipe edit' >>"$SOURCE/$FIXTURE_SWIFT_RECIPE"
if run_spike "$FIXTURE_REF" "$FIXTURE/swift-unrelated-recipe.log"; then
  fail "compiled SpikeGit accepted an unrelated approved-recipe edit"
fi
grep -Fq 'conflicting, partial, or unrelated' "$FIXTURE/swift-unrelated-recipe.log" ||
  fail "compiled SpikeGit recipe rejection lacked the exact-tree diagnostic"
cp "$FIXTURE/exact-swift-recipe.patch" "$SOURCE/$FIXTURE_SWIFT_RECIPE"

printf '%s\n' 'untracked Swift fixture data' >"$SOURCE/swift-untracked.txt"
if run_spike "$FIXTURE_REF" "$FIXTURE/swift-untracked.log"; then
  fail "compiled SpikeGit accepted an unknown untracked file"
fi
grep -Fq 'not owned by the approved patch set' "$FIXTURE/swift-untracked.log" ||
  fail "compiled SpikeGit untracked rejection lacked the ownership diagnostic"


# Fifth source route preserves the exact retained wrapper class while requiring
# complete new source authentication before any compile.
grep -Fq 'private class BuildFreetypeSource: PinnedSubtitleReleaseBuild' "$PATCH" || fail "FT source class missing"
grep -Fq 'verify-freetype' "$PATCH" || fail "FT-aware source verifier missing"
grep -Fq 'd5fb41dd3d66c6e433b389a398571b51b8d65f3f9e81f10ee61d5434a647749e' "$PATCH" || fail "retained FT wrapper guard lost"
grep -Fq 'SRC_FREETYPE=$subtitle_work/dist/libfreetype-2.15.0-37515cf5' "$BUILD" || fail "FT source readonly root absent"
grep -Fq 'Libfreetype:Libfreetype' "$ROOT/scripts/assemble-mpvkit-dvfel.sh" || fail "FT local target absent"
grep -Fq '9efee8b0508e142f38d1c7e2e192d3e5041aa4bbf6c2ab1a901518211f76a914' "$BUILD" || fail "FT raw source body pin absent"
grep -Fq 'apple-freetype-source.tar.gz' "$ROOT/scripts/native-media-hosted/build.sh" || fail "FT corresponding source output absent"

echo "PASS: compiled production SpikeGit and target pkg-config isolation, MPVKit-DVFEL pin/dirty-state, FFmpeg/Libmpv capability, exact slices, TLS, and post-fetch artifact contracts"
