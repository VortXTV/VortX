#!/usr/bin/env bash
# Build the Rust `stremiox-core` FFI crate for tvOS and iOS (device + simulator) and package it as an
# .xcframework the Xcode apps link (like NodeMobile). Requires: Rust nightly + rust-src, Xcode.
#   tvOS is a tier-3 Rust target, so std is built from source via -Z build-std.
#   iOS is tier-2, so its std is prebuilt: just add the targets, no build-std.
set -euo pipefail
# stremiox-core is proprietary + lives in a PRIVATE repo. Resolve its checkout: STREMIOX_CORE_DIR env,
# else a sibling ../../stremiox-core clone, else the legacy in-repo ../core (removed from the public repo).
_SD="$(cd "$(dirname "$0")" && pwd)"
# Capture the repo root BEFORE the `cd "$CORE_DIR"` below. OUT used to be relative ("../app/Vendor"),
# which was only ever correct for the legacy in-repo ./core layout, where ../app/Vendor happened to be
# the repo's own Vendor dir. With the core in a SIBLING checkout it resolved to <sibling-parent>/app/
# Vendor, i.e. outside the repo, so the build wrote the fresh xcframework somewhere nothing links and
# the app silently kept linking a stale one. Absolute against the repo root is correct for BOTH layouts.
REPO_ROOT="$(cd "$_SD/.." && pwd)"
CORE_DIR="${STREMIOX_CORE_DIR:-}"
if [ -z "$CORE_DIR" ]; then
  for c in "$_SD/../../stremiox-core" "$_SD/../core"; do
    if [ -f "$c/Cargo.toml" ]; then CORE_DIR="$c"; break; fi
  done
fi
if [ -z "$CORE_DIR" ] || [ ! -f "$CORE_DIR/Cargo.toml" ]; then
  echo "ERROR: stremiox-core crate not found. Set STREMIOX_CORE_DIR or clone VortXTV/stremiox-core to ../../stremiox-core." >&2
  exit 1
fi
CORE_DIR="$(cd "$CORE_DIR" && pwd)"   # absolute, so logs and any later use do not depend on the CWD
echo "core workspace: $CORE_DIR"
cd "$CORE_DIR"
source "$HOME/.cargo/env" 2>/dev/null || true

BUILDSTD="-Z build-std=std,panic_abort"
# --locked on every cargo build: the engine repo tracks Cargo.lock, so a drifted dependency
# resolution FAILS the build here instead of silently linking a different graph than CI proved.
LOCKED="--locked"
LIB="libstremiox_core.a"
OUT="$REPO_ROOT/app/Vendor/StremioXCore.xcframework"   # Vendor/ is gitignored; produced by this script

# Apple deployment floors - MUST match app/project.yml (tvOS 18.0, iOS 16.0, macOS 14.0). Exported so
# the Cargo + build-std COMPILATION stamps LC_BUILD_VERSION.minos on the OBJECTS THEMSELVES (rustc reads
# the per-platform var; simulator triples read their device sibling's var), not merely the ld -r relabel.
export TVOS_DEPLOYMENT_TARGET=18.0
export IPHONEOS_DEPLOYMENT_TARGET=16.0
export MACOSX_DEPLOYMENT_TARGET=14.0

rustup +nightly-2026-07-19 target add aarch64-apple-ios aarch64-apple-ios-sim 2>/dev/null || true

echo "▸ tvOS device (aarch64-apple-tvos)"
SDKROOT="$(xcrun --sdk appletvos --show-sdk-path)" \
  cargo +nightly-2026-07-19 build $LOCKED $BUILDSTD --target aarch64-apple-tvos --release

echo "▸ tvOS simulator (aarch64-apple-tvos-sim)"
SDKROOT="$(xcrun --sdk appletvsimulator --show-sdk-path)" \
  cargo +nightly-2026-07-19 build $LOCKED $BUILDSTD --target aarch64-apple-tvos-sim --release

echo "▸ iOS device (aarch64-apple-ios)"
SDKROOT="$(xcrun --sdk iphoneos --show-sdk-path)" \
  cargo +nightly-2026-07-19 build $LOCKED --target aarch64-apple-ios --release

echo "▸ iOS simulator (aarch64-apple-ios-sim)"
SDKROOT="$(xcrun --sdk iphonesimulator --show-sdk-path)" \
  cargo +nightly-2026-07-19 build $LOCKED --target aarch64-apple-ios-sim --release

# Native macOS slice for the Mac app (NOT Catalyst, which MPVKit can't link). Built with the same
# build-std=panic_abort as tvOS, NOT the prebuilt (unwinding) std: MPVKit's Libdovi (a Rust lib)
# also defines _rust_eh_personality, and the macOS linker rejects the duplicate against an
# unwinding-std core. A panic=abort std core does not emit the conflicting personality.
echo "▸ macOS (aarch64-apple-darwin)"
cargo +nightly-2026-07-19 build $LOCKED $BUILDSTD --target aarch64-apple-darwin --release
# MPVKit's Libdovi (also Rust) defines _rust_eh_personality too, and the macOS linker rejects the
# duplicate against our core's global copy (iOS tolerates it). Partial-link the darwin archive into
# one object with that symbol made LOCAL, then re-archive: our refs still resolve in-archive, but it
# no longer exports a clashing global. Only the macOS slice needs this.
DARWIN="target/aarch64-apple-darwin/release"
# Retain the pre-localization archive at a stable, cacheable, $REPO_ROOT-absolute path BEFORE localizing,
# and feed ld -r FROM it, so the localized object's OSO/debug-map references a file that still exists at
# dsymutil time on both cold and cache-warm CI (release-tvos.yml caches this dir with the xcframework key).
RETAINED="$REPO_ROOT/app/Vendor/engine-prelocalize/StremioXCore/aarch64-apple-darwin"
mkdir -p "$RETAINED"
cp "$DARWIN/$LIB" "$RETAINED/$LIB"
ld -r -arch arm64 -platform_version macos 14.0 14.0 -all_load "$RETAINED/$LIB" -unexported_symbol _rust_eh_personality -o "$DARWIN/core_localized.o"
rm -f "$DARWIN/$LIB"
libtool -static -o "$DARWIN/$LIB" "$DARWIN/core_localized.o"

echo "▸ packaging $OUT"
rm -rf "$OUT"
xcodebuild -create-xcframework \
  -library "target/aarch64-apple-tvos/release/$LIB"     -headers include \
  -library "target/aarch64-apple-tvos-sim/release/$LIB" -headers include \
  -library "target/aarch64-apple-ios/release/$LIB"      -headers include \
  -library "target/aarch64-apple-ios-sim/release/$LIB"  -headers include \
  -library "target/aarch64-apple-darwin/release/$LIB"   -headers include \
  -output "$OUT"
echo "OK: $OUT (tvOS + iOS + macOS slices)"
