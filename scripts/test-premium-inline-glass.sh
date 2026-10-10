#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p app/build
glass_dir="app/build/premium-inline-glass.$$.${RANDOM}"
mkdir "$glass_dir"

# Actual production GlassStyle, Theme tokens and Library card, with RAM-only palette glue.
# ImageRenderer does not start VortX, NSApplication, accounts, storage, engine or a player.
node --input-type=module - "$glass_dir" <<'NODE'
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
const theme = read('app/SourcesShared/Theme.swift');
const root = read('app/SourcesiOS/iOSRootView.swift');
const settings = read('app/SourcesiOS/iOSSettingsView.swift');
writeFileSync(`${dir}/ProductionInlineGlass.swift`, `import SwiftUI
enum Theme {
  ${['enum Palette', 'enum Space', 'enum Radius', 'enum Typography'].map(start => block(theme, start)).join('\n')}
}
${block(root, 'private struct iOSLibraryHubCard:').replace('private ', '')}
${block(root, 'private struct iOSLibraryHubCardSurface:').replace('private ', '')}
// Compile the actual native Section modifier propagation without launching a native Form host.
struct ProductionSettingsSectionHost {
  var usesWideSettingsLayout = true
  ${block(settings, 'private var settingsRowInsets:').replace('private ', '')}
  ${block(settings, 'private func styledSettingsSection<').replace('private ', '')}
}
`);
NODE

for mode in oled warm; do
    glass_flags=()
    if [[ "$mode" == warm ]]; then glass_flags=(-D WARM_GLASS_FIXTURE); fi
    xcrun swiftc -parse-as-library -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
        "${glass_flags[@]}" "$glass_dir/ProductionInlineGlass.swift" app/SourcesShared/GlassStyle.swift \
        app/Tests/PremiumInlineGlassTests.swift -o "$glass_dir/fixture-$mode"
    "$glass_dir/fixture-$mode" "$PWD" "$glass_dir" "$mode" | tee "$glass_dir/fixture-$mode.log"
done
xcrun swiftc -frontend -parse app/SourcesShared/GlassStyle.swift \
    app/SourcesiOS/iOSSettingsView.swift app/SourcesiOS/iOSRootView.swift
printf '%s\n' "Retained inline glass receipt: $glass_dir"
