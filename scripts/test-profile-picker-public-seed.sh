#!/usr/bin/env bash
set -euo pipefail

# Actual public picker cache/load regression; no app/device or network request.
# Usage: bash scripts/test-profile-picker-public-seed.sh [positive|negative-warm-gate] [receipt-parent]
picker_script_dir="$(cd "$(dirname "$0")" && pwd)"
picker_source_root="$(cd "$picker_script_dir/.." && pwd -P)"
picker_template_dir="$picker_source_root/app/Tests"
picker_mode="${1:-positive}"
picker_receipt_parent="${2:-$picker_source_root/app/build}"
case "$picker_mode" in positive|negative-warm-gate) ;; *) exit 2 ;; esac
test -f "$picker_source_root/app/SourcesShared/ProfilesView.swift"
test -f "$picker_template_dir/ProfilePickerPublicSeedTests.swift"
mkdir -p "$picker_receipt_parent"
picker_receipt="$(mktemp -d "$picker_receipt_parent/profile-picker-public-seed.XXXXXX")"

node --input-type=module - "$picker_source_root" "$picker_template_dir" "$picker_receipt" "$picker_mode" <<'NODE'
import { readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { createHash } from 'node:crypto';
const [root, packet, output, mode] = process.argv.slice(2);
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
function unique(source, needle) {
  const begin = source.indexOf(needle);
  if (begin < 0 || source.indexOf(needle, begin + needle.length) >= 0)
    throw new Error(`Missing or ambiguous actual-source boundary: ${needle}`);
  return begin;
}
function declaration(source, signature) {
  const begin = unique(source, signature);
  let depth = 0, opened = false, state = 'code', escaped = false, blockDepth = 0;
  for (let i = begin; i < source.length; i++) {
    const c = source[i], next = source[i + 1];
    if (state === 'line') { if (c === '\n') state = 'code'; continue; }
    if (state === 'block') {
      if (c === '/' && next === '*') { blockDepth++; i++; }
      else if (c === '*' && next === '/') { blockDepth--; i++; if (!blockDepth) state = 'code'; }
      continue;
    }
    if (state === 'string') {
      if (escaped) escaped = false;
      else if (c === '\\') escaped = true;
      else if (c === '"') state = 'code';
      continue;
    }
    if (c === '/' && next === '/') { state = 'line'; i++; continue; }
    if (c === '/' && next === '*') { state = 'block'; blockDepth = 1; i++; continue; }
    if (c === '"') { state = 'string'; continue; }
    if (c === '{') { depth++; opened = true; }
    if (c === '}' && opened && --depth === 0) return source.slice(begin, i + 1);
  }
  throw new Error(`Unterminated actual declaration: ${signature}`);
}

const pickerPath = resolve(root, 'app/SourcesShared/ProfilesView.swift');
const addonPath = resolve(root, 'app/SourcesShared/Addon.swift');
const templatePath = resolve(packet, 'ProfilePickerPublicSeedTests.swift');
const source = readFileSync(pickerPath, 'utf8');
const addon = readFileSync(addonPath, 'utf8');
const movie = declaration(source, 'private struct ProfilePickerMovie:');
const classSignature = '@MainActor\nprivate final class ProfilePickerArtwork: ObservableObject';
const actualClass = declaration(source, classSignature);
const classStart = unique(source, classSignature);
const avatarStart = source.indexOf('private struct ProfileAvatarTile:', classStart);
if (avatarStart < 0 || classStart + actualClass.length > avatarStart || actualClass.length > 35_000)
  throw new Error('Artwork extraction escaped the bounded production class.');
for (const member of ['private static func publicMovieID(', 'private static func publicPoster(',
  'private static func readPublicSeed()', 'private static func writePublicSeed(',
  'private func showInitialCandidate() async', 'func load() async']) unique(actualClass, member);
if (actualClass.includes('CoreBridge') || actualClass.includes('ProfileStore') || actualClass.includes('VortXSyncManager'))
  throw new Error('Pre-profile public-artwork class acquired a private owner/profile dependency.');

const cacheURL = declaration(actualClass, 'private static var publicSeedURL: URL?');
let testedClass = actualClass.replace(cacheURL,
  'private static var publicSeedURL: URL? { FixtureCacheBoundary.seedURL }');
const transformations = [{ declaration: 'publicSeedURL', reason: 'disposable file location only',
  originalSHA256: hash(cacheURL), replacement: 'FixtureCacheBoundary.seedURL' }];
if (mode === 'negative-warm-gate') {
  const fastReturn = '        if movie != nil { return }\n';
  unique(testedClass, fastReturn);
  testedClass = testedClass.replace(fastReturn, '');
  transformations.push({ reason: 'intentional negative control', removed: fastReturn.trim() });
}
let template = readFileSync(templatePath, 'utf8');
const baseMatch = addon.match(/^    static let cinemeta = "[^"\n]+"$/m);
if (!baseMatch) throw new Error('Missing public Cinemeta constant.');
const replacements = {
  '/* ACTUAL_PUBLIC_MOVIE */': movie,
  '/* ACTUAL_ARTWORK_CLASS */': testedClass,
  '/* ACTUAL_META_PREVIEW */': declaration(addon, 'struct MetaPreview:'),
  '/* ACTUAL_CINEMETA_CONSTANT */': baseMatch[0].trim(),
};
for (const [marker, bytes] of Object.entries(replacements)) {
  unique(template, marker);
  template = template.replace(marker, () => bytes);
}
if (template.includes('/* ACTUAL_')) throw new Error('Unresolved production extraction marker.');
writeFileSync(resolve(output, 'ProfilePickerPublicSeed.generated.swift'), template);
const dependencies = ['app/SourcesShared/ArtworkFallbackPolicy.swift',
  'app/SourcesShared/HeroArtworkQualityPolicy.swift'];
const inputs = [pickerPath, addonPath, templatePath, ...dependencies.map(path => resolve(root, path))];
writeFileSync(resolve(output, 'source-sha256.txt'), inputs.map(path => `${hash(readFileSync(path))}  ${path}`).join('\n') + '\n');
writeFileSync(resolve(output, 'extraction-receipt.json'), JSON.stringify({
  sourceRoot: root, mode,
  productionDeclarations: [movie, actualClass].map(bytes => ({ sha256: hash(bytes), bytes: Buffer.byteLength(bytes) })),
  transformations,
  exactProductionDependencies: dependencies,
  boundaries: ['Combine ObservableObject/Published retained', 'image cache/load synthetic and main-actor isolated',
    'public catalog response manually held with no URLSession', 'cache URL redirected to receipt-local Caches'],
  notProven: ['SwiftUI composition', 'real PosterImageLoader byte/decode behavior', 'UI first-image elapsed timing',
    'device focus/network/cache behavior', 'physical iOS/iPadOS/tvOS rendering'],
}, null, 2) + '\n');
console.log(`Retained actual-production extraction: ${output}`);
NODE

picker_swiftc="${PICKER_SWIFTC_PATH:-$(xcrun --find swiftc)}"
picker_sdk="${PICKER_SDK_PATH:-$(xcrun --sdk macosx --show-sdk-path)}"
picker_arch="$(uname -m)"
printf 'Compiler: %s\nSDK: %s\nTarget: %s-apple-macos14.0\n' "$picker_swiftc" "$picker_sdk" "$picker_arch" > "$picker_receipt/toolchain.txt"
git -C "$picker_source_root" rev-parse HEAD > "$picker_receipt/source-head.txt"
nice -n 15 "$picker_swiftc" -j 1 -num-threads 1 -parse-as-library \
  -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -target "$picker_arch-apple-macos14.0" -sdk "$picker_sdk" \
  "$picker_source_root/app/SourcesShared/ArtworkFallbackPolicy.swift" \
  "$picker_source_root/app/SourcesShared/HeroArtworkQualityPolicy.swift" \
  "$picker_receipt/ProfilePickerPublicSeed.generated.swift" \
  -o "$picker_receipt/profile-picker-public-seed" 2>&1 | tee "$picker_receipt/compile.log"

set +e
nice -n 15 "$picker_receipt/profile-picker-public-seed" "$picker_receipt/Caches/public-seed.json" 2>&1 | tee "$picker_receipt/checks.log"
picker_run_status=${PIPESTATUS[0]}
set -e
shasum -a 256 -c "$picker_receipt/source-sha256.txt"
if [[ "$picker_mode" == negative-warm-gate ]]; then
  if [[ "$picker_run_status" -eq 0 ]] || ! rg -q '^FAIL warm load waited for the held catalog' "$picker_receipt/checks.log"; then
    printf '%s\n' 'Negative control did not fail at the intended warm catalog boundary.' >&2
    exit 1
  fi
  printf '%s\n' 'PASS negative control: removing the actual warm fast return is detected.'
elif [[ "$picker_run_status" -ne 0 ]]; then
  exit "$picker_run_status"
fi
printf 'Retained picker seed receipt: %s\n' "$picker_receipt"
