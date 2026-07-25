#!/usr/bin/env bash
#
# Liveness test for the engine leak guard: proves the guard is not merely PRESENT but
# actually REFUSES an engine push, and actually stays out of the way of ordinary work.
#
# The failure this whole guard exists to prevent is a silent absence. A file that exists
# proves nothing; only a refused push does. So this runs in CI on every push and on the
# sweep schedule, which turns any future silent absence into a red build.
#
# No network, no secrets, no credentials. Everything happens inside one `mktemp -d` that
# is removed on exit, against `file://` bare remotes.
#
#   scripts/verify-engine-leak-guard.sh
#
# EXIT  0 every assertion passed   1 one or more failed

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_HOOK="$REPO/.githooks/pre-push"
SRC_SCANNER="$REPO/scripts/scan-proprietary-engine.sh"
ZERO="0000000000000000000000000000000000000000"

# Assembled from fragments for the same reason scan-proprietary-engine.sh does it: spelled
# out whole, this file would trip the very marker sweep it is testing.
MARKER_SPDX="LicenseRef-VortX""-Proprietary"

passes=0
failures=0
ok()  { printf 'PASS  %s\n' "$*"; passes=$((passes + 1)); }
bad() { printf 'FAIL  %s\n' "$*" >&2; failures=$((failures + 1)); }

[ -r "$SRC_HOOK" ]    || { echo "verify: missing $SRC_HOOK" >&2; exit 1; }
[ -r "$SRC_SCANNER" ] || { echo "verify: missing $SRC_SCANNER" >&2; exit 1; }

# --- 4. config hygiene, in the REAL repository ----------------------------------------
# Run before the hermetic block below, because that block nulls the global git config and
# a global core.hooksPath is exactly one of the things this assertion has to be able to see.
if out="$("$SCRIPT_DIR/install-git-hooks.sh" --check 2>&1)"; then
    ok "config hygiene: no core.hooksPath in any scope, installed files match the sources"
else
    bad "config hygiene: $out"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Hermetic from here down: the scratch repositories must not inherit this machine's git
# identity, aliases, or a core.hooksPath that would mask what is being tested.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null

# A scratch repository with a bare `file://` remote and the guard installed exactly the way
# install-git-hooks.sh installs it: hook in <common-dir>/hooks, scanner as its ../scripts
# sibling. Installing it this way is itself part of the test, because it is the sibling
# resolution at .githooks/pre-push that the relocation depends on.
new_repo() { # <name>
    local name="$1"
    git init --quiet --bare "$tmp/$name.git"
    git init --quiet -b main "$tmp/$name"
    git -C "$tmp/$name" config user.name "engine leak guard verify"
    git -C "$tmp/$name" config user.email "guard-verify@vortx.invalid"
    git -C "$tmp/$name" config commit.gpgsign false
    git -C "$tmp/$name" remote add origin "file://$tmp/$name.git"
    mkdir -p "$tmp/$name/.git/hooks" "$tmp/$name/.git/scripts"
    cp "$SRC_HOOK" "$tmp/$name/.git/hooks/pre-push"
    cp "$SRC_SCANNER" "$tmp/$name/.git/scripts/scan-proprietary-engine.sh"
    chmod +x "$tmp/$name/.git/hooks/pre-push" "$tmp/$name/.git/scripts/scan-proprietary-engine.sh"
}

# --- 1. fires: engine content to a remote whose visibility cannot be established --------
# A file:// URL is not a GitHub repository, so the hook cannot confirm the destination is
# private and must fail closed. One assertion exercises both the block path and the
# fail-closed path.
new_repo engine
mkdir -p "$tmp/engine/vortx-core"
printf 'license = "%s"\n' "$MARKER_SPDX" > "$tmp/engine/vortx-core/Cargo.toml"
git -C "$tmp/engine" add vortx-core/Cargo.toml
git -C "$tmp/engine" commit --quiet -m "engine snapshot"
out="$(git -C "$tmp/engine" push origin main 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'PUSH BLOCKED'; then
    ok "fires: engine push refused (exit $rc, PUSH BLOCKED)"
