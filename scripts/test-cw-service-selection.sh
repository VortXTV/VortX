#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
cw_repo_root="$PWD"
mkdir -p app/build
cw_build_dir=$(mktemp -d app/build/cw-service-selection.XXXXXX)
cw_baseline_ref="${CW_SERVICE_BASELINE_REF:-0e196c586ebe95810476be8efde84fb0c061ca12}"
# Extract the ACTUAL parent selector and ACTUAL candidate activation/map bodies. The fixtures
# provide only inert dependencies; they do not reimplement the decisions being tested.
node --input-type=module - "$cw_repo_root" "$cw_baseline_ref" "$cw_build_dir" <<'NODE'
import {execFileSync} from 'node:child_process';
import {readFileSync, writeFileSync} from 'node:fs';
const [root, ref, dir] = process.argv.slice(2);
const read = path => readFileSync(`${root}/${path}`, 'utf8');
function block(source, marker) {
  const start = source.indexOf(marker);
  if (start < 0) throw new Error(`Missing actual source marker: ${marker}`);
  const brace = source.indexOf('{', start);
  let end = brace + 1, depth = 1;
  for (; depth && end < source.length; end++) {
    if (source[end] === '{') depth++;
    if (source[end] === '}') depth--;
  }
  if (depth) throw new Error(`Unterminated actual source marker: ${marker}`);
  return source.slice(start, end);
}
const baseline = execFileSync('git', ['-C', root, 'show', `${ref}:app/SourcesShared/HomeContinueWatchingSelection.swift`], {encoding:'utf8'});
writeFileSync(`${dir}/BaselineServiceSelection.swift`, baseline.replaceAll('HomeContinueWatchingSelection', 'BaselineServiceSelection'));
const shelf = read('app/SourcesTV/TopShelfSnapshotWriter.swift');
writeFileSync(`${dir}/FixtureTopShelfMapper.swift`, 'import Foundation\nenum FixtureTopShelfMapper {\n' +
  ['static func items(\n', 'private static func shelfProgress(', 'private static func shelfPoster('].map(marker => block(shelf, marker)).join('\n') + '\n}\n');
writeFileSync(`${dir}/FixtureContinueWatchingFocus.swift`, 'import Foundation\nenum FixtureContinueWatchingFocus {\n' +
  block(read('app/SourcesTV/HomeView.swift'), 'static func permitsHeroEnrichment(') + '\n}\n');
