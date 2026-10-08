#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/native-watched-swift-inputs.sh
mkdir -p app/build
website_host_dir=$(mktemp -d app/build/native-website-host.XXXXXX)
sed -n '1,/^\/\/\/ The profile roster and the active selection\./{ /^\/\/\/ The profile roster and the active selection\./!p; }' app/SourcesShared/Profiles.swift > "$website_host_dir/UserProfile.swift"
{
    printf '%s\n' 'import Foundation'
    sed -n '/^struct ProfileDiscoveryPreferences: /,/^}$/p' app/SourcesShared/ProfileDiscoveryPreferences.swift
} > "$website_host_dir/Discovery.swift"
node --input-type=module - "$website_host_dir/vectors.json" <<'NODE'
import {writeFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
const canonical = x => x === null || typeof x !== 'object' ? JSON.stringify(x)
    : Array.isArray(x) ? '[' + x.map(canonical).join(',') + ']'
    : '{' + Object.keys(x).sort().map(k=>JSON.stringify(k)+':'+canonical(x[k])).join(',') + '}';
const values = [null,true,false,1.0,-0,1e-7,1e-6,1e20,1e21,333333333.33333329,
    Number.MIN_VALUE,Number.MAX_VALUE,'🍿 / \\ " \n',{'z':1,'a':[0.8,12.5,1.15],'😀':'emoji','\ue000':'private-plane'},
    {subtitleLang:'hin',audioLang:'eng',maxFileSizeGB:12.5}];
writeFileSync(process.argv[2],JSON.stringify(values.map(value=>({value,canonical:canonical(value),sha256:createHash('sha256').update(canonical(value)).digest('hex')}))));
NODE
xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
    app/SourcesShared/VortxNativeRuntime.swift app/SourcesShared/VortxResourceBridge.swift app/SourcesShared/VortxResourceProjection.swift \
    app/SourcesShared/VortxNativeBootstrapArchive.swift app/SourcesShared/VortxNativeHostPreferences.swift "${native_watched_swift_inputs[@]}" app/SourcesShared/VortxNativeSession.swift app/SourcesShared/VortxProfileOverlayWitness.swift \
    app/SourcesShared/ProfileAddonPreferences.swift app/SourcesShared/VortxNativeProfileEditHost.swift \
    "$website_host_dir/UserProfile.swift" "$website_host_dir/Discovery.swift" app/Tests/VortxNativeProfileEditHostTests.swift \
    -o "$website_host_dir/website-host"
"$website_host_dir/website-host" "$website_host_dir/vectors.json"
if [[ -n "${VORTX_FFI_LIBRARY:-}" ]]; then
    website_library_hash=$(shasum -a 256 "$VORTX_FFI_LIBRARY" | awk '{print $1}')
    website_header_hash=$(shasum -a 256 "${VORTX_FFI_HEADER:?exact reviewed header required}" | awk '{print $1}')
    cp "$VORTX_FFI_HEADER" "$website_host_dir/vortx_ffi.h"
    printf 'module VortxEngine { header "vortx_ffi.h" export * }\n' > "$website_host_dir/module.modulemap"
    xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
        -D VORTX_ENGINE_STATE_BRIDGE -D VORTX_ENGINE_RESOURCE_HOST -I "$website_host_dir" \
        app/SourcesShared/VortxNativeRuntime.swift app/SourcesShared/VortxResourceBridge.swift app/SourcesShared/VortxResourceProjection.swift \
        app/SourcesShared/VortxNativeBootstrapArchive.swift app/SourcesShared/VortxNativeHostPreferences.swift "${native_watched_swift_inputs[@]}" app/SourcesShared/VortxNativeSession.swift app/SourcesShared/VortxProfileOverlayWitness.swift \
        app/SourcesShared/ProfileAddonPreferences.swift app/SourcesShared/VortxNativeProfileEditHost.swift \
        "$website_host_dir/UserProfile.swift" "$website_host_dir/Discovery.swift" app/Tests/VortxNativeWebsiteTransactionTests.swift \
        "$VORTX_FFI_LIBRARY" -o "$website_host_dir/website-transaction"
    DYLD_LIBRARY_PATH="$(dirname "$VORTX_FFI_LIBRARY"):$(dirname "$VORTX_FFI_LIBRARY")/deps" "$website_host_dir/website-transaction" "$website_host_dir/checkpoints"
    test "$website_library_hash" = "$(shasum -a 256 "$VORTX_FFI_LIBRARY" | awk '{print $1}')"
    test "$website_header_hash" = "$(shasum -a 256 "$VORTX_FFI_HEADER" | awk '{print $1}')"
    printf 'Verified immutable website ABI/header: %s %s\n' "$website_library_hash" "$website_header_hash"
fi
