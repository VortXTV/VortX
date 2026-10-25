#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
publication_source_ref=working-tree
publication_prepare_only=0
publication_benchmark=0
publication_swift_version=6
while (($#)); do
  case "$1" in
    --prepare-only) publication_prepare_only=1; shift ;;
    --benchmark) publication_benchmark=1; shift ;;
    --swift-version)
      [[ $# -ge 2 && ( "$2" == 5 || "$2" == 6 ) ]] || { printf 'Expected --swift-version 5 or 6\n' >&2; exit 2; }
      publication_swift_version=$2; shift 2 ;;
    --*) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
    *) [[ "$publication_source_ref" == working-tree ]] || { printf 'Only one source ref is allowed\n' >&2; exit 2; }
       publication_source_ref=$1; shift ;;
  esac
done
mkdir -p app/build
publication_test_dir=$(mktemp -d "$PWD/app/build/addon-stream-publication.XXXXXX")
printf 'Source %s\nRetained output %s\nSwift version %s; benchmark %s\n' \
  "$publication_source_ref" "$publication_test_dir" "$publication_swift_version" "$publication_benchmark"
publication_compile_status=not-run
publication_runtime_status=not-run
publication_phase=extract
publication_supervisor="$PWD/test/mpv-bounded-child.mjs"
publication_receipt() {
  publication_exit=$?
  trap - EXIT
  set +e
  if [[ -f "$publication_test_dir/input-manifest.json" ]]; then
    node - "$publication_test_dir" "$publication_source_ref" > "$publication_test_dir/conservation.log" 2>&1 <<'NODE'
const fs = require('node:fs'), cp = require('node:child_process'), crypto = require('node:crypto');
const [out, ref] = process.argv.slice(2);
const manifest = JSON.parse(fs.readFileSync(`${out}/input-manifest.json`, 'utf8'));
for (const entry of manifest.inputs) {
  for (const bytes of [fs.readFileSync(`${out}/inputs/${entry.path}`), entry.origin === 'working-tree'
    ? fs.readFileSync(entry.path) : cp.execFileSync('git', ['show', `${ref}:${entry.path}`])]) {
    if (bytes.length !== entry.bytes || crypto.createHash('sha256').update(bytes).digest('hex') !== entry.sha256)
      throw new Error(`Input changed: ${entry.path}`);
  }
}
console.log(`Conserved ${manifest.inputs.length} input snapshots and original source inputs`);
NODE
    [[ $? -eq 0 ]] || publication_exit=3
  fi
  if [[ -f "$publication_test_dir/generated-before.sha256" ]]; then
    shasum -a 256 "$publication_test_dir/Collaborators.swift" \
      "$publication_test_dir/ProductionResourceValues.swift" "$publication_test_dir/ProductionPublication.swift" \
      "$publication_test_dir/guarded-mode.txt" "$publication_test_dir/guarded-extraction.json" \
      > "$publication_test_dir/generated-after.sha256"
    [[ $? -eq 0 ]] || publication_exit=3
    cmp -s "$publication_test_dir/generated-before.sha256" "$publication_test_dir/generated-after.sha256" || publication_exit=3
  fi
  printf 'source=%s\nswift_version=%s\nbenchmark=%s\ncompile_status=%s\nruntime_status=%s\nexit=%s\n' \
    "$publication_source_ref" "$publication_swift_version" "$publication_benchmark" \
    "$publication_compile_status" "$publication_runtime_status" "$publication_exit" > "$publication_test_dir/status.txt"
  printf 'phase=%s\nscope=whole-models-extracted-publication-resource-values-RAM-not-native-session-or-app\n' \
    "$publication_phase" >> "$publication_test_dir/status.txt"
  shasum -a 256 "$publication_test_dir/status.txt"
  for publication_artifact in input-manifest.json Collaborators.swift ProductionResourceValues.swift ProductionPublication.swift guarded-mode.txt guarded-extraction.json library-caller-contract.txt error-sidecar-source-contract.txt extractor-tests.log compiler.log test.log addon-stream-publication; do
    if [[ -f "$publication_test_dir/$publication_artifact" ]]; then
      shasum -a 256 "$publication_test_dir/$publication_artifact"
    fi
  done
  printf 'Retained receipt: %s/status.txt\n' "$publication_test_dir"
  exit "$publication_exit"
}
trap publication_receipt EXIT
node - "$publication_test_dir" "$publication_source_ref" <<'NODE'
const fs = require('node:fs');
const cp = require('node:child_process');
const crypto = require('node:crypto');
const path = require('node:path');
const [out, ref] = process.argv.slice(2);
const names = ['VortxResourceBridge', 'VortxResourceProjection', 'DetailMetaRecoveryPolicy',
  'CatalogRowResolution', 'SubtitleReleaseFingerprint', 'UsenetStreamValidation',
  'DiagnosticPlaybackIntegrityPolicy', 'ProfileAddonPreferences'];
