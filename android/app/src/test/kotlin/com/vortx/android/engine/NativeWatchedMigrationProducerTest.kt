package com.vortx.android.engine

import com.vortx.android.profile.UserProfile
import com.vortx.android.security.PersistentCredentialAvailability
import com.vortx.android.security.PersistentCredentialSnapshot
import com.vortx.android.sync.SessionOwnerSnapshot
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.launch
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.cancel
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.util.Base64
import java.util.zip.Deflater
import java.math.BigDecimal
import java.security.MessageDigest

/**
 * Fake-network contract tests for the one-time legacy watched-bitfield producer.
 *
 * These tests deliberately keep the transport seam injected.  A metadata response is accepted
 * only when it is tied to the requested source/add-on/series and can be replayed from its exact raw
 * bytes; an unavailable provider remains pending evidence instead of becoming an empty watch list.
 */
class NativeWatchedMigrationProducerTest {
    private val fixedOwner = UserProfile(
        id = UserProfile.OWNER_ID,
        name = "Main",
        avatar = "🍿",
        isOwner = true,
    )
    private val customOwner = UserProfile(
        id = "00000000-0000-0000-0000-00000000BEEF",
        name = "Custom owner",
        avatar = "🎬",
        isOwner = true,
    )
    private val sharedProfile = UserProfile(
        id = "11111111-1111-1111-1111-111111111111",
        name = "Family",
        avatar = "🎞️",
    )
    private val ownProfile = sharedProfile.copy(
        id = "22222222-2222-2222-2222-222222222222",
        name = "Independent",
        usesOwnAccount = true,
    )
    @Test
    fun `fixed and custom owner rows plus profile overlay decode with explicit mark and reset clocks`() = runBlocking {
        for (owner in listOf(fixedOwner, customOwner)) {
            val scope = VortxAccountScope("account.${owner.id}", owner.id)
            val roster = listOf(owner, sharedProfile)
            val document = document(owner.id)
            val requests = mutableListOf<String>()
            val producer = fakeProducer(requests)

            val batch = producer.prepare(scope, document, roster, isCurrent = { true })

            assertTrue(batch.isComplete)
            assertEquals(2, requests.size)
            assertEquals(
                listOf("owner-series:1:1", "owner-series:1:2", "owner-series:1:3"),
                batch.videoIDs(
                    owner.id,
                    LegacyWatchedBitfieldMigrationEvidence.SourceRowLocator.AuthenticatedOwnerLibrary(0),
                    document.getJSONObject("vortx").getJSONArray("library").getJSONObject(0),
                ),
            )
            assertEquals(
                listOf("overlay-series:1:1", "overlay-series:1:3"),
                batch.videoIDs(
                    sharedProfile.id,
                    LegacyWatchedBitfieldMigrationEvidence.SourceRowLocator.AuthenticatedProfileLibrary(0),
                    document.getJSONObject("vortx").getJSONObject("byProfile").getJSONObject(sharedProfile.id)
                        .getJSONArray("library").getJSONObject(0),
                ),
            )

            val material = nativeLegacyMaterial(
                document,
                roster,
                null,
                accountScope = scope,
                watchedMigration = batch,
            )
            val ownerRows = watchRows(material, owner.id)
            val overlayRows = watchRows(material, sharedProfile.id)

            assertEquals(3, ownerRows.size)
            assertTrue(ownerRows.first { it.getString("videoId") == "owner-series:1:1" }.getBoolean("watched"))
            val ownerReset = ownerRows.single { it.getString("videoId") == "owner-series:1:2" }
            assertEquals(20.0, ownerReset.getDouble("markedAtMs"), 0.0)
            assertEquals(30.0, ownerReset.getDouble("resetAtMs"), 0.0)
            assertFalse(ownerReset.has("watched"))
            assertTrue(ownerRows.first { it.getString("videoId") == "owner-series:1:3" }.getBoolean("watched"))

            assertEquals(2, overlayRows.size)
            val overlayMarked = overlayRows.single { it.getString("videoId") == "overlay-series:1:1" }
            assertEquals(40.0, overlayMarked.getDouble("markedAtMs"), 0.0)
            assertFalse(overlayMarked.has("watched"))
            val overlayReset = overlayRows.single { it.getString("videoId") == "overlay-series:1:3" }
            assertEquals(50.0, overlayReset.getDouble("resetAtMs"), 0.0)
            assertFalse(overlayReset.has("watched"))
        }
    }

