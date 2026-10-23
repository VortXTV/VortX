@file:JvmName("ProjectionBoundaryPacket")

package com.vortx.android.engine

import com.vortx.android.profile.ContinueWatchingOwnerGate
import com.vortx.android.profile.ExtractedProfileStore
import com.vortx.android.profile.NativeProfileGateway
import com.vortx.android.profile.UserProfile
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CancellationException

private const val WAIT_SECONDS = 5L
private fun CountDownLatch.awaitBounded() { check(await(WAIT_SECONDS, TimeUnit.SECONDS)) { "Fixture latch timed out" } }
private val cwMonitor = ContinueWatchingOwnerGate::class.java.getDeclaredField("monitor").apply { isAccessible = true }
    .get(ContinueWatchingOwnerGate)
private fun projection(id: String) = NativeProfileGateway.Projection(listOf(UserProfile(id)), id)

private class Fixture {
    val auth = Any()
    val lifecycle = Any()
    val original = projection("A")
    val runtime = VortxNativeSession(VortxNativeOwner(1, "A"), original)
    val mounted = AtomicReference(runtime)
    val admissionCalls = AtomicInteger()
    var accountEpoch = 1L // This synthetic admission collaborator reads it under auth.
    var sessionProvider: (() -> VortxNativeSession)? = null
    var beforeAuth: (() -> Unit)? = null
    val access = NativeProfileAccess(
        publicationAdmission = { selected, action ->
            check(Thread.holdsLock(selected)) { "Auth admission entered before native Session" }
            admissionCalls.incrementAndGet()
            beforeAuth?.invoke()
            synchronized(auth) {
                synchronized(lifecycle) {
                    if (mounted.get() !== selected || accountEpoch != 1L) false else action()
                }
            }
        },
        session = { sessionProvider?.invoke() ?: mounted.get() },
    )
    fun store(action: (NativeProfileGateway.Projection, Boolean) -> Unit) = ExtractedProfileStore(access, action)
    fun assertPublicationLocks() {
        check(Thread.holdsLock(cwMonitor)) { "Continue Watching owner gate missing" }
        check(Thread.holdsLock(runtime)) { "Native Session monitor missing" }
        check(Thread.holdsLock(auth)) { "Authenticated admission missing" }
        check(Thread.holdsLock(lifecycle)) { "Mounted lifecycle admission missing" }
    }
    fun assertLocksReleased() {
        check(!Thread.holdsLock(cwMonitor) && !Thread.holdsLock(runtime) &&
            !Thread.holdsLock(auth) && !Thread.holdsLock(lifecycle)) { "A publication monitor escaped" }
    }
}

private inline fun <reified T : Throwable> expectThrow(action: () -> Unit): T {
    try { action() } catch (actual: Throwable) {
        check(actual is T) { "Expected ${T::class.java.name}, received ${actual.javaClass.name}" }
        return actual
    }
    error("Expected ${T::class.java.name}")
}

private fun successRetainsAllPublicationFencesAndGenericIdentity() {
    val f = Fixture()
    var applied = 0
    f.store { value, force ->
        f.assertPublicationLocks()
        // Initial provider capture reuses the already fenced value, before any migration mutation.
        synchronized(f.auth) { check(value == f.original) }
        check(value == f.original && force)
        applied++
    }.publish(f.original, forceSettings = true)
    check(applied == 1 && f.admissionCalls.get() == 1)
    val identity = Any()
    check(f.access.withProjection(f.original) { identity } === identity)
    f.assertLocksReleased()
    println("PASS actual_store_and_access_boundaries_hold_all_fences_and_preserve_result_identity")
}

