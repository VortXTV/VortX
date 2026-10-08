#!/usr/bin/env bash
# Focused source contracts for the pinned MPVKit-DVFEL builder and release artifact gate.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/scripts/build-mpvkit-dvfel.sh"
PATCH="$ROOT/scripts/mpvkit-dvfel.patch"
VERIFY="$ROOT/scripts/verify-mpvkit-dvfel-artifacts.sh"
WORKFLOW="$ROOT/.github/workflows/release-tvos.yml"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

for file in "$BUILD" "$PATCH" "$VERIFY" "$WORKFLOW"; do
  [ -f "$file" ] || fail "missing required source: $file"
done

grep -Eq '^MPVKIT_REF="[0-9a-f]{40}"' "$BUILD" || fail "builder must expose one full MPVKit source pin"
grep -Fq 'MPVKIT_DIR="${MPVKIT_DVFEL_WORK:-$REPO/../MPVKit}"' "$BUILD" ||
  fail "builder default must use the canonical MPVKit sibling checkout"
if grep -Fq '$HOME/.cache/vortx-mpvkit-dvfel' "$BUILD"; then
  fail "builder must not silently use a HOME cache as its default source"
fi
if grep -Fq 'git checkout --quiet -- .' "$BUILD"; then
  fail "builder must not reset tracked user changes"
fi
grep -Fq 'git -C "$MPVKIT_DIR" rev-parse HEAD' "$BUILD" || fail "builder must validate an existing checkout HEAD"
grep -Fq 'FRESH_HEAD' "$BUILD" || fail "builder must assert the fresh clone resolved to the exact pin"
grep -Fq 'exact MPVKit patch already applied' "$BUILD" || fail "builder must support an explicit exact-patch retry"
grep -Fq 'existing generated patch differs' "$BUILD" || fail "builder must not overwrite a changed generated patch"

# The Swift patch must reject a wrong/dirty source checkout and distinguish forward application,
# exact reverse-checked reapplication, and an actionable conflict.
grep -Fq 'git status --porcelain --untracked-files=all' "$PATCH" || fail "SpikeGit must inspect dirty state"
grep -Fq 'git diff --cached --quiet' "$PATCH" || fail "SpikeGit must reject staged changes"
grep -Fq 'git rev-parse HEAD' "$PATCH" || fail "SpikeGit must validate an existing HEAD"
grep -Fq 'expected exact pin' "$PATCH" || fail "SpikeGit must assert the fresh checkout pin"
grep -Fq 'git apply --reverse --check' "$PATCH" || fail "SpikeGit must support an exact already-applied patch"
grep -Fq 'patch neither applies cleanly nor is already applied' "$PATCH" || fail "SpikeGit must fail actionable patch conflicts"

# The artifact verifier must inspect content, not only checksums or mtimes.
grep -Fq 'LIBAVCODEC_VERSION_MAJOR' "$VERIFY" || fail "artifact gate must inspect libavcodec major"
grep -Fq 'LIBAVFORMAT_VERSION_MAJOR' "$VERIFY" || fail "artifact gate must inspect libavformat major"
grep -Fq 'LIBAVCODEC_VERSION_MAJOR[[:space:]]+63' "$VERIFY" || fail "artifact gate must require libavcodec major 63"
grep -Fq 'LIBAVFORMAT_VERSION_MAJOR[[:space:]]+63' "$VERIFY" || fail "artifact gate must require libavformat major 63"
grep -Fq 'dovi_split' "$VERIFY" || fail "artifact gate must require dovi_split"
grep -Fq 'verify-mpvkit-dvfel-apple-tls.sh' "$VERIFY" || fail "artifact gate must retain TLS verification"

# Extract the real fetch step and require the verifier after unzip, before the next workflow step.
fetch_step="$(awk '/name: Fetch the MPVKit-DVFEL artifacts/{active=1; next}
  active && /^[[:space:]]+- name:/{exit} active{print}' "$WORKFLOW")"
grep -Fq 'unzip -q /tmp/mpvkit.zip -d "$DEST"' <<<"$fetch_step" ||
  fail "release fetch step must unpack the pinned artifact"
grep -Fq 'bash scripts/verify-mpvkit-dvfel-artifacts.sh "$DEST"' <<<"$fetch_step" ||
  fail "release fetch step must run the real MPV artifact verifier"
unzip_line="$(grep -nF 'unzip -q /tmp/mpvkit.zip -d "$DEST"' <<<"$fetch_step" | cut -d: -f1)"
verify_line="$(grep -nF 'bash scripts/verify-mpvkit-dvfel-artifacts.sh "$DEST"' <<<"$fetch_step" | cut -d: -f1)"
[ "$verify_line" -gt "$unzip_line" ] || fail "artifact verifier must run after unpack"

echo "PASS: MPVKit-DVFEL pin/dirty-state, FFmpeg capability, TLS, and post-fetch artifact contracts"
