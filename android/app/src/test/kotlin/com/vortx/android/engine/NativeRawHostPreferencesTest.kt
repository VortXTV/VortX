package com.vortx.android.engine

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** Synthetic source regression cases. No account, JNI, encrypted-file or device proof. UNRUN. */
class NativeRawHostPreferencesTest {
    private val scope = VortxAccountScope("account.00000000-0000-0000-0000-000000000123", "00000000-0000-0000-0000-00000000A11C")
    private val actor = "00000000-0000-0000-0000-000000000001"
    private val field = "xperience.import.00000000-0000-0000-0000-000000000101"
    private fun b(value: String) = value.toByteArray(Charsets.UTF_8)
    private fun rawRegister(number: String = "1.2300e+2", clock: String = "7") =
        b("{\"clock\":$clock,\"actor\":\"$actor\",\"value\":{\"schemaVersion\":99,\"future\":{\"n\":$number,\"z\":-0.0,\"a\":[18446744073709551615]}}}")
    private fun local(register: ByteArray = rawRegister(), profile: String = scope.ownerProfileID): ByteArray {
        val document = NativeHostPreferences.empty(scope)
        val root = OHJson.Obj().set("actor", OHJson.quote(actor)).set("counter", b("7.0"))
            .set("pending", b("false")).set("document", document.toString().toByteArray(Charsets.UTF_8))
            .set("futureLocal", b("{\"n\":1.000e+3,\"zero\":-0}"))
        val doc = root.obj("document"); val profiles = doc.obj("profiles")
        profiles.set(profile, OHJson.Obj().set("fields", OHJson.Obj().set(field, register).encoded()).encoded())
        return root.set("document", doc.set("profiles", profiles.encoded()).encoded()).encoded()
    }
    private fun register(local: ByteArray): ByteArray {
        val profiles = OHJson.Obj(local).obj("document").obj("profiles")
        val key = profiles.keys.single { NativeHostPreferences.canonicalProfileID(it) == scope.ownerProfileID }
        return profiles.obj(key).obj("fields").raw(field)
    }
    private fun decoded(local: ByteArray) = NativeHostPreferences.local(scope, JSONObject(OHJson.utf8(local)))
    private fun event(value: String, clock: String = "7") = b("{\"clock\":$clock,\"actor\":\"$actor\",\"value\":$value}")
    private fun withProfileField(local: ByteArray, name: String, register: ByteArray): ByteArray {
        val root = OHJson.Obj(local); val document = root.obj("document"); val profiles = document.obj("profiles")
        val bucket = profiles.obj(scope.ownerProfileID)
        bucket.set("fields", bucket.obj("fields").set(name, register).encoded())
        profiles.set(scope.ownerProfileID, bucket.encoded())
        return root.set("document", document.set("profiles", profiles.encoded()).encoded()).encoded()
    }
    private fun profileEvent(local: ByteArray, name: String) = OHJson.Obj(local).obj("document").obj("profiles")
        .obj(scope.ownerProfileID).obj("fields").raw(name)
    private val interestsField = com.vortx.android.foryou.ForYouInterests.FIELD
    private val collectionId = "00000000-0000-0000-0000-000000000301"
    private val collectionField = com.vortx.android.foryou.SmartCollection.FIELD_PREFIX + collectionId
    private fun interests(people: String) = withProfileField(local(), interestsField,
        event("{\"genres\":[],\"extras\":[],\"eras\":[],\"people\":$people,\"decided\":true,\"futureValue\":-0.0}"))
    private fun collection(rating: String) = withProfileField(local(), collectionField,
        event("{\"id\":\"$collectionId\",\"name\":\"Real\",\"rules\":{\"minRating\":$rating,\"yearFrom\":2.02e3,\"yearTo\":2029.0,\"people\":[],\"futureRule\":9007199254740992.1},\"home\":true,\"createdAt\":1.0,\"futureValue\":[1.000,9007199254740992.1,-0.0]}"))
    private fun people(local: ByteArray) = OHJson.array(OHJson.Obj(profileEvent(local, interestsField)).obj("value").raw("people"))
    private fun accepted(original: ByteArray, field: String, value: Any): ByteArray = NativeRawHostPreferences.reconcile(scope, original,
        NativeHostPreferences.recordProfileFields(scope, decoded(original), scope.ownerProfileID, JSONObject().put(field, value)))

