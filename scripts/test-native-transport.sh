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
# Compile the actual mobile lifecycle on the host, substituting only platform/ABI availability
# and its filesystem root. No engine, app, network listener or provider account is started.
sed '1d;$d;s/#if canImport(VortxEngine) \&\& VORTX_ENGINE_SERVER/#if VORTX_NATIVE_SERVER_LIFECYCLE_TEST/g;s/NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first/ProcessInfo.processInfo.environment["VORTX_TEST_NATIVE_CACHES"]/g' \
  app/SourcesShared/VortxNativeServer.swift > "$transport_test_dir/MobileNativeServer.swift"
xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
  -D VORTX_NATIVE_DATA_ENGINE -D VORTX_NATIVE_SERVER_LIFECYCLE_TEST \
  app/SourcesShared/NativeTransportPolicy.swift "$transport_test_dir/MobileNativeServer.swift" \
  app/Tests/MobileNativeServerLifecycleTests.swift -o "$transport_test_dir/mobile-lifecycle"
VORTX_TEST_NATIVE_CACHES="$PWD/$transport_test_dir" "$transport_test_dir/mobile-lifecycle"
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
