#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
NODE_OPTIONS='' exec nice -n 15 node scripts/test-native-owned-receipts.cjs "$@"
