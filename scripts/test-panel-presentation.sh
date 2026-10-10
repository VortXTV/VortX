#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p app/build
fixture_dir="app/build/panel-presentation.$$.${RANDOM}"
mkdir "$fixture_dir"

# Compile the exact production viewport and typography components in an isolated ImageRenderer fixture.
# Only palette glue is inert; no app lifecycle, accounts, profiles, engine, or provider code is loaded.
node --input-type=module - "$fixture_dir" <<'NODE'
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
const addons = read('app/SourcesShared/AddonsView.swift');
const settings = read('app/SourcesiOS/iOSSettingsView.swift');
const palette = ['enum Palette', 'enum Space', 'enum Radius', 'enum Typography']
  .map(start => block(theme, start)).join('\n');
const addonColumn = block(addons, 'private struct AddonPanelScrollContainer<')
  .replace('private struct ', 'struct ');
const addonSurface = block(addons, 'private struct AddonSurfaceModifier:')
  .replace('private struct ', 'struct ');
const addonView = block(addons, 'struct AddonsView: View {');
const addonBody = block(addonView, 'var body: some View {');
const settingsTypography = block(settings, 'private struct MacSettingsTypography:')
  .replace('private struct ', 'struct ');
const macShell = block(settings, 'private var macSettingsShell: some View {');
if (!/AddonPanelScrollContainer\(maxContentWidth:\s*usesWideAddonLayout\s*\?\s*1120\s*:\s*\.infinity\)/.test(addonBody) ||
    (addonBody.match(/AddonPanelScrollContainer\(/g) || []).length !== 1) {
  throw new Error('AddonsView body is not using the extracted production viewport/column component');
}
if ((macShell.match(/Form\s*\{/g) || []).length !== 1 ||
    (macShell.match(/modifier\(MacSettingsTypography\(\)\)/g) || []).length !== 1) {
  throw new Error('Mac Settings typography modifier is not attached to the real Form body');
}
writeFileSync(`${dir}/ProductionPanelPresentation.swift`, `import SwiftUI
struct ThemeManager {
  static let shared = ThemeManager()
  let textScale = 1.0
  let accent = Color(.sRGB, red: 0.851, green: 0.467, blue: 0.024)
  let accentBright = Color(.sRGB, red: 0.961, green: 0.620, blue: 0.043)
  let onAccent = Color(.sRGB, red: 0.059, green: 0.051, blue: 0.039)
  let canvas = Color.black
  let surface1 = Color(.sRGB, red: 0.055, green: 0.055, blue: 0.057)
  let surface2 = Color(.sRGB, red: 0.094, green: 0.094, blue: 0.098)
  let surface3 = Color(.sRGB, red: 0.141, green: 0.141, blue: 0.149)
  let hairline = Color(.sRGB, red: 0.196, green: 0.196, blue: 0.204)
  let glassVeil = Color(.sRGB, red: 0.265, green: 0.265, blue: 0.265)
}
enum Theme { ${palette} }
${addonColumn}
${addonSurface}
${settingsTypography}
`);
NODE

xcrun swiftc -parse-as-library -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
    "$fixture_dir/ProductionPanelPresentation.swift" app/SourcesShared/GlassStyle.swift \
    app/Tests/PanelPresentationTests.swift -o "$fixture_dir/panel-presentation"
"$fixture_dir/panel-presentation" "$PWD/$fixture_dir"
printf '%s\n' "Retained panel presentation receipt: $fixture_dir"
