#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p app/build
transport_test_dir=$(mktemp -d app/build/native-transport.XXXXXX)
xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
  app/SourcesShared/NativeTransportPolicy.swift app/SourcesShared/UsenetNodeClient.swift \
  app/Tests/NativeTransportTests.swift -o "$transport_test_dir/transport"
"$transport_test_dir/transport"
python3 test/native-transport-redirect.py "$transport_test_dir/transport"
xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
  app/SourcesShared/NativeTransportPolicy.swift app/SourcesShared/UsenetNodeClient.swift \
  app/Tests/UsenetNodeClientIntegrationTests.swift -o "$transport_test_dir/legacy-client"
"$transport_test_dir/legacy-client"
xcrun swiftc -parse-as-library -swift-version 5 -D VORTX_NATIVE_DATA_ENGINE \
  app/SourcesShared/NativeTransportPolicy.swift app/SourcesShared/MacNodeServer.swift \
  app/Tests/MacNativeTransportBootstrapTests.swift -o "$transport_test_dir/mac-bootstrap"
"$transport_test_dir/mac-bootstrap"
xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
  app/SourcesShared/UsenetStreamValidation.swift app/Tests/UsenetNodeRoutingContractTests.swift \
  -o "$transport_test_dir/routing-contract"
"$transport_test_dir/routing-contract"
xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
  app/SourcesShared/UsenetRoutingPolicy.swift app/Tests/UsenetRoutingPolicyTests.swift \
  -o "$transport_test_dir/routing-policy"
"$transport_test_dir/routing-policy"
xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
  app/SourcesShared/StreamingServerConnectionPolicy.swift app/Tests/StreamingServerConnectionPolicyTests.swift \
  -o "$transport_test_dir/server-settings"
"$transport_test_dir/server-settings"
