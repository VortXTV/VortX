package com.vortx.android.engine

import com.vortx.android.sync.NativeAccountReadCapture
import com.vortx.android.sync.NativePlaylistAccountProducer
import com.vortx.android.sync.NativePlaylistAccountWrite
import com.vortx.android.sync.SessionOwnerSnapshot
import com.vortx.android.xperience.XperienceCollections
import com.vortx.android.xperience.XperienceImportNamespace
import java.util.UUID
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** Authored UNRUN controls over real domain/Session/coordinator/composer bodies. The in-memory
 * checkpoint, native projection and authenticated mount opening are EXPLICIT controlled fixtures,
 * not a JVM/customer repro, native reducer, real GET, credential, encryption or device proof. */
class NativeXperienceWriteTest {
    private val scope = VortxAccountScope("account.00000000-0000-0000-0000-000000000123", "11111111-1111-4111-8111-111111111111")
    private val account = SessionOwnerSnapshot.Account("00000000-0000-0000-0000-000000000123", 4)
    private val actor = "00000000-0000-0000-0000-000000000001"
    private val namespace = UUID.fromString("00000000-0000-0000-0000-000000000101")
    private fun b(value: String) = value.toByteArray(Charsets.UTF_8)
    private fun doc(title: String = "Original", number: String = "1.0") = XperienceCollections.parse(b(
        """[{"id":"c","title":"$title","folders":[],"future":{"n":$number,"z":-0.0}}]"""))
    private fun edit(id: UUID = namespace, title: String = "Original") = XperienceImportNamespace.append(doc(title), "Saved", id)
    private fun rawLocal(counter: String = "7e0", fields: Map<String, ByteArray> = emptyMap()): ByteArray {
        val values = OHJson.Obj(); fields.forEach { (key, value) -> values.set(key, value) }
        val document = OHJson.Obj(NativeHostPreferences.empty(scope).toString().toByteArray())
        document.set("profiles", OHJson.Obj().set(scope.ownerProfileID,
            OHJson.Obj().set("fields", values.encoded()).encoded()).encoded())
        return OHJson.Obj().set("actor", OHJson.quote(actor)).set("counter", b(counter)).set("pending", b("false"))
            .set("document", document.encoded()).set("futureLocal", b("{\"n\":9007199254740992.1,\"zero\":-0}"))
            .encoded()
    }
    private fun saved(local: ByteArray, field: String = XperienceImportNamespace.field(namespace)) =
        XperienceImportNamespace.read(field, checkNotNull(NativeXperienceWrite.register(local, scope.ownerProfileID, field)))
    private fun fails(block: () -> Unit) { assertThrows(Exception::class.java, block) }

    @Test fun appendAndReplacementPreserveRawLocalAndUnknownValueMembers() {
        val original = rawLocal()
        val first = NativeXperienceWrite.replace(scope, scope.ownerProfileID, original, NativeXperienceWrite.Change.edit(edit()))
        val event = OHJson.Obj(first.register()); val value = event.obj("value").set("futureValue", b("[9007199254740992.1,-0.0,1e0]"))
        val retained = rawLocal("8", mapOf(edit().field to event.set("value", value.encoded()).encoded()))
        val baseline = saved(retained)
        val replacement = baseline.replacement(doc("Refreshed", "2.0"), "Renamed", baseline.bindings)
        val after = NativeXperienceWrite.replace(scope, scope.ownerProfileID, retained, NativeXperienceWrite.Change.edit(replacement))
        assertArrayEquals(value.raw("futureValue"), OHJson.Obj(after.register()).obj("value").raw("futureValue"))
        assertArrayEquals(OHJson.Obj(retained).raw("futureLocal"), OHJson.Obj(after.local()).raw("futureLocal"))
        assertArrayEquals(original, rawLocal())
        assertEquals("Refreshed", saved(after.local()).document.collections.single().title)
        assertEquals(9L, NativeRawHostPreferences.exactClock(OHJson.Obj(after.local()).raw("counter")))
    }