    @Test
    fun `stale admission and document mutation after metadata fetch fail closed`() = runBlocking {
        val roster = listOf(fixedOwner, sharedProfile)
        val scope = VortxAccountScope("account.fixture", fixedOwner.id)

        var current = true
        val staleProducer = fakeProducer { request ->
            current = false
            response(request)
        }
        assertFailure {
            staleProducer.prepare(scope, document(fixedOwner.id), roster, isCurrent = { current })
        }

        val mutableDocument = document(fixedOwner.id)
        val mutatingProducer = fakeProducer { request ->
            mutableDocument.getJSONObject("vortx").getJSONArray("library").getJSONObject(0)
                .put("name", "changed while suspended")
            response(request)
        }
        assertFailure {
            mutatingProducer.prepare(scope, mutableDocument, roster, isCurrent = { true })
        }
    }

    @Test
    fun `caller cancellation propagates and never publishes a partial batch`() = runBlocking {
        val entered = CompletableDeferred<Unit>()
        val producer = NativeWatchedMigrationProducer { request ->
            entered.complete(Unit)
            CompletableDeferred<Unit>().await()
            response(request)
        }
        val job = launch(start = CoroutineStart.LAZY) {
            producer.prepare(
                VortxAccountScope("account.fixture", fixedOwner.id),
                document(fixedOwner.id),
                listOf(fixedOwner, sharedProfile),
                isCurrent = { true },
            )
        }
        job.start()
        entered.await()
        job.cancel(CancellationException("test cancellation"))
        job.join()
        assertTrue(job.isCancelled)
    }

    @Test
    fun `successful final metadata callback after cancellation cannot return a batch`() = runBlocking {
        var returned = false
        val source = document(fixedOwner.id).also { it.getJSONObject("vortx").remove("byProfile") }
        val producer = NativeWatchedMigrationProducer { request ->
            currentCoroutineContext().cancel(CancellationException("cancel during successful callback"))
            response(request)
        }
        val task = launch {
            producer.prepare(VortxAccountScope("account.fixture", fixedOwner.id), source, listOf(fixedOwner), isCurrent = { true })
            returned = true
        }
        task.join()
        assertTrue(task.isCancelled)
        assertFalse(returned)
    }

    @Test
    fun `metadata unavailable and incomplete inventory retain original pending evidence`() = runBlocking {
        val roster = listOf(fixedOwner, sharedProfile)
        val scope = VortxAccountScope("account.fixture", fixedOwner.id)
        val pendingDocument = document(fixedOwner.id)

        val unavailable = NativeWatchedMigrationProducer { _ ->
            error("fixture provider unavailable")
        }.prepare(scope, pendingDocument, roster, isCurrent = { true })
        assertFalse(unavailable.isComplete)
        assertEquals(2, unavailable.pending().length())
        for (index in 0 until unavailable.pending().length()) {
            val pending = unavailable.pending().getJSONObject(index)
            assertEquals("episode_inventory_unavailable", pending.getString("reason"))
            assertEquals(1, pending.getInt("schemaVersion"))
            assertEquals(
                Base64.getEncoder().encodeToString(nativeWatchedDocumentSnapshot(pendingDocument)),
                pending.getString("sourceDocumentBase64"),
            )
            assertNotNull(pending.getJSONObject("row"))
        }
        assertEquals(0, unavailable.archive().length())
        assertFailure {
            nativeLegacyMaterial(
                document(fixedOwner.id),
                roster,
                null,
                accountScope = scope,
                watchedMigration = unavailable,
            )
        }

        val wrongAddonDocument = document(fixedOwner.id)
        wrongAddonDocument.getJSONObject("vortx").getJSONArray("addons").getJSONObject(0)
            .getJSONObject("manifest").put("resources", JSONArray().put("stream"))
        val wrongAddon = fakeProducer().prepare(scope, wrongAddonDocument, roster, isCurrent = { true })
        assertFalse(wrongAddon.isComplete)
        assertEquals(0, wrongAddon.archive().length())
        assertEquals(2, wrongAddon.pending().length())

        val incomplete = NativeWatchedMigrationProducer { request ->
            LegacyWatchedBitfieldMigrationEvidence.MetadataResponse(
                request,
                metadata(request.metaID, includeVideos = false),
            )
        }.prepare(scope, document(fixedOwner.id), roster, isCurrent = { true })
        assertFalse(incomplete.isComplete)
        assertEquals(2, incomplete.pending().length())
        assertEquals("episode_inventory_unavailable", incomplete.pending().getJSONObject(0).getString("reason"))
    }

