#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p app/build
file_access_dir="$(mktemp -d "$PWD/app/build/account-file-access.XXXXXX")"
shasum -a 256 app/SourcesShared/VortxAccountFileAccess.swift \
  app/Tests/VortxAccountFileAccessTests.swift > "$file_access_dir/source-sha256.txt"
swiftc -parse-as-library -swift-version 6 -strict-concurrency=complete \
  -warnings-as-errors -j 1 -num-threads 1 \
  app/SourcesShared/VortxAccountFileAccess.swift app/Tests/VortxAccountFileAccessTests.swift \
  -o "$file_access_dir/checks" 2>&1 | tee "$file_access_dir/compile.log"
"$file_access_dir/checks" 2>&1 | tee "$file_access_dir/test.log"
shasum -a 256 -c "$file_access_dir/source-sha256.txt"
printf 'Retained account file access checks: %s\n' "$file_access_dir"