    /** Real current Store.prepare and Model, with an explicitly synthetic read opening only.
     * Cancelled scope prevents reload IO. No fake Store/serializer/native/account authority. */
    private fun prepareForYou(original: ByteArray, change: (com.vortx.android.foryou.ForYouState) -> Any): JSONObject =
        JSONObject(requireNotNull(forYouIntent(original, false, change).encoded))
    private fun forYouIntent(original: ByteArray, delete: Boolean, change: (com.vortx.android.foryou.ForYouState) -> Any): com.vortx.android.foryou.PreparedForYouWrite {
        val prefs = java.lang.reflect.Proxy.newProxyInstance(android.content.SharedPreferences::class.java.classLoader,
            arrayOf(android.content.SharedPreferences::class.java)) { _, method, _ ->
            when (method.name) { "toString" -> "unused source fixture preferences"; "hashCode" -> 0; "equals" -> false
                else -> error("Prepare must not access preference IO") }
        } as android.content.SharedPreferences
        val job = kotlinx.coroutines.SupervisorJob().apply { cancel() }
        val dispatcher = kotlinx.coroutines.Dispatchers.Unconfined
        val store = com.vortx.android.foryou.ForYouStore(prefs, { scope.ownerProfileID }, { false }, {},
            kotlinx.coroutines.CoroutineScope(job + dispatcher), dispatcher, dispatcher)
        val fields = decoded(original).getJSONObject("document").getJSONObject("profiles").getJSONObject(scope.ownerProfileID).getJSONObject("fields")
        val (interests, collections) = com.vortx.android.foryou.ForYouSync.read(fields)
        // The actual constructor's synchronous first invalidation owns epoch 1; this controlled
        // opening exercises preparation only and is never submitted as real native authority.
        val origin = com.vortx.android.foryou.ForYouOrigin(store, 1L, null, null, null, fields)
        val state = com.vortx.android.foryou.ForYouState(scope.ownerProfileID, interests, collections, true, origin)
        val opening = com.vortx.android.foryou.ForYouEditSession(state)
        return try {
            val next = change(state)
            val intent = when (next) {
                is com.vortx.android.foryou.ForYouInterests -> store.prepare(opening, next)
                is com.vortx.android.foryou.SmartCollection -> if (delete) store.prepareDelete(opening, next) else store.prepare(opening, next)
                else -> error("Unsupported source fixture edit")
            }.getOrThrow()
            intent
        } finally { opening.close(); job.cancel() }
    }

    @Test fun `ordinary edit preserves original import tokens and unknown local metadata`() {
        val originalRoot = OHJson.Obj(local()); val originalDoc = originalRoot.obj("document")
        val profiles = originalDoc.obj("profiles"); val bucket = profiles.obj(scope.ownerProfileID)
        bucket.set("fields", bucket.obj("fields").set("avatar", b("{\"clock\":7.0,\"actor\":\"$actor\",\"value\":\"star\"}")).encoded())
        val original = originalRoot.set("document", originalDoc.set("profiles", profiles.set(scope.ownerProfileID, bucket.encoded()).encoded()).encoded()).encoded()
        val before = original.copyOf()
        val reduced = NativeHostPreferences.recordProfileFields(scope, decoded(original), scope.ownerProfileID,
            JSONObject().put("avatar", "moon"))
        val accepted = NativeRawHostPreferences.reconcile(scope, original, reduced)
        assertArrayEquals(rawRegister(), register(accepted))
        assertArrayEquals(OHJson.Obj(original).raw("futureLocal"), OHJson.Obj(accepted).raw("futureLocal"))
        assertArrayEquals(before, original)
        assertEquals(8L, decoded(accepted).getLong("counter"))
        val native = b("{\"schemaVersion\":5}")
        val cloud = OHJson.Obj().set("nativeSync", native).set("nativeHostPreferences", NativeRawHostPreferences.document(original)).encoded()
        val export = NativeOwnerHistoryAccount(NativePlaylistAccountComposer.compose(cloud, native, native,
            NativeRawHostPreferences.document(accepted), JSONObject()))
        val rawExport = export.raw("nativeHostPreferences")!!
        assertArrayEquals(rawRegister(), OHJson.Obj(rawExport).obj("profiles").obj(scope.ownerProfileID).obj("fields").raw(field))
    }

    @Test fun `cold raw capture and checkpoint replacement never use a serialized observation`() {
        val original = local(); val captured = NativeRawHostPreferences.captureLocal(scope, original)
        val projection = JSONObject().put("nativeHostPreferenceState", decoded(original)).put("futureNative", true).toString()
        val snapshot = NativeRawHostPreferences.snapshot(projection, captured)
        assertArrayEquals(original, OHJson.Obj(b(snapshot)).raw("nativeHostPreferenceState"))
        captured.fill(0)
        assertArrayEquals(rawRegister(), register(original))
    }

    @Test fun `incoming Lamport winner adopts exact source register and retains local metadata`() {
        val original = local(); val remoteRegister = OHJson.Obj(rawRegister("9007199254740993", "8"))
        val value = remoteRegister.obj("value")
        value.set("future", value.obj("future").set("a", b("[1.0000,-0.0]")).encoded())
        val remote = local(remoteRegister.set("value", value.encoded()).encoded())
        val incoming = JSONObject(OHJson.utf8(NativeRawHostPreferences.document(remote)))
        val reduced = NativeHostPreferences.merge(scope, decoded(original), incoming)
        val accepted = NativeRawHostPreferences.reconcile(scope, original, reduced, incoming,
            NativeRawHostPreferences.document(remote))
        assertArrayEquals(register(remote), register(accepted))
        assertArrayEquals(OHJson.Obj(original).raw("futureLocal"), OHJson.Obj(accepted).raw("futureLocal"))
    }

    @Test fun `opaque future numeric spelling keeps conservative format refusal`() {
        // This is an opaque future-format policy control, not adjacent precision-loss evidence.
        val original = local(rawRegister("1.0")); val remote = local(rawRegister("1"))
        val incoming = JSONObject(OHJson.utf8(NativeRawHostPreferences.document(remote)))
        val reduced = NativeHostPreferences.merge(scope, decoded(original), incoming)
        val error = assertThrows(IllegalArgumentException::class.java) {
            NativeRawHostPreferences.reconcile(scope, original, reduced, incoming, NativeRawHostPreferences.document(remote))
        }
        assertEquals("Conflicting full raw host preference event", error.message)
        assertArrayEquals(rawRegister("1.0"), register(original))
    }

