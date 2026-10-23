#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/native-watched-swift-inputs.sh
mkdir -p app/build
discover_dir=$(mktemp -d "$PWD/app/build/native-discover-recovery.XXXXXX")
discover_ref=${VORTX_DISCOVER_FACADE_REF:-working-tree}
node - "$discover_dir" "$discover_ref" <<'NODE'
const fs = require('node:fs'), crypto = require('node:crypto'), cp = require('node:child_process');
const [out, ref] = process.argv.slice(2);
const read = path => fs.readFileSync(path, 'utf8');
function declaration(source, marker) {
  const begin = source.indexOf(marker);
  if (begin < 0) throw new Error(`Missing source declaration: ${marker}`);
  const end = source.indexOf('\n}', begin);
  if (end < 0) throw new Error(`Missing declaration end: ${marker}`);
  return source.slice(begin, end + 2);
}
const models = read('app/SourcesShared/CoreModels.swift');
const fixtures = read('app/Tests/VortxNativeSessionTests.swift');
const template = read('app/Tests/NativeDiscoverRecoveryTests.swift');
const selected = ['struct CoreDiscover:', 'struct CoreDiscoverSelectable:', 'struct CoreSelectablePage:',
  'struct CoreSelectableType:', 'struct CoreSelectableCatalog:', 'struct CoreSelectableExtra:', 'struct CoreSelectableExtraOption:',
  'struct CoreCatalogPage:', 'struct CoreResourceRequest:', 'struct CoreResourcePath:', 'enum CoreLoadable<',
  'struct CoreRequest:', 'struct CoreRequestPath:'].map(marker => declaration(models, marker)).join('\n');
fs.writeFileSync(`${out}/Combined.swift`, template
  .replace('// SESSION_FIXTURES', ['private final class SessionABI:', 'private final class SessionStore:'].map(marker => declaration(fixtures, marker)).join('\n'))
  .replace('// DISCOVER_MODELS', selected));
fs.writeFileSync(`${out}/UserProfile.swift`, read('app/SourcesShared/Profiles.swift').split('/// The profile roster and the active selection.')[0]);
fs.writeFileSync(`${out}/Discovery.swift`, 'import Foundation\n' + declaration(read('app/SourcesShared/ProfileDiscoveryPreferences.swift'), 'struct ProfileDiscoveryPreferences:'));
fs.writeFileSync(`${out}/VortxNativeCoreFacade.swift`, ref === 'working-tree' ? read('app/SourcesShared/VortxNativeCoreFacade.swift')
  : cp.execFileSync('git', ['show', `${ref}:app/SourcesShared/VortxNativeCoreFacade.swift`], {encoding: 'utf8', maxBuffer: 8 * 1024 * 1024}));
const tv = read('app/SourcesTV/DiscoverView.swift');
for (const marker of ['if discover.hasFailedPage, !discover.isLoadingPage', 'if let request = discover.retryRequest { core.selectDiscover(request) }',
  'if discover.isLoadingPage', 'else if !discover.hasFailedPage', 'Text("Retry")', 'No catalogs are available.', 'No results in this catalog.']) {
  if (!tv.includes(marker)) throw new Error(`Missing TV failure/empty/retry consumer: ${marker}`);
}
const hashes = {};
for (const path of ['app/SourcesShared/CoreModels.swift', 'app/SourcesTV/DiscoverView.swift', 'app/Tests/VortxNativeSessionTests.swift', 'app/Tests/NativeDiscoverRecoveryTests.swift']) {
  hashes[path] = crypto.createHash('sha256').update(read(path)).digest('hex');
}
fs.writeFileSync(`${out}/extraction-receipt.json`, JSON.stringify({ facadeRef: ref,
  sourceHead: cp.execFileSync('git', ['rev-parse', 'HEAD'], {encoding: 'utf8'}).trim(),
  note: 'Actual production facade/session/resource sources plus unchanged CoreDiscover declarations. Test ABI, in-memory checkpoint store and controlled provider only; no SDK, network, device or customer account.', hashes }, null, 2) + '\n');
NODE
discover_inputs=(
  app/SourcesShared/VortxNativeRuntime.swift app/SourcesShared/VortxResourceBridge.swift
  app/SourcesShared/VortxResourceProjection.swift app/SourcesShared/VortxNativeBootstrapArchive.swift
  app/SourcesShared/VortxNativeHostPreferences.swift "${native_watched_swift_inputs[@]}"
  app/SourcesShared/VortxNativeSession.swift "$discover_dir/VortxNativeCoreFacade.swift" app/SourcesShared/VortxNativePreviouslyWatched.swift app/SourcesShared/VortxProfileOverlayWitness.swift
  "$discover_dir/UserProfile.swift" "$discover_dir/Discovery.swift" app/SourcesShared/ProfileAddonPreferences.swift
  app/SourcesShared/VortxNativeProviderCredentials.swift app/SourcesShared/VortxNativeProfileEditHost.swift "$discover_dir/Combined.swift"
)
for discover_source in "${discover_inputs[@]}"; do
  [[ "$discover_source" != *.swift ]] || shasum -a 256 "$discover_source" >> "$discover_dir/source-hashes.sha256"
done
if [[ ${1:-} == --prepare-only ]]; then
  printf 'Prepared native Discover fixture: %s\n' "$discover_dir"
  exit 0
fi
xcrun swiftc -j 2 -parse-as-library -strict-concurrency=complete -warnings-as-errors \
  "${discover_inputs[@]}" -o "$discover_dir/discover-recovery" > "$discover_dir/compiler.log" 2>&1
set +e
"$discover_dir/discover-recovery" 2>&1 | tee "$discover_dir/runtime.log"
discover_status=${PIPESTATUS[0]}
set -e
shasum -a 256 "$discover_dir/discover-recovery" "$discover_dir/compiler.log" "$discover_dir/runtime.log" \
  "$discover_dir/extraction-receipt.json" > "$discover_dir/result-hashes.sha256"
printf 'Native Discover regression status %s; retained %s\n' "$discover_status" "$discover_dir"
exit "$discover_status"