const inputs = ['app/SourcesShared/CoreBridge.swift', 'app/SourcesShared/CoreModels.swift',
  'app/Tests/BingeSourceMemoryRaceContractTests.swift', 'app/SourcesShared/VortxNativeRuntime.swift',
  'app/SourcesShared/ContinueWatchingDedupe.swift', ...names.map(name => `app/SourcesShared/${name}.swift`),
  'app/Tests/AddonStreamPublicationTests.swift', 'scripts/test-addon-stream-publication.sh',
  'test/mpv-bounded-child.mjs', 'test/addon-guarded-presentation-inputs.cjs',
  'test/addon-guarded-presentation-inputs.test.cjs',
  'test/metadata-frame-source-contracts.cjs', 'app/SourcesShared/VortxNativeCoreFacade.swift',
  'app/Tests/GuardedMetadataPresentationCases.swift'];
// Operational harness bytes are always the ones executing now, even for a historical model ref.
const harness = new Set(['scripts/test-addon-stream-publication.sh', 'test/mpv-bounded-child.mjs',
  'test/addon-guarded-presentation-inputs.cjs', 'test/addon-guarded-presentation-inputs.test.cjs',
  'test/metadata-frame-source-contracts.cjs', 'app/Tests/GuardedMetadataPresentationCases.swift']);
const origin = name => ref === 'working-tree' || harness.has(name) ? 'working-tree' : ref;
// Capture every input ONCE. Compiler and source checks use only conserved bytes.
const captured = new Map(inputs.map(name => [name, origin(name) === 'working-tree'
  ? fs.readFileSync(name) : cp.execFileSync('git', ['show', `${ref}:${name}`])]));
