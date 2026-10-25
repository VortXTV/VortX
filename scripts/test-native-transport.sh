#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p app/build
transport_test_dir=$(mktemp -d app/build/native-transport.XXXXXX)
printf 'Native transport evidence: %s\n' "$transport_test_dir"
host_arch="$(uname -m)"
case "$host_arch" in arm64|x86_64) ;; *) echo 'Unsupported host architecture' >&2; exit 2 ;; esac
host_sdk="$(xcrun --sdk macosx --show-sdk-path)"
swift_flags=(-parse-as-library -swift-version 6 -strict-concurrency=complete -warnings-as-errors
  -j 1 -num-threads 1 -target "$host_arch-apple-macosx14.0" -sdk "$host_sdk"
  -module-cache-path "$transport_test_dir/module-cache")
printf '%s\n' 'Native transport policy and client'
nice -n 15 xcrun swiftc "${swift_flags[@]}" \
  app/SourcesShared/NativeTransportPolicy.swift app/SourcesShared/UsenetNodeClient.swift \
  app/Tests/NativeTransportTests.swift -o "$transport_test_dir/transport"
"$transport_test_dir/transport"
python3 test/native-transport-redirect.py "$transport_test_dir/transport"
printf '%s\n' 'Native client wire integration'
nice -n 15 xcrun swiftc "${swift_flags[@]}" \
  app/SourcesShared/NativeTransportPolicy.swift app/SourcesShared/UsenetNodeClient.swift \
  app/Tests/UsenetNodeClientIntegrationTests.swift -o "$transport_test_dir/native-client"
"$transport_test_dir/native-client"
printf '%s\n' 'Mac native-only bootstrap'
nice -n 15 xcrun swiftc "${swift_flags[@]}" -D VORTX_NATIVE_DATA_ENGINE \
  app/SourcesShared/NativeTransportPolicy.swift app/SourcesShared/MacNodeServer.swift \
  app/Tests/MacNativeTransportBootstrapTests.swift -o "$transport_test_dir/mac-bootstrap"
"$transport_test_dir/mac-bootstrap"
# Compile the actual mobile lifecycle on the host, substituting only platform/ABI availability
# and its filesystem root. No engine, app, network listener or provider account is started.
[[ $(head -n 1 app/SourcesShared/VortxNativeServer.swift) == '#if os(iOS) || os(tvOS)' ]]
[[ $(tail -n 1 app/SourcesShared/VortxNativeServer.swift) == '#endif' ]]
[[ $(rg -c '^import VortxEngine$' app/SourcesShared/VortxNativeServer.swift) == 1 ]]
[[ $(rg -c '^    +#if VORTX_ENGINE_SERVER$' app/SourcesShared/VortxNativeServer.swift) == 2 ]]
[[ $(rg -Fc 'NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first' app/SourcesShared/VortxNativeServer.swift) == 1 ]]
sed '1d;$d;/^import VortxEngine$/d;s/#if VORTX_ENGINE_SERVER/#if VORTX_NATIVE_SERVER_LIFECYCLE_TEST/g;s/NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first/ProcessInfo.processInfo.environment["VORTX_TEST_NATIVE_CACHES"]/g' \
  app/SourcesShared/VortxNativeServer.swift > "$transport_test_dir/MobileNativeServer.swift"
for marker in 'vortx_server_start' 'vortx_server_stop' 'static var isSupported' 'queue.async'; do
  rg -Fq "$marker" "$transport_test_dir/MobileNativeServer.swift"
done
printf '%s\n' 'Actual mobile lifecycle with inert ABI'
nice -n 15 xcrun swiftc "${swift_flags[@]}" \
  -D VORTX_NATIVE_DATA_ENGINE -D VORTX_NATIVE_SERVER_LIFECYCLE_TEST \
  app/SourcesShared/NativeTransportPolicy.swift "$transport_test_dir/MobileNativeServer.swift" \
  app/Tests/MobileNativeServerLifecycleTests.swift -o "$transport_test_dir/mobile-lifecycle"
VORTX_TEST_NATIVE_CACHES="$PWD/$transport_test_dir" "$transport_test_dir/mobile-lifecycle"
printf '%s\n' 'Native routing source contracts'
nice -n 15 xcrun swiftc "${swift_flags[@]}" \
  app/SourcesShared/UsenetStreamValidation.swift app/Tests/UsenetNodeRoutingContractTests.swift \
  -o "$transport_test_dir/routing-contract"
"$transport_test_dir/routing-contract"
bash scripts/test-apple-usenet-admission.sh
bash scripts/test-apple-nzb-operation.sh
printf '%s\n' 'Usenet routing policy'
nice -n 15 xcrun swiftc "${swift_flags[@]}" \
  app/SourcesShared/UsenetRoutingPolicy.swift app/Tests/UsenetRoutingPolicyTests.swift \
  -o "$transport_test_dir/routing-policy"
"$transport_test_dir/routing-policy"
printf '%s\n' 'Streaming-server settings policy'
nice -n 15 xcrun swiftc "${swift_flags[@]}" \
  app/SourcesShared/StreamingServerConnectionPolicy.swift app/Tests/StreamingServerConnectionPolicyTests.swift \
  -o "$transport_test_dir/server-settings"
"$transport_test_dir/server-settings"
