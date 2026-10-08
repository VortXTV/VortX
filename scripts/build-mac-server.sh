#!/usr/bin/env bash
# Build the native Rust streaming server (vortx-streaming-server, rqbit-based) for the Mac app
# and drop it at app/Vendor/vortx-streaming-server (Vendor/ is gitignored; produced by this
# script, the same arrangement as the core xcframework from build-core-xcframework.sh).
#
# Uses the existing canonical sibling vortx-core/vortx-core workspace, including from an app
# worktree. Override with VORTX_ENGINE_DIR. Requires Rust (the workspace pins its
# own toolchain via rust-toolchain.toml; a first build may need network for crates).
#
# The app picks the binary up ONLY when this file exists (project.yml embeds it
# copy-if-present), and runs it ONLY behind the vortxNativeServer flag (default OFF), so
# skipping this script changes nothing about the shipping node+server.js path.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO_ROOT="$(pwd)"
source "$REPO_ROOT/scripts/resolve-native-engine.sh"
ENGINE_DIR=$(resolve_native_engine "$REPO_ROOT" streaming-server)
TARGET="aarch64-apple-darwin"
OUT="app/Vendor/vortx-streaming-server"

echo "engine workspace: $ENGINE_DIR"

source "$HOME/.cargo/env" 2>/dev/null || true

echo "Building vortx-streaming-server ($TARGET, release) from $ENGINE_DIR ..."
(cd "$ENGINE_DIR" && cargo build --locked --release -p vortx-streaming-server --target "$TARGET")

mkdir -p app/Vendor
NATIVE_TARGET_DIR="${CARGO_TARGET_DIR:-$ENGINE_DIR/target}"
# Cargo resolves a relative override from its workspace cwd, not this app repository.
[[ "$NATIVE_TARGET_DIR" = /* ]] || NATIVE_TARGET_DIR="$ENGINE_DIR/$NATIVE_TARGET_DIR"
cp -f "$NATIVE_TARGET_DIR/$TARGET/release/vortx-streaming-server" "$OUT"
chmod +x "$OUT"
echo "OK: $OUT ($(du -h "$OUT" | cut -f1 | tr -d ' '))"
