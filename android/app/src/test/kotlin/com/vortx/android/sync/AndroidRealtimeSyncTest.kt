package com.vortx.android.sync

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import androidx.lifecycle.viewModelScope
import com.vortx.android.ui.viewmodel.VortXAccountViewModel
import com.vortx.android.integrations.NativeProviderAccess
import com.vortx.android.integrations.NativeProviderTestStore
import com.vortx.android.profile.UserProfile
import com.vortx.android.sync.VortXSyncManager.SessionUiState
import java.lang.reflect.Proxy
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CancellationException
import com.vortx.android.ui.viewmodel.VortXAccountFormState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.*
import okhttp3.Request
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** Actual manager/channel crypto and scheduling with synthetic local transport/gateway/socket.
 * Does not substitute a second sync algorithm or claim to test the private native join kernel. */
@OptIn(ExperimentalCoroutinesApi::class)
class AndroidRealtimeSyncTest {
    private val key = ByteArray(32) { 17 }
    private val account = VortXSyncManager.Account("00000000-0000-0000-0000-000000000123", "fixture@example.invalid", "Fixture", false)
    private val scopeId = "account.${account.id}"
    private fun native(facts: JSONObject = JSONObject()) = JSONObject().put("schemaVersion", 1)
        .put("scope", scopeId).put("ownerProfileId", UserProfile.OWNER_ID).put("facts", facts)
    private fun document(carrier: JSONObject = native()) = JSONObject().put("foreign", "preserved").put("nativeSync", carrier)

    private inner class Gateway : NativeAccountGateway {
        var carrier = native()
        var applied = 0
        var exports = 0
        var reopens = 0
        var mount = Any()
        var mountRevision = 0L
        var provideMountToken = true
        var afterExport: (() -> Unit)? = null
        var reopenFails = false
        var reopenError: LinkageError? = null
        var applyFails = false
        var ackFails = false
        var exportFails = false
        var host: JSONObject? = null
        var applyGate: CompletableDeferred<Unit>? = null
        var applyEntered: CompletableDeferred<Unit>? = null
        var provideUploadComposer = true
        private var appliedRead: NativeAccountReadCapture? = null
        private var appliedRaw: ByteArray? = null
        override fun retire() {
            appliedRead = null; appliedRaw?.fill(0); appliedRaw = null
            mount = Any()
        }
        override fun captureUploadOrigin(account: SessionOwnerSnapshot.Account, isCurrent: () -> Boolean) =
            object : NativeAccountUploadCurrency.Origin { override fun isCurrent() = isCurrent.invoke() }
        private fun currency(original: NativeAccountUploadCurrency.Origin): NativeAccountUploadCurrency {
            val installation = mount
            // Explicit synthetic installation/health currency; ordinary revisions are permitted.
            return object : NativeAccountUploadCurrency {
                override fun isCurrent() = original.isCurrent() && mount === installation
                override fun <T> withCurrentSession(action: () -> T): T? = if (isCurrent() && !reopenFails) action() else null
            }
        }
        override suspend fun prepareUploadSeed(account: SessionOwnerSnapshot.Account, original: NativeAccountUploadCurrency.Origin,
            isCurrent: () -> Boolean): Pair<JSONObject, NativeAccountUploadCurrency>? {
            val currency = currency(original)
            val prepared = prepareEmptyAccount(account) { isCurrent() && currency.isCurrent() }
            return (prepared to currency).takeIf { isCurrent() && currency.isCurrent() }
        }
        override suspend fun applyUploadSeed(account: SessionOwnerSnapshot.Account, document: JSONObject,
            original: NativeAccountUploadCurrency, isCurrent: () -> Boolean): NativeAccountUploadCurrency? =
            if (original.isCurrent() && applyDocument(account, document) { original.isCurrent() && isCurrent() })
                original.takeIf { isCurrent() && it.isCurrent() } else null
        override fun <T> withUploadExport(account: SessionOwnerSnapshot.Account, source: NativeAccountReadCapture,
            originalRaw: ByteArray, original: NativeAccountUploadCurrency.Origin, isCurrent: () -> Boolean,
            action: (NativeAccountExport, NativeAccountMountToken?, ((JSONObject) -> ByteArray)?, NativeHostUploadAcknowledgment?, NativeAccountUploadCurrency) -> T): T? {
            val currency = currency(original)
            return currency.withCurrentSession {
                if (!isCurrent()) return@withCurrentSession null
                check(account == source.account && appliedRead?.sameObservation(source) == true) {
                    "Original synthetic upload read changed"
                }
                check(appliedRaw?.contentEquals(originalRaw) == true) { "Synthetic upload bytes changed" }
                val exported = exportDocument(account) ?: return@withCurrentSession null
                var active = true
                // This test collaborator has synthetic facts, not a JNI checkpoint. Explicitly issue
                // its synchronous composer after the actual manager GET/apply; do not label a DTO
                // rawAccount or relax the production generic-source conservation guard.
                val compose: ((JSONObject) -> ByteArray)? = if (!provideUploadComposer) null else { providers ->
                    check(active && isCurrent() && currency.isCurrent()) { "Synthetic upload export expired" }
                    val replacements = linkedMapOf("nativeSync" to exported.nativeSync.toString().toByteArray(Charsets.UTF_8))
                    exported.hostPreferences?.let { replacements["nativeHostPreferences"] = it.toString().toByteArray(Charsets.UTF_8) }
                    for (field in listOf("nativeProviderCredentials", "apiKeys")) {
                        providers.optJSONObject(field)?.let { replacements[field] = it.toString().toByteArray(Charsets.UTF_8) }
                    }
                    com.vortx.android.engine.NativeOwnerHistoryAccount(originalRaw)
                        .replacingOwned(replacements).validateBudget(writeV2 = true)
                }
                try { action(exported, currentMountToken(account), compose, null, currency) }
                finally { active = false }
            }
        }
        override fun currentMountToken(account: SessionOwnerSnapshot.Account) =
            if (reopenFails || !provideMountToken) null else NativeAccountMountToken(mount, mountRevision)
        override suspend fun reopenCheckpoint(account: SessionOwnerSnapshot.Account, isCurrent: () -> Boolean): Boolean {
            reopens++; check(isCurrent()); reopenError?.let { throw it }; if (reopenFails) error("checkpoint unavailable"); return true
        }
        override suspend fun applyRawDocument(account: SessionOwnerSnapshot.Account, captured: NativeAccountReadCapture,
            isCurrent: () -> Boolean): Boolean {
            val raw = captured.copyRawForApply(account)
            var retained = false
            try {
                if (!super<NativeAccountGateway>.applyRawDocument(account, captured, isCurrent) || !isCurrent()) return false
                appliedRaw?.fill(0); appliedRaw = raw; appliedRead = captured
                retained = true
                return true
            } finally { if (!retained) raw.fill(0) }
        }
        override suspend fun applyDocument(account: SessionOwnerSnapshot.Account, document: JSONObject, isCurrent: () -> Boolean): Boolean {
            applied++; applyEntered?.complete(Unit); applyGate?.await()
            if (!isCurrent() || applyFails) return false
            document.optJSONObject("nativeSync")?.let { incoming ->
                // Synthetic collaborator retains local facts; tests exercise manager admission/ACK,
                // not the implementation of the native causal join itself.
                val merged = JSONObject(incoming.toString())
                val facts = merged.optJSONObject("facts") ?: JSONObject().also { merged.put("facts", it) }
                carrier.optJSONObject("facts")?.let { local -> local.keys().forEach { facts.put(it, local.get(it)) } }
                carrier = merged
            }
            return true
        }
        override fun exportDocument(account: SessionOwnerSnapshot.Account): NativeAccountExport? {
            exports++
            val result = if (exportFails) null else NativeAccountExport(
            JSONObject(carrier.toString()), listOf(UserProfile(id = UserProfile.OWNER_ID, name = "Fixture", avatar = "star", isOwner = true)),
            0.0, hostPreferences = host)
            afterExport?.invoke()
            return result
        }
        override fun acknowledgeHostPreferences(account: SessionOwnerSnapshot.Account, document: JSONObject): Boolean = !ackFails
        override fun recordGlobalPreferences(account: SessionOwnerSnapshot.Account, changes: JSONObject,
            original: NativeAccountUploadCurrency.Origin): Boolean {
            if (!original.isCurrent()) return false
            val fields = host?.getJSONObject("globals")?.getJSONObject("fields") ?: JSONObject()
            changes.keys().forEach { fields.put(it, JSONObject().put("value", changes.get(it))) }
            host = JSONObject().put("globals", JSONObject().put("fields", fields))
            return true
        }
        override suspend fun prepareEmptyAccount(account: SessionOwnerSnapshot.Account, isCurrent: () -> Boolean) = document()
    }

    private inner class Fixture(
        scheduler: TestCoroutineScheduler,
        val context: MemoryContext = MemoryContext(),
        startupActive: (VortXSyncManager) -> Boolean = { true },
    ) {
        val work = CoroutineScope(SupervisorJob() + StandardTestDispatcher(scheduler))
        val manager = VortXSyncManager(context, work, startupActive)
        val gateway = Gateway()
        val providers = NativeProviderTestStore()
        var cloud = document()
        var version = 10L
        var gets = 0
        var puts = 0
        var putFails = false
        var getFails = false
        var beforePut: (() -> Unit)? = null
        var getGate: CompletableDeferred<Unit>? = null
        val tokens = mutableListOf<String?>()
        val sockets = mutableListOf<Socket>()
        val validators = mutableListOf<String?>()
        var replyTag: String? = null
        var unsolicited304 = false
        var beforeConditionalReply: (() -> Unit)? = null
        val realtime = VortXSyncRealtime(manager, work, "wss://fixture.invalid/v1/sync/connect",
                                         clockMs = { scheduler.currentTime }) { request, listener ->
            Socket(request, listener).also(sockets::add)
        }
        init {
            manager.installSyncTestSeam(VortXSyncManager.Session("fixture-a", account, key), 10, transport = { method, _, body, token ->
                tokens += token
                if (method == "GET") {
                    gets++; getGate?.await()
                    if (getFails) 500 to null else 200 to JSONObject().put("version", version).put("document",
                        VortXCrypto.sealDocument(key, cloud.toString().toByteArray(), account.id, version, true))
                } else {
                    puts++; beforePut?.invoke()
                    if (putFails) 500 to null else {
                        val sent = requireNotNull(body)
                        version = sent.getLong("version")
                        cloud = JSONObject(String(requireNotNull(VortXCrypto.openDocument(key, sent.getString("document"), account.id, version))))
                        200 to JSONObject().put("accepted", true)
                    }
                }
            })
            manager.installSessionRestoreTestSeam(manager.currentSession())
            manager.installNativeGatewayTestSeam(gateway, providers)
            manager.installRealtimeTestSeam(realtime)
            manager.uploadClockMs = { scheduler.currentTime }
        }
        fun edit(name: String) {
            gateway.carrier.getJSONObject("facts").put(name, true)
            manager.onLocalNativeMutation(SessionOwnerSnapshot.Account(account.id, 1))
        }
        fun progress(name: String) {
            gateway.carrier.getJSONObject("facts").put(name, true)
            manager.onLocalNativeMutation(SessionOwnerSnapshot.Account(account.id, 1), progressOnly = true)
        }
        fun enableConditionalTransport() {
            manager.installConditionalTransportTestSeam { method, _, body, token, tag ->
                tokens += token
                if (method == "GET") {
                    gets++; validators += tag
                    beforeConditionalReply?.invoke(); getGate?.await()
                    val currentTag = "\"$version\""
                    if (unsolicited304 || tag == currentTag) {
                        // A poison document proves the accepted bodyless path never attempts decode.
                        Triple(304, JSONObject().put("document", "not-ciphertext"), replyTag ?: currentTag)
                    } else Triple(200, JSONObject().put("version", version).put("document",
                        VortXCrypto.sealDocument(key, cloud.toString().toByteArray(), account.id, version, true)), currentTag)
                } else {
                    puts++
                    val sent = requireNotNull(body)
                    version = sent.getLong("version")
                    cloud = JSONObject(String(requireNotNull(VortXCrypto.openDocument(key, sent.getString("document"), account.id, version))))
                    Triple(200, JSONObject().put("accepted", true), null)
                }
            }
        }
        suspend fun routinePull() = manager.syncDownForRealtime(requireNotNull(manager.captureRealtimeLease()))
        fun dirty() = context.getSharedPreferences("vortx_sync_state", 0).getBoolean("pendingPush.${account.id}", false)
        fun settingsDirty() = JSONObject(context.getSharedPreferences("vortx_sync_dirty", 0)
            .getString("vortx.sync.dirtySettings.${account.id}", "{}")!!)
        fun settingsDirty(stamps: JSONObject) {
            check(context.getSharedPreferences("vortx_sync_dirty", 0).edit()
                .putString("vortx.sync.dirtySettings.${account.id}", stamps.toString()).commit())
        }
        fun unavailableWithoutLiveSession() {
            // Recreate the cold-launch null-session/unavailable state using persistence seams;
            // no device secure store is read or changed by this fixture transition.
            manager.installUnavailableSessionRestoreTestSeam(); manager.sessionOwnerSnapshot()
            manager.installSessionRestoreTestSeam(null); manager.sessionOwnerSnapshot()
            manager.installUnavailableSessionRestoreTestSeam()
            check(manager.sessionOwnerSnapshot() is SessionOwnerSnapshot.UnknownOrUnavailable)
            check(manager.currentSession() == null)
        }
        fun prepareStartup(
            foreground: MutableStateFlow<AccountSyncForeground>,
            confirmedOwner: SessionOwnerSnapshot = manager.sessionOwnerSnapshot(),
        ): () -> Unit = requireNotNull(manager.prepareNativeGateway(gateway, foreground, confirmedOwner))

        fun assertNoStartupDispatch() {
            assertEquals(0, gateway.reopens)
            assertEquals(0, gateway.applied)
            assertEquals(0, gets)
            assertEquals(0, puts)
            assertTrue(tokens.isEmpty())
            assertTrue(sockets.isEmpty())
        }

        suspend fun close() { realtime.stop(); manager.cancelSyncTestWork(); gateway.retire(); NativeProviderAccess.unbindForTest() }
    }