    @Test fun pureRebindAndRefreshUseSavedReplacementAndRetainUnknowns() {
        val collection = XperienceCollections.parse(b("""[{"id":"c","title":"C","folders":[{"id":"f","title":"F","sources":[{"provider":"addon","addonId":"org.example","type":"movie","catalogId":"popular","url":"https://untrusted.invalid"}]}]}]"""))
        val append = XperienceImportNamespace.append(collection, "Saved", namespace)
        val first = NativeXperienceWrite.replace(scope, scope.ownerProfileID, rawLocal(), NativeXperienceWrite.Change.edit(append))
        val original = saved(first.local()); val source = original.document.collections.single().folders.single().sources.single()
        val mapping = XperienceImportNamespace.Binding("org.example", "a".repeat(64))
        val rebind = original.replacement(original.document, original.label, mapOf(source.semanticDigest to mapping))
        val after = NativeXperienceWrite.replace(scope, scope.ownerProfileID, first.local(), NativeXperienceWrite.Change.edit(rebind))
        assertEquals(mapping, saved(after.local()).bindings[source.semanticDigest])
        assertArrayEquals(original.document.raw(), saved(after.local()).document.raw())
        // Stored mappings remain data. No installed-catalog/fetch authority is created here.
    }

    @Test fun deleteRequiresSupportedOriginalAndWritesAnExactTombstone() {
        val first = NativeXperienceWrite.replace(scope, scope.ownerProfileID, rawLocal(), NativeXperienceWrite.Change.edit(edit()))
        val after = NativeXperienceWrite.replace(scope, scope.ownerProfileID, first.local(), NativeXperienceWrite.Change.delete(saved(first.local())))
        assertArrayEquals(b("null"), OHJson.Obj(after.register()).raw("value"))
        assertArrayEquals(OHJson.Obj(first.local()).raw("futureLocal"), OHJson.Obj(after.local()).raw("futureLocal"))
        fails { NativeXperienceWrite.Change.delete(saved(after.local())) }
        fails { NativeXperienceWrite.replace(scope, scope.ownerProfileID, after.local(), NativeXperienceWrite.Change.edit(edit())) }
    }

    @Test fun unknownFutureRecordsAreReadOnlyRawObservationsAndCannotBecomeABaseline() {
        val future = b("""{"clock":7e0,"actor":"$actor","value":{"schemaVersion":99,"opaque":[9007199254740992.1,-0]}}""")
        val raw = rawLocal(fields = mapOf(edit().field to future))
        val observed = NativeXperienceWrite.fields(raw, scope.ownerProfileID)
        assertArrayEquals(future, observed.getValue(edit().field))
        observed.getValue(edit().field).fill(0)
        assertArrayEquals(future, NativeXperienceWrite.register(raw, scope.ownerProfileID, edit().field))
        fails { saved(raw) }
        fails { NativeXperienceWrite.replace(scope, scope.ownerProfileID, raw, NativeXperienceWrite.Change.edit(edit())) }
    }

    @Test fun exactClockAdmissionRejectsFractionRangeRegressionAndExhaustion() {
        for (counter in listOf("9007199254740990.1", "9007199254740992", "-1", "1e-1"))
            fails { NativeXperienceWrite.requireClocks(rawLocal(counter)) }
        // Controlled exact raw barrier. Android/JVM Number projection behavior is not assumed.
        assertEquals(7L, NativeXperienceWrite.requireClocks(rawLocal("7.0")))
        assertEquals(7L, NativeXperienceWrite.requireClocks(rawLocal("7e0")))
        fails { NativeXperienceWrite.replace(scope, scope.ownerProfileID, rawLocal(NativeHostPreferences.MAX_CLOCK.toString()), NativeXperienceWrite.Change.edit(edit())) }
        val fractional = b("""{"clock":6.000000000000000001,"actor":"$actor","value":null}""")
        fails { NativeXperienceWrite.requireClocks(rawLocal("7", mapOf(edit().field to fractional))) }
        val future = b("""{"clock":8,"actor":"$actor","value":null}""")
        fails { NativeXperienceWrite.requireClocks(rawLocal("7", mapOf(edit().field to future))) }
    }

