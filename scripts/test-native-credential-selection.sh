#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p app/build
selection_test_dir=$(mktemp -d app/build/native-credential-selection.XXXXXX)
xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
    app/SourcesShared/VortxNativeCredentialSelectionRelay.swift \
    app/Tests/VortxNativeCredentialSelectionRelayTests.swift -o "$selection_test_dir/selection"
"$selection_test_dir/selection" "$PWD"
xcrun swiftc -frontend -parse -D VORTX_NATIVE_DATA_ENGINE -D VORTX_ENGINE_STATE_BRIDGE \
    -D VORTX_ENGINE_RESOURCE_HOST app/SourcesShared/CoreBridge.swift app/SourcesShared/StremioAccount.swift