    private fun test(block: suspend TestScope.() -> Unit) = runTest {
        Dispatchers.setMain(UnconfinedTestDispatcher(testScheduler))
        val previousNotifications = NativeSettingsFence.queuedNotificationsForTest
        NativeSettingsFence.queuedNotificationsForTest = mutableListOf()
        try { block() } finally {
            NativeSettingsFence.queuedNotificationsForTest = previousNotifications
            NativeProviderAccess.unbindForTest(); Dispatchers.resetMain()
        }
    }

    private fun drainSettingsNotifications() {
        val notifications = checkNotNull(NativeSettingsFence.queuedNotificationsForTest)
        while (notifications.isNotEmpty()) {
            val batch = notifications.toList()
            notifications.clear()
            batch.forEach { it() }
        }
    }

    @Test fun pickerBackWaitsForUnresolvedManualAuthRequestWithoutDiscardingIt() = test {
        val f = Fixture(testScheduler)
        val model = VortXAccountViewModel(f.manager)
        try {
            val response = CompletableDeferred<Unit>()
            f.manager.installSyncTestSeam(checkNotNull(f.manager.currentSession()), 10, transport = { _, path, _, _ ->
                check(path == "/v1/auth/prelogin"); response.await(); 500 to null
            })
            model.openPickerPresentation()
            model.onLoginChange("fixture@example.invalid"); model.onPasswordChange("fixture password")
            model.submit(); runCurrent()
            assertEquals(VortXAccountFormState.Submitting, model.formState.value)
            assertFalse(model.requestClosePickerPresentation())
            assertTrue(model.pickerPresentationOpen.value)
            response.complete(Unit); runCurrent()
            assertTrue(model.requestClosePickerPresentation())
        } finally { model.viewModelScope.cancel(); f.close() }
    }

    @Test fun oldRegistrationReceiptCannotAttachItsRecoveryCodeToAReplacementSession() = test {
        val f = Fixture(testScheduler)
        val model = VortXAccountViewModel(f.manager)
        try {
            val original = f.manager.capturePickerCompletionOwner()
            val replacement = VortXSyncManager.Session("replacement", account, key)
            f.manager.replaceSyncSessionTestSeam(replacement)
            model.completeRegistration(VortXSyncManager.RegisterResult(VortXSyncManager.AuthResult.Ok, "old fixture code"), original, original)
            assertNull(model.recoveryCode.value); assertFalse(model.showReconcile.value)
            assertSame(replacement, f.manager.currentSession())
        } finally { model.viewModelScope.cancel(); f.close() }
    }

    @Test fun registrationBackBeforeRecoveryAcknowledgementKeepsOriginalCodeAndReconcile() = test {
        val f = Fixture(testScheduler)
        val model = VortXAccountViewModel(f.manager)
        try {
            f.cloud.put("vortx", JSONObject()) // Actual post-auth probe returns the pending account-data choice.
            model.openPickerPresentation()
            model.completeRegistration(VortXSyncManager.RegisterResult(VortXSyncManager.AuthResult.Ok, "fixture recovery code"),
                f.manager.capturePickerCompletionOwner(), f.manager.capturePickerCompletionOwner())
            assertEquals("fixture recovery code", model.recoveryCode.value)
            assertTrue(model.showReconcile.value)
            assertFalse(model.requestClosePickerPresentation())
            assertTrue(model.pickerPresentationOpen.value)
            assertEquals("fixture recovery code", model.recoveryCode.value)
            model.dismissRecoveryCode("fixture recovery code")
            assertNull(model.recoveryCode.value)
            assertFalse(model.requestClosePickerPresentation()) // The separate unresolved reconcile still blocks.
            model.reconcileUseAccount(); runCurrent()
            assertFalse(model.showReconcile.value)
            assertTrue(model.requestClosePickerPresentation())
        } finally { model.viewModelScope.cancel(); f.close() }
    }

    @Test fun signInBackBeforeAccountChoiceKeepsPendingChoiceAndReplacementClearsIt() = test {
        val f = Fixture(testScheduler)
        val model = VortXAccountViewModel(f.manager)
        try {
            model.openPickerPresentation()
            model.finishPostAuth { model.requireAccountReconcile() }
            assertFalse(model.requestClosePickerPresentation())
            assertTrue(model.showReconcile.value)
            f.manager.replaceSyncSessionTestSeam(VortXSyncManager.Session("fixture replacement", account, key))
            runCurrent()
            assertFalse(model.showReconcile.value); assertNull(model.recoveryCode.value)
            assertFalse(model.pickerPresentationOpen.value)
            model.openPickerPresentation()
            assertFalse(model.hasPendingPickerCompletion())
        } finally { model.viewModelScope.cancel(); f.close() }
    }

    @Test fun failedSecureClearRetainsUnacknowledgedRecoveryAndResumesItsPresentation() = test {
        val f = Fixture(testScheduler)
        val model = VortXAccountViewModel(f.manager)
        try {
            f.cloud.put("vortx", JSONObject())
            model.openPickerPresentation()
            model.completeRegistration(VortXSyncManager.RegisterResult(VortXSyncManager.AuthResult.Ok, "fixture recovery code"),
                f.manager.capturePickerCompletionOwner(), f.manager.capturePickerCompletionOwner())
            val saved = f.manager.currentSession()
            f.manager.installSessionClearTestSeam { false }
            val captured = checkNotNull(f.manager.capturePickerAccountSnapshot())
            val result = model.signOut(captured) { model.retirePickerPresentationForSignOut() }
            model.resumePickerCompletionIfCurrent(); runCurrent()
            assertEquals(PickerSignOutResult.STORAGE_UNAVAILABLE, result)
            assertSame(saved, f.manager.currentSession())
            assertEquals("fixture recovery code", model.recoveryCode.value)
            assertTrue(model.showReconcile.value); assertTrue(model.pickerPresentationOpen.value)
            f.manager.replaceSyncSessionTestSeam(VortXSyncManager.Session("different", account.copy(id = "00000000-0000-0000-0000-000000000999"), key))
            runCurrent()
            assertNull(model.recoveryCode.value); assertFalse(model.showReconcile.value)
        } finally { model.viewModelScope.cancel(); f.close() }
    }

    @Test fun pickerSignOutRechecksActualManagerAfterUiRetirementChangesItsAccount() = test {
        val f = Fixture(testScheduler)
        val model = VortXAccountViewModel(f.manager)
        try {
            val original = checkNotNull(f.manager.capturePickerAccountSnapshot())
            val replacement = VortXSyncManager.Session("fixture-replacement", account, key)
            var retired = false
            val result = model.signOut(original) {
                retired = true
                f.manager.replaceSyncSessionTestSeam(replacement)
            }
            assertTrue(retired)
            assertEquals(PickerSignOutResult.STALE, result)
            assertSame(replacement, f.manager.currentSession())
        } finally { model.viewModelScope.cancel(); f.close() }
    }

    @Test fun pickerSignOutCaptureRejectsSameAccountReplacementAndExpiredOperation() = test {
        val f = Fixture(testScheduler)
        try {
            val first = checkNotNull(f.manager.capturePickerAccountSnapshot())
            assertTrue(f.manager.isPickerAccountCurrent(first))
            val replacement = VortXSyncManager.Session("fixture-replacement", account, key)
            f.manager.replaceSyncSessionTestSeam(replacement)
            assertFalse(f.manager.isPickerAccountCurrent(first))
            assertEquals(PickerSignOutResult.STALE, f.manager.signOut(first))
            assertSame(replacement, f.manager.currentSession())
            val second = checkNotNull(f.manager.capturePickerAccountSnapshot())
            f.manager.expireSyncOperationTestSeam()
            assertFalse(f.manager.isPickerAccountCurrent(second))
            assertEquals(PickerSignOutResult.STALE, f.manager.signOut(second))
            assertSame(replacement, f.manager.currentSession())
            assertEquals("PickerAccountSnapshot", first.toString())
        } finally { f.close() }
    }

    @Test fun fullEncryptedAccountDownloadWorksWithoutProfileOrNativeMountAndNeverDecryptsOrAcknowledges() = test {
        val context = MemoryContext()
        val work = CoroutineScope(SupervisorJob() + StandardTestDispatcher(testScheduler))
        val manager = VortXSyncManager(context, work)
        val original = VortXSyncManager.Session("fixture original", account, key)
        try {
            var ordinaryRequests = 0; var downloads = 0
            manager.installSyncTestSeam(original, 99, transport = { _, _, _, _ -> ordinaryRequests++; 500 to null })
            manager.installSessionRestoreTestSeam(original)
            // Valid framing but deliberately not decryptable under key: export must retain opaque ciphertext.
            val ciphertext = "v2." + com.vortx.android.engine.OHJson.b64(ByteArray(28))
            val raw = """{"document":"$ciphertext","version":42,"username":"untrusted response metadata","future":{"precise":9007199254740991.1}}""".toByteArray()
            manager.installAccountFileTransportTestSeam { method, path, token ->
                downloads++; assertEquals("GET", method); assertEquals("/v1/backup", path)
                assertEquals(original.token, token); 200 to raw
            }
            val names = listOf("vortx_settings", "vortx_sync_state", "vortx_sync_dirty")
            val before = names.associateWith { context.getSharedPreferences(it, 0).all.toMap() }
            val file = manager.downloadAccountBackupFile()
            val wrapper = com.vortx.android.engine.OHJson.Obj(file)
            assertEquals(account.username, wrapper.text("username"))
            assertEquals(ciphertext, wrapper.text("document")); assertEquals(42L, com.vortx.android.engine.OHJson.integer(wrapper.raw("version")))
            assertEquals(1, downloads); assertEquals(0, ordinaryRequests)
            assertEquals(99L, manager.lastAppliedVersion()) // Downloading a lower cloud revision changes no floor.
            assertSame(original, manager.currentSession())
            names.forEach { assertEquals(before[it], context.getSharedPreferences(it, 0).all) }
        } finally { manager.cancelSyncTestWork() }
    }

    @Test fun fullEncryptedAccountDownloadRefusesSameValueSessionReplacementAndExpiredOriginalOperation() = test {
        for (replace in listOf(true, false)) {
            val context = MemoryContext()
            val work = CoroutineScope(SupervisorJob() + StandardTestDispatcher(testScheduler))
            val manager = VortXSyncManager(context, work)
            val original = VortXSyncManager.Session("fixture original", account, key)
            try {
                manager.installSyncTestSeam(original, 10, transport = { _, _, _, _ -> error("Unexpected ordinary request") })
                manager.installSessionRestoreTestSeam(original)
                val entered = CompletableDeferred<Unit>(); val reply = CompletableDeferred<Unit>()
                manager.installAccountFileTransportTestSeam { _, _, _ ->
                    entered.complete(Unit); reply.await()
                    200 to """{"document":"v2.${com.vortx.android.engine.OHJson.b64(ByteArray(28))}","version":10}""".toByteArray()
                }
                val pending = async { runCatching { manager.downloadAccountBackupFile() } }
                runCurrent(); entered.await()
                if (replace) manager.replaceSyncSessionTestSeam(VortXSyncManager.Session(original.token, account, key.copyOf()))
                else manager.expireSyncOperationTestSeam()
                reply.complete(Unit); runCurrent()
                val error = pending.await().exceptionOrNull()
                assertTrue(error is AccountBackupFile.Failure)
                assertEquals(AccountBackupFile.Reason.SESSION_CHANGED, (error as AccountBackupFile.Failure).reason)
            } finally { manager.cancelSyncTestWork() }
        }
    }

