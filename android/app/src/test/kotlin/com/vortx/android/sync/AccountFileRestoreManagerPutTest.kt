package com.vortx.android.sync

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import com.vortx.android.engine.OHJson
import com.vortx.android.engine.VortxAccountScope
import com.vortx.android.integrations.NativeProviderAccess
import com.vortx.android.integrations.NativeProviderAdmission
import com.vortx.android.integrations.NativeProviderVault
import com.vortx.android.integrations.SecureTokenStore
import com.vortx.android.security.CredentialBackend
import com.vortx.android.security.FailClosedCredentialState
import com.vortx.android.security.FailClosedCredentialStore
import com.vortx.android.sync.AccountFileRestoreJournal.Read
import com.vortx.android.sync.AccountFileRestoreJournal.State
import com.vortx.android.sync.AccountFileRestoreTransaction.Result
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import okhttp3.Authenticator
import okhttp3.CookieJar
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.io.IOException
import java.lang.reflect.InvocationTargetException
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.Path
import java.nio.file.attribute.PosixFilePermissions
import java.security.MessageDigest
import kotlin.coroutines.coroutineContext

/** Run this class in its own JVM, serially. No DNS/socket/server/Android Keystore/JNI operation is
 * part of this fixture. Actual manager, transaction, crypto, host admission, journal, outbox,
 * one-use grant, request body and outbound permit code run unchanged.
 *
 * Explicit synthetic boundaries: empty credential backends; external native/profile reservation;
 * AccountBackupRepairFixture.Bindings; POSIX metadata adapters; in-memory raw HTTP interceptor.
 * The interceptor never calls proceed. It enters the ACTUAL request's network-attempt guard and
 * writes its ACTUAL one-shot body. This is orchestration evidence, not HTTP-stack or JNI proof. */
class AccountFileRestoreManagerPutTest {
    @get:Rule val temporary = TemporaryFolder()
    private val f = AccountBackupRepairFixture

    @Test fun originalAbsentOutboxReachesOneActualPutAndConfirmedReadbackWithoutSyncSideEffects() = isolated {
        Fixture(CoroutineScope(coroutineContext + SupervisorJob()), temporary.newFolder()).use { x ->
            val selectedBefore = x.selected.copyOf()
            val settingsBefore = x.localPreferenceSnapshot()
            assertFalse(Files.exists(x.outboxRoot, LinkOption.NOFOLLOW_LINKS))
            val result = x.restore() as Result.ServerConfirmed
            val stored = x.snapshot()
            assertEquals(3, x.gets)
            assertEquals(1, x.puts)
            assertEquals(3, x.absenceChecks)
            assertEquals(1, x.bodyWrites)
            assertEquals(4, x.rejectedNetworkReplays)
            assertEquals(1, x.rejectedBodyReplays)
            assertEquals(State.ServerConfirmed, stored.state)
            assertEquals(result.operationId, stored.intent.operationId)
            assertEquals(f.version + 1, result.revision)
            assertArrayEquals(selectedBefore, x.selected)
            assertArrayEquals(selectedBefore, stored.intent.selectedFile())
            assertArrayEquals(x.head, stored.intent.displacedHeadResponse())
            assertArrayEquals(x.submission, stored.intent.submissionBytes())
            val body = OHJson.Obj(checkNotNull(x.submission))
            assertEquals(setOf("document", "version", "baseRevision"), body.keys)
            assertEquals(f.version, OHJson.integer(body.raw("baseRevision")))
            assertEquals(f.version + 1, OHJson.integer(body.raw("version")))
            val candidate = checkNotNull(VortXCrypto.openDocument(x.key, body.text("document"), f.account, result.revision))
            try {
                assertEquals(stored.intent.plaintextSha256, OHJson.sha(candidate))
                assertArrayEquals(candidate, f.plaintext(stored.intent.candidateFile()))
                val original = OHJson.Obj(x.source)
                val admitted = OHJson.Obj(candidate)
                assertEquals(original.keys + "nativeSync", admitted.keys)
                original.keys.forEach { assertArrayEquals(original.raw(it), admitted.raw(it)) }
            } finally { candidate.fill(0) }
            assertEquals(settingsBefore, x.localPreferenceSnapshot())
            assertFalse(Files.exists(x.outboxRoot, LinkOption.NOFOLLOW_LINKS))
            assertNull(field(x.manager, "nativeReceiveReceipt"))
            assertEquals(x.bindings.created, x.bindings.freed)
            assertTrue(x.bindings.live.isEmpty())
            assertTrue(x.manager.isPickerAccountCurrent(x.picker))

            // ServerConfirmed is historical remote evidence, not local adoption or a new PUT grant.
            assertEquals(Result.ExistingIntent(result.operationId, State.ServerConfirmed), x.restore())
            assertEquals(1, x.puts)
            assertEquals(3, x.gets)
            assertEquals(settingsBefore, x.localPreferenceSnapshot())
        }
    }

