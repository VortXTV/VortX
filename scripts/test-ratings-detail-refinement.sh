#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p app/build
receipt="app/build/ratings-detail-refinement.$$.${RANDOM}"
mkdir "$receipt"

# Only the actual model and store declarations are extracted. No live service, preferences write,
# credential owner, native engine, app entry point or player is constructed by these policy cases.
node --input-type=module - "$receipt" <<'NODE'
import {readFileSync, writeFileSync} from 'node:fs';
const directory = process.argv[2];
function declaration(path, start) {
  const source = readFileSync(path, 'utf8');
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
writeFileSync(`${directory}/ProductionRatingStore.swift`, `import Foundation
${declaration('app/SourcesShared/MDBListClient.swift', 'struct MDBListRatings: Equatable {')}
@MainActor
${declaration('app/SourcesShared/CardRatingBadge.swift', 'final class CardRatingStore {')}
`);
for (const [platform, path] of [['IOS', 'app/SourcesiOS/iOSDetailView.swift'], ['TV', 'app/SourcesTV/DetailView.swift']]) {
  // Only the two transport collaborators are substituted with held responses. The actual lease,
  // key-change reset, cancellation, gap merge and publication fences are compiled unchanged.
  const load = declaration(path, 'private func loadRatings()')
    .replaceAll('VortXRatingsClient.ratings', 'FixtureVortXRatings.ratings')
    .replaceAll('MDBListClient.ratings', 'FixtureMDBListRatings.ratings');
  writeFileSync(`${directory}/Production${platform}DetailRatings.swift`, `import Foundation
@MainActor final class Production${platform}DetailRatings: DetailRatingsHarness {
  var mdbRatings: MDBListRatings?
  var ratingsKey: RatingRequestKey?
  var ratingsTask: Task<Void, Never>?
  var ratingsGeneration: UUID?
  var currentRatingsRequest: RatingRequestKey?
  func begin(_ key: RatingRequestKey?) { currentRatingsRequest = key; loadRatings() }
  ${load}
}
`);
}
NODE
xcrun swiftc -parse-as-library -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  "$receipt/ProductionRatingStore.swift" "$receipt/ProductionIOSDetailRatings.swift" \
  "$receipt/ProductionTVDetailRatings.swift" app/SourcesShared/VortXRatings.swift app/SourcesShared/RatingsFormat.swift \
  app/SourcesShared/EpisodeRailInitialPositionPolicy.swift app/Tests/RatingsFreshnessAndEpisodeRailTests.swift \
  -o "$receipt/refinement-tests"
"$receipt/refinement-tests"
xcrun swiftc -frontend -parse app/SourcesiOS/iOSDetailView.swift app/SourcesiOS/CinemaPresentation.swift \
  app/SourcesTV/DetailView.swift app/SourcesTV/SharedUI.swift app/SourcesShared/CardRatingBadge.swift
printf '%s\n' "Retained ratings/detail refinement receipt: $receipt"