    @Test
    fun `cold replay uses exact retained metadata bytes and rejects digest tampering`() = runBlocking {
        val roster = listOf(fixedOwner, sharedProfile)
        val scope = VortxAccountScope("account.fixture", fixedOwner.id)
        val source = document(fixedOwner.id)
        val firstRequests = mutableListOf<String>()
        val first = NativeWatchedMigrationProducer { request ->
            firstRequests += request.metaID
            LegacyWatchedBitfieldMigrationEvidence.MetadataResponse(request, metadata(request.metaID))
        }.prepare(scope, source, roster, isCurrent = { true })
        val archive = first.archive()
        assertEquals(listOf("owner-series", "overlay-series"), firstRequests)

        val secondRequests = mutableListOf<String>()
        val replay = NativeWatchedMigrationProducer { request ->
            secondRequests += request.metaID
            error("cold replay must not fetch metadata")
        }.prepare(scope, source, roster, retainedArchive = archive, isCurrent = { true })
        assertTrue(replay.isComplete)
        assertTrue(secondRequests.isEmpty())
        assertEquals(archive.toString(), replay.archive().toString())

        val freshMaterial = nativeLegacyMaterial(source, roster, null, accountScope = scope, watchedMigration = first)
        val coldMaterial = nativeLegacyMaterial(source, roster, null, accountScope = scope, watchedMigration = replay)
        assertEquals(freshMaterial.toString(), coldMaterial.toString())

        val tampered = JSONArray(archive.toString())
        tampered.getJSONObject(0).put("metadataResponseSha256", "0".repeat(64))
        assertFailure {
            NativeWatchedMigrationProducer { error("tampered archive must not fetch") }
                .prepare(scope, source, roster, retainedArchive = tampered, isCurrent = { true })
        }
    }

    @Test
    fun `independent source archive stays bound to the authenticated UID and exact source`() = runBlocking {
        val roster = listOf(fixedOwner, ownProfile)
        val sourceDocument = ownDocument()
        val source = ownSource(sourceDocument, ownProfile.id, "verified-streaming-uid")
        val scope = VortxAccountScope("account.00000000-0000-0000-0000-000000000456", fixedOwner.id)
        val requests = mutableListOf<String>()
        val first = NativeWatchedMigrationProducer { request ->
            requests += request.metaID
            response(request)
        }.prepare(scope, sourceDocument, roster, ownSources = listOf(source), isCurrent = { true })
        assertTrue(first.isComplete)
        assertEquals(listOf("own-library", "own-overlay"), requests)
        assertEquals(2, first.archive().length())
        for (index in 0 until first.archive().length()) {
            assertEquals("verified-streaming-uid", first.archive().getJSONObject(index).getString("verifiedStreamingUid"))
        }

        val foreignUID = JSONArray(first.archive().toString())
            .getJSONObject(0).put("verifiedStreamingUid", "foreign-streaming-uid")
        val replay = NativeWatchedMigrationProducer { error("foreign UID archive must not fetch") }
            .prepare(
                scope,
                sourceDocument,
                roster,
                ownSources = listOf(source),
                retainedArchive = JSONArray().put(foreignUID),
                isCurrent = { true },
            )
        assertFalse(replay.isComplete)
        assertFalse(replay.archive().toString().contains("foreign-streaming-uid"))
        assertFailure {
            nativeLegacyMaterial(
                sourceDocument,
                roster,
                null,
                ownAccountSources = listOf(source),
                accountScope = scope,
                watchedMigration = replay,
            )
        }

        val material = nativeLegacyMaterial(
            sourceDocument,
            roster,
            null,
            ownAccountSources = listOf(source),
            accountScope = scope,
            watchedMigration = first,
        )
        assertEquals(4, material.getJSONObject("watches").getJSONArray(ownProfile.id).length())
    }

