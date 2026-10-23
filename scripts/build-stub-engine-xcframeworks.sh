#!/usr/bin/env bash
set -euo pipefail

# CI-ONLY fail-closed native-engine and Mac-server stand-ins for secretless PR packaging.
# The real VortxEngine SDK and daemon are built from a reviewed private source pin. This script
# contains no private headers, implementation, networking, or state; it defines only the 24 C
# functions called by the tracked public Swift sources so real app compilation/linking can run.
#
# Public declaration provenance (keep source call sites and this stub surface in sync):
#   VortxNativeRuntime.swift:201-230: state, hydration, dispatch, delta,
#     string ownership, engine lifetime, and stateless owner-history canonicalization.
#   VortxResourceBridge.swift:284-306: raw-pointer host and cancellation handles.
#   OwnerHistorySessionRuntime.swift:87-125: opaque session handles and the explicit
#     @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Int32 callback.
#   VortxNativeServer.swift:112-142: raw-pointer in-process server handle and UInt16 port.
#
# The framework keeps the real Headers/vortx layout and five slice families, with universal
# simulator stubs to check both simulator architectures. The Mac executable exits unavailable.
# Every generated artifact is marked STUB-CI-ONLY. Protected workflows must never invoke this
# script or consume its markers; test-release-orchestration-contracts.sh enforces isolation.
# This checks compile/link/package mechanics only. It is never runtime/ABI/release proof.
# Output is gitignored; never ship the resulting libraries or daemon.

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

# sdk | xcframework slice dir | target triples. Simulator slices intentionally contain arm64 and
# x86_64 so the secretless packaging lane exercises both Xcode simulator link paths.
SDK_SPECS=(
    "iphoneos|ios-arm64|arm64-apple-ios16.0"
    "iphonesimulator|ios-arm64_x86_64-simulator|arm64-apple-ios16.0-simulator,x86_64-apple-ios16.0-simulator"
    "appletvos|tvos-arm64|arm64-apple-tvos18.0"
    "appletvsimulator|tvos-arm64_x86_64-simulator|arm64-apple-tvos18.0-simulator,x86_64-apple-tvos18.0-simulator"
    "macosx|macos-arm64|arm64-apple-macos14.0"
)

# ---------------------------------------------------------------- Stub sources ----------------------

ENGINE_STUB_SRC="$WORK_DIR/VortxEngine-src"
mkdir -p "$ENGINE_STUB_SRC/vortx"

cat > "$ENGINE_STUB_SRC/vortx/vortx_ffi.h" <<'EOF'
/* CI-only minimal ABI declarations inferred exclusively from public Swift call sites.
 * Never copy a private engine header into the public repo. This is compile/link scaffolding,
 * not an authoritative ABI document or a release engine. All bodies fail closed. */
#ifndef VORTX_FFI_CI_STUB_H
#define VORTX_FFI_CI_STUB_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct VortxEngine VortxEngine;
typedef struct VortxCiOwnerHistorySession VortxCiOwnerHistorySession;
typedef int32_t (*VortxCiOwnerHistoryVerify)(void *context, const char *evidence_json);

/* VortxNativeRuntime.swift:207-230. */
VortxEngine *vortx_init_runtime(const char *owner_id, const char *owner_name);
VortxEngine *vortx_init_from_state_json(const char *snapshot_json);
char *vortx_dispatch_json(VortxEngine *engine, const char *action_json, uint64_t now);
char *vortx_resolve_json(const VortxEngine *engine, const char *request_json);
char *vortx_get_state_json(const VortxEngine *engine);
char *vortx_get_state_delta_json(VortxEngine *engine);
void vortx_string_free(char *value);
void vortx_engine_free(VortxEngine *engine);
char *vortx_owner_history_canonicalize_evidence_json(const char *evidence_json);

/* VortxResourceBridge.swift:284-306: these handles are UnsafeMutableRawPointer. */
uint32_t vortx_resource_host_abi_version(void);
void *vortx_resource_host_new(void);
char *vortx_resource_host_load_json(void *host, const char *request_json, void *cancel);
void vortx_resource_host_free(void *host);
void *vortx_cancel_new(void);
void vortx_cancel_cancel(void *cancel);
void vortx_cancel_free(void *cancel);

/* OwnerHistorySessionRuntime.swift:87-125: session is OpaquePointer, callback is explicit. */
VortxCiOwnerHistorySession *vortx_owner_history_session_open(const char *snapshot_json,
    VortxCiOwnerHistoryVerify verify, void *context);
VortxCiOwnerHistorySession *vortx_owner_history_session_fork(VortxCiOwnerHistorySession *session,
    const char *fence_json, VortxCiOwnerHistoryVerify verify, void *context);
char *vortx_owner_history_session_json(VortxCiOwnerHistorySession *session,
    const char *request_json, uint64_t now, VortxCiOwnerHistoryVerify verify, void *context);
void vortx_owner_history_session_free(VortxCiOwnerHistorySession *session);

/* VortxNativeServer.swift:112-142. */
void *vortx_server_start(const char *config_json);
uint16_t vortx_server_port(const void *handle);
char *vortx_server_base_url(const void *handle);
void vortx_server_stop(void *handle);

#ifdef __cplusplus
}
#endif
#endif
EOF

cat > "$ENGINE_STUB_SRC/vortx/stub.c" <<'EOF'
/* CI-only fail-closed bodies for the public Swift call-site declarations. */
#include "vortx_ffi.h"

