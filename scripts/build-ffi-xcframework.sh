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
#   - Non-vortx_* public globals are hidden per slice (ld -r + -exported_symbols_list). The app
#     already links StremioXCore (another Rust staticlib) and MPVKit's Libdovi (Rust as well);
#     any exported std/compiler-builtins symbol from this archive would be a duplicate at link
#     time. Only vortx_* entry points stay public; SDK common symbols may remain private externs.
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
#   3. <canonical-app>/../vortx-core/vortx-core (also from a registered app worktree)
set -euo pipefail
cd "$(dirname "$0")/.."   # repo root
# Rust may already be on PATH without rustup's optional shell initializer.
# A missing source file is fatal in the system Bash even with `|| true`.
if [[ -f "$HOME/.cargo/env" ]]; then
    source "$HOME/.cargo/env"
fi
REPO_ROOT="$(pwd)"

MODE=server
RESOURCE_HOST=0
VERIFY_STATE=0
STAGED_MACOS=0
STAGED_OUT_ROOT=""
STAGED_PRELOCALIZE_ROOT=""
STAGED_TARGET_DIR=""
STAGED_ENGINE_REVISION=""
STAGED_ABI_REVIEW=""
SEEN_STAGED=0
SEEN_OUT=0
SEEN_PRELOCALIZE=0
SEEN_TARGET=0
SEEN_REVISION=0
SEEN_ABI_REVIEW=0
for argument in "$@"; do
    case "$argument" in
        --no-server) MODE=kernel ;;
        --state-bridge) VERIFY_STATE=1 ;;
        --resource-host) RESOURCE_HOST=1; VERIFY_STATE=1 ;;
        --staged-macos-arm64) [[ "$SEEN_STAGED" == 0 ]] || { echo "repeated staged mode" >&2; exit 2; }; SEEN_STAGED=1; STAGED_MACOS=1 ;;
        --staged-output-root=*) [[ "$SEEN_OUT" == 0 ]] || { echo "repeated staged output root" >&2; exit 2; }; SEEN_OUT=1; STAGED_OUT_ROOT="${argument#*=}" ;;
        --staged-prelocalize-root=*) [[ "$SEEN_PRELOCALIZE" == 0 ]] || { echo "repeated staged prelocalize root" >&2; exit 2; }; SEEN_PRELOCALIZE=1; STAGED_PRELOCALIZE_ROOT="${argument#*=}" ;;
        --staged-target-dir=*) [[ "$SEEN_TARGET" == 0 ]] || { echo "repeated staged target dir" >&2; exit 2; }; SEEN_TARGET=1; STAGED_TARGET_DIR="${argument#*=}" ;;
        --engine-revision=*) [[ "$SEEN_REVISION" == 0 ]] || { echo "repeated engine revision" >&2; exit 2; }; SEEN_REVISION=1; STAGED_ENGINE_REVISION="${argument#*=}" ;;
        --abi-review-report=*) [[ "$SEEN_ABI_REVIEW" == 0 ]] || { echo "repeated ABI review report" >&2; exit 2; }; SEEN_ABI_REVIEW=1; STAGED_ABI_REVIEW="${argument#*=}" ;;
        *) echo "Unknown option: $argument" >&2; exit 1 ;;
    esac
done

if [ "$STAGED_MACOS" != 1 ] && { [ "$SEEN_OUT" = 1 ] || [ "$SEEN_PRELOCALIZE" = 1 ] || [ "$SEEN_TARGET" = 1 ] || [ "$SEEN_REVISION" = 1 ] || [ "$SEEN_ABI_REVIEW" = 1 ]; }; then
    echo "staged-only arguments require --staged-macos-arm64" >&2
    exit 2
fi

if [ "$STAGED_MACOS" != 1 ] && [[ -f "$HOME/.cargo/env" ]]; then source "$HOME/.cargo/env"; fi
if [ "$STAGED_MACOS" = 1 ]; then
    [[ -n "${VORTX_ENGINE_DIR:-}" ]] || { echo "staged macOS FFI requires explicit VORTX_ENGINE_DIR" >&2; exit 2; }
