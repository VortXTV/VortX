#!/usr/bin/env bash
set -euo pipefail

# REL-02 + REL-03 executable contracts for the release orchestration surface. Run anywhere with
# bash + git; greps are anchored to the exact invariants the audit requires, so a regression in
# artifact naming, event/ref binding, secretless PR validation, or the no-debug-fallback posture
# fails here instead of surfacing during a real release.

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly RELEASE_WF="$REPO_ROOT/.github/workflows/android-release.yml"
readonly VALIDATION_WF="$REPO_ROOT/.github/workflows/release-packaging-validation.yml"
readonly ANDROID_CI_WF="$REPO_ROOT/.github/workflows/android.yml"
readonly CODEQL_WF="$REPO_ROOT/.github/workflows/codeql.yml"
readonly APPLE_RELEASE_WF="$REPO_ROOT/.github/workflows/release-tvos.yml"
readonly RECOVERY_WF="$REPO_ROOT/.github/workflows/recover-release-feed.yml"
readonly ANDROID_AUGMENT_WF="$REPO_ROOT/.github/workflows/augment-android-release-feed.yml"
readonly ROOT_GRADLE_BUILD="$REPO_ROOT/android/build.gradle.kts"
readonly GRADLE_BUILD="$REPO_ROOT/android/app/build.gradle.kts"
readonly MPV_SEAM_BUILD="$REPO_ROOT/android/mpv-seam/build.gradle.kts"
readonly ARTIFACTS_DOC="$REPO_ROOT/docs/RELEASE-ARTIFACTS.md"
readonly VERSION_CHECK="$REPO_ROOT/scripts/verify-android-release-version.sh"
readonly CHANGELOG="$REPO_ROOT/CHANGELOG.md"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

ok() {
    printf 'ok: %s\n' "$1"
}

require_grep() {
    local description="$1" pattern="$2" file="$3"
    grep -Eq -- "$pattern" "$file" || fail "$description"
    ok "$description"
}

require_absent() {
    local description="$1" pattern="$2" shift_file="$3"
    if grep -Eq "$pattern" "$shift_file"; then
        fail "$description"
    fi
    ok "$description"
}

# Extract the YAML `on:` trigger block (from the `on:` line up to the next top-level key) so
# trigger assertions cannot be fooled by prose mentions inside comments.
trigger_block() {
    awk '/^on:/{flag=1} flag && /^[a-zA-Z_-]+:/ && !/^on:/{exit} flag{print}' "$1"
}

[[ -f "$RELEASE_WF" ]] || fail "release workflow missing: $RELEASE_WF"
[[ -f "$VALIDATION_WF" ]] || fail "secretless validation workflow missing: $VALIDATION_WF"

# Release and candidate builds must share the same immutable wrapper revision; otherwise a
# source-level history API can link on one platform yet ship an older engine on another.
engine_pin=""
for wf in "$APPLE_RELEASE_WF" "$ANDROID_CI_WF" "$RELEASE_WF"; do
    pin="$(awk '/repository: VortXTV\/stremiox-core/{active=1; next}
        active && /^[[:space:]]+ref:/{print $2; exit}' "$wf")"
    [[ "$pin" =~ ^[0-9a-f]{40}$ ]] || fail "$(basename "$wf") wrapper pin must be immutable"
    [[ -z "$engine_pin" || "$engine_pin" = "$pin" ]] || fail "Apple/Android wrapper pins differ"
    engine_pin="$pin"
done
candidate_signing_step="$(awk '/name: Verify signed release artifacts against the pinned production signer/{active=1; next}
    active && /^[[:space:]]+- name:/{exit} active{print}' "$ANDROID_CI_WF")"
require_grep "signed candidate APK and AAB both verify complete engine ABIs" \
    'verify-native-android-artifacts\.sh .*--native-only|--native-only --staged-dir android/app/src/main/jniLibs' \
    <(printf '%s\n' "$candidate_signing_step")
ok "Apple and both Android lanes use one exact wrapper revision"
native_pin=""
for wf in "$APPLE_RELEASE_WF" "$ANDROID_CI_WF" "$RELEASE_WF"; do
    pin="$(awk '/repository: VortXTV\/vortx-core/{active=1; next}
        active && /^[[:space:]]+ref:/{print $2; exit}' "$wf")"
    [[ "$pin" =~ ^[0-9a-f]{40}$ ]] || fail "$(basename "$wf") native engine pin must be immutable"
    [[ -z "$native_pin" || "$native_pin" = "$pin" ]] || fail "Apple/Android native engine pins differ"
    native_pin="$pin"
done
ok "Apple and both Android lanes use one exact native engine revision"

# A directly invoked gate must survive Git checkout as executable; otherwise CI fails before its
# artifact checks run. Inspect the actual workflow commands and tracked modes, not a prose list.
direct_helpers=0
while IFS= read -r helper; do
    [[ "$helper" =~ ^\./scripts/[A-Za-z0-9._-]+\.sh$ ]] || fail "unsafe direct Apple helper path: $helper"
    relative="${helper#./}"
    mode="$(git -C "$REPO_ROOT" ls-files -s -- "$relative" | awk '{print $1}')"
    [[ "$mode" == 100755 && -x "$REPO_ROOT/$relative" ]] \
        || fail "Apple directly executes a non-executable tracked helper: $relative (mode $mode)"
    direct_helpers=$((direct_helpers + 1))
done < <(awk '/^[[:space:]]*(run: )?\.\/scripts\// {
    for (i=1; i<=NF; i++) if ($i ~ /^\.\/scripts\/.*\.sh$/) print $i
}' "$APPLE_RELEASE_WF" | sort -u)
[[ "$direct_helpers" -gt 0 ]] || fail "Apple direct-helper contract inspected no commands"
ok "all actual direct Apple build and artifact-gate helpers have executable Git modes"

# Execute only the real MPV selection prefix, stopping before its first network/download command.
# This proves the reviewed default works with empty push/dispatch inputs, overrides are atomic,
# and the retired digest remains rejected independently of the new EXPECTED digest.
readonly REVIEWED_MPV_SHA='ccccc9a3faa84276bf10625d652dd4c9eea04c6a0abdc8e26cb1b35f147514fb'
readonly REVIEWED_MPV_URL='https://github.com/VortXTV/VortX/releases/download/vendor-mpvkit-dvfel-2/mpvkit-dvfel-artifacts-ffmpeg9-20261008.zip'
readonly LEGACY_MPV_SHA='6b22848743a9744dc4d61edadf6ae82eac583ea6802e2d154f4a6fbc9aa03fc1'
mpv_selection="$(awk '
    /name: Fetch the MPVKit-DVFEL artifacts \(pinned, sha256-verified\)/ { step=1; next }
    step && /^        run: \|$/ { script=1; next }
    script && /curl -sfL/ { exit }
    script { sub(/^          /, ""); print }
' "$APPLE_RELEASE_WF")"
[[ "$mpv_selection" == *'LEGACY_MPVKIT_SHA256='* && "$mpv_selection" == *'EXPECTED='* ]] \
    || fail "MPV selection prefix is missing"
mpv_selected_pair() {
    REVIEWED_MPVKIT_URL="$1" REVIEWED_MPVKIT_SHA256="$2" \
        bash -c "$mpv_selection"$'\n''printf "%s\\n%s\\n" "$URL" "$EXPECTED"'
}
expected_mpv_pair="$REVIEWED_MPV_URL"$'\n'"$REVIEWED_MPV_SHA"
[[ "$(mpv_selected_pair '' '')" = "$expected_mpv_pair" ]] \
    || fail "empty MPV inputs do not select the pinned fresh package"
[[ "$(mpv_selected_pair "$REVIEWED_MPV_URL" "$REVIEWED_MPV_SHA")" = "$expected_mpv_pair" ]] \
    || fail "valid explicit fresh MPV pair was rejected"
for invalid in url-only sha-only bad-sha foreign-url old-sha; do
    case "$invalid" in
        url-only) override_url="$REVIEWED_MPV_URL"; override_sha='' ;;
        sha-only) override_url=''; override_sha="$REVIEWED_MPV_SHA" ;;
        bad-sha) override_url="$REVIEWED_MPV_URL"; override_sha='latest' ;;
        foreign-url) override_url='https://example.com/player.zip'; override_sha="$REVIEWED_MPV_SHA" ;;
        old-sha) override_url="$REVIEWED_MPV_URL"; override_sha="$LEGACY_MPV_SHA" ;;
    esac
    if mpv_selected_pair "$override_url" "$override_sha" >/dev/null 2>&1; then
        fail "MPV selector accepted $invalid override"
    fi
done
require_grep "secretless Apple validation uses the same reviewed MPV digest" \
    "MPVKIT_ARTIFACTS_SHA256: \"$REVIEWED_MPV_SHA\"" "$VALIDATION_WF"
grep -Fq "$REVIEWED_MPV_URL" "$VALIDATION_WF" \
    || fail "secretless Apple validation uses a different MPV URL"
require_grep "secretless Apple validation retains actual player content verification" \
    'bash scripts/verify-mpvkit-dvfel-artifacts\.sh "\$DEST"' "$VALIDATION_WF"
ok "actual MPV selector accepts the reviewed fallback/pair and rejects partial, foreign and legacy inputs"