    @Test fun existingCurrentAccountPendingSidecarVetoesBeforeJournalAndPut() = isolated {
        Fixture(CoroutineScope(coroutineContext + SupervisorJob()), temporary.newFolder()).use { x ->
            val sidecar = x.createPendingSidecar()
            val before = Files.readAllBytes(sidecar)
            assertEquals(Result.NotSubmitted(AccountFileRestoreTransaction.Reason.LOCAL_STATE_UNVERIFIABLE), x.restore())
            assertEquals(1, x.gets)
            assertEquals(0, x.puts)
            assertEquals(0, x.bodyWrites)
            assertEquals(1, x.absenceChecks)
            assertEquals(Read.Missing, x.journal.readExisting(f.account, x.key))
            assertArrayEquals(before, Files.readAllBytes(sidecar))
            assertTrue(x.localPreferenceSnapshot().values.all { it.isEmpty() })
        }
    }

    @Test fun mutationInsideGrantTakeCannotReplaceTheFirstAbsentOutboxObservationOrReplayTheJournal() = isolated {
        Fixture(CoroutineScope(coroutineContext + SupervisorJob()), temporary.newFolder()).use { x ->
            var sidecar: Path? = null
            x.onAbsence = { count ->
                if (count == 3) {
                    // Calls 1/2 completed the original observation and its pre-send recheck.
                    // Call 3 is LiveSend.take -> requireSend -> requireLocalAbsence, before the
                    // actual manager's recheckExisting of the RETAINED outbox observation.
                    assertEquals(2, x.gets)
                    assertEquals(0, x.puts)
                    assertEquals(State.PossibleSend, x.snapshot().state)
                    assertFalse(Files.exists(x.outboxRoot, LinkOption.NOFOLLOW_LINKS))
                    sidecar = x.createPendingSidecar()
                }
            }
            val result = x.restore() as Result.DeliveryUnconfirmed
            assertEquals(3, x.absenceChecks)
            assertEquals(2, x.gets)
            assertEquals(0, x.puts)
            assertEquals(0, x.bodyWrites)
            val retained = x.snapshot()
            assertEquals(State.DeliveryUnconfirmed, retained.state)
            assertArrayEquals(x.selected, retained.intent.selectedFile())
            assertEquals(result.operationId, retained.intent.operationId)
            assertArrayEquals(byteArrayOf(19, 37), Files.readAllBytes(checkNotNull(sidecar)))

            // Conservative production result: PossibleSend was durable before take refused.
            // No unsafe NotSubmitted claim and no resend, even though this local sink saw no PUT.
            assertEquals(Result.ExistingIntent(result.operationId, State.DeliveryUnconfirmed), x.restore())
            assertEquals(2, x.gets)
            assertEquals(Result.DeliveryUnconfirmed(result.operationId),
                x.manager.verifyAccountBackupFileRestore(x.picker, result.operationId) { true })
            assertEquals(3, x.gets)
            assertEquals(0, x.puts)
            assertEquals(State.DeliveryUnconfirmed, x.snapshot().state)
            assertTrue(x.localPreferenceSnapshot().values.all { it.isEmpty() })
        }
    }

    @Test fun originalPermitRetirementAtTheSyntheticDispatchBoundaryReleasesNoBody() = isolated {
        Fixture(CoroutineScope(coroutineContext + SupervisorJob()), temporary.newFolder()).use { x ->
            x.beforePutDispatch = {
                // Select the actual in-flight request permit, not a fresh synthetic permit.
                // Both completed GET permits have already closed; this is the sole active call.
                val operations = field(x.manager, "operations") as SessionOperationCoordinator
                val originalPermit = operations.snapshot {
                    @Suppress("UNCHECKED_CAST")
                    val calls = field(operations, "activeCalls") as Set<SessionOperationCoordinator.OutboundCallPermit>
                    assertEquals(1, calls.size)
                    calls.single().also { permit ->
                        assertEquals(SessionOperationCoordinator.OutboundCallOwner.SESSION, permit.owner)
                        assertTrue(permit.isCurrent())
                        assertNotNull(permit.cancellation)
                    }
                }
                // beginAuth() retires AUTH only. A real session invalidation must retire this
                // SESSION permit after grant.take and before the actual body can write.
                operations.invalidate { }
                assertFalse(originalPermit.isCurrent())
                assertNull(originalPermit.cancellation)
                operations.snapshot { assertTrue((field(operations, "activeCalls") as Set<*>).isEmpty()) }
            }
            assertTrue(runCatching { x.restore() }.exceptionOrNull() is CancellationException)
            assertEquals(1, x.puts)
            assertEquals(0, x.bodyWrites)
            assertEquals(State.DeliveryUnconfirmed, x.snapshot().state)
            assertEquals(2, x.gets)
            assertTrue(x.localPreferenceSnapshot().values.all { it.isEmpty() })
        }
    }