fi
source "$REPO_ROOT/scripts/resolve-native-engine.sh"
ENGINE_DIR=$(resolve_native_engine "$REPO_ROOT" ffi)
echo "engine workspace: $ENGINE_DIR (mode: $MODE)"

if [ "$STAGED_MACOS" = 1 ]; then
    fail_staged() { echo "staged macOS FFI: $*" >&2; exit 2; }
    # BEGIN staged engine workspace guard
    validate_staged_engine_workspace() {
        ENGINE_PHYSICAL="$1"
        ENGINE_GIT_ROOT="$(git -C "$ENGINE_PHYSICAL" rev-parse --show-toplevel)"
        if [[ "$ENGINE_PHYSICAL" == "$ENGINE_GIT_ROOT" ]]; then
            ENGINE_TRACKED_PREFIX=""
        elif [[ "$ENGINE_PHYSICAL" == "$ENGINE_GIT_ROOT/vortx-core" ]]; then
            ENGINE_TRACKED_PREFIX="vortx-core/"
        else
            fail_staged "Cargo workspace must be the exact Git root or its tracked vortx-core child"
        fi
        local required
        for required in Cargo.toml Cargo.lock crates/ffi/Cargo.toml crates/ffi/include/vortx_ffi.h; do
            [[ -f "$ENGINE_PHYSICAL/$required" && ! -L "$ENGINE_PHYSICAL/$required" ]] || fail_staged "required engine input is missing or a symlink: $required"
        done
        git -C "$ENGINE_GIT_ROOT" ls-files --error-unmatch -- \
            "${ENGINE_TRACKED_PREFIX}Cargo.toml" "${ENGINE_TRACKED_PREFIX}Cargo.lock" \
            "${ENGINE_TRACKED_PREFIX}crates/ffi/Cargo.toml" \
            "${ENGINE_TRACKED_PREFIX}crates/ffi/include/vortx_ffi.h" >/dev/null 2>&1 || \
            fail_staged "required Cargo workspace and FFI inputs must be tracked in the owning Git worktree"
    }
    # END staged engine workspace guard
    [[ "$MODE" == server && "$RESOURCE_HOST" == 1 && "$VERIFY_STATE" == 1 ]] || fail_staged "staged macOS slice requires --resource-host (which also enables the state bridge)"
    [[ -n "$STAGED_OUT_ROOT" && -n "$STAGED_PRELOCALIZE_ROOT" && -n "$STAGED_TARGET_DIR" && -n "$STAGED_ENGINE_REVISION" && -n "$STAGED_ABI_REVIEW" ]] || fail_staged "output, prelocalize, target, engine revision and ABI review report are required"
    [[ "$STAGED_ENGINE_REVISION" =~ ^[0-9a-f]{40}$ ]] || fail_staged "engine revision must be a full lowercase 40-hex commit"

    canonical_fresh_path() { # absolute fresh leaf with existing physical parent
        local candidate="$1" parent leaf physical
        [[ "$candidate" = /* && "$candidate" != *"/../"* && "$candidate" != */.. && "$candidate" != */. && "$candidate" != *"/./"* ]] || fail_staged "paths must be absolute normalized leaf paths: $candidate"
        parent="${candidate%/*}"; leaf="${candidate##*/}"
        [[ -n "$leaf" && -d "$parent" ]] || fail_staged "path parent must already exist: $candidate"
        physical="$(cd "$parent" && pwd -P)" || fail_staged "cannot resolve path parent: $candidate"
        [[ "$parent" == "$physical" ]] || fail_staged "destination parents may not traverse symlinks: $candidate"
        candidate="$physical/$leaf"
        [[ ! -e "$candidate" && ! -L "$candidate" ]] || fail_staged "destination must be fresh and absent: $candidate"
        printf '%s\n' "$candidate"
    }
    STAGED_OUT_ROOT="$(canonical_fresh_path "$STAGED_OUT_ROOT")"
    STAGED_PRELOCALIZE_ROOT="$(canonical_fresh_path "$STAGED_PRELOCALIZE_ROOT")"
    STAGED_TARGET_DIR="$(canonical_fresh_path "$STAGED_TARGET_DIR")"
    REPO_PHYSICAL="$(cd "$REPO_ROOT" && pwd -P)"
    ENGINE_PHYSICAL="$(cd "$ENGINE_DIR" && pwd -P)"
    REQUESTED_ENGINE_PHYSICAL="$(cd "$VORTX_ENGINE_DIR" && pwd -P)" || fail_staged "cannot resolve VORTX_ENGINE_DIR"
    [[ "$ENGINE_PHYSICAL" == "$REQUESTED_ENGINE_PHYSICAL" ]] || fail_staged "resolved engine differs from explicit VORTX_ENGINE_DIR"
    validate_staged_engine_workspace "$ENGINE_PHYSICAL"
    COMMON_DIR="$(git -C "$REPO_PHYSICAL" rev-parse --path-format=absolute --git-common-dir)"
    CANONICAL_APP_ROOT="$(cd "$COMMON_DIR/.." && pwd -P)"
    WORKSPACE_PHYSICAL="$(cd "$CANONICAL_APP_ROOT/.." && pwd -P)"
    RECOVERY_PHYSICAL="$WORKSPACE_PHYSICAL/_recovery"
    [[ -d "$RECOVERY_PHYSICAL" ]] || fail_staged "workspace recovery root is missing"
    [[ -f "$STAGED_ABI_REVIEW" && ! -L "$STAGED_ABI_REVIEW" ]] || fail_staged "ABI review report must be a regular non-symlink file"
    ABI_REVIEW_PHYSICAL="$(cd "${STAGED_ABI_REVIEW%/*}" && pwd -P)/${STAGED_ABI_REVIEW##*/}"
    case "$ABI_REVIEW_PHYSICAL" in "$RECOVERY_PHYSICAL/"*) ;; *) fail_staged "ABI review report must be inside workspace _recovery" ;; esac
    APP_VENDOR="$REPO_PHYSICAL/app/Vendor"
    ENGINE_DEFAULT_TARGET="$ENGINE_PHYSICAL/target"
    ENGINE_DEFAULT_PRELOCALIZE="$REPO_PHYSICAL/app/Vendor/engine-prelocalize"
    path_overlaps() { case "$1/" in "$2/"*|"$2"/) return 0;; esac; case "$2/" in "$1/"*) return 0;; esac; return 1; }
    for candidate in "$STAGED_OUT_ROOT" "$STAGED_PRELOCALIZE_ROOT" "$STAGED_TARGET_DIR"; do
        case "$candidate/" in "$RECOVERY_PHYSICAL/"*) ;; *) fail_staged "all output roots must be below the workspace _recovery directory: $candidate" ;; esac
        path_overlaps "$candidate" "$REPO_PHYSICAL" && fail_staged "destination may not be inside or contain the app repository: $candidate"
        path_overlaps "$candidate" "$ENGINE_PHYSICAL" && fail_staged "destination may not be inside or contain the private engine checkout: $candidate"
        path_overlaps "$candidate" "$APP_VENDOR" && fail_staged "Vendor is protected: $candidate"
        path_overlaps "$candidate" "$ENGINE_DEFAULT_TARGET" && fail_staged "default engine target is protected: $candidate"
        path_overlaps "$candidate" "$ENGINE_DEFAULT_PRELOCALIZE" && fail_staged "default prelocalize output is protected: $candidate"
    done
    path_overlaps "$STAGED_OUT_ROOT" "$STAGED_PRELOCALIZE_ROOT" && fail_staged "output roots overlap"
    path_overlaps "$STAGED_OUT_ROOT" "$STAGED_TARGET_DIR" && fail_staged "output and target roots overlap"
    path_overlaps "$STAGED_PRELOCALIZE_ROOT" "$STAGED_TARGET_DIR" && fail_staged "prelocalize and target roots overlap"

    ENGINE_HEAD="$(git -C "$ENGINE_PHYSICAL" rev-parse HEAD)"
    [[ "$ENGINE_HEAD" == "$STAGED_ENGINE_REVISION" ]] || fail_staged "engine HEAD differs from requested revision"
    [[ -z "$(git -C "$ENGINE_PHYSICAL" status --porcelain --untracked-files=all)" ]] || fail_staged "engine worktree must be clean"
    STAGED_HEADER_HASH="$(shasum -a 256 "$ENGINE_PHYSICAL/crates/ffi/include/vortx_ffi.h" | awk '{print $1}')"
    STAGED_LOCK_HASH="$(shasum -a 256 "$ENGINE_PHYSICAL/Cargo.lock" | awk '{print $1}')"
    STAGED_BUILDER_HASH="$(shasum -a 256 "$REPO_PHYSICAL/scripts/build-ffi-xcframework.sh" | awk '{print $1}')"
    STAGED_RESOLVER_HASH="$(shasum -a 256 "$REPO_PHYSICAL/scripts/resolve-native-engine.sh" | awk '{print $1}')"
    STAGED_TOOLCHAIN_ENV_HASH="$(shasum -a 256 "$REPO_PHYSICAL/scripts/native-rust-toolchain-env.sh" | awk '{print $1}')"
    STAGED_ARTIFACT_VERIFIER_HASH="$(shasum -a 256 "$REPO_PHYSICAL/scripts/verify-apple-engine-artifacts.sh" | awk '{print $1}')"
    STAGED_ABI_VERIFIER_HASH="$(shasum -a 256 "$REPO_PHYSICAL/scripts/verify-native-engine-abi.sh" | awk '{print $1}')"
    STAGED_ABI_REVIEW_HASH="$(shasum -a 256 "$ABI_REVIEW_PHYSICAL" | awk '{print $1}')"
    # Claim all three fresh roots exclusively before any native/toolchain command.
    mkdir -m 700 "$STAGED_OUT_ROOT" || fail_staged "could not exclusively claim output root"
    mkdir -m 700 "$STAGED_PRELOCALIZE_ROOT" || fail_staged "could not exclusively claim prelocalize root"
    mkdir -m 700 "$STAGED_TARGET_DIR" || fail_staged "could not exclusively claim Cargo target root"
    [[ -d "$STAGED_OUT_ROOT" && -d "$STAGED_PRELOCALIZE_ROOT" && -d "$STAGED_TARGET_DIR" ]] || fail_staged "claimed output roots changed type"
    [[ ! -e "$STAGED_OUT_ROOT/BUILD-RECEIPT.json" && ! -L "$STAGED_OUT_ROOT/BUILD-RECEIPT.json" ]] || fail_staged "receipt path already exists"
    export CARGO_TARGET_DIR="$STAGED_TARGET_DIR"
