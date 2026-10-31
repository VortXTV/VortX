#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p app/build
genre_ui_dir=$(mktemp -d "$PWD/app/build/library-genre-filter.XXXXXX")
genre_ui_inputs=(app/SourcesShared/LibraryGenreFacts.swift app/SourcesShared/LibraryGenreFilter.swift
  app/SourcesShared/VortxResourceBridge.swift app/Tests/LibraryGenreFilterTests.swift scripts/test-library-genre-filter.sh)
shasum -a 256 "${genre_ui_inputs[@]}" > "$genre_ui_dir/source-before.sha256"
node - "$genre_ui_dir" <<'NODE'
const fs = require('node:fs'), assert = require('node:assert/strict');
const out = process.argv[2], source = fs.readFileSync('app/SourcesShared/VortxResourceBridge.swift', 'utf8');
const marker = 'indirect enum VortxJSON:', begin = source.indexOf(marker);
assert.ok(begin >= 0);
let depth = 0, quoted = false, escaped = false, lineComment = false, end = -1;
for (let i = source.indexOf('{', begin); i < source.length; i++) {
  const c = source[i], n = source[i + 1];
  if (lineComment) { if (c === '\n') lineComment = false; continue; }
  if (quoted) { if (escaped) escaped = false; else if (c === '\\') escaped = true; else if (c === '"') quoted = false; continue; }
  if (c === '/' && n === '/') { lineComment = true; i++; continue; }
  if (c === '"') { quoted = true; continue; }
  if (c === '{') depth++;
  if (c === '}' && --depth === 0) { end = i + 1; break; }
}
assert.ok(end > begin);
fs.writeFileSync(out + '/PublicJSON.swift', 'import Foundation\n' + source.slice(begin, end));
NODE
swiftc -swift-version 6 "$genre_ui_dir/PublicJSON.swift" app/SourcesShared/LibraryGenreFacts.swift \
  app/SourcesShared/LibraryGenreFilter.swift app/Tests/LibraryGenreFilterTests.swift -o "$genre_ui_dir/LibraryGenreFilterTests"
"$genre_ui_dir/LibraryGenreFilterTests" | tee "$genre_ui_dir/result.txt"
shasum -a 256 "${genre_ui_inputs[@]}" > "$genre_ui_dir/source-after.sha256"
cmp "$genre_ui_dir/source-before.sha256" "$genre_ui_dir/source-after.sha256"
printf 'Retained pure genre-filter fixture: %s\n' "$genre_ui_dir"