    @Test fun onceGateRefusesMissingSwallowedFailureDuplicateAndLateCallbacks() {
        var writes = 0; var late: (() -> Unit)? = null
        fails { NativeXperienceWrite.admitOnce({ late = it }) { writes++ } }
        fails { late!!() }; assertEquals(0, writes)
        fails { NativeXperienceWrite.admitOnce({ callback -> try { callback() } catch (_: Exception) {} }) { error("prewrite authority failure") } }
        fails { NativeXperienceWrite.admitOnce({ callback -> callback(); try { callback() } catch (_: Exception) {} }) { writes++ } }
        assertEquals(1, writes)
        NativeXperienceWrite.admitOnce({ it() }) { writes++ }; assertEquals(2, writes)
    }

    @Test fun onceGateRefusesCrossThreadCallbackWithBoundedOwnedCleanup() {
        var writes = 0; var worker: Thread? = null
        try {
            fails { NativeXperienceWrite.admitOnce({ callback ->
                worker = Thread { try { callback() } catch (_: Exception) {} }.apply { isDaemon = true; start() }
                worker!!.join(1_000)
                check(!worker!!.isAlive) { "Synthetic callback did not finish within bound" }
            }) { writes++ } }
            assertEquals(0, writes)
        } finally {
            worker?.let { it.interrupt(); it.join(1_000); assertFalse("Synthetic worker survived cleanup", it.isAlive) }
        }
    }

    private fun snapshot(local: ByteArray) = OHJson.Obj().set("activeProfileId", OHJson.quote(scope.ownerProfileID))
        .set("roster", b("""{"profiles":{"${scope.ownerProfileID}":{"id":"${scope.ownerProfileID}","name":"Owner","owner":true,"deleted":false,"addons":"share_primary","account":{"kind":"local_only"},"settings":{"disabledAddons":[]}}}}"""))
        .set("libraries", b("""{"${scope.ownerProfileID}":{}}"""))
        .set("nativeSync", b("""{"schemaVersion":5,"scope":"${scope.accountID}","ownerProfileId":"${scope.ownerProfileID}","profiles":{},"addons":{},"libraries":{},"watches":{}}"""))
        .set("nativeHostPreferenceState", local)
        .set("hostProfilePreferences", b("""{"${scope.ownerProfileID}":{"id":"${scope.ownerProfileID}","name":"Owner"}}"""))