else
    # Default route retains its existing shell setup and all five-slice behavior.
    :
fi

BUILDSTD="-Z build-std=std,panic_abort"
LIB="libvortx_ffi.a"
if [ "$STAGED_MACOS" = 1 ]; then
    OUT="$STAGED_OUT_ROOT/VortxEngine.xcframework"
    TARGET_DIR="$STAGED_TARGET_DIR"
else
    OUT="$REPO_ROOT/app/Vendor/VortxEngine.xcframework"
    TARGET_DIR="${CARGO_TARGET_DIR:-$ENGINE_DIR/target}"
fi

# Apple deployment floors - MUST match app/project.yml (tvOS 18.0, iOS 16.0, macOS 14.0). Exported so
# every build_slice (incl. -Z build-std) stamps the OBJECTS' LC_BUILD_VERSION.minos, not just the ld -r
# relabel below. rustc reads the per-platform var; sim triples read their device sibling's var.
export TVOS_DEPLOYMENT_TARGET=18.0
export IPHONEOS_DEPLOYMENT_TARGET=16.0
export MACOSX_DEPLOYMENT_TARGET=14.0

# Bundled rust-objcopy may have an RPATH relative to its nested rustlib/bin
# directory, while LLVM lives in the toolchain root's lib. Fail before builds
# if the installed pinned tools cannot load, and keep the lookup command-scoped.
source "$REPO_ROOT/scripts/native-rust-toolchain-env.sh"
NATIVE_RUST_LLVM_PATH="$(native_rust_llvm_library_path nightly-2026-07-19)"