    @Test fun fullEncryptedAccountDownloadKeepsMissingTransportMalformedAndOversizedFailuresDistinct() = test {
        val context = MemoryContext()
        val work = CoroutineScope(SupervisorJob() + StandardTestDispatcher(testScheduler))
        val manager = VortXSyncManager(context, work)
        val original = VortXSyncManager.Session("fixture original", account, key)
        try {
            manager.installSyncTestSeam(original, 10, transport = { _, _, _, _ -> error("Unexpected ordinary request") })
            manager.installSessionRestoreTestSeam(original)
            var status = 404; var raw: ByteArray? = null
            manager.installAccountFileTransportTestSeam { _, _, _ -> status to raw }
            suspend fun refused(reason: AccountBackupFile.Reason) {
                val error = runCatching { manager.downloadAccountBackupFile() }.exceptionOrNull()
                assertTrue(error is AccountBackupFile.Failure)
                assertEquals(reason, (error as AccountBackupFile.Failure).reason)
                assertSame(original, manager.currentSession()); assertEquals(10L, manager.lastAppliedVersion())
            }
            refused(AccountBackupFile.Reason.NO_BACKUP)
            for (failure in listOf(0, 304, 401, 403, 500)) { status = failure; refused(AccountBackupFile.Reason.UNAVAILABLE) }
            status = 200; refused(AccountBackupFile.Reason.DAMAGED)
            raw = """{"document":"v2.${com.vortx.android.engine.OHJson.b64(ByteArray(28))}","version":9007199254740991.1}""".toByteArray()
            refused(AccountBackupFile.Reason.DAMAGED)
            raw = ByteArray(AccountBackupFile.MAXIMUM_RESPONSE_BYTES + 1) { 32 }
            refused(AccountBackupFile.Reason.TOO_LARGE)
        } finally { manager.cancelSyncTestWork() }
    }

    @Test fun fullEncryptedAccountDownloadDoesNotTreatUnavailableSessionAsSignedOutOrContactTransport() = test {
        val context = MemoryContext()
        val work = CoroutineScope(SupervisorJob() + StandardTestDispatcher(testScheduler))
        val manager = VortXSyncManager(context, work)
        val original = VortXSyncManager.Session("fixture original", account, key)
        try {
            manager.installSyncTestSeam(original, 10, transport = { _, _, _, _ -> error("Unexpected ordinary request") })
            manager.installUnavailableSessionRestoreTestSeam()
            var calls = 0
            manager.installAccountFileTransportTestSeam { _, _, _ -> calls++; 404 to null }
            val error = runCatching { manager.downloadAccountBackupFile() }.exceptionOrNull()
            assertTrue(error is AccountBackupFile.Failure)
            assertEquals(AccountBackupFile.Reason.SESSION_CHANGED, (error as AccountBackupFile.Failure).reason)
            assertEquals(0, calls); assertSame(original, manager.currentSession())
            assertEquals(VortXSyncManager.SessionUiState.UnknownOrUnavailable, manager.sessionUiState.value)
        } finally { manager.cancelSyncTestWork() }
    }

    @Test fun synchronousSocketStartupFailureRetainsSessionWorkerPollingAndRetry() = test {
        val f = Fixture(testScheduler)
        var attempts = 0
        val channel = VortXSyncRealtime(f.manager, f.work, "wss://fixture.invalid/v1/sync/connect",
            clockMs = { testScheduler.currentTime }) { _, _ ->
            attempts++
            throw IllegalStateException("https://fixture.invalid/private?token=fixture-private")
        }
        try {
            val saved = f.manager.currentSession()
            f.context.getSharedPreferences("fixture-retained", 0).edit().putString("saved", "keep").commit()
            f.manager.installRealtimeTestSeam(channel)
            f.manager.setRealtimeForeground(true); runCurrent()
            assertTrue(channel.isActive()); assertEquals(1, attempts); assertEquals(1, f.gets)
            assertSame(saved, f.manager.currentSession()); assertEquals(account, f.manager.account.value)
            advanceTimeBy(3_001); runCurrent()
            assertTrue(attempts >= 2)
            val afterRetries = f.gets
            advanceTimeBy(3_001); runCurrent() // Poll at 6 s; next socket retry is at 7 s.
            assertTrue(f.gets > afterRetries)
            assertEquals("keep", f.context.getSharedPreferences("fixture-retained", 0).getString("saved", null))
            f.manager.setRealtimeForeground(false)
            val stoppedGets = f.gets
            advanceTimeBy(30_000); runCurrent()
            assertFalse(channel.isActive()); assertEquals(stoppedGets, f.gets)
            assertSame(saved, f.manager.currentSession())
        } finally { channel.stop(); f.close() }
    }

    @Test fun synchronousSocketFailureCanReconnectUsingCapturedSession() = test {
        val f = Fixture(testScheduler)
        var attempts = 0
        val channel = VortXSyncRealtime(f.manager, f.work, "wss://fixture.invalid/v1/sync/connect",
            clockMs = { testScheduler.currentTime }) { request, listener ->
            if (++attempts == 1) throw IllegalStateException("fixture startup")
            Socket(request, listener).also(f.sockets::add)
        }
        try {
            f.manager.installRealtimeTestSeam(channel)
            f.manager.setRealtimeForeground(true); runCurrent()
            assertTrue(f.sockets.isEmpty())
            advanceTimeBy(1_001); runCurrent()
            assertEquals(2, attempts); assertEquals(1, f.sockets.size)
            assertEquals("Bearer fixture-a", f.sockets.single().request().header("authorization"))
            assertEquals(account, f.manager.account.value)
        } finally { channel.stop(); f.close() }
    }

    @Test fun realtimeStartupCancellationPropagatesAndDiscardsPartialChannel() = test {
        val f = Fixture(testScheduler)
        val cancelled = CancellationException("fixture cancellation")
        val channel = VortXSyncRealtime(f.manager, f.work, "wss://fixture.invalid/v1/sync/connect") { _, _ -> throw cancelled }
        try {
            f.manager.installRealtimeTestSeam(channel)
            try {
                f.manager.setRealtimeForeground(true)
                fail("Cancellation was converted to a startup success")
            } catch (actual: CancellationException) { assertSame(cancelled, actual) }
            runCurrent()
            assertFalse(channel.isActive()); assertEquals(0, f.gets); assertEquals(account, f.manager.account.value)
        } finally { channel.stop(); f.close() }
    }

    @Test fun realtimeStartupDoesNotSwallowFatalErrors() = test {
        val f = Fixture(testScheduler)
        val fatal = AssertionError("fixture fatal")
        val channel = VortXSyncRealtime(f.manager, f.work, "wss://fixture.invalid/v1/sync/connect") { _, _ -> throw fatal }
        try {
            f.manager.installRealtimeTestSeam(channel)
            try {
                f.manager.setRealtimeForeground(true)
                fail("Fatal error was converted to a startup success")
            } catch (actual: AssertionError) { assertSame(fatal, actual) }
            assertEquals(account, f.manager.account.value)
        } finally { channel.stop(); f.close() }
    }

    @Test fun submitPreloginExceptionKeepsSavedSessionAndClearsOnlyOriginalSecrets() = test {
        val f = Fixture(testScheduler)
        val saved = requireNotNull(f.manager.currentSession())
        var requests = 0
        f.manager.installSyncTestSeam(saved, 10, transport = { method, path, body, token ->
            requests++
            assertEquals("POST", method); assertEquals("/v1/auth/prelogin", path)
            assertEquals("fixture-login", body?.getString("login")); assertNull(token)
            throw IllegalStateException("https://fixture.invalid/private?token=fixture-private")
        })
        f.manager.installSessionRestoreTestSeam(saved)
        val model = VortXAccountViewModel(f.manager)
        try {
            f.context.getSharedPreferences("fixture-retained", 0).edit().putString("saved", "keep").commit()
            f.gateway.carrier.getJSONObject("facts").put("saved-library", true)
            val retainedFacts = f.gateway.carrier.toString()
            val retainedState = f.context.getSharedPreferences("vortx_sync_state", 0).all.toMap()
            model.onLoginChange("fixture-login"); model.onPasswordChange("fixture password")
            model.onTotpChange("123456"); model.onRecoveryInputChange("fixture recovery")
            model.submit(); runCurrent()
            assertEquals(1, requests)
            assertEquals(VortXAccountFormState.Error(
                "Could not complete this account action. Your saved data is preserved. Please try again.",
            ), model.formState.value)
            assertEquals("", model.password.value); assertEquals("", model.totp.value)
            assertEquals("", model.recoveryInput.value); assertFalse(model.totpRequired.value)
            assertFalse(model.syncing.value); assertFalse(f.realtime.isActive())
            assertSame(saved, f.manager.currentSession()); assertEquals(account, model.account.value)
            assertEquals(retainedFacts, f.gateway.carrier.toString())
            assertEquals(retainedState, f.context.getSharedPreferences("vortx_sync_state", 0).all)
            assertEquals("keep", f.context.getSharedPreferences("fixture-retained", 0).getString("saved", null))
            assertEquals(0, f.gateway.applied); assertEquals(0, f.gateway.exports)
        } finally { model.viewModelScope.cancel(); f.close() }
    }

    @Test fun deferredSubmitExceptionRetainsEditedFieldsAndCannotStartParallelAuth() = test {
        val f = Fixture(testScheduler)
        val saved = requireNotNull(f.manager.currentSession())
        val release = CompletableDeferred<Unit>()
        var requests = 0
        f.manager.installSyncTestSeam(saved, 10, transport = { _, path, _, _ ->
            requests++; assertEquals("/v1/auth/prelogin", path)
            release.await()
            throw IllegalStateException("fixture stale auth failure")
        })
        f.manager.installSessionRestoreTestSeam(saved)
        val model = VortXAccountViewModel(f.manager)
        try {
            model.onLoginChange("original-login"); model.onPasswordChange("original password")
            model.submit(); runCurrent()
            assertEquals(1, requests); assertEquals(VortXAccountFormState.Submitting, model.formState.value)
            model.onLoginChange("edited-login"); model.onPasswordChange("edited password")
            model.onTotpChange("654321"); model.onRecoveryInputChange("edited recovery")
            model.submit(); runCurrent()
            assertEquals(1, requests) // An edit revokes cleanup, not the one-flight request guard.
            release.complete(Unit); runCurrent()
            assertEquals(VortXAccountFormState.Idle, model.formState.value)
            assertEquals("edited-login", model.login.value); assertEquals("edited password", model.password.value)
            assertEquals("654321", model.totp.value); assertEquals("edited recovery", model.recoveryInput.value)
            assertFalse(model.syncing.value); assertSame(saved, f.manager.currentSession())
            assertEquals(account, model.account.value); assertEquals(0, f.gateway.applied)
            assertEquals(0, f.gateway.exports); assertFalse(f.realtime.isActive())
        } finally { model.viewModelScope.cancel(); f.close() }
    }

    @Test fun submitCancellationRetainsExactCauseAndSavedSessionWithoutRetryError() = test {
        val f = Fixture(testScheduler)
        val saved = requireNotNull(f.manager.currentSession())
        val release = CompletableDeferred<Unit>()
        val cancelled = CancellationException("fixture auth cancellation")
        var requests = 0
        f.manager.installSyncTestSeam(saved, 10, transport = { _, path, _, _ ->
            requests++; assertEquals("/v1/auth/prelogin", path)
            release.await()
            throw cancelled
        })
        f.manager.installSessionRestoreTestSeam(saved)
        val model = VortXAccountViewModel(f.manager)
        try {
            model.onLoginChange("fixture-login"); model.onPasswordChange("fixture password")
            model.onTotpChange("123456"); model.onRecoveryInputChange("fixture recovery")
            val owner = requireNotNull(model.viewModelScope.coroutineContext[kotlinx.coroutines.Job])
            val before = owner.children.toSet()
            model.submit(); runCurrent()
            val submission = owner.children.single { it !in before }
            var completion: Throwable? = null
            submission.invokeOnCompletion { completion = it }
            assertEquals(1, requests); assertEquals(VortXAccountFormState.Submitting, model.formState.value)
            release.complete(Unit); runCurrent()
            assertTrue(submission.isCancelled); assertSame(cancelled, completion)
            assertEquals(VortXAccountFormState.Idle, model.formState.value)
            assertEquals("", model.password.value); assertEquals("", model.totp.value)
            assertEquals("", model.recoveryInput.value); assertFalse(model.syncing.value)
            assertSame(saved, f.manager.currentSession()); assertEquals(account, model.account.value)
            assertNull(model.syncNotice.value); assertFalse(f.realtime.isActive())
            assertEquals(0, f.gateway.applied); assertEquals(0, f.gateway.exports)
        } finally { model.viewModelScope.cancel(); f.close() }
    }