    /** Simple projection transport, deliberately no reducer. Production Session/fork/CAS bodies
     * run against real objects, but controlled protocol output is never called real JNI proof. */
    private inner class Fixture(val initialLocal: ByteArray = rawLocal(), val sourceHost: ByteArray? = null) : AutoCloseable {
        var current = true; var epoch = 1; var writes = 0; var previews = 0
        var onPreview: (() -> Unit)? = null
        var provider = JSONObject(); var pending = JSONObject()
        var providerEpoch = 0; var settingsEpoch = 0
        var retainedPreview: VortxNativeSession.XperienceHostPreview? = null
        var lastCandidate: ByteArray? = null
        private val issuer = Any()
        var read = NativeCheckpointRead(OHJson.utf8(snapshot(initialLocal).encoded()), issuer, scope, 0, byteArrayOf(0))
        private var generation = 0L
        val store = object : VortxCheckpointStore {
            override val supportsCheckpointAuthority = true
            override fun read(scope: VortxAccountScope) = read.plaintext
            override fun captureCheckpoint(scope: VortxAccountScope) = read
            override fun requireCurrentCheckpoint(scope: VortxAccountScope, expected: NativeCheckpointRead) { check(expected === read) }
            override fun commit(scope: VortxAccountScope, snapshot: String) { generation++; read = NativeCheckpointRead(snapshot, issuer, scope, generation, byteArrayOf(generation.toByte())) }
            override fun compareAndCommitCheckpoint(scope: VortxAccountScope, expected: NativeCheckpointRead, snapshot: String): NativeCheckpointRead {
                requireCurrentCheckpoint(scope, expected); writes++; commit(scope, snapshot); return read
            }
        }
        val bindings = object : VortxRuntimeBindings {
            var next = 1L; val states = mutableMapOf<Long, String>()
            override fun create(ownerId: String, ownerName: String) = error("Must hydrate controlled original")
            override fun hydrate(snapshot: String) = next++.also { states[it] = snapshot }
            override fun dispatch(handle: Long, action: String) = "{\"ok\":true}"
            override fun resolve(handle: Long, request: String) = error("No resource/registry request")
            override fun state(handle: Long) = states.getValue(handle)
            override fun delta(handle: Long) = state(handle)
            override fun free(handle: Long) { states.remove(handle) }
        }
        val transport = object : VortxResourceTransport {
            override fun makeCancellation(): VortxResourceCancellation = error("No resource request")
            override fun load(requestJson: String, cancellation: VortxResourceCancellation): String = error("No network")
        }
        val session = VortxNativeSession.open(scope, "Owner", bindings, store, transport, isAccountCurrent = { current })
        val raw = OHJson.Obj().set("nativeSync", snapshot(initialLocal).raw("nativeSync"))
            .set("nativeHostPreferences", sourceHost ?: NativeRawHostPreferences.document(initialLocal))
            .set("futureRoot", b("{\"n\":9007199254740992.1,\"z\":-0}"))
            .set("apiKeys", b("{\"unknownProviderSibling\":1.0}")).encoded()
        val coordinator = NativeAccountCoordinator(bindings, store, { transport }, { it == account && current }, { it() }, {},
            captureOwnAccountAdmission = { expected ->
                val captured = epoch
                val admission: (() -> Boolean) -> Boolean = { action -> expected == account && current && epoch == captured && action() }
                admission
            })
        init {
            // Controlled mount only: this is NOT an authenticated GET capability receipt.
            val mountedClass = NativeAccountCoordinator::class.java.declaredClasses.single { it.simpleName == "Mounted" }
            val constructor = mountedClass.declaredConstructors.single().apply { isAccessible = true }
            val mounted = constructor.newInstance(account, session)
            val capture = NativeAccountReadCapture.fromAuthenticatedPull(account, 1, account.id, account.generation, 1, raw)
            mountedClass.getDeclaredMethod("retain", NativeAccountReadCapture::class.java, ByteArray::class.java)
                .apply { isAccessible = true }
                .invoke(mounted, capture, snapshot(initialLocal).raw("nativeSync"))
            val field = NativeAccountCoordinator::class.java.getDeclaredField("mounted").apply { isAccessible = true }
            @Suppress("UNCHECKED_CAST")
            (field.get(coordinator) as java.util.concurrent.atomic.AtomicReference<Any?>).set(mounted)
            coordinator.installPlaylistAccountProducer(NativePlaylistAccountProducer {
                val originalProvider = providerEpoch; val originalSettings = settingsEpoch
                val capturedGlobals = pending.toString()
                object : NativePlaylistAccountWrite {
                    override fun pendingGlobalValues() = JSONObject(capturedGlobals)
                    override fun commitCandidate(raw: ByteArray, originalNativeProjection: ByteArray, candidateNative: ByteArray, candidateHost: ByteArray, commit: () -> Unit) = error("Playlist path forbidden")
                    override fun commitXperienceCandidate(raw: ByteArray, originalNativeProjection: ByteArray, candidateNative: ByteArray,
                        host: VortxNativeSession.XperienceHostPreview, commit: () -> Unit) {
                        previews++; retainedPreview = host; onPreview?.also { onPreview = null }?.invoke()
                        check(providerEpoch == originalProvider && settingsEpoch == originalSettings) { "Controlled full-family witness changed" }
                        lastCandidate = NativePlaylistAccountComposer.composeXperience(raw, originalNativeProjection, candidateNative, host, provider)
                        commit()
                    }
                    override fun close() {}
                }
            })
        }
        fun opening() = coordinator.captureXperienceProfile().getOrThrow()
        fun operation(change: NativeXperienceWrite.Change): VortxNativeSession.XperienceOperation {
            val read = session.read()
            return session.captureXperienceOperation(read.owner, session.xperienceContext(read), change, true)
        }
        override fun close() { coordinator.retire() }
    }

