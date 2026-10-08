#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p app/build
native_test_dir=$(mktemp -d app/build/native-cutover.XXXXXX)
xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
  app/SourcesShared/VortxNativeRuntime.swift app/SourcesShared/VortxResourceBridge.swift \
  app/SourcesShared/VortxResourceProjection.swift app/Tests/VortxNativeBridgeTests.swift \
  -o "$native_test_dir/native-bridges"
"$native_test_dir/native-bridges" test/fixtures/native-resource-contract.json
bash test/build-mac-server-resolver.sh
