#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Controlled C replies, not real libmpv or playback. Require an existing genuine
# client header; do not fetch a substitute or link any player/framework binary.
header="${1:?existing selected mpv/client.h required}"
[[ -f "$header" && "$header" == /* && "$(basename "$header")" == client.h ]]
[[ "$(basename "$(dirname "$header")")" == mpv ]]
include_root="$(dirname "$(dirname "$header")")"
mkdir -p app/build
run=$(mktemp -d "$PWD/app/build/mpv-reference-capture.XXXXXX")
printf 'Capture source evidence: %s\n' "$run"
inputs=("$0" "$header" app/Sources/Player/MPVReferenceAlignmentCapture.swift
    app/SourcesShared/SubtitleEmbeddedExtractor.swift app/Tests/MPVCaptureFixture.h
    app/Tests/MPVCaptureFixture.c app/Tests/MPVReferenceAlignmentCaptureTests.swift)
shasum -a 256 "${inputs[@]}" > "$run/inputs.sha256"

# Keep only the literal two declarations used by capture. There is no substitute
# FFmpeg/container/extractor implementation in this test composition.
extractor=app/SourcesShared/SubtitleEmbeddedExtractor.swift
[[ $(rg -c '^    static func isLocalFileInput\(' "$extractor") == 1 ]]
[[ $(rg -c '^    struct TimingLocalFileIdentity: ' "$extractor") == 1 ]]
{
    printf '%s\n' 'import Foundation' 'import Darwin' 'enum SubtitleEmbeddedExtractor {'
    sed -n '/^    static func isLocalFileInput(/,/^    }/p' "$extractor"
    sed -n '/^    struct TimingLocalFileIdentity: /,/^    }/p' "$extractor"
    printf '%s\n' '}'
} > "$run/ExtractorDeclarations.swift"
printf 'module Libmpv { header "%s" export * }\n' "$PWD/app/Tests/MPVCaptureFixture.h" > "$run/module.modulemap"
host_arch="$(uname -m)"
case "$host_arch" in arm64|x86_64) ;; *) echo 'Unsupported host architecture' >&2; exit 2 ;; esac
sdk="$(xcrun --sdk macosx --show-sdk-path)"
target="$host_arch-apple-macosx14.0"
nice -n 15 xcrun --sdk macosx clang -target "$target" -isysroot "$sdk" \
    -std=c11 -Wall -Wextra -Werror -I "$include_root" \
    -c app/Tests/MPVCaptureFixture.c -o "$run/fixture.o"
nice -n 15 xcrun swiftc -parse-as-library -swift-version 6 \
    -strict-concurrency=complete -warnings-as-errors -j 1 -num-threads 1 \
    -sdk "$sdk" -target "$target" -module-cache-path "$run/module-cache" \
    -I "$run" -Xcc -I -Xcc "$include_root" \
    app/Sources/Player/MPVReferenceAlignmentCapture.swift "$run/ExtractorDeclarations.swift" \
    app/Tests/MPVReferenceAlignmentCaptureTests.swift "$run/fixture.o" -o "$run/capture-tests"
nice -n 15 "$run/capture-tests"
shasum -a 256 --check "$run/inputs.sha256"
shasum -a 256 "$run/fixture.o" "$run/capture-tests" "$run/module.modulemap" \
    "$run/ExtractorDeclarations.swift" > "$run/artifacts.sha256"
printf 'Verified controlled capture composition: %s\n' "$run"
