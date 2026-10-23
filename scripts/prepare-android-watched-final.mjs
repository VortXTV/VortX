// Current-source standalone watched gate; integrates only through the reviewed test-only patch.
// This is not a checkout, candidate applier, dependency installer, or app builder.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';

const workspace = '/Users/daksh/VortXTV';
const [app, output, mode = 'positive'] = process.argv.slice(2);
const outputRoot = `${workspace}/_build/repair-20261018-android-watched-final-tests`;
const realApp = fs.realpathSync(app);
if (app !== realApp || !(app === `${workspace}/VortX` || app.startsWith(`${workspace}/.worktrees/VortX/`)) ||
    path.dirname(output ?? '') !== outputRoot || fs.realpathSync(outputRoot) !== outputRoot ||
    !['positive', 'negative-scope'].includes(mode)) throw Error('Unexpected workspace repository/output/mode');
const main = `${app}/android/app/src/main/kotlin/com/vortx/android`;
const tests = `${app}/android/app/src/test/kotlin/com/vortx/android`;
const generated = `${output}/source`;
fs.mkdirSync(generated, {recursive: true});
fs.mkdirSync(`${output}/logs`, {recursive: true});
const sha = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const inputs = new Map();
function read(file, coverage) {
  const bytes = fs.readFileSync(file);
  const prior = inputs.get(file);
  inputs.set(file, {path: file, sha256: sha(bytes), coverage: prior?.coverage ?? coverage});
  return bytes.toString('utf8');
}
function once(source, marker) {
  const first = source.indexOf(marker);
  if (first < 0 || source.indexOf(marker, first + marker.length) >= 0) throw Error(`Nonunique extraction anchor: ${marker}`);
  return first;
}
function between(source, start, end) {
  const from = once(source, start), to = once(source, end);
  if (to <= from) throw Error(`Reversed extraction anchors: ${start}`);
  return source.slice(from, to);
}
const sources = [];
function write(name, text) {
  const target = `${generated}/${name}`;
  fs.writeFileSync(target, text);
  sources.push(target);
  return {path: target, sha256: sha(Buffer.from(text))};
}
const derived = [];
read(`${app}/android/gradle/libs.versions.toml`, 'app target dependency pins; provenance only, no Gradle execution');
read(`${app}/scripts/test-android-watched-final.sh`, 'serial runner provenance');
function copy(relative, name = path.basename(relative)) {
  derived.push(write(name, read(`${main}/${relative}`, 'complete production compilation')));
}

const l1 = ['LegacyWatchedBitfieldMigrationEvidence.kt', 'NativeWatchedMigrationProducer.kt',
  'NativeWatchedMigrationStorage.kt', 'NativeMigrationPreflight.kt', 'NativeHostDocument.kt',
  'NativeAccountCoordinator.kt', 'NativeStreamingAccountLink.kt'];
for (const unit of l1) read(`${main}/engine/${unit}`, l1.indexOf(unit) < 5 ?
  'complete L1 production compilation' : 'hash only; orchestration compile/runtime HOLD');
for (const unit of l1.slice(0, 5)) copy(`engine/${unit}`);
for (const relative of ['engine/LegacyWatchedBitfieldDecoder.kt', 'engine/NativeProfileOverlayWitness.kt',
  'engine/AddonManifestFetcher.kt', 'engine/NativeHostPreferences.kt', 'engine/NativeWebsiteProfileEdits.kt',
  'engine/NativeWebsiteAddonEdits.kt', 'engine/NativeAccountBinding.kt', 'library/NativeWatchlistCodec.kt',
  'backup/BinaryPlist.kt', 'backup/SettingsBackup.kt', 'profile/UserProfile.kt', 'foryou/ForYouModel.kt']) copy(relative);

const session = read(`${main}/engine/VortxNativeSession.kt`, 'exact complete account scope/interface/encrypted store extraction; full session excluded');
let scope = between(session, 'internal data class VortxAccountScope(', '\ninternal interface VortxCheckpointStore');
const fence = 'NativeWatchedMigrationStorage.read(state.getJSONObject("hostDocument")).requireScope(this)';
if (scope.split(fence).length !== 2) throw Error('Mandatory production checkpoint watched-scope fence absent or duplicated; integrate L1 + engine-owned fence first');
if (mode === 'negative-scope') scope = scope.replace(fence, '// Intentional fixture-only negative control: watched-scope admission omitted.');
const store = between(session, 'internal interface VortxCheckpointStore', '/** Android Keystore holds a non-exportable');
const engineImports = ['java.io.File', 'java.io.FileOutputStream', 'java.nio.ByteBuffer', 'java.nio.channels.FileChannel',
  'java.nio.charset.CodingErrorAction', 'java.nio.file.Files', 'java.nio.file.StandardCopyOption', 'java.nio.file.StandardOpenOption',
  'java.security.MessageDigest', 'javax.crypto.Cipher', 'javax.crypto.SecretKey', 'javax.crypto.spec.GCMParameterSpec',
  'org.json.JSONObject', 'org.json.JSONArray'];