    private inner class Fixture(val scope: CoroutineScope, val root: File) : AutoCloseable {
        val key = f.key()
        private val memory = RevisionContext()
        private val noBackup = Files.createDirectory(root.toPath().resolve("no_backup"), PRIVATE_DIRECTORY).toFile()
        private val prefsDirectory = Files.createDirectory(root.toPath().resolve("shared_prefs"), PRIVATE_DIRECTORY)
        val outboxRoot: Path = noBackup.toPath().resolve("vortx-provider-retries-v1")
        private val app = object : ContextWrapper(memory) {
            override fun getApplicationContext(): Context = this
            override fun getPackageName(): String = memory.packageName
            override fun getDataDir(): File = root
            override fun getNoBackupFilesDir(): File = noBackup
            override fun isDeviceProtectedStorage(): Boolean = false
            override fun deleteSharedPreferences(name: String): Boolean = true
            override fun getSharedPreferences(name: String, mode: Int): SharedPreferences =
                NativeSettingsFence.open(this, name, mode) { memory.getSharedPreferences(name, mode) }
        }
        private val queue = NativeSettingsFence.RestoreAuxiliaryBacking.PROVIDER_RETRY_QUEUE
        init {
            // Exact ordinary Application startup preparation, before the first queue open.
            NativeSettingsFence.preparePristineRestoreBacking(app, queue) {
                memory.getSharedPreferences(queue.fileName, Context.MODE_PRIVATE)
            }
        }
        val manager = VortXSyncManager(app, scope)
        val bindings = AccountBackupRepairFixture.Bindings()
        val journal: AccountFileRestoreJournal
        private val outbox: ProviderRetryOutbox
        val picker: PickerAccountSnapshot
        private val session: VortXSyncManager.Session
        private val originalBinding = field(NativeProviderAccess, "binding")
        val source: ByteArray = OHJson.Obj(f.source(settings = false)).let { root ->
            val vortx = root.obj("vortx")
            // This fixture targets submission ownership; tagged profile/receipt semantics have
            // their own real-kernel controls. Keep this synthetic kernel's names ordinary.
            vortx.set("roster", OHJson.array(OHJson.array(vortx.raw("roster")).mapIndexed { index, row ->
                OHJson.Obj(row).set("name", OHJson.quote("Synthetic viewer $index")).encoded()
            }))
            root.set("vortx", vortx.encoded()).encoded()
        }
        val selected = f.file(source, v2 = false)
        val head = OHJson.Obj().set("version", OHJson.literal(f.version.toString()))
            .set("document", OHJson.quote(checkNotNull(VortXCrypto.sealDocument(key, source, f.account, f.version, false)))).encoded()
        var gets = 0
        var puts = 0
        var bodyWrites = 0
        var rejectedNetworkReplays = 0
        var rejectedBodyReplays = 0
        var absenceChecks = 0
        var submission: ByteArray? = null
        var onAbsence: (Int) -> Unit = {}
        var beforePutDispatch: () -> Unit = {}

        init {
            val appMetadata = metadata(root.toPath())
            journal = AccountFileRestoreJournal.forJvmFixture(noBackup.toPath(), appMetadata.uid, appMetadata.gid) { path ->
                metadata(path).let { AccountFileRestoreJournal.UnixMetadata(it.uid, it.gid, it.mode) }
            }
            outbox = ProviderRetryOutbox.forJvmFixture(root.toPath(), appMetadata.uid, appMetadata.gid, ::metadata)
            replaceLazy(manager, "fileRestoreJournal", journal)
            replaceLazy(manager, "fileRestoreProviderRetryOutbox", outbox)
            replaceLazy(manager, "fileRestoreTransaction", AccountFileRestoreTransaction(journal, bindings, AccountFileHostAdmission::requireCandidate))
            // These are explicit synthetic durable-absence backends, not Android Keystore proof.
            for (path in listOf(
                listOf("debridKeys", "store", "store"), listOf("metadataKeys", "store", "store"),
                listOf("libraryPublicationProofs", "persistence", "store"),
                listOf("addonPublicationProofs", "persistence", "store"),
                listOf("ownerWatchedIntents", "persistence", "store"),
            )) emptyCredentialState(path.fold(manager as Any) { value, name -> checkNotNull(field(value, name)) })
            session = VortXSyncManager.Session(RenewalFixtures.token(RenewalFixtures.now + RenewalFixtures.day, accountID = f.account),
                VortXSyncManager.Account(f.account, "restore@example.invalid", "Synthetic", false), key.copyOf())
            // Do NOT use installSyncTestSeam: it writes lastSyncedVersion and would invalidate
            // the actual original SYNC_STATE physical backing required by this positive.
            manager.installUnavailableSessionRestoreTestSeam()
            assertTrue(manager.sessionOwnerSnapshot() is SessionOwnerSnapshot.UnknownOrUnavailable)
            manager.installSessionRestoreTestSeam(session, ownerEpoch = 11)
            assertEquals(SessionOwnerSnapshot.Account(f.account, 11), manager.sessionOwnerSnapshot())
            picker = checkNotNull(manager.capturePickerAccountSnapshot())
            val secure = SecureTokenStore(app, "fixture_native_provider_credentials")
            emptyCredentialState(checkNotNull(field(secure, "store")))
            val vault = NativeProviderVault(secure)
            setField(manager, "fileRestoreProviderVault", vault)
            assertNull("Dedicated JVM must not inherit a provider binding", originalBinding)
            assertTrue((field(NativeProviderAccess, "outbound") as Map<*, *>).isEmpty())
            NativeProviderAccess.bind(vault, object : NativeProviderAdmission {
                override fun <T> withCurrent(expected: SessionOwnerSnapshot.Account?, action: (SessionOwnerSnapshot.Account) -> T): T? {
                    val actual = manager.sessionOwnerSnapshot() as? SessionOwnerSnapshot.Account ?: return null
                    return if (expected == null || expected == actual) action(actual) else null
                }
            }) { error("Restore must not edit provider credentials") }
            replaceLazy(manager, "fileRestoreHttp", OkHttpClient.Builder()
                .followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false)
                .cookieJar(CookieJar.NO_COOKIES).authenticator(Authenticator.NONE).proxyAuthenticator(Authenticator.NONE)
                .dns { error("Synthetic Restore transport must never resolve a host") }
                .addInterceptor { chain ->
                    val request = chain.request()
                    assertEquals("/v1/backup", request.url.encodedPath)
                    assertEquals("Bearer ${session.currentBearer}", request.header("Authorization"))
                    assertEquals("no-cache, no-store", request.header("Cache-Control"))
                    val raw = when (request.method) {
                        "GET" -> {
                            gets++
                            enterActualNetworkAttempt(request)
                            if (submission == null) head else OHJson.Obj(checkNotNull(submission))
                                .remove("baseRevision").encoded()
                        }
                        "PUT" -> {
                            puts++
                            beforePutDispatch()
                            enterActualNetworkAttempt(request)
                            val body = checkNotNull(request.body)
                            assertTrue(body.isOneShot())
                            val sink = Buffer()
                            body.writeTo(sink)
                            bodyWrites++
                            assertNull(submission)
                            submission = sink.readByteArray()
                            assertEquals(checkNotNull(submission).size.toLong(), body.contentLength())
                            assertArrayEquals(snapshot().intent.submissionBytes(), submission)
                            val replay = Buffer()
                            assertTrue(runCatching { body.writeTo(replay) }.exceptionOrNull() is IOException)
                            assertEquals(0L, replay.size)
                            rejectedBodyReplays++
                            OHJson.literal("{\"accepted\":true}")
                        }
                        else -> error("Unexpected Restore method")
                    }
                    // Never proceed: no production/local socket or HTTP endpoint is contacted.
                    Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("Synthetic")
                        .body(raw.toResponseBody()).build()
                }.build())
            assertTrue(localPreferenceSnapshot().values.all { it.isEmpty() })
        }

