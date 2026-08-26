#!/usr/bin/env bash
set -euo pipefail

# =====================================================================================================
# build-stub-engine-xcframeworks.sh : CI-ONLY engine stand-ins for the secretless PR packaging lane.
#
# WHY THIS EXISTS
#   The two Apple engine frameworks are built from PRIVATE repos:
#     app/Vendor/StremioXCore.xcframework <- stremiox-core (proprietary), via scripts/build-core-xcframework.sh
#     app/Vendor/VortxEngine.xcframework  <- vortx-core engine workspace (private), via scripts/build-ffi-xcframework.sh
#   A pull-request run has neither the source nor a token, so .github/workflows/release-packaging-validation.yml
#   generates THESE STUBS instead: real Mach-O static libraries that DEFINE exactly the C symbols the
#   tracked Swift sources reference (so xcodebuild genuinely compiles AND links), with fail-closed
#   bodies (NULL/false/0 -- every consumer already handles engine absence), plus module maps laid out
#   byte-for-byte like the real frameworks so `import StremioXCore` / `import VortxEngine` resolve.
#
# WHAT A STUB IS NOT
#   These are NOT engines. They contain no business logic, no networking, no state. Any process linked
#   against them gets a cleanly unavailable engine (init returns false, resolves return NULL), which is
#   the same contract the shipping app already implements for engine-absent targets. They exist purely
#   so the packaging pipeline (Swift compilation, module discovery, archive linking, bundling) is
#   exercised end to end on PRs where the private source cannot be.
#
# LAYOUT FIDELITY
#   Slice directories, static-lib filenames (libstremiox_core.a / libvortx_ffi.a), header paths
#   (Headers/stremiox_core.h, Headers/vortx/vortx_ffi.h), module maps, and the xcframework
#   Info.plist shape mirror the REAL frameworks so Xcode's selection/linking behaves identically.
#
# HONESTY BOUNDARY
#   The stub headers are hand-written MINIMAL declarations of only the surface the TRACKED Swift
#   files consume. They are not copies of the private engine headers (the real ABI documents stay
#   in the private repos; this public repo must never carry them -- see scan-proprietary-engine.sh).
#
# CI-ONLY GUARANTEES
#   - Every generated .xcframework carries STUB-CI-ONLY.txt at its root, naming this script.
#   - This script is invoked ONLY by release-packaging-validation.yml. Contract tests
#     (scripts/test-release-orchestration-contracts.sh) FAIL if any protected workflow
#     (android-release.yml, release-tvos.yml, android.yml) references this script or the STUB
#     marker, so a stub can never be wired into a lane that publishes artifacts.
#   - Output paths are the gitignored Vendor locations; they never enter git through this script.
#
# SYMBOL SURFACE PROVENANCE (tracked call sites; keep in sync when these change):
#   StremioXCore (app/SourcesShared/CoreBridge.swift):
#     stremiox_core_init(storage, cache, ctx, cb)      CoreBridge.swift:168  -> bool
#     stremiox_core_schema_version()                   CoreBridge.swift:652  -> uint32_t
#     stremiox_core_dispatch(json)                     CoreBridge.swift:2489 -> void
#     stremiox_core_get_state(query)                   CoreBridge.swift:2510 -> char* (nullable)
#     stremiox_core_string_free(ptr)                   CoreBridge.swift:2511 -> void
#     event callback shape                             CoreBridge.swift:3238 (ctx, data u8*, len)
#   VortxEngine (app/SourcesShared/VortxBridge.swift, app/SourcesShared/VortxNativeServer.swift):
#     vortx_init_runtime(id, name) -> VortxEngine*     VortxBridge.swift
#     vortx_resolve_json(engine, req) -> char*         VortxBridge.swift
#     vortx_get_state_json(engine) -> char*            VortxBridge.swift
#     vortx_string_free(ptr)                           both files
#     vortx_engine_free(engine)                        VortxBridge.swift deinit
#     vortx_server_start(config) -> void*              VortxNativeServer.swift:136
#     vortx_server_port(handle) -> uint16_t            VortxNativeServer.swift:141
#     vortx_server_base_url(handle) -> char*           VortxNativeServer.swift:143
#     vortx_server_stop(handle)                        VortxNativeServer.swift:161
# =====================================================================================================

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vortx-engine-stubs.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

