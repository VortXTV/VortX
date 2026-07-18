#!/usr/bin/env bash
# Build the native Rust streaming server (vortx-streaming-server, rqbit-based) for the Mac app
# and drop it at app/Vendor/vortx-streaming-server (Vendor/ is gitignored; produced by this
# script, the same arrangement as the core xcframework from build-core-xcframework.sh).
#
# Requires the ENGINE CHECKOUT to be present at ../vortx-engine/vortx-core relative to this
# repo (i.e. /Users/daksh/vortx-engine/vortx-core), the same prerequisite as the core
# xcframework build. Override with VORTX_ENGINE_DIR. Requires Rust (the workspace pins its
# own toolchain via rust-toolchain.toml; a first build may need network for crates).
#
# The app picks the binary up ONLY when this file exists (project.yml embeds it
# copy-if-present), and runs it ONLY behind the vortxNativeServer flag (default OFF), so
# skipping this script changes nothing about the shipping node+server.js path.
set -euo pipefail
cd "$(dirname "$0")/.."

ENGINE_DIR="${VORTX_ENGINE_DIR:-$HOME/vortx-engine/vortx-core}"
TARGET="aarch64-apple-darwin"
OUT="app/Vendor/vortx-streaming-server"

if [ ! -f "$ENGINE_DIR/crates/streaming-server/Cargo.toml" ]; then
    echo "ERROR: engine checkout not found at $ENGINE_DIR (set VORTX_ENGINE_DIR)" >&2
    echo "       The native server builds from the engine workspace, like the core xcframework." >&2
    exit 1
fi

source "$HOME/.cargo/env" 2>/dev/null || true

echo "Building vortx-streaming-server ($TARGET, release) from $ENGINE_DIR ..."
(cd "$ENGINE_DIR" && cargo build --release -p vortx-streaming-server --target "$TARGET")

mkdir -p app/Vendor
cp -f "$ENGINE_DIR/target/$TARGET/release/vortx-streaming-server" "$OUT"
chmod +x "$OUT"
echo "OK: $OUT ($(du -h "$OUT" | cut -f1 | tr -d ' '))"
