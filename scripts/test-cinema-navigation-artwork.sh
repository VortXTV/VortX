#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p app/build
receipt="app/build/cinema-navigation-artwork.$$.${RANDOM}"
mkdir "$receipt"

# Compile the production bitmap crop, compositor timing and SwiftUI dissolve only.
# No app entry point, account, provider, playback or network owner is constructed.
node --input-type=module - "$receipt" <<'NODE'
import {readFileSync, writeFileSync} from 'node:fs';
const directory = process.argv[2];
const source = readFileSync('app/SourcesiOS/FeaturedHeroView.swift', 'utf8');
function declaration(start) {
  const begin = source.indexOf(start);
  if (begin < 0) throw new Error(`Missing production declaration: ${start}`);
  const brace = source.indexOf('{', begin);
  let depth = 1, end = brace + 1;
  for (; depth && end < source.length; end++) {
    if (source[end] === '{') depth++;
    if (source[end] === '}') depth--;
  }
  if (depth) throw new Error(`Unterminated production declaration: ${start}`);
  return source.slice(begin, end);
}
writeFileSync(`${directory}/ProductionArtworkLayers.swift`, `import SwiftUI
import AppKit
import QuartzCore
${declaration('enum KenBurnsPan {')}
${declaration('final class KenBurnsBackingView: NSView {')}
${declaration('struct CinemaNavigationArtworkLayerHost: NSViewRepresentable {')}
`);
NODE
xcrun swiftc -parse-as-library -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  "$receipt/ProductionArtworkLayers.swift" app/SourcesiOS/CinemaNavigationArtwork.swift \
  app/Tests/CinemaNavigationArtworkTests.swift -o "$receipt/navigation-artwork"
"$receipt/navigation-artwork" "$PWD" "$receipt"
xcrun swiftc -frontend -parse app/SourcesiOS/CinemaNavigationArtwork.swift \
  app/SourcesiOS/FeaturedHeroView.swift app/SourcesiOS/iOSRootView.swift app/SourcesiOS/iOSDetailView.swift
printf '%s\n' "Retained navigation artwork receipt: $receipt"