log() { printf '[engine-stub] %s\n' "$*"; }

usage() {
    printf 'Usage: %s [--output-dir <dir>]   (default: %s/app/Vendor)\n' "$(basename "$0")" "$REPO_ROOT" >&2
    exit 2
}

OUTPUT_DIR="$REPO_ROOT/app/Vendor"
while (( $# > 0 )); do
    case "$1" in
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        *) usage ;;
    esac
done
mkdir -p "$OUTPUT_DIR"

command -v clang >/dev/null || { echo "error: clang not found" >&2; exit 1; }
command -v xcrun >/dev/null || { echo "error: xcrun not found (need Xcode)" >&2; exit 1; }
command -v lipo >/dev/null || { echo "error: lipo not found (need Xcode)" >&2; exit 1; }
command -v plutil >/dev/null || { echo "error: plutil not found (need Xcode)" >&2; exit 1; }

# sdk | xcframework slice dir | target triple   (single-arch arm64 slices, matching the real frameworks)
SDK_SPECS=(
    "iphoneos|ios-arm64|arm64-apple-ios16.0"
    "iphonesimulator|ios-arm64-simulator|arm64-apple-ios16.0-simulator"
    "appletvos|tvos-arm64|arm64-apple-tvos18.0"
    "appletvsimulator|tvos-arm64-simulator|arm64-apple-tvos18.0-simulator"
    "macosx|macos-arm64|arm64-apple-macos14.0"
)

# ---------------------------------------------------------------- Stub sources ----------------------

CORE_STUB_SRC="$WORK_DIR/StremioXCore-src"
ENGINE_STUB_SRC="$WORK_DIR/VortxEngine-src"
mkdir -p "$CORE_STUB_SRC" "$ENGINE_STUB_SRC/vortx"

cat > "$CORE_STUB_SRC/stremiox_core.h" <<'EOF'
/*
 * CI-ONLY STUB HEADER for the secretless pull-request packaging lane.
 *
 * Hand-written minimal declaration of the stremiox_core_* surface the tracked Swift sources
 * reference (app/SourcesShared/CoreBridge.swift; provenance table in
 * scripts/build-stub-engine-xcframeworks.sh). Signatures mirror the real ABI. The companion stub
 * implementation is fail-closed: init returns false, every accessor returns NULL/0, matching the
 * app's documented engine-absent contract. This is NOT a copy of the private engine header; the
 * real ABI document stays in the private stremiox-core repo. Never ship a binary built on this stub.
 */
#ifndef STREMIOX_CORE_CI_STUB_H
#define STREMIOX_CORE_CI_STUB_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*StremioxCiStubEventCallback)(void *ctx, const uint8_t *data, size_t len);

bool stremiox_core_init(const char *storage_dir, const char *cache_dir, void *ctx,
                        StremioxCiStubEventCallback on_event);
uint32_t stremiox_core_schema_version(void);
void stremiox_core_dispatch(const char *action_json);
char *stremiox_core_get_state(const char *field_json);
void stremiox_core_string_free(char *ptr);

#ifdef __cplusplus
}
#endif

#endif /* STREMIOX_CORE_CI_STUB_H */
EOF

cat > "$CORE_STUB_SRC/stub.c" <<'EOF'
/* CI-only fail-closed stub implementation; see stremiox_core.h. */
#include "stremiox_core.h"

bool stremiox_core_init(const char *storage_dir, const char *cache_dir, void *ctx,
                        StremioxCiStubEventCallback on_event) {
    (void)storage_dir; (void)cache_dir; (void)ctx; (void)on_event;
    return false; /* stub: engine unavailable, exactly the branch consumers already handle */
}

uint32_t stremiox_core_schema_version(void) { return 0u; }

void stremiox_core_dispatch(const char *action_json) { (void)action_json; }

