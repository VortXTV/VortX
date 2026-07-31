package com.vortx.android.sync

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VortXSessionOwnerTransitionContractTest {

    @Test
    fun everyPersistentOwnerMutationUsesTheDebridTransitionOutsideTheSessionMonitor() {
        val source = readSource()
        val setup = source
            .substringAfter("private val sessionState = DurableSessionState(")
            .substringBefore("private val operations")
        val signOut = source
            .substringAfter("fun signOut(): Boolean {")
            .substringBefore("/**\n     * The current session snapshot")
        val resume = source
            .substringAfter("private fun resumeRetainedSessionWork(retained: RetainedSessionWork?)")
            .substringBefore("private fun captureSyncLease()")
        val adopt = source
            .substringAfter("private fun adopt(")
            .substringBefore("// MARK: - HTTP")

        assertTrue(setup.contains("initialOwnerEpoch = initialSessionLoad.ownerEpochOrInitial()"))
        assertTrue(setup.contains("ownerTransition = debridKeys::runOwnerTransition"))
        assertTrue(signOut.contains("operations.invalidate {"))
        assertFalse(signOut.contains("hadPendingPush"))
        assertTrue(signOut.contains("hadActiveRealtime = realtime.isActive()"))
        assertTrue(signOut.contains("cancelSessionWork()"))
        assertTrue(signOut.contains("sessionState.clear {"))
        assertTrue(signOut.contains("resumeRetainedSessionWork(retained)"))
        assertTrue(signOut.indexOf("sessionState.serialized") < signOut.indexOf("cancelSessionWork()"))
        assertTrue(signOut.indexOf("cancelSessionWork()") < signOut.indexOf("sessionState.clear {"))
        assertTrue(resume.contains("armPendingSync(it, recordEdit = false)"))
        assertTrue(resume.contains("operations.mutateIfCurrent(retained.operationGeneration)"))
        assertTrue(resume.contains("sessionState.matches(retained.ownerEpoch)"))
        assertTrue(
            resume.contains(
                "shouldResumeRetainedRealtime(retained.hadActiveRealtime, retainedSessionIsCurrent)",
            ),
        )
        assertTrue(resume.contains("realtime.start()"))
        assertTrue(
            resume.indexOf("armPendingSync(it, recordEdit = false)") <
                resume.indexOf("realtime.start()"),
        )
        assertTrue(adopt.contains("val result = operation.commitSessionMutation("))
        assertTrue(adopt.contains("onCommitted = ::cancelSessionWork"))
        assertTrue(adopt.contains("sessionState.replace(s) {"))
        assertTrue(adopt.contains("armPendingSync(it, recordEdit = false)"))
        assertFalse(adopt.contains("sessionState.serialized"))
    }

    @Test
    fun unavailableRetryCanRestoreDurableSignedOutTruthWithoutMutatingPersistence() {
        val source = readSource()
        val restore = source
            .substringAfter("internal fun sessionOwnerSnapshot(): SessionOwnerSnapshot")
            .substringBefore("/** Retry an unavailable/corrupt secure-session read")

        assertTrue(restore.contains("val loaded = store.load()"))
        assertTrue(restore.contains("sessionState.restore(persisted, persistedOwnerEpoch)"))
        assertTrue(restore.contains("_account.value = persisted?.account"))
        assertTrue(restore.contains("SessionOwnerSnapshot.SignedOutLocal(sessionState.ownerEpoch)"))
        assertTrue(
            restore.indexOf("if (_sessionUiState.value == SessionUiState.UnknownOrUnavailable)") <
                restore.indexOf("sessionState.restore(persisted, persistedOwnerEpoch)"),
        )
        assertTrue(
            restore.indexOf("sessionState.restore(persisted, persistedOwnerEpoch)") <
                restore.indexOf("SessionOwnerSnapshot.SignedOutLocal(sessionState.ownerEpoch)"),
        )
        assertFalse(restore.contains("sessionState.replace"))
        assertFalse(restore.contains("sessionState.clear"))
        assertFalse(restore.contains("store.persist"))
        assertFalse(restore.contains("store.clear"))
    }

    @Test
    fun secureSessionStoreCommitsOwnerEpochWithSessionAndSignedOutTombstone() {
        val source = readSource()
        val sessionStore = source
            .substringAfter("private class SessionStore(appContext: Context)")
            .substringBefore("private sealed interface SessionLoad")
        val persist = sessionStore
            .substringAfter("fun persist(s: Session, ownerEpoch: Long): Boolean")
            .substringBefore("fun load(): SessionLoad")
        val load = sessionStore
            .substringAfter("fun load(): SessionLoad")
            .substringBefore("fun clear(ownerEpoch: Long): Boolean")
        val clear = sessionStore
            .substringAfter("fun clear(ownerEpoch: Long): Boolean")
            .substringBefore("private companion object")

        assertTrue(persist.contains("KEY_TOKEN to s.token"))
        assertTrue(persist.contains("KEY_ACCOUNT to acct.toString()"))
        assertTrue(persist.contains("KEY_DATA_KEY to VortXCrypto.b64(s.dataKey)"))
        assertTrue(persist.contains("KEY_OWNER_EPOCH to ownerEpoch.toString()"))
        assertTrue(load.contains("confirmedSnapshot(KEY_TOKEN, KEY_ACCOUNT, KEY_DATA_KEY, KEY_OWNER_EPOCH)"))
        assertTrue(load.contains("SessionLoad.Available(Session(token, account, dataKey), ownerEpoch)"))
        assertTrue(clear.contains("KEY_TOKEN to null"))
        assertTrue(clear.contains("KEY_ACCOUNT to null"))
        assertTrue(clear.contains("KEY_DATA_KEY to null"))
        assertTrue(clear.contains("KEY_OWNER_EPOCH to ownerEpoch.toString()"))
        assertTrue(clear.contains("store.setAndPurgeLegacy("))
    }

    @Test
    fun everyAuthFlowAcquiresAndRechecksItsOperationBeforeAdoption() {
        val source = readSource()
        val beginAuth = source
            .substringAfter("private fun beginAuthOperation()")
            .substringBefore("private fun cancelSessionWork()")
        val register = source
            .substringAfter("suspend fun register(email: String, username: String, password: String)")
            .substringBefore("/**\n     * Sign in with email-or-username")
        val signIn = source
            .substringAfter("suspend fun signIn(login: String, password: String, totp: String? = null)")
            .substringBefore("/**\n     * Forgot-password recovery")
        val recover = source
            .substringAfter("suspend fun recover(email: String, recoveryCode: String, newPassword: String)")
            .substringBefore("/** Sign out only after")
        val transport = source
            .substringAfter("private suspend fun request(")
            .substringBefore("/**\n     * Keystore-encrypted persistence")

        assertTrue(beginAuth.contains("operations.beginAuth()"))
        assertFalse(beginAuth.contains("cancelSessionWork"))
        listOf(register, signIn, recover).forEach { flow ->
            assertTrue(flow.indexOf("val operation = beginAuthOperation()") in 0 until flow.indexOf("request("))
            assertResponseFenceAfterEveryRequest(flow)
            assertTrue(flow.contains("adopt(operation, token, acct, dataKey)"))
        }
        assertMutatingAuthFence(
            register,
            endpoint = "\"/v1/auth/register\"",
            guard = "if (!operation.isCurrent())",
            permit = "val callPermit = operation.acquireCallPermit()",
            permitArgument = "callPermit = callPermit",
        )
        assertMutatingAuthFence(
            signIn,
            endpoint = "\"/v1/auth/login\"",
            guard = "if (!operation.isCurrent()) return AuthResult.Failed(AUTH_SUPERSEDED)",
            permit = "val loginPermit = operation.acquireCallPermit()",
            permitArgument = "callPermit = loginPermit",
        )
        assertMutatingAuthFence(
            recover,
            endpoint = "\"/v1/auth/recover-complete\"",
            guard = "if (!operation.isCurrent()) return AuthResult.Failed(AUTH_SUPERSEDED)",
            permit = "val completePermit = operation.acquireCallPermit()",
            permitArgument = "callPermit = completePermit",
        )
        assertTrue(
            signIn.indexOf("val preloginPermit = operation.acquireCallPermit()") <
                signIn.indexOf("\"/v1/auth/prelogin\""),
        )
        assertTrue(signIn.contains("callPermit = preloginPermit"))
        assertTrue(
            recover.indexOf("val startPermit = operation.acquireCallPermit()") <
                recover.indexOf("\"/v1/auth/recover-start\""),
        )
        assertTrue(recover.contains("callPermit = startPermit"))
        val openConnection = transport.indexOf("URL(BASE + path).openConnection()")
        val attach = transport.indexOf("callPermit.attachCancellation(opened::disconnect)")
        val outputStream = transport.indexOf("outputStream.use")
        assertTrue(transport.lastIndexOf("if (!callPermit.isCurrent())", openConnection) >= 0)
        assertTrue(attach > openConnection)
        assertTrue(transport.lastIndexOf("if (!callPermit.isCurrent())", outputStream) > attach)
        assertTrue(transport.contains("callPermit.close()"))
        assertTrue(transport.contains("Once the request body is accepted"))
    }

    @Test
    fun outboundPermitRegistryAtomicallyFencesAuthAndSessionCalls() {
        val source = readSource()
        val coordinator = source
            .substringAfter("internal class SessionOperationCoordinator")
            .substringBefore("internal class SyncSessionLease")
        val sessionAcquire = coordinator
            .substringAfter("fun acquireSessionCallPermit(")
            .substringBefore("internal inner class AuthOperation")
        val authAcquire = coordinator
            .substringAfter("fun acquireCallPermit(): OutboundCallPermit?")
            .substringBefore("fun commitSessionMutation(")

        assertTrue(coordinator.contains("Collections.newSetFromMap(IdentityHashMap())"))
        assertTrue(coordinator.contains("retireCallsLocked { it.owner == OutboundCallOwner.AUTH }"))
        assertTrue(coordinator.contains("cancellations = retireCallsLocked { true }"))
        assertTrue(coordinator.contains("it.owner == OutboundCallOwner.SESSION"))
        assertTrue(sessionAcquire.contains("synchronized(lock)"))
        assertTrue(sessionAcquire.contains("sessionGeneration != expectedGeneration || !validate()"))
        assertTrue(sessionAcquire.contains("registerCallLocked(OutboundCallOwner.SESSION"))
        assertTrue(authAcquire.contains("synchronized(lock)"))
        assertTrue(authAcquire.contains("authGeneration != expectedAuthGeneration"))
        assertTrue(authAcquire.contains("registerCallLocked(OutboundCallOwner.AUTH"))
        assertTrue(coordinator.contains("cancelCalls(cancellations)"))
    }

    @Test
    fun debouncedPushClearsItsPendingSlotOnlyAfterASuccessfulRetry() {
        val source = readSource()
        val requestSync = source
            .substringAfter("fun requestSyncSoon()")
            .substringBefore("/** Catch-up PULL entry point")

        val mark = requestSync.indexOf("pendingState.recordEdit(owner, proposedAttempt)")
        val createJob = requestSync.indexOf("scope.launch(start = CoroutineStart.LAZY)")
        val retry = requestSync.indexOf("runPendingSyncRetryLoop(")
        val push = requestSync.indexOf("val synced = syncUp(lease)")
        val complete = requestSync.indexOf("pendingState.completeAccepted(")

        assertTrue(requestSync.contains("armPendingSync(lease, recordEdit = true)"))
        assertTrue(mark >= 0)
        assertTrue(mark < createJob)
        assertTrue(createJob < retry)
        assertTrue(retry < push)
        assertTrue(push < complete)
        assertTrue(requestSync.contains("pendingState.owns(attempt, runningJob)"))
        assertTrue(requestSync.contains("maxDelayMs = SYNC_RETRY_MAX_MS"))
    }

    @Test
    fun durableDirtyMarkerIsPerAccountAndRestoredBeforeRealtimeOrForegroundPull() {
        val source = readSource()
        val pendingState = source
            .substringAfter("internal class DurablePendingSyncState(")
            .substringBefore("/**\n * The VortX end-to-end-encrypted account")
        val stateStore = source
            .substringAfter("private class SyncStateStore(appContext: Context)")
            .substringBefore("private companion object {")
        val startRealtime = source
            .substringAfter("fun startRealtime()")
            .substringBefore("/** Close the real-time channel")
        val syncDown = source
            .substringAfter("private suspend fun syncDown(")
            .substringBefore("/**\n     * Auto-sync")

        assertTrue(pendingState.contains("writeMarker(nextOwner.accountId, true)"))
        assertTrue(pendingState.contains("attempt !== expectedAttempt"))
        assertTrue(pendingState.contains("expectedAttempt.job !== job"))
        assertTrue(pendingState.contains("!isCurrentSnapshot()"))
        assertTrue(pendingState.contains("writeMarker(accountId, false)"))
        assertTrue(pendingState.contains("PendingMarkerTruth.DIRTY_UNCONFIRMED"))
        assertTrue(pendingState.contains("PendingMarkerTruth.READ_UNKNOWN"))
        assertTrue(pendingState.contains("PendingSyncClaim(blockPull = true)"))
        assertTrue(stateStore.contains("KEY_PENDING_PUSH + accountId"))
        assertTrue(stateStore.contains("return edit.commit()"))
        assertTrue(source.contains("const val KEY_PENDING_PUSH = \"pendingPush.\""))
        assertTrue(startRealtime.indexOf("retryPendingPushBeforePull") < startRealtime.indexOf("realtime.start()"))
        assertTrue(syncDown.contains("if (retryPendingPushBeforePull(lease)) return false"))
    }

    @Test
    fun syncLeaseCarriesOneImmutableOwnerIdentityThroughTransportAndCrypto() {
        val source = readSource()
        val leaseType = source
            .substringAfter("internal class SyncSessionLease(")
            .substringBefore("/**\n * The VortX end-to-end-encrypted account")
        val capture = source
            .substringAfter("private fun captureSyncLease(): SyncSessionLease?")
            .substringBefore("private fun isSyncLeaseCurrent")
        val pull = source
            .substringAfter("private suspend fun pullSyncDocResult(lease: SyncSessionLease)")
            .substringBefore("// ---- Push with optimistic concurrency ----")
        val push = source
            .substringAfter("private suspend fun pushSyncDocAt(")
            .substringBefore("/**\n     * Push a doc DERIVED")
        val matching = source
            .substringAfter("private fun sessionMatchesLease(lease: SyncSessionLease)")
            .substringBefore("// MARK: - Flows")
        val mergeLocal = source
            .substringAfter("private suspend fun mergeLocalIntoDoc(lease: SyncSessionLease)")
            .substringBefore("/**\n     * Pull the account doc")
        val syncDown = source
            .substringAfter("private suspend fun syncDown(")
            .substringBefore("/**\n     * Auto-sync")

        assertFalse(source.contains("internal data class SyncSessionLease"))
        assertTrue(leaseType.contains("private val immutableDataKey = dataKey.copyOf()"))
        assertTrue(leaseType.contains("fun dataKeyCopy(): ByteArray = immutableDataKey.copyOf()"))
        assertTrue(capture.contains("operationGeneration = operationGeneration"))
        assertTrue(capture.contains("ownerEpoch = sessionState.ownerEpoch"))
        assertTrue(capture.contains("accountId = current.account.id"))
        assertTrue(capture.contains("token = current.token"))
        assertTrue(pull.contains("val callPermit = acquireSyncCallPermit(lease)"))
        assertTrue(pull.contains("bearerToken = lease.token"))
        assertTrue(pull.contains("callPermit = callPermit"))
        assertTrue(push.contains("lease.dataKeyCopy()"))
        assertTrue(push.contains("lease.accountId"))
        assertTrue(push.contains("val callPermit = acquireSyncCallPermit(lease)"))
        assertTrue(push.contains("bearerToken = lease.token"))
        assertTrue(push.contains("callPermit = callPermit"))
        assertTrue(push.contains("publishIfSyncLeaseCurrent(lease)"))
        assertTrue(matching.contains("sessionState.ownerEpoch == lease.ownerEpoch"))
        assertTrue(matching.contains("current.account.id == lease.accountId"))
        assertTrue(matching.contains("current.token == lease.token"))
        assertFalse(matching.contains("dataKey"))
        assertTrue(mergeLocal.contains("publishIfSyncLeaseCurrent(lease)"))
        assertTrue(syncDown.contains("publishIfSyncLeaseCurrent(lease)"))
        assertTrue(syncDown.contains("advanceVersion(lease, version)"))
    }

    @Test
    fun mergeBothAndSignInReconciliationReuseOneCapturedLease() {
        val source = readSource()
        val reconcile = source
            .substringAfter("suspend fun reconcileAfterSignIn(): SignInReconcile")
            .substringBefore("/** Conflict resolution: adopt the account's roster")
        val mergeBoth = source
            .substringAfter("suspend fun mergeBoth(): Boolean")
            .substringBefore("// MARK: - Session adoption + persistence")

        assertTrue(reconcile.contains("val lease = captureSyncLease()"))
        assertTrue(reconcile.contains("accountHasSyncData(lease)"))
        assertTrue(reconcile.contains("syncUp(lease)"))
        assertTrue(mergeBoth.contains("val lease = captureSyncLease()"))
        assertTrue(mergeBoth.contains("syncDown(lease, force = true)"))
        assertTrue(mergeBoth.contains("syncUp(lease)"))
        assertEquals(1, mergeBoth.windowed("captureSyncLease".length).count { it == "captureSyncLease" })
    }

    private fun assertResponseFenceAfterEveryRequest(flow: String) {
        var request = flow.indexOf("request(")
        while (request >= 0) {
            val nextRequest = flow.indexOf("request(", request + 1)
            val responseFence = flow.indexOf("if (!operation.isCurrent())", request)
            assertTrue(responseFence > request)
            assertTrue(nextRequest < 0 || responseFence < nextRequest)
            request = nextRequest
        }
    }

    private fun assertMutatingAuthFence(
        flow: String,
        endpoint: String,
        guard: String,
        permit: String,
        permitArgument: String,
    ) {
        val endpointIndex = flow.indexOf(endpoint)
        val guardIndex = flow.lastIndexOf(guard, endpointIndex)
        val permitIndex = flow.lastIndexOf(permit, endpointIndex)
        val permitArgumentIndex = flow.indexOf(permitArgument, endpointIndex)
        assertTrue(endpointIndex >= 0)
        assertTrue(guardIndex >= 0)
        assertTrue(guardIndex < permitIndex)
        assertTrue(permitIndex < endpointIndex)
        assertTrue(permitArgumentIndex > endpointIndex)
    }

    private fun readSource(): String {
        val candidates = listOf(
            File("src/main/kotlin/com/vortx/android/sync/VortXSyncManager.kt"),
            File("app/src/main/kotlin/com/vortx/android/sync/VortXSyncManager.kt"),
            File("android/app/src/main/kotlin/com/vortx/android/sync/VortXSyncManager.kt"),
        )
        return candidates.firstOrNull(File::isFile)?.readText()
            ?: error("Could not locate VortXSyncManager.kt from ${File(".").absolutePath}")
    }
}
