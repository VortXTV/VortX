#!/usr/bin/env bash
set -euo pipefail

# Repackage an extracted app bundle into an .ipa for Signulous to re-sign.
# Usage: repackage-ipa.sh <dir-containing-Payload> <out.ipa>

die() {
  echo "repackage-ipa: $*" >&2
  exit 1
}

[[ $# -eq 2 ]] || die "usage: repackage-ipa.sh <dir-containing-Payload> <out.ipa>"
SRC_REQUEST="$1"
OUT_REQUEST="$2"
CALLER_DIR="$(pwd -P)"

[[ -n "$OUT_REQUEST" && "$OUT_REQUEST" != */ ]] || die "output must be an .ipa file path"
case "$OUT_REQUEST" in
  /*) OUT_CANDIDATE="$OUT_REQUEST" ;;
  *) OUT_CANDIDATE="$CALLER_DIR/$OUT_REQUEST" ;;
esac

OUT_NAME="$(basename "$OUT_CANDIDATE")"
case "$OUT_NAME" in
  "" | "." | "..") die "output must name an .ipa file" ;;
  *.ipa) ;;
  *) die "output must end in .ipa" ;;
esac

# Resolve the requested destination while still in the caller's directory. The archive command later runs
# from the source tree, so passing an unresolved relative path to zip would redirect it into that tree.
OUT_PARENT_REQUEST="$(dirname "$OUT_CANDIDATE")"
mkdir -p "$OUT_PARENT_REQUEST"
OUT_PARENT="$(cd "$OUT_PARENT_REQUEST" && pwd -P)"
OUT="$OUT_PARENT/$OUT_NAME"
[[ ! -d "$OUT" ]] || die "output is a directory: $OUT"

case "$SRC_REQUEST" in
  /*) SRC_CANDIDATE="$SRC_REQUEST" ;;
  *) SRC_CANDIDATE="$CALLER_DIR/$SRC_REQUEST" ;;
esac
[[ -d "$SRC_CANDIDATE/Payload" ]] || die "no Payload/ in $SRC_REQUEST"
SRC="$(cd "$SRC_CANDIDATE" && pwd -P)"
[[ -d "$SRC/Payload" ]] || die "no Payload/ in $SRC"
PAYLOAD="$(cd "$SRC/Payload" && pwd -P)"
case "$OUT" in
  "$PAYLOAD" | "$PAYLOAD/"*) die "output cannot be inside the Payload tree" ;;
esac

# Build beside the requested destination so the final move is an atomic same-filesystem replacement. A
# failed zip or validation leaves any existing output untouched.
STAGE_DIR="$(mktemp -d "$OUT_PARENT/.repackage-ipa.XXXXXX")"
STAGED_IPA="$STAGE_DIR/$OUT_NAME"
ENTRIES_FILE="$STAGE_DIR/entries.txt"

cleanup() {
  [[ ! -f "${STAGED_IPA:-}" ]] || rm -f "$STAGED_IPA"
  [[ ! -f "${ENTRIES_FILE:-}" ]] || rm -f "$ENTRIES_FILE"
  [[ ! -d "${STAGE_DIR:-}" ]] || rmdir "$STAGE_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# IPA = zip with Payload/ at the archive root. iOS frameworks are flat (no symlinks), so plain zip is safe.
if ! (cd "$SRC" && zip -qry "$STAGED_IPA" Payload -x '*.DS_Store'); then
  die "archive creation failed"
fi
[[ -s "$STAGED_IPA" ]] || die "archive creation produced an empty file"
unzip -tqq "$STAGED_IPA" || die "archive integrity validation failed"
unzip -Z1 "$STAGED_IPA" > "$ENTRIES_FILE" || die "could not read archive entries"
[[ -s "$ENTRIES_FILE" ]] || die "archive contains no entries"

invalid_entry=""
while IFS= read -r entry || [[ -n "$entry" ]]; do
  case "$entry" in
    Payload | Payload/*) ;;
    *)
      invalid_entry="$entry"
      break
      ;;
  esac
  case "/$entry/" in
    *"/../"*)
      invalid_entry="$entry"
      break
      ;;
  esac
  case "$entry" in
    *\\*)
      invalid_entry="$entry"
      break
      ;;
  esac
done < "$ENTRIES_FILE"
[[ -z "$invalid_entry" ]] || die "archive has an invalid root entry: $invalid_entry"
grep -Eq '^Payload/[^/]+[.]app/Info[.]plist$' "$ENTRIES_FILE" ||
  die "archive has no Payload/<App>.app/Info.plist"

SIZE="$(du -h "$STAGED_IPA" | awk 'NR == 1 { print $1 }')"
[[ -n "$SIZE" ]] || die "could not measure the validated archive"
mv -f "$STAGED_IPA" "$OUT"
echo "OK: $OUT ($SIZE)"