char *stremiox_core_get_state(const char *field_json) { (void)field_json; return (char *)0; }

void stremiox_core_string_free(char *ptr) { (void)ptr; }
EOF

cat > "$CORE_STUB_SRC/module.modulemap" <<'EOF'
module StremioXCore {
    header "stremiox_core.h"
    export *
}
EOF

cat > "$ENGINE_STUB_SRC/vortx/vortx_ffi.h" <<'EOF'
/*
 * CI-ONLY STUB HEADER for the secretless pull-request packaging lane.
 *
 * Hand-written minimal declaration of the vortx_* C ABI the tracked Swift sources reference
 * (app/SourcesShared/VortxBridge.swift, app/SourcesShared/VortxNativeServer.swift; provenance
 * table in scripts/build-stub-engine-xcframeworks.sh). Signatures mirror the real ABI (owned
 * char* results freed via vortx_string_free, uint16_t bound port, opaque handles). Fail-closed
 * bodies: runtime creation returns NULL and servers refuse to start, matching the app's
 * documented engine-absent branches. This is NOT a copy of the private engine header; the real
 * ABI document stays in the private vortx-core workspace. Never ship a binary built on this stub.
 */
#ifndef VORTX_FFI_CI_STUB_H
#define VORTX_FFI_CI_STUB_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct VortxEngine VortxEngine;

VortxEngine *vortx_init_runtime(const char *owner_id, const char *owner_name);
char *vortx_resolve_json(const VortxEngine *engine, const char *request_json);
char *vortx_get_state_json(const VortxEngine *engine);
void vortx_string_free(char *s);
void vortx_engine_free(VortxEngine *engine);

void *vortx_server_start(const char *config_json);
uint16_t vortx_server_port(const void *handle);
char *vortx_server_base_url(const void *handle);
void vortx_server_stop(void *handle);

#ifdef __cplusplus
}
#endif

#endif /* VORTX_FFI_CI_STUB_H */
EOF

cat > "$ENGINE_STUB_SRC/vortx/stub.c" <<'EOF'
/* CI-only fail-closed stub implementation; see vortx_ffi.h. */
#include "vortx_ffi.h"

VortxEngine *vortx_init_runtime(const char *owner_id, const char *owner_name) {
    (void)owner_id; (void)owner_name;
    return (VortxEngine *)0;
}

char *vortx_resolve_json(const VortxEngine *engine, const char *request_json) {
    (void)engine; (void)request_json;
    return (char *)0;
}

char *vortx_get_state_json(const VortxEngine *engine) { (void)engine; return (char *)0; }

void vortx_string_free(char *s) { (void)s; }

void vortx_engine_free(VortxEngine *engine) { (void)engine; }

void *vortx_server_start(const char *config_json) { (void)config_json; return (void *)0; }

uint16_t vortx_server_port(const void *handle) { (void)handle; return 0u; }

char *vortx_server_base_url(const void *handle) { (void)handle; return (char *)0; }

void vortx_server_stop(void *handle) { (void)handle; }
EOF

cat > "$ENGINE_STUB_SRC/vortx/module.modulemap" <<'EOF'
module VortxEngine {
    header "vortx_ffi.h"
    export *
}
EOF

# ---------------------------------------------------------------- Framework generation --------------

