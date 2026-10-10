#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
receipt_sdk_dir=${1:?Pass the exact existing macos-arm64 SDK directory; no SDK build occurs}
test -f "$receipt_sdk_dir/libvortx_ffi.a"
test -f "$receipt_sdk_dir/Headers/vortx/vortx_ffi.h"
mkdir -p app/build
receipt_abi_dir=$(mktemp -d "$PWD/app/build/native-addon-error-abi.XXXXXX")
printf 'Retained loopback output %s\n' "$receipt_abi_dir"
shasum -a 256 "$receipt_sdk_dir/libvortx_ffi.a" "$receipt_sdk_dir/Headers/vortx/vortx_ffi.h"
xcrun clang -Wall -Wextra -Werror -I "$receipt_sdk_dir/Headers/vortx" \
    app/Tests/NativeAddonErrorABIReceipt.c "$receipt_sdk_dir/libvortx_ffi.a" \
    -framework Security -framework SystemConfiguration -framework CoreFoundation \
    -o "$receipt_abi_dir/receipt"
node app/Tests/NativeAddonErrorABIReceipt.mjs "$receipt_abi_dir/receipt" | tee "$receipt_abi_dir/test.log"
shasum -a 256 app/Tests/NativeAddonErrorABIReceipt.c app/Tests/NativeAddonErrorABIReceipt.mjs \
    scripts/test-native-addon-error-abi.sh "$receipt_abi_dir/receipt" "$receipt_abi_dir/test.log"
shasum -a 256 "$receipt_sdk_dir/libvortx_ffi.a" "$receipt_sdk_dir/Headers/vortx/vortx_ffi.h"
