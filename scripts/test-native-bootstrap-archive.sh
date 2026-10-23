#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
exec bash scripts/test-native-migration-phase-a.sh bootstrap
