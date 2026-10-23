#!/bin/zsh
# Renders the production GlassEpisodeCard and TitleExtraCard offscreen and checks their geometry. Theme tokens
# are extracted from Theme.swift, the rating plate and its model from their production files; the palette
# and TMDBClient.TitleVideo are inert stand-ins.
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p app/build
receipt="app/build/glass-episode-card.$$.${RANDOM}"
mkdir "$receipt"
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
  return source.slice(begin, end);
}
const theme = read('app/SourcesShared/Theme.swift');
const tokens = ['enum Palette', 'enum Space', 'enum Radius', 'enum Motion', 'enum Typography']
  .map(start => block(theme, start)).join('\n');
const titleVideo = block(read('app/SourcesShared/TMDBClient.swift'), 'struct TitleVideo: Identifiable, Hashable, Sendable {');
const badge = read('app/SourcesShared/CardRatingBadge.swift');
const ratingViews = ['struct RatingBadgeFit: View {', 'struct RatingBadgePlate: View {'].map(start => block(badge, start)).join('\n');
const ratingsModel = block(read('app/SourcesShared/MDBListClient.swift'), 'struct MDBListRatings: Equatable {');
writeFileSync(`${directory}/Fixture.swift`, `import SwiftUI
final class ThemeManager: ObservableObject, @unchecked Sendable {
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
enum TMDBClient { ${titleVideo} }
${ratingsModel}
${ratingViews}
`);
NODE
xcrun swiftc -parse-as-library -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  "$receipt/Fixture.swift" app/SourcesShared/GlassStyle.swift app/SourcesShared/VisualEffects.swift \
  app/SourcesShared/RatingsFormat.swift app/SourcesShared/RatingLogo.swift app/SourcesShared/GlassEpisodeCard.swift \
  app/Tests/GlassEpisodeCardRenderTests.swift -o "$receipt/render"
"$receipt/render" "$receipt"