const profiles = read('app/SourcesShared/Profiles.swift');
const fixture = `import Foundation
${block(read('app/SourcesShared/ProfileSync.swift'), 'struct WatchEntry:')}
enum VortXSyncManager { static func suppressHousekeeping(_ work: () -> Void) { work() } }
final class SourcePreferences { static let shared = SourcePreferences(); func reload() {} }
final class SourcePinStore { static let shared = SourcePinStore(); func reload() {} }
@MainActor final class MigrationFixtureProfileStore {
    var profiles: [UserProfile]; var activeID: UUID?
    var watch: [String: WatchEntry] = [:]
    var active: UserProfile? { profiles.first { $0.id == activeID } }
    var nativeProfileError: String?
    private var nativeProjectionTarget: PlaybackMutationTarget?
    private var nativePublishedPlayback: UserProfile.PlaybackPrefs?
    private var nativePublishedDiscovery: ProfileDiscoveryPreferences?
    private let continueWatchingLegacyAccount = CredentialScopeRegistry.shared.capture()
    ${block(profiles, 'private struct ContinueWatchingMigrationWitness')}
    private var continueWatchingMigration: ContinueWatchingMigrationWitness?
    private var continueWatchingMigrationInFlight = false
    var failSave = false; var suspendSave = false; var saveCount = 0
    var saving: CheckedContinuation<Void, Never>?
    init(profiles: [UserProfile], activeID: UUID?) { self.profiles = profiles; self.activeID = activeID }
    func persist(touch: Bool = true) {}
    func applyTheme(_ profile: UserProfile) {}
    func applyPlayback(_ profile: UserProfile, resetUnset: Bool) {}
    func currentPlaybackPrefs() -> UserProfile.PlaybackPrefs { .init() }
    func currentDiscoveryPrefs() -> ProfileDiscoveryPreferences { ProfileDiscoveryPreferencesStore.capture() }
    func applyDiscovery(_ profile: UserProfile, resetUnset: Bool = false) { ProfileDiscoveryPreferencesStore.apply(profile.discovery, resetUnset: resetUnset) }
    func update(_ profile: UserProfile) { Task { _ = await saveNative(profile, creating: false) } }
    func saveNative(_ profile: UserProfile, creating: Bool, target: PlaybackMutationTarget? = nil) async -> Bool {
        saveCount += 1
        let captured = target ?? CoreBridge.shared.captureNativePlaybackTarget()
        if suspendSave { await withCheckedContinuation { saving = $0 } }
        guard !failSave, captured.stillOwnsCurrentContext(core: .shared), activeID == profile.id else { return false }
        let roster = profiles.map { $0.id == profile.id ? profile : $0 }
        applyNativeProfiles(roster, activeID: profile.id, projectionTarget: captured)
        return true
    }
    func drain() async { for _ in 0..<100 { await Task.yield() } }
    ${block(profiles, 'func applyNativeProfiles(')}
    ${block(profiles, 'private func migrateContinueWatchingIfQualified(')}
    ${block(profiles, 'func captureDiscovery(')}
    ${block(profiles, 'var cwItems:')}
}
`;
writeFileSync(`${dir}/MigrationFixtureProfileStore.swift`, fixture);
const service = read('app/SourcesShared/SIMKLService.swift');
writeFileSync(`${dir}/FixtureSIMKLHTTPClient.swift`, `import Foundation
actor InertSIMKLHTTPAuth {
    var sessionID: SIMKLSessionID? { SIMKLAuth.storedSessionID }
    func validToken(for session: SIMKLSessionID) throws -> String {
        guard SIMKLAuth.storedSessionID == session else { throw SIMKLError.sessionChanged }
        return "inert-token"
    }
}
actor FixtureSIMKLHTTPClient {
    let auth = InertSIMKLHTTPAuth()
    var requests: [URLRequest] = []
    var retireAfterTransport = false
    func setRetirement() { retireAfterTransport = true }
    func perform(_ request: URLRequest, maxResponseBytes: Int) async throws -> (Data, Int) {
        requests.append(request)
        if retireAfterTransport { SIMKLAuth.storedSessionID = SIMKLSessionID(rawValue: "inert-replacement") }
        return (Data("{}".utf8), 200)
    }
    func expectSuccess(_ status: Int) throws { if status != 200 { throw SIMKLError.fixture } }
    ${block(service, 'nonisolated func continueWatchingSessionIsCurrent(')}
    ${block(service, 'func continueWatchingRead(')}
    ${block(service, 'private func read(path:')}
}
`);
NODE
cw_inputs=(
    app/Tests/HomeContinueWatchingFixtureStubs.swift
    app/SourcesShared/PlaybackMutationOwnershipPolicy.swift
    app/SourcesShared/ExternalSyncSessionPolicy.swift
    app/SourcesShared/TraktScrobbleProgressPolicy.swift
    app/SourcesShared/TraktArtworkPolicy.swift
    app/SourcesShared/TraktContinueWatchingFold.swift
    app/SourcesShared/ContinueWatchingDedupe.swift
    app/SourcesShared/ContinueWatchingPreferences.swift
    app/SourcesShared/ProfileDiscoveryPreferences.swift
    app/SourcesShared/TraktPlaybackShadow.swift
    app/SourcesShared/SIMKLContinueWatching.swift
    app/SourcesShared/SIMKLContinueWatchingShadow.swift
    app/SourcesShared/HomeContinueWatchingSelection.swift
    "$cw_build_dir/FixtureTopShelfMapper.swift"
    "$cw_build_dir/FixtureContinueWatchingFocus.swift"
    "$cw_build_dir/MigrationFixtureProfileStore.swift"
    "$cw_build_dir/FixtureSIMKLHTTPClient.swift"
    app/Tests/ContinueWatchingServiceTests.swift
)
swiftc -parse-as-library -D VORTX_NATIVE_DATA_ENGINE -D CW_SERVICE_FIXTURE -D CW_SERVICE_BASELINE "${cw_inputs[@]}" "$cw_build_dir/BaselineServiceSelection.swift" -o "$cw_build_dir/baseline"
if "$cw_build_dir/baseline" > "$cw_build_dir/baseline.log" 2>&1; then
    printf '%s\n' 'FAIL: actual parent unexpectedly supports selected SIMKL'
    exit 1
fi
rg -F 'FAIL: actual parent selector supports selected SIMKL' "$cw_build_dir/baseline.log"
swiftc -parse-as-library -D VORTX_NATIVE_DATA_ENGINE -D CW_SERVICE_FIXTURE "${cw_inputs[@]}" -o "$cw_build_dir/services"
"$cw_build_dir/services" | tee "$cw_build_dir/services.log"
printf '%s\n' "Actual parent RED and candidate receipts: $cw_build_dir"