    @Test fun postAuthRestoreExceptionKeepsSavedSessionClearsSecretsAndUsesFixedNotice() = test {
        val f = Fixture(testScheduler)
        val model = VortXAccountViewModel(f.manager)
        try {
            val saved = f.manager.currentSession()
            model.onPasswordChange("fixture password"); model.onTotpChange("123456")
            model.onRecoveryInputChange("fixture recovery")
            model.finishPostAuth {
                assertEquals("", model.password.value); assertEquals("", model.totp.value)
                assertEquals("", model.recoveryInput.value)
                throw IllegalStateException("https://fixture.invalid/private?token=fixture-private")
            }
            assertSame(saved, f.manager.currentSession()); assertEquals(account, model.account.value)
            assertEquals(VortXAccountFormState.Idle, model.formState.value)
            assertFalse(model.syncing.value); assertFalse(f.realtime.isActive())
            assertEquals("Signed in. Sync could not finish. Your saved data is preserved. Try Sync now again.", model.syncNotice.value)
            assertFalse(model.syncNotice.value!!.contains("fixture-private"))
        } finally { model.viewModelScope.cancel(); f.close() }
    }

    @Test fun failedPostAuthCompletionCannotPublishIntoReplacementSession() = test {
        val f = Fixture(testScheduler)
        val model = VortXAccountViewModel(f.manager)
        try {
            val replacement = account.copy(id = "00000000-0000-0000-0000-000000000999")
            model.finishPostAuth {
                f.manager.replaceSyncSessionTestSeam(VortXSyncManager.Session("fixture-b", replacement, key))
                throw IllegalStateException("fixture superseded restore")
            }
            assertEquals(replacement, model.account.value)
            assertNull(model.syncNotice.value)
        } finally { model.viewModelScope.cancel(); f.close() }
    }

    @Test fun postAuthCancellationAndFatalErrorsRetainOriginalIdentity() = test {
        val f = Fixture(testScheduler)
        val model = VortXAccountViewModel(f.manager)
        try {
            val cancelled = CancellationException("fixture cancellation")
            try {
                model.finishPostAuth { throw cancelled }
                fail("Post-auth cancellation was swallowed")
            } catch (actual: CancellationException) { assertSame(cancelled, actual) }
            val fatal = AssertionError("fixture fatal")
            try {
                model.finishPostAuth { throw fatal }
                fail("Post-auth fatal error was swallowed")
            } catch (actual: AssertionError) { assertSame(fatal, actual) }
            assertEquals(account, model.account.value)
        } finally { model.viewModelScope.cancel(); f.close() }
    }

    @Test fun cancellingManualSyncClearsBusyStateWithoutDiscardingSession() = test {
        val f = Fixture(testScheduler)
        val model = VortXAccountViewModel(f.manager)
        try {
            val saved = f.manager.currentSession()
            f.getGate = CompletableDeferred()
            model.syncNow(); runCurrent()
            assertTrue(model.syncing.value); assertEquals(1, f.gets)
            model.viewModelScope.cancel(); runCurrent()
            assertFalse(model.syncing.value); assertSame(saved, f.manager.currentSession())
            assertEquals(0, f.puts)
        } finally { model.viewModelScope.cancel(); f.close() }
    }

    @Test fun `conditional idle poll skips export reopen decode and apply but newer document applies`() = test {
        val f = Fixture(testScheduler)
        try {
            f.enableConditionalTransport()
            assertTrue(f.routinePull()) // persisted integer alone must still apply this mount once
            assertNull(f.validators.single())
            assertEquals(1, f.gateway.applied)
            val exports = f.gateway.exports; val reopens = f.gateway.reopens
            assertTrue(f.routinePull())
            assertEquals("\"10\"", f.validators.last())
            assertEquals(1, f.gateway.applied); assertEquals(exports, f.gateway.exports); assertEquals(reopens, f.gateway.reopens)
            f.version = 11; f.cloud = document(native(JSONObject().put("peer-edit", true)))
            assertTrue(f.routinePull())
            assertEquals(2, f.gateway.applied); assertEquals(11L, f.manager.lastAppliedVersion())
            assertTrue(f.gateway.carrier.getJSONObject("facts").getBoolean("peer-edit"))
            assertTrue(f.routinePull()); assertEquals("\"11\"", f.validators.last())
            assertEquals(2, f.gateway.applied)
        } finally { f.close() }
    }

    @Test fun `conditional response requires exact strong tag and completed current mount receipt`() = test {
        val f = Fixture(testScheduler)
        try {
            f.enableConditionalTransport()
            f.unsolicited304 = true
            assertFalse(f.routinePull()); assertNull(f.validators.last()); assertEquals(0, f.gateway.applied)
            f.unsolicited304 = false
            assertTrue(f.routinePull())
            for (bad in listOf("W/\"10\"", "\"11\"", "*", "10", "")) {
                f.replyTag = bad
                assertFalse(f.routinePull()); assertEquals("\"10\"", f.validators.last())
                f.replyTag = null
                assertTrue(f.routinePull()); assertNull(f.validators.last())
            }
            assertTrue(f.manager.syncDown(force = true)); assertNull(f.validators.last())
            f.gateway.mount = Any()
            assertTrue(f.routinePull()); assertNull(f.validators.last())
            f.gateway.mountRevision++
            assertTrue(f.routinePull()); assertNull(f.validators.last())
        } finally { f.close() }
    }

    @Test fun `failed apply and pending local edit cannot obtain or consume conditional receipt`() = test {
        val f = Fixture(testScheduler)
        try {
            f.enableConditionalTransport(); f.gateway.applyFails = true
            assertFalse(f.routinePull()); assertNull(f.validators.last())
            f.gateway.applyFails = false
            assertTrue(f.routinePull()); assertNull(f.validators.last())
            f.beforeConditionalReply = { f.beforeConditionalReply = null; f.edit("arrived-during-get") }
            assertFalse(f.routinePull()); assertTrue(f.dirty()); assertEquals(10L, f.manager.lastAppliedVersion())
            assertEquals(0, f.puts)
        } finally { f.close() }
    }

    @Test fun `delayed conditional response cannot survive account ABA or mount replacement`() = test {
        val f = Fixture(testScheduler)
        try {
            f.enableConditionalTransport(); assertTrue(f.routinePull())
            f.beforeConditionalReply = { f.beforeConditionalReply = null; f.gateway.mount = Any() }
            assertFalse(f.routinePull())
            assertTrue(f.routinePull()); assertNull(f.validators.last())
            f.beforeConditionalReply = {
                f.beforeConditionalReply = null
                f.manager.installSyncTestSeam(VortXSyncManager.Session("fixture-b", account, ByteArray(32) { 18 }), 10, { _, _, _, _ -> 500 to null })
                f.manager.installSyncTestSeam(VortXSyncManager.Session("fixture-a", account, key), 10, { _, _, _, _ -> 500 to null })
            }
            assertFalse(f.routinePull()); assertEquals(10L, f.manager.lastAppliedVersion())
            assertTrue(f.routinePull()); assertNull(f.validators.last())
        } finally { f.close() }
    }

    @Test fun `export publication generation race cannot mint conditional receipt and absent mount token stays full`() = test {
        val f = Fixture(testScheduler)
        try {
            f.enableConditionalTransport()
            f.gateway.afterExport = {
                if (f.gateway.applied > 0) { f.gateway.afterExport = null; f.gateway.mountRevision++ }
            }
            assertFalse(f.routinePull()); assertEquals(10L, f.manager.lastAppliedVersion())
            assertTrue(f.routinePull()); assertNull(f.validators.last())
            f.gateway.provideMountToken = false
            assertTrue(f.routinePull()); assertNull(f.validators.last())
            assertTrue(f.routinePull()); assertNull(f.validators.last())
        } finally { f.close() }
    }

    @Test fun `generic fixture without issued composer cannot PUT or acknowledge pending edits`() = test {
        val f = Fixture(testScheduler)
        try {
            f.gateway.provideUploadComposer = false
            f.settingsDirty(JSONObject().put("vortx.player.matchFrameRate", 120.0))
            val retainedCloud = f.cloud.toString()
            f.edit("retained-local")
            runCurrent(); advanceTimeBy(2_501); runCurrent()
            assertTrue(f.gateway.exports > 0)
            assertEquals(0, f.puts); assertTrue(f.dirty()); assertEquals(10L, f.manager.lastAppliedVersion())
            assertEquals(120.0, f.settingsDirty().getDouble("vortx.player.matchFrameRate"), 0.0)
            assertEquals(retainedCloud, f.cloud.toString())
            assertTrue(f.gateway.carrier.getJSONObject("facts").getBoolean("retained-local"))
        } finally { f.close() }
    }

    @Test fun `synthetic upload composer requires the exact applied observation bytes and scope`() = test {
        val gateway = Gateway()
        val principal = SessionOwnerSnapshot.Account(account.id, 1)
        val raw = document().toString().toByteArray(Charsets.UTF_8)
        fun read() = NativeAccountReadCapture.fromAuthenticatedPull(principal, 1, account.id, 1, 10, raw)
        val first = read(); val other = read()
        val original = gateway.captureUploadOrigin(principal) { true }
        var escaped: ((JSONObject) -> ByteArray)? = null
        try {
            assertTrue(gateway.applyRawDocument(principal, first) { true })
            assertTrue(runCatching { gateway.withUploadExport(principal, other, raw, original, { true }) {
                _, _, _, _, _ -> fail("Unapplied observation admitted")
            } }.exceptionOrNull() is IllegalStateException)
            assertTrue(runCatching { gateway.withUploadExport(principal, first, raw + byteArrayOf(32), original, { true }) {
                _, _, _, _, _ -> fail("Different source bytes admitted")
            } }.exceptionOrNull() is IllegalStateException)
            gateway.withUploadExport(principal, first, raw, original, { true }) { _, _, compose, _, _ ->
                val composer = requireNotNull(compose)
                escaped = composer
                val candidate = composer(JSONObject())
                try { assertEquals("preserved", JSONObject(String(candidate, Charsets.UTF_8)).getString("foreign")) }
                finally { candidate.fill(0) }
            }
            assertTrue(runCatching { requireNotNull(escaped)(JSONObject()) }.exceptionOrNull() is IllegalStateException)
        } finally { first.retire(); other.retire(); gateway.retire(); raw.fill(0) }
    }

    @Test fun `continuous progress does not postpone upload and PUT edit survives exact ACK`() = test {
        val f = Fixture(testScheduler)
        try {
            f.edit("first"); runCurrent()
            advanceTimeBy(1_000); f.edit("second"); runCurrent()
            advanceTimeBy(1_000); f.edit("third"); runCurrent()
            f.beforePut = { f.beforePut = null; f.edit("during-put") }
            advanceTimeBy(501); runCurrent()
            assertEquals(1, f.puts)
            assertFalse(f.cloud.getJSONObject("nativeSync").getJSONObject("facts").has("during-put"))
            assertTrue(f.dirty())
            advanceTimeBy(2_500); runCurrent()
            assertEquals(2, f.puts)
            assertTrue(f.cloud.getJSONObject("nativeSync").getJSONObject("facts").getBoolean("during-put"))
            assertFalse(f.dirty())
            assertEquals("preserved", f.cloud.getString("foreign"))
        } finally { f.close() }
    }

    @Test fun `playback progress uploads once playback goes quiet, not every few seconds`() = test {
        val f = Fixture(testScheduler)
        try {
            for (tick in 0 until 6) { f.progress("tick-$tick"); runCurrent(); advanceTimeBy(5_000) }
            assertEquals(0, f.puts) // thirty seconds of playback, no upload yet
            assertTrue(f.dirty())   // the pending intent is durable all the while
            advanceTimeBy(9_000); runCurrent()
            assertEquals(0, f.puts)
            advanceTimeBy(1_100); runCurrent() // fifteen quiet seconds after the last report
            assertEquals(1, f.puts)
            assertTrue(f.cloud.getJSONObject("nativeSync").getJSONObject("facts").getBoolean("tick-5"))
            assertFalse(f.dirty())
        } finally { f.close() }
    }

    @Test fun `continuous playback still uploads within a minute`() = test {
        val f = Fixture(testScheduler)
        try {
            var tick = 0
            while (testScheduler.currentTime < 59_000) { f.progress("tick-${tick++}"); runCurrent(); advanceTimeBy(5_000) }
            runCurrent(); advanceTimeBy(1_200); runCurrent()
            assertEquals(1, f.puts)
        } finally { f.close() }
    }

    @Test fun `a real edit during playback is not held behind the progress window`() = test {
        val f = Fixture(testScheduler)
        try {
            f.progress("tick"); runCurrent(); advanceTimeBy(5_000)
            f.edit("renamed-profile"); runCurrent()
            advanceTimeBy(2_501); runCurrent()
            assertEquals(1, f.puts)
            assertTrue(f.cloud.getJSONObject("nativeSync").getJSONObject("facts").getBoolean("renamed-profile"))
            assertFalse(f.dirty())
        } finally { f.close() }
    }

