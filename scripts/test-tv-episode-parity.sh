#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"

# Source seam checks also run before the implementation exists, without starting any compiler.
node --input-type=module <<'NODE'
import {readFileSync} from 'node:fs';
import assert from 'node:assert/strict';
const source = readFileSync('app/SourcesTV/DetailView.swift', 'utf8');
const view = source.slice(source.indexOf('struct CoreSeasonedEpisodes: View {'),
                          source.indexOf('private struct EpisodeThumbImage: View {'));
assert(view.includes('private func markEpisodeWatched('), 'TV row must use an acknowledged action');
assert(view.includes('try await core.markNativeVideoWatched('), 'native mutation must await persistence');
assert(view.includes('.disabled(manualWatchedAction.isRunning)'), 'duplicate watched gestures must be disabled');
assert(view.includes('ProgressView("Updating watched status…")'), 'pending acknowledgement must be visible');
assert(view.includes('manualWatchedAction.errorMessage'), 'failure must be visible for a retry');
assert(view.includes('.onDisappear {'), 'dismissal must retire presentation and deferred focus');
assert(view.includes('manualWatchedAction.cancel()'), 'scope changes must retire the action');
assert(view.includes('TVEpisodeInitialPositionPolicy()'), 'initial vertical placement must use production policy');
assert(view.includes('watchedVideoIds != nil'), 'missing restored native history cannot mean unwatched');
assert(view.includes('core.nativePlaybackTargetIsCurrent(.capture(core: core))'), 'initial placement requires a current native binding');
assert(view.includes('watched: localWatched'), 'initial placement uses profile authority, not Trakt display ticks');
assert(view.includes('initialPosition.userInteracted('), 'remote interaction must retire initial placement');
assert(view.includes('pendingFocusEpisode == request'), 'deferred focus must reject replaced requests');
assert(view.includes('request.scope == episodeScope'), 'deferred focus must reject account/profile/title changes');
assert(view.includes('TVDetailEpisodeListFocusPolicy.rowOwnsUpEscape(at: index)'), 'only row zero owns Up escape');
assert(!view.includes('DragGesture'), 'TV list must retain native remote navigation');
console.log('PASS TV episode source seams: awaited watched, restored history, one-shot placement, remote focus ownership');
NODE
if [[ "${1:-}" == "--source-only" ]]; then exit 0; fi

mkdir -p app/build
receipt=$(mktemp -d app/build/tv-episode-parity.XXXXXX)
# Compile the production action body unchanged with held acknowledgements. No account, storage,
# native session, playback, network, or app entry point is created by this fixture.
node --input-type=module - "$receipt" <<'NODE'
import {readFileSync, writeFileSync} from 'node:fs';
const source = readFileSync('app/SourcesTV/DetailView.swift', 'utf8');
function declaration(marker) {
  const start = source.indexOf(marker);
  const brace = source.indexOf('{', start);
  let depth = 1, end = brace + 1;
  for (; depth && end < source.length; end++) {
    if (source[end] === '{') depth++;
    if (source[end] === '}') depth--;
  }
  if (start < 0 || depth) throw new Error(`Missing production declaration: ${marker}`);
  return source.slice(start, end).replace('private func', 'func').replace('private struct', 'struct');
}
const action = declaration('private func markEpisodeWatched(');
writeFileSync(`${process.argv[2]}/ProductionTVWatchedAction.swift`, `import Foundation
@MainActor final class ProductionTVWatchedAction {
    let core = HeldCore()
    let profiles = FixtureProfiles()
    let manualWatchedAction = ProfileMutationPresentation()
    var detailTarget = FixtureDetailTarget(id: "show", type: "series")
    var interactions = 0
    func noteEpisodeInteraction() { interactions += 1 }
    ${action}
}
`);
writeFileSync(`${process.argv[2]}/ProductionTVEpisodeFocus.swift`, `import Foundation
@MainActor final class ProductionTVEpisodeFocus {
    let core = HeldCore()
    let presenter = FixturePresenter()
    var season = 1
    var episodes = [CoreVideo(id: "ep1"), CoreVideo(id: "ep44")]
    var episodeScope = "profileA:credential1:series:show"
    var pendingFocusEpisode: EpisodeFocusRequest?
    var initialPosition = TVEpisodeInitialPositionPolicy()
    var focusInteractionGeneration: UInt64 = 0
    var didApplyInitial = false
    ${declaration('private struct EpisodeFocusRequest: Equatable {')}
    ${declaration('private func focusRequestIsCurrent(')}
    ${declaration('private func requestEpisodeFocus(')}
    ${declaration('private func noteEpisodeInteraction(')}
}
`);
NODE
xcrun swiftc -D VORTX_NATIVE_DATA_ENGINE -parse-as-library -swift-version 6 \
  -strict-concurrency=complete -warnings-as-errors \
  app/SourcesShared/EpisodeRailInitialPositionPolicy.swift \
  app/SourcesTV/TVEpisodeInitialPositionPolicy.swift app/SourcesShared/ProfileMutationPresentation.swift \
  "$receipt/ProductionTVWatchedAction.swift" "$receipt/ProductionTVEpisodeFocus.swift" \
  app/Tests/TVEpisodeParityTests.swift \
  -o "$receipt/episode-tests"
"$receipt/episode-tests"
xcrun swiftc -frontend -parse -D VORTX_NATIVE_DATA_ENGINE app/SourcesTV/DetailView.swift \
  app/SourcesTV/TVEpisodeInitialPositionPolicy.swift
xcrun swiftc -frontend -parse app/SourcesTV/DetailView.swift app/SourcesTV/TVEpisodeInitialPositionPolicy.swift
printf '%s\n' "Retained TV episode parity receipt: $receipt"