    @Test
    fun `foreign account scope or retained UID cannot be used for a watched batch`() = runBlocking {
        val roster = listOf(fixedOwner, sharedProfile)
        val source = document(fixedOwner.id)
        val scope = VortxAccountScope("account.fixture", fixedOwner.id)
        val batch = fakeProducer().prepare(scope, source, roster, isCurrent = { true })

        assertFailure {
            nativeLegacyMaterial(
                source,
                roster,
                null,
                accountScope = scope.copy(accountID = "account.foreign"),
                watchedMigration = batch,
            )
        }

        val foreignArchive = JSONArray(batch.archive().toString())
        foreignArchive.getJSONObject(0).put("accountId", "account.foreign")
        val unresolved = NativeWatchedMigrationProducer { error("foreign archive must not be accepted") }
            .prepare(scope, source, roster, retainedArchive = foreignArchive, isCurrent = { true })
        assertFalse(unresolved.isComplete)
        assertEquals("episode_inventory_unavailable", unresolved.pending().getJSONObject(0).getString("reason"))

        // The UID field is only accepted for an independent authenticated source.  A shared source
        // archive carrying one is structurally invalid and must never be replayed as owner evidence.
        val uidArchive = JSONArray(batch.archive().toString())
        uidArchive.getJSONObject(0).put("verifiedStreamingUid", "foreign-streaming-uid")
        assertFailure {
            NativeWatchedMigrationProducer { error("foreign UID archive must be rejected before fetch") }
                .prepare(scope, source, roster, retainedArchive = uidArchive, isCurrent = { true })
        }
    }

    @Test
    fun `custom owner and fixed historical owner history rows retain distinct source locators`() = runBlocking {
        val scope = VortxAccountScope("account.custom-owner", customOwner.id)
        val roster = listOf(customOwner, sharedProfile)
        val source = ownerHistoryDocument(customOwner.id)
        val requests = mutableListOf<String>()
        val batch = fakeProducer(requests).prepare(scope, source, roster, isCurrent = { true })

        assertTrue(batch.isComplete)
        assertEquals(4, requests.size)
        assertEquals(4, batch.archive().length())

        val byProfile = source.getJSONObject("vortx").getJSONObject("byProfile")
        val currentHistory = byProfile.getJSONObject(customOwner.id).getJSONArray("ownerHistory").getJSONObject(0)
        val fixedHistory = byProfile.getJSONObject(UserProfile.OWNER_ID).getJSONArray("ownerHistory").getJSONObject(0)
        assertEquals(
            listOf("custom-history:1:1", "custom-history:1:3"),
            batch.videoIDs(
                customOwner.id,
                LegacyWatchedBitfieldMigrationEvidence.SourceRowLocator.AuthenticatedOwnerHistory(0, customOwner.id),
                currentHistory,
            ),
        )
        assertEquals(
            listOf("historical-history:1:2"),
            batch.videoIDs(
                customOwner.id,
                LegacyWatchedBitfieldMigrationEvidence.SourceRowLocator.AuthenticatedOwnerHistory(0, UserProfile.OWNER_ID),
                fixedHistory,
            ),
        )

        val material = nativeLegacyMaterial(source, roster, null, accountScope = scope, watchedMigration = batch)
        val ownerRows = watchRows(material, customOwner.id)
        assertTrue(ownerRows.any { it.getString("videoId") == "custom-history:1:1" })
        assertTrue(ownerRows.any { it.getString("videoId") == "historical-history:1:2" })
    }