    @Test fun `failed upload retains durable pending intent and cold restart retries`() = test {
        val context = MemoryContext()
        val first = Fixture(testScheduler, context)
        first.putFails = true; first.edit("persisted")
        runCurrent(); advanceTimeBy(2_501); runCurrent()
        assertEquals(1, first.puts); assertTrue(first.dirty()); first.close()
        val second = Fixture(testScheduler, context)
        try {
            second.gateway.carrier = native(JSONObject().put("persisted", true))
            assertFalse(second.manager.syncDown()) // restored dirty marker defers pull
            runCurrent(); advanceTimeBy(2_501); runCurrent()
            assertEquals(1, second.puts); assertFalse(second.dirty())
            assertTrue(second.cloud.getJSONObject("nativeSync").getJSONObject("facts").getBoolean("persisted"))
        } finally { second.close() }
    }

    @Test fun `retained unsupported settings cannot starve native worker after restart or subsequent receiving`() = test {
        val context = MemoryContext()
        val retained = JSONObject().put("stremiox.theme.oled", 123.25).put("stremiox.audioLang", 124.5)
            .put("stremiox.autoSkipDelaySeconds", 125.75)
        // A known key with an unsupported stored type is not an intentional deletion.
        context.getSharedPreferences("vortx_settings", 0).edit().putString("stremiox.autoSkipDelaySeconds", "invalid").commit()
        val first = Fixture(testScheduler, context)
        try {
            first.settingsDirty(retained); first.putFails = true; first.edit("library-edit")
            runCurrent(); advanceTimeBy(2_501); runCurrent()
            assertEquals(1, first.puts); assertTrue(first.dirty())
            assertEquals("invalid", context.getSharedPreferences("vortx_settings", 0).getString("stremiox.autoSkipDelaySeconds", null))
            assertEquals(retained.toString(), first.settingsDirty().toString())
        } finally { first.close() }
        val second = Fixture(testScheduler, context)
        try {
            second.gateway.carrier = native(JSONObject().put("library-edit", true))
            second.manager.setRealtimeForeground(true); runCurrent()
            advanceTimeBy(2_501); runCurrent()
            assertEquals(1, second.puts); assertFalse(second.dirty())
            assertEquals("invalid", context.getSharedPreferences("vortx_settings", 0).getString("stremiox.autoSkipDelaySeconds", null))
            assertTrue(second.cloud.getJSONObject("nativeSync").getJSONObject("facts").getBoolean("library-edit"))
            assertEquals(retained.toString(), second.settingsDirty().toString())
            assertFalse(second.cloud.has("nativeHostPreferences"))
            second.version++
            second.cloud.getJSONObject("nativeSync").getJSONObject("facts").put("peer-after-upload", true)
            advanceTimeBy(3_001); runCurrent()
            assertTrue(second.gateway.carrier.getJSONObject("facts").getBoolean("peer-after-upload"))
            assertEquals(second.version, second.manager.lastAppliedVersion())
            assertEquals(1, second.puts); assertFalse(second.dirty())
            assertEquals("invalid", context.getSharedPreferences("vortx_settings", 0).getString("stremiox.autoSkipDelaySeconds", null))
            assertEquals(retained.toString(), second.settingsDirty().toString())
            context.getSharedPreferences("vortx_settings", 0).edit().putInt("stremiox.autoSkipDelaySeconds", 3).commit()
            second.edit("after-setting-type-repair")
            runCurrent(); advanceTimeBy(2_501); runCurrent()
            assertEquals(2, second.puts); assertFalse(second.dirty())
            assertEquals(3, second.cloud.getJSONObject("nativeHostPreferences").getJSONObject("globals")
                .getJSONObject("fields").getJSONObject("stremiox.autoSkipDelaySeconds").getInt("value"))
            assertFalse(second.settingsDirty().has("stremiox.autoSkipDelaySeconds"))
            assertEquals(setOf("stremiox.theme.oled", "stremiox.audioLang"), second.settingsDirty().keys().asSequence().toSet())
        } finally { second.close() }
    }

    @Test fun `dirty unsupported local value survives an older valid host receive and upload own apply`() = test {
        val field = "stremiox.autoSkipDelaySeconds"
        val principal = com.vortx.android.engine.VortxAccountScope(scopeId, UserProfile.OWNER_ID)
        val olderHost = com.vortx.android.engine.NativeHostPreferences.empty(principal).also { host ->
            host.getJSONObject("globals").getJSONObject("fields").put(field,
                JSONObject().put("clock", 1).put("actor", "00000000-0000-0000-0000-000000000222").put("value", 3))
            com.vortx.android.engine.NativeHostPreferences.validate(principal, host)
        }
        for (dirty in listOf(true, false)) {
            val context = MemoryContext()
            val prefs = context.getSharedPreferences("vortx_settings", 0)
            prefs.edit().putString(field, "invalid").commit()
            val f = Fixture(testScheduler, context)
            try {
                if (dirty) f.settingsDirty(JSONObject().put(field, 125.75))
                // The synthetic checkpoint and incoming cloud each contain an eligible, schema-valid
                // older INT. The actual manager receive/own-apply must consult the local dirty stamp.
                f.gateway.host = JSONObject(olderHost.toString())
                f.cloud.put("nativeHostPreferences", JSONObject(olderHost.toString()))
                f.version++
                assertTrue(f.manager.syncDown())
                assertEquals(f.version, f.manager.lastAppliedVersion())
                if (dirty) {
                    assertEquals("invalid", prefs.getString(field, null))
                    assertEquals(125.75, f.settingsDirty().getDouble(field), 0.0)
                    f.edit("library-with-protected-invalid-setting")
                    runCurrent(); advanceTimeBy(2_501); runCurrent()
                    assertEquals(1, f.puts); assertFalse(f.dirty())
                    assertEquals("invalid", prefs.getString(field, null))
                    assertEquals(125.75, f.settingsDirty().getDouble(field), 0.0)
                    assertTrue(NativeSyncPublicationPolicy.same(olderHost, f.cloud.getJSONObject("nativeHostPreferences")))
                } else {
                    // Positive control proves this same valid incoming register really reaches
                    // application; only the dirty-key guard preserves the unsupported local value.
                    assertEquals(3, prefs.getInt(field, -1))
                    assertFalse(f.settingsDirty().has(field))
                }
            } finally { f.close() }
        }
    }

    @Test fun `global setting alone schedules native upload and acknowledgement does not echo`() = test {
        val f = Fixture(testScheduler, MemoryContext(notifyChanges = true))
        try {
            f.enableConditionalTransport()
            assertTrue(f.routinePull())
            assertTrue(f.routinePull()); assertEquals("\"10\"", f.validators.last())
            assertFalse(f.dirty()); assertEquals(0, f.puts)
            // This is the real preference listener; no library/native edit or manual sync is used.
            f.context.getSharedPreferences("vortx_settings", 0).edit()
                .putBoolean("vortx.player.matchFrameRate", true).commit()
            assertTrue(checkNotNull(NativeSettingsFence.queuedNotificationsForTest).isNotEmpty())
            assertFalse(f.dirty()) // Production notifications are delivered after the preference replacement.
            drainSettingsNotifications()
            assertTrue(f.dirty()); assertTrue(f.settingsDirty().has("vortx.player.matchFrameRate"))
            runCurrent(); advanceTimeBy(2_501); runCurrent()
            drainSettingsNotifications()
            assertEquals(1, f.puts); assertFalse(f.dirty())
            assertFalse(f.settingsDirty().has("vortx.player.matchFrameRate"))
            assertTrue(f.cloud.getJSONObject("nativeHostPreferences").getJSONObject("globals")
                .getJSONObject("fields").getJSONObject("vortx.player.matchFrameRate").getBoolean("value"))
            assertTrue(f.routinePull()); drainSettingsNotifications(); advanceTimeBy(10_000); runCurrent()
            assertEquals(1, f.puts); assertFalse(f.dirty())
        } finally { f.close() }
    }

    @Test fun `remote globals and profile mirrors do not arm native upload through preference listener`() = test {
        val f = Fixture(testScheduler, MemoryContext(notifyChanges = true))
        try {
            f.gateway.host = JSONObject().put("globals", JSONObject().put("fields", JSONObject()
                .put("vortx.player.matchFrameRate", JSONObject().put("value", true))))
            f.cloud.put("nativeHostPreferences", JSONObject(f.gateway.host!!.toString()))
            assertTrue(f.routinePull())
            assertTrue(f.context.getSharedPreferences("vortx_settings", 0).getBoolean("vortx.player.matchFrameRate", false))
            assertTrue(checkNotNull(NativeSettingsFence.queuedNotificationsForTest).isNotEmpty())
            drainSettingsNotifications() // Remote own-apply already rebased the shadow before delivery.
            assertFalse(f.dirty())
            // These are the same flat mirror writes made by ProfileStore.applyPlayback after a
            // native projection, outside the manager's applyingRemote window.
            f.context.getSharedPreferences("vortx_settings", 0).edit()
                .putString("stremiox.theme.accent", "fixture").putString("stremiox.sub.color", "yellow").commit()
            drainSettingsNotifications()
            runCurrent(); advanceTimeBy(10_000); runCurrent()
            assertEquals(0, f.puts); assertFalse(f.dirty())
            assertFalse(f.settingsDirty().has("vortx.player.matchFrameRate"))
            // A later real global edit must not export the retained profile mirror stamp either.
            f.context.getSharedPreferences("vortx_settings", 0).edit().putBoolean("vortx.player.matchFrameRate", false).commit()
            drainSettingsNotifications()
            assertTrue(f.dirty())
            runCurrent(); advanceTimeBy(2_501); runCurrent()
            assertEquals(1, f.puts)
            assertFalse(f.cloud.getJSONObject("nativeHostPreferences").getJSONObject("globals")
                .getJSONObject("fields").has("stremiox.sub.color"))
        } finally { f.close() }
    }

    private fun pendingReconcile(manager: VortXSyncManager): VortXAccountViewModel = VortXAccountViewModel(manager).also { model ->
        model.requireAccountReconcile()
    }

    @Test fun `failed reconcile choices remain visible and actionable until confirmed retry`() = test {
        val choices: List<(VortXAccountViewModel) -> Unit> = listOf(
            { it.reconcileUseAccount() }, { it.reconcileMergeBoth() }, { it.reconcileKeepDevice() })
        for (choose in choices) {
            val f = Fixture(testScheduler)
            val model = pendingReconcile(f.manager)
            try {
                f.getFails = true
                choose(model); runCurrent()
                assertTrue(model.showReconcile.value); assertFalse(model.syncing.value)
                assertNotNull(model.syncNotice.value); assertFalse(f.realtime.isActive())
                // The same visible card can now retry a confirmed account restore.
                f.getFails = false
                model.reconcileUseAccount(); runCurrent()
                assertFalse(model.showReconcile.value); assertFalse(model.syncing.value)
                assertNull(model.syncNotice.value)
            } finally { model.viewModelScope.cancel(); f.close() }
        }
    }

    @Test fun `reconcile keeps choice visible while suspended and ignores duplicate submits`() = test {
        val f = Fixture(testScheduler)
        val model = pendingReconcile(f.manager)
        try {
            f.getGate = CompletableDeferred(); f.getFails = true
            model.reconcileUseAccount(); runCurrent()
            assertTrue(model.showReconcile.value); assertTrue(model.syncing.value); assertEquals(1, f.gets)
            model.reconcileMergeBoth(); runCurrent(); assertEquals(1, f.gets)
            f.getGate!!.complete(Unit); runCurrent()
            assertTrue(model.showReconcile.value); assertFalse(model.syncing.value); assertNotNull(model.syncNotice.value)
        } finally { model.viewModelScope.cancel(); f.close() }
    }

    @Test fun `filtered global acknowledgement preserves newer edit and profile stamp during PUT`() = test {
        val f = Fixture(testScheduler)
        try {
            f.context.getSharedPreferences("vortx_settings", 0).edit().putBoolean("stremiox.autoSkip", true).commit()
            f.settingsDirty(JSONObject().put("stremiox.theme.oled", 123.25).put("stremiox.autoSkip", 124.5))
            f.edit("library-before")
            f.beforePut = {
                f.beforePut = null
                f.context.getSharedPreferences("vortx_settings", 0).edit().putBoolean("stremiox.autoSkip", false).commit()
                f.settingsDirty(f.settingsDirty().put("stremiox.autoSkip", 126.75))
                f.edit("library-during")
            }
            runCurrent(); advanceTimeBy(2_501); runCurrent()
            assertEquals(1, f.puts); assertTrue(f.dirty())
            assertTrue(f.cloud.getJSONObject("nativeHostPreferences").getJSONObject("globals").getJSONObject("fields")
                .getJSONObject("stremiox.autoSkip").getBoolean("value"))
            assertEquals(126.75, f.settingsDirty().getDouble("stremiox.autoSkip"), 0.0)
            assertEquals(10L, f.manager.lastAppliedVersion()) // Newer local globals prevented the old own-apply/ACK.
            advanceTimeBy(2_499); runCurrent()
            assertEquals(1, f.puts); assertTrue(f.dirty())
            assertEquals(126.75, f.settingsDirty().getDouble("stremiox.autoSkip"), 0.0)
            advanceTimeBy(2_501); runCurrent() // Existing failed-own-apply retry backoff is five seconds.
            assertEquals(2, f.puts); assertFalse(f.dirty())
            assertFalse(f.cloud.getJSONObject("nativeHostPreferences").getJSONObject("globals").getJSONObject("fields")
                .getJSONObject("stremiox.autoSkip").getBoolean("value"))
            assertTrue(f.cloud.getJSONObject("nativeSync").getJSONObject("facts").getBoolean("library-during"))
            assertEquals(setOf("stremiox.theme.oled"), f.settingsDirty().keys().asSequence().toSet())
            assertEquals(123.25, f.settingsDirty().getDouble("stremiox.theme.oled"), 0.0)
        } finally { f.close() }
    }