# Exercise the actual effective expression and generator shell routing without compiling or
# downloading anything. Command fixtures log only the selected XcodeGen route; the real generated
# target/dependency/define/floor contract remains in test-native-apple-project.rb.
node --input-type=module - "$APPLE_RELEASE_WF" "$REPO_ROOT" <<'NODE'
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
const [workflow, root] = process.argv.slice(2);
const source = readFileSync(workflow, 'utf8');
const input = source.match(/^      native_only:\n([\s\S]*?)(?=^      [a-z_]+:)/m)?.[1];
assert.ok(input, 'native selection input must exist');
assert.match(input, /^        type: boolean$/m);
const defaultValue = input.match(/^        default: (true|false)$/m)?.[1];
assert.equal(defaultValue, 'true', 'shipping dispatch must default to native');
const build = source.match(/^  build-tvos:\n([\s\S]*?)^  attach-release:/m)?.[1];
assert.ok(build, 'build job must be distinct from the release-write job');
const expression = build.match(/^      VORTX_NATIVE_ONLY: \$\{\{ (.+) \}\}$/m)?.[1];
assert.ok(expression, 'build job must define its single effective selector');
assert.equal((build.match(/inputs\.native_only/g) ?? []).length, 1,
  'no build consumer may bypass the effective selector with absent push inputs');
const evaluate = new Function('github', 'inputs', `return (${expression});`);
const step = (name) => {
  const block = build.split(/^      - /m).find(value => value.startsWith(`name: ${name}\n`));
  assert.ok(block, `${name}: required step missing`);
  return block;
};
const run = (block) => {
  const script = block.split('        run: |\n')[1];
  assert.ok(script, 'fixture requires the actual step shell');
  return script.split('\n').filter(line => line.startsWith('          '))
    .map(line => line.slice(10)).join('\n');
};
const shellConsumers = ['Generate the Xcode project', 'Smoke-test tvOS launch in a simulator (fail closed)',
  'Gate iOS-simulator link + dSYM (fail closed)', 'Package Full tvOS test IPA', 'Package the IPAs'];
assert.equal((build.match(/^          NATIVE_ONLY:/gm) ?? []).length, shellConsumers.length);
for (const name of shellConsumers) {
  assert.match(step(name), /^          NATIVE_ONLY: \$\{\{ env\.VORTX_NATIVE_ONLY \}\}$/m,
    `${name}: use the same effective native selection`);
}
const proofConditions = ['Capture exact native SDK and player inputs before app compilation',
  'Verify exact native app selection and linked inputs'].map(name => {
    const condition = step(name).match(/^        if: (.+)$/m)?.[1];
    assert.equal(condition, "env.VORTX_NATIVE_ONLY == 'true'", `${name}: proof condition`);
    return new Function('env', `return (${condition});`);
  });
const comparison = step('Constrain legacy comparison to artifact-only builds');
const comparisonCondition = comparison.match(/^        if: (.+)$/m)?.[1];
assert.equal(comparisonCondition, "env.VORTX_NATIVE_ONLY != 'true'");
const comparisonRequired = new Function('env', `return (${comparisonCondition});`);
const generator = run(step('Generate the Xcode project'));
const commands = 'ruby() { printf "ruby:%s\\n" "$*"; }\nxcodegen() { printf "xcodegen:%s\\n" "$*"; }\n';
for (const [name, event, inputs, expected] of [
  ['push without inputs', 'push', {}, true],
  ['push ignores dispatch comparison value', 'push', {native_only: false}, true],
  ['default dispatch', 'workflow_dispatch', {native_only: defaultValue === 'true'}, true],
  ['explicit native dispatch', 'workflow_dispatch', {native_only: true}, true],
  ['explicit legacy comparison', 'workflow_dispatch', {native_only: false}, false],
]) {
  const selected = evaluate({event_name: event}, inputs);
  assert.equal(selected, expected, name);
  const env = {VORTX_NATIVE_ONLY: String(selected)};
  for (const proof of proofConditions) assert.equal(proof(env), expected, `${name}: native proof`);
  assert.equal(comparisonRequired(env), !expected, `${name}: comparison guard`);
  const routed = spawnSync('bash', ['-c', commands + generator], {cwd: root, encoding: 'utf8',
    env: {...process.env, NATIVE_ONLY: env.VORTX_NATIVE_ONLY, VORTX_ENGINE_SOURCE_REVISION: '0'.repeat(40)}});
  assert.equal(routed.status, 0, `${name}: ${routed.stderr}`);
  if (expected) {
    assert.match(routed.stdout, /ruby:..\/scripts\/generate-native-apple-project\.rb --engine-revision 0{40} /);
    assert.match(routed.stdout, /xcodegen:generate --spec \.native-project\.yml\n/);
  } else {
    assert.equal(routed.stdout, 'xcodegen:generate\n', 'explicit comparison keeps the legacy spec');
  }
}
const comparisonScript = run(comparison);
for (const [name, tag, id, publish, accepted] of [
  ['artifact-only comparison', '', '', 'false', true],
  ['comparison with release tag', 'v0.5.0-beta.1', '', 'false', false],
  ['comparison with release ID', '', '123', 'false', false],
  ['comparison publication', '', '', 'true', false],
]) {
  const result = spawnSync('bash', ['-c', comparisonScript], {encoding: 'utf8',
    env: {...process.env, COMPARISON_RELEASE_TAG: tag, COMPARISON_RELEASE_ID: id, COMPARISON_PUBLISH: publish}});
  assert.equal(result.status === 0, accepted, name);
}
NODE
ok "actual Apple effective selector routes push/default dispatch and every proof to native; legacy comparison cannot ship"

require_grep "Apple builds the native resource host" \
    'run: ./scripts/build-ffi-xcframework.sh --resource-host$' "$APPLE_RELEASE_WF"
require_grep "Apple verifies resource and state ABI on warm and cold builds" \
    'run: ./scripts/verify-native-engine-abi.sh apple app/Vendor/VortxEngine.xcframework resource-host$' "$APPLE_RELEASE_WF"
require_grep "Mac server is built from the same pinned private workspace" \
    'run: ./scripts/build-mac-server.sh$' "$APPLE_RELEASE_WF"
for wf in "$ANDROID_CI_WF" "$RELEASE_WF"; do
    # Every engine-required Gradle invocation, including the separately signed
    # build, must select the same resource-host feature set.
    awk '/VORTX_REQUIRE_ENGINE: "1"/ { required++; waiting=1; next }
         waiting { if ($0 !~ /VORTX_NATIVE_RESOURCE_HOST: "1"/) exit 1; enabled++; waiting=0 }
         END { if (!required || required != enabled || waiting) exit 1 }' "$wf" ||
        fail "$(basename "$wf") has an engine build without the resource host"
    require_grep "$(basename "$wf") invokes native-only staged/package verification" \
        '--native-only --staged-dir android/app/src/main/jniLibs' "$wf"
done
require_grep "native-only Android verifier retains resource-host ABI proof" \
    'verify-native-engine-abi\.sh.*android.*resource-host' "$REPO_ROOT/scripts/verify-native-android-artifacts.sh"
require_grep "native-only verifier rejects legacy Stremio JNI packaging" \
    'native-only artifact still contains legacy libstremiox_core\.so' "$REPO_ROOT/scripts/verify-native-android-artifacts.sh"
require_grep "Android quality analysis uses the NDK-aware traced build" \
    'queries: \./\.github/codeql/java-quality\.qls' "$CODEQL_WF"
require_grep "Android quality suite retains GitHub's maintained selector" \
    'apply: code-quality-selectors\.yml' "$REPO_ROOT/.github/codeql/java-quality.qls"

# setup-android's default includes the removed standalone 'tools' package. Validate the actual
# action block, not a matching comment elsewhere, in every SDK lane before any native build starts.
for wf in "$ANDROID_CI_WF" "$RELEASE_WF" "$VALIDATION_WF" "$CODEQL_WF"; do
    sdk_setup="$(awk '/uses: android-actions\/setup-android@/{active=1}
        active && /^[[:space:]]*-[[:space:]]/{exit} active{print}' "$wf")"
    require_grep "$(basename "$wf") installs supported explicit Android SDK packages" \
        '^[[:space:]]+packages: "platform-tools platforms;android-36 build-tools;36\.0\.0"$' \
        <(printf '%s\n' "$sdk_setup")
done