private fun concurrentWorkerSessionThenAuthCompletesWithoutInversion() {
    val f = Fixture()
    val workerHasSession = CountDownLatch(1)
    val uiAttemptedSession = CountDownLatch(1)
    val workerEnteredAuth = CountDownLatch(1)
    val workerFailure = AtomicReference<Throwable?>()
    val uiFailure = AtomicReference<Throwable?>()
    val applied = AtomicInteger()
    f.sessionProvider = {
        // withCurrentRead acquires Session before read; announce the UI attempt before that monitor.
        if (Thread.currentThread().name == "projection-fixture-ui") uiAttemptedSession.countDown()
        f.mounted.get()
    }
    val worker = Thread({
        try {
            f.runtime.owned(f.runtime.owner) {
                workerHasSession.countDown()
                uiAttemptedSession.awaitBounded()
                check(f.admissionCalls.get() == 0) { "UI acquired auth before waiting for worker Session" }
                synchronized(f.auth) { workerEnteredAuth.countDown() }
            }
        } catch (failure: Throwable) { workerFailure.set(failure) }
    }, "projection-fixture-worker").apply { isDaemon = true }
    val ui = Thread({
        try {
            workerHasSession.awaitBounded()
            f.store { _, _ -> f.assertPublicationLocks(); applied.incrementAndGet() }.publish(f.original)
        } catch (failure: Throwable) { uiFailure.set(failure) }
    }, "projection-fixture-ui").apply { isDaemon = true }
    worker.start()
    ui.start()
    worker.join(WAIT_SECONDS * 1_000)
    ui.join(WAIT_SECONDS * 1_000)
    check(!worker.isAlive && !ui.isAlive) { "Publication schedule did not complete; daemon fixtures cannot keep JVM alive" }
    workerFailure.get()?.let { throw it }
    uiFailure.get()?.let { throw it }
    check(workerEnteredAuth.count == 0L && applied.get() == 1)
    println("PASS concurrent_session_then_auth_schedule_finishes_before_ui_admission")
}

private fun missingProductionAdmissionRejectsPublication() {
    val f = Fixture()
    val access = NativeProfileAccess { f.runtime }
    var applied = 0
    expectThrow<IllegalStateException> { access.withProjection(f.original) { applied++ } }
    check(applied == 0)
    f.assertLocksReleased()
    println("PASS missing_admission_never_publishes")
}

private fun staleProjectionRejectsPublication() {
    val f = Fixture()
    f.runtime.replaceProjection(projection("newer"))
    var applied = 0
    expectThrow<IllegalStateException> { f.store { _, _ -> applied++ }.publish(f.original) }
    check(applied == 0)
    check(f.runtime.fullReads.get() == 1) { "stale expected projection must reject after one fresh read" }
    f.assertLocksReleased()
    println("PASS stale_projection_never_publishes")
}

private fun replacedRuntimeRejectsPublication() {
    val f = Fixture()
    val replacement = VortxNativeSession(VortxNativeOwner(2, "A"), f.original)
    val calls = AtomicInteger()
    // The first lookup is capture; the lookup under admission observes a replacement runtime.
    f.sessionProvider = { if (calls.incrementAndGet() == 1) f.runtime else replacement }
    var applied = 0
    expectThrow<IllegalStateException> { f.store { _, _ -> applied++ }.publish(f.original) }
    check(applied == 0 && calls.get() == 2)
    f.assertLocksReleased()
    println("PASS_runtime_replacement_never_publishes_old_projection")
}

private fun replacedAccountEpochRejectsPublication() {
    val f = Fixture()
    f.beforeAuth = { f.accountEpoch = 2 }
    var applied = 0
    expectThrow<IllegalStateException> { f.store { _, _ -> applied++ }.publish(f.original) }
    check(applied == 0)
    f.assertLocksReleased()
    println("PASS_replaced_account_epoch_rejected_by_admission")
}

private fun throwingActionsPreserveIdentityAndReleaseEveryMonitor() {
    val cancel = CancellationException("fixture cancellation")
    val fatal = AssertionError("fixture fatal")
    val ordinary = IllegalStateException("fixture ordinary")
    for ((name, failure) in listOf("cancellation" to cancel, "fatal" to fatal, "ordinary" to ordinary)) {
        val f = Fixture()
        val actual = expectThrow<Throwable> {
            f.store { _, _ -> f.assertPublicationLocks(); throw failure }.publish(f.original)
        }
        check(actual === failure) { "$name identity changed or failure swallowed" }
        f.assertLocksReleased()
        println("PASS_${name}_identity_propagates_and_all_publication_monitors_release")
    }
}