    @Test fun genericGatewayPersistsReadsBackAndPublishesOnlyOriginalSnapshot() = runBlocking {
        Fixture().use { fixture ->
            val opening = fixture.opening()
            val accepted = fixture.coordinator.writeXperience(opening.target, edit()).getOrThrow()
            assertEquals(1, fixture.writes); assertEquals(1, fixture.previews)
            assertEquals("Saved", XperienceImportNamespace.read(edit().field, accepted.registers().getValue(edit().field)).label)
            var publications = 0
            assertFalse(fixture.coordinator.publishXperienceIfCurrent(opening) { publications++ })
            assertTrue(fixture.coordinator.publishXperienceIfCurrent(accepted) { publications++ }); assertEquals(1, publications)
            fails { fixture.retainedPreview!!.withRawHost(scope) {} }
        }
    }

    @Test fun pendingNamespaceAThenBNeverRoundTripsAThroughOldGetDto() = runBlocking {
        val originalA = NativeXperienceWrite.replace(scope, scope.ownerProfileID, rawLocal(), NativeXperienceWrite.Change.edit(edit())).local()
        Fixture(originalA).use { fixture ->
            val target = fixture.opening().target
            val a = fixture.opening()
            val old = XperienceImportNamespace.read(edit().field, a.registers().getValue(edit().field))
            fixture.coordinator.writeXperience(target, old.replacement(doc("Changed", "2.0"), old.label, old.bindings)).getOrThrow()
            val pendingA = fixture.session.xperienceFields(fixture.session.read().owner).getValue(edit().field)
            val second = edit(UUID.fromString("00000000-0000-0000-0000-000000000102"), "B")
            fixture.coordinator.writeXperience(target, second).getOrThrow()
            val candidate = NativeOwnerHistoryAccount(checkNotNull(fixture.lastCandidate))
            val fields = OHJson.Obj(checkNotNull(candidate.raw("nativeHostPreferences"))).obj("profiles").obj(scope.ownerProfileID).obj("fields")
            assertArrayEquals(pendingA, fields.raw(edit().field)); assertNotNull(fields[second.field])
            assertArrayEquals(OHJson.Obj(fixture.raw).raw("futureRoot"), candidate.raw("futureRoot"))
            assertArrayEquals(b("1.0"), OHJson.Obj(checkNotNull(candidate.raw("apiKeys"))).raw("unknownProviderSibling"))
            assertEquals(2, fixture.writes)
        }
    }

    @Test fun priorProgressKeepsTargetButPreparedOperationRejectsLaterCheckpointAndAba() = runBlocking {
        Fixture().use { fixture ->
            val target = fixture.opening().target
            fixture.session.dispatch(emptyList(), fixture.session.read().owner, progressOnly = true)
            assertTrue(fixture.coordinator.xperienceTargetIsCurrent(target))
            fixture.coordinator.writeXperience(target, edit()).getOrThrow()
            val operation = fixture.operation(NativeXperienceWrite.Change.edit(edit(UUID.randomUUID())))
            val before = fixture.writes
            fixture.session.dispatch(emptyList(), fixture.session.read().owner, progressOnly = true)
            // Replacing an identical plaintext still advances the concrete checkpoint witness.
            fixture.store.commit(scope, checkNotNull(fixture.store.read(scope)))
            fails { fixture.session.dispatchXperience(operation, JSONObject(), { _, _, commit -> commit() }, { _, _, _ -> error("No typed path") }, {}) }
            assertEquals(before, fixture.writes); operation.close()
        }
    }

