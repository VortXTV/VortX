#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
node_bin="$(command -v node)"
[[ "$node_bin" == /* && -x "$node_bin" ]] || { printf 'FAIL: absolute node executable is required\n' >&2; exit 1; }
exec "$node_bin" "$repo_root/scripts/test-subtitle-mount-owner.cjs"