    @Test
    fun `prepareOwn isolates independent source and revokes carrier on credential admission loss`() = runBlocking {
        var credentialAdmitted = true
        val sourceDocument = ownDocument()
        val source = ownSource(
            sourceDocument,
            ownProfile.id,
            "verified-streaming-uid",
            admission = { action -> if (!credentialAdmitted) false else action() },
        )
        val scope = VortxAccountScope("account.00000000-0000-0000-0000-000000000456", fixedOwner.id)
        val batch = NativeWatchedMigrationProducer { request -> response(request) }
            .prepareOwn(scope, ownProfile, source, isCurrent = { true })

        assertTrue(batch.isComplete)
        assertEquals(2, batch.archive().length())
        val carrier = nativeOwnAccountCarrier(source, ownProfile, sourceDocument, watchedMigration = batch)
        assertTrue(carrier.getJSONArray("watches").length() >= 4)
        assertFalse(carrier.toString().contains(fixedOwner.id))
        assertFalse(carrier.toString().contains("owner-series"))

        credentialAdmitted = false
        assertCredentialRevoked {
            nativeOwnAccountCarrier(source, ownProfile, sourceDocument, watchedMigration = batch)
        }
    }

    @Test
    fun `two authorized providers with conflicting inventories remain ambiguous pending`() = runBlocking {
        val roster = listOf(fixedOwner, sharedProfile)
        val scope = VortxAccountScope("account.fixture", fixedOwner.id)
        val source = document(fixedOwner.id).also {
            it.getJSONObject("vortx").getJSONArray("addons")
                .put(addon("catalog-alt", "https://catalog-alt.example/manifest.json"))
        }
        val batch = NativeWatchedMigrationProducer { request ->
            val alternate = request.addon.transportURL.contains("catalog-alt")
            val ids = if (alternate) {
                listOf("${request.metaID}:alternative:1", "${request.metaID}:alternative:2", "${request.metaID}:1:3")
            } else {
                episodeIDs(request.metaID)
            }
            LegacyWatchedBitfieldMigrationEvidence.MetadataResponse(
                request,
                metadata(request.metaID, videoIds = ids),
            )
        }.prepare(scope, source, roster, isCurrent = { true })

        assertFalse(batch.isComplete)
        assertEquals(0, batch.archive().length())
        assertEquals(2, batch.pending().length())
        for (index in 0 until batch.pending().length()) {
            assertEquals("episode_inventory_ambiguous", batch.pending().getJSONObject(index).getString("reason"))
        }
    }

    @Test
    fun `consumed document snapshot and manifest preserve exact decimal identity and source digest`() = runBlocking {
        val source = document(fixedOwner.id)
        source.getJSONObject("vortx").getJSONArray("addons").getJSONObject(0).getJSONObject("manifest")
            .put("rank", BigDecimal("1.0000000000000001"))
        source.put("exactInteger", BigDecimal("9007199254740993"))
        val snapshot = nativeWatchedDocumentSnapshot(source)
        assertTrue(snapshot.toString(Charsets.UTF_8).contains("1.0000000000000001"))
        assertTrue(snapshot.toString(Charsets.UTF_8).contains("9007199254740993"))
        val batch = fakeProducer().prepare(VortxAccountScope("account.fixture", fixedOwner.id), source,
            listOf(fixedOwner, sharedProfile), isCurrent = { true })
        assertTrue(batch.isComplete)
        val record = batch.archive().getJSONObject(0)
        assertEquals(Base64.getEncoder().encodeToString(snapshot), record.getString("sourceDocumentBase64"))
        assertEquals(MessageDigest.getInstance("SHA-256").digest(snapshot).joinToString("") { "%02x".format(it) }, record.getString("sourceDocumentSha256"))
        assertTrue(String(Base64.getDecoder().decode(record.getJSONObject("addon").getString("manifestBase64")), Charsets.UTF_8).contains("1.0000000000000001"))
        source.put("exactInteger", BigDecimal("9007199254740992"))
        assertFailure { nativeLegacyMaterial(source, listOf(fixedOwner, sharedProfile), null,
            accountScope = VortxAccountScope("account.fixture", fixedOwner.id), watchedMigration = batch) }
    }

