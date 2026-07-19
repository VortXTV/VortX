#!/usr/bin/env bash
# Build the vortx-core engine ABI (the Rust `vortx-ffi` staticlib) for the Apple platforms and
# package it as app/Vendor/VortxEngine.xcframework - the Phase 7/8 (engine/apple-cutover) sibling
# of build-core-xcframework.sh. Requires: Rust nightly + rust-src, Xcode.
#
# This produces EXACTLY the artifact app/project.yml links (see the VortxEngine.xcframework
# dependency on VortXiOSNative), which is deliberately NOT what the engine workspace's own
# vortx-core/scripts/build-ffi-xcframework.sh emits. The layout, per slice:
#
#   ios-arm64            SERVER-INCLUSIVE (kernel ABI + vortx_server_start/port/base_url/stop)
#   ios-arm64-simulator  SERVER-INCLUSIVE
#   tvos-arm64           SERVER-INCLUSIVE (unwalled by the engine's librqbit rust-tls swap; below)
#   tvos-arm64-simulator SERVER-INCLUSIVE
#   macos-arm64          KERNEL-ONLY (macOS runs the server as a spawned child; the desktop
#                        cutover branch owns that lane, so nothing here consumes a mac server)
#
# Feature selection (Phase 8): the server slices build the ffi crate with
# `--no-default-features --features server`. NOT the crate's full default set: the default `host`
# feature drags rquickjs (the QuickJS JS-plugin executor), and rquickjs-sys 0.12.1 ships NO
# prebuilt bindings for aarch64-apple-ios (build error: "couldn't read .../bindings/
# aarch64-apple-ios.rs"), and no Apple app target calls vortx_host_resolve_json anyway. Kernel +
# server is exactly the ABI the app links.
#
# tvOS tier-3 history (resolved): the SERVER feature originally did NOT cross-compile to
# aarch64-apple-tvos / aarch64-apple-tvos-sim. The wall was openssl-sys v0.9.117, reached via
#   librqbit v8.1.1 -> librqbit-sha1-wrapper v4.1.0 (default feature `sha1-crypto-hash`)
#     -> crypto-hash v0.3.4 -> openssl v0.10.81 -> openssl-sys v0.9.117
# (crypto-hash selects CommonCrypto only for target_os = macos/ios and falls back to OpenSSL for
# every other unix; tvOS is "other unix" to it and has no OpenSSL sysroot, so the build script
# aborted with "Could not find directory of OpenSSL installation", exit 101). FIXED engine-side
# (engine/vortx-core 5314577): crates/streaming-server declares librqbit with
# default-features = false and its `rust-tls` set (reqwest/rustls-tls + sha1-ring), keeping the
# whole TLS/SHA-1 stack pure-Rust (ring), so `--no-default-features --features server` now
# cross-compiles cleanly to BOTH tvOS triples. tvOS therefore ships SERVER-INCLUSIVE slices and
# VortXTV carries the VORTX_ENGINE_SERVER condition in project.yml (the real VortxNativeServer
# body compiles there, not the stubs). The `vortxNativeServer` runtime flag stays default OFF:
# nodejs-mobile keeps serving until the device-gated flip.
#
# Both tvOS targets are TIER 3 (no prebuilt std), which is why every slice here builds with
# `-Z build-std=std,panic_abort` from rust-src - the same flag the panic-abort C-boundary
# discipline already required on the tier-2 slices.
#
# Other invariants, unchanged from the Phase 7 script:
#   - Every slice builds against a panic_abort std so no panic can unwind across the C boundary.
#   - ALL non-vortx_* globals are localized per slice (ld -r + -exported_symbols_list). The app
#     already links StremioXCore (another Rust staticlib) and MPVKit's Libdovi (Rust as well);
#     any exported std/compiler-builtins symbol from this archive would be a duplicate at link
#     time. Only the vortx_* entry points stay global.
#   - Headers are nested as Headers/vortx/{vortx_ffi.h,module.modulemap}. A flat Headers/ would
#     collide with StremioXCore's module.modulemap in the shared Products/include copy step
#     ("Multiple commands produce ... module.modulemap"); project.yml points SWIFT_INCLUDE_PATHS
#     at $(BUILT_PRODUCTS_DIR)/include/vortx to discover the nested module instead.
#
# Usage:
#   build-ffi-xcframework.sh              # the Phase 8 layout above (server on the iOS + tvOS slices)
#   build-ffi-xcframework.sh --no-server  # EVERY slice kernel-only: the JSCore/wasm-shaped
#                                         # fallback route. Same slice set, no server symbols
#                                         # anywhere; a target built against it must NOT define
#                                         # VORTX_ENGINE_SERVER.
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

