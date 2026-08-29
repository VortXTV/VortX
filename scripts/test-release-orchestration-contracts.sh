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
readonly ROOT_GRADLE_BUILD="$REPO_ROOT/android/build.gradle.kts"
readonly GRADLE_BUILD="$REPO_ROOT/android/app/build.gradle.kts"
readonly MPV_SEAM_BUILD="$REPO_ROOT/android/mpv-seam/build.gradle.kts"
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

# The universal label is only honest when every native producer and verifier carries the same ABI
# set. In particular, armeabi-v7a must never be enabled at packaging level without both Rust engines,
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
    require_grep "$(basename "$wf") verifies all three shipped ABI directories" \
        'for abi in arm64-v8a armeabi-v7a x86_64' "$wf"
done
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
require_grep "attach-release exposes immutable release ID to the downstream verifier" \
    'release_id: \$\{\{ steps\.identity\.outputs\.release_id \}\}' "$APPLE_RELEASE_WF"
grep -Fq 'needs.attach-release.outputs.release_id' <<<"$verify_published_block" \
    || fail "downstream verifier does not consume attach-release's immutable release ID"
ok "downstream verifier consumes the immutable release ID"
grep -Eq '^    permissions:$' <<<"$verify_published_block" \
    && grep -Eq '^      contents: read$' <<<"$verify_published_block" \
    || fail "published-release verifier must hold contents: read only"
if grep -Eq 'contents:\s*write|actions/checkout' <<<"$verify_published_block"; then
    fail "published-release verifier has write authority or executes repository code"
fi
ok "published-release verifier has least privilege and runs no repository code"

# --- Workflow YAML parses --------------------------------------------------------------------------

if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
    for wf in "$RELEASE_WF" "$VALIDATION_WF" "$ANDROID_CI_WF"; do
        python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$wf" \
            || fail "$(basename "$wf") is not valid YAML"
        ok "$(basename "$wf") parses as valid YAML"
    done
else
    printf 'skip: pyyaml unavailable; YAML syntax not re-checked\n'
fi

printf 'all release orchestration contract tests passed\n'