    @Test
    fun `real JNI retains decoded and explicit unwatch facts across replay and cold hydration`() = runBlocking {
        org.junit.Assume.assumeTrue(System.getenv("VORTX_JNI_SYNC") == "1" && !System.getenv("VORTX_JNI_LIBRARY").isNullOrBlank())
        System.load(requireNotNull(System.getenv("VORTX_JNI_LIBRARY")))
        val bindings = object : VortxRuntimeBindings {
            override fun create(ownerId: String, ownerName: String) = VortxCore.nativeInitRuntime(JSONObject().put("ownerId", ownerId).put("ownerName", ownerName).toString())
            override fun hydrate(snapshot: String) = VortxCore.nativeInitFromStateJson(snapshot)
            override fun dispatch(handle: Long, action: String) = VortxCore.nativeDispatchJson(handle, action)
            override fun resolve(handle: Long, request: String) = VortxCore.nativeResolveJson(handle, request)
            override fun state(handle: Long) = VortxCore.nativeGetStateJson(handle)
            override fun delta(handle: Long) = VortxCore.nativeGetStateDeltaJson(handle)
            override fun free(handle: Long) = VortxCore.nativeEngineFree(handle)
        }
        for (independent in listOf(false, true)) {
            val scope = VortxAccountScope("account.00000000-0000-0000-0000-000000000456", fixedOwner.id)
            val source = if (independent) ownDocument() else document(fixedOwner.id)
            val profiles = listOf(fixedOwner, if (independent) ownProfile else sharedProfile)
            val own = if (independent) listOf(ownSource(source, ownProfile.id, "verified-streaming-uid")) else emptyList()
            val first = fakeProducer().prepare(scope, source, profiles, ownSources = own, isCurrent = { true })
            val material = nativeLegacyMaterial(source, profiles, null, ownAccountSources = own, accountScope = scope, watchedMigration = first)
            val cold = NativeWatchedMigrationProducer { error("Archived migration must not fetch") }
                .prepare(scope, source, profiles, ownSources = own, retainedArchive = first.archive(), isCurrent = { true })
            val replay = nativeLegacyMaterial(source, profiles, null, ownAccountSources = own, accountScope = scope, watchedMigration = cold)
            fun query(profileID: String) = JSONObject().put("kind", "profile_playback").put("profileId", profileID).toString()
            fun watched(runtime: VortxNativeRuntime, profileID: String, title: String): Set<String> {
                val rows = JSONObject(runtime.resolve(query(profileID))).getJSONObject("watchedVideoIdsByTitle").optJSONArray(title) ?: return emptySet()
                return (0 until rows.length()).map(rows::getString).toSet()
            }
            VortxNativeRuntime.create(bindings, fixedOwner.id, fixedOwner.name).use { runtime ->
                fun dispatch(action: JSONObject) {
                    val result = JSONObject(runtime.dispatch(action.toString()))
                    assertTrue(result.toString(), result.getBoolean("ok"))
                }
                dispatch(JSONObject().put("type", "bind_sync_scope").put("scope", scope.accountID))
                fun importAction(value: JSONObject) = JSONObject().put("type", "import_legacy_sync").put("scope", scope.accountID)
                    .put("ownerProfileId", fixedOwner.id).put("material", value)
                dispatch(importAction(material))
                if (independent) {
                    assertEquals(setOf("own-library:1:1", "own-library:1:3"), watched(runtime, ownProfile.id, "own-library"))
                    assertEquals(setOf("own-overlay:1:1"), watched(runtime, ownProfile.id, "own-overlay"))
                } else {
                    assertEquals(setOf("owner-series:1:1", "owner-series:1:3"), watched(runtime, fixedOwner.id, "owner-series"))
                    assertEquals(setOf("overlay-series:1:1"), watched(runtime, sharedProfile.id, "overlay-series"))
                }
                val before = JSONObject(runtime.stateJson()).getJSONObject("nativeSync")
                dispatch(importAction(replay))
                assertTrue(NativeHostPreferences.equal(before, JSONObject(runtime.stateJson()).getJSONObject("nativeSync")))
                VortxNativeRuntime.hydrate(bindings, runtime.stateJson()).use { reopened ->
                    assertTrue(NativeHostPreferences.equal(before, JSONObject(reopened.stateJson()).getJSONObject("nativeSync")))
                    for (profile in profiles) assertEquals(runtime.resolve(query(profile.id)), reopened.resolve(query(profile.id)))
                }
            }
        }
    }

