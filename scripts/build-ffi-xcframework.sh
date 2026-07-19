#!/usr/bin/env bash
# Build the vortx-core engine ABI (the Rust `vortx-ffi` staticlib) for the Apple platforms and
# package it as app/Vendor/VortxEngine.xcframework - the Phase 7 (engine/apple-cutover) sibling of
# build-core-xcframework.sh. Requires: Rust nightly + rust-src, Xcode.
#
# This produces EXACTLY the artifact app/project.yml links (see the VortxEngine.xcframework
# dependency on VortXiOSNative), which is deliberately NOT what the engine workspace's own
# vortx-core/scripts/build-ffi-xcframework.sh emits. The differences, and why:
#   - iOS device + iOS simulator + macOS slices only. Those are the targets this branch links
#     (the shadow ranking diff runs in VortXiOSNative); no tvOS slices yet.
#   - KERNEL-ONLY build (--no-default-features). VortxBridge.swift drives the frozen vortx_* C
#     ABI only; the default `host` feature would drag tokio + reqwest into an Apple cross-compile
#     for no consumer.
#   - Every slice builds against a panic_abort std (-Z build-std=std,panic_abort) so no panic can
#     unwind across the C boundary, mirroring the stremio-core recipe.
#   - ALL non-vortx_* globals are localized per slice (ld -r + -exported_symbols_list). The app
#     already links StremioXCore (another Rust staticlib) and MPVKit's Libdovi (Rust as well);
#     any exported std/compiler-builtins symbol from this archive would be a duplicate at link
#     time. Only the 8 vortx_* entry points stay global.
#   - Headers are nested as Headers/vortx/{vortx_ffi.h,module.modulemap}. A flat Headers/ would
#     collide with StremioXCore's module.modulemap in the shared Products/include copy step
#     ("Multiple commands produce ... module.modulemap"); project.yml points SWIFT_INCLUDE_PATHS
#     at $(BUILT_PRODUCTS_DIR)/include/vortx to discover the nested module instead.
#
# Engine source resolution (first existing crates/ffi wins):
#   1. $VORTX_ENGINE_DIR                 - explicit override (CI passes the in-repo path)
#   2. <repo>/vortx-core                 - the vendored engine snapshot, once it carries crates/ffi
#   3. <repo>/../vortx-engine/vortx-core - a sibling engine checkout (local dev layout)
#   4. $HOME/vortx-engine/vortx-core     - the default local engine checkout
set -euo pipefail
cd "$(dirname "$0")/.."   # repo root
source "$HOME/.cargo/env" 2>/dev/null || true
REPO_ROOT="$(pwd)"

ENGINE_DIR="${VORTX_ENGINE_DIR:-}"
if [ -z "$ENGINE_DIR" ]; then
    for cand in "$REPO_ROOT/vortx-core" "$REPO_ROOT/../vortx-engine/vortx-core" "$HOME/vortx-engine/vortx-core"; do
        if [ -f "$cand/crates/ffi/Cargo.toml" ]; then ENGINE_DIR="$cand"; break; fi
    done
fi
if [ -z "$ENGINE_DIR" ] || [ ! -f "$ENGINE_DIR/crates/ffi/Cargo.toml" ]; then
    echo "ERROR: no vortx-ffi workspace found." >&2
    echo "  Looked at: \$VORTX_ENGINE_DIR, $REPO_ROOT/vortx-core," >&2
    echo "  $REPO_ROOT/../vortx-engine/vortx-core, $HOME/vortx-engine/vortx-core" >&2
    echo "  Each candidate must contain crates/ffi/Cargo.toml (the vortx-ffi crate)." >&2
    echo "  Point VORTX_ENGINE_DIR at a vortx-core workspace that carries the ffi crate." >&2
    exit 1
fi
ENGINE_DIR="$(cd "$ENGINE_DIR" && pwd)"
echo "engine workspace: $ENGINE_DIR"

