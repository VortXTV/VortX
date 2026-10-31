#!/usr/bin/env bash
set -euo pipefail
script_dir="$(dirname "$0")"
cd "$script_dir/.."

# Controlled C replies plus literal production capture/decoder declarations. The
# unrelated prepare/commit/revoke/query/render methods are intentionally excluded.
if [ "$#" -lt 1 ]; then echo "existing selected mpv/client.h required" >&2; exit 2; fi
header="$1"
if [ ! -f "$header" ] || [[ "$header" != /* ]] || [ "$(basename "$header")" != client.h ] ||
   [ "$(basename "$(dirname "$header")")" != mpv ]; then
  echo "absolute existing mpv/client.h required" >&2
  exit 2
fi
include_root="$(dirname "$(dirname "$header")")"
mkdir -p app/build
run="$(mktemp -d "$PWD/app/build/mpv-reference-capture-v2.XXXXXX")"
printf 'Capture source evidence: %s\n' "$run"
shasum -a 256 "$0" "$header" app/Sources/Player/MPVReferenceAlignmentCapture.swift \
  app/SourcesShared/SubtitleEmbeddedExtractor.swift app/Tests/MPVCaptureFixture.h \
  app/Tests/MPVCaptureFixture.c app/Tests/MPVReferenceAlignmentCaptureTests.swift \
  > "$run/inputs.sha256"

extractor=app/SourcesShared/SubtitleEmbeddedExtractor.swift
capture=app/Sources/Player/MPVReferenceAlignmentCapture.swift
[ "$(rg -c '^struct MPVReferenceAlignmentCapture: Sendable, Equatable \{' "$capture")" = 1 ]
[ "$(rg -c '^enum MPVOwnedSubtitleTransport \{' "$capture")" = 1 ]
[ "$(rg -c '^    static func isLocalFileInput\(' "$extractor")" = 1 ]
[ "$(rg -c '^    struct TimingLocalFileIdentity: ' "$extractor")" = 1 ]

node - "$run" "$capture" "$extractor" <<'NODE'
const fs = require('node:fs');
const crypto = require('node:crypto');
const args = process.argv.slice(2), out = args[0], capturePath = args[1], extractorPath = args[2];
const sha = value => crypto.createHash('sha256').update(value).digest('hex');
const read = path => fs.readFileSync(path, 'utf8');
function once(text, marker) {
  const index = text.indexOf(marker);
  if (index < 0 || text.indexOf(marker, index + marker.length) >= 0) {
    throw new Error('Nonunique/missing source boundary: ' + marker);
  }
  return index;
}
// Balanced declarations ignore braces in strings and line/nested-block comments.
// Unsupported literals fail closed rather than accepting a partial extraction.
function declaration(text, marker) {
  const start = once(text, marker), open = text.indexOf('{', start + marker.length);
  if (open < 0) throw new Error('Missing declaration body: ' + marker);
  let depth = 0, comment = 0, mode = 'code';
  for (let i = open; i < text.length; i++) {
    const c = text[i], n = text[i + 1];
    if (mode === 'line') { if (c === '\n') mode = 'code'; continue; }
    if (mode === 'block') {
      if (c === '/' && n === '*') { comment++; i++; }
      else if (c === '*' && n === '/') { i++; if (--comment === 0) mode = 'code'; }
      continue;
    }
    if (mode === 'string') { if (c === '\\') i++; else if (c === '"') mode = 'code'; continue; }
    if (c === '/' && n === '/') { mode = 'line'; i++; continue; }
    if (c === '/' && n === '*') { mode = 'block'; comment = 1; i++; continue; }
    if ((c === '#' && n === '"') || text.startsWith('"""', i)) {
      throw new Error('Unsupported literal in selected declaration: ' + marker);
    }
    if (c === '"') { mode = 'string'; continue; }
    if (c === '{') depth++;
    else if (c === '}' && --depth === 0) return text.slice(start, i + 1);
  }
  throw new Error('Unclosed selected declaration: ' + marker);
}
function arrayLiteral(text, marker) {
  const start = once(text, marker), open = text.indexOf('[', start + marker.length);
  if (open < 0) throw new Error('Missing array literal: ' + marker);
  const close = text.indexOf('\n    ]', open);
  if (close < 0) throw new Error('Unclosed array literal: ' + marker);
  return text.slice(start, close + '\n    ]'.length);
}
const source = read(capturePath), extractor = read(extractorPath);
const captureStruct = declaration(source, 'struct MPVReferenceAlignmentCapture: Sendable, Equatable');
const transportParts = [
  declaration(source, '    struct Snapshot: Sendable, Equatable'),
  declaration(source, '    enum Argument: Sendable'),
  declaration(source, '    private enum Value'),
  arrayLiteral(source, '    private static let snapshotKeys'),
  declaration(source, '    static func snapshot('),
  declaration(source, '    static func decodeSnapshot('),
  declaration(source, '    fileprivate static func packedPrimaryFlags('),
  declaration(source, '    private static func integer(_ value: Value?)'),
  declaration(source, '    private static func fields(_ node: mpv_node, count: Int)'),
  declaration(source, '    private static func exactFields(_ node: mpv_node, names: Set<String>)')
];
const transport = 'enum MPVOwnedSubtitleTransport {\n' + transportParts.join('\n\n') + '\n}';
const extractorParts = [
  declaration(extractor, '    static func isLocalFileInput('),
  declaration(extractor, '    struct TimingLocalFileIdentity: ')
];
const extractorDeclarations = 'enum SubtitleEmbeddedExtractor {\n' + extractorParts.join('\n\n') + '\n}';
const generated = [
  'import Foundation', 'import Darwin', 'import Libmpv', '',
  transport, '', extractorDeclarations, '', captureStruct, ''
].join('\n');
fs.writeFileSync(out + '/ReferenceCaptureDeclarations.swift', generated);
fs.writeFileSync(out + '/source-manifest.json', JSON.stringify({
  capture_source: capturePath,
  extractor_source: extractorPath,
  transport_declarations: transportParts.map(sha),
  capture_struct_sha256: sha(captureStruct),
  extractor_declarations_sha256: sha(extractorDeclarations),
  generated_sha256: sha(generated),
  composition: 'Literal MPVReferenceAlignmentCapture plus only the v2 Snapshot/Argument/Value/snapshot decoder helpers and exact field validators. Prepare/commit/revoke/payload/query/render APIs are intentionally excluded; no fake native authority is supplied.'
}, null, 2) + '\n');
NODE

printf '%s\n' '--- source extraction integrity ---'
rg -n '^struct MPVReferenceAlignmentCapture: Sendable, Equatable \{|^enum MPVOwnedSubtitleTransport \{|^    struct Snapshot: Sendable, Equatable|^    enum Argument: Sendable|^    private enum Value|^    private static let snapshotKeys|^    static func snapshot\(|^    static func decodeSnapshot\(|^    fileprivate static func packedPrimaryFlags\(|^    private static func integer\(_ value: Value\?\)|^    private static func fields\(_ node: mpv_node, count: Int\)|^    private static func exactFields\(_ node: mpv_node, names: Set<String>\)' "$capture" >/dev/null

printf '%s\n' 'module Libmpv { header "'"$PWD"'/app/Tests/MPVCaptureFixture.h" export * }' > "$run/module.modulemap"
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
  "$run/ReferenceCaptureDeclarations.swift" app/Tests/MPVReferenceAlignmentCaptureTests.swift \
  "$run/fixture.o" -o "$run/capture-tests"
nice -n 15 "$run/capture-tests"
shasum -a 256 --check "$run/inputs.sha256"
shasum -a 256 "$run/fixture.o" "$run/capture-tests" "$run/module.modulemap" \
  "$run/ReferenceCaptureDeclarations.swift" > "$run/artifacts.sha256"
printf 'Verified controlled capture composition: %s\n' "$run"
