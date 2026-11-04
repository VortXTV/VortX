#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="$PWD/app/build/account-backup-file"
mkdir -p "$build_dir"
swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -j 1 -num-threads 1 \
  app/SourcesShared/VortXSyncCrypto.swift \
  app/SourcesShared/VortxNativeBootstrapArchive.swift \
  app/SourcesShared/VortxAccountBackupFile.swift \
  app/Tests/VortxAccountBackupFileTests.swift -o "$build_dir/account-backup-file-tests"
"$build_dir/account-backup-file-tests"
