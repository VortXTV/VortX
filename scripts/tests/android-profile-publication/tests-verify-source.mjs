import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { method } from './kotlin-source-boundary.mjs';
const packet=dirname(fileURLToPath(import.meta.url));
const repo=process.argv[2] ?? fileURLToPath(new URL('../../../',import.meta.url));
const source=join(repo,'android/app/src/main/kotlin/com/vortx/android');
const read=path=>readFileSync(join(source,path),'utf8');
const fixture=path=>readFileSync(join(packet,path),'utf8');
const hash=text=>createHash('sha256').update(text).digest('hex');
const manifest=JSON.parse(fixture('tests-source-manifest.json'));
const lexicalMarker='    fun lexical(';
const lexicalBoundary=[
  '    fun lexical(value: String = "{") = outer {',
  '        val ordinary = "{ ignored }"',
  '        val raw = """ { raw } """',
  "        val character = '}'",
  '        val template = "${nested("}")}"',
  '        // } ignored',
  '        /* { nested /* } */ } */',
  '        inner { true }',
  '    }',
].join('\n')+'\n';
assert.equal(method(lexicalBoundary+'    fun following() { false }\n',lexicalMarker),lexicalBoundary);
assert.throws(()=>method(lexicalBoundary+lexicalBoundary,lexicalMarker),/Missing\/ambiguous/);
assert.throws(()=>method('    fun broken() { /* never closed', '    fun broken('),/Unterminated/);
const access=read('engine/NativeProfileAccess.kt'), store=read('profile/ProfileStore.kt');
const session=read('engine/VortxNativeSession.kt'), coordinator=read('engine/NativeAccountCoordinator.kt');
const accessExtract=fixture('tests-extracted/NativeProfileAccess.kt');
const storeExtract=fixture('tests-extracted/ProfileStoreBoundary.kt');
const bootstrapExtract=fixture('tests-extracted/ProfileBootstrapBoundary.kt');
const policyEnum='internal enum class PlaylistScopeTransition { PROJECTION_REFRESH, AUTHORITY_BOUNDARY }';
assert(store.includes(policyEnum) && bootstrapExtract.includes(policyEnum),'Playlist scope reason must be the actual typed declaration');
const scopeEvidence=store.slice(store.indexOf('internal data class PlaylistScopeEvidence('),store.indexOf('\n\ninternal fun playlistScopeTransition('));
const fixtureScopeEvidence=bootstrapExtract.slice(bootstrapExtract.indexOf('internal data class PlaylistScopeEvidence('),bootstrapExtract.indexOf('\n\ninternal fun playlistScopeTransition('));
const scopeClassifier=method(store,'internal fun playlistScopeTransition(');
assert.equal(fixtureScopeEvidence,scopeEvidence);
assert.equal(method(bootstrapExtract,'internal fun playlistScopeTransition('),scopeClassifier);
assert.match(scopeClassifier,/selectedID\.isNullOrBlank\(\)[\s\S]*nativeAccountID\.isNullOrBlank\(\)[\s\S]*nativeAccountGeneration != null[\s\S]*before == after/,
  'Soft preservation requires a positive, identical admitted Native Account id+generation and full scalar evidence');
