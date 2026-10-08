#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/resolve-native-engine.sh
mkdir -p app/build
fixture_root=$(mktemp -d "$PWD/app/build/native-resolver.XXXXXX")
# Empty manifest fixtures, never copies of a VortX checkout.
mkdir -p "$fixture_root/app" "$fixture_root/vortx-core/vortx-core/crates/streaming-server" "$fixture_root/override/crates/streaming-server"
touch "$fixture_root/vortx-core/vortx-core/Cargo.toml" "$fixture_root/vortx-core/vortx-core/crates/streaming-server/Cargo.toml"
touch "$fixture_root/override/Cargo.toml" "$fixture_root/override/crates/streaming-server/Cargo.toml"
test "$(resolve_native_engine "$fixture_root/app" streaming-server)" = "$fixture_root/vortx-core/vortx-core"
test "$(VORTX_ENGINE_DIR="$fixture_root/override" resolve_native_engine "$fixture_root/app" streaming-server)" = "$fixture_root/override"
if VORTX_ENGINE_DIR="$fixture_root/missing" resolve_native_engine "$fixture_root/app" streaming-server 2>/dev/null; then
    echo "invalid explicit override silently fell back" >&2; exit 1
fi
if VORTX_ENGINE_DIR="$fixture_root/override" resolve_native_engine "$fixture_root/app" ffi 2>/dev/null; then
    echo "workspace without required crate accepted" >&2; exit 1
fi
if [[ "$PWD" == /Users/daksh/VortXTV/* ]]; then
    test "$(resolve_native_engine "$PWD" streaming-server)" = /Users/daksh/VortXTV/vortx-core/vortx-core
fi
# Execute the real builder against a command fixture: locked invocation, sibling resolution and
# CARGO_TARGET_DIR output pickup must agree, without Rust/network or touching a shipping artifact.
mkdir -p "$fixture_root/app/scripts" "$fixture_root/bin"
cp scripts/build-mac-server.sh scripts/resolve-native-engine.sh "$fixture_root/app/scripts/"
cp test/fixtures/native-build-cargo.sh "$fixture_root/bin/cargo"
chmod +x "$fixture_root/bin/cargo"
PATH="$fixture_root/bin:$PATH" VORTX_TEST_CARGO_LOG="$fixture_root/cargo.log" CARGO_TARGET_DIR="$fixture_root/build-output" \
    bash "$fixture_root/app/scripts/build-mac-server.sh" > "$fixture_root/build.log"
test -x "$fixture_root/app/app/Vendor/vortx-streaming-server"
test -s "$fixture_root/cargo.log"
PATH="$fixture_root/bin:$PATH" VORTX_TEST_CARGO_LOG="$fixture_root/relative-cargo.log" CARGO_TARGET_DIR=target-review \
    bash "$fixture_root/app/scripts/build-mac-server.sh" > "$fixture_root/relative-build.log"
test -x "$fixture_root/vortx-core/vortx-core/target-review/aarch64-apple-darwin/release/vortx-streaming-server"
test -s "$fixture_root/relative-cargo.log"
echo "canonical native-engine resolver checks passed"