# Tier-2 targets install prebuilt components; the tier-3 tvOS triples have none to install
# (build-std compiles std from rust-src), so they are deliberately absent here.
if [ "$STAGED_MACOS" != 1 ]; then
    rustup +nightly-2026-07-19 target add aarch64-apple-ios aarch64-apple-ios-sim 2>/dev/null || true
fi

# The per-slice feature sets. `kernel` = the pure frozen kernel ABI; `server` = kernel + the
# 4-symbol in-process streaming server. See the header comment for why `host` is never built.
FEATURES_KERNEL="--no-default-features"
FEATURES_SERVER="--no-default-features --features server"
if [ "$RESOURCE_HOST" = 1 ]; then
    FEATURES_KERNEL="--no-default-features --features resource-host"
    FEATURES_SERVER="--no-default-features --features server,resource-host"
fi

build_slice() { # <triple> <sdk> <kernel|server>
    local features="$FEATURES_KERNEL"
    [ "$3" = server ] && features="$FEATURES_SERVER"
    echo "- vortx-ffi $1 ($3)"
    # --locked: the engine workspace tracks Cargo.lock, so a drifted dependency resolution FAILS
    # the build here instead of silently linking a different graph than CI proved.
    CARGO_PROFILE_RELEASE_PANIC=abort \
    DYLD_LIBRARY_PATH="$NATIVE_RUST_LLVM_PATH" \
    SDKROOT="$(xcrun --sdk "$2" --show-sdk-path)" \
        cargo +nightly-2026-07-19 build --locked $BUILDSTD --manifest-path "$ENGINE_DIR/Cargo.toml" \
        -p vortx-ffi $features --release --target "$1"
}