    @Test fun `profile spelling is preserved and canonical aliases reject`() {
        val original = local(profile = scope.ownerProfileID.lowercase())
        val reduced = NativeHostPreferences.recordGlobals(scope, decoded(original), JSONObject().put("futureGlobal", "yes"))
        val accepted = NativeRawHostPreferences.reconcile(scope, original, reduced)
        assertEquals(setOf(scope.ownerProfileID.lowercase()), OHJson.Obj(accepted).obj("document").obj("profiles").keys)
        assertArrayEquals(register(original), register(accepted))
        NativeRawHostPreferences.requireRawExport(decoded(accepted).getJSONObject("document"), NativeRawHostPreferences.document(accepted))
        val root = OHJson.Obj(original); val doc = root.obj("document"); val profiles = doc.obj("profiles")
        profiles.set(scope.ownerProfileID, profiles.raw(scope.ownerProfileID.lowercase()))
        val duplicate = root.set("document", doc.set("profiles", profiles.encoded()).encoded()).encoded()
        assertThrows(IllegalArgumentException::class.java) { NativeRawHostPreferences.captureLocal(scope, duplicate) }
    }

    @Test fun `opaque imports require original incoming bytes and never become generic DTO edits`() {
        val original = local(); val incoming = JSONObject(OHJson.utf8(NativeRawHostPreferences.document(original)))
        assertThrows(IllegalArgumentException::class.java) { NativeRawHostPreferences.requireIncomingObservation(scope, incoming, null) }
        assertThrows(IllegalArgumentException::class.java) { NativeRawHostPreferences.requireRawExport(incoming, null) }
        NativeRawHostPreferences.requireRawExport(incoming, NativeRawHostPreferences.document(original))
        assertThrows(IllegalArgumentException::class.java) {
            NativeHostPreferences.recordProfileFields(scope, decoded(original), scope.ownerProfileID, JSONObject().put(field, JSONObject()))
        }
        val base = JSONObject().put(scope.ownerProfileID, JSONObject().put(field, JSONObject()).put("name", "Main"))
        val roster = JSONObject().put(scope.ownerProfileID, JSONObject().put("name", "Main").put("deleted", false))
        val projection = NativeHostPreferences.projectProfiles(decoded(original), base, roster)
        assertFalse(projection.getJSONObject(scope.ownerProfileID).has(field))
        assertArrayEquals(rawRegister(), register(original))
    }

    @Test fun `unsupported wrapper extension remains rejected and source bytes remain untouched`() {
        val register = OHJson.Obj(rawRegister()).set("futureWrapper", b("-0.0")).encoded()
        val original = local(register); val before = original.copyOf()
        assertThrows(IllegalArgumentException::class.java) { NativeRawHostPreferences.captureLocal(scope, original) }
        assertArrayEquals(before, original)
    }

    @Test fun `changed opaque arrays with a lossy baseline reject instead of dropping raw tokens`() {
        assertThrows(IllegalArgumentException::class.java) {
            NativeRawHostPreferences.patch(b("[1.0,-0.0]"), b("[1,0]"), b("[2,0]"))
        }
        assertArrayEquals(b("[1.0,-0.0]"), NativeRawHostPreferences.patch(b("[1.0,-0.0]"), b("[1,0]"), b("[1,0]")))
    }

    @Test fun `typed full account preview preserves source archive native and unknown siblings`() {
        val host = NativeRawHostPreferences.document(local())
        val native = OHJson.Obj().set("schemaVersion", b("6")).set("scope", OHJson.quote(scope.accountID))
            .set("ownerProfileId", OHJson.quote(scope.ownerProfileID)).set("ownerHistory", b("{\"future\":-0.0}"))
            .set("futureNative", b("18446744073709551615"))
        val raw = OHJson.Obj().set("nativeSync", native.encoded()).set("nativeHostPreferences", host)
            .set(NativeOwnerHistoryAccount.ARCHIVE, b("{\"futureArchive\":1.000e+3}"))
            .set("futureAccount", b("{\"n\":-0.0}"))
        val preview = NativeOwnerHistoryAccount(NativePlaylistAccountComposer.composePrepared(raw.encoded(), host, JSONObject()))
        for (key in listOf("nativeSync", NativeOwnerHistoryAccount.ARCHIVE, "futureAccount", "nativeHostPreferences"))
            assertArrayEquals(raw.raw(key), preview.raw(key))
        assertThrows(IllegalArgumentException::class.java) {
            NativePlaylistAccountComposer.compose(raw.encoded(), native.encoded(), native.encoded(), host, JSONObject())
        }
    }

    @Test fun `prepared account full encrypted budget includes pending provider family before callback`() {
        val host = NativeRawHostPreferences.document(local())
        val native = OHJson.Obj().set("schemaVersion", b("6")).set("scope", OHJson.quote(scope.accountID))
            .set("ownerProfileId", OHJson.quote(scope.ownerProfileID)).set("ownerHistory", b("{}"))
        val raw = OHJson.Obj().set("nativeSync", native.encoded()).set("nativeHostPreferences", host)
            .set(NativeOwnerHistoryAccount.ARCHIVE, b("{}"))
        val providers = JSONObject().put("nativeProviderCredentials", JSONObject().put("pending", "x".repeat(6_000_000)))
        var persisted = false
        assertThrows(IllegalArgumentException::class.java) {
            NativePlaylistAccountComposer.composePrepared(raw.encoded(), host, providers)
            persisted = true
        }
        assertFalse(persisted)
        assertNull(raw["nativeProviderCredentials"])
    }

