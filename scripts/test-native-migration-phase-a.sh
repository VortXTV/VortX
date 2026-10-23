#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
exec node scripts/test-native-migration-phase-a.cjs "$@"
