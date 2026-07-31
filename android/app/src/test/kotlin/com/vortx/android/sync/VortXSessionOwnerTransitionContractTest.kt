package com.vortx.android.sync

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VortXSessionOwnerTransitionContractTest {

    @Test
    fun everyPersistentOwnerMutationUsesTheDebridTransitionOutsideTheSessionMonitor() {
        val source = readSource()
        val setup = source
            .substringAfter("private val sessionState = DurableSessionState(")
            .substringBefore("private val ownerTracker")
        val signOut = source
            .substringAfter("fun signOut(): Boolean {")
            .substringBefore("/**\n     * The current session snapshot")
        val adopt = source
            .substringAfter("private fun adopt(token: String, acct: JSONObject, dataKey: ByteArray): Boolean {")
            .substringBefore("// MARK: - HTTP")

        assertTrue(setup.contains("ownerTransition = debridKeys::runOwnerTransition"))
        assertTrue(signOut.contains("sessionState.clear {"))
        assertFalse(signOut.contains("sessionState.serialized"))
        assertTrue(adopt.contains("sessionState.replace(s) {"))
        assertFalse(adopt.contains("sessionState.serialized"))
    }

    @Test
    fun restoreOnlyReconcilesAnAlreadyPersistedOwnerAndNeverMutatesPersistence() {
        val source = readSource()
        val restore = source
            .substringAfter("internal fun sessionOwnerSnapshot(): SessionOwnerSnapshot")
            .substringBefore("/** Retry an unavailable/corrupt secure-session read")

        assertTrue(restore.contains("val loaded = store.load()"))
        assertTrue(restore.contains("sessionState.restore(persisted)"))
        assertFalse(restore.contains("sessionState.replace"))
        assertFalse(restore.contains("sessionState.clear"))
        assertFalse(restore.contains("store.persist"))
        assertFalse(restore.contains("store.clear"))
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