const manifest = [];
for (const [name, bytes] of captured) {
  const retained = path.join(out, 'inputs', name);
  fs.mkdirSync(path.dirname(retained), {recursive: true});
  fs.writeFileSync(retained, bytes);
  manifest.push({path: name, origin: origin(name), bytes: bytes.length,
    sha256: crypto.createHash('sha256').update(bytes).digest('hex')});
}
fs.writeFileSync(`${out}/input-manifest.json`, JSON.stringify({source:ref, inputs:manifest}, null, 2) + '\n');
const read = name => captured.get(name).toString('utf8');
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
const stubs = read('app/Tests/BingeSourceMemoryRaceContractTests.swift');
const start = stubs.indexOf('enum DebridService:');
const end = stubs.indexOf('// MARK: - StreamRanking peripheral stubs');
if (start < 0 || end < start) throw new Error('Missing inert collaborator boundaries');
fs.writeFileSync(`${out}/Collaborators.swift`, 'import Foundation\n' + stubs.slice(start, end) + '\n'
  + block(stubs, 'enum ProfileStore {') + `
// This fixture-only immutable, fieldless collaborator can satisfy checked
// Sendable. No production formatter/model conformance is mocked or changed.
extension DebridKeys: Sendable {}
extension CommunityStreamGateway: Sendable {}
extension DebridPlaybackAvailability: Sendable {}
extension VortXSyncManager {
  static func orderedByApplied<T>(_ values: [T], url: (T) -> String) -> [T] { values }
}
`);
// Exact production Player attribution method and matching predicate. Only input storage, dispatch and
// diagnostic collaborators are inert: no native engine, user state, stream or account mutation is used.
const originLoader = block(core, 'func loadEnginePlayer(for stream: CoreStream, sourceGroupID:');
const originMatcher = block(core, 'private func streamMatches(');
fs.appendFileSync(`${out}/Collaborators.swift`, `
@MainActor final class SourceOriginBindingProbe {
  let metadata: Data
  var dispatched: [[String: Any]] = []
  init(_ object: [String: Any]) throws { metadata = try JSONSerialization.data(withJSONObject: object) }
  func stateData(_ field: String) -> Data? { field == "meta_details" ? metadata : nil }
  func dispatch(action: [String: Any], field: String) -> Bool {
    guard field == "player" else { return false }; dispatched.append(action); return true
  }
  enum DiagnosticsLog { static func log(_ category: String, _ message: String) {} }
  ${originLoader}
  ${originMatcher}
}
`);
const declarations = [
  block(read('app/SourcesShared/VortxNativeRuntime.swift'), 'enum VortxNativeError:'),
  block(read('app/SourcesShared/ContinueWatchingDedupe.swift'), 'enum WatchedMembershipPolicy {'),
];
const bridge = read('app/SourcesShared/VortxResourceBridge.swift');
const resourceMarkers = ['indirect enum VortxJSON: Codable, Equatable, Sendable {',
  'struct VortxResourceRequest: Codable, Equatable, Sendable {',
  'struct VortxResourceAddon: Codable, Sendable {', 'struct VortxResourceGroup: Decodable, Sendable {',
  'struct VortxResourceSnapshot: Sendable {'];
// Exact production value declarations only. Neither VortxEngine import/C ABI nor
// transport/lease execution is compiled or mocked by this pure host fixture.
fs.writeFileSync(`${out}/ProductionResourceValues.swift`, 'import Foundation\n'
  + resourceMarkers.map(marker => block(bridge, marker)).join('\n'));
