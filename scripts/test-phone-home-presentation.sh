#!/usr/bin/env bash
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

swift app/Tests/PhoneHomePresentationContractTests.swift "$PWD"
xcrun swiftc -frontend -parse app/SourcesiOS/iOSRootView.swift

printf '%s\n' 'ok: compact Home presentation and bounded hero signal contracts are parseable'