private fun ordinaryPublicationUsesOneBoundaryReadAndRefreshUsesTwo() {
    val f = Fixture()
    f.store { value, _ -> f.assertPublicationLocks(); check(value == f.original) }.publish(f.original)
    check(f.runtime.fullReads.get() == 1) { "withProjection repeated a full-state read" }
    val refresh = Fixture()
    val prepared = refresh.access.read()
    refresh.store { value, _ -> refresh.assertPublicationLocks(); check(value == prepared) }.publish(prepared)
    check(refresh.runtime.fullReads.get() == 2) { "initial capture plus boundary must remain two reads" }
    println("PASS metered_boundary_reads=1 common_refresh_reads=2 synthetic_payload_not_device_latency")
}

private fun closedRecoveryAndAccountFailuresRejectBeforePublication() {
    for ((name, invalidate) in listOf<Pair<String, (VortxNativeSession) -> Unit>>(
        "closed" to { it.closed = true },
        "recovering" to { it.recovering = true },
        "account" to { it.accountCurrent = false },
    )) {
        val f = Fixture(); var applied = 0; invalidate(f.runtime)
        expectThrow<IllegalStateException> { f.store { _, _ -> applied++ }.publish(f.original) }
        check(applied == 0 && f.admissionCalls.get() == 0 && f.runtime.fullReads.get() == 0)
        f.assertLocksReleased()
        println("PASS " + name + "_rejects_before_snapshot_or_publication")
    }
}

private fun nullableResultAndFreshProjectionArePreserved() {
    val f = Fixture()
    check(f.access.withProjection<String?>(f.original) { null } == null)
    val newer = NativeProfileGateway.Projection(listOf(UserProfile("A"), UserProfile("added")), "A")
    f.runtime.replaceProjection(newer)
    check(f.access.read() == newer)
    expectThrow<IllegalStateException> { f.access.withProjection(f.original) { error("stale action ran") } }
    check(f.access.withProjection(newer) { newer } === newer)
    f.assertLocksReleased()
    println("PASS nullable_result_identity_and_fresh_projection_without_cache")
}

private fun migrationMutationStillRequiresFreshSaveReadbackAndNestedPublication() {
    val f = Fixture()
    val savedValue = NativeProfileGateway.Projection(listOf(UserProfile("A"), UserProfile("added")), "A")
    var publications = 0
    lateinit var store: ExtractedProfileStore
    store = f.store { value, _ ->
        f.assertPublicationLocks(); publications++
        if (publications == 1) {
            check(value == f.original && f.access.read() == value)
            f.runtime.replaceProjection(savedValue) // Synthetic save collaborator changes actual boundary's payload.
            val saved = f.access.read()
            check(saved == savedValue && f.access.read() == saved)
            store.publish(saved, forceSettings = true)
        } else check(value == savedValue)
    }
    store.publish(f.original)
    check(publications == 2 && f.runtime.fullReads.get() == 5)
    f.assertLocksReleased()
    println("PASS migration_save_readback_and_nested_fresh_publication_remain_live_reads")
}

fun main() {
    successRetainsAllPublicationFencesAndGenericIdentity()
    concurrentWorkerSessionThenAuthCompletesWithoutInversion()
    missingProductionAdmissionRejectsPublication()
    staleProjectionRejectsPublication()
    replacedRuntimeRejectsPublication()
    replacedAccountEpochRejectsPublication()
    throwingActionsPreserveIdentityAndReleaseEveryMonitor()
    ordinaryPublicationUsesOneBoundaryReadAndRefreshUsesTwo()
    closedRecoveryAndAccountFailuresRejectBeforePublication()
    nullableResultAndFreshProjectionArePreserved()
    migrationMutationStillRequiresFreshSaveReadbackAndNestedPublication()
    println("PASS projection_boundary_packet_complete cases=15")
}
