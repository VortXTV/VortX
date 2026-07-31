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
        assertTrue(signOut.contains("hadPendingPush = hasPendingPush"))
        assertTrue(signOut.contains("cancelSessionWork()"))
        assertTrue(signOut.contains("sessionState.clear {"))
        assertTrue(signOut.contains("resumeRetainedSessionWork(retained)"))
        assertTrue(signOut.indexOf("sessionState.serialized") < signOut.indexOf("cancelSessionWork()"))
        assertTrue(signOut.indexOf("cancelSessionWork()") < signOut.indexOf("sessionState.clear {"))
        assertTrue(resume.contains("operations.mutateIfCurrent(retained.operationGeneration)"))
        assertTrue(resume.contains("sessionState.matches(retained.ownerEpoch)"))
        assertTrue(resume.contains("if (retained.hadPendingPush) requestSyncSoon()"))
        assertTrue(adopt.contains("val result = operation.commitSessionMutation("))
        assertTrue(adopt.contains("onCommitted = ::cancelSessionWork"))
        assertTrue(adopt.contains("sessionState.replace(s) {"))
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

        assertTrue(beginAuth.contains("operations.beginAuth()"))
        assertFalse(beginAuth.contains("cancelSessionWork"))
        listOf(register, signIn, recover).forEach { flow ->
            assertTrue(flow.indexOf("val operation = beginAuthOperation()") in 0 until flow.indexOf("request("))
            assertEquals(
                flow.countOccurrences("request("),
                flow.countOccurrences("operation.isCurrent()"),
            )
            assertTrue(flow.contains("adopt(operation, token, acct, dataKey)"))
        }
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
        assertTrue(pull.contains("bearerToken = lease.token"))
        assertTrue(push.contains("lease.dataKeyCopy()"))
        assertTrue(push.contains("lease.accountId"))
        assertTrue(push.contains("bearerToken = lease.token"))
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

    private fun String.countOccurrences(needle: String): Int =
        windowed(needle.length).count { it == needle }

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