const sessionExtract=fixture('tests-session-fixture.kt');
const constructor=access.slice(access.indexOf('internal class NativeProfileAccess('),access.indexOf(') : NativeProfileGateway {')+') : NativeProfileGateway {'.length)+'\n';
const readMethod='    override fun read(): NativeProfileGateway.Projection = projection(session().read())\n';
assert(access.includes(readMethod) && accessExtract.includes(constructor) && accessExtract.includes(readMethod));
const snippets={constructor,read:readMethod};
for(const [name,marker] of [['withProjection','    override fun <T> withProjection('],['currentProjection','    override fun <T> withCurrentProjection('],['prepareProjection','    override fun prepareProjection(']]) {
  snippets[name]=method(access,marker); assert.equal(method(accessExtract,marker),snippets[name]);
}
assert(!snippets.withProjection.includes('override fun <T> withCurrentProjection('), 'An expression body must not swallow the following method');
snippets.storeBoundary=method(store,'    private fun applyNativeProjection(');
assert.equal(method(storeExtract,'    private fun applyNativeProjection('),snippets.storeBoundary);
for(const [name,marker] of [['owned','    @Synchronized fun <T> owned('],['currentRead','    @Synchronized internal fun <T> withCurrentRead(']]) {
  snippets[name]=method(session,marker);assert.equal(method(sessionExtract,marker),snippets[name]);
}
for(const [name,path] of [['gateway','NativeProfileGateway.kt'],['cwGate','ContinueWatchingOwnerGate.kt']]) {
  snippets[name]=read('profile/'+path);assert.equal(fixture('tests-extracted/'+path),snippets[name]);
}
for(const [name,text] of Object.entries(snippets)) assert.equal(hash(text),manifest.hashes[name],`${name}: reviewed hash changed`);
for(const marker of ['    internal suspend fun attachNativeGateway(','    internal suspend fun refreshNativeProjectionInBackground(','    private fun prepareNativeProjection(','    private fun applyPreparedNativeProjection(','    internal fun clearNativeProjection(']) assert.equal(method(bootstrapExtract,marker),method(store,marker));
const fields=store.slice(store.indexOf('    private var nativeProjectionRequest ='),store.indexOf('    /** Bootstrap remains suspended'));
assert(bootstrapExtract.includes(fields),'Bootstrap fields/basis/receipt types must match actual source');
const capture=method(coordinator,'    internal fun captureProfilePresentation(');
assert.equal(method(fixture('tests-extracted/ProfilePresentationBoundary.kt'),'    internal fun captureProfilePresentation('),capture);
const discovery=read('profile/ProfileDiscoveryPreferences.kt');
const policy=discovery.slice(discovery.indexOf('data class ProfileDiscoveryPreferences('),discovery.indexOf('/** Bridges a profile'));
assert.equal(fixture('tests-extracted/ContinueWatchingMigration.kt'),'package com.vortx.android.profile\n'+policy.trimEnd()+'\n');
console.log('PASS exact_actual_bootstrap_access_metadata_admission_checkpoint_and_synchronous_publication_sources');

