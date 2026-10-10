#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p app/build
publication_test_dir=$(mktemp -d "$PWD/app/build/addon-stream-publication.XXXXXX")
publication_source_ref=${1:-working-tree}
printf 'Source %s\nRetained output %s\n' "$publication_source_ref" "$publication_test_dir"
node - "$publication_test_dir" "$publication_source_ref" <<'NODE'
const fs = require('node:fs');
const cp = require('node:child_process');
const [out, ref] = process.argv.slice(2);
const read = path => ref === 'working-tree' ? fs.readFileSync(path, 'utf8') : cp.execFileSync('git', ['show', `${ref}:${path}`], {encoding:'utf8'});
function block(source, marker) {
  const begin = source.indexOf(marker);
  if (begin < 0) throw new Error(`Missing declaration ${marker}`);
  const open = source.indexOf('{', begin);
  let depth = 1, end = open + 1;
  for (; depth && end < source.length; end++) {
    if (source[end] === '{') depth++;
    if (source[end] === '}') depth--;
  }
  if (depth) throw new Error(`Unbalanced declaration ${marker}`);
  return source.slice(begin, end);
}
const core = read('app/SourcesShared/CoreBridge.swift');
const models = read('app/SourcesShared/CoreModels.swift');
fs.writeFileSync(`${out}/CoreBridge.swift`, core);
fs.writeFileSync(`${out}/CoreModels.swift`, models);
// Reuse only this existing fixture's inert peripheral collaborators; all models, decoding,
// projection, comparison, accepted-publication statements and group assembly are production code.
const stubs = read('app/Tests/BingeSourceMemoryRaceContractTests.swift');
const start = stubs.indexOf('enum DebridService:');
const end = stubs.indexOf('// MARK: - StreamRanking peripheral stubs');
if (start < 0 || end < start) throw new Error('Missing inert collaborator boundaries');
fs.writeFileSync(`${out}/Collaborators.swift`, 'import Foundation\n' + stubs.slice(start, end) + '\n' + block(stubs, 'enum ProfileStore {') + `
extension VortXSyncManager {
  static func orderedByApplied<T>(_ values: [T], url: (T) -> String) -> [T] { values }
}
`);
const declarations = [
  block(read('app/SourcesShared/VortxNativeRuntime.swift'), 'enum VortxNativeError:'),
  block(read('app/SourcesShared/ContinueWatchingDedupe.swift'), 'enum WatchedMembershipPolicy {'),
];
const predicates = ['private static func metaDetailsNeedsRepublish(', 'private static func metaDetailsStreamsChanged('];
predicates.push(core.includes('private static func streamSetsEqual(') ? 'private static func streamSetsEqual(' : 'private static func streamSetSignature(');
declarations.push(`@MainActor final class AddonPublicationProbe {
  var metaDetails: CoreMetaDetails?
  var streamsEpoch = 0
  var indexerStarts = 0
  var names: [String: String] = [:]
  func addonNamesByBase() -> [String: String] { names }
  func isTombstonedAddonBase(_ base: String, removed: Set<String>) -> Bool { false }
  func startNZBIndexerSearchIfNeeded(details: CoreMetaDetails) { indexerStarts += 1 }
  ${predicates.map(marker => block(core, marker)).join('\n')}
  ${block(core, 'private func assembleStreamGroups(')}
  func needs(_ next: CoreMetaDetails?) -> Bool { Self.metaDetailsNeedsRepublish(current: metaDetails, next: next) }
  func streamsChange(_ next: CoreMetaDetails?) -> Bool { Self.metaDetailsStreamsChanged(current: metaDetails, next: next) }
  func groups(streamID: String? = nil) -> [CoreStreamSourceGroup] {
    guard let metaDetails else { return [] }
    return assembleStreamGroups(metaDetails, streamId: streamID)
  }
  // Actual accepted publication branch. The account/profile/refind fences surrounding it
  // remain outside this fixture and are unchanged by the production patch.
  func accept(_ details: CoreMetaDetails?) {
    ${block(core, 'if Self.metaDetailsNeedsRepublish(current: self.metaDetails, next: details) {')}
  }
}`);
fs.writeFileSync(`${out}/ProductionPublication.swift`, 'import Foundation\n' + declarations.join('\n'));
for (const name of ['VortxResourceBridge', 'VortxResourceProjection', 'DetailMetaRecoveryPolicy', 'CatalogRowResolution', 'SubtitleReleaseFingerprint', 'UsenetStreamValidation', 'DiagnosticPlaybackIntegrityPolicy', 'ProfileAddonPreferences']) {
  fs.writeFileSync(`${out}/${name}.swift`, read(`app/SourcesShared/${name}.swift`));
}
NODE
if [[ "${2:-}" == --prepare-only ]]; then
  printf 'Prepared exact source extraction; no compiler or executable run\n'
  exit 0
fi
xcrun swiftc -parse-as-library -warnings-as-errors -D VORTX_NATIVE_DATA_ENGINE \
  "$publication_test_dir/Collaborators.swift" "$publication_test_dir/CoreModels.swift" \
  "$publication_test_dir/ProductionPublication.swift" "$publication_test_dir/VortxResourceBridge.swift" \
  "$publication_test_dir/VortxResourceProjection.swift" "$publication_test_dir/DetailMetaRecoveryPolicy.swift" \
  "$publication_test_dir/CatalogRowResolution.swift" "$publication_test_dir/SubtitleReleaseFingerprint.swift" \
  "$publication_test_dir/UsenetStreamValidation.swift" "$publication_test_dir/DiagnosticPlaybackIntegrityPolicy.swift" \
  "$publication_test_dir/ProfileAddonPreferences.swift" app/Tests/AddonStreamPublicationTests.swift \
  -o "$publication_test_dir/addon-stream-publication"
set +e
"$publication_test_dir/addon-stream-publication" | tee "$publication_test_dir/test.log"
publication_status=${PIPESTATUS[0]}
set -e
shasum -a 256 "$publication_test_dir/CoreBridge.swift" "$publication_test_dir/CoreModels.swift" \
  "$publication_test_dir/ProductionPublication.swift" "$publication_test_dir/addon-stream-publication" \
  "$publication_test_dir/test.log" app/Tests/AddonStreamPublicationTests.swift scripts/test-addon-stream-publication.sh
exit "$publication_status"