build_static_lib() {
    local src_root="$1" headers_rel="$2" out_a="$3" sysroot="$4"
    shift 4
    local objects=()
    local triple
    for triple in "$@"; do
        local obj="$out_a.$triple.o"
        clang -target "$triple" -isysroot "$sysroot" -I"$src_root/$headers_rel" \
            -c "$src_root/$headers_rel/stub.c" -o "$obj"
        objects+=("$obj")
    done
    if (( ${#objects[@]} == 1 )); then
        mv "${objects[0]}" "$out_a"
    else
        lipo -create "${objects[@]}" -output "$out_a"
        rm -f "${objects[@]}"
    fi
}

# generate_stub_framework <name> <src_root> <headers_rel> <lib_filename> <marker_file>
generate_stub_framework() {
    local name="$1" src_root="$2" headers_rel="$3" lib_file="$4" marker_text="$5"
    local fw_dir="$OUTPUT_DIR/$name.xcframework"
    rm -rf "$fw_dir"
    mkdir -p "$fw_dir"
    log "generating $name.xcframework:"
    local spec
    local lib_entries=()
    for spec in "${SDK_SPECS[@]}"; do
        IFS='|' read -r sdk slice_name triples <<<"$spec"
        local slice_dir="$fw_dir/$slice_name"
        # Destination header dir is ALWAYS "Headers" inside the slice, mirroring the real
        # frameworks; headers_rel only describes where the stub sources keep them.
        mkdir -p "$slice_dir/Headers"
        cp "$src_root/$headers_rel/"*.h "$slice_dir/Headers/"
        cp "$src_root/$headers_rel/module.modulemap" "$slice_dir/Headers/module.modulemap"
        # shellcheck disable=SC2086
        build_static_lib "$src_root" "$headers_rel" "$slice_dir/$lib_file" \
            "$(xcrun --sdk "$sdk" --show-sdk-path)" ${triples//,/ }
        # Accumulate the AvailableLibraries entry for this slice.
        local platform variant_keys=""
        case "$slice_name" in
            ios-arm64) platform="ios" ;;
            ios-arm64-simulator) platform="ios"; variant_keys="<key>SupportedPlatformVariant</key><string>simulator</string>" ;;
            tvos-arm64) platform="tvos" ;;
            tvos-arm64-simulator) platform="tvos"; variant_keys="<key>SupportedPlatformVariant</key><string>simulator</string>" ;;
            macos-arm64) platform="macos" ;;
            *) echo "error: unknown slice $slice_name" >&2; exit 1 ;;
        esac
        lib_entries+=("<dict><key>BinaryPath</key><string>$lib_file</string><key>HeadersPath</key><string>Headers</string><key>LibraryIdentifier</key><string>$slice_name</string><key>LibraryPath</key><string>$lib_file</string><key>SupportedArchitectures</key><array><string>arm64</string></array><key>SupportedPlatform</key><string>$platform</string>$variant_keys</dict>")
        log "  slice $slice_name ($(stat -f%z "$slice_dir/$lib_file") bytes)"
    done
    {
        printf '<?xml version="1.0" encoding="UTF-8"?>\n'
        printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
        printf '<plist version="1.0"><dict>\n'
        printf '<key>AvailableLibraries</key><array>\n'
        printf '%s\n' "${lib_entries[@]}"
        printf '</array>\n'
        printf '<key>CFBundlePackageType</key><string>XFWK</string>\n'
        printf '<key>XCFrameworkFormatVersion</key><string>1.0</string>\n'
        printf '</dict></plist>\n'
    } > "$fw_dir/Info.plist"
    plutil -lint "$fw_dir/Info.plist" >/dev/null || { echo "error: generated $name Info.plist is invalid" >&2; exit 1; }
    printf '%s\n' "$marker_text" > "$fw_dir/STUB-CI-ONLY.txt"
}

generate_stub_framework "StremioXCore" "$CORE_STUB_SRC" "." "libstremiox_core.a" \
"C I-ONLY STUB. Generated by scripts/build-stub-engine-xcframeworks.sh.
Fail-closed no-op stremiox_core_* symbols for the secretless PR packaging lane.
The real engine comes from the private stremiox-core repo via scripts/build-core-xcframework.sh.
Never ship, never wire into a protected release workflow."

generate_stub_framework "VortxEngine" "$ENGINE_STUB_SRC" "vortx" "libvortx_ffi.a" \
"C I-ONLY STUB. Generated by scripts/build-stub-engine-xcframeworks.sh.
Fail-closed no-op vortx_* symbols for the secretless PR packaging lane.
The real engine comes from the private vortx-core workspace via scripts/build-ffi-xcframework.sh.
Never ship, never wire into a protected release workflow."

log "stub engine xcframeworks ready under $OUTPUT_DIR (CI-only, fail-closed)"