// Existing command/PIN/edit boundary remains live and independent of metadata-only publication.
assert.match(snippets.storeBoundary,/ContinueWatchingOwnerGate\.serialized[\s\S]*withProjection\(value\)/);
assert.match(snippets.currentProjection,/runtime\.withCurrentRead[\s\S]*check\(admit\(runtime\)/);
assert.match(snippets.withProjection,/check\(current == expected\)/);
const add=method(store,'    fun add(profile: UserProfile)');
function nativeAdd(text) {
  assert.match(text,/fun add\(profile: UserProfile\) = ContinueWatchingOwnerGate\.serialized \{/,'Native add must hold CW gate');
  assert.match(text,/applyNativeProjection\(checkNotNull\(nativeGateway\)\.save\(profile, adding = true\)\)/);
}
nativeAdd(add);assert.throws(()=>nativeAdd(add.replace('= ContinueWatchingOwnerGate.serialized {','{')),/Native add must hold CW gate/);
const pending=method(store,'    private fun capturePendingNativeContinueWatchingDiscovery(');
assert.match(pending,/val current = gateway\.read\(\)[\s\S]*gateway\.withProjection\(current\)/);
assert.match(pending,/readbackIsCurrent = \{ saved -> nativeGateway\?\.read\(\) == saved \}/);
assert.match(access,/Open this profile through its PIN gate before editing/);
assert.match(access,/Profile editor source changed/);

// Final Main effects have no Session/provider/secure access, including switch-hook callers.
const playlistEvidence=method(store,'    private fun playlistScopeEvidence(');
assert.equal(method(bootstrapExtract,'    private fun playlistScopeEvidence('),playlistEvidence);
const adoptRoster=method(store,'    fun adoptRemoteRoster(');
assert.match(adoptRoster,/ContinueWatchingOwnerGate\.transition\(::captureActiveProfileBinding\) \{[\s\S]*val beforeBinding = captureActiveProfileBinding\(profiles, activeID\)[\s\S]*val beforeAccount = acknowledgedNativeAccount[\s\S]*val beforeTraktEpoch = acknowledgedNativeTraktEpoch[\s\S]*profiles = remote[\s\S]*afterRosterFold\(beforeBinding, beforeAccount, beforeTraktEpoch\)/,
  'Roster transition evidence must be captured inside the same owner gate and before assignment');
const synchronousProjection=method(store,'    private fun applyNativeProjectionLocked(');
assert.match(synchronousProjection,/val beforeBinding = captureActiveProfileBinding\(profiles, activeID\)/);
assert.match(synchronousProjection,/val beforeAccount = acknowledgedNativeAccount/);
assert.match(synchronousProjection,/val beforeTraktEpoch = acknowledgedNativeTraktEpoch/);
assert.match(synchronousProjection,/playlistScopeTransition\([\s\S]*providerGuard\?\.owner, traktEpoch/);
assert.match(synchronousProjection,/if \(transition == PlaylistScopeTransition\.AUTHORITY_BOUNDARY\) notifyPlaylistScopeListeners\(transition\)/);
assert.match(synchronousProjection,/activateProfileState\(it, resetUnset = true, playlistTransition = transition\)/);
const apply=method(store,'    private fun applyPreparedNativeProjection(');
assert.doesNotMatch(apply,/\.read\(|NativeProviderAccess\.(?:capture|current|guarded)|currentSessionEpoch|\.save\(/);
assert.match(apply,/withoutNativePreferenceCapture/);
assert.match(apply,/PlaylistScopeTransition\.AUTHORITY_BOUNDARY/);
assert.match(apply,/notifyPlaylistScopeListeners\(transition\)/);
const attach=method(store,'    internal suspend fun attachNativeGateway(');
assert.match(attach,/withContext\(Dispatchers\.IO\)[\s\S]*gateway\.prepareProjection/);
assert.match(attach,/prepared\.publishIfCurrent/);
assert.match(attach,/NativeProviderAccess\.revision\.value == currentEffects\.providerRevision/);
assert.match(attach,/if \(prepared\.requiresRecovery\)[\s\S]*continueWatchingMigration\.restore[\s\S]*check\(!recoveryRequired\)/);
assert.match(attach,/check\(\+\+attempt < 4\)[\s\S]*delay\(50L \* attempt\)/);
const prepare=method(store,'    private fun prepareNativeProjection(');
assert.match(prepare,/NativeProviderAccess\.capture/);assert.match(prepare,/TraktAuth\.currentSessionEpoch/);
assert.match(prepare,/Native provider authority is unavailable/);
assert.match(prepare,/previousAcknowledgement\?\.takeIf/);
const publicationTail=capture.slice(capture.indexOf('PreparedProjection('));
assert.doesNotMatch(publicationTail,/session\.(?:read|owned|withCurrentRead)|captureProfilePresentationAdmission\(/);
assert.match(publicationTail,/mounted\.get\(\) === current && changes\.value == epoch && session\.updates\.value == version/);
const forYou=read('foryou/ForYouStore.kt');
const forYouExtract=fixture('tests-extracted/ForYouReloadBoundary.kt');
const forYouBody=forYou.slice(forYou.indexOf('class ForYouStore internal constructor('),forYou.indexOf('    companion object {\n        internal const val LOCAL_KEY'));
assert(forYouExtract.includes(forYouBody),'Entire actual ForYou Store through native/local writes must match');
assert(forYouExtract.includes(forYou.slice(forYou.indexOf('interface ForYouNativeGateway {'),forYou.indexOf('/**\n * The active profile'))),'Actual ForYou Snapshot and State must match');
assert.match(forYou,/registerProfileSwitch \{ reload\(invalidate = true\) \}/);
assert.match(forYou,/private suspend fun reload\([\s\S]*withContext\(ioDispatcher\)[\s\S]*reloadMutex\.withLock[\s\S]*currentCoroutineContext\(\)\.ensureActive\(\)/);
assert.match(forYou,/generation == reloadGeneration && gateway === native/);
assert.match(forYou,/captured\?\.publishIfCurrent\(publication\)/);
const watchlist=read('library/WatchlistStore.kt');
assert.match(method(watchlist,'    private fun scheduleReload('),/scope\.launch\(ioDispatcher\) \{ reloadAttempt\(attempt\) \}/);
const app=read('VortXApplication.kt');
assert.match(app,/addPlaylistScopeTransitionListener \{ transition ->[\s\S]*PROJECTION_REFRESH -> savedPlaylistStore\.nativeProjectionWillChange\(\)[\s\S]*AUTHORITY_BOUNDARY -> savedPlaylistStore\.invalidateAuthority\(\)/,
  'App must route the typed reason to the matching local-only Store cut');
const phoneShell=read('ui/VortXApp.kt'), tvShell=read('ui/tv/TvApp.kt');
for(const [name,shell,owner] of [['phone',phoneShell,'queueOwner == playlistOwner'],['tv',tvShell,'playlistOwner == currentQueueOwner']]) {
  const start=shell.indexOf('if (playlistOwner != null && playlistStore != null && '+owner+')');
  const stop=shell.indexOf('if (playable != null) {',start);
  const overlay=shell.slice(start,stop);
  assert(start >= 0 && stop > start, `${name} saved playlist overlay branch missing`);
  assert.match(overlay,/androidx\.compose\.ui\.window\.Dialog/);
  assert.doesNotMatch(overlay,/return@VortXTheme/,'Opening the playlist overlay must keep PlayerScreen composed');
}
assert.match(app,/candidate -> ProfileStore\.sharedOrNull\(\)\?\.attachNativeGateway\(nativeProfiles, candidate\)/);
assert.doesNotMatch(app,/nativeAccounts\.session\(\)\.also \{ it\.read\(\) \}/);
const readOnly=app.slice(app.indexOf('captureProfilePresentationAdmission ='),app.indexOf('internal fun nativeStreamingAccounts'));
assert.match(readOnly,/manager\.sessionOwnerSnapshot\(\) != captured/);
const metadataGate=readOnly.slice(readOnly.indexOf('val gate:'));
assert.doesNotMatch(metadataGate,/sessionOwnerSnapshot\(/);
assert.match(metadataGate,/manager\.sessionUiState\.value is VortXSyncManager\.SessionUiState\.SignedIn/);
// Generic mutation callback still performs its original persisted-identity revalidation.
assert.match(app,/syncManager === manager && manager\.sessionOwnerSnapshot\(\) == captured && action\(\)/);
assert.match(read('sync/VortXSyncManager.kt'),/profileStore\.refreshNativeProjectionInBackground\(forceSettings = true\)/);
assert.match(read('sync/VortXSyncManager.kt'),/val isSignedIn: Boolean get\(\) = session != null/);
console.log('PASS metadata_only_main_effects_preserve_live_commands_and_background_dependent_capture_contracts');
console.log('INFO source and scheduling collaborators only; no full Android/JNI/device crash proof');

// The full write path above is actual source; the separate adapter fixture below is actual source too.
assert.doesNotMatch(forYou, /suspend fun (?:save|delete)\(/, 'Unbound delayed Store write API must not return');
assert.match(forYou, /fun prepare\(edit: ForYouEditSession/);
assert.match(forYou, /origin\.epoch == authorityEpoch\.get\(\) && intent\.edit\.isActive\(\)/);
assert.match(forYou, /native\.write\(checkNotNull\(origin\.owner\)/);
assert.match(forYou, /localMutex\.withLock[\s\S]*origin\.localAuthority[\s\S]*intent\.observed\.matches/);
assert.match(forYou, /if \(current\(\)\) reload\(\)/);
assert.doesNotMatch(method(forYou,'    suspend fun execute('), /signedIn\(\)|activeProfileId\(\)|gateway\?\.write/);
console.log('PASS actual_store_original_write_intent_and_one_field_local_merge_sources');