        suspend fun restore(): Result = manager.restoreAccountBackupFile(picker, selected, { true }) { owner, current, operation ->
            current()
            // Native/profile absence is deliberately synthetic; actual manager, add-on, provider
            // writer lanes and physical auxiliary preference/outbox checks remain untouched.
            operation(object : AccountFileRestoreExternalExclusion.Reservation {
                override fun requireCurrent(original: AccountFileRestoreExternalExclusion.Owner) {
                    assertSame(owner, original)
                    current()
                }
                override fun requireLocalAbsence(original: AccountFileRestoreExternalExclusion.Owner, scope: VortxAccountScope) {
                    requireCurrent(original)
                    assertEquals(VortxAccountScope("account.${f.account}", f.owner), scope)
                    onAbsence(++absenceChecks)
                    current()
                }
            })
            current()
        }

        fun snapshot() = (journal.readExisting(f.account, key) as Read.Present).snapshot

        fun localPreferenceSnapshot(): Map<String, Map<String, *>> = listOf(
            "vortx_settings", "vortx_sync_state", "vortx_sync_dirty", "vortx.addon.prefs", queue.fileName,
        ).associateWith { memory.getSharedPreferences(it, Context.MODE_PRIVATE).all.toMap() }

        fun createPendingSidecar(): Path {
            if (!Files.exists(outboxRoot, LinkOption.NOFOLLOW_LINKS)) Files.createDirectory(outboxRoot, PRIVATE_DIRECTORY)
            val account = outboxRoot.resolve(MessageDigest.getInstance("SHA-256").digest(f.account.toByteArray(Charsets.US_ASCII))
                .joinToString("") { "%02x".format(java.util.Locale.ROOT, it.toInt() and 255) })
            if (!Files.exists(account, LinkOption.NOFOLLOW_LINKS)) Files.createDirectory(account, PRIVATE_DIRECTORY)
            val epoch = account.resolve("e-11")
            if (!Files.exists(epoch, LinkOption.NOFOLLOW_LINKS)) Files.createDirectory(epoch, PRIVATE_DIRECTORY)
            return Files.createFile(epoch.resolve("trakt.v1.stage"), PRIVATE_FILE).also { Files.write(it, byteArrayOf(19, 37)) }
        }