    @Test fun `supported profile numeric edits accept noncanonical baselines and preserve unknown siblings`() {
        for (spelling in listOf("1.0", "1e0")) {
            val value = "{\"maxFileSizeGB\":$spelling,\"subSizeScale\":$spelling,\"maxResolution\":$spelling,\"minResolution\":$spelling," +
                "\"futureNumeric\":9007199254740992.1,\"futureArray\":[1.000,-0.0]}"
            val original = withProfileField(local(), "playback", event(value, "7e0"))
            val next = JSONObject(value)
            for (key in listOf("maxFileSizeGB", "subSizeScale", "maxResolution", "minResolution")) next.put(key, 2)
            val reduced = NativeHostPreferences.recordProfileFields(scope, decoded(original), scope.ownerProfileID,
                JSONObject().put("playback", next))
            val accepted = NativeRawHostPreferences.reconcile(scope, original, reduced)
            val beforeValue = OHJson.Obj(profileEvent(original, "playback")).obj("value")
            val afterValue = OHJson.Obj(profileEvent(accepted, "playback")).obj("value")
            for (key in listOf("maxFileSizeGB", "subSizeScale", "maxResolution", "minResolution"))
                assertEquals(2.0, JSONObject(OHJson.utf8(afterValue.encoded())).getDouble(key), 0.0)
            for (key in listOf("futureNumeric", "futureArray")) assertArrayEquals(beforeValue.raw(key), afterValue.raw(key))
            assertArrayEquals(register(original), register(accepted))
            val native = b("{\"schemaVersion\":5}")
            val cloud = OHJson.Obj().set("nativeSync", native).set("nativeHostPreferences", NativeRawHostPreferences.document(original)).encoded()
            val exported = NativeOwnerHistoryAccount(NativePlaylistAccountComposer.compose(cloud, native, native,
                NativeRawHostPreferences.document(accepted), JSONObject())).raw("nativeHostPreferences")!!
            val exportedValue = OHJson.Obj(exported).obj("profiles").obj(scope.ownerProfileID).obj("fields").obj("playback").obj("value")
            assertArrayEquals(beforeValue.raw("futureNumeric"), exportedValue.raw("futureNumeric"))
            assertArrayEquals(beforeValue.raw("futureArray"), exportedValue.raw("futureArray"))
            assertEquals(2.0, JSONObject(OHJson.utf8(exportedValue.encoded())).getDouble("maxFileSizeGB"), 0.0)
        }
        val precise = "{\"maxFileSizeGB\":0.1234567890123456789,\"subSizeScale\":0.1234567890123456789,\"futureNumeric\":9007199254740992.1}"
        val original = withProfileField(local(), "playback", event(precise))
        val ordinaryAfter = NativeHostPreferences.recordProfileFields(scope, decoded(original), scope.ownerProfileID,
            JSONObject().put("playback", JSONObject(precise).put("maxFileSizeGB", 2).put("subSizeScale", 2)))
        val ordinary = NativeRawHostPreferences.reconcile(scope, original, ordinaryAfter)
        val ordinaryValue = OHJson.Obj(profileEvent(ordinary, "playback")).obj("value")
        assertEquals(2.0, JSONObject(OHJson.utf8(ordinaryValue.encoded())).getDouble("maxFileSizeGB"), 0.0)
        assertArrayEquals(b("9007199254740992.1"), ordinaryValue.raw("futureNumeric"))
        val roundedBefore = decoded(original)
        // Controlled rounded projection: the JVM may retain BigDecimal while Android/libcore
        // or another admitted disposable Number view can round. This is no natural-repro claim.
        val projectedValue = roundedBefore.getJSONObject("document").getJSONObject("profiles").getJSONObject(scope.ownerProfileID)
            .getJSONObject("fields").getJSONObject("playback").getJSONObject("value")
        projectedValue.put("maxFileSizeGB", 0.12345678901234568).put("subSizeScale", 0.12345678901234568)
        val newValue = JSONObject(projectedValue.toString()).put("maxFileSizeGB", 2).put("subSizeScale", 2)
        val after = NativeHostPreferences.recordProfileFields(scope, roundedBefore, scope.ownerProfileID, JSONObject().put("playback", newValue))
        val patched = NativeRawHostPreferences.patchDocument(NativeRawHostPreferences.document(original),
            b(roundedBefore.getJSONObject("document").toString()), b(after.getJSONObject("document").toString()))
        val acceptedValue = OHJson.Obj(patched).obj("profiles").obj(scope.ownerProfileID).obj("fields").obj("playback").obj("value")
        assertEquals(2.0, JSONObject(OHJson.utf8(acceptedValue.encoded())).getDouble("maxFileSizeGB"), 0.0)
        assertEquals(2.0, JSONObject(OHJson.utf8(acceptedValue.encoded())).getDouble("subSizeScale"), 0.0)
        assertArrayEquals(b("9007199254740992.1"), acceptedValue.raw("futureNumeric"))
    }

