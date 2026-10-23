#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Standalone synthetic source unit, not an app/SDK build. Run one mode at a time.
# Developer convenience wrapper, not a sandbox or release-acceptance gate.
cw_swift_mode="${1:-6}"
case "$cw_swift_mode" in
  5|6) ;;
  *) printf '%s\n' 'Usage: bash scripts/test-cw-preferences.sh [5|6]' >&2; exit 2 ;;
esac
if [[ "$(uname -s)" != Darwin ]]; then
  printf '%s\n' 'This source unit requires the macOS Foundation/os APIs.' >&2
  exit 2
fi

cw_repo_root="$PWD"
mkdir -p app/_build
cw_stage="$cw_repo_root/$(mktemp -d app/_build/cw-preferences.XXXXXX)"
mkdir -p "$cw_stage/home" "$cw_stage/tmp" "$cw_stage/module-cache"
printf 'Retaining Swift %s source-unit output: %s\n' "$cw_swift_mode" "$cw_stage"
cw_sdk="$(xcrun --sdk macosx --show-sdk-path)"
cw_compiler="$(xcrun --sdk macosx --find swiftc)"
cw_target="$(uname -m)-apple-macosx14.0"
cw_environment=(HOME="$cw_stage/home" CFFIXED_USER_HOME="$cw_stage/home"
  TMPDIR="$cw_stage/tmp" TMP="$cw_stage/tmp" TEMP="$cw_stage/tmp"
  CLANG_MODULE_CACHE_PATH="$cw_stage/module-cache" SWIFT_MODULECACHE_PATH="$cw_stage/module-cache")

/usr/bin/nice -n 15 /usr/bin/env "${cw_environment[@]}" "$cw_compiler" \
  -parse-as-library -swift-version "$cw_swift_mode" -strict-concurrency=complete \
  -warnings-as-errors -whole-module-optimization -j 1 -num-threads 1 \
  -target "$cw_target" -sdk "$cw_sdk" -module-cache-path "$cw_stage/module-cache" \
  app/SourcesShared/ContinueWatchingPreferences.swift \
  app/Tests/ContinueWatchingPreferencesSourceTests.swift -o "$cw_stage/cw-preferences"
/usr/bin/nice -n 15 /usr/bin/env "${cw_environment[@]}" "$cw_stage/cw-preferences"
printf 'Retained Swift %s source-unit output: %s\n' "$cw_swift_mode" "$cw_stage"
