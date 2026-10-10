#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p app/build
# A shell-local unique directory avoids the host's intermittent inherited-pipe hang
# in mktemp command/process substitutions. mkdir is exclusive; no existing receipt is overwritten.
character_dir="app/build/home-cinema-character.$$.${RANDOM}"
mkdir "$character_dir"

# Compile the actual production tint gate, publication task/callback, Home callback and
# canvas component with RAM-only hosts. No CoreBridge, accounts, player or app entry point.
node --input-type=module - "$character_dir" <<'NODE'
import {readFileSync, writeFileSync} from 'node:fs';
const dir = process.argv[2];
const read = path => readFileSync(path, 'utf8');
function block(text, start) {
  const begin = text.indexOf(start);
  if (begin < 0) throw new Error(`Missing production declaration: ${start}`);
  const brace = text.indexOf('{', begin);
  let depth = 1, end = brace + 1;
  for (; depth && end < text.length; end++) {
    if (text[end] === '{') depth++;
    if (text[end] === '}') depth--;
  }
  if (depth) throw new Error(`Unterminated production declaration: ${start}`);
  return text.slice(begin, end);
}
const hero = read('app/SourcesiOS/FeaturedHeroView.swift');
const root = read('app/SourcesiOS/iOSRootView.swift');
const theme = read('app/SourcesShared/Theme.swift');
const task = block(hero, '.task(id: heroTintKey)');
const taskBody = task.slice(task.indexOf('{') + 1, -1);
const declarations = [block(hero, 'struct FeaturedHeroTintKey:'), block(hero, 'struct FeaturedHeroTintSnapshot<Tint>'),
  block(theme, 'enum HomeAtmospherePolicy'), block(root, 'private struct HomeCinemaAtmosphere:').replace('private ', ''),
  block(root, 'private struct CinemaCardExternalLiftKey:').replace('private ', ''),
  block(root, 'private extension EnvironmentValues').replace('private ', '')];
writeFileSync(`${dir}/ProductionCharacter.swift`, `import SwiftUI
${declarations.join('\n')}
@MainActor final class ProductionHeroTintHost {
  var heroTintKey = FeaturedHeroTintKey(id: nil, type: nil, artwork: nil)
  var heroTint: FeaturedHeroTintSnapshot<Color>?
  var onTintChange: (@MainActor (FeaturedHeroTintSnapshot<Color>) -> Void)?
  var reduceMotion = true
  func sampleCurrentHero() async { ${taskBody} }
  @MainActor ${block(hero, 'private func publishHeroTint(').replace('private ', '')}
}
@MainActor final class ProductionHomeTintHost {
  var homeHeroTintKey = FeaturedHeroTintKey(id: nil, type: nil, artwork: nil)
  var homeHeroTint: FeaturedHeroTintSnapshot<Color>?
  @MainActor ${block(root, 'private func acceptHomeHeroTint(').replace('private ', '')}
}
`);
NODE

xcrun swiftc -parse-as-library -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  "$character_dir/ProductionCharacter.swift" app/Tests/HomeCinemaCharacterTests.swift \
  -o "$character_dir/character"
"$character_dir/character" "$PWD" "$character_dir" | tee "$character_dir/fixture.log"
xcrun swiftc -frontend -parse app/SourcesiOS/FeaturedHeroView.swift \
  app/SourcesiOS/iOSRootView.swift app/SourcesShared/Theme.swift
printf '%s\n' "Retained character receipt: $character_dir"
