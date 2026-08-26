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
readonly APPLE_RELEASE_WF="$REPO_ROOT/.github/workflows/release-tvos.yml"
readonly GRADLE_BUILD="$REPO_ROOT/android/app/build.gradle.kts"
readonly ARTIFACTS_DOC="$REPO_ROOT/docs/RELEASE-ARTIFACTS.md"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

ok() {
    printf 'ok: %s\n' "$1"
}

require_grep() {
    local description="$1" pattern="$2" file="$3"
    grep -Eq "$pattern" "$file" || fail "$description"
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
require_grep "validation rejects Android Debug certificates" 'Android Debug' "$VALIDATION_WF"
require_grep "validation uses strict jarsigner verification on the AAB" \
    'jarsigner" -verify -strict' "$VALIDATION_WF"
require_grep "validation enforces the GPL boundary on the play flavor" \
    'GPL native library found in play release APK' "$VALIDATION_WF"
require_grep "validation generates an explicitly non-debug ad-hoc identity" \
    'CN=VortX CI Ad-hoc Release' "$VALIDATION_WF"
require_grep "validation shreds the ephemeral keystore" 'Shred ephemeral ad-hoc keystore' "$VALIDATION_WF"
require_grep "validation exercises the release-feed script contract" \
    'node scripts/tests/release-feed\.test\.mjs' "$VALIDATION_WF"
require_grep "validation exercises the AltStore source generator contract" \
    'python3 scripts/tests/test_gen_altstore_source\.py' "$VALIDATION_WF"
require_grep "validation exercises the IPA repackaging contract" \
    'bash scripts/tests/repackage-ipa\.test\.sh' "$VALIDATION_WF"
require_grep "validation parses the real project build number" \
    'node scripts/release-feed\.mjs project-build --file app/project\.yml' "$VALIDATION_WF"

permissions_block="$(awk '/^permissions:/{flag=1} flag && /^[a-zA-Z_-]+:/ && !/^permissions:/{exit} flag{print}' "$VALIDATION_WF")"
grep -Eq 'contents:\s*read' <<<"$permissions_block" \
    || fail "validation workflow must hold contents: read only"
ok "validation workflow holds contents: read only"

# --- Contract 4: no debug-signing fallback anywhere in the release path ---------------------------

for wf in "$RELEASE_WF" "$ANDROID_CI_WF" "$APPLE_RELEASE_WF" "$VALIDATION_WF"; do
    require_absent "no debug-signed fallback marker in $(basename "$wf")" \
        'debug-signed' "$wf"
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

# --- Workflow YAML parses --------------------------------------------------------------------------

if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
    for wf in "$RELEASE_WF" "$VALIDATION_WF"; do
        python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$wf" \
            || fail "$(basename "$wf") is not valid YAML"
        ok "$(basename "$wf") parses as valid YAML"
    done
else
    printf 'skip: pyyaml unavailable; YAML syntax not re-checked\n'
fi

printf 'all release orchestration contract tests passed\n'
