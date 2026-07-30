#!/usr/bin/env bash
set -euo pipefail

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/vortx-repackage-test.XXXXXX")"
SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)/scripts/repackage-ipa.sh"
REAL_ZIP="$(command -v zip)"

cleanup() {
  find "$ROOT" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

make_payload() {
  local source="$1"
  mkdir -p "$source/Payload/Stremio.app"
  printf '<plist/>\n' > "$source/Payload/Stremio.app/Info.plist"
  printf '#!/bin/sh\nexit 0\n' > "$source/Payload/Stremio.app/Stremio"
  chmod +x "$source/Payload/Stremio.app/Stremio"
}

assert_payload_root() {
  local archive="$1"
  local entry
  while IFS= read -r entry; do
    case "$entry" in
      Payload | Payload/*) ;;
      *) fail "archive has a non-Payload root entry: $entry" ;;
    esac
  done < <(unzip -Z1 "$archive")
}

source_with_spaces="$ROOT/source tree"
absolute_output="$ROOT/absolute output/VortX Test.ipa"
make_payload "$source_with_spaces"
"$SCRIPT" "$source_with_spaces" "$absolute_output"
[[ -f "$absolute_output" ]] || fail "absolute output was not created"
unzip -tqq "$absolute_output"
assert_payload_root "$absolute_output"

caller="$ROOT/caller tree"
relative_source="$ROOT/relative source"
mkdir -p "$caller"
make_payload "$relative_source"
# The old script changed into the source before handing this relative path to zip. Pre-creating the same
# directory there reproduces its misleading success case: it wrote an IPA, but under the source tree.
mkdir -p "$relative_source/relative output"
(
  cd "$caller"
  "$SCRIPT" "../relative source" "relative output/VortX Relative.ipa"
)
relative_output="$caller/relative output/VortX Relative.ipa"
[[ -f "$relative_output" ]] || fail "relative output was not resolved against the caller"
[[ ! -e "$relative_source/relative output/VortX Relative.ipa" ]] ||
  fail "relative output was written inside the source tree"
unzip -tqq "$relative_output"
assert_payload_root "$relative_output"

missing_source="$ROOT/missing payload"
missing_output="$ROOT/missing.ipa"
mkdir -p "$missing_source"
if "$SCRIPT" "$missing_source" "$missing_output" >/dev/null 2>&1; then
  fail "missing Payload was accepted"
fi
[[ ! -e "$missing_output" ]] || fail "missing Payload produced an output"

invalid_source="$ROOT/invalid payload"
invalid_output="$ROOT/invalid.ipa"
mkdir -p "$invalid_source/Payload"
printf 'not an app\n' > "$invalid_source/Payload/readme.txt"
if "$SCRIPT" "$invalid_source" "$invalid_output" >/dev/null 2>&1; then
  fail "Payload without an app Info.plist was accepted"
fi
[[ ! -e "$invalid_output" ]] || fail "invalid Payload produced an output"

symlink_source="$ROOT/symlink source"
symlink_payload="$ROOT/physical payload"
make_payload "$ROOT/payload fixture"
mkdir -p "$symlink_source"
mv "$ROOT/payload fixture/Payload" "$symlink_payload"
rmdir "$ROOT/payload fixture"
ln -s "$symlink_payload" "$symlink_source/Payload"
if "$SCRIPT" "$symlink_source" "$symlink_payload/inside.ipa" >/dev/null 2>&1; then
  fail "output inside a symlinked Payload target was accepted"
fi
[[ ! -e "$symlink_payload/inside.ipa" ]] || fail "output was written inside a symlinked Payload target"

fake_bin="$ROOT/fake bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/zip" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
archive="$2"
work="$(mktemp -d "${TMPDIR:-/tmp}/vortx-wrong-root.XXXXXX")"
printf 'wrong root\n' > "$work/Unexpected.txt"
(
  cd "$work"
  "$REAL_ZIP" -q "$archive" Unexpected.txt
)
rm -f "$work/Unexpected.txt"
rmdir "$work"
EOF
chmod +x "$fake_bin/zip"

wrong_root_output="$ROOT/wrong root.ipa"
printf 'existing output\n' > "$wrong_root_output"
if PATH="$fake_bin:$PATH" REAL_ZIP="$REAL_ZIP" \
  "$SCRIPT" "$source_with_spaces" "$wrong_root_output" >/dev/null 2>&1; then
  fail "archive with a non-Payload root was accepted"
fi
[[ "$(cat "$wrong_root_output")" == "existing output" ]] ||
  fail "failed validation replaced the existing output"
if find "$ROOT" -name '.repackage-ipa.*' -print -quit | grep -q .; then
  fail "failed validation left a staging directory behind"
fi

cat > "$fake_bin/zip" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'not a zip\n' > "$2"
EOF
chmod +x "$fake_bin/zip"

corrupt_output="$ROOT/corrupt.ipa"
if PATH="$fake_bin:$PATH" "$SCRIPT" "$source_with_spaces" "$corrupt_output" >/dev/null 2>&1; then
  fail "corrupt archive was accepted"
fi
[[ ! -e "$corrupt_output" ]] || fail "corrupt archive reached the requested output"
if find "$ROOT" -name '.repackage-ipa.*' -print -quit | grep -q .; then
  fail "corrupt archive left a staging directory behind"
fi

backslash_source="$ROOT/backslash payload"
backslash_output="$ROOT/backslash.ipa"
make_payload "$backslash_source"
printf 'hostile entry\n' > "$backslash_source/Payload/Stremio.app/bad\\name"
if "$SCRIPT" "$backslash_source" "$backslash_output" >/dev/null 2>&1; then
  fail "archive with a backslash entry was accepted"
fi
[[ ! -e "$backslash_output" ]] || fail "archive with a backslash entry reached the output"

echo "PASS: repackage-ipa absolute, relative, missing, root-shape, and integrity cases"