    @Test fun revokeAccountSwitchAndOriginalAdmissionAbaNeverWrite() = runBlocking {
        for (kind in listOf("retire", "account", "epoch")) Fixture().use { fixture ->
            val target = fixture.opening().target
            when (kind) {
                "retire" -> fixture.coordinator.retireXperienceTarget(target)
                "account" -> fixture.current = false
                else -> { fixture.epoch++; fixture.epoch++ }
            }
            assertTrue(fixture.coordinator.writeXperience(target, edit()).isFailure)
            assertEquals(0, fixture.writes)
        }
    }

    @Test fun providerSettingsAndBudgetRejectBeforeGenericWrite() = runBlocking {
        for (kind in listOf("provider", "settings", "budget")) Fixture().use { fixture ->
            fixture.pending = JSONObject().put("stremiox.autoSkip", true)
            fixture.provider = JSONObject().put("nativeProviderCredentials", JSONObject().put("future", "x".repeat(6_000_000)))
            if (kind != "budget") fixture.provider = JSONObject()
            fixture.onPreview = { when (kind) { "provider" -> fixture.providerEpoch++; "settings" -> fixture.settingsEpoch++ } }
            val result = fixture.coordinator.writeXperience(fixture.opening().target, edit())
            assertTrue(result.isFailure); assertEquals(0, fixture.writes)
            assertFalse(fixture.session.requiresRecovery())
        }
    }

    @Test fun staleSavedCasAndRevocationDuringPreviewNeverWriteAReplacement() = runBlocking {
        val initial = NativeXperienceWrite.replace(scope, scope.ownerProfileID, rawLocal(), NativeXperienceWrite.Change.edit(edit())).local()
        Fixture(initial).use { fixture ->
            val target = fixture.opening().target
            val old = saved(initial)
            fixture.coordinator.writeXperience(target, old.replacement(doc("New"), old.label, old.bindings)).getOrThrow()
            assertTrue(fixture.coordinator.writeXperience(target, old.replacement(doc("Stale"), old.label, old.bindings)).isFailure)
            assertEquals(1, fixture.writes)
        }
        Fixture().use { fixture ->
            val target = fixture.opening().target
            fixture.onPreview = { fixture.coordinator.retireXperienceTarget(target) }
            assertTrue(fixture.coordinator.writeXperience(target, edit()).isFailure)
            assertEquals(0, fixture.writes); assertFalse(fixture.session.requiresRecovery())
        }
    }

    @Test fun registryMutationRetiresTargetAndProgressDuringPreparedPreviewCannotRebase() = runBlocking {
        Fixture().use { fixture ->
            val target = fixture.opening().target
            // Controlled projection accepts this command; the real Session's explicit registry
            // action invalidates the captured owner even when this fixture returns no state delta.
            fixture.session.dispatch(listOf(JSONObject().put("type", "install_addon")), fixture.session.read().owner)
            assertFalse(fixture.coordinator.xperienceTargetIsCurrent(target))
            assertTrue(fixture.coordinator.writeXperience(target, edit()).isFailure); assertEquals(0, fixture.writes)
        }
        Fixture().use { fixture ->
            val target = fixture.opening().target
            fixture.onPreview = { fixture.session.dispatch(emptyList(), fixture.session.read().owner, progressOnly = true) }
            assertTrue(fixture.coordinator.writeXperience(target, edit()).isFailure)
            assertEquals(0, fixture.writes); assertFalse(fixture.session.requiresRecovery())
        }
    }