    @Test fun `schema owned global and integer array edits preserve unrelated raw members`() {
        val discovery = "{\"selectedProviders\":[1.0,2e0],\"providerOrder\":[2.0,1e0],\"future\":[1.000,-0.0]}"
        val watchlistField = com.vortx.android.library.NativeWatchlistCodec.field("tt123", "movie")
        val watchlist = "{\"id\":\"tt123\",\"type\":\"movie\",\"name\":\"Fixture\",\"addedAt\":1e0}"
        val withWatchlist = withProfileField(local(), watchlistField, event(watchlist))
        val root = OHJson.Obj(withProfileField(withWatchlist, "discovery", event(discovery)))
        val document = root.obj("document"); val globals = document.obj("globals")
        val fields = globals.obj("fields").set("stremiox.autoSkipDelaySeconds", event("1e0"))
            .set("stremiox.sub.sizeScale", event("0.1234567890123456789")).set("futureSetting", event("{\"n\":9007199254740992.1,\"z\":-0.0}"))
        val original = root.set("document", document.set("globals", globals.set("fields", fields.encoded()).encoded()).encoded()).encoded()
        val nextDiscovery = JSONObject(discovery).put("selectedProviders", org.json.JSONArray().put(2).put(3))
            .put("providerOrder", org.json.JSONArray().put(3).put(2))
        val profileEdit = NativeHostPreferences.recordProfileFields(scope, decoded(original), scope.ownerProfileID,
            JSONObject().put("discovery", nextDiscovery).put(watchlistField, JSONObject(watchlist).put("addedAt", 2.0)))
        val reduced = NativeHostPreferences.recordGlobals(scope, profileEdit,
            JSONObject().put("stremiox.autoSkipDelaySeconds", 2).put("stremiox.sub.sizeScale", 2.0))
        val accepted = NativeRawHostPreferences.reconcile(scope, original, reduced)
        val beforeDiscovery = OHJson.Obj(profileEvent(original, "discovery")).obj("value")
        val afterDiscovery = OHJson.Obj(profileEvent(accepted, "discovery")).obj("value")
        assertArrayEquals(b("[2,3]"), afterDiscovery.raw("selectedProviders"))
        assertArrayEquals(b("[3,2]"), afterDiscovery.raw("providerOrder"))
        assertArrayEquals(beforeDiscovery.raw("future"), afterDiscovery.raw("future"))
        val afterGlobals = OHJson.Obj(accepted).obj("document").obj("globals").obj("fields")
        assertEquals(2L, JSONObject(OHJson.utf8(afterGlobals.raw("stremiox.autoSkipDelaySeconds"))).getLong("value"))
        assertEquals(2.0, JSONObject(OHJson.utf8(afterGlobals.raw("stremiox.sub.sizeScale"))).getDouble("value"), 0.0)
        assertArrayEquals(fields.raw("futureSetting"), afterGlobals.raw("futureSetting"))
        assertEquals(2.0, JSONObject(OHJson.utf8(profileEvent(accepted, watchlistField))).getJSONObject("value").getDouble("addedAt"), 0.0)
    }

    @Test fun `repeated known clock and numeric events retain original spelling including negative zero`() {
        for (clock in listOf("7.0", "7e0")) {
            val original = withProfileField(local(), "avatar", event("\"star\"", clock))
            val remote = withProfileField(local(), "avatar", event("\"star\"", "7"))
            val incoming = JSONObject(OHJson.utf8(NativeRawHostPreferences.document(remote)))
            val reduced = NativeHostPreferences.merge(scope, decoded(original), incoming)
            val accepted = NativeRawHostPreferences.reconcile(scope, original, reduced, incoming,
                NativeRawHostPreferences.document(remote))
            assertArrayEquals(profileEvent(original, "avatar"), profileEvent(accepted, "avatar"))
        }
        val original = withProfileField(local(), "playback", event("{\"maxFileSizeGB\":-0.0,\"subSizeScale\":1.0,\"maxResolution\":1e0}", "7.0"))
        val remote = withProfileField(local(), "playback", event("{\"maxFileSizeGB\":0e0,\"subSizeScale\":1e0,\"maxResolution\":1.0}", "7"))
        val incoming = JSONObject(OHJson.utf8(NativeRawHostPreferences.document(remote)))
        val accepted = NativeRawHostPreferences.reconcile(scope, original, NativeHostPreferences.merge(scope, decoded(original), incoming),
            incoming, NativeRawHostPreferences.document(remote))
        assertArrayEquals(profileEvent(original, "playback"), profileEvent(accepted, "playback"))
        val watchlistField = com.vortx.android.library.NativeWatchlistCodec.field("tt123", "movie")
        val firstWatchlist = withProfileField(local(), watchlistField,
            event("{\"id\":\"tt123\",\"type\":\"movie\",\"addedAt\":1.0}", "7e0"))
        val secondWatchlist = withProfileField(local(), watchlistField,
            event("{\"id\":\"tt123\",\"type\":\"movie\",\"addedAt\":1e0}", "7"))
        val peer = JSONObject(OHJson.utf8(NativeRawHostPreferences.document(secondWatchlist)))
        val merged = NativeRawHostPreferences.reconcile(scope, firstWatchlist,
            NativeHostPreferences.merge(scope, decoded(firstWatchlist), peer), peer, NativeRawHostPreferences.document(secondWatchlist))
        assertArrayEquals(profileEvent(firstWatchlist, watchlistField), profileEvent(merged, watchlistField))
    }

