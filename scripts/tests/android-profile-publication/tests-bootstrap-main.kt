package com.vortx.android.engine
import com.vortx.android.profile.*
import com.vortx.android.integrations.*
import com.vortx.android.sync.SessionOwnerSnapshot
import kotlinx.coroutines.*
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

private fun CountDownLatch.waitForTest() { check(await(5,TimeUnit.SECONDS)) { "Bootstrap fixture timed out" } }
private class BootstrapFixture:AutoCloseable {
    val uiExecutor=java.util.concurrent.Executors.newSingleThreadExecutor { Thread(it,"profile-bootstrap-ui").apply { isDaemon=true } }
    val ioExecutor=java.util.concurrent.Executors.newSingleThreadExecutor { Thread(it,"profile-bootstrap-io").apply { isDaemon=true } }
    val ui=uiExecutor.asCoroutineDispatcher()
    val io=ioExecutor.asCoroutineDispatcher()
    val account=SessionOwnerSnapshot.Account("A",1)
    val initial=NativeProfileGateway.Projection(listOf(UserProfile("A")),"A")
    val runtime=VortxNativeSession(VortxNativeOwner(1,"A"),initial)
    val accounts=ExtractedProfileCoordinator(runtime,account)
    val store=ExtractedBootstrapStore()
    val access=NativeProfileAccess(
        publicationAdmission={ selected, action ->
            check(Thread.holdsLock(selected))
            synchronized(accounts.auth) { synchronized(accounts.lifecycleLock) {
                accounts.available && accounts.authenticatedEpoch==account.generation &&
                    accounts.mounted.get()?.session===selected && action()
            } }
        },
        capturePreparedPublication=accounts::captureProfilePresentation,
        session={ checkNotNull(accounts.mounted.get()).session },
    )
    init {
        com.vortx.android.profile.Dispatchers.Main=ui
        com.vortx.android.profile.Dispatchers.IO=io
        NativeProviderAccess.owner=account; NativeProviderAccess.available=true; NativeProviderAccess.revision.value=0L
        TraktAuth.currentSessionEpoch=1L
        access.saveForTest={ profile ->
            NativeProfileGateway.Projection(listOf(profile),profile.id).also(runtime::replaceProjection)
        }
    }
    fun migrationSeed() {
        store.seed(initial,account,1L)
        store.prefs.values[ScrobbleService.KEY_TRAKT_CONTINUE_WATCHING]=true
    }
    override fun close() { ui.close();io.close();uiExecutor.shutdownNow();ioExecutor.shutdownNow() }
}

private fun blockedCaptureLeavesMainRunnableAndEffectsOffSession() = runBlocking {
    BootstrapFixture().use { f ->
        val entered=CountDownLatch(1);val release=CountDownLatch(1);val once=AtomicInteger()
        f.runtime.beforeReadLock={ if(once.getAndIncrement()==0) { entered.countDown();release.waitForTest() } }
        f.store.onApply={
            check(Thread.currentThread().name=="profile-bootstrap-ui")
            check(!Thread.holdsLock(f.runtime)) { "Main retained or reacquired native Session" }
        }
        val job=async { f.store.attachNativeGateway(f.access,f.runtime) }
        withContext(kotlinx.coroutines.Dispatchers.IO) { entered.waitForTest() }
        withContext(f.ui) { check(f.store.profiles.isEmpty()) } // Can run while native worker is blocked.
        release.countDown();job.await()
        check(f.store.activeID=="A" && f.store.applied==1)
        println("PASS actual_bootstrap_blocked_capture_keeps_ui_runnable_and_main_effects_have_no_session")
    }
}

private fun preparedMetadataRejectsEveryStaleOwnerAndNeverWaitsForSession() = runBlocking {
    for(kind in listOf("accountABA","mountABA","profileABA","update","coordinator","unavailable","manager")) {
        BootstrapFixture().use { f ->
            val captured=f.accounts.captureProfilePresentation(f.runtime)
            when(kind) {
                "accountABA" -> { f.accounts.authenticatedEpoch=2;f.accounts.authenticatedEpoch=3 }
                "mountABA" -> { val old=f.accounts.mounted.get()!!;f.accounts.mounted.set(null);f.accounts.mounted.set(ExtractedProfileCoordinator.Mounted(old.account,old.session)) }
                "profileABA" -> { f.runtime.replaceProjection(NativeProfileGateway.Projection(listOf(UserProfile("B")),"B"));f.runtime.replaceProjection(f.initial) }
                "update" -> f.runtime.updates.value++
                "coordinator" -> f.accounts.changes.value++
                "unavailable" -> f.accounts.available=false
                "manager" -> f.accounts.managerIdentity=Any()
            }
            var published=false
            check(!captured.publishIfCurrent { published=true } && !published) { "Accepted stale $kind" }
        }
    }
    BootstrapFixture().use { f ->
        val captured=f.accounts.captureProfilePresentation(f.runtime)
        val held=CountDownLatch(1);val release=CountDownLatch(1)
        val holder=Thread({ synchronized(f.runtime) { held.countDown();release.waitForTest() } },"held-native-session").apply { isDaemon=true;start() }
        held.waitForTest()
        withContext(f.ui) { check(captured.publishIfCurrent { check(!Thread.holdsLock(f.runtime)) }) }
        release.countDown();holder.join(5000);check(!holder.isAlive)
    }
    println("PASS actual_metadata_gate_rejects_account_mount_profile_update_ABA_and_unavailable_auth_without_session")
}