BUILDSTD="-Z build-std=std,panic_abort"
LIB="libvortx_ffi.a"
OUT="$REPO_ROOT/app/Vendor/VortxEngine.xcframework"
TARGET_DIR="${CARGO_TARGET_DIR:-$ENGINE_DIR/target}"

rustup +nightly target add aarch64-apple-ios aarch64-apple-ios-sim 2>/dev/null || true

build_slice() { # <triple> <sdk>
    echo "- vortx-ffi $1 (kernel-only)"
    SDKROOT="$(xcrun --sdk "$2" --show-sdk-path)" \
        cargo +nightly build $BUILDSTD --manifest-path "$ENGINE_DIR/Cargo.toml" \
        -p vortx-ffi --no-default-features --release --target "$1"
}

build_slice aarch64-apple-ios     iphoneos
build_slice aarch64-apple-ios-sim iphonesimulator
build_slice aarch64-apple-darwin  macosx

# Localize every non-vortx_* global. Two other Rust staticlibs live in the same binaries
# (StremioXCore, MPVKit's Libdovi), so an exported std symbol (or _rust_eh_personality) is a
# guaranteed duplicate at link time. Partial-link each archive into one object exporting ONLY the
# vortx_* C ABI, then re-archive - same treatment build-core-xcframework.sh applies to its macOS
# slice, extended to every slice and to the whole export surface.
EXPORTS="$(mktemp)"
trap 'rm -f "$EXPORTS"; rm -rf "${HDRS:-}"' EXIT
printf '_vortx_*\n' > "$EXPORTS"

localize() { # <triple> <ld-platform> <minos> <sdkver>
    local dir="$TARGET_DIR/$1/release"
    ld -r -arch arm64 -platform_version "$2" "$3" "$4" -all_load "$dir/$LIB" \
        -exported_symbols_list "$EXPORTS" -o "$dir/vortx_ffi_localized.o"
    rm -f "$dir/$LIB"
    libtool -static -o "$dir/$LIB" "$dir/vortx_ffi_localized.o"
}

IOS_SDK="$(xcrun --sdk iphoneos --show-sdk-version)"
SIM_SDK="$(xcrun --sdk iphonesimulator --show-sdk-version)"
MAC_SDK="$(xcrun --sdk macosx --show-sdk-version)"
localize aarch64-apple-ios     ios           16.0 "$IOS_SDK"
localize aarch64-apple-ios-sim ios-simulator 16.0 "$SIM_SDK"
localize aarch64-apple-darwin  macos         14.0 "$MAC_SDK"

# Stage the nested header dir: Headers/vortx/{vortx_ffi.h,module.modulemap}.
HDRS="$(mktemp -d)"
mkdir -p "$HDRS/vortx"
cp "$ENGINE_DIR/crates/ffi/include/vortx_ffi.h" "$HDRS/vortx/"
cat > "$HDRS/vortx/module.modulemap" <<'EOF'
module VortxEngine {
    header "vortx_ffi.h"
    export *
}
EOF

echo "- packaging $OUT"
mkdir -p "$REPO_ROOT/app/Vendor"
rm -rf "$OUT"
xcodebuild -create-xcframework \
    -library "$TARGET_DIR/aarch64-apple-ios/release/$LIB"     -headers "$HDRS" \
    -library "$TARGET_DIR/aarch64-apple-ios-sim/release/$LIB" -headers "$HDRS" \
    -library "$TARGET_DIR/aarch64-apple-darwin/release/$LIB"  -headers "$HDRS" \
    -output "$OUT"

echo "- exported globals per slice (must be vortx_* only):"
for slice in ios-arm64 ios-arm64-simulator macos-arm64; do
    echo "  $slice: $(nm -gUj "$OUT/$slice/$LIB" | sort -u | tr '\n' ' ')"
done
echo "OK: $OUT (iOS device + iOS simulator + macOS slices, kernel-only, vortx_*-only exports)"
