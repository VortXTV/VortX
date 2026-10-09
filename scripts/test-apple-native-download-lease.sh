#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p app/build
download_lease_dir=$(mktemp -d app/build/apple-native-download-lease.XXXXXX)
# Producer root may point at the separately reviewed dependency until it is integrated here.
download_producer_root=${1:-.}
download_baseline=${2:-}
xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
  app/Tests/AppleNativeDownloadLeaseTests.swift -o "$download_lease_dir/driver"
"$download_lease_dir/driver" "$PWD" "$download_producer_root" "$download_lease_dir" "$download_baseline"