private fun actualDetachedMigrationRetainsFailedRecoveryWitnessAndPendingEdit() = runBlocking {
    BootstrapFixture().use { f ->
        f.migrationSeed()
        f.store.continueWatchingMigration.capture("A",f.account,1L)
        f.store.continueWatchingMigration.retainDiscoveryCapture(UserProfile("A"),ProfileDiscoveryPreferences(hiddenCatalogs=listOf("retain-me")))
        f.access.saveForTest={
            // Real Session checkpoint uncertainty invalidates updates and makes withCurrentRead reject.
            // Persistence itself is a collaborator, not JNI/disk proof.
            f.runtime.recovering=true;f.runtime.updates.value++
            error("synthetic durable checkpoint failure")
        }
        val failure=runCatching { f.store.attachNativeGateway(f.access,f.runtime) }.exceptionOrNull()
        check(failure is IllegalStateException && failure.message?.contains("requires recovery")==true)
        val pending=f.store.continueWatchingMigration.snapshot()
        check(pending.witness==ContinueWatchingMigrationCheckpoint.Witness("A",f.account,1L))
        check(pending.pendingDiscovery?.hiddenCatalogs==listOf("retain-me"))
        check(f.store.prefs.getBoolean(ScrobbleService.KEY_TRAKT_CONTINUE_WATCHING,false))
        check(f.store.applied==0 && f.store.profiles.isEmpty())
    }
    println("PASS actual_checkpoint_policy_and_bootstrap_recovery_handoff_retain_qualified_pending_migration_without_success")
}

private fun successfulMigrationAcknowledgementSurvivesNativeRecapture() = runBlocking {
    BootstrapFixture().use { f ->
        f.migrationSeed()
        val captures=AtomicInteger()
        val access=NativeProfileAccess(
            publicationAdmission={ _,action -> action() },
            capturePreparedPublication={ runtime ->
                val prepared=f.accounts.captureProfilePresentation(runtime)
                if(captures.incrementAndGet()==1) runtime.updates.value++
                prepared
            }, session={ f.runtime },
        )
        access.saveForTest=f.access.saveForTest
        f.store.attachNativeGateway(access,f.runtime)
        check(captures.get()==2)
        check(f.store.active?.discovery?.continueWatchingSource=="trakt")
        check(!f.store.prefs.getBoolean(ScrobbleService.KEY_TRAKT_CONTINUE_WATCHING,true))
        check(f.store.continueWatchingMigration.witness==null)
    }
    println("PASS actual_legacy_migration_ACK_survives_stale_native_publication_and_exact_successor_recapture")
}

private fun unavailableProviderAndCancellationRetainWitness() = runBlocking {
    BootstrapFixture().use { f ->
        f.migrationSeed(); f.store.continueWatchingMigration.capture("A",f.account,1L)
        NativeProviderAccess.available=false
        check(runCatching { f.store.attachNativeGateway(f.access,f.runtime) }.isFailure)
        check(f.store.continueWatchingMigration.witness!=null)
        check(f.store.prefs.getBoolean(ScrobbleService.KEY_TRAKT_CONTINUE_WATCHING,false))
        NativeProviderAccess.available=true
        val cancellation=CancellationException("migration cancellation")
        f.access.saveForTest={throw cancellation}
        val actual=runCatching { f.store.attachNativeGateway(f.access,f.runtime) }.exceptionOrNull()
        check(actual===cancellation)
        check(f.store.continueWatchingMigration.witness!=null)
    }
    println("PASS provider_unavailable_and_cancel_never_retire_qualified_migration_or_report_success")
}

private fun boundedRecaptureStopsWithoutEmptySuccess() = runBlocking {
    BootstrapFixture().use { f ->
        val captures=AtomicInteger()
        val access=NativeProfileAccess(publicationAdmission={ _,action -> action() },
            capturePreparedPublication={runtime -> f.accounts.captureProfilePresentation(runtime).also { captures.incrementAndGet();runtime.updates.value++ } },session={f.runtime})
        val failure=runCatching { f.store.attachNativeGateway(access,f.runtime) }.exceptionOrNull()
        check(captures.get()==4 && failure?.message?.contains("Retry this account")==true)
        check(f.store.applied==0)
    }
    println("PASS bootstrap_native_update_storm_is_bounded_to_four_captures_and_explicit_retry")
}

fun runBootstrapBoundaryCases() {
    blockedCaptureLeavesMainRunnableAndEffectsOffSession()
    preparedMetadataRejectsEveryStaleOwnerAndNeverWaitsForSession()
    actualDetachedMigrationRetainsFailedRecoveryWitnessAndPendingEdit()
    successfulMigrationAcknowledgementSurvivesNativeRecapture()
    unavailableProviderAndCancellationRetainWitness()
    boundedRecaptureStopsWithoutEmptySuccess()
}