# Localize every non-vortx_* global. Two other Rust staticlibs live in the same binaries
# (StremioXCore, MPVKit's Libdovi), so an exported std symbol (or _rust_eh_personality) is a
# guaranteed duplicate at link time. Partial-link each archive into one object exporting ONLY the
# vortx_* C ABI, then re-archive - same treatment build-core-xcframework.sh applies to its macOS
# slice, extended to every slice and to the whole export surface.
EXPORTS="$(mktemp)"
trap 'rm -f "$EXPORTS"; rm -rf "${HDRS:-}"' EXIT
printf '_vortx_*\n' > "$EXPORTS"
# Stable, cacheable, $REPO_ROOT-absolute retain root for the pre-localization archives (one per slice).
# Deliberately NOT in the EXIT trap above: these must survive to app-link/dsymutil time and into the CI
# cache so every localized object's OSO/debug-map still resolves on cold AND cache-warm runs.
if [ "$STAGED_MACOS" = 1 ]; then
    RETAINED_FFI="$STAGED_PRELOCALIZE_ROOT/VortxEngine"
else
    RETAINED_FFI="$REPO_ROOT/app/Vendor/engine-prelocalize/VortxEngine"
fi

localize() { # <triple> <ld-platform> <minos> <sdkver>
    local dir="$TARGET_DIR/$1/release"
    local keep="$RETAINED_FFI/$1"
    mkdir -p "$keep"
    cp "$dir/$LIB" "$keep/$LIB"                   # retain pre-localization archive (stable path) BEFORE ld -r overwrites $dir/$LIB
    ld -r -arch arm64 -platform_version "$2" "$3" "$4" -all_load "$keep/$LIB" \
        -exported_symbols_list "$EXPORTS" -o "$dir/vortx_ffi_localized.o"
    rm -f "$dir/$LIB"
    libtool -static -o "$dir/$LIB" "$dir/vortx_ffi_localized.o"
}

