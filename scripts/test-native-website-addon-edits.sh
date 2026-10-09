#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/native-watched-swift-inputs.sh
mkdir -p app/build
addon_test_dir=$(mktemp -d app/build/native-website-addons.XXXXXX)
sed -n '1,/^\/\/\/ The profile roster and the active selection\./{ /^\/\/\/ The profile roster and the active selection\./!p; }' app/SourcesShared/Profiles.swift > "$addon_test_dir/UserProfile.swift"
{
  printf '%s\n' 'import Foundation'
  sed -n '/^struct ProfileDiscoveryPreferences: /,/^}$/p' app/SourcesShared/ProfileDiscoveryPreferences.swift
} > "$addon_test_dir/Discovery.swift"
addon_inputs=(
  app/SourcesShared/VortxNativeRuntime.swift app/SourcesShared/VortxResourceBridge.swift
  app/SourcesShared/VortxResourceProjection.swift app/SourcesShared/VortxNativeBootstrapArchive.swift
  app/SourcesShared/VortxNativeHostPreferences.swift "${native_watched_swift_inputs[@]}"
  app/SourcesShared/VortxNativeSession.swift app/SourcesShared/VortxNativeCoreFacade.swift
  app/SourcesShared/VortxProfileOverlayWitness.swift app/SourcesShared/VortxNativeProfiles.swift
  app/SourcesShared/AuthenticatedHTTPTransport.swift app/SourcesShared/VortxNativeOwnerAddonImport.swift
  app/SourcesShared/ProfileAddonPreferences.swift app/SourcesShared/VortxNativeProfileEditHost.swift
  "$addon_test_dir/UserProfile.swift" "$addon_test_dir/Discovery.swift"
  app/Tests/VortxNativeWebsiteAddonEditsTests.swift
)
addon_flags=(-swift-version 6 -parse-as-library -strict-concurrency=complete -warnings-as-errors)
if [[ -n "${VORTX_FFI_LIBRARY:-}" ]]; then
  addon_library_hash=$(shasum -a 256 "$VORTX_FFI_LIBRARY" | awk '{print $1}')
  addon_header_hash=$(shasum -a 256 "${VORTX_FFI_HEADER:?exact reviewed header required}" | awk '{print $1}')
  cp "$VORTX_FFI_HEADER" "$addon_test_dir/vortx_ffi.h"
  printf 'module VortxEngine { header "vortx_ffi.h" export * }\n' > "$addon_test_dir/module.modulemap"
  addon_flags+=(-D VORTX_ENGINE_STATE_BRIDGE -D VORTX_ENGINE_RESOURCE_HOST -I "$addon_test_dir" "$VORTX_FFI_LIBRARY")
fi
xcrun swiftc "${addon_inputs[@]}" "${addon_flags[@]}" -o "$addon_test_dir/website-addons"
DYLD_LIBRARY_PATH="$(dirname "${VORTX_FFI_LIBRARY:-.}"):$(dirname "${VORTX_FFI_LIBRARY:-.}")/deps" \
  "$addon_test_dir/website-addons" "$addon_test_dir/checkpoints"
if [[ -n "${VORTX_FFI_LIBRARY:-}" ]]; then
  test "$addon_library_hash" = "$(shasum -a 256 "$VORTX_FFI_LIBRARY" | awk '{print $1}')"
  test "$addon_header_hash" = "$(shasum -a 256 "$VORTX_FFI_HEADER" | awk '{print $1}')"
  printf 'Verified immutable website add-on ABI/header: %s %s\n' "$addon_library_hash" "$addon_header_hash"
fi