# Native configuration must see the same pinned NDK before defaultConfig or flavors can resolve
# a CXX model. A later second android block must not silently leave earlier configuration on AGP's
# default version. Installation is still required separately; this is not an autobuild workaround.
readonly NDK_PIN="27.2.12479018"
app_ndk_pin="$(awk '/^android \{/{active=1}
    active && /^[[:space:]]+defaultConfig \{/{exit}
    active && /^[[:space:]]+ndkVersion[[:space:]]*=/{print $3}' "$GRADLE_BUILD")"
[[ "$app_ndk_pin" = "\"$NDK_PIN\"" ]] || fail "app NDK pin must precede its first defaultConfig"
[[ "$(grep -Ec '^[[:space:]]*ndkVersion[[:space:]]*=' "$GRADLE_BUILD")" -eq 1 ]] \
    || fail "app must declare exactly one NDK pin"
ok "app declares one pinned NDK before native variant configuration"
require_grep "mpv seam uses the same pinned NDK" \
    "^[[:space:]]+ndkVersion = \"${NDK_PIN//./\\.}\"$" "$MPV_SEAM_BUILD"
for wf in "$ANDROID_CI_WF" "$RELEASE_WF" "$VALIDATION_WF" "$CODEQL_WF"; do
    require_grep "$(basename "$wf") installs the pinned native toolchain" \
        "sdkmanager \"ndk;${NDK_PIN//./\\.}\"" "$wf"
done

# --- Contract 1 (REL-02): artifacts are labeled by their real dimensions -------------------------

require_grep "staging emits the full-mpv universal APK name" \
    'dist/VortX-\$\{version\}-full-mpv-universal\.apk' "$RELEASE_WF"
require_grep "staging emits the play-media3 universal APK name" \
    'dist/VortX-\$\{version\}-play-media3-universal\.apk' "$RELEASE_WF"
require_grep "staging emits the play-media3 AAB name" \
    'dist/VortX-\$\{version\}-play-media3\.aab' "$RELEASE_WF"

for stale in '-phone\.apk' '-tv\.apk'; do
    if grep -rqE -e "$stale" "$REPO_ROOT/.github/workflows"; then
        fail "misleading device-class artifact label '$stale' still referenced under .github/workflows"
    fi
done
ok "no phone/tv artifact labels remain under .github/workflows"

require_grep "release binds Android version to all packaged manifests" \
    'bash scripts/verify-android-release-version.sh' "$RELEASE_WF"
require_grep "AAB metadata inspector is digest-pinned" \
    'a099cfa1543f55593bc2ed16a70a7c67fe54b1747bb7301f37fdfd6d91028e29.*sha256sum --check' "$RELEASE_WF"
require_grep "version evidence inspects protobuf AAB version code" \
    'xpath=.*/manifest/@android:versionCode' "$VERSION_CHECK"
require_grep "version evidence requires two APKs and one AAB" \
    'apk_count.*= 2.*bundle_count.*= 1' "$VERSION_CHECK"
require_grep "secretless packaging runs version evidence fixtures" \
    'python3 scripts/tests/test_android_release_version.py' "$VALIDATION_WF"

require_grep "SHA256SUMS covers the full-mpv universal APK" \
    'full-mpv-universal\.apk' "$RELEASE_WF"
require_grep "release notes explain engine/distribution naming" \
    'named by engine and distribution' "$RELEASE_WF"

[[ -f "$ARTIFACTS_DOC" ]] || fail "docs/RELEASE-ARTIFACTS.md is missing"
require_grep "docs define the full-mpv dimension" 'full-mpv' "$ARTIFACTS_DOC"
require_grep "docs define the play-media3 dimension" 'play-media3' "$ARTIFACTS_DOC"
require_grep "docs define the universal ABI dimension" 'universal' "$ARTIFACTS_DOC"
require_grep "docs state both variants carry phone and Android TV UI" \
    'contain the phone AND the Android TV activities' "$ARTIFACTS_DOC"
require_grep "docs map the old misleading names to canonical ones" \
    'VortX-x\.y\.z-phone\.apk' "$ARTIFACTS_DOC"
require_grep "gradle still declares the distribution flavor dimension" \
    'flavorDimensions \+= "distribution"' "$GRADLE_BUILD"

# The universal label is only honest when every native producer and verifier carries the same ABI
# set. In particular, armeabi-v7a must never be enabled at packaging level without the VortX engine,
# the source-built libmpv seam, CI rust-std installation, and artifact inspection following it.
require_grep "root Gradle contract includes the 32-bit Fire TV ABI" \
    'vortxAndroidAbis.*arm64-v8a.*armeabi-v7a.*x86_64' "$ROOT_GRADLE_BUILD"
require_grep "app ABI filter consumes the shared native ABI contract" \
    'abiFilters \+= androidAbis' "$GRADLE_BUILD"
require_grep "mpv seam ABI filter consumes the shared native ABI contract" \
    'abiFilters \+= androidAbis' "$MPV_SEAM_BUILD"
for wf in "$ANDROID_CI_WF" "$RELEASE_WF"; do
    require_grep "$(basename "$wf") installs the armv7 Rust target" \
        'targets: aarch64-linux-android,armv7-linux-androideabi,x86_64-linux-android' "$wf"
    require_grep "$(basename "$wf") invokes the shared native-only artifact verifier" \
        'verify-native-android-artifacts\.sh' "$wf"
done
for abi in arm64-v8a armeabi-v7a x86_64; do
    require_grep "native-only verifier explicitly requires $abi" "$abi/libvortx_ffi\.so" \
        "$REPO_ROOT/scripts/verify-native-android-artifacts.sh"
done
for method in nativeResourceHostAbiVersion nativeResourceHostNew nativeResourceHostLoadJson nativeResourceHostFree; do
    require_grep "native-only engine ABI gate checks $method" "$method" \
        "$REPO_ROOT/scripts/verify-native-engine-abi.sh"
done
require_grep "native-only verifier rejects non-little-endian engines" 'Data:.*little endian' \
    "$REPO_ROOT/scripts/verify-native-android-artifacts.sh"
require_grep "native-only verifier rejects non-shared-object engines" 'Type:.*DYN' \
    "$REPO_ROOT/scripts/verify-native-android-artifacts.sh"
# Keep the original executable JNI predicate negatives after moving the workflow's inline
# checker into shared helpers. A text match or archive path can never replace callable exports.
for helper in "$REPO_ROOT/scripts/verify-native-android-artifacts.sh" "$REPO_ROOT/scripts/verify-native-engine-abi.sh"; do
    symbol_predicate="$(sed -n "s/.*awk -v wanted=.* '\\(.*\\)' <<<.*/\\1/p" "$helper" | awk 'NR == 1 { print }')"
    [[ -n "$symbol_predicate" ]] || fail "$(basename "$helper") callable JNI predicate missing"
    valid_symbol='1: 0000000000000100 64 FUNC GLOBAL DEFAULT 12 nativeResourceHostNew'
    awk -v wanted=nativeResourceHostNew "$symbol_predicate" <<<"$valid_symbol" \
        || fail "$(basename "$helper") rejects a defined visible JNI function"
    for invalid_symbol in \
        '1: 0000000000000000 0 FUNC GLOBAL DEFAULT UND nativeResourceHostNew' \
        '1: 0000000000000100 64 FUNC LOCAL DEFAULT 12 nativeResourceHostNew' \
        '1: 0000000000000100 64 FUNC GLOBAL HIDDEN 12 nativeResourceHostNew' \
        '1: 0000000000000100 64 OBJECT GLOBAL DEFAULT 12 nativeResourceHostNew'; do
        if awk -v wanted=nativeResourceHostNew "$symbol_predicate" <<<"$invalid_symbol"; then
            fail "$(basename "$helper") accepts a non-callable JNI entry"
        fi
    done
    ok "$(basename "$helper") JNI predicate rejects undefined/local/hidden/object symbols"
done
require_grep "release verifies engines inside the Play AAB as well as both APKs" \
    '\*\.aab\) prefix=base/lib' "$REPO_ROOT/scripts/verify-native-android-artifacts.sh"
require_grep "candidate verifies exactly one Full and one Play APK" \
    '\$\{#full_apks\[@\]\} -ne 1.*\$\{#play_apks\[@\]\} -ne 1' "$ANDROID_CI_WF"
require_grep "secretless packaging proves libmpv for all three shipped ABIs" \
    'for abi in arm64-v8a armeabi-v7a x86_64' "$VALIDATION_WF"
require_grep "release docs name all three universal APK ABIs" \
    'arm64-v8a.*, `armeabi-v7a`.*, and `x86_64`' "$ARTIFACTS_DOC"

# --- Contract 2: event/ref binding ----------------------------------------------------------------

require_grep "release checkout is bound to the requested tag input" \
    'ref: \$\{\{ inputs\.release_tag \}\}' "$RELEASE_WF"
require_grep "release tag must pass git check-ref-format" 'git check-ref-format' "$RELEASE_WF"
ref_line="$(awk '/ref: \$\{\{ inputs.release_tag \}\}/{ print NR; exit }' "$RELEASE_WF")"
tag_gate_line="$(awk '/source_commit" != "\$tag_commit/{ print NR; exit }' "$RELEASE_WF")"
build_line="$(awk '/gradlew :app:assembleFullRelease/{ print NR; exit }' "$RELEASE_WF")"
[[ -n "$ref_line" && -n "$tag_gate_line" && "$ref_line" -lt "$tag_gate_line" ]] \
    || fail "tag binding does not precede the commit-equality gate"
[[ -n "$tag_gate_line" && -n "$build_line" && "$tag_gate_line" -lt "$build_line" ]] \
    || fail "commit-equality gate does not precede the release build"
ok "checkout binds the tag, verifies ref format and commit equality, then builds"

require_absent "privileged android-release workflow has no pull_request trigger" \
    'pull_request' <(trigger_block "$RELEASE_WF")
require_absent "privileged android CI workflow has no pull_request trigger" \
    'pull_request' <(trigger_block "$ANDROID_CI_WF")
require_absent "privileged Apple release workflow has no pull_request trigger" \
    'pull_request' <(trigger_block "$APPLE_RELEASE_WF")

# The Apple coordinator keeps the full tag in Apple asset URLs, but Android artifact names are
# keyed by Android's numeric versionName. The production Android-asset gate must remove only a
# prerelease suffix before it checks those names; otherwise a beta tag asks for impossible
# VortX-x.y.z-beta.N-*.apk files even though Android stages VortX-x.y.z-*.apk.
require_grep "Apple Android-asset gate first removes the v prefix" \
    '^[[:space:]]*VERSION="\$\{TAG#v\}"$' "$APPLE_RELEASE_WF"
require_grep "Apple Android-asset gate removes a prerelease suffix before Android lookup" \
    '^[[:space:]]*VERSION="\$\{VERSION%%-\*\}"$' "$APPLE_RELEASE_WF"

android_asset_version_from_production_gate() {
    local tag="$1" version
    # Keep this exactly equal to the two normalization assignments above. The grep assertions bind
    # the executable examples below to the production workflow rather than a separately invented
    # release-tag parser.
    VERSION="${tag#v}"
    VERSION="${VERSION%%-*}"
    version="$VERSION"
    printf '%s\n' "$version"
}

[[ "$(android_asset_version_from_production_gate 'v0.4.0')" = '0.4.0' ]] \
    || fail "stable tag does not map to Android numeric artifact version"
[[ "$(android_asset_version_from_production_gate 'v0.4.0-beta.1')" = '0.4.0' ]] \
    || fail "beta tag does not map to Android numeric artifact version"
ok "Apple Android-asset gate maps stable and beta tags to Android numeric artifact names"

validation_triggers="$(trigger_block "$VALIDATION_WF")"
grep -Eq '^\s+pull_request:' <<<"$validation_triggers" \
    || fail "validation workflow does not run on pull requests"
ok "secretless validation runs on every pull request"

# --- Contract 3 (REL-03): mandatory secretless validation exercises packaging ---------------------

if grep -q '\${{ secrets\.' "$VALIDATION_WF"; then
    fail "secretless validation workflow references secrets"
fi
ok "validation workflow references zero secrets"
for forbidden in 'ENGINE_REPO_TOKEN' 'TRAKT_CLIENT' 'SIMKL_CLIENT' 'VortXTV/stremiox-core' 'VortXTV/vortx-core'; do
    if grep -qF "$forbidden" "$VALIDATION_WF"; then
        fail "secretless validation workflow references '$forbidden'"
    fi
done
ok "validation workflow touches no private-repo token or sync credentials"

require_grep "validation builds the full release variant" 'assembleFullRelease' "$VALIDATION_WF"
require_grep "validation builds the play release variant" 'assemblePlayRelease' "$VALIDATION_WF"
require_grep "validation bundles the play AAB" 'bundlePlayRelease' "$VALIDATION_WF"
require_grep "validation requires APK Signature Scheme v2" \
    'Verified using v2 scheme \(APK Signature Scheme v2\): true' "$VALIDATION_WF"
require_grep "validation derives APK identity from a PEM certificate" \
    'print-certs-pem' "$VALIDATION_WF"
require_grep "validation requires exactly one APK PEM signer certificate" \
    'exactly one PEM signer certificate' "$VALIDATION_WF"
require_grep "validation rejects Android Debug certificates" 'Android Debug' "$VALIDATION_WF"
require_grep "validation uses strict jarsigner verification on the AAB" \
    'jarsigner" -verify -strict' "$VALIDATION_WF"
require_grep "validation runs signer parsing and strict-verification fixtures" \
    'bash scripts/test-android-release-signing\.sh' "$VALIDATION_WF"
adhoc_fp_parser="$(awk '/expected_fp=/{active=1} active{print} active && /head -n1/{exit}' "$VALIDATION_WF")"
grep -Fq "sed -n 's/^[[:space:]]*SHA256:[[:space:]]*//p'" <<<"$adhoc_fp_parser" \
    || fail "validation ephemeral-keystore fingerprint parser ignores indented SHA256 lines"
ok "validation ephemeral-keystore fingerprint parser admits real keytool indentation"
adhoc_bundle_verification="$(awk '/jarsigner_out=/{active=1} active{print}
    active && /bundle.*2>\&1/{exit}' "$VALIDATION_WF")"
require_grep "validation binds strict self-signed verification to the generated keystore" \
    '-keystore "\$RUNNER_TEMP/adhoc-signing/adhoc-release\.jks"' \
    <(printf '%s\n' "$adhoc_bundle_verification")
require_grep "validation enforces the GPL boundary on the play flavor" \
    'GPL native library found in play release APK' "$VALIDATION_WF"
require_grep "validation generates an explicitly non-debug ad-hoc identity" \
    'CN=VortX CI Ad-hoc Release' "$VALIDATION_WF"
require_grep "validation shreds the ephemeral keystore" 'Shred ephemeral ad-hoc keystore' "$VALIDATION_WF"
require_grep "candidate CI invokes the shared pinned signer verifier" \
    'scripts/verify-android-release-signing\.sh verify' "$ANDROID_CI_WF"
require_grep "validation exercises the release-feed script contract" \
    'node scripts/tests/release-feed\.test\.mjs' "$VALIDATION_WF"
require_grep "validation exercises the AltStore source generator contract" \
    'python3 scripts/tests/test_gen_altstore_source\.py' "$VALIDATION_WF"
require_grep "validation exercises the IPA repackaging contract" \
    'bash scripts/tests/repackage-ipa\.test\.sh' "$VALIDATION_WF"

# --- Contract 3b: Apple shell packaging exercises real compile/link/package -----------------------
# The secretless lane must go beyond script fixtures: it must generate the Xcode project, build
# every native platform shell (tvOS, iOS, macOS), and verify each produced .app carries the
# expected bundle ID and a Mach-O executable with resolved engine symbols. This is what proves
# the packaging pipeline works end-to-end without private source.

require_grep "validation installs pinned XcodeGen" \
    'xcodegen.*--version' "$VALIDATION_WF"
require_grep "validation generates CI-only stub engine xcframeworks" \
    'build-stub-engine-xcframeworks\.sh' "$VALIDATION_WF"
require_grep "validation verifies StremioXCore stub marker" \
    'StremioXCore\.xcframework/STUB-CI-ONLY\.txt' "$VALIDATION_WF"
require_grep "validation verifies VortxEngine stub marker" \
    'VortxEngine\.xcframework/STUB-CI-ONLY\.txt' "$VALIDATION_WF"
require_grep "validation proves the supported Full tvOS arm64 simulator link" \
    'dd-tv".*both arm64' "$VALIDATION_WF"
require_grep "validation proves the Lite x86_64 tvOS simulator link" \
    'dd-tvlite-x86.*core-only x86_64' "$VALIDATION_WF"
require_grep "stub engine preserves the real nested module map destination" \
    'header_dir="\$header_dir/vortx"' "$REPO_ROOT/scripts/build-stub-engine-xcframeworks.sh"
require_grep "stub frameworks provide a universal simulator slice" \
    'tvos-arm64_x86_64-simulator.*x86_64-apple-tvos' "$REPO_ROOT/scripts/build-stub-engine-xcframeworks.sh"
require_grep "stub framework plist declares x86_64 simulator support" \
    'architectures.*x86_64' "$REPO_ROOT/scripts/build-stub-engine-xcframeworks.sh"
require_grep "validation uses one supported PKCS12 password for store and key" \
    'ADHOC_KEY_PASS: vortx-adhoc-ci-store' "$VALIDATION_WF"
require_grep "validation generates the Xcode project from project.yml" \
    'xcodegen generate' "$VALIDATION_WF"
require_grep "validation builds tvOS shell via xcodebuild" \
    'build_shell VortXTV ' "$VALIDATION_WF"
require_grep "validation builds tvOS Lite shell via xcodebuild" \
    'build_shell VortXTVLite' "$VALIDATION_WF"
require_grep "validation builds iOS native shell via xcodebuild" \
    'build_shell VortXiOSNative' "$VALIDATION_WF"
require_grep "validation builds macOS shell via xcodebuild" \
    'build_shell VortXMac' "$VALIDATION_WF"
require_grep "validation disables code signing for secretless builds" \
    'CODE_SIGNING_ALLOWED=NO' "$VALIDATION_WF"
require_grep "validation verifies bundle IDs of produced apps" \
    'CFBundleIdentifier' "$VALIDATION_WF"
require_grep "validation reads the macOS nested bundle plist" \
    'info_plist="\$products_dir/Contents/Info.plist"' "$VALIDATION_WF"
require_grep "validation inspects the macOS nested executable directory" \
    'executable_dir="\$products_dir/Contents/MacOS"' "$VALIDATION_WF"
require_grep "validation reads bundle metadata from the selected plist" \
    'CFBundleExecutable.*"\$info_plist"' "$VALIDATION_WF"
require_grep "validation resolves engine symbols from the selected executable" \
    'nm -gU "\$executable_dir/\$exe"' "$VALIDATION_WF"
require_grep "validation verifies Mach-O executables in produced apps" \
    'Mach-O' "$VALIDATION_WF"
require_grep "validation verifies linked engine symbols are resolved" \
    '_stremiox_core_schema_version' "$VALIDATION_WF"
require_grep "validation checks for unresolved engine symbols" \
    'unresolved engine symbols' "$VALIDATION_WF"

# --- Contract 3c: CI-only stub isolation (stubs never enter protected release lanes) ---------------
# The stub engine xcframeworks exist ONLY for the secretless PR lane. Protected workflows
# (android-release.yml, release-tvos.yml, android.yml) must NEVER reference the stub script or
# its marker file, because that would mean a release could ship with no-op engine stand-ins.

readonly STUB_SCRIPT="$REPO_ROOT/scripts/build-stub-engine-xcframeworks.sh"
[[ -f "$STUB_SCRIPT" ]] || fail "stub engine script missing: $STUB_SCRIPT"
for wf in "$RELEASE_WF" "$APPLE_RELEASE_WF" "$ANDROID_CI_WF"; do
    require_absent "protected $(basename "$wf") never references the stub engine script" \
        'build-stub-engine-xcframeworks' "$wf"
    require_absent "protected $(basename "$wf") never references the STUB-CI-ONLY marker" \
        'STUB-CI-ONLY' "$wf"
done
ok "stub engine artifacts are isolated to the secretless validation lane"

# --- Contract 3d: android.yml release signing-variable mapping ------------------------------------
# The Gradle signing config reads exactly four env vars (build.gradle.kts:38-43). The workflow
# must export all four under the correct names, and must never carry the old misnamed variable
# VORTX_KEYSTORE_FILE (which silently missed the Gradle contract before it was caught).

require_grep "android CI exports VORTX_KEYSTORE_PATH (not KEYSTORE_FILE)" \
    'VORTX_KEYSTORE_PATH:' "$ANDROID_CI_WF"
# The misnamed VORTX_KEYSTORE_FILE must never appear as an env-var export (indented key: value).
# Mentions inside assertion scripts or comments are acceptable (the inline contract test itself
# references the name to verify its absence); only an actual env binding is a regression.
if grep -Eq '^[[:space:]]+VORTX_KEYSTORE_FILE:' "$ANDROID_CI_WF"; then
    fail "android CI exports the misnamed VORTX_KEYSTORE_FILE as an env var (must be VORTX_KEYSTORE_PATH)"
fi
ok "android CI never exports the misnamed VORTX_KEYSTORE_FILE as an env var"
require_grep "android CI asserts the release signing-variable mapping inline" \
    'Assert release signing-variable mapping' "$ANDROID_CI_WF"
for var in VORTX_KEYSTORE_PATH VORTX_KEYSTORE_PASSWORD VORTX_KEY_ALIAS VORTX_KEY_PASSWORD; do
    require_grep "android CI signing-variable mapping assertion checks $var" \
        "$var" "$ANDROID_CI_WF"
done

# Execute the assertion embedded in android.yml itself against disposable fixtures. This catches
# self-scans: a forbidden value mentioned by the assertion must not make the clean workflow fail,
# while an actual YAML signing key or Gradle signing-input map drift must fail closed.
assertion_script="$(mktemp)"
trap 'rm -f "$assertion_script"' EXIT
awk '
    /^      - name: Assert release signing-variable mapping \(exact four canonical vars\)$/ { in_step=1; next }
    in_step && /^        run: \|$/ { in_script=1; next }
    in_script && /^      - name:/ { exit }
    in_script { sub(/^          /, ""); print }
' "$ANDROID_CI_WF" > "$assertion_script"
[[ -s "$assertion_script" ]] || fail "could not extract android CI signing-contract assertion"

run_signing_assertion_fixture() {
    local fixture="$1"
    mkdir -p "$fixture/.github/workflows" "$fixture/android/app"
    cp "$ANDROID_CI_WF" "$fixture/.github/workflows/android.yml"
    cp "$GRADLE_BUILD" "$fixture/android/app/build.gradle.kts"
    (cd "$fixture" && bash "$assertion_script")
}

fixture_root="$(mktemp -d)"
trap 'rm -rf "$fixture_root"; rm -f "$assertion_script"' EXIT
run_signing_assertion_fixture "$fixture_root/clean" >/dev/null
ok "android CI signing-variable mapping assertion accepts the real workflow and Gradle configuration"

run_signing_assertion_fixture "$fixture_root/misnamed-env" >/dev/null
perl -0pi -e 's/(          VORTX_KEYSTORE_PATH:.*\n)/$1          VORTX_KEYSTORE_FILE: injected-test-value\n/' \
    "$fixture_root/misnamed-env/.github/workflows/android.yml"
if (cd "$fixture_root/misnamed-env" && bash "$assertion_script") >/dev/null 2>&1; then
    fail "android CI signing-variable mapping assertion accepted a misnamed keystore env key"
fi
ok "android CI signing-variable mapping assertion rejects a misnamed keystore env key"

run_signing_assertion_fixture "$fixture_root/missing-env" >/dev/null
perl -0pi -e 's/^          VORTX_KEY_PASSWORD:.*\n//m' \
    "$fixture_root/missing-env/.github/workflows/android.yml"
if (cd "$fixture_root/missing-env" && bash "$assertion_script") >/dev/null 2>&1; then
    fail "android CI signing-variable mapping assertion accepted a missing env key"
fi
ok "android CI signing-variable mapping assertion rejects a missing env key"

run_signing_assertion_fixture "$fixture_root/extra-env" >/dev/null
perl -0pi -e 's/(          VORTX_KEY_PASSWORD:.*\n)/$1          VORTX_KEY_EXTRA: injected-test-value\n/' \
    "$fixture_root/extra-env/.github/workflows/android.yml"
if (cd "$fixture_root/extra-env" && bash "$assertion_script") >/dev/null 2>&1; then
    fail "android CI signing-variable mapping assertion accepted an extra env key"
fi
ok "android CI signing-variable mapping assertion rejects an extra env key"

run_signing_assertion_fixture "$fixture_root/digit-env" >/dev/null
perl -0pi -e 's/(          VORTX_KEY_PASSWORD:.*\n)/$1          VORTX_KEY2_EXTRA: injected-test-value\n/' \
    "$fixture_root/digit-env/.github/workflows/android.yml"
if (cd "$fixture_root/digit-env" && bash "$assertion_script") >/dev/null 2>&1; then
    fail "android CI signing-variable mapping assertion accepted a digit-bearing extra env key"
fi
ok "android CI signing-variable mapping assertion rejects a digit-bearing extra env key"

run_signing_assertion_fixture "$fixture_root/extra-signing-input" >/dev/null
perl -0pi -e 's/(    "VORTX_KEY_PASSWORD" to signingSecret\("VORTX_KEY_PASSWORD"\),\n)/$1    "VORTX_EXTRA_SIGNING_INPUT" to\n        signingSecret("VORTX_EXTRA_SIGNING_INPUT"),\n/' \
    "$fixture_root/extra-signing-input/android/app/build.gradle.kts"
if (cd "$fixture_root/extra-signing-input" && bash "$assertion_script") >/dev/null 2>&1; then
    fail "android CI signing-variable mapping assertion accepted a fifth signing input"
fi
ok "android CI signing-variable mapping assertion rejects a fifth signing input"

run_signing_assertion_fixture "$fixture_root/missing-signing-input" >/dev/null
perl -0pi -e 's/^    "VORTX_KEY_PASSWORD" to signingSecret\("VORTX_KEY_PASSWORD"\),\n//m' \
    "$fixture_root/missing-signing-input/android/app/build.gradle.kts"
if (cd "$fixture_root/missing-signing-input" && bash "$assertion_script") >/dev/null 2>&1; then
    fail "android CI signing-variable mapping assertion accepted a missing signing input"
fi
ok "android CI signing-variable mapping assertion rejects a missing signing input"

run_signing_assertion_fixture "$fixture_root/whitespace-only-signing-input" >/dev/null
perl -0pi -e 's/(    "VORTX_KEYSTORE_PATH") to (signingSecret\("VORTX_KEYSTORE_PATH"\),)/$1\n        to\n        $2/' \
    "$fixture_root/whitespace-only-signing-input/android/app/build.gradle.kts"
(cd "$fixture_root/whitespace-only-signing-input" && bash "$assertion_script") >/dev/null \
    || fail "android CI signing-variable mapping assertion rejected harmless Gradle map whitespace"
ok "android CI signing-variable mapping assertion accepts harmless Gradle map whitespace"

permissions_block="$(awk '/^permissions:/{flag=1} flag && /^[a-zA-Z_-]+:/ && !/^permissions:/{exit} flag{print}' "$VALIDATION_WF")"
grep -Eq 'contents:\s*read' <<<"$permissions_block" \
    || fail "validation workflow must hold contents: read only"
ok "validation workflow holds contents: read only"

# --- Contract 4: no debug-signing fallback anywhere in the release path ---------------------------

for wf in "$RELEASE_WF" "$ANDROID_CI_WF" "$APPLE_RELEASE_WF" "$VALIDATION_WF"; do
    # The string "debug-signed" may appear inside an inline contract-assertion step (a grep that
    # CHECKS for the marker). Only a USE of the marker outside such an assertion is a regression.
    # A line containing 'debug-signed' that also contains 'grep' or '#' is part of an assertion,
    # not an actual fallback.
    if grep -E 'debug-signed' "$wf" | grep -vEq 'grep|#'; then
        fail "debug-signed fallback marker found outside assertion logic in $(basename "$wf")"
    fi
    ok "no debug-signed fallback marker in $(basename "$wf")"
done
require_absent "gradle never selects the debug signing config for release" \
    'signingConfigs\.getByName\("debug"\)' "$GRADLE_BUILD"
require_grep "gradle fails configuration when release signing inputs are absent" \
    'Release signing inputs are required' "$GRADLE_BUILD"
require_grep "release preflight gate exists before build" \
    'Preflight release signing inputs \(fail closed\)' "$RELEASE_WF"
preflight_line="$(awk '/Preflight release signing inputs/{ print NR; exit }' "$RELEASE_WF")"
verify_line="$(awk '/Verify pinned production signer/{ print NR; exit }' "$RELEASE_WF")"
upload_line="$(awk '/gh release upload/{ print NR; exit }' "$RELEASE_WF")"
[[ -n "$preflight_line" && -n "$build_line" && "$preflight_line" -lt "$build_line" ]] \
    || fail "signing preflight is not before the release build"
[[ -n "$verify_line" && -n "$upload_line" && "$verify_line" -lt "$upload_line" ]] \
    || fail "signer verification is not before release upload"
ok "preflight precedes build and pinned signer verification precedes upload"

# --- Contract 5: release feed artifact validation (t22) ------------------------------------------
# The release-feed.mjs must export validateReleaseFeedArtifact with split Android validation,
# client-compatible caps, tag/versionName coherence, and flat-root rejection.

readonly FEED_SCRIPT="$REPO_ROOT/scripts/release-feed.mjs"
readonly FEED_TEST="$REPO_ROOT/scripts/tests/release-feed.test.mjs"
[[ -f "$FEED_SCRIPT" ]] || fail "release-feed.mjs missing: $FEED_SCRIPT"
[[ -f "$FEED_TEST" ]] || fail "release-feed test missing: $FEED_TEST"

require_grep "release-feed exports validateReleaseFeedArtifact" \
    'export function validateReleaseFeedArtifact' "$FEED_SCRIPT"
require_grep "release-feed exports FEED_CAPS" \
    'export const FEED_CAPS' "$FEED_SCRIPT"
require_grep "release-feed enforces schemaVersion exactly 2" \
    'schemaVersion must be exactly|schemaVersion.*FEED_ARTIFACT_SCHEMA' "$FEED_SCRIPT"
require_grep "release-feed validates split android.full" \
    'android\.full|validateAndroidFlavorEntry.*full|VALID_ANDROID_FLAVORS' "$FEED_SCRIPT"
require_grep "release-feed validates split android.play" \
    'android\.play|validateAndroidFlavorEntry.*play' "$FEED_SCRIPT"
require_grep "release-feed rejects flat root.android metadata" \
    'flat root\.android|split flavor entries' "$FEED_SCRIPT"
require_grep "release-feed enforces manifest size cap (512 KiB)" \
    'manifestBytes.*512|512.*1024' "$FEED_SCRIPT"
require_grep "release-feed enforces artifact size cap (1 GiB)" \
    'artifactBytes.*1024.*1024.*1024|1.*GiB' "$FEED_SCRIPT"
require_grep "release-feed enforces version length cap (64)" \
    'versionLength.*64' "$FEED_SCRIPT"
require_grep "release-feed enforces name length cap (200)" \
    'nameLength.*200' "$FEED_SCRIPT"
require_grep "release-feed enforces notes length cap (20000)" \
    'notesLength.*20.000|notesLength.*20000' "$FEED_SCRIPT"
require_grep "release-feed requires lower-case 64-hex SHA-256" \
    'lower-case 64-character hex|\[0-9a-f\]\{64\}' "$FEED_SCRIPT"
require_grep "release-feed requires HTTPS artifact URL" \
    'HTTPS URL|https://' "$FEED_SCRIPT"
require_grep "release-feed requires compact pinned signer" \
    'signer.*compact|signer is too long' "$FEED_SCRIPT"
require_grep "release-feed asserts tag version equals Android versionName" \
    'tag version|tag-derived version|tagVersion' "$FEED_SCRIPT"
require_grep "release-feed requires exact applicationId" \
    'applicationId.*com\.vortx\.android|ANDROID_APPLICATION_ID' "$FEED_SCRIPT"
require_grep "release-feed requires engine field per flavor" \
    'engine.*mpv|engine.*media3' "$FEED_SCRIPT"
require_grep "release-feed requires an exact declared flavor per entry" \
    'entry\.flavor !== flavor' "$FEED_SCRIPT"
require_grep "release-feed requires artifactType field" \
    'artifactType.*apk|VALID_ANDROID_ARTIFACT_TYPES' "$FEED_SCRIPT"
require_grep "release-feed exposes validate-android-feed CLI command" \
    'validate-android-feed' "$FEED_SCRIPT"

# Test coverage for the new validation function
require_grep "test covers positive full+play Android fixture" \
    'full+play Android|full.*VALID_ANDROID_FULL.*play.*VALID_ANDROID_PLAY' "$FEED_TEST"
require_grep "test covers Apple+Android combined fixture" \
    'Apple.*Android|hasApple.*true' "$FEED_TEST"
require_grep "test covers Android-only fixture" \
    'Android-only|hasApple.*false' "$FEED_TEST"
require_grep "test covers flat root.android rejection" \
    'flat root\.android|split flavor entries' "$FEED_TEST"
require_grep "test covers schemaVersion rejection" \
    'wrong schemaVersion|schemaVersion must be exactly 2' "$FEED_TEST"
require_grep "test covers client cap enforcement" \
    'exceeding.*cap|exceeds.*characters|exceeds maximum' "$FEED_TEST"
require_grep "test covers lower-case SHA-256 enforcement" \
    'upper-case SHA-256|lower-case 64-character' "$FEED_TEST"
require_grep "test covers tag/versionName coherence" \
    'version mismatch with tag|tag version' "$FEED_TEST"

# --- Contract 6: every workflow-driven publication reaches a read-only verifier ------------------
# A release published by GITHUB_TOKEN does not emit a recursive release event. The verifier must
# therefore be a downstream job in the same dispatch run, keyed by the immutable release ID emitted
# by attach-release. Keep the external release-event path too, but neither verifier path may receive
# write authority or execute repository-controlled code.

verify_published_block="$(awk '
    /^  verify-published:$/ { in_job=1 }
    in_job { print }
' "$APPLE_RELEASE_WF")"
[[ -n "$verify_published_block" ]] || fail "Apple published-release verifier job is missing"

grep -Fq 'needs: [attach-release]' <<<"$verify_published_block" \
    || fail "published-release verifier does not depend on attach-release"
ok "published-release verifier depends on attach-release"
grep -Fq 'always()' <<<"$verify_published_block" \
    || fail "published-release verifier can silently skip after an eligible dispatch publication"
grep -Fq "github.event_name == 'workflow_dispatch'" <<<"$verify_published_block" \
    || fail "published-release verifier has no workflow-dispatch path"
grep -Fq 'inputs.publish_release == true' <<<"$verify_published_block" \
    || fail "published-release verifier is not gated on actual publication"
grep -Fq "needs.attach-release.result == 'success'" <<<"$verify_published_block" \
    || fail "published-release verifier does not require successful publication"
ok "workflow-driven publication always reaches the downstream verifier after successful attachment"
grep -Fq "github.event_name == 'release'" <<<"$verify_published_block" \
    || fail "published-release verifier no longer accepts external published-release events"
ok "external published-release events retain independent verification"
grep -Fq "!startsWith(github.event.release.tag_name, 'vendor-')" <<<"$verify_published_block" \
    || fail "dependency-only vendor release events must not enter app/feed verification"
VERIFY_PUBLISHED_BLOCK="$verify_published_block" node --input-type=module <<'NODE'
import assert from 'node:assert/strict';
const block = process.env.VERIFY_PUBLISHED_BLOCK;
const expression = block.match(/^    if: >-\n([\s\S]*?)^    concurrency:/m)?.[1];
assert.ok(expression, 'published-release job must have its own condition');
// GitHub expressions accept hyphenated properties; use equivalent JS bracket access.
const jsExpression = expression.replaceAll('needs.attach-release', "needs['attach-release']");
const evaluate = new Function('github', 'inputs', 'needs', 'always', 'startsWith', `return (${jsExpression});`);
const eligible = (event, tag, publish = false, result = 'skipped') => evaluate(
  {event_name: event, event: {release: {tag_name: tag}}}, {publish_release: publish},
  {'attach-release': {result}}, () => true,
  (value, prefix) => String(value).toLowerCase().startsWith(String(prefix).toLowerCase()),
);
for (const tag of ['v0.5.0', 'v0.5.0-beta.1', 'v0.5.0-vendor-test', 'other-release']) {
  assert.equal(eligible('release', tag), true, `${tag}: retain external app verification`);
}
for (const tag of ['vendor-mpvkit-dvfel-2', 'vendor-fonts-1', 'VENDOR-nodemobile-1']) {
  assert.equal(eligible('release', tag), false, `${tag}: dependency-only event`);
}
assert.equal(eligible('workflow_dispatch', 'v0.5.0-beta.1', true, 'success'), true);
assert.equal(eligible('workflow_dispatch', 'vendor-mpvkit-dvfel-2', true, 'success'), true,
  'vendor event guard must never suppress a dispatch publication verifier');
for (const result of ['failure', 'cancelled', 'skipped']) {
  assert.equal(eligible('workflow_dispatch', 'v0.5.0-beta.1', true, result), false);
}
assert.equal(eligible('workflow_dispatch', 'v0.5.0-beta.1', false, 'success'), false);
assert.equal(eligible('push', 'v0.5.0-beta.1', true, 'success'), false);
NODE
ok "actual verifier condition isolates vendor events and preserves app/dispatch gates"
require_grep "attach-release exposes immutable release ID to the downstream verifier" \
    'release_id: \$\{\{ steps\.identity\.outputs\.release_id \}\}' "$APPLE_RELEASE_WF"
grep -Fq 'needs.attach-release.outputs.release_id' <<<"$verify_published_block" \
    || fail "downstream verifier does not consume attach-release's immutable release ID"
ok "downstream verifier consumes the immutable release ID"
numeric_release_id_guards="$(grep -Fc 'if [[ "$RELEASE_ID_INPUT" =~ ^[0-9]+$ ]]; then' "$APPLE_RELEASE_WF")"
[[ "$numeric_release_id_guards" -eq 2 ]] \
    || fail "Apple release workflow must validate both supplied draft release IDs as numeric before direct lookup"
ok "Apple release workflow rejects nonnumeric draft release IDs and falls back to tag lookup"
require_grep "Apple coordinator derives prerelease state from the tag" \
    'IS_PRERELEASE=false; \[\[ "\$TAG" == \*-\* \]\] && IS_PRERELEASE=true' "$APPLE_RELEASE_WF"
require_grep "latest beta channel requires the durable exact marker" \
    "LATEST_BETA_MARKER='<!-- vortx-channel: latest-beta -->'" "$APPLE_RELEASE_WF"
require_grep "latest beta channel is restricted to strict beta tags" \
    'latest-beta marker is allowed only on strict beta tags' "$APPLE_RELEASE_WF"
require_grep "feed artifact carries the computed prerelease state" \
    '--prerelease "\$IS_PRERELEASE"' "$APPLE_RELEASE_WF"
require_grep "Android lane refuses partial publication" \
    'Refuse Android-only publication' "$RELEASE_WF"
require_grep "Android checksum lists downloadable basenames" \
    "sed 's#  dist/#  #' > dist/SHA256SUMS-android.txt" "$RELEASE_WF"
require_grep "Apple coordinator exposes an Apple-only dispatch boolean" \
    '^      apple_only:$' "$APPLE_RELEASE_WF"
apple_only_input_block="$(awk '
    /^      apple_only:$/ { capture=1 }
    capture && /^      [A-Za-z_][A-Za-z_]*:$/ && !/^      apple_only:$/ { exit }
    capture { print }
' "$APPLE_RELEASE_WF")"
grep -Eq '^        type: boolean$' <<<"$apple_only_input_block" \
    && grep -Eq '^        default: false$' <<<"$apple_only_input_block" \
    || fail "Apple-only dispatch must be a default-false boolean"
ok "Apple-only dispatch defaults to the full-platform path"
require_grep "Apple-only changelog declares the same platform contract" \
    'vortx-platforms:[[:space:]]*apple' "$CHANGELOG"
apple_only_tag_regexes="$(awk -F"'" '/^[[:space:]]*APPLE_ONLY_TAG_RE=/{ print $2 }' "$APPLE_RELEASE_WF")"
apple_only_marker_regexes="$(awk -F"'" '/^[[:space:]]*APPLE_ONLY_MARKER_RE=/{ print $2 }' "$APPLE_RELEASE_WF")"
[[ "$(sed '/^$/d' <<<"$apple_only_tag_regexes" | wc -l | tr -d ' ')" -eq 2 ]] \
    && [[ "$(sed '/^$/d' <<<"$apple_only_tag_regexes" | sort -u | wc -l | tr -d ' ')" -eq 1 ]] \
    || fail "Apple-only tag regex must be declared identically for dispatch and publication verification"
[[ "$(sed '/^$/d' <<<"$apple_only_marker_regexes" | wc -l | tr -d ' ')" -eq 2 ]] \
    && [[ "$(sed '/^$/d' <<<"$apple_only_marker_regexes" | sort -u | wc -l | tr -d ' ')" -eq 1 ]] \
    || fail "Apple-only marker regex must be declared identically for dispatch and publication verification"
apple_only_tag_re="$(head -n 1 <<<"$apple_only_tag_regexes")"
apple_only_marker_re="$(head -n 1 <<<"$apple_only_marker_regexes")"
for accepted_tag in v0.4.0-beta.2; do
    [[ "$accepted_tag" =~ $apple_only_tag_re ]] || fail "Apple-only beta tag regex rejected $accepted_tag"
done
for rejected_tag in v0.4.0 v0.4.0-rc.1 v0.4.0-alpha.1; do
    [[ ! "$rejected_tag" =~ $apple_only_tag_re ]] || fail "Apple-only beta tag regex accepted $rejected_tag"
done
for valid_marker in 'vortx-platforms: apple' '<!-- vortx-platforms: apple -->'; do
    grep -Eq "$apple_only_marker_re" <<<"$valid_marker" || fail "Apple-only marker regex rejected a valid declaration: $valid_marker"
done
for malformed_marker in '<!-- vortx-platforms: apple' 'vortx-platforms: apple -->'; do
    grep -Eq "$apple_only_marker_re" <<<"$malformed_marker" && fail "Apple-only marker regex accepted malformed declaration: $malformed_marker"
done
ok "Apple-only release mode accepts only beta tags and complete bare or paired markers"
require_grep "Apple-only dispatch is rejected for non-beta tags" \
    'Apple-only publication is allowed only for beta tags' "$APPLE_RELEASE_WF"
require_grep "Apple coordinator keeps the full Android checksum gate" \
    'Android checksum asset is missing' "$APPLE_RELEASE_WF"
require_grep "Apple coordinator skips Android only through its explicit Apple-only branch" \
    'if \[ "\$APPLE_ONLY" != true \]; then' "$APPLE_RELEASE_WF"
require_grep "published verifier derives Apple-only state from the release body" \
    'PLATFORM_APPLE=false' "$APPLE_RELEASE_WF"
require_grep "published verifier reads the release-body platform declaration" \
    'RELEASE_BODY=.*\.body' "$APPLE_RELEASE_WF"
require_grep "published verifier rejects Apple-only declarations on non-beta tags" \
    'Apple-only release declaration is valid only on a beta tag' "$APPLE_RELEASE_WF"
require_grep "published verifier checks the actual Android feed before downloading it" \
    'HAS_ANDROID=false' "$APPLE_RELEASE_WF"
require_grep "published verifier rejects partial Android feeds" \
    'appcast Android feed is partial or malformed' "$APPLE_RELEASE_WF"
require_grep "published verifier retains byte proof for a present inherited Android feed" \
    'if \[ "\$HAS_ANDROID" = true \]; then' "$APPLE_RELEASE_WF"
require_grep "Stable publish sends GitHub's string-valued latest mode" \
    'gh api --method PATCH -f make_latest=true' "$APPLE_RELEASE_WF"
require_grep "Publication sends a typed draft Boolean in a separate request" \
    'gh api --method PATCH -F draft=false' "$APPLE_RELEASE_WF"
require_absent "Publication and Latest must be separate proven transitions" \
    'draft=false.*make_latest=true' "$APPLE_RELEASE_WF"
require_absent "Stable publish must not encode make_latest as a JSON boolean" \
    '[-]F make_latest=true' "$APPLE_RELEASE_WF"
require_absent "numeric release objects must not use the non-existent is_latest field" '\.is_latest' "$APPLE_RELEASE_WF"
latest_identity_checks="$(grep -Fc 'repos/$GH_REPO/releases/latest' "$APPLE_RELEASE_WF")"
[[ "$latest_identity_checks" -eq 3 ]] || fail "stable publication, readiness, and verifier must each query /releases/latest"
ok "stable release identity uses the separate latest-release endpoint in every verifier"
require_grep "staged publication does not byte-compare the dynamic appcast worker" \
    'combined Apple\+Android view' "$APPLE_RELEASE_WF"
require_grep "live appcast validation binds to worker tag provenance" \
    '_generatedFromTag == \$tag' "$APPLE_RELEASE_WF"
require_grep "published-release readiness derives prerelease state from event tag" \
    'IS_PRERELEASE=false; \[\[ "\$EVENT_TAG" == \*-\* \]\] && IS_PRERELEASE=true' "$APPLE_RELEASE_WF"

event_tag_prerelease() {
    local event_tag="$1"
    local is_prerelease=false
    [[ "$event_tag" == *-* ]] && is_prerelease=true
    printf '%s\n' "$is_prerelease"
}
[[ "$(event_tag_prerelease v0.3.15)" = false ]] || fail "stable event tag did not derive prerelease=false"
[[ "$(event_tag_prerelease v0.3.14-beta.31)" = true ]] || fail "beta event tag did not derive prerelease=true"
ok "published-release readiness derives stable and beta prerelease bits from the event tag"
[[ -f "$RECOVERY_WF" ]] || fail "published feed recovery workflow is missing"
require_grep "published feed recovery uses protected release approval" 'environment: release-approval' "$RECOVERY_WF"
require_grep "published feed recovery requires immutable source commit" 'source commit must be immutable' "$RECOVERY_WF"
require_grep "published feed recovery verifies release latest identity" 'repos/\$GH_REPO/releases/latest' "$RECOVERY_WF"
require_grep "published feed recovery signs the recover action" 'action:"recover"' "$RECOVERY_WF"
require_grep "published feed recovery binds the signed target source digest" 'targetSourceSha256:\$source' "$RECOVERY_WF"
require_grep "published feed recovery CASes main source bytes" '--arg sha "\$CURRENT_SHA"' "$RECOVERY_WF"
require_grep "published feed recovery marks edge mutation attempted before the POST" 'EDGE_ATTEMPTED=1' "$RECOVERY_WF"
require_grep "published feed recovery marks source mutation attempted before the PUT" 'SOURCE_ATTEMPTED=1' "$RECOVERY_WF"
require_grep "published feed recovery compensates an edge mutation on later failure" 'rollback_edge' "$RECOVERY_WF"
require_grep "published feed recovery compensates a source mutation on later failure" 'rollback_source' "$RECOVERY_WF"
require_grep "published feed recovery traps failure after recovery" 'trap on_failure EXIT' "$RECOVERY_WF"
require_grep "published feed recovery handles ambiguous mutation acknowledgement by readback" 'recovery response was ambiguous' "$RECOVERY_WF"
require_grep "published feed recovery emits an incident for incomplete compensation" 'incident: release recovery compensation was incomplete' "$RECOVERY_WF"
require_absent "published feed recovery must never redraft a public release" 'draft=true|draft: true' "$RECOVERY_WF"
ok "published feed recovery is protected, authenticated, source-CAS-bound, and never redrafts"
[[ -f "$ANDROID_AUGMENT_WF" ]] || fail "Android feed augmentation workflow is missing"
require_grep "Android feed augmentation uses protected release approval" 'environment: release-approval' "$ANDROID_AUGMENT_WF"
require_grep "Android feed augmentation is read-only to repository contents" 'contents: read' "$ANDROID_AUGMENT_WF"
require_grep "Android feed augmentation signs the narrow coordinator action" 'action augment-android' "$ANDROID_AUGMENT_WF"
require_grep "Android feed augmentation binds the active receipt digest" 'expectedReceiptSha256:\$receipt' "$ANDROID_AUGMENT_WF"
require_grep "Android feed augmentation binds source bytes" 'expectedSourceSha256:\$source' "$ANDROID_AUGMENT_WF"
require_grep "Android feed augmentation binds Apple-only appcast bytes" 'expectedAppcastSha256:\$appcast' "$ANDROID_AUGMENT_WF"
require_grep "Android feed augmentation pins the production signer" 'FC22B87ECD9E4FA26930A1C3E227D8F7D918C646B216032B5DA820EF1AC218CA' "$ANDROID_AUGMENT_WF"
require_grep "Android feed augmentation validates release asset digests" '\.digest \| sub\("\^sha256:"' "$ANDROID_AUGMENT_WF"
require_grep "Android feed augmentation preserves Apple appcast entries" "jq -S 'del\(\.android\)'" "$ANDROID_AUGMENT_WF"
require_grep "Android feed augmentation marks mutation attempted before the POST" 'MUTATION_ATTEMPTED=1' "$ANDROID_AUGMENT_WF"
require_grep "Android feed augmentation resolves ambiguous commits through authenticated operation status" 'action:"operation-status"' "$ANDROID_AUGMENT_WF"
require_grep "Android feed augmentation binds predecessor status to its exact receipt" '\.active\.generation == \$generation and \.active\.receiptSha256 == \$receipt' "$ANDROID_AUGMENT_WF"
require_grep "Android feed compensation checks the exact untouched predecessor receipt" 'if status_is_exact_predecessor "\$status"' "$ANDROID_AUGMENT_WF"
require_grep "Android feed rollback readback checks the exact predecessor receipt" 'status_is_exact_predecessor "\$readback"' "$ANDROID_AUGMENT_WF"
require_grep "Android feed augmentation compensates later verification failure" '^          compensate\(\)' "$ANDROID_AUGMENT_WF"
require_grep "Android feed augmentation verifies exact predecessor bytes after compensation" 'cmp -s "\$RUNNER_TEMP/before-appcast.json" "\$RUNNER_TEMP/compensated-appcast.json"' "$ANDROID_AUGMENT_WF"
require_grep "Android feed augmentation hard-fails incomplete compensation" 'incident: Android feed augmentation compensation was incomplete' "$ANDROID_AUGMENT_WF"
mutation_line="$(grep -n 'MUTATION_ATTEMPTED=1' "$ANDROID_AUGMENT_WF" | cut -d: -f1)"
post_line="$(grep -n 'RESPONSE=.*curl --fail-with-body' "$ANDROID_AUGMENT_WF" | head -1 | cut -d: -f1)"
[[ -n "$mutation_line" && -n "$post_line" && "$mutation_line" -lt "$post_line" ]] || fail "Android augmentation must mark mutation attempted before its POST"
ok "Android augmentation marks ambiguous mutation before the network call"
forward_status_line="$(grep -n 'FORWARD_STATUS="\$(operation_status)' "$ANDROID_AUGMENT_WF" | cut -d: -f1)"
public_convergence_line="$(grep -n 'DEADLINE=.*date.*90' "$ANDROID_AUGMENT_WF" | cut -d: -f1)"
[[ -n "$forward_status_line" && -n "$public_convergence_line" && "$forward_status_line" -lt "$public_convergence_line" ]] || fail "forward ambiguity must resolve authenticated operation status before public convergence"
ok "forward ambiguity uses authenticated operation status before public route readback"
require_absent "Android feed augmentation must not check out or mutate repository source" 'actions/checkout|contents: write|gh api --method (PUT|PATCH|DELETE)|gh release (edit|upload|delete)' "$ANDROID_AUGMENT_WF"
ok "Android feed augmentation is protected, authenticated, CAS-bound, rollbackable, and release-read-only"
grep -Eq '^    permissions:$' <<<"$verify_published_block" \
    && grep -Eq '^      contents: read$' <<<"$verify_published_block" \
    || fail "published-release verifier must hold contents: read only"
if grep -Eq 'contents:\s*write|actions/checkout' <<<"$verify_published_block"; then
    fail "published-release verifier has write authority or executes repository code"
fi
ok "published-release verifier has least privilege and runs no repository code"

# --- Full tvOS test lane stays TV-only and cannot publish ------------------------------------------
node - "$APPLE_RELEASE_WF" <<'NODE'
const fs = require('node:fs'), assert = require('node:assert/strict');
const workflow = fs.readFileSync(process.argv[2], 'utf8');
function step(name) {
    const start = workflow.indexOf('      - name: ' + name + '\n');
    assert(start >= 0, name);
    const end = workflow.indexOf('\n      - ', start + 1);
    return workflow.slice(start, end < 0 ? undefined : end);
}
for (const name of ['Build tvOS (Lite)', 'Build iOS', 'Gate iOS-simulator link + dSYM (fail closed)', 'Build macOS', 'Package the IPAs', 'Retain app dSYMs to the private symbols vault (guarded)']) {
    assert(step(name).includes('if: inputs.tvos_test_only != true'), name + ' must be excluded from TV-only tests');
}
for (const name of ['Build tvOS (Full)', 'Smoke-test tvOS launch in a simulator (fail closed)', 'Verify Apple engine artifacts (fail closed)', 'Verify tvOS device artifact metadata (fail closed)', 'Audit bundle symlinks (fail closed)']) {
    assert(!step(name).includes('if: inputs.tvos_test_only'), name + ' must remain enabled');
}
const packaging = step('Package Full tvOS test IPA');
assert(packaging.includes('unzip -tqq out/VortX-tvOS-ci.ipa'));
assert(packaging.includes('shasum -a 256 out/VortX-tvOS-ci.ipa'));
assert(!/hdiutil|VortXTVLite|VortXiOSNative/.test(packaging));
const guard = step('Constrain Full tvOS test mode to artifact-only builds');
for (const check of ['[ -z "$TEST_RELEASE_TAG" ]', '[ -z "$TEST_RELEASE_ID" ]', '[ "$TEST_PUBLISH" != "true" ]', 'exit 1']) assert(guard.includes(check));
console.log('ok: Full tvOS test lane preserves TV gates, skips other app builds, packages only TV, and refuses release writes');
const publicPackaging = step('Package the IPAs');
assert(publicPackaging.includes('set -euo pipefail'));
const payloadCleanup = publicPackaging.indexOf('rm -rf out/full/Payload');
for (const asset of ['VortX-tvOS-ci.ipa', 'VortX-tvOS-lite-ci.ipa', 'VortX-iOS-ci.ipa']) {
    const verified = publicPackaging.indexOf('unzip -tqq out/' + asset);
    assert(verified >= 0 && verified < payloadCleanup, asset + ' must verify before cleanup');
}
const inputCleanup = publicPackaging.indexOf('rm -rf app/Vendor/MPVKit-DVFEL/artifacts');
const signCheck = publicPackaging.indexOf('codesign --verify --deep --strict "$MAC_APP"');
const dmg = publicPackaging.indexOf('\n          bash scripts/package-macos-dmg.sh');
assert(payloadCleanup < inputCleanup && inputCleanup < signCheck && signCheck < dmg);
assert(!publicPackaging.includes('rm -rf app/build/ci-mac'));
const packager = fs.readFileSync(require('node:path').join(require('node:path').dirname(process.argv[2]), '../../scripts/package-macos-dmg.sh'), 'utf8');
const measure = packager.indexOf('SOURCE_KIB="$(du -A -l -P -s -k');
const size = packager.indexOf('DMG_MIB=');
const free = packager.indexOf('AVAILABLE_KIB="$(df -Pk');
const create = packager.indexOf('hdiutil create -volname VortX -size "${DMG_MIB}m"');
assert(measure >= 0 && measure < size && size < free && free < create);
assert(packager.includes('SOURCE_MIB * 5 + 3') && packager.includes('/ 4 + 1024'));
assert(packager.includes('"$AVAILABLE_KIB" -ge "$REQUIRED_KIB"'));
assert(packager.includes('refusing to overwrite an existing disk image'));
assert(packager.indexOf('hdiutil verify "$OUTPUT"') > create);
assert(packager.includes('hdiutil attach -readonly -nobrowse -noautoopen'));
assert(packager.includes('codesign --verify --deep --strict "$MOUNT/VortX.app"'));
assert(packager.includes('audit-bundle-symlinks.sh" "$MOUNT/VortX.app"'));
assert(packager.includes('"$MOUNT_HASH" == "$SOURCE_HASH"'));
assert(packager.includes('hdiutil detach "$MOUNT"') && packager.includes('trap cleanup EXIT'));
assert(!/rm\s+-r/.test(packager));
console.log('ok: public packaging verifies IPAs before cleanup and creates an explicitly sized, mounted and signature-verified Mac DMG');
NODE

bash -n "$REPO_ROOT/scripts/package-macos-dmg.sh"

# Keep the shared settings deployment floor and release-feed commit identity explicit.
require_grep "shared settings availability fixture runs before app packaging" \
    'app/Tests/ServerConfigViewAvailabilityTests.swift app/SourcesShared/ServerConfigView.swift' "$APPLE_RELEASE_WF"
require_grep "shared settings fixture targets supported iOS 16" \
    'swiftc -typecheck -swift-version 5 -target arm64-apple-ios16.0' "$APPLE_RELEASE_WF"
require_grep "release feed commits retain Mamaclapper authorship" \
    'author:\{name:"Mamaclapper",email:"mamaclapper@users.noreply.github.com"\}' "$APPLE_RELEASE_WF"
require_grep "release feed commits retain Mamaclapper committer identity" \
    'committer:\{name:"Mamaclapper",email:"mamaclapper@users.noreply.github.com"\}' "$APPLE_RELEASE_WF"

# --- Workflow YAML parses --------------------------------------------------------------------------

node --test "$REPO_ROOT/scripts/tests/release-resume-contract.test.mjs"

if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
    for wf in "$RELEASE_WF" "$VALIDATION_WF" "$ANDROID_CI_WF" "$APPLE_RELEASE_WF" "$RECOVERY_WF" "$ANDROID_AUGMENT_WF"; do
        python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$wf" \
            || fail "$(basename "$wf") is not valid YAML"
        ok "$(basename "$wf") parses as valid YAML"
    done
else
    printf 'skip: pyyaml unavailable; YAML syntax not re-checked\n'
fi

printf 'all release orchestration contract tests passed\n'