if [ "$STAGED_MACOS" = 1 ]; then
    # This opt-in path owns only the explicitly declared fresh roots. It does not touch Vendor,
    # the engine's default target, or the full-matrix retained archive tree.
    SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
    SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
    CARGO_NET_OFFLINE=true CARGO_BUILD_JOBS=1 CARGO_PROFILE_RELEASE_PANIC=abort DYLD_LIBRARY_PATH="$NATIVE_RUST_LLVM_PATH" \
        SDKROOT="$SDKROOT" cargo +nightly-2026-07-19 build --locked --offline -j 1 $BUILDSTD \
        --manifest-path "$ENGINE_DIR/Cargo.toml" -p vortx-ffi $FEATURES_KERNEL --release \
        --target aarch64-apple-darwin
    localize aarch64-apple-darwin macos 14.0 "$SDK_VERSION"
    HDRS="$STAGED_OUT_ROOT/headers"
    mkdir -p "$HDRS/vortx"
    cp "$ENGINE_DIR/crates/ffi/include/vortx_ffi.h" "$HDRS/vortx/"
    cat > "$HDRS/vortx/module.modulemap" <<'EOF'
module VortxEngine {
    header "vortx_ffi.h"
    export *
}
EOF
    xcodebuild -create-xcframework \
        -library "$TARGET_DIR/aarch64-apple-darwin/release/$LIB" -headers "$HDRS" \
        -output "$OUT"
    # Recheck source identity before stamping the output receipt.
    [[ "$(git -C "$ENGINE_PHYSICAL" rev-parse HEAD)" == "$STAGED_ENGINE_REVISION" ]] || fail_staged "engine HEAD changed during build"
    [[ -z "$(git -C "$ENGINE_PHYSICAL" status --porcelain --untracked-files=all)" ]] || fail_staged "engine worktree changed during build"
    [[ "$(shasum -a 256 "$ENGINE_PHYSICAL/crates/ffi/include/vortx_ffi.h" | awk '{print $1}')" == "$STAGED_HEADER_HASH" ]] || fail_staged "FFI header changed during build"
    [[ "$(shasum -a 256 "$ENGINE_PHYSICAL/Cargo.lock" | awk '{print $1}')" == "$STAGED_LOCK_HASH" ]] || fail_staged "Cargo.lock changed during build"
    [[ "$(shasum -a 256 "$REPO_PHYSICAL/scripts/build-ffi-xcframework.sh" | awk '{print $1}')" == "$STAGED_BUILDER_HASH" ]] || fail_staged "builder changed during build"
    [[ "$(shasum -a 256 "$REPO_PHYSICAL/scripts/resolve-native-engine.sh" | awk '{print $1}')" == "$STAGED_RESOLVER_HASH" ]] || fail_staged "engine resolver changed during build"
    [[ "$(shasum -a 256 "$REPO_PHYSICAL/scripts/native-rust-toolchain-env.sh" | awk '{print $1}')" == "$STAGED_TOOLCHAIN_ENV_HASH" ]] || fail_staged "toolchain environment helper changed during build"
    [[ "$(shasum -a 256 "$REPO_PHYSICAL/scripts/verify-apple-engine-artifacts.sh" | awk '{print $1}')" == "$STAGED_ARTIFACT_VERIFIER_HASH" ]] || fail_staged "artifact verifier changed during build"
    [[ "$(shasum -a 256 "$REPO_PHYSICAL/scripts/verify-native-engine-abi.sh" | awk '{print $1}')" == "$STAGED_ABI_VERIFIER_HASH" ]] || fail_staged "ABI verifier changed during build"
    [[ "$(shasum -a 256 "$ABI_REVIEW_PHYSICAL" | awk '{print $1}')" == "$STAGED_ABI_REVIEW_HASH" ]] || fail_staged "ABI review report changed during build"
    /usr/bin/python3 - "$OUT" "$RETAINED_FFI/aarch64-apple-darwin/$LIB" "$STAGED_ENGINE_REVISION" "$STAGED_HEADER_HASH" "$STAGED_LOCK_HASH" "$STAGED_BUILDER_HASH" "$STAGED_RESOLVER_HASH" "$STAGED_TOOLCHAIN_ENV_HASH" "$STAGED_ARTIFACT_VERIFIER_HASH" "$STAGED_ABI_VERIFIER_HASH" "$STAGED_ABI_REVIEW_HASH" "$SDK_VERSION" <<'PY'