derived.push(write('ActualScopeAndEncryptedStore.kt', 'package com.vortx.android.engine\n' +
  engineImports.map(item => `import ${item}`).join('\n') + '\n' + scope + '\n' + store));

const own = read(`${main}/engine/NativeOwnAccountSources.kt`, 'exact complete pure validators/scanner/overlay/envelope methods extracted; authenticated producer excluded');
const uid = read(`${main}/engine/NativeOwnAccountCredentials.kt`, 'exact complete requireNativeStreamingUID extraction only; credentials/platform store excluded');
const uidMarker = 'internal fun requireNativeStreamingUID(uid: String)';
const pureOwn = [
  between(own, 'internal fun nativeOwnAccountOverlay(', '/** A cold peer may reuse only a baseline'),
  between(own, 'private fun decodeOwnEnvelope(', '/** Exact token-free source bytes'),
  between(own, 'internal fun validateNativeOwnAccountArchive(', '/** Hold every exact credential generation'),
  between(own, 'private fun ownObject(', 'private fun ownString('),
  own.slice(once(own, 'internal fun requireOwnAccountSourceCredentialFree(')),
  uid.slice(once(uid, uidMarker)),
];
derived.push(write('ActualOwnAccountPureValidators.kt', 'package com.vortx.android.engine\n' +
  ['org.json.JSONArray', 'org.json.JSONObject', 'java.nio.ByteBuffer', 'java.nio.charset.CodingErrorAction', 'java.util.Base64']
    .map(item => `import ${item}`).join('\n') + '\n' + pureOwn.join('\n')));

// Pure data declaration copied byte-for-byte. Android preference IO stays out of this JVM gate.
const discovery = read(`${main}/profile/ProfileDiscoveryPreferences.kt`, 'exact data declaration and activeProjectionKeys constants/initializer; Android preference IO excluded');
derived.push(write('ActualDiscoveryModel.kt', 'package com.vortx.android.profile\n' +
  between(discovery, 'data class ProfileDiscoveryPreferences(', '/** Migration requires both exact acknowledged records')));
// SettingsBackup.isSyncable needs the exact active-profile key exclusion set. Copy the real
// declaration and its complete constant dependencies, never an empty/permissive substitute.
const projectionImports = ['com.vortx.android.data.CatalogPreferencesStore',
  'com.vortx.android.home.COLLECTIONS_SELECTED_PROVIDERS_KEY',
  'com.vortx.android.home.COLLECTIONS_PROVIDER_ORDER_KEY',
  'com.vortx.android.home.DISCOVER_HIDDEN_CATEGORIES_KEY',
  'com.vortx.android.home.DISCOVER_REGION_PREFERENCE_KEY',
  'com.vortx.android.ui.prefs.TabBarPrefs'];
const projection = between(discovery, 'internal object ProfileDiscoveryPreferencesStore {',
  '    fun capture(prefs: SharedPreferences)');
derived.push(write('ActualActiveProjectionKeys.kt', 'package com.vortx.android.profile\n' +
  projectionImports.map(item => `import ${item}`).join('\n') + '\n' + projection + '\n}\n'));
function constant(source, name) {
  const declaration = new RegExp(`^\\s*(?:internal\\s+)?const\\s+val\\s+${name}\\s*=`);
  const lines = source.split('\n').filter(line => declaration.test(line));
  if (lines.length !== 1) throw Error(`Nonunique constant declaration: ${name}`);
  return lines[0];
}
const collectionKeys = read(`${main}/home/CollectionsHubModel.kt`, 'exact four projection-key constant declarations only; home model/runtime excluded');
const continueKeys = read(`${main}/home/ContinueWatchingSelection.kt`, 'exact two projection-key constant declarations only; selection runtime excluded');
derived.push(write('ActualHomeProjectionConstants.kt', 'package com.vortx.android.home\n' +
  ['COLLECTIONS_SELECTED_PROVIDERS_KEY', 'COLLECTIONS_PROVIDER_ORDER_KEY',
    'DISCOVER_HIDDEN_CATEGORIES_KEY', 'DISCOVER_REGION_PREFERENCE_KEY'].map(name => constant(collectionKeys, name)).join('\n') + '\n' +
  ['CONTINUE_WATCHING_SOURCE_KEY', 'CONTINUE_WATCHING_WINDOW_KEY'].map(name => constant(continueKeys, name)).join('\n') + '\n'));
