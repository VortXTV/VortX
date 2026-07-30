#!/bin/bash
# Fail closed if the rebuilt Apple player regresses to the wrong TLS backend,
# loses required network protocols, or misses its system framework. Runtime
# tests separately prove trust-verification behavior.
set -euo pipefail

PKG="${1:?usage: verify-mpvkit-dvfel-apple-tls.sh <MPVKit-DVFEL-package-dir>}"
XC="$PKG/artifacts/Libavformat-GPL.xcframework"
PACKAGE_FILE="$PKG/Package.swift"
VERIFY_TMP="$(mktemp -d)"
trap 'rm -rf "$VERIFY_TMP"' EXIT

fail() {
  echo "TLS VERIFY FAILED: $*" >&2
  exit 1
}

[ -d "$XC" ] || fail "missing $XC"
[ -f "$PACKAGE_FILE" ] || fail "missing $PACKAGE_FILE"

configs=()
while IFS= read -r file; do
  configs+=("$file")
done < <(find "$XC" -type f -path '*/Libavformat.framework/Headers/config.h' | LC_ALL=C sort)

[ "${#configs[@]}" -eq 5 ] ||
  fail "expected 5 Apple Libavformat slices, found ${#configs[@]}"

for required_path in \
  'ios-arm64/' \
  'ios-arm64_x86_64-simulator/' \
  'tvos-arm64_arm64e/' \
  'tvos-arm64_x86_64-simulator/' \
  'macos-arm64_x86_64/'; do
  printf '%s\n' "${configs[@]}" | grep -F "/$required_path" >/dev/null ||
    fail "missing slice $required_path"
done

required_macros=(
  CONFIG_SECURETRANSPORT
  CONFIG_NETWORK
  CONFIG_LIBSMBCLIENT
)

verified_arches=0
for config in "${configs[@]}"; do
  grep -Eq '^#define CONFIG_GNUTLS 0$' "$config" ||
    fail "$config does not disable GnuTLS for Libavformat"
  for macro in "${required_macros[@]}"; do
    grep -Eq "^#define $macro 1$" "$config" ||
      fail "$config does not enable $macro"
  done

  binary="${config%/Headers/config.h}/Libavformat"
  [ -f "$binary" ] || fail "missing $binary"

  read -r -a binary_arches <<<"$(lipo -archs "$binary")"
  [ "${#binary_arches[@]}" -gt 0 ] || fail "could not enumerate architectures in $binary"

  for arch in "${binary_arches[@]}"; do
    thin="$VERIFY_TMP/libavformat-$verified_arches-$arch"
    if [ "${#binary_arches[@]}" -eq 1 ]; then
      cp "$binary" "$thin"
    else
      lipo "$binary" -thin "$arch" -output "$thin"
    fi

    strings "$thin" | grep -F -- '--enable-securetransport' >/dev/null ||
      fail "$binary [$arch] lacks --enable-securetransport"
    strings "$thin" | grep -F -- '--disable-gnutls' >/dev/null ||
      fail "$binary [$arch] lacks --disable-gnutls"

    defined_symbols="$(xcrun nm -g "$thin" 2>/dev/null)" ||
      fail "could not inspect defined symbols in $binary [$arch]"
    undefined_symbols="$(xcrun nm -u "$thin" 2>/dev/null)" ||
      fail "could not inspect imported symbols in $binary [$arch]"

    # Component enablement is emitted into FFmpeg's build-only config_components.h,
    # which MPVKit does not package. Verify the linked binary instead of asking the
    # public config.h for macros it cannot contain.
    for symbol in _ff_http_protocol _ff_https_protocol _ff_tls_protocol _ff_hls_demuxer; do
      grep -Fq "$symbol" <<<"$defined_symbols" ||
        fail "$binary [$arch] lacks $symbol"
    done
    for symbol in _SSLCreateContext _SSLSetPeerDomainName _SSLCopyPeerTrust _SecTrustEvaluate; do
      grep -Fq "$symbol" <<<"$undefined_symbols" ||
        fail "$binary [$arch] lacks SecureTransport import $symbol"
    done

    if grep -Eq '(_ff_gnutls_|_gnutls_)' <<<"$defined_symbols"$'\n'"$undefined_symbols"; then
      fail "$binary [$arch] still contains a GnuTLS Libavformat reference"
    fi
    verified_arches=$((verified_arches + 1))
  done
done

[ "$verified_arches" -eq 9 ] ||
  fail "expected 9 Apple Libavformat architectures, verified $verified_arches"

command -v jq >/dev/null || fail "jq is required to verify Package.swift structurally"
PACKAGE_JSON="$VERIFY_TMP/package.json"
swift package dump-package --package-path "$PKG" >"$PACKAGE_JSON" ||
  fail "SwiftPM could not parse $PACKAGE_FILE"
jq -e '
  .targets[]
  | select(.name == "_FFmpeg-GPL")
  | any(.settings[]?; .kind.linkedFramework._0 == "Security")
' "$PACKAGE_JSON" >/dev/null ||
  fail "_FFmpeg-GPL does not link Security.framework"
for dependency in Libsmbclient gmp nettle hogweed gnutls; do
  jq -e --arg dependency "$dependency" '
    .targets[]
    | select(.name == "_FFmpeg-GPL")
    | [.dependencies[]?.byName[0]]
    | index($dependency) != null
  ' "$PACKAGE_JSON" >/dev/null ||
    fail "_FFmpeg-GPL lost required SMB dependency $dependency"
done

echo "TLS VERIFY PASSED: 5 Apple slices and 9 architectures use SecureTransport"
shasum -a 256 "$XC/Info.plist" | sed 's/^/  xcframework Info.plist: /'