    @Test fun `controlled rounded projections reach immutable event and opaque mutation refusals`() {
        val rawA = event("{\"maxFileSizeGB\":9007199254740992.0}", "7.0")
        val rawB = event("{\"maxFileSizeGB\":9007199254740992.1}", "7")
        // Controlled rounded reducer fixture: JVM JSONObject may retain Long/BigDecimal exactly.
        // These deliberately identical projections model loss; they are not a natural JVM or
        // customer reproduction. The production raw equal-event barrier itself is invoked below.
        val roundedA = JSONObject().put("maxFileSizeGB", 9_007_199_254_740_992.0)
        val roundedB = JSONObject().put("maxFileSizeGB", 9_007_199_254_740_992.0)
        assertTrue(NativeHostPreferences.equal(roundedA, roundedB))
        NativeRawHostPreferences.requireEqualEvent("playback", true, rawA,
            event("{\"maxFileSizeGB\":9007199254740992}", "7"))
        val conflict = assertThrows(IllegalArgumentException::class.java) {
            NativeRawHostPreferences.requireEqualEvent("playback", true, rawA, rawB)
        }
        assertEquals("Conflicting full raw host preference event", conflict.message)

        val original = withProfileField(local(), "playback", event("{\"futureNumeric\":9007199254740992.1}"))
        val roundedBefore = decoded(original)
        roundedBefore.getJSONObject("document").getJSONObject("profiles").getJSONObject(scope.ownerProfileID)
            .getJSONObject("fields").getJSONObject("playback").put("value", JSONObject().put("futureNumeric", 9_007_199_254_740_992.0))
        val after = NativeHostPreferences.recordProfileFields(scope, roundedBefore, scope.ownerProfileID,
            JSONObject().put("playback", JSONObject().put("futureNumeric", 2)))
        val mutation = assertThrows(IllegalArgumentException::class.java) {
            NativeRawHostPreferences.patchDocument(NativeRawHostPreferences.document(original),
                b(roundedBefore.getJSONObject("document").toString()), b(after.getJSONObject("document").toString()))
        }
        assertEquals("Opaque host value requires lossless mutation support", mutation.message)
        assertArrayEquals(event("{\"futureNumeric\":9007199254740992.1}"), profileEvent(original, "playback"))
    }

    @Test fun `numeric token comparison handles long exponents without arbitrary precision arithmetic`() {
        // Comparison-only resource controls, not host admission or measured memory/latency proof.
        // No new protocol cap is inferred from these one-megabyte synthetic exponent spellings.
        val zeros = "0".repeat(1_000_000)
        NativeRawHostPreferences.requireEqualEvent("avatar", true, event("\"star\"", "7e+" + zeros), event("\"star\"", "7"))
        fun compare(first: String, second: String) = NativeRawHostPreferences.requireEqualEvent("playback", true,
            event("{\"subSizeScale\":$first}"), event("{\"subSizeScale\":$second}"))
        compare("10e9999999999999999999", "1e10000000000000000000")
        compare("1e-10000000000000000000", "10e-10000000000000000001")
        compare("10e-10000000000000000000", "1e-9999999999999999999")
        compare("1e+" + zeros, "1.0000")
        assertThrows(IllegalArgumentException::class.java) {
            compare("1e-10000000000000000000", "1e-10000000000000000001")
        }
    }

    @Test fun `real ForYou prepare changes rating years and createdAt while retaining unknown raw members`() {
        for ((rating, edited) in listOf("1.0" to 2.0, "6.0" to 7.0, "6.1234567890123456789" to 7.0)) {
            val original = collection(rating)
            val value = prepareForYou(original) { state -> state.collections.single().let { old ->
                old.copy(rules = old.rules.copy(minRating = edited, yearFrom = 2021, yearTo = 2030), createdAt = 2.0)
            } }
            val result = accepted(original, collectionField, value)
            val before = OHJson.Obj(profileEvent(original, collectionField)).obj("value")
            val after = OHJson.Obj(profileEvent(result, collectionField)).obj("value")
            assertEquals(edited, JSONObject(OHJson.utf8(after.raw("rules"))).getDouble("minRating"), 0.0)
            assertEquals(2021L, OHJson.integer(after.obj("rules").raw("yearFrom")))
            assertEquals(2030L, OHJson.integer(after.obj("rules").raw("yearTo")))
            assertEquals(2.0, JSONObject(OHJson.utf8(after.encoded())).getDouble("createdAt"), 0.0)
            assertArrayEquals(before.raw("futureValue"), after.raw("futureValue"))
            assertArrayEquals(before.obj("rules").raw("futureRule"), after.obj("rules").raw("futureRule"))
        }
    }