const catalog = read(`${main}/data/CatalogPreferencesStore.kt`, 'exact FILTERS_KEY declaration only; constant-only class carrier, Android store excluded');
derived.push(write('ActualCatalogProjectionConstant.kt', 'package com.vortx.android.data\n' +
  'class CatalogPreferencesStore private constructor() {\n    companion object {\n' +
  constant(catalog, 'FILTERS_KEY') + '\n    }\n}\n'));
const tabs = read(`${main}/ui/prefs/TabBarPrefs.kt`, 'exact four tab-key declarations only; constant-only class carrier, Android preferences excluded');
derived.push(write('ActualTabProjectionConstants.kt', 'package com.vortx.android.ui.prefs\n' +
  'class TabBarPrefs private constructor() {\n    companion object {\n' +
  ['HIDE_DISCOVER_KEY', 'HIDE_LIVE_KEY', 'HIDE_LIBRARY_KEY', 'HIDE_SEARCH_KEY'].map(name => constant(tabs, name)).join('\n') +
  '\n    }\n}\n'));

// The actual constructor fields are sufficient for NativeWatchlistCodec. The toMetaItem UI projection
// is deliberately not compiled; no replacement validator or UI projection is supplied.
const watchlist = read(`${main}/library/WatchlistStore.kt`, 'exact WatchlistEntry constructor declaration only; store and toMetaItem UI projection excluded');
const entry = between(watchlist, 'internal data class WatchlistEntry(', '\ninternal object WatchlistCodec');
const entryBody = once(entry, ') {');
derived.push(write('ActualWatchlistEntryFields.kt', 'package com.vortx.android.library\n' + entry.slice(0, entryBody + 1) + '\n'));

// This unreachable capability seam is fail-closed, not a validator. Tests pass empty ownSources and
// exercise the actual pure own-archive validators above; this cannot mint authenticated source proof.
derived.push(write('ExcludedAuthenticatedSourceCapability.kt', `package com.vortx.android.engine
internal class NativeOwnAccountSource private constructor() {
    val accountID: String get() = excluded()
    val profileID: String get() = excluded()
    val verifiedUID: String get() = excluded()
    val credentialTransactionID: String? get() = excluded()
    val digest: String get() = excluded()
    fun archiveBase64(): String = excluded()
    fun <T> withActive(action: () -> T): T = excluded()
    private fun excluded(): Nothing = error("Authenticated source capability is excluded from this bounded JVM gate")
}
`));

for (const unit of ['LegacyWatchedBitfieldMigrationEvidenceTest.kt', 'LegacyWatchedBitfieldDecoderTest.kt']) {
  const file = `${tests}/engine/${unit}`;
  derived.push(write(unit, read(file, 'complete existing production JUnit source')));
}
// These committed fixtures preserve the expanded cold-restart cases. Current test hashes are
// recorded rather than pinned to recovery paths; no old candidate or recovery artifact is loaded.
for (const unit of ['RepairWatchedStorageTest.kt', 'RepairWatchedCheckpointTest.kt', 'RepairWatchedFinalScopeTest.kt']) {
  const file = `${tests}/engine/${unit}`;
  derived.push(write(unit, read(file, 'complete committed standalone regression fixture')));
}
const preparation = fs.readFileSync(import.meta.filename ?? new URL(import.meta.url));
const manifest = {mode, capturedAt: new Date().toISOString(), preparationSha256: sha(preparation),
  compiledL1: l1.slice(0, 5), hashOnlyOrchestrations: l1.slice(5),
  actualValidator: 'Complete production VortxAccountScope, not a synthetic NativeSnapshotValidator',
  negativeControl: mode === 'negative-scope' ? 'Only mandatory watched-scope fence omitted in generated fixture source' : null,
  inputs: [...inputs.values()], generated: derived,
  exclusions: ['Full NativeAccountCoordinator', 'Full NativeStreamingAccountLink', 'Full VortxNativeSession dispatcher/fallback/hydrate',
    'JNI/native engine', 'Android Keystore provider', 'Authenticated own-source capability',
    'Android preference stores: CatalogPreferencesStore/TabBarPrefs represented only by exact production constant declarations',
    'Android SDK/Compose/app/APK/package/device'],
};
fs.writeFileSync(`${output}/logs/source-manifest.json`, JSON.stringify(manifest, null, 2) + '\n');
fs.writeFileSync(`${output}/logs/source-manifest.txt`, [...inputs.values()].map(item => `${item.sha256}  ${item.path}  [${item.coverage}]`).join('\n') + '\n');
fs.writeFileSync(`${output}/sources.list`, sources.join('\n') + '\n');
console.log(`Prepared ${sources.length} Kotlin compilation inputs in ${output}; mode=${mode}. No compiler, test, or network operation was started by this preparation script.`);