    private fun fakeProducer(
        requests: MutableList<String> = mutableListOf(),
        handler: suspend (LegacyWatchedBitfieldMigrationEvidence.MetadataRequest) -> LegacyWatchedBitfieldMigrationEvidence.MetadataResponse = { request ->
            response(request)
        },
    ): NativeWatchedMigrationProducer = NativeWatchedMigrationProducer { request ->
        requests += request.metaID
        handler(request)
    }

    private fun response(request: LegacyWatchedBitfieldMigrationEvidence.MetadataRequest): LegacyWatchedBitfieldMigrationEvidence.MetadataResponse =
        LegacyWatchedBitfieldMigrationEvidence.MetadataResponse(request, metadata(request.metaID))

    private fun document(ownerID: String): JSONObject {
        val ownerSeries = seriesRow("owner-series", setOf(0, 1, 2))
            .put("ma", JSONObject().put("owner-series:1:2", 20.0))
            .put("ua", JSONObject().put("owner-series:1:2", 30.0))
        val overlaySeries = seriesRow("overlay-series", setOf(0, 2))
            .put("ma", JSONObject().put("overlay-series:1:1", 40.0))
            .put("ua", JSONObject().put("overlay-series:1:3", 50.0))
        return JSONObject().put(
            "vortx",
            JSONObject()
                .put("library", JSONArray().put(ownerSeries))
                .put(
                    "byProfile",
                    JSONObject().put(
                        sharedProfile.id,
                        JSONObject().put("library", JSONArray().put(overlaySeries)),
                    ),
                )
                .put("addons", JSONArray().put(addon("catalog"))),
        ).put("accountOwnerId", ownerID)
    }

    private fun ownDocument(): JSONObject = JSONObject().put(
        "vortx",
        JSONObject().put(
            "byProfile",
            JSONObject().put(
                ownProfile.id,
                JSONObject().put(
                    "library",
                    JSONArray().put(
                        seriesRow("own-overlay", setOf(0, 2))
                            .put("ma", JSONObject().put("own-overlay:1:1", 60.0))
                            .put("ua", JSONObject().put("own-overlay:1:3", 70.0)),
                    ),
                ),
            ),
        ),
    )

    private fun ownSource(
        document: JSONObject,
        profileID: String,
        uid: String,
        admission: (() -> Boolean) -> Boolean = { it() },
    ): NativeOwnAccountSource {
        val account = SessionOwnerSnapshot.Account("00000000-0000-0000-0000-000000000456", 7)
        val stored = mutableMapOf<String, String?>()
        val credentials = NativeOwnAccountCredentials(
            { key -> PersistentCredentialSnapshot(PersistentCredentialAvailability.AVAILABLE, mapOf(key to stored[key])) },
            { key, value -> stored[key] = value; true },
        )
        val attempt = credentials.begin(account, profileID, admission)
        val capture = credentials.storeVerified(attempt, "fixture-token", uid)
        val library = JSONObject().put(
            "result",
            JSONArray().put(
                JSONObject()
                    .put("_id", "own-library")
                    .put("type", "series")
                    .put("name", "Own library")
                    .put("state", JSONObject().put("watched", bitmap(episodeIDs("own-library"), setOf(0, 2)))),
            ),
        ).toString().toByteArray(Charsets.UTF_8)
        val addons = JSONObject().put(
            "result",
            JSONObject().put("addons", JSONArray().put(addon("own-catalog"))),
        ).toString().toByteArray(Charsets.UTF_8)
        val overlay = nativeOwnAccountOverlay(document, profileID).toString().toByteArray(Charsets.UTF_8)
        return NativeOwnAccountSource.fromFetched(capture, uid, library, addons, overlay, witnessedOverlay = true)
    }