        private fun enterActualNetworkAttempt(request: Request) {
            val type = manager.javaClass.declaredClasses.single { it.simpleName == "FileRestoreNetworkAttempt" }
            @Suppress("UNCHECKED_CAST")
            val attempt = checkNotNull(request.tag(type as Class<Any>))
            val enter = type.getDeclaredMethod("enter").apply { isAccessible = true }
            fun invoke() {
                try { enter.invoke(attempt) }
                catch (wrapped: InvocationTargetException) { throw checkNotNull(wrapped.cause) }
            }
            invoke()
            assertTrue(runCatching { invoke() }.exceptionOrNull() is IOException)
            rejectedNetworkReplays++
        }

        override fun close() {
            scope.cancel()
            NativeProviderAccess.unbindForTest()
            assertSame(originalBinding, field(NativeProviderAccess, "binding"))
            session.dataKey.fill(0)
            key.fill(0)
            submission?.fill(0)
            selected.fill(0)
            source.fill(0)
            head.fill(0)
        }
    }

    private fun isolated(test: suspend () -> Unit) = withIsolatedPristinePreferenceFence { runBlocking { test() } }

    private fun emptyCredentialState(store: Any) {
        assertTrue(store is FailClosedCredentialStore)
        setField(store, "state", FailClosedCredentialState(object : CredentialBackend {
            override fun string(key: String): String? = error("Restore must use existing-only inspection")
            override fun readExistingForRestore(keys: List<String>): Map<String, String?> = keys.associateWith { null }
            override fun write(values: Map<String, String?>): Boolean = error("Restore must not write credentials")
        }))
    }

    private fun field(owner: Any, name: String): Any? = declaredField(owner, name).get(owner)
    private fun setField(owner: Any, name: String, value: Any?) = declaredField(owner, name).set(owner, value)
    private fun declaredField(owner: Any, name: String) = owner.javaClass.getDeclaredField(name).apply { isAccessible = true }
    private fun replaceLazy(owner: Any, name: String, value: Any) = setField(owner, name + "\$delegate", lazyOf(value))
    private fun metadata(path: Path): ProviderRetryOutbox.UnixMetadata {
        val attributes = Files.readAttributes(path, "unix:uid,gid,mode", LinkOption.NOFOLLOW_LINKS)
        fun number(name: String) = (attributes.getValue(name) as Number).toInt()
        return ProviderRetryOutbox.UnixMetadata(number("uid"), number("gid"), number("mode"))
    }

    private companion object {
        val PRIVATE_DIRECTORY = PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rwx------"))
        val PRIVATE_FILE = PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rw-------"))
    }
}
