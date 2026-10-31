#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo"
test -d app/build
run_dir=$(mktemp -d "$PWD/app/build/addon-subtitle-file.XXXXXX")
trap 'rm -rf "$run_dir"' EXIT
# Read the exact genuine budget/cue/parser span; no parser or receipt is reimplemented.
python3 - "$run_dir/SubtitleParser.swift" <<'PY'
import hashlib
from pathlib import Path
import sys

source = Path("app/Sources/Player/SubtitleCueRenderer.swift").read_bytes()
start = b"enum SubtitleFileBudget {\n"
end = b"\n/// Downloads external subtitle bytes"
if source.count(start) != 1 or source.count(end) != 1:
    raise SystemExit("Subtitle parser source fences changed")
first = source.index(start)
last = source.index(end, first)
declarations = source[first:last]
print("Renderer source SHA-256 " + hashlib.sha256(source).hexdigest())
print("Parser span bytes " + str(first) + "..<" + str(last) + " SHA-256 "
      + hashlib.sha256(declarations).hexdigest())
Path(sys.argv[1]).write_bytes(b"import Foundation\n\n" + declarations + b"\n")
PY
test -s "$run_dir/SubtitleParser.swift"
mkdir -p "$run_dir/tmp" "$run_dir/module-cache"
export TMPDIR="$run_dir/tmp"
nice -n 15 xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -parse-as-library -j 1 -num-threads 1 -module-cache-path "$run_dir/module-cache" \
  app/SourcesShared/AddonPairingProtocol.swift \
  app/SourcesShared/SubtitleRequestMetadata.swift \
  app/SourcesShared/AddonURLGuard.swift \
  app/SourcesShared/SubtitleAddons.swift \
  app/Tests/AddonSubtitleFileClientFixtures.swift \
  "$run_dir/SubtitleParser.swift" \
  app/SourcesShared/AddonSubtitleFileClient.swift \
  app/SourcesShared/PooledSubtitleSelectionPolicy.swift \
  app/Tests/AddonSubtitleFileClientTests.swift \
  -o "$run_dir/subtitle-addon-file-tests"
"$run_dir/subtitle-addon-file-tests"
