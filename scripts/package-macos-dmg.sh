#!/usr/bin/env bash
# Package an already signed VortX.app and Applications link. Never alter the app or publish it.
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
die() { printf '::error::%s\n' "$*" >&2; exit 1; }
[[ "$#" -eq 2 ]] || die 'usage: package-macos-dmg.sh <staging-directory> <new-output.dmg>'
[[ "$(uname -s)" == Darwin ]] || die 'Mac disk images must be packaged on macOS'

STAGE="$(cd "$1" && pwd -P)"
OUTPUT_DIR="$(cd "$(dirname "$2")" && pwd -P)"
OUTPUT="$OUTPUT_DIR/$(basename "$2")"
[[ "$OUTPUT" == *.dmg ]] || die 'output must have a .dmg extension'
[[ ! -e "$OUTPUT" && ! -L "$OUTPUT" ]] || die 'refusing to overwrite an existing disk image'
case "$OUTPUT" in "$STAGE"/*) die 'output must be outside the source tree';; esac
[[ -d "$STAGE/VortX.app" && ! -L "$STAGE/VortX.app" ]] || die 'staging must contain a real VortX.app bundle'
[[ -L "$STAGE/Applications" && "$(readlink "$STAGE/Applications")" == /Applications ]] \
    || die 'staging must contain the /Applications install link'
codesign --verify --deep --strict "$STAGE/VortX.app"
bash "$SCRIPT_DIR/audit-bundle-symlinks.sh" "$STAGE/VortX.app"

# hdiutil's automatic -srcfolder estimate can under-size the destination filesystem even when
# the runner has plenty of free space. Apparent size accounts for compressed/sparse source files;
# count hard links separately (a copy may duplicate them), but never follow framework symlinks.
SOURCE_KIB="$(du -A -l -P -s -k "$STAGE" | awk 'NR == 1 {print $1}')"
[[ "$SOURCE_KIB" =~ ^[0-9]{1,12}$ && "$SOURCE_KIB" -gt 0 ]] || die 'invalid source size'
SOURCE_MIB=$(((SOURCE_KIB + 1023) / 1024))
DMG_MIB=$(((SOURCE_MIB * 5 + 3) / 4 + 1024))
AVAILABLE_KIB="$(df -Pk "$OUTPUT_DIR" | awk 'END {print $4}')"
[[ "$AVAILABLE_KIB" =~ ^[0-9]{1,12}$ ]] || die 'invalid destination free-space report'
# Reserve room for the writable image, compressed result, and temporary/compression overhead.
REQUIRED_KIB=$((DMG_MIB * 1024 * 3))
[[ "$AVAILABLE_KIB" -ge "$REQUIRED_KIB" ]] || die 'insufficient host space for image creation and compression'
printf 'Mac DMG: source=%s KiB, volume=%s MiB, host available=%s KiB\n' "$SOURCE_KIB" "$DMG_MIB" "$AVAILABLE_KIB"
hdiutil create -volname VortX -size "${DMG_MIB}m" -srcfolder "$STAGE" -format UDZO "$OUTPUT"
hdiutil verify "$OUTPUT"

MOUNT="$(mktemp -d "$OUTPUT_DIR/.vortx-dmg-mount.XXXXXX")"
MOUNTED=0
cleanup() {
    local result=$?
    trap - EXIT
    if [[ "$MOUNTED" -eq 1 ]]; then
        if hdiutil detach "$MOUNT"; then
            MOUNTED=0
        else
            printf '::error::could not detach the verification disk image at %s\n' "$MOUNT" >&2
            result=1
        fi
    fi
    # Never recursively remove a possibly mounted volume; only retire our empty mount directory.
    if [[ "$MOUNTED" -eq 0 ]]; then rmdir "$MOUNT" || result=1; fi
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
MOUNTED=1 # An interrupted/failed attach may still have mounted the image; cleanup must try detach.
hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$MOUNT" "$OUTPUT"
[[ -d "$MOUNT/VortX.app" && ! -L "$MOUNT/VortX.app" ]] || die 'disk image is missing its app bundle'
[[ -L "$MOUNT/Applications" && "$(readlink "$MOUNT/Applications")" == /Applications ]] \
    || die 'disk image is missing its install link'
cmp "$STAGE/VortX.app/Contents/Info.plist" "$MOUNT/VortX.app/Contents/Info.plist"
codesign --verify --deep --strict "$MOUNT/VortX.app"
bash "$SCRIPT_DIR/audit-bundle-symlinks.sh" "$MOUNT/VortX.app"
SOURCE_HASH="$(codesign -d --verbose=4 "$STAGE/VortX.app" 2>&1 | awk -F= '$1 == "CDHash" {print $2}')"
MOUNT_HASH="$(codesign -d --verbose=4 "$MOUNT/VortX.app" 2>&1 | awk -F= '$1 == "CDHash" {print $2}')"
[[ "$SOURCE_HASH" =~ ^[0-9a-f]{40}$ && "$MOUNT_HASH" == "$SOURCE_HASH" ]] \
    || die 'mounted app signature does not match the signed source'
hdiutil detach "$MOUNT"
MOUNTED=0
printf 'Mac DMG verified: signed app, exact metadata, safe framework links and install link\n'
