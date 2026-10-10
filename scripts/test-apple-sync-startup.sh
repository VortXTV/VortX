#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
node test/apple-sync-startup.mjs "$@"