    @Test fun `account replacement while filtered upload waits cannot clear either account intent`() = test {
        val f = Fixture(testScheduler)
        try {
            f.context.getSharedPreferences("vortx_settings", 0).edit().putBoolean("stremiox.autoSkip", true).commit()
            val retained = JSONObject().put("stremiox.theme.oled", 123.25).put("stremiox.autoSkip", 124.5)
            f.settingsDirty(retained); f.edit("library-a")
            f.getGate = CompletableDeferred()
            runCurrent(); advanceTimeBy(2_501); runCurrent(); assertEquals(1, f.gets)
            val b = account.copy(id = "00000000-0000-0000-0000-000000000999")
            val otherKey = "vortx.sync.dirtySettings.${b.id}"
            f.context.getSharedPreferences("vortx_sync_dirty", 0).edit().putString(otherKey, "{\"stremiox.autoSkip\":999}").commit()
            f.manager.replaceSyncSessionTestSeam(VortXSyncManager.Session("fixture-b", b, key))
            f.getGate!!.complete(Unit); runCurrent()
            assertEquals(0, f.puts)
            assertEquals(retained.toString(), f.settingsDirty().toString())
            assertEquals("{\"stremiox.autoSkip\":999}", f.context.getSharedPreferences("vortx_sync_dirty", 0).getString(otherKey, null))
            assertTrue(f.dirty())
        } finally { f.close() }
    }

    @Test fun `failed native apply and failed host receipt do not advance revision`() = test {
        val f = Fixture(testScheduler)
        try {
            f.version = 11; f.gateway.applyFails = true
            assertFalse(f.manager.syncDown()); assertEquals(10L, f.manager.lastAppliedVersion())
            f.gateway.applyFails = false; f.gateway.host = JSONObject().put("globals", JSONObject().put("fields", JSONObject()))
            f.context.rejectCommitKey = "vortx_settings:"
            assertFalse(f.manager.syncDown()); assertEquals(10L, f.manager.lastAppliedVersion())
            f.context.rejectCommitKey = null
            assertTrue(f.manager.syncDown()); assertEquals(11L, f.manager.lastAppliedVersion())
        } finally { f.close() }
    }

    @Test fun nativeReopenLinkageFailureRetainsStateNoticeUntilSuccessAndRejectsStaleNotice() = test {
        val f = Fixture(testScheduler)
        val expectedNotice = "The native engine is unavailable or incompatible. Your saved data and pending changes are preserved. Update VortX or export diagnostics, then retry sync."
        try {
            val saved = f.manager.currentSession()
            val retainedState = f.context.getSharedPreferences("vortx_sync_state", 0).all.toMap()
            val retainedFacts = f.gateway.carrier.toString()
            f.gateway.reopenError = UnsatisfiedLinkError("fixture/private/checkpoint?token=fixture-private")
            assertFalse(f.manager.syncDown())
            assertEquals(expectedNotice, f.manager.syncProblem.value)
            assertSame(saved, f.manager.currentSession()); assertEquals(account, f.manager.account.value)
            assertEquals(10L, f.manager.lastAppliedVersion()); assertFalse(f.dirty())
            assertEquals(retainedState, f.context.getSharedPreferences("vortx_sync_state", 0).all)
            assertEquals(retainedFacts, f.gateway.carrier.toString())
            assertEquals(0, f.gets); assertEquals(0, f.puts); assertEquals(0, f.gateway.applied)
            f.gateway.reopenError = null; f.getFails = true
            assertFalse(f.manager.syncDown())
            assertEquals(expectedNotice, f.manager.syncProblem.value) // Ordinary failure cannot clear native failure.
            f.getFails = false
            assertTrue(f.manager.syncDown()); assertNull(f.manager.syncProblem.value)
            assertSame(saved, f.manager.currentSession()); assertEquals(10L, f.manager.lastAppliedVersion())

            val replacement = VortXSyncManager.Session("fixture-b",
                account.copy(id = "00000000-0000-0000-0000-000000000999"), key)
            f.gateway.afterExport = {
                f.gateway.afterExport = null
                f.manager.replaceSyncSessionTestSeam(replacement)
                throw UnsatisfiedLinkError("fixture stale linkage")
            }
            assertFalse(f.manager.syncDown())
            assertSame(replacement, f.manager.currentSession()); assertEquals(replacement.account, f.manager.account.value)
            assertNull(f.manager.syncProblem.value) // An old lease cannot publish into the replacement account.
        } finally { f.close() }
    }

    @Test fun staleNativeGatewayLinkageCannotMarkSameAccountReplacementUnavailable() = test {
        val f = Fixture(testScheduler)
        try {
            val saved = f.manager.currentSession()
            val retainedState = f.context.getSharedPreferences("vortx_sync_state", 0).all.toMap()
            val retainedCloud = f.cloud.toString()
            val replacement = Gateway()
            f.gateway.afterExport = {
                f.gateway.afterExport = null
                f.manager.installNativeGatewayTestSeam(replacement, f.providers)
                throw UnsatisfiedLinkError("fixture stale gateway/private?token=fixture-private")
            }
            assertFalse(f.manager.syncDown())
            assertNull(f.manager.syncProblem.value)
            assertSame(saved, f.manager.currentSession()); assertEquals(account, f.manager.account.value)
            assertEquals(retainedState, f.context.getSharedPreferences("vortx_sync_state", 0).all)
            assertEquals(retainedCloud, f.cloud.toString()); assertEquals(10L, f.manager.lastAppliedVersion())
            assertFalse(f.dirty()); assertEquals(0, f.gets); assertEquals(0, f.puts)
            assertEquals(1, f.gateway.exports); assertEquals(0, replacement.exports)
            assertTrue(f.manager.syncDown()) // The same-session replacement remains retryable.
            assertTrue(replacement.exports > 0); assertEquals(1, replacement.reopens)
            assertNull(f.manager.syncProblem.value); assertSame(saved, f.manager.currentSession())
            assertEquals(0, f.puts)
        } finally { f.close() }
    }

    @Test fun queuedNativeExportLinkageFailureRetainsActualPendingEditsAndUnacknowledgedRevision() = test {
        val f = Fixture(testScheduler)
        try {
            val saved = f.manager.currentSession()
            f.settingsDirty(JSONObject().put("vortx.player.matchFrameRate", 120.0))
            f.edit("queued-local-library")
            val retainedSettings = f.settingsDirty().toString()
            val retainedCloud = f.cloud.toString()
            f.gateway.afterExport = { throw UnsatisfiedLinkError("fixture/private/export?token=fixture-private") }
            assertTrue(f.dirty())
            runCurrent(); advanceTimeBy(2_501); runCurrent()
            assertTrue(f.gateway.exports > 0) // The actual debounced upload reached native export.
            assertEquals("The native engine is unavailable or incompatible. Your saved data and pending changes are preserved. Update VortX or export diagnostics, then retry sync.",
                f.manager.syncProblem.value)
            assertSame(saved, f.manager.currentSession()); assertEquals(account, f.manager.account.value)
            assertTrue(f.dirty()); assertEquals(retainedSettings, f.settingsDirty().toString())
            assertEquals(10L, f.manager.lastAppliedVersion()); assertEquals(0, f.puts)
            assertEquals(retainedCloud, f.cloud.toString())
            assertTrue(f.gateway.carrier.getJSONObject("facts").getBoolean("queued-local-library"))
            assertFalse(f.realtime.isActive())
        } finally { f.close() }
    }

    @Test fun `accepted PUT cannot stamp until host provider and durable revision receipts succeed`() = test {
        val f = Fixture(testScheduler)
        try {
            f.gateway.host = JSONObject().put("globals", JSONObject().put("fields", JSONObject()))
            f.gateway.ackFails = true
            assertFalse(f.manager.syncUp()); assertEquals(10L, f.manager.lastAppliedVersion())
            f.gateway.ackFails = false
            f.beforePut = { f.beforePut = null; f.providers.failWrite = true }
            assertFalse(f.manager.syncUp()); assertEquals(10L, f.manager.lastAppliedVersion())
            f.providers.failWrite = false
            f.context.rejectCommitKey = "vortx_sync_state:lastSyncedVersion."
            assertFalse(f.manager.syncUp()); assertEquals(10L, f.manager.lastAppliedVersion())
            f.context.rejectCommitKey = null
            assertTrue(f.manager.syncUp()); assertEquals(f.version, f.manager.lastAppliedVersion())
        } finally { f.close() }
    }

    @Test fun `accepted create-only backup with failed local apply remains unacknowledged`() = test {
        val f = Fixture(testScheduler)
        try {
            f.context.getSharedPreferences("vortx_sync_state", 0).edit().remove("lastSyncedVersion.${account.id}").commit()
            f.getFails = false
            // GET 404 without prior-backup evidence is the only path allowed to seed.
            f.manager.installSyncTestSeam(VortXSyncManager.Session("fixture-a", account, key), 0, transport = { method, _, _, _ ->
                if (method == "GET") 404 to null else 200 to JSONObject().put("accepted", true)
            })
            f.context.getSharedPreferences("vortx_sync_state", 0).edit().remove("lastSyncedVersion.${account.id}").commit()
            f.gateway.applyFails = true
            assertFalse(f.manager.syncUp())
            assertFalse(f.context.getSharedPreferences("vortx_sync_state", 0).contains("lastSyncedVersion.${account.id}"))
        } finally { f.close() }
    }

    @Test fun `equal acknowledged carrier neither joins remounts nor repushes`() = test {
        val f = Fixture(testScheduler)
        try {
            repeat(4) { assertTrue(f.manager.syncDown()) }
            assertEquals(0, f.gateway.applied); assertFalse(f.dirty())
            runCurrent(); advanceTimeBy(10_000); runCurrent(); assertEquals(0, f.puts)
        } finally { f.close() }
    }

    @Test fun `version zero without durable acknowledgement still applies recovered checkpoint`() = test {
        val f = Fixture(testScheduler)
        try {
            f.version = 0
            f.cloud.getJSONObject("nativeSync").getJSONObject("facts").put("peer", true)
            f.context.getSharedPreferences("vortx_sync_state", 0).edit().remove("lastSyncedVersion.${account.id}").commit()
            assertTrue(f.manager.syncDown()); assertEquals(1, f.gateway.applied)
            assertTrue(f.gateway.carrier.getJSONObject("facts").getBoolean("peer"))
        } finally { f.close() }
    }

    @Test fun `checkpoint-only local fact heals equal cloud once without echo loop`() = test {
        val f = Fixture(testScheduler)
        try {
            f.gateway.carrier.getJSONObject("facts").put("checkpoint-only", true)
            assertTrue(f.manager.syncDown()); assertTrue(f.dirty()); assertEquals(0, f.gateway.applied)
            runCurrent(); advanceTimeBy(2_501); runCurrent()
            assertEquals(1, f.puts); assertFalse(f.dirty())
            repeat(3) { assertTrue(f.manager.syncDown()) }
            advanceTimeBy(10_000); runCurrent(); assertEquals(1, f.puts)
        } finally { f.close() }
    }

    @Test fun `legacy rollback higher envelope heals causal fact without replacing foreign fields`() = test {
        val f = Fixture(testScheduler)
        try {
            f.gateway.carrier.getJSONObject("facts").put("new-local", true)
            f.version = 1_760_000_000_000L
            assertTrue(f.manager.syncDown()); assertTrue(f.dirty())
            runCurrent(); advanceTimeBy(2_501); runCurrent()
            assertEquals(1_760_000_000_001L, f.version)
            assertTrue(f.cloud.getJSONObject("nativeSync").getJSONObject("facts").getBoolean("new-local"))
            assertEquals("preserved", f.cloud.getString("foreign")); assertFalse(f.dirty())
        } finally { f.close() }
    }