const guarded = core.includes('private final class MetadataPresentation');
fs.writeFileSync(out + '/guarded-mode.txt', guarded ? '1\n' : '0\n');
if (guarded) {
  // Load the operational helper FROM THE CAPTURED INPUT, never a second live read.
  const helper = {exports:{}};
  Function('module', 'exports', read('test/addon-guarded-presentation-inputs.cjs'))(helper, helper.exports);
  const slices = [];
  const extracted = helper.exports.guardedPublication(core,
    read('app/Tests/GuardedMetadataPresentationCases.swift'), slices);
  const contractHelper = {exports:{}};
  Function('module', 'exports', read('test/metadata-frame-source-contracts.cjs'))(contractHelper, contractHelper.exports);
  const sourceContract = contractHelper.exports.frameSourceContracts(core,
    read('app/SourcesShared/VortxNativeCoreFacade.swift'), helper.exports.exact, slices);
  if (sourceContract.ok !== true) throw Error('Current frame source contract failed: ' + JSON.stringify(sourceContract));
  fs.writeFileSync(out + '/ProductionPublication.swift',
    'import Foundation\nimport CoreFoundation\nimport Combine\nimport os\n'
    + declarations.join('\n') + '\n' + extracted.source);
  const hash = text => crypto.createHash('sha256').update(text).digest('hex');
  fs.writeFileSync(out + '/guarded-extraction.json', JSON.stringify({
    sourceContract, productionTransformations:extracted.productionTransformations,
    negativeControlTransformations:extracted.negativeControlTransformations,
    fixtureOnly:extracted.fixtureOnly,
    slices:slices.map(({bytes, ...entry}) => ({...entry, bytes:Buffer.byteLength(bytes), sha256:hash(bytes)})),
    scope:'real-Models-and-exact-source-linearized-frame-owner-RAM-not-original-native-pipeline-runtime'
  }, null, 2) + '\n');
  fs.writeFileSync(out + '/library-caller-contract.txt',
    'Current owned library overlay source contract; quiet value/epoch cases retained. Not native owner runtime.\n');
  fs.writeFileSync(out + '/error-sidecar-source-contract.txt',
    'Current source-linearized immutable frame/same-buffer/nil-phase/source-task-ABA/pending-clear contracts; remove-one negatives. Exact frame owner executes separately; real F/source runtime is NOT claimed.\n');
} else {
  fs.writeFileSync(out + '/guarded-extraction.json',
    JSON.stringify({scope:'historical-Published-path-no-current-owner-proof'}) + '\n');
const hasLibraryMerge = core.includes('private static func libraryMetaDetailsUpdate(');
if (!hasLibraryMerge && ref === 'working-tree') throw new Error('Missing current library overlay merge');
const hasStatusProjection = core.includes('private static func streamAddonStatusProjection(');
if (!hasStatusProjection && ref === 'working-tree') throw new Error('Missing current accepted error sidecar');
const predicates = ['private static func metaDetailsNeedsRepublish(', 'private static func metaDetailsStreamsChanged(',
  'private static func currentReadyStreamCount('];
if (hasLibraryMerge) predicates.push('private static func libraryMetaDetailsUpdate(');
if (hasStatusProjection) predicates.push('private static func streamAddonStatusProjection(',
  'private static func describeResourceError(', 'private func beginStreamAddonStatusAdmission(',
  'private func acceptStreamAddonStatus(');
predicates.push(core.includes('private static func streamSetsEqual(')
  ? 'private static func streamSetsEqual(' : 'private static func streamSetSignature(');
let statusFixture = '';
if (hasStatusProjection) {
  const signalDeclaration = '@Published private var streamAddonStatusSignal = UUID()';
  const generationDeclaration = 'private var streamAddonStatusAdmissionGeneration = UUID()';
  const payloadDeclaration = 'private var acceptedStreamAddonStatus: StreamAddonStatusProjection?';
  for (const declaration of [signalDeclaration, generationDeclaration, payloadDeclaration]) {
    if (!core.includes(declaration)) throw new Error(`Missing actual status declaration ${declaration}`);
  }
  const acceptance = block(core, 'private func acceptStreamAddonStatus(');
  const postFence = 'guard streamAddonStatusAdmissionGeneration == originalGeneration else { return }';
  if (acceptance.split(postFence).length !== 2) throw new Error('Expected exactly one post-signal original fence');
  // Explicit negative control only: rename the actual helper and remove exactly that one guard.
  // All other production statements are retained; runtime tests must expose the counterexample.
  const unfenced = acceptance.replace('private func acceptStreamAddonStatus(',
    'private func acceptStreamAddonStatusWithoutPostFence(').replace(postFence,
    '// Negative control: post-signal original-generation fence intentionally removed.');
  const dataAcceptance = (name, acceptName) => `func ${name}(_ data: Data) throws {
    let details = try JSONDecoder().decode(CoreMetaDetails?.self, from: data)
    let streamAddonStatus = try Self.streamAddonStatusProjection(data: data, details: details)
    let statusGeneration = self.beginStreamAddonStatusAdmission()
    ${block(core, 'if Self.metaDetailsNeedsRepublish(current: self.metaDetails, next: details) {')}
    self.${acceptName}(streamAddonStatus, originalGeneration: statusGeneration)
  }`;
  statusFixture = `${block(core, 'struct StreamAddonState:')}
  ${block(core, 'private struct StreamAddonStatusRow:')}
  ${block(core, 'private struct StreamAddonStatusProjection:')}
  ${payloadDeclaration}
  ${generationDeclaration}
  ${signalDeclaration}
  var statusPublications = 0
  private var publicationSubscriptions: Set<AnyCancellable> = []
  init() {
    $metaDetails.dropFirst().sink { [weak self] _ in self?.metadataPublications += 1 }
      .store(in: &publicationSubscriptions)
    $streamAddonStatusSignal.dropFirst().sink { [weak self] _ in self?.statusPublications += 1 }
      .store(in: &publicationSubscriptions)
  }
  ${block(core, 'func streamAddonStates(')}
  ${dataAcceptance('acceptData', 'acceptStreamAddonStatus')}
  ${unfenced}
  ${dataAcceptance('acceptDataWithoutPostFence', 'acceptStreamAddonStatusWithoutPostFence')}`;
}
declarations.push(`@MainActor final class AddonPublicationProbe: ObservableObject {
  var metadataPublications = 0
  ${hasStatusProjection ? block(core, '@Published private(set) var metaDetails: CoreMetaDetails?')
    : 'var metaDetails: CoreMetaDetails? { didSet { metadataPublications += 1 } }'}
  @Published private(set) var streamsEpoch = 0
  ${statusFixture}
  var indexerStarts = 0
  var names: [String: String] = [:]
  func addonNamesByBase() -> [String: String] { names }
  func isTombstonedAddonBase(_ base: String, removed: Set<String>) -> Bool { false }
  func startNZBIndexerSearchIfNeeded(details: CoreMetaDetails) { indexerStarts += 1 }
  ${predicates.map(marker => block(core, marker)).join('\n')}
  ${block(core, 'private func assembleStreamGroups(')}
  func needs(_ next: CoreMetaDetails?) -> Bool { Self.metaDetailsNeedsRepublish(current: metaDetails, next: next) }
  func streamsChange(_ next: CoreMetaDetails?) -> Bool { Self.metaDetailsStreamsChanged(current: metaDetails, next: next) }
  func readyCount(_ group: [String: Any]) -> Int? { Self.currentReadyStreamCount(group) }
  // Actual pure merge helper; surrounding account/request fences are source-checked below,
  // not executed as a real CoreBridge receipt in this RAM fixture.
  ${hasLibraryMerge ? `func acceptLibrary(_ next: CoreMetaDetails?) {
    if let merged = Self.libraryMetaDetailsUpdate(current: metaDetails, next: next) { metaDetails = merged }
  }` : ''}
  func groups(streamID: String? = nil) -> [CoreStreamSourceGroup] {
    guard let metaDetails else { return [] }
    return assembleStreamGroups(metaDetails, streamId: streamID)
  }
  // Actual coalesced typed branch only. Native account/request/executor ownership is NOT modeled.
  func accept(_ details: CoreMetaDetails?) {
    ${block(core, 'if Self.metaDetailsNeedsRepublish(current: self.metaDetails, next: details) {')}
  }
}`);
fs.writeFileSync(`${out}/ProductionPublication.swift`, 'import Foundation\nimport CoreFoundation\nimport Combine\n' + declarations.join('\n'));
if (hasLibraryMerge) {
const libraryStart = core.indexOf('let requestGeneration = metaLoadTargetLock.withLock { nativeMetaRequestGeneration }');
if (libraryStart < 0) throw new Error('Missing library request generation capture');
const libraryClosure = block(core.slice(libraryStart), 'DispatchQueue.main.async { [weak self] in');
const libraryGuards = ['self.publicationStillCurrent(publicationToken)',
  'CredentialScopeRegistry.shared.isCurrent(credentialCapture)',
  'self.metaLoadTargetLock.withLock({ self.nativeMetaRequestGeneration == requestGeneration })',
  'Self.libraryMetaDetailsUpdate(current: self.metaDetails, next: details)', 'self.metaDetails = merged'];
function libraryCallerAccepts(source) {
  return libraryGuards.every(guard => source.includes(guard)) && !source.includes('self.metaDetails = details');
}
if (!libraryCallerAccepts(libraryClosure)) throw new Error('Library overlay caller contract failed');
for (const guard of libraryGuards) {
  if (libraryCallerAccepts(libraryClosure.replace(guard, 'REMOVED_GUARD'))) throw new Error('Library caller negative control accepted');
}
fs.writeFileSync(`${out}/library-caller-contract.txt`, 'Actual library overlay caller contract PASS; five guard-removal negatives rejected; not executor/native receipt proof\n');
} else {
  fs.writeFileSync(`${out}/library-caller-contract.txt`, 'Historical source predates library overlay merge; no new caller contract result claimed\n');
}
if (hasStatusProjection) {
  const coalescer = block(core, 'private func scheduleMetaDetailsRepublish(capturedPublicationToken');
  const worker = block(coalescer, 'DispatchQueue.global(qos: .userInitiated).async { [weak self] in');
  const admission = block(worker, 'DispatchQueue.main.async { [weak self] in');
  const acceptance = block(core, 'private func acceptStreamAddonStatus(');
  const getter = block(core, 'func streamAddonStates(');
  const observer = block(core, '@Published private(set) var metaDetails: CoreMetaDetails?');
  const projection = block(core, 'private static func streamAddonStatusProjection(');
  const workerNeeds = ['guard let data = self.stateData("meta_details") else { return }',
    'details = try Self.decoder.decode(CoreMetaDetails?.self, from: data)',
    'streamAddonStatus = try Self.streamAddonStatusProjection(data: data, details: details)'];
  const admissionNeeds = ['self.publicationStillCurrent(publicationToken)',
    'self.appleCWMetaRefreshRequest?.generation == refreshGenerationAtSchedule',
    'self.refindGeneration == refindGenerationAtSchedule',
    'let statusGeneration = self.beginStreamAddonStatusAdmission()',
    'self.acceptStreamAddonStatus(streamAddonStatus, originalGeneration: statusGeneration)'];
  const typedMarker = 'if Self.metaDetailsNeedsRepublish(current: self.metaDetails, next: details) {';
  const workerAccepts = source => workerNeeds.every(text => source.includes(text))
    && source.split('self.stateData("meta_details")').length === 2;
  const admissionAccepts = source => admissionNeeds.every(text => source.includes(text))
    && admissionNeeds.slice(0, 3).every(text => source.indexOf(text) < source.indexOf(admissionNeeds[3]))
    && source.indexOf(admissionNeeds[3]) < source.indexOf(typedMarker)
    && source.indexOf(typedMarker) < source.indexOf(admissionNeeds[4]);
  if (!workerAccepts(worker) || !admissionAccepts(admission)) throw new Error('Same-buffer/original status admission contract failed');
  for (const text of workerNeeds) {
    if (workerAccepts(worker.replace(text, 'REMOVED_CONTRACT'))) throw new Error('Worker contract removal accepted');
  }
  for (const text of admissionNeeds) {
    if (admissionAccepts(admission.replace(text, 'REMOVED_CONTRACT'))) throw new Error('Admission contract removal accepted');
  }
  const signalIndex = acceptance.indexOf('streamAddonStatusSignal = UUID()');
  const postIndex = acceptance.indexOf('guard streamAddonStatusAdmissionGeneration == originalGeneration else { return }');
  const commitIndex = acceptance.indexOf('acceptedStreamAddonStatus = projection');
  if (!getter.includes('projection.selected == details.selected') || getter.includes('stateData(')
      || getter.includes('streamsEpoch') || getter.includes('addonStatesCache')
      || projection.includes('stateData(') || projection.includes('streamsEpoch')
      || !observer.includes('if metaDetails == nil {')
      || !observer.includes('streamAddonStatusAdmissionGeneration = UUID()')
      || !observer.includes('acceptedStreamAddonStatus = nil')
      || core.includes('@Published private var acceptedStreamAddonStatus')
      || !acceptance.includes('guard streamAddonStatusAdmissionGeneration == originalGeneration,')
      || acceptance.includes('beginStreamAddonStatusAdmission(')
      || !(signalIndex >= 0 && signalIndex < postIndex && postIndex < commitIndex)) {
    throw new Error('Real Published signal/original fence/plain commit/getter/clear source contract failed');
  }
  fs.writeFileSync(`${out}/error-sidecar-source-contract.txt`, 'Same-buffer/original status admission source contract PASS; eight worker/admission removals rejected; real Combine properties retained; missing-post-fence RAM counterexamples required at runtime; not native executor or full actor proof\n');
} else {
  fs.writeFileSync(`${out}/error-sidecar-source-contract.txt`, 'Historical source predates accepted status projection; no new sidecar/reentry result claimed\n');
}
}
// Models and tests compile directly from input snapshots; no source declaration,
// date formatter, protocol annotation or test assertion is edited during prepare.
NODE
shasum -a 256 "$publication_test_dir/Collaborators.swift" \
  "$publication_test_dir/ProductionResourceValues.swift" "$publication_test_dir/ProductionPublication.swift" \
      "$publication_test_dir/guarded-mode.txt" "$publication_test_dir/guarded-extraction.json" \
  > "$publication_test_dir/generated-before.sha256"
