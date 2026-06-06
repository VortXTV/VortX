#!/usr/bin/env bash
# Build the Rust `stremiox-core` FFI crate for tvOS (device + simulator) and package it as an
# .xcframework the Xcode app links (like NodeMobile). Requires: Rust nightly + rust-src, Xcode.
#   tvOS is a tier-3 Rust target, so std is built from source via -Z build-std.
set -euo pipefail
cd "$(dirname "$0")/../core"
source "$HOME/.cargo/env" 2>/dev/null || true
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

BUILDSTD="-Z build-std=std,panic_abort"
LIB="libstremiox_core.a"
OUT="../app/Vendor/StremioXCore.xcframework"   # Vendor/ is gitignored; produced by this script

echo "▸ tvOS device (aarch64-apple-tvos)"
SDKROOT="$(xcrun --sdk appletvos --show-sdk-path)" \
  cargo +nightly build $BUILDSTD --target aarch64-apple-tvos --release

echo "▸ tvOS simulator (aarch64-apple-tvos-sim)"
SDKROOT="$(xcrun --sdk appletvsimulator --show-sdk-path)" \
  cargo +nightly build $BUILDSTD --target aarch64-apple-tvos-sim --release

echo "▸ packaging $OUT"
rm -rf "$OUT"
xcodebuild -create-xcframework \
  -library "target/aarch64-apple-tvos/release/$LIB"     -headers include \
  -library "target/aarch64-apple-tvos-sim/release/$LIB" -headers include \
  -output "$OUT"
echo "OK: $OUT"