    @Test fun `real ForYou people add rename and remove preserve original row and metadata slices`() {
        val known = "{ \"id\":1.0, \"name\":\"A\", \"futurePrecise\":9007199254740992.1 }"
        val unknown = "{\"id\":50,\"futureShape\":true,\"opaque\":[1.000,-0.0]}"
        val original = interests("[$known,$unknown]")
        val added = accepted(original, interestsField, prepareForYou(original) { state ->
            val current = requireNotNull(state.interests)
            current.copy(people = current.people + com.vortx.android.foryou.ForYouPerson(2, "B"))
        })
        assertArrayEquals(b(known), people(added)[0]); assertArrayEquals(b(unknown), people(added)[1])
        assertEquals(2L, OHJson.integer(OHJson.Obj(people(added)[2]).raw("id")))
        val renamedOriginal = interests("[{\"id\":1e0,\"name\":\"A\",\"futurePrecise\":9007199254740992.1},$unknown]")
        val renamed = accepted(renamedOriginal, interestsField, prepareForYou(renamedOriginal) { state ->
            val current = requireNotNull(state.interests)
            current.copy(people = current.people.map { it.copy(name = "Updated", department = "Directing") })
        })
        assertArrayEquals(b("1e0"), OHJson.Obj(people(renamed)[0]).raw("id"))
        assertArrayEquals(b("9007199254740992.1"), OHJson.Obj(people(renamed)[0]).raw("futurePrecise"))
        assertEquals("Updated", OHJson.Obj(people(renamed)[0]).text("name")); assertArrayEquals(b(unknown), people(renamed)[1])
        val removed = accepted(original, interestsField, prepareForYou(original) { it.interests!!.copy(people = emptyList()) })
        assertEquals(1, people(removed).size); assertArrayEquals(b(unknown), people(removed).single())
    }

    @Test fun `ForYou duplicate and reserved identities preserve ambiguity while unrelated append works`() {
        val first = "{\"id\":1.0,\"name\":\"A\",\"n\":1.000}"
        val second = "{\"id\":1e0,\"name\":\"Alias\",\"n\":2.000}"
        val unknown = "{\"id\":50,\"futureShape\":true,\"n\":9007199254740992.1}"
        val original = interests("[$first,$second,$unknown]")
        val result = accepted(original, interestsField, prepareForYou(original) { state ->
            val current = requireNotNull(state.interests)
            current.copy(people = current.people + com.vortx.android.foryou.ForYouPerson(2, "B"))
        })
        for ((index, row) in listOf(first, second, unknown).withIndex()) assertArrayEquals(b(row), people(result)[index])
        val protected = accepted(original, interestsField, prepareForYou(original) { state ->
            state.interests!!.copy(people = listOf(com.vortx.android.foryou.ForYouPerson(1, "Attempt"), com.vortx.android.foryou.ForYouPerson(50, "Borrow")))
        })
        assertEquals(3, people(protected).size)
        for ((index, row) in listOf(first, second, unknown).withIndex()) assertArrayEquals(b(row), people(protected)[index])
        val adversarial = JSONObject(OHJson.utf8(OHJson.Obj(profileEvent(original, interestsField)).raw("value")))
            .put("people", org.json.JSONArray().put(JSONObject(first)).put(JSONObject(unknown)))
        assertThrows(IllegalArgumentException::class.java) { accepted(original, interestsField, adversarial) }
    }

    @Test fun `ForYou rounded nonintegral and unsupported people identities never authorize edits`() {
        for (row in listOf("{\"id\":1.000000000000000001,\"name\":\"Future\",\"n\":9007199254740992.1}",
            "{\"id\":1,\"name\":{\"future\":true},\"n\":9007199254740992.1}")) {
            val original = interests("[$row]")
            val changed = prepareForYou(original) { state -> state.interests!!.copy(people = listOf(com.vortx.android.foryou.ForYouPerson(1, "Edited"))) }
            assertThrows(IllegalArgumentException::class.java) { accepted(original, interestsField, changed) }
            val removed = prepareForYou(original) { state -> state.interests!!.copy(people = emptyList()) }
            assertThrows(IllegalArgumentException::class.java) { accepted(original, interestsField, removed) }
            assertArrayEquals(b(row), people(original).single())
        }
        val unknown = "{\"id\":1.000000000000000001,\"name\":\"Future\"}"
        val original = interests("[$unknown]")
        val collision = JSONObject(OHJson.utf8(OHJson.Obj(profileEvent(original, interestsField)).raw("value")))
            .put("people", org.json.JSONArray().put(JSONObject(unknown)).put(JSONObject().put("id", 1).put("name", "Rebind")))
        assertThrows(IllegalArgumentException::class.java) { accepted(original, interestsField, collision) }
    }

    @Test fun `ForYou immutable numeric and unique people formatting agrees but exact contradictions refuse`() {
        fun value(rating: String, year: String, id: String, future: String = "9007199254740992.1") =
            "{\"id\":\"$collectionId\",\"name\":\"Real\",\"home\":true,\"createdAt\":1,\"rules\":{\"minRating\":$rating,\"yearFrom\":$year,\"people\":[{\"id\":$id,\"name\":\"A\",\"futurePrecise\":$future}]}}"
        val original = event(value("6.0", "2.02e3", "1.0"), "7.0")
        NativeRawHostPreferences.requireEqualEvent(collectionField, true, original, event(value("6", "2020.0", "1"), "7"))
        // Model Double views may collide; these explicit raw barriers are not customer/runtime proof.
        for (incoming in listOf(value("6.000000000000000001", "2020", "1"),
            value("6", "2020", "1", "9007199254740992.0"), value("6", "2020", "1.000000000000000001"))) {
            assertThrows(IllegalArgumentException::class.java) { NativeRawHostPreferences.requireEqualEvent(collectionField, true, original, event(incoming)) }
        }
        assertThrows(IllegalArgumentException::class.java) { NativeRawHostPreferences.requireEqualEvent(interestsField, true,
            event("{\"people\":[{\"id\":50.0,\"futureShape\":true}]}"), event("{\"people\":[{\"id\":50,\"futureShape\":true}]}")) }
    }