git -C "$PWD" rev-parse HEAD > "$publication_test_dir/source-head.txt"
if ((publication_prepare_only)); then
  publication_phase=prepared
  printf 'Prepared exact frozen source; no compiler or executable run\n'
  exit 0
fi
publication_phase=extractor-tests
publication_node=$(node -p 'process.execPath')
nice -n 15 node "$publication_supervisor" run 15 "$publication_test_dir/extractor-tests-process.json" -- \
  "$publication_node" --test "$publication_test_dir/inputs/test/addon-guarded-presentation-inputs.test.cjs" \
  > "$publication_test_dir/extractor-tests.log" 2>&1
nice -n 15 node "$publication_supervisor" check "$publication_test_dir/extractor-tests-process.json" 0 normal-exit
publication_guarded_flags=()
if [[ "$(<"$publication_test_dir/guarded-mode.txt")" == 1 ]]; then
  publication_guarded_flags=(-D VORTX_GUARDED_METADATA_PRESENTATION)
fi
publication_phase=compile
mkdir "$publication_test_dir/module-cache"
set +e
nice -n 15 node "$publication_supervisor" run 60 "$publication_test_dir/compile-process.json" -- \
  /usr/bin/xcrun swiftc -parse-as-library -warnings-as-errors -whole-module-optimization \
  -swift-version "$publication_swift_version" -strict-concurrency=complete -j 1 -num-threads 1 \
  -module-cache-path "$publication_test_dir/module-cache" \
  -D VORTX_NATIVE_DATA_ENGINE "${publication_guarded_flags[@]}" \
  "$publication_test_dir/Collaborators.swift" \
  "$publication_test_dir/inputs/app/SourcesShared/CoreModels.swift" \
  "$publication_test_dir/ProductionPublication.swift" \
  "$publication_test_dir/ProductionResourceValues.swift" \
  "$publication_test_dir/inputs/app/SourcesShared/VortxResourceProjection.swift" \
  "$publication_test_dir/inputs/app/SourcesShared/DetailMetaRecoveryPolicy.swift" \
  "$publication_test_dir/inputs/app/SourcesShared/CatalogRowResolution.swift" \
  "$publication_test_dir/inputs/app/SourcesShared/SubtitleReleaseFingerprint.swift" \
  "$publication_test_dir/inputs/app/SourcesShared/UsenetStreamValidation.swift" \
  "$publication_test_dir/inputs/app/SourcesShared/DiagnosticPlaybackIntegrityPolicy.swift" \
  "$publication_test_dir/inputs/app/SourcesShared/ProfileAddonPreferences.swift" \
  "$publication_test_dir/inputs/app/Tests/AddonStreamPublicationTests.swift" \
  -o "$publication_test_dir/addon-stream-publication" > "$publication_test_dir/compiler.log" 2>&1
publication_compile_status=$?
set -e
if [[ "$publication_compile_status" != 0 ]]; then cat "$publication_test_dir/compiler.log"; exit "$publication_compile_status"; fi
nice -n 15 node "$publication_supervisor" check "$publication_test_dir/compile-process.json" 0 normal-exit
publication_phase=runtime
set +e
nice -n 15 node "$publication_supervisor" run 30 "$publication_test_dir/runtime-process.json" -- \
  /usr/bin/env "VORTX_ADDON_PUBLICATION_BENCHMARK=$publication_benchmark" \
  "$publication_test_dir/addon-stream-publication" > "$publication_test_dir/test.log" 2>&1
publication_runtime_status=$?
set -e
cat "$publication_test_dir/test.log"
if [[ "$publication_runtime_status" != 0 ]]; then exit "$publication_runtime_status"; fi
nice -n 15 node "$publication_supervisor" check "$publication_test_dir/runtime-process.json" 0 normal-exit
publication_phase=complete
exit "$publication_runtime_status"
