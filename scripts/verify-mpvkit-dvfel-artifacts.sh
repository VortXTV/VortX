#!/usr/bin/env bash
# Verify the shipped MPVKit-DVFEL package by inspecting its framework contents.
#
# This gate intentionally does not trust archive freshness, release prose, or a checksum alone:
# it proves the actual local binary targets contain the FFmpeg 9 ABI and Dolby Vision splitter that
# the package manifest claims to provide, then delegates the existing per-slice TLS proof.
set -euo pipefail

PKG="${1:?usage: verify-mpvkit-dvfel-artifacts.sh <MPVKit-DVFEL-package-dir>}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACTS="$PKG/artifacts"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "MPVKit-DVFEL ARTIFACT VERIFY FAILED: $*" >&2
  exit 1
}

[ -f "$PKG/Package.swift" ] || fail "missing package manifest: $PKG/Package.swift"
[ -d "$ARTIFACTS" ] || fail "missing artifact directory: $ARTIFACTS"

# Local targets are the only rebuilt pieces. Requiring each path prevents a package that happens
# to contain one valid framework from silently falling back to the old remote target set.
local_targets=(
  Libmpv-GPL Libavcodec-GPL Libavdevice-GPL Libavfilter-GPL Libavformat-GPL
  Libavutil-GPL Libswresample-GPL Libswscale-GPL Libplacebo
)
for target in "${local_targets[@]}"; do
  grep -Fq "name: \"$target\"" "$PKG/Package.swift" || fail "manifest is missing local target $target"
  grep -Fq "path: \"artifacts/$target.xcframework\"" "$PKG/Package.swift" ||
    fail "manifest does not bind $target to its local artifact"
  [ -d "$ARTIFACTS/$target.xcframework" ] || fail "missing local framework $target.xcframework"
done

SLICES=(
  ios-arm64
  ios-arm64_x86_64-simulator
  tvos-arm64_arm64e
  tvos-arm64_x86_64-simulator
  macos-arm64_x86_64
)

framework_binary() {
  case "$1" in
    Libmpv-GPL) echo Libmpv ;;
    Libavcodec-GPL) echo Libavcodec ;;
    Libavdevice-GPL) echo Libavdevice ;;
    Libavfilter-GPL) echo Libavfilter ;;
    Libavformat-GPL) echo Libavformat ;;
    Libavutil-GPL) echo Libavutil ;;
    Libswresample-GPL) echo Libswresample ;;
    Libswscale-GPL) echo Libswscale ;;
    Libplacebo) echo Libplacebo ;;
    *) fail "unknown local framework $1" ;;
  esac
}

version_major_pattern() {
  case "$1" in
    Libavcodec-GPL) echo '^[[:space:]]*#define[[:space:]]+LIBAVCODEC_VERSION_MAJOR[[:space:]]+63([[:space:]]|$)' ;;
    Libavformat-GPL) echo '^[[:space:]]*#define[[:space:]]+LIBAVFORMAT_VERSION_MAJOR[[:space:]]+63([[:space:]]|$)' ;;
    *) return 1 ;;
  esac
}

if command -v xcrun >/dev/null 2>&1; then
  NM=(xcrun nm)
else
  NM=(nm)
fi
command -v lipo >/dev/null 2>&1 || fail "lipo is required to inspect every framework architecture"

for target in Libavcodec-GPL Libavformat-GPL; do
  binary_name="$(framework_binary "$target")"
  pattern="$(version_major_pattern "$target")"
  framework="$ARTIFACTS/$target.xcframework"
  for slice in "${SLICES[@]}"; do
    slice_root="$framework/$slice/${binary_name}.framework"
    binary="$slice_root/$binary_name"
    headers="$slice_root/Headers"
    [ -f "$binary" ] || fail "missing $target binary in slice $slice"
    [ -d "$headers" ] || fail "missing $target headers in slice $slice"

    version_header=""
    while IFS= read -r candidate; do
      if grep -Eq "$pattern" "$candidate"; then
        version_header="$candidate"
        break
      fi
    done < <(find "$headers" -type f \( -name 'version_major.h' -o -name 'version.h' \) | LC_ALL=C sort)
    [ -n "$version_header" ] || fail "$target/$slice does not declare required FFmpeg 9 major 63"

    arch_list="$(lipo -archs "$binary")" || fail "cannot enumerate architectures in $binary"
    read -r -a arches <<<"$arch_list"
    [ "${#arches[@]}" -gt 0 ] || fail "no architectures found in $binary"
    for arch in "${arches[@]}"; do
      thin="$TMP/$target-$slice-$arch"
      if [ "${#arches[@]}" -eq 1 ]; then
        cp "$binary" "$thin"
      else
        lipo "$binary" -thin "$arch" -output "$thin"
      fi
      symbols="$("${NM[@]}" -gU "$thin" 2>/dev/null)" ||
        fail "cannot inspect defined symbols in $target/$slice [$arch]"
      # nm -gU reports only defined external symbols; the symbol must therefore be real code/data,
      # not an undefined reference or a string/comment mentioning dovi_split.
      grep -Eq '(^|[[:space:]])_?(ff_)?dovi_split(_bsf)?$' <<<"$symbols" ||
        fail "$target/$slice [$arch] lacks the defined dovi_split bitstream filter symbol"
    done
  done
done

# The existing TLS gate checks every Libavformat architecture, config macros, SecureTransport
# imports, and absence of GnuTLS references. Keep it in this content gate so release fetches cannot
# stop after a checksum/unzip or accidentally skip the security backend proof.
"$REPO/scripts/verify-mpvkit-dvfel-apple-tls.sh" "$PKG"

echo "MPVKit-DVFEL ARTIFACT VERIFY PASSED: FFmpeg 9 (libavcodec/libavformat major 63), dovi_split, and Apple TLS gates"
