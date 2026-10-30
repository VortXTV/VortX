#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
test "$#" -eq 0
repo=$(pwd -P)
base="$repo/app/build/apple-playlist-store-host"
cache="$repo/app/build/swift-host-fixture-module-cache"
python3 - "$repo" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1]).resolve(strict=True)
for relative in ["app/build/apple-playlist-store-host", "app/build/swift-host-fixture-module-cache"]:
    if not (root / relative).resolve().is_relative_to(root):
        raise SystemExit("fixture output/cache escapes repository")
PY
mkdir -p "$base" "$cache/swift" "$cache/clang"
lock="$cache/.serial-compile-lock"
if ! mkdir "$lock"; then
    echo 'Another owned host-fixture invocation holds the compile/cache lock.' >&2
    exit 1
fi
trap 'rmdir "$lock"' EXIT
run=$(mktemp -d "$base/run.XXXXXX")
python3 scripts/extract-apple-playlist-store-host.py "$repo" "$run/generated"

# Exactly one serial compiler invocation, then one non-GUI host process. No private engine
# SDK/native module, account, Keychain, checkpoint, network, app or media process is launched.
if ! nice -n 15 xcrun --sdk macosx swiftc \
    -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
    -j 1 -num-threads 1 -whole-module-optimization -parse-as-library \
    -module-cache-path "$cache/swift" -Xcc "-fmodules-cache-path=$cache/clang" \
    "$run/generated/GenuineStoreHostDefinitions.swift" \
    app/SourcesShared/PlaybackTitleQueuePolicy.swift \
    app/SourcesShared/VortxNativeHostFieldMutation.swift \
    app/SourcesShared/VortxNativePlaylist.swift \
    app/SourcesShared/OwnerHistoryExactJSON.swift \
    app/SourcesShared/NativePlaylistCloudReceiptLedger.swift \
    app/SourcesShared/NativePlaylistCloudReceiptProjectionWorker.swift \
    app/SourcesShared/SavedPlaylistStore.swift \
    app/Tests/SavedPlaylistStoreHostCollaborators.swift \
    app/Tests/SavedPlaylistStoreHostTests.swift \
    -o "$run/store-host" > "$run/compiler.log" 2>&1; then
    cat "$run/compiler.log"
    exit 1
fi
nice -n 15 "$run/store-host" | tee "$run/runtime.log"
printf 'Retained host fixture evidence: %s\n' "$run"