    @Test fun `legacy-only cloud recovers checkpoint edit before lost callback without equal join loop`() = test {
        val f = Fixture(testScheduler)
        try {
            f.cloud.remove("nativeSync")
            f.gateway.carrier.put("legacyImport", JSONObject().put("receipt", true))
            f.gateway.carrier.getJSONObject("facts").put("checkpoint-before-callback", true)
            assertTrue(f.manager.syncDown()); assertTrue(f.dirty()); assertEquals(0, f.gateway.applied)
            runCurrent(); advanceTimeBy(2_501); runCurrent()
            assertEquals(1, f.puts); assertFalse(f.dirty())
            assertTrue(f.cloud.getJSONObject("nativeSync").getJSONObject("facts").getBoolean("checkpoint-before-callback"))
            repeat(3) { assertTrue(f.manager.syncDown()) }
            advanceTimeBy(10_000); runCurrent(); assertEquals(1, f.puts)
        } finally { f.close() }
    }

    @Test fun `verified legacy-only baseline heals but missing or mismatched carrier authority cannot`() = test {
        val joined = NativeAccountExport(native().put("legacyImport", JSONObject().put("receipt", true)), emptyList(), 0.0)
        assertTrue(NativeSyncPublicationPolicy.needsRepublish(JSONObject().put("foreign", "keep"), joined))
        assertFalse(NativeSyncPublicationPolicy.needsRepublish(JSONObject(), joined.copy(nativeSync = native())))
        assertFalse(NativeSyncPublicationPolicy.needsRepublish(document(native().put("scope", "account.other")), joined))
        assertFalse(NativeSyncPublicationPolicy.needsRepublish(JSONObject().put("nativeSync", "malformed"), joined))
        val equal = JSONObject("""{"a":1.0,"b":[{"x":2}]}""")
        assertTrue(NativeSyncPublicationPolicy.same(equal, JSONObject("""{"b":[{"x":2.0}],"a":1}""")))
    }

    @Test fun `origin mutation cannot arm different account or same-account new epoch`() = test {
        val f = Fixture(testScheduler)
        try {
            val origin = SessionOwnerSnapshot.Account(account.id, 1)
            val b = account.copy(id = "00000000-0000-0000-0000-000000000999")
            f.manager.replaceSyncSessionTestSeam(VortXSyncManager.Session("fixture-b", b, key))
            f.manager.onLocalNativeMutation(origin)
            assertFalse(f.context.getSharedPreferences("vortx_sync_state", 0).getBoolean("pendingPush.${b.id}", false))
            f.manager.installSessionRestoreTestSeam(VortXSyncManager.Session("fixture-a", account, key), 2)
            // Production restore reconciles persisted epoch after unavailable storage; exercise
            // the same durable-session transition without signing into any account.
            f.manager.installUnavailableSessionRestoreTestSeam(); f.manager.sessionOwnerSnapshot()
            f.manager.installSessionRestoreTestSeam(VortXSyncManager.Session("fixture-a", account, key), 2)
            f.manager.sessionOwnerSnapshot(); f.manager.onLocalNativeMutation(origin)
            assertFalse(f.dirty())
        } finally { f.close() }
    }

    @Test fun `cold confirmed account waits for manager publication and forces one authenticated receive`() = test {
        var published: VortXSyncManager? = null
        val f = Fixture(testScheduler, startupActive = { it === published })
        try {
            val owner = f.manager.sessionOwnerSnapshot()
            assertEquals(SessionOwnerSnapshot.Account(account.id, INITIAL_SESSION_OWNER_EPOCH), owner)
            val start = f.prepareStartup(MutableStateFlow(AccountSyncForeground(active = false)), owner)
            runCurrent()
            f.assertNoStartupDispatch()
            assertTrue(runCatching { start() }.exceptionOrNull() is IllegalStateException)
            runCurrent()
            f.assertNoStartupDispatch()

            published = f.manager
            start()
            runCurrent()

            assertEquals(1, f.gateway.reopens)
            assertEquals(1, f.gateway.applied)
            assertEquals(1, f.gets)
            assertEquals(listOf("fixture-a"), f.tokens)
            assertEquals(0, f.puts)
            assertTrue(f.sockets.isEmpty())
        } finally { f.close() }
    }

    @Test fun `owner presentation changes on confirmed same account recovery and clears on unavailable storage`() = test {
        val f = Fixture(testScheduler)
        try {
            val manager = f.manager
            val session = requireNotNull(manager.currentSession())
            val original = SessionOwnerSnapshot.Account(account.id, INITIAL_SESSION_OWNER_EPOCH)
            assertEquals(original, manager.sessionOwnerSnapshot())
            assertEquals(original, manager.sessionOwnerPresentation.value)

            manager.installUnavailableSessionRestoreTestSeam()
            assertTrue(manager.sessionOwnerSnapshot() is SessionOwnerSnapshot.UnknownOrUnavailable)
            assertTrue(manager.sessionOwnerPresentation.value is SessionOwnerSnapshot.UnknownOrUnavailable)

            val replacement = original.copy(generation = original.generation + 1)
            manager.installSessionRestoreTestSeam(session, ownerEpoch = replacement.generation)
            assertEquals(replacement, manager.sessionOwnerSnapshot())
            assertEquals(SessionUiState.SignedIn(account), manager.sessionUiState.value)
            assertEquals(replacement, manager.sessionOwnerPresentation.value)
        } finally { f.close() }
    }

    @Test fun `cold signed-out and unavailable owners cannot open a checkpoint request or socket`() = test {
        for (signedOut in listOf(true, false)) {
            val f = Fixture(testScheduler)
            try {
                f.manager.installUnavailableSessionRestoreTestSeam()
                assertTrue(f.manager.sessionOwnerSnapshot() is SessionOwnerSnapshot.UnknownOrUnavailable)
                if (signedOut) f.manager.installSessionRestoreTestSeam(null, ownerEpoch = 2)
                val owner = f.manager.sessionOwnerSnapshot()
                if (signedOut) {
                    assertEquals(SessionOwnerSnapshot.SignedOutLocal(2), owner)
                } else {
                    assertTrue(owner is SessionOwnerSnapshot.UnknownOrUnavailable)
                }

                f.prepareStartup(MutableStateFlow(AccountSyncForeground(active = true)), owner)()
                runCurrent()

                f.assertNoStartupDispatch()
                assertEquals(if (signedOut) SessionUiState.SignedOut else SessionUiState.UnknownOrUnavailable,
                    f.manager.sessionUiState.value)
            } finally { f.close() }
        }
    }

    @Test fun `a live account and mismatched persisted tuple do not authorize cold receive`() = test {
        val f = Fixture(testScheduler)
        try {
            val live = requireNotNull(f.manager.currentSession())
            f.manager.installSessionRestoreTestSeam(
                VortXSyncManager.Session("changed-fixture-token", live.account, ByteArray(32) { 38 }),
                ownerEpoch = INITIAL_SESSION_OWNER_EPOCH,
            )
            val owner = f.manager.sessionOwnerSnapshot()
            assertTrue(owner is SessionOwnerSnapshot.UnknownOrUnavailable)
            assertSame(live, f.manager.currentSession())

            // No foreground transition is present to independently recover the newer tuple.
            f.prepareStartup(MutableStateFlow(AccountSyncForeground(active = false)), owner)()
            runCurrent()

            f.assertNoStartupDispatch()
        } finally { f.close() }
    }

    @Test fun `cold startup rechecks unavailable or changed persistence after it waits for the native mutex`() = test {
        for (unavailable in listOf(true, false)) {
            val f = Fixture(testScheduler)
            val release = CompletableDeferred<Unit>()
            try {
                val foreground = MutableStateFlow(AccountSyncForeground(active = false))
                val start = f.prepareStartup(foreground)
                f.getGate = release
                val holder = async { f.manager.syncDown() }
                runCurrent()
                assertFalse(holder.isCompleted)
                assertEquals(1, f.gets)
                assertEquals(1, f.gateway.reopens)

                start()
                runCurrent()
                assertEquals(1, f.gets)
                if (unavailable) {
                    f.manager.installUnavailableSessionRestoreTestSeam()
                } else {
                    f.manager.installSessionRestoreTestSeam(requireNotNull(f.manager.currentSession()), ownerEpoch = 2)
                }
                // Stop the holder at its existing transport response. It must not observe the changed
                // persisted tuple on the way out and indirectly reject the queued cold lease for us.
                f.getFails = true
                f.getGate = null
                release.complete(Unit)
                runCurrent()
                assertFalse(holder.await())

                assertEquals("the rejected cold lease must not reopen the checkpoint", 1, f.gateway.reopens)
                assertEquals(listOf("fixture-a"), f.tokens)
                assertEquals(0, f.puts)
                assertTrue(f.sockets.isEmpty())
            } finally {
                release.complete(Unit)
                f.close()
            }
        }
    }

    @Test fun `background rejects an admitted realtime receive still waiting for native mutex`() = test {
        val f = Fixture(testScheduler)
        val release = CompletableDeferred<Unit>()
        try {
            val foreground = MutableStateFlow(AccountSyncForeground(active = true))
            f.prepareStartup(foreground)()
            runCurrent()
            val socket = f.sockets.single()
            val previousGets = f.gets
            val previousReopens = f.gateway.reopens

            f.getGate = release
            val holder = async { f.manager.syncDown() }
            runCurrent()
            assertFalse(holder.isCompleted)
            assertEquals(previousGets + 1, f.gets)
            assertEquals(previousReopens + 1, f.gateway.reopens)

            val oldLease = requireNotNull(f.manager.captureRealtimeLease())
            // This call is not the socket worker, so stopping that worker cannot make the test pass by cancellation.
            val queued = async { f.manager.syncDownForRealtime(oldLease) }
            runCurrent()
            assertFalse(queued.isCompleted)
            foreground.value = AccountSyncForeground(active = false)
            f.getGate = null
            release.complete(Unit)
            runCurrent()

            assertTrue(holder.await())
            assertFalse(queued.await())
            assertTrue(socket.cancelled)
            assertEquals(previousReopens + 1, f.gateway.reopens)
            assertEquals(previousGets + 1, f.gets)
            assertEquals(0, f.puts)
        } finally {
            release.complete(Unit)
            f.close()
        }
    }

    @Test fun `background after checkpoint preparation blocks the realtime transport request`() = test {
        val f = Fixture(testScheduler)
        try {
            val foreground = MutableStateFlow(AccountSyncForeground(active = true))
            f.prepareStartup(foreground)()
            runCurrent()
            val socket = f.sockets.single()
            val previousGets = f.gets
            val previousReopens = f.gateway.reopens
            val oldLease = requireNotNull(f.manager.captureRealtimeLease())

            // Invalidate the conditional receipt so this receive must use the real checkpoint/export path.
            f.gateway.mountRevision++
            var backgroundedBeforeRequest = false
            f.gateway.afterExport = {
                f.gateway.afterExport = null
                backgroundedBeforeRequest = true
                foreground.value = AccountSyncForeground(active = false)
            }
            val result = async { f.manager.syncDownForRealtime(oldLease) }
            runCurrent()

            assertTrue(backgroundedBeforeRequest)
            assertFalse(result.await())
            assertTrue(socket.cancelled)
            assertEquals(previousReopens + 1, f.gateway.reopens)
            assertEquals(previousGets, f.gets)
            assertEquals(0, f.puts)
        } finally { f.close() }
    }

    @Test fun `a conflated background and foreground retires the previous realtime socket`() = test {
        val f = Fixture(testScheduler)
        try {
            val foreground = MutableStateFlow(AccountSyncForeground(active = true))
            f.prepareStartup(foreground)()
            runCurrent()
            val old = f.sockets.single()
            val previousGets = f.gets

            foreground.value = AccountSyncForeground(active = false)
            foreground.value = AccountSyncForeground(active = true)
            runCurrent()

            assertTrue(old.cancelled)
            assertEquals(2, f.sockets.size)
            assertEquals(previousGets + 1, f.gets)
            old.updated(11)
            runCurrent()
            assertEquals(previousGets + 1, f.gets)
        } finally { f.close() }
    }

    @Test fun `queued realtime work and old socket cannot adopt A B A replacement`() = test {
        val f = Fixture(testScheduler)
        try {
            f.realtime.start(); val old = f.sockets.single()
            f.manager.replaceSyncSessionTestSeam(VortXSyncManager.Session("fixture-b", account.copy(id = "00000000-0000-0000-0000-000000000999"), key))
            f.manager.replaceSyncSessionTestSeam(VortXSyncManager.Session("fixture-a", account, key))
            old.updated(11); runCurrent(); assertEquals(0, f.gets)
            f.realtime.start(); assertEquals(2, f.sockets.size); runCurrent(); assertEquals(1, f.gets)
            old.updated(12); runCurrent(); assertEquals(1, f.gets)
            assertEquals(listOf("fixture-a"), f.tokens)
        } finally { f.close() }
    }

