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

REPO_ROOT="$(pwd)"
# Resolve the engine workspace the same way build-ffi-xcframework.sh does: an explicit override, then
# a candidate list, rather than one hardcoded default. The old single default was
# $HOME/vortx-engine/vortx-core, which was a WORKTREE of the public repo holding 316k engine files.
# That worktree was deliberately removed on 2026-07-25 (engine source must not sit in a public-repo
# worktree), so this script's only default pointed at a path that no longer exists.
ENGINE_DIR="${VORTX_ENGINE_DIR:-}"
if [ -z "$ENGINE_DIR" ]; then
    for cand in "$REPO_ROOT/vortx-core" "$HOME/vortx-core" "$REPO_ROOT/../vortx-engine/vortx-core" "$HOME/vortx-engine/vortx-core"; do
        if [ -f "$cand/crates/streaming-server/Cargo.toml" ]; then ENGINE_DIR="$cand"; break; fi
    done
fi
TARGET="aarch64-apple-darwin"
OUT="app/Vendor/vortx-streaming-server"

if [ -z "$ENGINE_DIR" ] || [ ! -f "$ENGINE_DIR/crates/streaming-server/Cargo.toml" ]; then
    echo "ERROR: engine workspace not found. The native server builds from it, like the core xcframework." >&2
    echo "       Looked at: \$VORTX_ENGINE_DIR, $REPO_ROOT/vortx-core, $HOME/vortx-core," >&2
    echo "       $REPO_ROOT/../vortx-engine/vortx-core, $HOME/vortx-engine/vortx-core" >&2
    echo "" >&2
    echo "       The engine is PROPRIETARY and lives in the private repo VortXTV/vortx-core." >&2
    echo "       Clone it OUTSIDE this repo (never as a worktree of the public one):" >&2
    echo "         git clone https://github.com/VortXTV/vortx-core.git ~/vortx-core" >&2
    echo "       A local git bundle also exists at ~/vortx-engine-backup/ as a second copy." >&2
    exit 1
fi
echo "engine workspace: $ENGINE_DIR"

source "$HOME/.cargo/env" 2>/dev/null || true

echo "Building vortx-streaming-server ($TARGET, release) from $ENGINE_DIR ..."
(cd "$ENGINE_DIR" && cargo build --release -p vortx-streaming-server --target "$TARGET")

mkdir -p app/Vendor
cp -f "$ENGINE_DIR/target/$TARGET/release/vortx-streaming-server" "$OUT"
chmod +x "$OUT"
echo "OK: $OUT ($(du -h "$OUT" | cut -f1 | tr -d ' '))"