else
    bad "fires: engine push was NOT refused (exit $rc)"
    printf '%s\n' "$out" | sed 's/^/      /' >&2
fi

# --- 2. stays silent: ordinary app content --------------------------------------------
new_repo app
printf '# VortX\n' > "$tmp/app/README.md"
mkdir -p "$tmp/app/app"
printf 'import SwiftUI\n\nstruct RootView: View {\n    var body: some View { Text("VortX") }\n}\n' \
    > "$tmp/app/app/RootView.swift"
git -C "$tmp/app" add README.md app/RootView.swift
git -C "$tmp/app" commit --quiet -m "app code"
out="$(git -C "$tmp/app" push origin main 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && ! printf '%s' "$out" | grep -qE 'PUSH BLOCKED|engine leak guard'; then
    ok "stays silent: ordinary app push succeeded with no guard output"
else
    bad "stays silent: ordinary app push did not pass cleanly (exit $rc)"
    printf '%s\n' "$out" | sed 's/^/      /' >&2
fi

# The push above cannot prove "no output" on its own, because git prints its own transfer
# lines. Invoking the hook the way git invokes it does prove it.
app_sha="$(git -C "$tmp/app" rev-parse HEAD)"
out="$(cd "$tmp/app" && printf 'refs/heads/main %s refs/heads/main %s\n' "$app_sha" "$ZERO" \
        | .git/hooks/pre-push origin "file://$tmp/app.git" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    ok "stays silent: hook exits 0 and prints nothing at all on clean content"
else
    bad "stays silent: hook printed output or failed on clean content (exit $rc)"
    printf '%s\n' "$out" | sed 's/^/      /' >&2
fi

# --- 3. private engine remote is allowed ----------------------------------------------
# Invoked directly rather than through `git push`, because a real push to that URL would
# need the network and a credential. The hook's contract is exactly this: argv is the
# remote name and the push URL, stdin is one line per ref. The short circuit under test
# runs before any ref is read, so this exercises the real code path.
engine_sha="$(git -C "$tmp/engine" rev-parse HEAD)"
out="$(cd "$tmp/engine" && printf 'refs/heads/main %s refs/heads/main %s\n' "$engine_sha" "$ZERO" \
        | .git/hooks/pre-push vortx-core-private https://github.com/VortXTV/vortx-core.git 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    ok "private remote: engine content to VortXTV/vortx-core allowed silently"
else
    bad "private remote: engine push to the private engine repo was not allowed (exit $rc)"
    printf '%s\n' "$out" | sed 's/^/      /' >&2
fi

# --- 5. partial copy: a vendored crate with no vortx-core/ directory -------------------
# The case the path probe is blind to by construction. Asserting the path probe's silence
# alongside the manifest probe's hit is what makes this a test of the new probe rather than
# a test that something somewhere fired.
new_repo partial
mkdir -p "$tmp/partial/crates/ranking"
printf '[package]\nname = "%s"\nversion = "0.1.0"\n' "vortx-ranking" \
    > "$tmp/partial/crates/ranking/Cargo.toml"
git -C "$tmp/partial" add crates/ranking/Cargo.toml
git -C "$tmp/partial" commit --quiet -m "vendored crate"
scanner="$tmp/partial/.git/scripts/scan-proprietary-engine.sh"
( cd "$tmp/partial" && "$scanner" paths HEAD ) >/dev/null 2>&1
path_rc=$?
manifest_out="$(cd "$tmp/partial" && "$scanner" markers HEAD 2>&1)"
manifest_rc=$?
if [ "$path_rc" -eq 0 ] && [ "$manifest_rc" -eq 1 ] \
   && printf '%s' "$manifest_out" | grep -q 'crates/ranking/Cargo.toml'; then
    ok "partial copy: path probe silent (as designed), manifest probe caught it"
else
    bad "partial copy: path rc=$path_rc manifest rc=$manifest_rc"
    printf '%s\n' "$manifest_out" | sed 's/^/      /' >&2
fi

printf '\n%d passed, %d failed\n' "$passes" "$failures"
[ "$failures" -eq 0 ] || exit 1
