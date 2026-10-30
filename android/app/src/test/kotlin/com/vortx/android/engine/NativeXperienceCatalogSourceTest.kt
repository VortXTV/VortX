package com.vortx.android.engine

import com.vortx.android.sync.NativeAccountReadCapture
import com.vortx.android.sync.NativePlaylistAccountProducer
import com.vortx.android.sync.SessionOwnerSnapshot
import com.vortx.android.xperience.XperienceCollections
import com.vortx.android.xperience.XperienceAddonBinding
import com.vortx.android.xperience.XperienceImportNamespace
import java.nio.file.Files
import java.nio.file.Paths
import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** Authored UNRUN actual app coordinator/Session/adapter/repository bodies over a CONTROLLED
 * in-memory checkpoint, mount, native projection and resource response. No real GET, encryption,
 * native reducer, credential store, private SDK, TLS, Android or device result is implied. */
class NativeXperienceCatalogSourceTest {
    private val owner = "11111111-1111-4111-8111-111111111111"
    private val other = "22222222-2222-4222-8222-222222222222"
    private val scope = VortxAccountScope("account.00000000-0000-0000-0000-000000000123", owner)
    private val account = SessionOwnerSnapshot.Account("00000000-0000-0000-0000-000000000123", 1)
    private val namespace = UUID.fromString("10000000-0000-4000-8000-000000000001")
    private val configuredURL = "https://configured.fixture.invalid/selected/manifest.json?configuration=opaque"
    private fun installedBinding(url: String = configuredURL): XperienceImportNamespace.Binding {
        val candidate = XperienceAddonBinding.Candidate.fromInstalled(XperienceAddonBinding.InstalledDescriptor("fixture", url,
            listOf(XperienceAddonBinding.Catalog("movie", "popular", acceptsGenre = true, requiresGenre = false, supportsSkip = true))))
        return XperienceImportNamespace.Binding(candidate.manifestID, candidate.transportFingerprint)
    }
    private fun b(text: String) = text.toByteArray(Charsets.UTF_8)
    private fun document() = XperienceCollections.parse(b("""[{"id":"c","title":"C","folders":[{"id":"f","title":"F","sources":[{"provider":"addon","addonId":"fixture","type":"movie","catalogId":"popular","genre":"None","url":"https://never-request-import.invalid"}]}]}]"""))
    private fun register(clock: Int = 1) = b("""{"clock":$clock,"actor":"00000000-0000-0000-0000-000000000001","value":null}""")
    private fun local(field: ByteArray? = null, otherField: ByteArray? = null): ByteArray {
        val host = OHJson.Obj(NativeHostPreferences.empty(scope).toString().toByteArray())
        val profiles = OHJson.Obj()
        profiles.set(owner, OHJson.Obj().set("fields", OHJson.Obj().also { if (field != null) it.set(XperienceImportNamespace.field(namespace), field) }.encoded()).encoded())
        profiles.set(other, OHJson.Obj().set("fields", OHJson.Obj().also { if (otherField != null) it.set(XperienceImportNamespace.field(namespace), otherField) }.encoded()).encoded())
        host.set("profiles", profiles.encoded())
        return OHJson.Obj().set("actor", OHJson.quote("00000000-0000-0000-0000-000000000001"))
            .set("counter", b("9")).set("pending", b("false")).set("document", host.encoded()).encoded()
    }
    private fun snapshot(raw: ByteArray): ByteArray = OHJson.Obj()
        .set("activeProfileId", OHJson.quote(owner))
        .set("roster", b("""{"profiles":{"$owner":{"id":"$owner","name":"Owner","owner":true,"deleted":false,"addons":"share_primary","account":{"kind":"local_only"},"settings":{"disabledAddons":[]},"parental":{"kids":true,"maturityCeiling":null}}}}"""))
        .set("libraries", b("""{"$owner":{}}"""))
        .set("nativeSync", b("""{"schemaVersion":5,"scope":"${scope.accountID}","ownerProfileId":"$owner","profiles":{},"addons":{},"libraries":{},"watches":{}}"""))
        .set("hostProfilePreferences", b("""{"$owner":{"id":"$owner","name":"Owner"}}"""))
        .set("nativeHostPreferenceState", raw).encoded()
    private inner class Fixture(initial: ByteArray = local()) : AutoCloseable {
        var auth = 1; var writes = 0; var stateReads = 0; var producerCalls = 0; var requests = 0
        var raw = initial.copyOf(); var onLoad: (() -> Unit)? = null
        val requestExtras = mutableListOf<List<Pair<String, String>>>()
        private val issuer = Any(); private var generation = 0L
        var checkpoint = NativeCheckpointRead(OHJson.utf8(snapshot(raw)), issuer, scope, 0, byteArrayOf(0))
        val store = object : VortxCheckpointStore {
            override val supportsCheckpointAuthority = true
            override fun read(scope: VortxAccountScope) = checkpoint.plaintext
            override fun captureCheckpoint(scope: VortxAccountScope) = checkpoint
            override fun commit(scope: VortxAccountScope, snapshot: String) {
                writes++; generation++; checkpoint = NativeCheckpointRead(snapshot, issuer, scope, generation, byteArrayOf(generation.toByte()))
            }
        }
        val transportURL = configuredURL
        var installedTransportURLs = listOf(transportURL)
        val bindings = object : VortxRuntimeBindings {
            var next = 1L; val states = mutableMapOf<Long, String>()
            private fun controlledAddon(url: String): JSONObject {
                val extras = JSONArray().put(JSONObject().put("name", "genre").put("isRequired", false))
                    .put(JSONObject().put("name", "skip").put("isRequired", false))
                val catalog = JSONObject().put("type", "movie").put("id", "popular").put("extra", extras)
                val manifest = JSONObject().put("id", "fixture").put("name", "Do not expose configured URL")
                    .put("catalogs", JSONArray().put(catalog))
                return JSONObject().put("transportUrl", url).put("manifest", manifest)
            }
            override fun create(ownerId: String, ownerName: String) = error("Hydrate controlled fixture only")
            override fun hydrate(snapshot: String) = next++.also { states[it] = snapshot }
            override fun dispatch(handle: Long, action: String) = "{\"ok\":true}"
            override fun resolve(handle: Long, request: String): String {
                val input = JSONObject(request)
                return when (input.getString("kind")) {
                    "installed_addons" -> JSONObject().put("kind", "installed_addons").put("profileId", input.getString("profileId"))
                        .put("addons", JSONArray().also { addons -> installedTransportURLs.forEach { addons.put(controlledAddon(it)) } }).toString()
                    "catalog" -> JSONObject().put("kind", "catalog").put("metas", JSONArray()).toString() // Controlled parental filter removes all.
                    else -> error("No other controlled resolver")
                }
            }
            override fun state(handle: Long): String { stateReads++; return states.getValue(handle) }
            override fun delta(handle: Long) = state(handle)
            override fun free(handle: Long) { states.remove(handle) }
        }
        val transport = object : VortxResourceTransport {
            override fun makeCancellation() = object : VortxResourceCancellation { override fun cancel() {}; override fun close() {} }
            override fun load(requestJson: String, cancellation: VortxResourceCancellation): String {
                requests++
                val wire = JSONObject(requestJson); val addon = wire.getJSONArray("addons").getJSONObject(0)
                assertEquals(transportURL, addon.getString("transportUrl"))
                assertFalse(requestJson.contains("never-request-import.invalid"))
                val extras = wire.getJSONObject("request").getJSONArray("extra")
                requestExtras += (0 until extras.length()).map { extras.getJSONArray(it).let { pair -> pair.getString(0) to pair.getString(1) } }
                onLoad?.also { onLoad = null }?.invoke()
                return JSONObject().put("kind", "resource_result").put("requestId", wire.getString("requestId"))
                    .put("generation", wire.getLong("generation")).put("request", wire.getJSONObject("request")).put("cancelled", false)
                    .put("groups", JSONArray().put(JSONObject().put("addonId", addon.getString("id")).put("status", "ready")
                        .put("content", JSONObject().put("metas", JSONArray()
                            .put(JSONObject().put("id", "tt1").put("type", "movie").put("name", "A"))
                            .put(JSONObject().put("id", "tt2").put("type", "movie").put("name", "B"))))).toString()
            }
        }
        val session = VortxNativeSession.open(scope, "Owner", bindings, store, transport)
        val coordinator = NativeAccountCoordinator(bindings, store, { transport }, { it == account }, { it() }, {},
            captureOwnAccountAdmission = { expected -> val original = auth; { action -> expected == account && auth == original && action() } })
        val jobs = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        val repo = NativeCatalogRepository(sessionProvider = { error("A post-await provider must not be sampled") })
        val access = NativeXperienceCatalogAccess(coordinator, repo, jobs)
        init {
            // Explicit controlled mount/read identity, NOT authenticated production GET proof.
            val mountedClass = NativeAccountCoordinator::class.java.declaredClasses.single { it.simpleName == "Mounted" }
            val mounted = mountedClass.declaredConstructors.single().apply { isAccessible = true }.newInstance(account, session)
            val source = OHJson.Obj().set("nativeSync", snapshot(raw).let { OHJson.Obj(it).raw("nativeSync") })
                .set("nativeHostPreferences", NativeRawHostPreferences.document(raw)).encoded()
            val read = NativeAccountReadCapture.fromAuthenticatedPull(account, 1, account.id, account.generation, 1, source)
            mountedClass.getDeclaredMethod("retain", NativeAccountReadCapture::class.java, ByteArray::class.java)
                .apply { isAccessible = true }.invoke(mounted, read, OHJson.Obj(snapshot(raw)).raw("nativeSync"))
            val field = coordinator.javaClass.getDeclaredField("mounted").apply { isAccessible = true }
            @Suppress("UNCHECKED_CAST")
            (field.get(coordinator) as java.util.concurrent.atomic.AtomicReference<Any?>).set(mounted)
            coordinator.installPlaylistAccountProducer(NativePlaylistAccountProducer { producerCalls++; error("Readonly path must not capture write producer") })
        }
        fun install(next: ByteArray) {
            synchronized(session) {
                val runtime = session.javaClass.getDeclaredField("runtime").apply { isAccessible = true }.get(session)
                val method = session.javaClass.declaredMethods.single { it.name == "commitCheckpoint" }.apply { isAccessible = true }
                method.invoke(session, OHJson.utf8(snapshot(next)), runtime, null, null, false, null, null, null)
                raw.fill(0); raw = next.copyOf()
            }
        }
        override fun close() { coordinator.retire(); jobs.coroutineContext[Job]?.cancel(); raw.fill(0) }
    }
    @Test fun rawObservationPreservesOtherProfileAndEqualProgressButNeverSurvivesSameProfileABA() {
        Fixture(local(register(), register())).use { f ->
            val token = f.session.captureXperienceObservation(f.session.read().owner)
            f.install(local(register(), register(2))); assertTrue(token.isCurrent())
            f.install(local(register(), register(2))); assertTrue(token.isCurrent()) // Equal raw/current checkpoint, not a new raw observation.
            f.install(local(register(2), register(2))); assertFalse(token.isCurrent())
            f.install(local(register(), register())); assertFalse(token.isCurrent())
            val fresh = f.session.captureXperienceObservation(f.session.read().owner); assertTrue(fresh.isCurrent()); fresh.close(); assertFalse(fresh.isCurrent())
        }
    }
    @Test fun originalOpeningHasNoNativeReadBeforeHopAndRefusesOriginalAuthRetirement() {
        Fixture().use { f ->
            val reads = f.stateReads; val stage = checkNotNull(f.access.stageOpening(f.access.callerEpoch()))
            assertEquals(reads, f.stateReads)
            f.auth++; assertTrue(f.access.open(stage).isFailure); assertEquals(0, f.producerCalls)
            stage.close()
        }
        Fixture().use { f ->
            val stage = checkNotNull(f.access.stageOpening(f.access.callerEpoch()))
            val owner = f.session.read().owner
            f.session.dispatch(emptyList(), owner, progressOnly = true)
            assertTrue(f.access.open(stage).isFailure) // Even benign progress during STAGED opening changes its exact update pin.
            stage.close()
        }
    }
    @Test fun actualAdapterKeepsGenreRawCursorConfiguredAddonAndRejectsExternalSavedMutation() = runBlocking {
        val doc = document()
        val key = XperienceAddonBinding.key(doc.collections.single().folders.single().sources.single())
        val edit = XperienceImportNamespace.append(doc, "Saved", namespace, mapOf(key to installedBinding()))
        val savedEvent = b("{\"clock\":1,\"actor\":\"00000000-0000-0000-0000-000000000001\",\"value\":" + String(edit.value()) + "}")
        Fixture(local(savedEvent)).use { f ->
            val stage = checkNotNull(f.access.stageOpening(f.access.callerEpoch()))
            val original = f.access.open(stage).getOrThrow(); stage.close()
            val saved = XperienceImportNamespace.read(edit.field, original.registers().getValue(edit.field))
            val lease = f.access.capture(original, saved).getOrThrow()
            try {
                val preview = f.access.preview(lease, saved.document, saved.label, saved.bindings, emptyMap()).getOrThrow()
                assertTrue(preview.rows.single().choices.all { !it.label.contains("http") && !it.label.contains("configuration") })
                val selected = f.access.select(lease, "c", "f", 0).getOrThrow()
                try {
                    val page = (f.access.load(selected, XperienceCatalogConsumerID.create()).getOrThrow() as NativeXperienceCatalogGateway.Outcome.Loaded).page
                    assertTrue(page.items.isEmpty()); assertEquals(2, page.rawCount); assertEquals(2, page.nextSkip); assertTrue(page.hasMore)
                    f.access.load(selected, XperienceCatalogConsumerID.create(), page.nextSkip).getOrThrow()
                    assertEquals(listOf("genre" to "None"), f.requestExtras[0])
                    assertEquals(listOf("genre" to "None", "skip" to "2"), f.requestExtras[1])
                    f.onLoad = { f.install(local(register(3))) }
                    assertTrue(f.access.load(selected, XperienceCatalogConsumerID.create()).isFailure)
                    assertFalse(f.access.locallyCurrent(lease))
                    assertEquals(0, f.producerCalls)
                } finally { selected.close() }
            } finally { lease.close(); f.access.discard(original) }
        }
    }
    @Test fun savedBindingsAndExplicitUnavailableStayDistinctFromFreshDefaults() = runBlocking {
        val doc = document(); val key = XperienceAddonBinding.key(doc.collections.single().folders.single().sources.single())
        val noMapping = XperienceImportNamespace.append(doc, "Unbound", namespace)
        val raw = b("{\"clock\":1,\"actor\":\"00000000-0000-0000-0000-000000000001\",\"value\":" + String(noMapping.value()) + "}")
        Fixture(local(raw)).use { f ->
            val stage = checkNotNull(f.access.stageOpening(f.access.callerEpoch()))
            val original = f.access.open(stage).getOrThrow(); stage.close()
            val saved = XperienceImportNamespace.read(noMapping.field, original.registers().getValue(noMapping.field))
            val savedLease = f.access.capture(original, saved).getOrThrow()
            val freshLease = f.access.capture(original).getOrThrow()
            try {
                val reviewed = f.access.preview(savedLease, doc, saved.label, saved.bindings, emptyMap()).getOrThrow()
                assertTrue(reviewed.bindings.isEmpty()); assertEquals(NativeXperienceCatalogGateway.SourceStatus.MAPPING_UNAVAILABLE, reviewed.rows.single().status)
                val selected = f.access.select(savedLease, "c", "f", 0).getOrThrow()
                try { assertEquals(NativeXperienceCatalogGateway.Outcome.Unresolved(NativeXperienceCatalogGateway.SourceStatus.MAPPING_UNAVAILABLE),
                    f.access.load(selected, XperienceCatalogConsumerID.create()).getOrThrow()); assertEquals(0, f.requests) }
                finally { selected.close() }
                val fresh = f.access.preview(freshLease, doc, "Fresh", emptyMap(), emptyMap(), allowDefaults = true).getOrThrow()
                assertEquals(installedBinding(), fresh.bindings[key]); assertEquals(NativeXperienceCatalogGateway.SourceStatus.RESOLVED, fresh.rows.single().status)
                val cleared = f.access.preview(freshLease, doc, "Fresh", fresh.bindings, mapOf(key to null), allowDefaults = true).getOrThrow()
                assertTrue(cleared.bindings.isEmpty()); assertEquals(NativeXperienceCatalogGateway.SourceStatus.MAPPING_UNAVAILABLE, cleared.rows.single().status)
                val staged = f.access.preview(freshLease, doc, "Renamed", cleared.bindings, emptyMap()).getOrThrow()
                assertTrue(staged.bindings.isEmpty()); assertEquals(NativeXperienceCatalogGateway.SourceStatus.MAPPING_UNAVAILABLE, staged.rows.single().status)
            } finally { savedLease.close(); freshLease.close(); f.access.discard(original) }
        }
        // Controlled current installed registry replacements: saved mappings never borrow a
        // different configured singleton, and an initial ambiguous registry never defaults.
        for (urls in listOf(listOf("https://configured.fixture.invalid/replaced/manifest.json"),
                listOf(configuredURL, "https://configured.fixture.invalid/second/manifest.json"))) {
            val bound = XperienceImportNamespace.append(doc, "Bound", namespace, mapOf(key to installedBinding()))
            val event = b("{\"clock\":1,\"actor\":\"00000000-0000-0000-0000-000000000001\",\"value\":" + String(bound.value()) + "}")
            Fixture(local(event)).use { f ->
                f.installedTransportURLs = urls
                val stage = checkNotNull(f.access.stageOpening(f.access.callerEpoch())); val original = f.access.open(stage).getOrThrow(); stage.close()
                val saved = XperienceImportNamespace.read(bound.field, original.registers().getValue(bound.field))
                val lease = f.access.capture(original, saved).getOrThrow(); val fresh = f.access.capture(original).getOrThrow()
                try {
                    if (urls.size == 1) {
                        val selected = f.access.select(lease, "c", "f", 0).getOrThrow()
                        try { assertEquals(NativeXperienceCatalogGateway.Outcome.Unresolved(NativeXperienceCatalogGateway.SourceStatus.MAPPING_UNAVAILABLE), f.access.load(selected, XperienceCatalogConsumerID.create()).getOrThrow()) }
                        finally { selected.close() }
                    } else {
                        val preview = f.access.preview(fresh, doc, "Ambiguous", emptyMap(), emptyMap(), allowDefaults = true).getOrThrow()
                        assertTrue(preview.bindings.isEmpty()); assertEquals(NativeXperienceCatalogGateway.SourceStatus.AMBIGUOUS, preview.rows.single().status)
                        val mismatch = f.access.preview(lease, doc, "Mismatch", mapOf(key to installedBinding("https://configured.fixture.invalid/missing/manifest.json")), emptyMap()).getOrThrow()
                        assertEquals(NativeXperienceCatalogGateway.SourceStatus.MAPPING_UNAVAILABLE, mismatch.rows.single().status)
                    }
                    assertEquals(0, f.requests)
                } finally { lease.close(); fresh.close(); f.access.discard(original) }
            }
        }
    }
    @Test fun uncertaintyAndCloseRevokeWhileTypedAndGenericRawInstallJoinsRemainExplicit() {
        Fixture().use { f ->
            val token = f.session.captureXperienceObservation(f.session.read().owner)
            f.session.javaClass.getDeclaredMethod("enterCheckpointUncertainty").apply { isAccessible = true }.invoke(f.session)
            assertFalse(token.isCurrent()); assertTrue(f.session.requiresRecovery())
        }
        Fixture().use { f -> val token = f.session.captureXperienceObservation(f.session.read().owner); f.session.close(); assertFalse(token.isCurrent()) }
        // STATIC source join control, not typed runtime proof. The real typed protocol remains
        // independently gated; this checks both actual assignments route through the tested body.
        val source = Files.readString(Paths.get("src/main/kotlin/com/vortx/android/engine/VortxNativeSession.kt"))
        assertTrue(source.contains("replaceRawHostPreferenceState(rawHost.copyOf())"))
        assertTrue(source.contains("replaceRawHostPreferenceState(acceptedRawHost)"))
        assertFalse(source.contains("rawNativeHostPreferenceState = rawHost.copyOf()"))
        assertFalse(source.contains("rawNativeHostPreferenceState = acceptedRawHost"))
    }
}