VortxEngine *vortx_init_runtime(const char *owner_id, const char *owner_name) {
    (void)owner_id; (void)owner_name; return (VortxEngine *)0;
}
VortxEngine *vortx_init_from_state_json(const char *snapshot) {
    (void)snapshot; return (VortxEngine *)0;
}
char *vortx_dispatch_json(VortxEngine *engine, const char *action, uint64_t now) {
    (void)engine; (void)action; (void)now; return (char *)0;
}
char *vortx_resolve_json(const VortxEngine *engine, const char *request) {
    (void)engine; (void)request; return (char *)0;
}
char *vortx_get_state_json(const VortxEngine *engine) { (void)engine; return (char *)0; }
char *vortx_get_state_delta_json(VortxEngine *engine) { (void)engine; return (char *)0; }
void vortx_string_free(char *value) { (void)value; }
void vortx_engine_free(VortxEngine *engine) { (void)engine; }
char *vortx_owner_history_canonicalize_evidence_json(const char *evidence) { (void)evidence; return (char *)0; }

uint32_t vortx_resource_host_abi_version(void) { return 0; }
void *vortx_resource_host_new(void) { return (void *)0; }
char *vortx_resource_host_load_json(void *host, const char *request, void *cancel) {
    (void)host; (void)request; (void)cancel; return (char *)0;
}
void vortx_resource_host_free(void *host) { (void)host; }
void *vortx_cancel_new(void) { return (void *)0; }
void vortx_cancel_cancel(void *cancel) { (void)cancel; }
void vortx_cancel_free(void *cancel) { (void)cancel; }

VortxCiOwnerHistorySession *vortx_owner_history_session_open(const char *snapshot,
    VortxCiOwnerHistoryVerify verify, void *context) {
    (void)snapshot; (void)verify; (void)context; return (VortxCiOwnerHistorySession *)0;
}
VortxCiOwnerHistorySession *vortx_owner_history_session_fork(VortxCiOwnerHistorySession *session,
    const char *fence, VortxCiOwnerHistoryVerify verify, void *context) {
    (void)session; (void)fence; (void)verify; (void)context; return (VortxCiOwnerHistorySession *)0;
}
char *vortx_owner_history_session_json(VortxCiOwnerHistorySession *session, const char *request,
    uint64_t now, VortxCiOwnerHistoryVerify verify, void *context) {
    (void)session; (void)request; (void)now; (void)verify; (void)context; return (char *)0;
}
void vortx_owner_history_session_free(VortxCiOwnerHistorySession *session) { (void)session; }

void *vortx_server_start(const char *config) { (void)config; return (void *)0; }
uint16_t vortx_server_port(const void *handle) { (void)handle; return 0; }
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
        # Match the real nested module path used by the app's SWIFT_INCLUDE_PATHS.
        local header_dir="$slice_dir/Headers"
        if [[ "$name" == "VortxEngine" ]]; then
            header_dir="$header_dir/vortx"
        fi
        mkdir -p "$header_dir"
        cp "$src_root/$headers_rel/"*.h "$header_dir/"
        cp "$src_root/$headers_rel/module.modulemap" "$header_dir/module.modulemap"
        # shellcheck disable=SC2086
        build_static_lib "$src_root" "$headers_rel" "$slice_dir/$lib_file" \
            "$(xcrun --sdk "$sdk" --show-sdk-path)" ${triples//,/ }
        # Accumulate the AvailableLibraries entry for this slice.
        local platform variant_keys=""
        case "$slice_name" in
            ios-arm64) platform="ios" ;;
            ios-arm64_x86_64-simulator) platform="ios"; variant_keys="<key>SupportedPlatformVariant</key><string>simulator</string>" ;;
            tvos-arm64) platform="tvos" ;;
            tvos-arm64_x86_64-simulator) platform="tvos"; variant_keys="<key>SupportedPlatformVariant</key><string>simulator</string>" ;;
            macos-arm64) platform="macos" ;;
            *) echo "error: unknown slice $slice_name" >&2; exit 1 ;;
        esac
        architectures="<string>arm64</string>"
        [[ "$triples" == *x86_64* ]] && architectures+="<string>x86_64</string>"
        lib_entries+=("<dict><key>BinaryPath</key><string>$lib_file</string><key>HeadersPath</key><string>Headers</string><key>LibraryIdentifier</key><string>$slice_name</string><key>LibraryPath</key><string>$lib_file</string><key>SupportedArchitectures</key><array>$architectures</array><key>SupportedPlatform</key><string>$platform</string>$variant_keys</dict>")
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



generate_stub_framework "VortxEngine" "$ENGINE_STUB_SRC" "vortx" "libvortx_ffi.a" \
"C I-ONLY STUB. Generated by scripts/build-stub-engine-xcframeworks.sh.
Fail-closed no-op vortx_* symbols for the secretless PR packaging lane.
The real engine comes from the private vortx-core workspace via scripts/build-ffi-xcframework.sh.
Never ship, never wire into a protected release workflow."

# Mac's native-only embed phase requires an executable. A CI-only Mach-O that always refuses
# service exercises that packaging contract without adding networking or a usable daemon.
cat > "$WORK_DIR/server-stub.c" <<'EOF'
/* CI-only packaging stand-in: never start a server, always report unavailable. */
int main(void) { return 78; }
EOF
xcrun --sdk macosx clang -target arm64-apple-macos14.0 \
    -isysroot "$(xcrun --sdk macosx --show-sdk-path)" \
    "$WORK_DIR/server-stub.c" -o "$OUTPUT_DIR/vortx-streaming-server"
chmod +x "$OUTPUT_DIR/vortx-streaming-server"
printf '%s\n' 'CI-ONLY STUB: scripts/build-stub-engine-xcframeworks.sh; always exits unavailable; never ship.' \
    > "$OUTPUT_DIR/vortx-streaming-server.STUB-CI-ONLY.txt"

log "CI-only native framework and unavailable Mac daemon ready under $OUTPUT_DIR"