    @Test fun `notification burst is conflated with at most one in-flight and one followup`() = test {
        val f = Fixture(testScheduler)
        try {
            f.getGate = CompletableDeferred(); f.realtime.start(); runCurrent(); assertEquals(1, f.gets)
            repeat(100) { f.sockets.single().updated(11) }
            runCurrent(); assertEquals(1, f.gets)
            f.getGate!!.complete(Unit); f.getGate = null; runCurrent(); assertEquals(2, f.gets)
            f.sockets.single().updated(10); f.sockets.single().message("{\"type\":\"updated\",\"version\":10.5}")
            runCurrent(); assertEquals(2, f.gets)
        } finally { f.close() }
    }

    @Test fun `active fallback catches missed broadcast at three seconds and stops on background`() = test {
        val f = Fixture(testScheduler)
        try {
            f.manager.setRealtimeForeground(true); runCurrent(); assertEquals(1, f.gets)
            f.version = 11; f.cloud.getJSONObject("nativeSync").getJSONObject("facts").put("peer", true)
            advanceTimeBy(3_001); runCurrent(); assertEquals(2, f.gets); assertEquals(11L, f.manager.lastAppliedVersion())
            f.manager.setRealtimeForeground(false); f.manager.startRealtime() // delayed auth completion
            advanceTimeBy(30_000); runCurrent(); assertEquals(2, f.gets); assertFalse(f.realtime.isActive())
            assertEquals(1, f.sockets.size)
        } finally { f.close() }
    }

    @Test fun `foreground restore retry opens channel catches up and continues socket and polling receive`() = test {
        val f = Fixture(testScheduler)
        try {
            f.unavailableWithoutLiveSession()
            f.manager.setRealtimeForeground(true); runCurrent()
            assertFalse(f.realtime.isActive()); assertTrue(f.sockets.isEmpty()); assertEquals(0, f.gets)
            f.version = 11; f.cloud.getJSONObject("nativeSync").getJSONObject("facts").put("while-unavailable", true)
            f.manager.installSessionRestoreTestSeam(VortXSyncManager.Session("fixture-a", account, key))
            f.manager.retrySessionRestore(); runCurrent()
            assertEquals(SessionUiState.SignedIn(account), f.manager.sessionUiState.value)
            assertTrue(f.realtime.isActive()); assertEquals(1, f.sockets.size); assertEquals(1, f.gets)
            assertTrue(f.gateway.carrier.getJSONObject("facts").getBoolean("while-unavailable"))
            assertEquals(11L, f.manager.lastAppliedVersion())
            f.manager.retrySessionRestore(); runCurrent()
            assertEquals(1, f.sockets.size); assertEquals(1, f.gets) // already-active retry is idempotent
            f.version = 12; f.cloud.getJSONObject("nativeSync").getJSONObject("facts").put("socket-peer", true)
            f.sockets.single().updated(12); runCurrent()
            assertEquals(2, f.gets); assertTrue(f.gateway.carrier.getJSONObject("facts").getBoolean("socket-peer"))
            f.version = 13; f.cloud.getJSONObject("nativeSync").getJSONObject("facts").put("missed-broadcast", true)
            advanceTimeBy(3_001); runCurrent()
            assertEquals(3, f.gets); assertEquals(13L, f.manager.lastAppliedVersion())
            assertTrue(f.gateway.carrier.getJSONObject("facts").getBoolean("missed-broadcast"))
            assertEquals(0, f.puts)
        } finally { f.close() }
    }

    @Test fun `fallback poll waits five minutes behind a live socket and resumes when it goes silent`() = test {
        val f = Fixture(testScheduler)
        try {
            // The worker answers each 30 s keep-alive; mirror that while time passes.
            fun live(ms: Long) {
                var left = ms
                while (left > 0) {
                    f.sockets.single().message("pong")
                    val step = minOf(left, 30_000L); advanceTimeBy(step); runCurrent(); left -= step
                }
            }
            f.manager.setRealtimeForeground(true); runCurrent()
            assertTrue(f.realtime.isActive()); assertEquals(1, f.gets)
            live(3_001)
            assertEquals(2, f.gets) // the first poll after opening always pulls
            f.version = 11; f.cloud.getJSONObject("nativeSync").getJSONObject("facts").put("missed-broadcast", true)
            live(290_000)
            assertEquals(2, f.gets) // a live socket holds the poll off
            live(12_000)
            assertEquals(3, f.gets); assertEquals(11L, f.manager.lastAppliedVersion()) // five minutes on, it pulls
            f.version = 12; f.cloud.getJSONObject("nativeSync").getJSONObject("facts").put("after-silence", true)
            advanceTimeBy(VortXSyncRealtime.SOCKET_SILENCE_LIMIT_MS + 3_001); runCurrent()
            assertTrue(f.gets > 3); assertEquals(12L, f.manager.lastAppliedVersion()) // a silent socket: every tick
            assertTrue(VortXSyncRealtime.shouldPoll(1_000, 2_000, 900)) // a clock that moved back never holds off
            assertTrue(VortXSyncRealtime.shouldPoll(1_000, 900, 2_000))
        } finally { f.close() }
    }

    @Test fun `background restore retry stays socketless until foreground returns`() = test {
        val f = Fixture(testScheduler)
        try {
            f.unavailableWithoutLiveSession()
            f.manager.setRealtimeForeground(true); f.manager.setRealtimeForeground(false)
            f.manager.installSessionRestoreTestSeam(VortXSyncManager.Session("fixture-a", account, key))
            f.manager.retrySessionRestore(); runCurrent(); advanceTimeBy(10_000); runCurrent()
            assertEquals(SessionUiState.SignedIn(account), f.manager.sessionUiState.value)
            assertFalse(f.realtime.isActive()); assertTrue(f.sockets.isEmpty()); assertEquals(0, f.gets)
            f.manager.setRealtimeForeground(true); runCurrent()
            assertTrue(f.realtime.isActive()); assertEquals(1, f.sockets.size); assertEquals(1, f.gets)
        } finally { f.close() }
    }

    @Test fun `unavailable and signed out restore retries cannot open foreground channel`() = test {
        val f = Fixture(testScheduler)
        try {
            f.unavailableWithoutLiveSession()
            f.manager.setRealtimeForeground(true); f.manager.retrySessionRestore(); runCurrent()
            assertEquals(SessionUiState.UnknownOrUnavailable, f.manager.sessionUiState.value)
            assertFalse(f.realtime.isActive()); assertTrue(f.sockets.isEmpty()); assertEquals(0, f.gets)
            f.manager.installSessionRestoreTestSeam(null)
            f.manager.retrySessionRestore(); advanceTimeBy(10_000); runCurrent()
            assertEquals(SessionUiState.SignedOut, f.manager.sessionUiState.value)
            assertFalse(f.realtime.isActive()); assertTrue(f.sockets.isEmpty()); assertEquals(0, f.gets)
        } finally { f.close() }
    }

    @Test fun `restored foreground channel cannot deliver queued work after account replacement`() = test {
        val f = Fixture(testScheduler)
        try {
            f.unavailableWithoutLiveSession(); f.manager.setRealtimeForeground(true)
            f.manager.installSessionRestoreTestSeam(VortXSyncManager.Session("fixture-a", account, key))
            f.manager.retrySessionRestore()
            val old = f.sockets.single()
            val b = account.copy(id = "00000000-0000-0000-0000-000000000999")
            f.manager.replaceSyncSessionTestSeam(VortXSyncManager.Session("fixture-b", b, key))
            old.updated(11); runCurrent(); advanceTimeBy(6_001); runCurrent()
            assertEquals(0, f.gets); assertEquals(0, f.gateway.applied); assertEquals(0L, f.manager.lastAppliedVersion())
            assertTrue(f.tokens.isEmpty())
        } finally { f.close() }
    }

    @Test fun `reconnect uses captured bearer catches up and revoked reconnect stays closed`() = test {
        val f = Fixture(testScheduler)
        try {
            f.realtime.start(); runCurrent(); f.sockets.single().fail()
            advanceTimeBy(1_001); runCurrent(); assertEquals(2, f.sockets.size); assertEquals(2, f.gets)
            assertEquals("Bearer fixture-a", f.sockets.last().request().header("authorization"))
            f.sockets.last().fail(); f.realtime.stop()
            advanceTimeBy(30_000); runCurrent(); assertEquals(2, f.sockets.size); assertEquals(2, f.gets)
        } finally { f.close() }
    }

    @Test fun `stop cancels queued and in-flight pull without applying or stamping`() = test {
        val f = Fixture(testScheduler)
        try {
            f.getGate = CompletableDeferred(); f.version = 11
            f.realtime.start(); runCurrent(); assertEquals(1, f.gets)
            f.realtime.stop(); f.getGate!!.complete(Unit); runCurrent()
            assertEquals(0, f.gateway.applied); assertEquals(10L, f.manager.lastAppliedVersion())
        } finally { f.close() }
    }

    @Test fun `delayed native apply rejects same account generation replacement and failed reopen is retryable`() = test {
        val f = Fixture(testScheduler)
        try {
            f.version = 11; f.gateway.reopenFails = true
            assertFalse(f.manager.syncDown()); assertEquals(0, f.gets)
            f.gateway.reopenFails = false; f.gateway.applyEntered = CompletableDeferred(); f.gateway.applyGate = CompletableDeferred()
            val applying = async { f.manager.syncDown() }; runCurrent(); f.gateway.applyEntered!!.await()
            f.manager.replaceSyncSessionTestSeam(VortXSyncManager.Session("fixture-a", account, key))
            f.gateway.applyGate!!.complete(Unit); assertFalse(applying.await()); assertEquals(10L, f.manager.lastAppliedVersion())
        } finally { f.close() }
    }

    private class Socket(private val openingRequest: Request, val listener: WebSocketListener) : WebSocket {
        var cancelled = false
        override fun request() = openingRequest
        override fun queueSize() = 0L
        override fun send(text: String) = !cancelled
        override fun send(bytes: ByteString) = !cancelled
        override fun close(code: Int, reason: String?): Boolean { cancelled = true; return true }
        override fun cancel() { cancelled = true }
        fun message(value: String) = listener.onMessage(this, value)
        fun updated(version: Long) = message(JSONObject().put("type", "updated").put("version", version).toString())
        fun fail() = listener.onFailure(this, IllegalStateException("fixture-only disconnect"), null)
    }

    private class MemoryContext(private val notifyChanges: Boolean = false) : ContextWrapper(null) {
        private val stores = mutableMapOf<String, SharedPreferences>()
        var rejectCommitKey: String? = null
        override fun getApplicationContext(): Context = this
        override fun getPackageName() = "com.vortx.android.sync.fixture"
        override fun getSharedPreferences(name: String, mode: Int) = stores.getOrPut(name) {
            val values = linkedMapOf<String, Any?>()
            val listeners = linkedSetOf<SharedPreferences.OnSharedPreferenceChangeListener>()
            lateinit var preferences: SharedPreferences
            fun editor(): SharedPreferences.Editor {
                val edits = linkedMapOf<String, Any?>(); var clear = false
                return Proxy.newProxyInstance(SharedPreferences.Editor::class.java.classLoader, arrayOf(SharedPreferences.Editor::class.java)) { proxy, method, args ->
                    when (method.name) {
                        "clear" -> { clear = true; proxy }
                        "remove" -> { edits[args!![0] as String] = null; proxy }
                        "commit", "apply" -> {
                            val rejected = method.name == "commit" && rejectCommitKey?.let { prefix ->
                                prefix == "$name:" || edits.keys.any { "$name:$it".startsWith(prefix) }
                            } == true
                            if (!rejected) {
                                val before = values.toMap()
                                if (clear) values.clear()
                                edits.forEach { (key, value) -> if (value == null) values.remove(key) else values[key] = value }
                                if (notifyChanges) (before.keys + values.keys).filter { before[it] != values[it] }.forEach { key ->
                                    listeners.toList().forEach { it.onSharedPreferenceChanged(preferences, key) }
                                }
                            }
                            if (method.name == "commit") !rejected else null
                        }
                        else -> if (method.name.startsWith("put")) { edits[args!![0] as String] = args[1]; proxy } else null
                    }
                } as SharedPreferences.Editor
            }
            preferences = Proxy.newProxyInstance(SharedPreferences::class.java.classLoader, arrayOf(SharedPreferences::class.java)) { _, method, args ->
                when (method.name) {
                    "getAll" -> values.toMap()
                    "contains" -> values.containsKey(args!![0])
                    "edit" -> editor()
                    "registerOnSharedPreferenceChangeListener" -> { listeners.add(args!![0] as SharedPreferences.OnSharedPreferenceChangeListener); null }
                    "unregisterOnSharedPreferenceChangeListener" -> { listeners.remove(args!![0] as SharedPreferences.OnSharedPreferenceChangeListener); null }
                    else -> if (method.name.startsWith("get")) values[args!![0]] ?: args[1] else null
                }
            } as SharedPreferences
            preferences
        }
    }
}