    @Test fun originalOperationRejectsWrongScopeAndUnattestedWholeHost() {
        Fixture().use { fixture ->
            val operation = fixture.operation(NativeXperienceWrite.Change.edit(edit()))
            val fake = VortxNativeSession.XperienceHostPreview(Any(), operation, NativeRawHostPreferences.document(rawLocal()))
            fails { fake.withRawHost(scope) {} }
            fails { fake.withRawHost(scope.copy(accountID = "other")) {} }
            fake.close(); operation.close(); assertEquals(0, fixture.writes)
        }
    }

    @Test fun genuineWholeHostPreviewRejectsWrongScopeAndIncludesPendingGlobalsOnlyForBudget() = runBlocking {
        Fixture().use { fixture ->
            fixture.pending = JSONObject().put("stremiox.autoSkip", true)
            fixture.onPreview = { fails { fixture.retainedPreview!!.withRawHost(scope.copy(accountID = "other")) {} } }
            fixture.coordinator.writeXperience(fixture.opening().target, edit()).getOrThrow()
            val candidate = NativeOwnerHistoryAccount(checkNotNull(fixture.lastCandidate))
            val globals = OHJson.Obj(checkNotNull(candidate.raw("nativeHostPreferences"))).obj("globals").obj("fields")
            assertArrayEquals(b("true"), globals.obj("stremiox.autoSkip").raw("value"))
            val durable = OHJson.Obj(checkNotNull(fixture.store.read(scope)).toByteArray()).obj("nativeHostPreferenceState")
            assertNull(durable.obj("document").obj("globals").obj("fields")["stremiox.autoSkip"])
        }
    }

    @Test fun sourceUnknownSiblingsMustBeRetainedAndTruePrecisionContradictionsRefuse() = runBlocking {
        val field = "future.raw"
        fun local(number: String) = rawLocal(fields = mapOf(field to b("""{"clock":7e0,"actor":"$actor","value":{"n":$number}}""")))
        Fixture(local("9007199254740992.1")).use { fixture ->
            fixture.coordinator.writeXperience(fixture.opening().target, edit()).getOrThrow()
            val host = OHJson.Obj(checkNotNull(NativeOwnerHistoryAccount(checkNotNull(fixture.lastCandidate)).raw("nativeHostPreferences")))
            assertArrayEquals(OHJson.Obj(local("9007199254740992.1")).obj("document").obj("profiles").obj(scope.ownerProfileID).obj("fields").raw(field),
                host.obj("profiles").obj(scope.ownerProfileID).obj("fields").raw(field))
        }
        // Deliberately controlled lossy mount projection, not a natural JVM JSONObject repro.
        // This reaches the source-host subset barrier with adjacent raw precision disagreement.
        Fixture(local("9007199254740992"), NativeRawHostPreferences.document(local("9007199254740992.1"))).use { fixture ->
            val result = fixture.coordinator.writeXperience(fixture.opening().target, edit())
            assertTrue(result.isFailure); assertEquals("Conflicting full raw host preference event", result.exceptionOrNull()?.message)
            assertEquals(0, fixture.writes); assertFalse(fixture.session.requiresRecovery())
        }
        Fixture(rawLocal(), NativeRawHostPreferences.document(local("1.0"))).use { fixture ->
            val result = fixture.coordinator.writeXperience(fixture.opening().target, edit())
            assertTrue(result.isFailure); assertEquals("Source host register was omitted", result.exceptionOrNull()?.message)
            assertEquals(0, fixture.writes)
        }
    }

    @Test fun genericDtoAndPlaylistRoutesStillRejectXperience() {
        val change = JSONObject().put(edit().field, JSONObject(OHJson.utf8(edit().value())))
        fails { NativeHostPreferences.recordProfileFields(scope, JSONObject(OHJson.utf8(rawLocal())), scope.ownerProfileID, change) }
        Fixture().use { fixture ->
            fails { fixture.session.dispatchBudgetedPlaylist(fixture.session.read().owner, change, {}) }
            assertEquals(0, fixture.writes)
        }
    }
}
