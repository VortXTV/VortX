#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p app/build
genre_dir=$(mktemp -d "$PWD/app/build/library-genre-facts.XXXXXX")
genre_inputs=(app/SourcesShared/LibraryGenreFacts.swift app/SourcesShared/LibraryWatchedMutationPolicy.swift
  app/SourcesShared/CoreModels.swift app/SourcesShared/VortxResourceBridge.swift
  app/Tests/LibraryGenreFactsTests.swift scripts/test-library-genre-facts.sh)
shasum -a 256 "${genre_inputs[@]}" > "$genre_dir/source-before.sha256"
node - "$genre_dir" <<'NODE'
const fs = require('node:fs'), assert = require('node:assert/strict');
const out = process.argv[2];
function member(source, marker) {
  const begin = source.indexOf(marker); assert.ok(begin >= 0, marker);
  const open = source.indexOf('{', begin);
  let depth = 0, quoted = false, escaped = false, lineComment = false;
  for (let i = open; i < source.length; i++) {
    const c = source[i], n = source[i + 1];
    if (lineComment) { if (c === '\n') lineComment = false; continue; }
    if (quoted) { if (escaped) escaped = false; else if (c === '\\') escaped = true; else if (c === '"') quoted = false; continue; }
    if (c === '/' && n === '/') { lineComment = true; i++; continue; }
    if (c === '"') { quoted = true; continue; }
    if (c === '{') depth++;
    if (c === '}' && --depth === 0) return source.slice(begin, i + 1);
  }
  throw new Error('Unbalanced production declaration: ' + marker);
}
const models = fs.readFileSync('app/SourcesShared/CoreModels.swift', 'utf8');
const resource = fs.readFileSync('app/SourcesShared/VortxResourceBridge.swift', 'utf8');
const combined = ['import Foundation', member(resource, 'indirect enum VortxJSON:'),
  member(models, 'struct CoreMeta:'), member(models, 'struct CoreLink:')].join('\n');
fs.writeFileSync(out + '/ProductionModels.swift', combined);
NODE
swiftc -swift-version 6 "$genre_dir/ProductionModels.swift" \
  app/SourcesShared/LibraryGenreFacts.swift app/SourcesShared/LibraryWatchedMutationPolicy.swift \
  app/Tests/LibraryGenreFactsTests.swift -o "$genre_dir/LibraryGenreFactsTests"
"$genre_dir/LibraryGenreFactsTests" | tee "$genre_dir/result.txt"
shasum -a 256 "${genre_inputs[@]}" > "$genre_dir/source-after.sha256"
cmp "$genre_dir/source-before.sha256" "$genre_dir/source-after.sha256"
printf 'Retained source-only genre fixture: %s\n' "$genre_dir"
