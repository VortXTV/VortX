package com.vortx.android.sync

import androidx.lifecycle.ViewModelStore
import com.vortx.android.engine.AccountFileLocalPresence
import com.vortx.android.integrations.CredentialStoreAccess
import com.vortx.android.integrations.NativeProviderAccess
import com.vortx.android.integrations.NativeProviderVault
import com.vortx.android.security.AccountFileProviderWriters
import com.vortx.android.security.PersistentCredentialAvailability
import com.vortx.android.security.PersistentCredentialSnapshot
import com.vortx.android.ui.viewmodel.VortXAccountFormState
import com.vortx.android.ui.viewmodel.VortXAccountMode
import com.vortx.android.ui.viewmodel.VortXAccountViewModel
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class PickerFileRecoverySignInTest {
    private class CountingProviderStore : CredentialStoreAccess {
        private val values = mutableMapOf<String, String>()
        var ordinaryReads = 0
            private set
        var existingProbes = 0
            private set
        var writes = 0
            private set

        override fun string(key: String): String? {
            ordinaryReads++
            return values[key]
        }

        override fun confirmedSnapshot(vararg keys: String): PersistentCredentialSnapshot {
            ordinaryReads++
            return PersistentCredentialSnapshot(PersistentCredentialAvailability.AVAILABLE, keys.associateWith(values::get))
        }

        override fun inspectExisting(key: String, isInert: (String) -> Boolean): AccountFileLocalPresence {
            existingProbes++
            return if (values[key]?.let { !isInert(it) } == true) AccountFileLocalPresence.PRESENT
            else AccountFileLocalPresence.ABSENT
        }

        override fun set(key: String, value: String?): Boolean = set(mapOf(key to value))
        override fun set(values: Map<String, String?>): Boolean {
            writes++
            values.forEach { (key, value) -> if (value == null) this.values.remove(key) else this.values[key] = value }
            return true
        }
        override fun clear(vararg keys: String): Boolean = set(keys.associateWith { null })
    }

    @Test fun signedOutGrantCannotBeReusedAfterCancelOrResumeWithoutAnAdoptedOwner() = runTest {
        val manager = VortXSyncManager(RevisionContext(), backgroundScope)
        manager.installSessionRestoreTestSeam(null)
        assertTrue(manager.sessionOwnerSnapshot() is SessionOwnerSnapshot.SignedOutLocal)
        val original = checkNotNull(manager.capturePickerAccountSnapshot())
        val grant = checkNotNull(manager.beginPickerFileRecoverySignIn(original))
        assertNull(manager.beginPickerFileRecoverySignIn(original))

        manager.abandonPickerFileRecoverySignIn(grant)
        val result = manager.signInForPickerFileRecovery(grant, "synthetic", "synthetic", null, PickerAuthCompletion()) { true }
        assertTrue(result is VortXSyncManager.AuthResult.Failed)
        assertTrue(manager.isPickerAccountCurrent(original))
        assertFalse(manager.resumePickerFileRecovery(original))
        assertFalse(manager.pickerFileRecoveryPaused.value)
        manager.abandonPickerFileRecoverySignIn(checkNotNull(manager.beginPickerFileRecoverySignIn(original)))
    }

    @Test fun editedAttemptDrainsAndRetriesInRecoveryModeUntilExplicitBack() = runTest {
        val models = ViewModelStore()
        val first = CompletableDeferred<Unit>()
        val second = CompletableDeferred<Unit>()
        val manager = VortXSyncManager(RevisionContext(), backgroundScope)
        var attempts = 0
        val transport: SyncRequestTestSeam = { method, path, _, bearer ->
            assertEquals("POST", method)
            assertEquals("/v1/auth/prelogin", path)
            assertNull(bearer)
            val release = when (++attempts) {
                1 -> first
                2 -> second
                else -> error("Unexpected auth request")
            }
            withContext(NonCancellable) { release.await() }
            503 to null
        }
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        try {
            // Reuse the actual request transport seam without installing a signed-in fixture.
            manager.javaClass.getDeclaredField("requestTestSeam").apply { isAccessible = true }.set(manager, transport)
            manager.installSessionRestoreTestSeam(null)
            assertTrue(manager.sessionOwnerSnapshot() is SessionOwnerSnapshot.SignedOutLocal)
            val originalDrain = checkNotNull(manager.captureProviderRetryDrainRewrite())
            val model = VortXAccountViewModel(manager).also { models.put("recovery", it) }
            assertTrue(model.openPickerFileRecoverySignIn(checkNotNull(manager.capturePickerAccountSnapshot())))
            model.onLoginChange("synthetic")
            model.onPasswordChange("first")
            model.submit()
            runCurrent()
            assertEquals(1, attempts)

            model.onPasswordChange("edited")
            model.onTotpChange("012345")
            model.onModeChange(VortXAccountMode.REGISTER)
            model.startQrJoiner()
            model.submit()
            runCurrent()
            assertTrue(model.pickerFileRecoverySignIn.value)
            assertEquals(VortXAccountMode.SIGN_IN, model.mode.value)
            assertEquals(1, attempts)

            first.complete(Unit)
            runCurrent()
            assertEquals(VortXAccountFormState.Idle, model.formState.value)
            assertTrue(model.pickerFileRecoverySignIn.value)
            model.submit()
            runCurrent()
            assertEquals(2, attempts)
            assertTrue(model.requestClosePickerPresentation())
            assertFalse(model.pickerFileRecoverySignIn.value)
            assertFalse(model.pickerPresentationOpen.value)
            second.complete(Unit)
            runCurrent()
            assertEquals(VortXAccountFormState.Idle, model.formState.value)
            assertTrue(manager.sessionOwnerSnapshot() is SessionOwnerSnapshot.SignedOutLocal)
            assertTrue(originalDrain { true }) // An auth-only failure did not replace the ordinary owner.
        } finally {
            first.complete(Unit)
            second.complete(Unit)
            models.clear()
            runCurrent()
            Dispatchers.resetMain()
        }
    }

    @Test fun cancellationBeforeQueuedRecoveryBodyStartsReleasesOnlyItsAttempt() = runTest {
        val models = ViewModelStore()
        val manager = VortXSyncManager(RevisionContext(), backgroundScope)
        var attempts = 0
        val transport: SyncRequestTestSeam = { method, path, _, bearer ->
            assertEquals("POST", method)
            assertEquals("/v1/auth/prelogin", path)
            assertNull(bearer)
            attempts++
            503 to null
        }
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        try {
            manager.javaClass.getDeclaredField("requestTestSeam").apply { isAccessible = true }.set(manager, transport)
            manager.installSessionRestoreTestSeam(null)
            assertTrue(manager.sessionOwnerSnapshot() is SessionOwnerSnapshot.SignedOutLocal)
            val model = VortXAccountViewModel(manager).also { models.put("recovery", it) }
            assertTrue(model.openPickerFileRecoverySignIn(checkNotNull(manager.capturePickerAccountSnapshot())))
            model.onLoginChange("synthetic")
            model.onPasswordChange("before-edit")
            model.submit()
            assertEquals(VortXAccountFormState.Submitting, model.formState.value)
            model.onPasswordChange("after-edit") // The scheduled job has not entered its body.
            assertEquals(0, attempts)
            runCurrent()

            assertEquals(VortXAccountFormState.Idle, model.formState.value)
            assertEquals("after-edit", model.password.value)
            assertTrue(model.pickerFileRecoverySignIn.value)
            assertEquals(0, attempts)
            model.submit()
            runCurrent()
            assertEquals(1, attempts)
            assertTrue(model.pickerFileRecoverySignIn.value)
            assertNull(manager.beginPickerFileRecoverySignIn(checkNotNull(manager.capturePickerAccountSnapshot())))
        } finally {
            models.clear()
            runCurrent()
            Dispatchers.resetMain()
        }
    }

    @Test fun realTotpAdoptionPausesRoutineWorkAndResumeWaitsForOwnedRestoreDrain() = runTest {
        val models = ViewModelStore()
        val releaseRestore = CompletableDeferred<Unit>()
        val enteredRestore = CompletableDeferred<Unit>()
        val manager = VortXSyncManager(RevisionContext(), backgroundScope)
        var persisted = 0
        var loginRequests = 0
        val providerStore = CountingProviderStore()
        val password = "fixture-password"
        val salt = ByteArray(16) { 23 }
        val masterKey = VortXCrypto.masterKey(password, salt, VortXCrypto.MIN_ITERS)
        val wrapped = try { checkNotNull(VortXCrypto.seal(masterKey, RenewalFixtures.key)) }
        finally { masterKey.fill(0) }
        val transport: SyncRequestTestSeam = { method, path, body, bearer ->
            assertEquals("POST", method)
            assertNull(bearer)
            when (path) {
                "/v1/auth/prelogin" -> 200 to JSONObject()
                    .put("kdfSalt", VortXCrypto.b64(salt)).put("kdfIters", VortXCrypto.MIN_ITERS)
                "/v1/auth/login" -> when (++loginRequests) {
                    1 -> {
                        assertFalse(checkNotNull(body).has("totp"))
                        401 to JSONObject().put("error", "totp_required")
                    }
                    2 -> {
                        assertEquals("012345", checkNotNull(body).getString("totp"))
                        val account = RenewalFixtures.account
                        200 to JSONObject().put("token", RenewalFixtures.prior).put("wrappedKeyPassword", wrapped)
                            .put("account", JSONObject().put("id", account.id).put("email", account.email)
                                .put("username", account.username).put("twoFactorEnabled", account.twoFactorEnabled))
                    }
                    else -> error("Unexpected additional login")
                }
                else -> error("Routine cloud work escaped the paused session")
            }
        }
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        try {
            // Keep actual DurableSessionState.replace and adoption, substituting only its durable writer.
            val durable = manager.javaClass.getDeclaredField("sessionState").apply { isAccessible = true }.get(manager)
            val persist: (VortXSyncManager.Session, Long) -> Boolean = { session, epoch ->
                assertEquals(RenewalFixtures.account, session.account)
                persisted++
                manager.installSessionRestoreTestSeam(session, epoch)
                true
            }
            durable.javaClass.getDeclaredField("persist").apply { isAccessible = true }.set(durable, persist)
            manager.javaClass.getDeclaredField("requestTestSeam").apply { isAccessible = true }.set(manager, transport)
            manager.installSessionRestoreTestSeam(null)
            assertTrue(manager.sessionOwnerSnapshot() is SessionOwnerSnapshot.SignedOutLocal)

            val model = VortXAccountViewModel(manager).also { models.put("recovery", it) }
            suspend fun <T> awaitStage(label: String, action: suspend () -> T): T = try {
                // The production KDF uses Dispatchers.Default, so use a wall-clock bound.
                withContext(Dispatchers.Default) { withTimeout(8_000) { action() } }
            } catch (timeout: TimeoutCancellationException) {
                throw AssertionError("$label timed out, loginRequests=$loginRequests, persisted=$persisted, " +
                    "form=${model.formState.value}, challenge=${model.totpRequired.value}, " +
                    "presentation=${model.pickerPresentationOpen.value}, paused=${manager.pickerFileRecoveryPaused.value}", timeout)
            }

            val signedOut = checkNotNull(manager.capturePickerAccountSnapshot())
            // Exercise the manager's actual NativeProviderAdmission with only the vault's backing synthetic.
            manager.installNativeGatewayTestSeam(object : NativeAccountGateway {
                override fun retire() = Unit
                override suspend fun applyDocument(account: SessionOwnerSnapshot.Account, document: JSONObject,
                    isCurrent: () -> Boolean): Boolean = error("Unexpected native application")
                override fun exportDocument(account: SessionOwnerSnapshot.Account): NativeAccountExport? =
                    error("Unexpected native export")
            }, providerStore)
            val vault = manager.javaClass.getDeclaredField("fileRestoreProviderVault")
                .apply { isAccessible = true }.get(manager) as NativeProviderVault
            val signedOutDrain = checkNotNull(manager.captureProviderRetryDrainRewrite())
            assertTrue(signedOutDrain { true })
            assertFalse(manager.isPickerFileRecoveryPaused(signedOut))
            assertTrue(model.openPickerFileRecoverySignIn(signedOut))
            model.onLoginChange("fixture")
            model.onPasswordChange(password)
            val immediateRetry = async(UnconfinedTestDispatcher(testScheduler)) {
                model.totpRequired.first { it }
                model.formState.first { it == VortXAccountFormState.Idle }
                assertEquals(1, loginRequests)
                assertEquals(0, persisted)
                assertTrue(model.pickerFileRecoverySignIn.value)
                model.onTotpChange("012345")
                model.submit() // Run directly from visible readiness, before unrelated Main work.
                assertEquals(VortXAccountFormState.Submitting, model.formState.value)
            }
            model.submit()
            awaitStage("First TOTP response and immediate visible-ready retry") { immediateRetry.await() }
            awaitStage("TOTP retry and original recovery adoption") { model.pickerPresentationOpen.first { !it } }

            assertEquals(2, loginRequests)
            assertEquals(1, persisted)
            assertTrue(manager.pickerFileRecoveryPaused.value)
            assertFalse(model.pickerFileRecoverySignIn.value)
            val original = checkNotNull(manager.capturePickerAccountSnapshot())
            assertEquals(RenewalFixtures.account, original.account)
            assertTrue(manager.isPickerFileRecoveryPaused(original))
            assertFalse(manager.isPickerFileRecoveryPaused(signedOut))
            assertFalse(signedOutDrain { error("A retired drain rewrote the queue") })
            assertNull(manager.captureProviderRetryDrainRewrite())
            assertNull(manager.captureRealtimeLease())
            assertFalse(manager.syncDown(force = true))
            assertFalse(manager.pushThisDevice())

            val providerOwner = manager.sessionOwnerSnapshot() as SessionOwnerSnapshot.Account
            assertTrue(AccountFileProviderWriters.withWriter(false) { true })
            assertNull(NativeProviderAccess.read(setOf("tmdb")))
            assertFalse(NativeProviderAccess.edit(mapOf("tmdb" to "synthetic")))
            assertNull(NativeProviderAccess.captureProspective(providerOwner))
            assertEquals(0, providerStore.ordinaryReads)
            assertEquals(0, providerStore.writes)
            assertEquals(0, providerStore.existingProbes)

            var routeCurrent = true
            val restore = async {
                runCatching {
                    manager.restoreAccountBackupFile(original, byteArrayOf(1), { routeCurrent }) { owner, requireOriginal, _ ->
                        requireOriginal()
                        assertEquals(providerOwner, owner.account)
                        assertFalse(AccountFileProviderWriters.withWriter(false) { true })
                        assertEquals(AccountFileLocalPresence.UNAVAILABLE,
                            NativeProviderAccess.inspectRestoreVaultPresence(owner.account.copy(generation = owner.account.generation + 1), vault))
                        val otherVault = NativeProviderVault(CountingProviderStore())
                        assertEquals(AccountFileLocalPresence.UNAVAILABLE,
                            NativeProviderAccess.inspectRestoreVaultPresence(owner.account, otherVault))
                        assertEquals(AccountFileLocalPresence.ABSENT,
                            NativeProviderAccess.inspectRestoreVaultPresence(owner.account, vault))
                        assertEquals(1, providerStore.existingProbes)
                        assertEquals(0, providerStore.ordinaryReads)
                        assertEquals(0, providerStore.writes)
                        enteredRestore.complete(Unit)
                        withContext(NonCancellable) { releaseRestore.await() }
                    }
                }
            }
            runCurrent()
            assertTrue(enteredRestore.isCompleted)
            routeCurrent = false
            val resume = async { manager.resumePickerFileRecovery(original) }
            runCurrent()
            assertFalse(resume.isCompleted)
            assertTrue(manager.pickerFileRecoveryPaused.value)
            releaseRestore.complete(Unit)
            assertTrue(awaitStage("Retired Restore worker drains") { restore.await() }.exceptionOrNull() is kotlinx.coroutines.CancellationException)
            assertTrue(awaitStage("Original recovery pause resumes") { resume.await() })
            assertFalse(manager.pickerFileRecoveryPaused.value)
            assertFalse(manager.isPickerFileRecoveryPaused(original))
            assertFalse(signedOutDrain { error("Resume revived a retired drain") })
            assertTrue(checkNotNull(manager.captureProviderRetryDrainRewrite()).invoke { true })
            checkNotNull(manager.captureRealtimeLease())
            assertFalse(manager.resumePickerFileRecovery(original))

            assertNull(checkNotNull(NativeProviderAccess.read(setOf("tmdb"))).values["tmdb"])
            assertEquals(2, providerStore.ordinaryReads) // Load and read back one new inert vault.
            assertEquals(1, providerStore.writes)
            checkNotNull(NativeProviderAccess.captureProspective(providerOwner)).use { prospective ->
                assertTrue(prospective.withCurrent(JSONObject()) { true })
            }
            assertEquals(4, providerStore.ordinaryReads) // Capture and recheck the same bound vault.
            assertEquals(1, providerStore.writes)
        } finally {
            releaseRestore.complete(Unit)
            models.clear()
            runCurrent()
            NativeProviderAccess.unbindForTest()
            Dispatchers.resetMain()
        }
    }

    @Test fun drainRewriteDoesNotSurviveTemporarySecureStoreUnavailability() = runTest {
        val manager = VortXSyncManager(RevisionContext(), backgroundScope)
        manager.installSessionRestoreTestSeam(null)
        assertTrue(manager.sessionOwnerSnapshot() is SessionOwnerSnapshot.SignedOutLocal)
        val original = checkNotNull(manager.captureProviderRetryDrainRewrite())

        manager.installUnavailableSessionRestoreTestSeam()
        assertTrue(manager.sessionOwnerSnapshot() is SessionOwnerSnapshot.UnknownOrUnavailable)
        assertNull(manager.captureProviderRetryDrainRewrite())
        assertFalse(original { error("Unavailable owner rewrote the queue") })

        manager.installSessionRestoreTestSeam(null)
        assertTrue(manager.sessionOwnerSnapshot() is SessionOwnerSnapshot.SignedOutLocal)
        assertFalse(original { error("A new secure read revived an old drain") })
        assertTrue(checkNotNull(manager.captureProviderRetryDrainRewrite()).invoke { true })
    }

    @Test fun retiredAttemptDoesNotConsumeTheCurrentRecoveryPresentation() = runTest {
        val manager = VortXSyncManager(RevisionContext(), backgroundScope)
        manager.installSessionRestoreTestSeam(null)
        assertTrue(manager.sessionOwnerSnapshot() is SessionOwnerSnapshot.SignedOutLocal)
        val original = checkNotNull(manager.capturePickerAccountSnapshot())
        val grant = checkNotNull(manager.beginPickerFileRecoverySignIn(original))
        val result = manager.signInForPickerFileRecovery(grant, "synthetic", "synthetic", null, PickerAuthCompletion()) { false }
        assertTrue(result is VortXSyncManager.AuthResult.Failed)
        assertTrue(manager.isPickerAccountCurrent(original))
        assertNull(manager.beginPickerFileRecoverySignIn(original))
        manager.abandonPickerFileRecoverySignIn(grant)
        manager.abandonPickerFileRecoverySignIn(checkNotNull(manager.beginPickerFileRecoverySignIn(original)))
    }

    @Test fun refusedConditionalAuthLeavesOriginalAuthAndPickerAuthorityCurrent() {
        val coordinator = SessionOperationCoordinator()
        val active = coordinator.beginAuth()
        val authority = coordinator.pickerAuthorityRevision.value
        assertNull(coordinator.beginAuthIf { false })
        assertTrue(active.isCurrent())
        assertEquals(authority, coordinator.pickerAuthorityRevision.value)
        checkNotNull(coordinator.beginAuthIf { true })
        assertFalse(active.isCurrent())
        assertTrue(coordinator.pickerAuthorityRevision.value > authority)
    }
}
