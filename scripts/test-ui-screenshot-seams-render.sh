#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p app/build
receipt="app/build/ui-screenshot-seams.$$.${RANDOM}"
mkdir "$receipt"

# Extract only the actual owned presentation declarations. The fixture supplies inert model/palette
# values; it does not construct the app, account, source resolver, playback, provider or media pipeline.
node --input-type=module - "$receipt" <<'NODE'
import {readFileSync, writeFileSync} from 'node:fs';
const directory = process.argv[2];
const read = path => readFileSync(path, 'utf8');
function block(source, start) {
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
const theme = read('app/SourcesShared/Theme.swift');
const detail = read('app/SourcesiOS/iOSDetailView.swift');
const root = read('app/SourcesiOS/iOSRootView.swift');
const artwork = read('app/SourcesiOS/CinemaNavigationArtwork.swift');
const featured = read('app/SourcesiOS/FeaturedHeroView.swift');
const tokens = ['enum Palette', 'enum Space', 'enum Radius', 'enum Motion', 'enum Typography']
  .map(start => block(theme, start)).join('\n');
const homeAtmospherePolicy = block(theme, 'enum HomeAtmospherePolicy {');
const components = [
  `@MainActor ${block(root, 'private final class CinemaNavigationArtworkPresentation: ObservableObject {').replace('private ', '')}`,
  block(root, 'private struct CinemaNavigationArtworkBackground: View {').replace('private ', ''),
  block(detail, 'struct CinemaEpisodeRailCard: View {'),
  block(detail, 'private struct iOSSourceRowFocusStyle: ButtonStyle {').replaceAll('private ', ''),
  block(detail, 'private struct iOSSourceRowFocusContent: View {').replaceAll('private ', '')
].join('\n');
writeFileSync(`${directory}/ProductionUIScreenshotSeams.swift`, `import SwiftUI
import AppKit
import CoreGraphics
import QuartzCore
struct ThemeManager {
  static let shared = ThemeManager()
  let textScale = 1.0
  var canvas: Color { .black }
  var surface1: Color { Color(.sRGB, red: 0.055, green: 0.055, blue: 0.057) }
  var surface2: Color { Color(.sRGB, red: 0.094, green: 0.094, blue: 0.098) }
  var surface3: Color { Color(.sRGB, red: 0.141, green: 0.141, blue: 0.149) }
  var hairline: Color { Color(.sRGB, red: 0.196, green: 0.196, blue: 0.204) }
  var glassVeil: Color { Color(.sRGB, red: 0.188, green: 0.188, blue: 0.196) }
  var accent: Color { Color(.sRGB, red: 0.851, green: 0.467, blue: 0.024) }
  var accentBright: Color { Color(.sRGB, red: 0.961, green: 0.620, blue: 0.043) }
  var onAccent: Color { Color(.sRGB, red: 0.059, green: 0.051, blue: 0.039) }
}
enum Theme { ${tokens} }
${homeAtmospherePolicy}
${block(artwork, 'struct CinemaNavigationArtwork: Equatable {')}
${block(artwork, 'struct CinemaNavigationArtworkStrip: View {')}
${block(featured, 'enum KenBurnsPan {')}
${block(featured, 'final class KenBurnsBackingView: NSView {')}
${block(featured, 'struct CinemaNavigationArtworkLayerHost: NSViewRepresentable {')}
${components}
`);
NODE

xcrun swiftc -parse-as-library -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  "$receipt/ProductionUIScreenshotSeams.swift" app/SourcesShared/GlassStyle.swift \
  app/Tests/UIScreenshotSeamsRenderTests.swift -o "$receipt/ui-screenshot-seams-render"
"$receipt/ui-screenshot-seams-render" "$receipt"
printf '%s\n' "Retained inert render receipt: $receipt"
