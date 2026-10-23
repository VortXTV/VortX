#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p app/build
fixture_dir=$(mktemp -d "$PWD/app/build/player-skip-chrome.XXXXXX")
node --input-type=module - "$fixture_dir" <<'NODE'
import assert from 'node:assert/strict';
import {readFileSync, writeFileSync} from 'node:fs';
const source = readFileSync('app/Sources/PlayerScreen.swift', 'utf8');
const glass = readFileSync('app/SourcesShared/GlassStyle.swift', 'utf8');
const start = source.indexOf('private enum PlayerSkipChromePolicy {');
assert(start >= 0, 'extract shipping policy');
let depth = 1, end = source.indexOf('{', start) + 1;
for (; depth && end < source.length; end++) {
  if (source[end] === '{') depth++;
  if (source[end] === '}') depth--;
}
assert.equal(depth, 0);
writeFileSync(`${process.argv[2]}/Policy.swift`, source.slice(start, end).replace('private enum', 'enum'));
assert(source.includes('PlayerSkipChromePolicy.showsPrompt(controlsVisible: controlsVisible,'));
assert(source.includes('value: geometry.size.height'), 'actual chrome measurement');
assert(source.includes('chromeHeight: Double(bottomChromeHeight)'), 'measurement reaches prompt');
assert(source.includes('!loadFailed, !stillWatchingPrompt,'), 'modal suppresses elevated manual Skip');
assert(source.includes('(!skipSharesChrome || !skipEditActive)'), 'Mac editor suppresses competing Skip action');
assert(source.includes('let promptAvailable = !controlsVisible && !isLocked'),
       'revealing manual Skip must not activate an automatic countdown during scrubbing');
const plateStart = glass.indexOf('private struct VortXPlayerBottomBackplateModifier:');
const plateEnd = glass.indexOf('extension View {', plateStart);
assert(plateStart >= 0 && plateEnd > plateStart, 'bound the actual shared video backplate');
const plate = glass.slice(plateStart, plateEnd);
assert(source.includes('.vortxPlayerBottomBackplate()') &&
       plate.includes('shadow: .bar') && plate.includes('tone: .scrim'),
       'video chrome uses the actual shared video scrim role');
console.log('PASS shipping consumer wiring; automatic-skip controls gate retained');
NODE
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -parse-as-library -num-threads 1 "$fixture_dir/Policy.swift" \
  app/Tests/PlayerSkipChromeTests.swift -o "$fixture_dir/checks"
"$fixture_dir/checks"
xcrun swiftc -frontend -parse app/Sources/PlayerScreen.swift
printf 'Retained player chrome checks: %s\n' "$fixture_dir"
