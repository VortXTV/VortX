#!/usr/bin/env bash
# Deterministic contract checks for the local-MPVKit scheduled report.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$REPO/.github/workflows/mpvkit-watch.yml"
PROJECT="$REPO/app/project.yml"
BUILD="$REPO/scripts/build-mpvkit-dvfel.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[ -f "$WORKFLOW" ] || fail "workflow missing: $WORKFLOW"
[ -f "$PROJECT" ] || fail "project file missing: $PROJECT"
[ -f "$BUILD" ] || fail "build script missing: $BUILD"

MPVKIT_PATH=$(awk '
  /^  MPVKit:$/ { in_mpvkit = 1; next }
  in_mpvkit && /^  [^[:space:]]/ { exit }
  in_mpvkit && /^[[:space:]]+path:/ {
    sub(/^[[:space:]]*path:[[:space:]]*/, "")
    print
    exit
  }
' "$PROJECT")
[ "$MPVKIT_PATH" = "Vendor/MPVKit-DVFEL" ] || fail "expected local MPVKit-DVFEL package, found: ${MPVKIT_PATH:-none}"

PINNED=$(sed -nE 's/^MPVKIT_REF="([0-9a-f]{40})".*/\1/p' "$BUILD")
PINNED_COUNT=$(printf '%s\n' "$PINNED" | awk 'NF { count++ } END { print count + 0 }')
[ "$PINNED_COUNT" -eq 1 ] && printf '%s\n' "$PINNED" | grep -qxE '[0-9a-f]{40}' \
  || fail "build script must expose exactly one 40-character MPVKIT_REF"

grep -Fq 'permissions:' "$WORKFLOW" || fail "workflow must declare permissions"
grep -Fq 'contents: read' "$WORKFLOW" || fail "workflow must retain read-only contents access"
grep -Eq 'uses: actions/checkout@[0-9a-f]{40}' "$WORKFLOW" || fail "checkout action must be SHA-pinned"
grep -Fq 'Authoritative MPVKit base-source pin:' "$WORKFLOW" || fail "workflow must report the build-script source pin"
grep -Fq 'scripts/build-mpvkit-dvfel.sh' "$WORKFLOW" || fail "workflow must identify the authoritative build script"

if grep -Eq 'exactVersion:|issues:[[:space:]]+write|gh issue create|repos/mpvkit/MPVKit/releases' "$WORKFLOW"; then
  fail "workflow must not treat the local package as a release-version bump"
fi

echo "PASS: local MPVKit-DVFEL source-pin report contract ($PINNED)"