    private fun seriesRow(id: String, watched: Set<Int>): JSONObject {
        val episodes = episodeIDs(id)
        return JSONObject()
            .put("id", id)
            .put("type", "series")
            .put("name", id)
            .put("watched", bitmap(episodes, watched))
    }

    private fun ownerHistoryDocument(ownerID: String): JSONObject = document(ownerID).also { source ->
        source.getJSONObject("vortx").getJSONObject("byProfile")
            .put(ownerID, JSONObject().put("ownerHistory", JSONArray().put(seriesRow("custom-history", setOf(0, 2))
                .put("lastWatched", "2026-01-01T00:00:00Z").put("eventEpochMs", 1767225600123.5))))
            .put(UserProfile.OWNER_ID, JSONObject().put("ownerHistory", JSONArray().put(seriesRow("historical-history", setOf(1))
                .put("lastWatched", "2026-01-01T00:00:00Z").put("eventEpochMs", 1767225600456.75))))
    }

    private fun addon(id: String, transportUrl: String = "https://catalog.example/manifest.json"): JSONObject = JSONObject()
        .put("transportUrl", transportUrl)
        .put(
            "manifest",
            JSONObject()
                .put("id", id)
                .put("name", "Fixture catalog")
                .put("version", "1.0.0")
                .put("types", JSONArray().put("series"))
                .put("resources", JSONArray().put("meta")),
        )

    private fun episodeIDs(id: String): List<String> = listOf("$id:1:1", "$id:1:2", "$id:1:3")

    private fun metadata(id: String, includeVideos: Boolean = true, videoIds: List<String>? = null): ByteArray {
        val videos = JSONArray()
        if (includeVideos) (videoIds ?: episodeIDs(id)).forEachIndexed { index, episodeID ->
            videos.put(
                JSONObject()
                    .put("id", episodeID)
                    .put("season", 1)
                    .put("episode", index + 1)
                    .put("released", "2005-01-0${index + 1}T00:00:00Z"),
            )
        }
        return JSONObject().put("meta", JSONObject().put("id", id).put("type", "series").put("videos", videos))
            .toString().toByteArray(Charsets.UTF_8)
    }

    /** Legacy uses a zlib bitmap whose low bit is episode one. */
    private fun bitmap(ids: List<String>, watched: Set<Int>): String {
        require(watched.isNotEmpty())
        val anchor = watched.maxOrNull()!!
        val plain = ByteArray(anchor / 8 + 1)
        watched.forEach { index ->
            require(index in ids.indices)
            plain[index / 8] = (plain[index / 8].toInt() or (1 shl (index % 8))).toByte()
        }
        val deflater = Deflater()
        return try {
            deflater.setInput(plain)
            deflater.finish()
            val compressed = ByteArray(64 * 1024)
            val count = deflater.deflate(compressed)
            "${ids[anchor]}:${anchor + 1}:${Base64.getEncoder().encodeToString(compressed.copyOf(count))}"
        } finally {
            deflater.end()
        }
    }

    private fun watchRows(material: JSONObject, profileID: String): List<JSONObject> =
        material.getJSONObject("watches").getJSONArray(profileID).let { rows ->
            (0 until rows.length()).map(rows::getJSONObject)
        }

    private fun assertFailure(action: suspend () -> Unit) {
        try {
            runBlocking { action() }
            fail("Expected watched migration failure")
        } catch (_: IllegalArgumentException) {
            // Expected fail-closed path.
        }
    }

    private fun assertCredentialRevoked(action: () -> Unit) {
        try {
            action()
            fail("Expected streaming credential revocation")
        } catch (_: IllegalStateException) {
            // Expected authority gate failure.
        }
    }
}
