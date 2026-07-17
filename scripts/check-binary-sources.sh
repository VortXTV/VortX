#!/usr/bin/env bash
# Fail if any source file contains a NUL byte.
#
# WHY THIS EXISTS (2026-07-16):
# android/app/src/main/kotlin/com/vortx/android/ui/viewmodel/DetailViewModel.kt carried a raw
# 0x00 inside a string literal. It compiled and ran fine, so no build, test or review caught it.
# But `file` classified the 684-line source as "data", so grep treated it as BINARY AND SILENTLY
# SKIPPED IT. Not "returned zero" - returned NOTHING. Every grep-based audit silently omitted it.
#
# It produced a real false conclusion: a grep for "mediaRef =" found nothing, which read as
# "Playable.mediaRef is never populated", which would have meant trickplay capture, Trakt/SIMKL
# scrobbling and skip-segment resolve were all dead. They were not: DetailViewModel.kt sets
# mediaRef at lines 343, 400 and 477.
#
# Use \uXXXX escapes for control characters in string literals. Runtime value identical, source
# stays greppable.
#
# NOTE ON THIS SCRIPT'S OWN HISTORY, which is the point:
# v1 used `grep -qP '\x00'`. BSD grep on macOS has no -P, and with stderr suppressed it returned
# non-zero, which the caller read as "clean". The guard reported OK on the very file that carries
# the NUL. It failed the same way the bug does: it answered "not found" when it meant "could not
# look". Detection is now done in python, which either reads the bytes or raises. Never suppress
# the error path of a detector.
set -uo pipefail

ROOT="${1:-.}"
status=0

while IFS= read -r f; do
  case "$f" in
    */node_modules/*|*/build/*|*/.git/*|*/Vendor/*|*/target/*|*/dist/*) continue ;;
  esac
  # Definitive: read the bytes. No regex engine, no platform flags, no silent skip.
  if python3 -c 'import sys; sys.exit(0 if bytes([0]) in open(sys.argv[1],"rb").read() else 1)' "$f"; then
    echo "ERROR: NUL byte in source file: $f"
    echo "       This makes grep silently skip the file. Use a \\uXXXX escape instead."
    status=1
  fi
done < <(find "$ROOT" \
  \( -name '*.kt' -o -name '*.kts' -o -name '*.swift' -o -name '*.ts' -o -name '*.tsx' \
     -o -name '*.js' -o -name '*.rs' -o -name '*.yml' -o -name '*.yaml' -o -name '*.json' \
     -o -name '*.md' -o -name '*.sh' \) -type f 2>/dev/null)

if [ "$status" -eq 0 ]; then
  echo "OK: no NUL bytes in source files."
fi
exit "$status"