    @Test fun `ForYou opaque arrays unsupported containers and altered original people observations refuse`() {
        val original = collection("6.0")
        val raw = NativeRawHostPreferences.document(original)
        val before = JSONObject(OHJson.utf8(raw))
        val fields = before.getJSONObject("profiles").getJSONObject(scope.ownerProfileID).getJSONObject("fields")
        // Explicit controlled rounded baseline; no natural JVM/libcore reproduction is claimed.
        fields.getJSONObject(collectionField).getJSONObject("value").put("futureValue", org.json.JSONArray().put(1).put(9_007_199_254_740_992.0).put(0))
        val after = JSONObject(before.toString())
        after.getJSONObject("profiles").getJSONObject(scope.ownerProfileID).getJSONObject("fields")
            .getJSONObject(collectionField).getJSONObject("value").put("futureValue", org.json.JSONArray().put(2).put(9_007_199_254_740_992.0).put(0))
        assertThrows(IllegalArgumentException::class.java) { NativeRawHostPreferences.patchDocument(raw, b(before.toString()), b(after.toString())) }
        val rows = interests("[{\"id\":1.0,\"name\":\"A\"}]")
        val observed = JSONObject(OHJson.utf8(NativeRawHostPreferences.document(rows)))
        observed.getJSONObject("profiles").getJSONObject(scope.ownerProfileID).getJSONObject("fields")
            .getJSONObject(interestsField).getJSONObject("value").put("people", org.json.JSONArray())
        val edited = JSONObject(observed.toString())
        edited.getJSONObject("profiles").getJSONObject(scope.ownerProfileID).getJSONObject("fields")
            .getJSONObject(interestsField).getJSONObject("value").put("people", org.json.JSONArray().put(JSONObject().put("id", 2).put("name", "B")))
        assertThrows(IllegalArgumentException::class.java) { NativeRawHostPreferences.patchDocument(NativeRawHostPreferences.document(rows), b(observed.toString()), b(edited.toString())) }
        val unsupported = withProfileField(local(), interestsField, event("{\"people\":{\"futureShape\":true}}"))
        val prepared = prepareForYou(unsupported) { it.interests!!.copy(people = listOf(com.vortx.android.foryou.ForYouPerson(2, "B"))) }
        assertThrows(IllegalArgumentException::class.java) { accepted(unsupported, interestsField, prepared) }
    }

    @Test fun `real collection delete and closed Watchlist removal admit explicit tombstones only`() {
        val original = collection("6.0")
        val intent = forYouIntent(original, true) { it.collections.single() }
        assertNull(intent.encoded)
        val deleted = accepted(original, collectionField, JSONObject.NULL)
        assertArrayEquals(b("null"), OHJson.Obj(profileEvent(deleted, collectionField)).raw("value"))
        val watchField = com.vortx.android.library.NativeWatchlistCodec.field("tt123", "movie")
        val watch = withProfileField(local(), watchField, event("{\"id\":\"tt123\",\"type\":\"movie\",\"addedAt\":1e0}"))
        val change = com.vortx.android.library.NativeWatchlistCodec.change(
            com.vortx.android.library.WatchlistEntry("tt123", "movie", null, null, 1.0), false)
        val removed = accepted(watch, watchField, change.get(watchField))
        assertArrayEquals(b("null"), OHJson.Obj(profileEvent(removed, watchField)).raw("value"))
        val unreadable = withProfileField(local(), collectionField, event("{\"future\":1.0}"))
        assertThrows(IllegalArgumentException::class.java) { accepted(unreadable, collectionField, JSONObject.NULL) }
        val mismatched = withProfileField(local(), collectionField, event("{\"id\":\"00000000-0000-0000-0000-000000000399\",\"name\":\"Wrong\",\"rules\":{\"minRating\":6.0}}"))
        assertThrows(IllegalArgumentException::class.java) { accepted(mismatched, collectionField, JSONObject.NULL) }
        val opaque = withProfileField(local(), "future.record", event("{\"n\":1.0}"))
        assertThrows(IllegalArgumentException::class.java) { accepted(opaque, "future.record", JSONObject.NULL) }
        val playlistField = NativePlaylist.field(java.util.UUID.fromString("00000000-0000-0000-0000-000000000777"))
        val unsupportedPlaylist = withProfileField(local(), playlistField, event("{\"schema\":2,\"future\":1.0}"))
        val playlistBefore = decoded(unsupportedPlaylist).getJSONObject("document")
        val playlistFields = playlistBefore.getJSONObject("profiles").getJSONObject(scope.ownerProfileID).getJSONObject("fields")
        assertThrows(IllegalStateException::class.java) {
            NativePlaylist.validateMutation(playlistField, playlistFields.getJSONObject(playlistField), JSONObject.NULL, playlistFields)
        }
        assertFalse(NativeHostPreferences.explicitRecordTombstone(playlistField, playlistFields.getJSONObject(playlistField).getJSONObject("value")))
        val playlistAfter = JSONObject(playlistBefore.toString())
        playlistAfter.getJSONObject("profiles").getJSONObject(scope.ownerProfileID).getJSONObject("fields")
            .getJSONObject(playlistField).put("value", JSONObject.NULL)
        assertThrows(IllegalArgumentException::class.java) {
            NativeRawHostPreferences.patchDocument(NativeRawHostPreferences.document(unsupportedPlaylist),
                b(playlistBefore.toString()), b(playlistAfter.toString()))
        }
    }
}