MODE=server
if [ "${1:-}" = "--no-server" ]; then MODE=kernel; fi

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
echo "engine workspace: $ENGINE_DIR (mode: $MODE)"

BUILDSTD="-Z build-std=std,panic_abort"
LIB="libvortx_ffi.a"
OUT="$REPO_ROOT/app/Vendor/VortxEngine.xcframework"
TARGET_DIR="${CARGO_TARGET_DIR:-$ENGINE_DIR/target}"

# Tier-2 targets install prebuilt components; the tier-3 tvOS triples have none to install
# (build-std compiles std from rust-src), so they are deliberately absent here.
rustup +nightly target add aarch64-apple-ios aarch64-apple-ios-sim 2>/dev/null || true

# The per-slice feature sets. `kernel` = the pure frozen kernel ABI; `server` = kernel + the
# 4-symbol in-process streaming server. See the header comment for why `host` is never built.
FEATURES_KERNEL="--no-default-features"
FEATURES_SERVER="--no-default-features --features server"

build_slice() { # <triple> <sdk> <kernel|server>
    local features="$FEATURES_KERNEL"
    [ "$3" = server ] && features="$FEATURES_SERVER"
    echo "- vortx-ffi $1 ($3)"
    SDKROOT="$(xcrun --sdk "$2" --show-sdk-path)" \
        cargo +nightly build $BUILDSTD --manifest-path "$ENGINE_DIR/Cargo.toml" \
        -p vortx-ffi $features --release --target "$1"
}

# What each slice carries in THIS mode (kernel mode strips the server everywhere; the --no-server
# fallback must stay able to produce an all-kernel artifact for the JSCore/wasm-shaped route).
IOS_KIND=server
TV_KIND=server
if [ "$MODE" = kernel ]; then IOS_KIND=kernel; TV_KIND=kernel; fi

build_slice aarch64-apple-ios       iphoneos          "$IOS_KIND"
build_slice aarch64-apple-ios-sim   iphonesimulator   "$IOS_KIND"
build_slice aarch64-apple-tvos      appletvos         "$TV_KIND"
build_slice aarch64-apple-tvos-sim  appletvsimulator  "$TV_KIND"
build_slice aarch64-apple-darwin    macosx            kernel

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
TVOS_SDK="$(xcrun --sdk appletvos --show-sdk-version)"
TVSIM_SDK="$(xcrun --sdk appletvsimulator --show-sdk-version)"
MAC_SDK="$(xcrun --sdk macosx --show-sdk-version)"
localize aarch64-apple-ios      ios             16.0 "$IOS_SDK"
localize aarch64-apple-ios-sim  ios-simulator   16.0 "$SIM_SDK"
localize aarch64-apple-tvos     tvos            16.0 "$TVOS_SDK"
localize aarch64-apple-tvos-sim tvos-simulator  16.0 "$TVSIM_SDK"
localize aarch64-apple-darwin   macos           14.0 "$MAC_SDK"

# Stage the nested header dir: Headers/vortx/{vortx_ffi.h,module.modulemap}. One header for every
# slice: it declares the server symbols unconditionally, and a target linking a kernel-only slice
# is fine as long as its Swift never REFERENCES them - which is exactly what the per-target
# VORTX_ENGINE_SERVER compilation condition enforces (see project.yml / VortxNativeServer.swift).
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
    -library "$TARGET_DIR/aarch64-apple-ios/release/$LIB"      -headers "$HDRS" \
    -library "$TARGET_DIR/aarch64-apple-ios-sim/release/$LIB"  -headers "$HDRS" \
    -library "$TARGET_DIR/aarch64-apple-tvos/release/$LIB"     -headers "$HDRS" \
    -library "$TARGET_DIR/aarch64-apple-tvos-sim/release/$LIB" -headers "$HDRS" \
    -library "$TARGET_DIR/aarch64-apple-darwin/release/$LIB"   -headers "$HDRS" \
    -output "$OUT"

echo "- slice audit (exports must be vortx_* only; server column from _vortx_server_start):"
for slice in ios-arm64 ios-arm64-simulator tvos-arm64 tvos-arm64-simulator macos-arm64; do
    syms="$(nm -gUj "$OUT/$slice/$LIB" | sort -u)"
    if echo "$syms" | grep -q '^_vortx_server_start$'; then kind=server-inclusive; else kind=kernel-only; fi
    echo "  $slice [$kind]: $(echo "$syms" | tr '\n' ' ')"
done
echo "OK: $OUT (iOS device+sim $IOS_KIND, tvOS device+sim $TV_KIND, macOS kernel-only; vortx_*-only exports)"