import hashlib, json, pathlib, sys
out, retained, revision, header, lock, builder, resolver, toolchain_env, artifact_verifier, abi_verifier, abi_review, sdk = sys.argv[1:]
def sha(path):
    h=hashlib.sha256()
    with open(path,"rb") as f:
        for block in iter(lambda:f.read(1024*1024),b""): h.update(block)
    return h.hexdigest()
root=pathlib.Path(out)
archive=root/"macos-arm64"/"libvortx_ffi.a"
header_file=root/"macos-arm64"/"Headers"/"vortx"/"vortx_ffi.h"
assert sha(header_file)==header, "packaged header differs from source header"
receipt={"schema":"staged-macos-arm64-v1","engineRevision":revision,"engineClean":True,
 "triple":"aarch64-apple-darwin","sdk":"macosx","sdkVersion":sdk,"deploymentFloor":"14.0",
 "rustToolchain":"nightly-2026-07-19","mode":"kernel-resource-host",
 "features":["resource-host","panic_abort"],"cargo":{"locked":True,"offline":True,"jobs":1},
 "inputs":{"headerSha256":header,"cargoLockSha256":lock,"builderSha256":builder,
 "resolverSha256":resolver,"toolchainEnvSha256":toolchain_env,
 "artifactVerifierSha256":artifact_verifier,"abiVerifierSha256":abi_verifier,
 "abiReviewReceiptSha256":abi_review},
 "outputs":{"xcframeworkArchiveSha256":sha(archive),"headerSha256":sha(header_file),
 "xcframeworkInfoPlistSha256":sha(root/"Info.plist"),"prelocalizeArchiveSha256":sha(retained)}}
receipt_path=root.parent/"BUILD-RECEIPT.json"
fd=__import__("os").open(receipt_path, __import__("os").O_WRONLY|__import__("os").O_CREAT|__import__("os").O_EXCL, 0o600)
with __import__("os").fdopen(fd,"w") as f: f.write(json.dumps(receipt,indent=2)+"\n")
PY
    bash "$REPO_ROOT/scripts/verify-apple-engine-artifacts.sh" --staged-macos-arm64 "$OUT" "$STAGED_PRELOCALIZE_ROOT"
    bash "$REPO_ROOT/scripts/verify-native-engine-abi.sh" apple-macos-arm64-staged "$OUT" resource-host
    exit 0
fi

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

IOS_SDK="$(xcrun --sdk iphoneos --show-sdk-version)"
SIM_SDK="$(xcrun --sdk iphonesimulator --show-sdk-version)"
TVOS_SDK="$(xcrun --sdk appletvos --show-sdk-version)"
TVSIM_SDK="$(xcrun --sdk appletvsimulator --show-sdk-version)"
MAC_SDK="$(xcrun --sdk macosx --show-sdk-version)"
localize aarch64-apple-ios      ios             16.0 "$IOS_SDK"
localize aarch64-apple-ios-sim  ios-simulator   16.0 "$SIM_SDK"
localize aarch64-apple-tvos     tvos            18.0 "$TVOS_SDK"
localize aarch64-apple-tvos-sim tvos-simulator  18.0 "$TVSIM_SDK"
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
    syms="$(nm -m -gU "$OUT/$slice/$LIB" | awk '/ external / && !/ private external / { print $NF }' | sort -u)"
    unexpected="$(printf '%s\n' "$syms" | sed '/^_vortx_/d; /^$/d')"
    [ -z "$unexpected" ] || { echo "unexpected public native exports in $slice: $unexpected" >&2; exit 1; }
    if echo "$syms" | grep -q '^_vortx_server_start$'; then kind=server-inclusive; else kind=kernel-only; fi
    echo "  $slice [$kind]: $(echo "$syms" | tr '\n' ' ')"
done
echo "OK: $OUT (iOS device+sim $IOS_KIND, tvOS device+sim $TV_KIND, macOS kernel-only; vortx_*-only exports)"
if [ "$VERIFY_STATE" = 1 ]; then
    ABI_MODE=state
    [ "$RESOURCE_HOST" != 1 ] || ABI_MODE=resource-host
    bash "$REPO_ROOT/scripts/verify-native-engine-abi.sh" apple "$OUT" "$ABI_MODE"
fi
