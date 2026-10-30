import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { method } from '../android-profile-publication/kotlin-source-boundary.mjs';
const repo=process.argv[2];
const read=p=>readFileSync(join(repo,p),'utf8');
const prefix='android/app/src/main/kotlin/com/vortx/android/';
const fixture=read('scripts/tests/android-foryou-write-authority/tests-native-fixture.kt');
const coordinator=read(prefix+'engine/NativeAccountCoordinator.kt');
assert.equal(method(fixture,'    internal fun captureForYouMutationAdmission('),method(coordinator,'    internal fun captureForYouMutationAdmission('));
const adapter=read(prefix+'engine/NativeForYouAccess.kt');
const write=method(adapter,'    override suspend fun write(');
assert.doesNotMatch(write,/accounts\.(?:session|accountFor|withProfileMutation)\(/);
assert.match(write,/captured\.session\.owned\(captured\.native\)[\s\S]*captured\.admission\.admit[\s\S]*observed\.matches[\s\S]*session\.dispatch/);
assert.match(write,/beforeCommit = \{ operation\.ensureActive\(\); check\(isCurrent\(\)\)/);
assert.doesNotMatch(adapter,/dispatchBudgetedPlaylist|runtime\.isTyped/);
const store=read(prefix+'foryou/ForYouStore.kt');
const extracted=read('scripts/tests/android-profile-publication/tests-extracted/ForYouReloadBoundary.kt');
const actual=store.slice(store.indexOf('interface ForYouNativeGateway {'),store.indexOf('    companion object {\n        internal const val LOCAL_KEY'));
// The extraction omits only the class-level explanatory KDoc, with the full class/methods retained.
const api=store.slice(store.indexOf('interface ForYouNativeGateway {'),store.indexOf('/**\n * The active profile'));
assert(extracted.includes(api));
const body=store.slice(store.indexOf('class ForYouStore internal constructor('),store.indexOf('    companion object {\n        internal const val LOCAL_KEY'));
assert(extracted.includes(body));
for (const file of ['ui/foryou/ForYouPickers.kt','ui/foryou/ForYouHomeRows.kt','ui/screens/HomeScreen.kt','ui/tv/TvHomeScreen.kt','ui/screens/SmartCollectionsScreen.kt','ui/tv/TvSmartCollectionsScreen.kt']) {
  const text=read(prefix+file);
  assert.match(text,/opening|ForYouEditSession/);
  assert.doesNotMatch(text,/\.save\(|\.delete\(/);
}
const pickers=read(prefix+'ui/foryou/ForYouPickers.kt');
assert.match(pickers,/val intent = store\.prepare\(opening[\s\S]*scope\.launch[\s\S]*store\.execute\(intent\)/);
assert.match(pickers,/prepareDelete\(opening, existing\)/);
assert.match(pickers,/remember\(opening\)/);
assert.match(pickers,/opening\.finishIfActive\(onFinish\)/);
const session=read(prefix+'engine/VortxNativeSession.kt');
const dispatchStart=session.indexOf('    @Synchronized fun dispatch(');
assert(dispatchStart >= 0 && session.indexOf('    @Synchronized fun dispatch(',dispatchStart+1)<0);
const dispatchEnd=session.indexOf('\n\n    /**\n     * Dedicated playlist route.',dispatchStart);
assert(dispatchEnd>dispatchStart,'Complete dispatch declaration/delegation boundary missing');
const dispatchAbi=session.slice(dispatchStart,dispatchEnd)+'\n';
assert.equal(dispatchAbi,read('scripts/tests/android-foryou-write-authority/tests-dispatch-abi.txt'),
  'The complete original dispatch ABI, defaults and delegation must remain byte-identical');
assert.match(dispatchAbi,/beforeCommit: \(\) -> Unit = \{\}/);
assert.match(dispatchAbi,/requireCompleteAccountExportBudget = false/);
assert.match(store,/addPlaylistScopeTransitionListener[\s\S]*AUTHORITY_BOUNDARY\) invalidate\(\)/);
assert.doesNotMatch(store,/addHomeTransitionListener|addSwitchListener/);
console.log('PASS actual_store_native_adapter_original_capture_and_generic_route_source_closure');

const sync=read(prefix+'sync/VortXSyncManager.kt');
const syncFixture=read('scripts/tests/android-foryou-write-authority/tests-sync-fixture.kt');
assert.equal(method(syncFixture,'    internal fun captureLocalLibraryMutationAuthority('),method(sync,'    internal fun captureLocalLibraryMutationAuthority('));
const identityTypes=sync.slice(sync.indexOf('/** Stable identity of the exact captured command scope'),sync.indexOf('internal sealed interface SessionMutationResult'));
assert(syncFixture.includes(identityTypes));
const expectedAuthorityTypes='package com.vortx.android.sync\n\n'+identityTypes;
assert(expectedAuthorityTypes.endsWith('\n\n'),'Authority type extraction must end with its known declaration-separator LF');
assert.equal(read('scripts/tests/android-foryou-write-authority/tests-authority-types-extracted.kt'),expectedAuthorityTypes.slice(0,-1));
const home=read(prefix+'foryou/ForYouHome.kt');
const expectedHome='package com.vortx.android.foryou\n\n'+home.slice(home.indexOf('/** What Home shows'),home.indexOf('/** Home catalogs'));
assert(expectedHome.endsWith('\n\n'),'Home extraction must end with its known declaration-separator LF');
assert.equal(read('scripts/tests/android-foryou-write-authority/tests-home-extracted.kt'),expectedHome.slice(0,-1));
assert.match(read(prefix+'ui/viewmodel/CatalogViewModels.kt'),/_forYouUi\.value = com\.vortx\.android\.foryou\.forYouOpeningUi\(state, enabled/);
assert.match(store,/scope == other\.scope && registers == other\.registers/);
assert.match(store,/origin\.localAuthority/);
assert.match(store,/if \(failure is kotlinx\.coroutines\.CancellationException\) throw failure/);
console.log('PASS exact_auth_scope_home_projection_full_dispatch_ABI_and_raw_observation_conflation_sources');

assert.equal(method(sync,'    internal fun captureLocalLibraryMutationAdmission('),read('scripts/tests/android-foryou-write-authority/tests-library-admission-preserved.txt'),
  'Existing general library admission body remains exact; only the For You identity API is additive');
const admissionType=coordinator.slice(coordinator.indexOf('    internal class ForYouMutationAdmission('),coordinator.indexOf('    /**\n     * Final reclaim fence.',coordinator.indexOf('    internal class ForYouMutationAdmission(')));
assert(fixture.includes(admissionType));
