#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"

mkdir -p app/build
receipt="app/build/ui-seams-contracts.$$.${RANDOM}"
mkdir "$receipt"

xcrun swiftc -parse-as-library -swift-version 6 -warnings-as-errors \
app/Tests/UIScreenshotSeamsContractTests.swift -o "$receipt/ui-seams-contracts"
"$receipt/ui-seams-contracts"
printf '%s\n' "Retained source-contract receipt: $receipt"
