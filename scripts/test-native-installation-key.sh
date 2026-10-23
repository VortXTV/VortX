#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p app/build
installation_gate=$(mktemp -d "$PWD/app/build/native-installation-key.XXXXXX")
{
    printf '%s\n' 'import Foundation' 'import Darwin' 'enum VortxNativeError: Error { case unavailable }'
    sed -n '/^final class VortxNativeInstallationKeyFileStore:/,/^\/\/ End immutable installation-key file store/p' app/SourcesShared/VortxNativeSession.swift
} > "$installation_gate/Production.swift"
shasum -a 256 app/SourcesShared/VortxNativeSession.swift app/Tests/NativeInstallationKeyFileTests.swift "$installation_gate/Production.swift" > "$installation_gate/source-sha256.txt"
xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors "$installation_gate/Production.swift" app/Tests/NativeInstallationKeyFileTests.swift -o "$installation_gate/installation-key-tests"
"$installation_gate/installation-key-tests" "$installation_gate/fixtures"
printf 'Retained installation-key gate: %s\n' "$installation_gate"
