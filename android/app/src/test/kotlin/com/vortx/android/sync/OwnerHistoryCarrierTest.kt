package com.vortx.android.sync

import com.vortx.android.profile.UserProfile
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class OwnerHistoryCarrierTest {
    @Test fun `conditional cold add requires exact neutral membership authority not a constructor viewing clock`() {
        val raw = publicationRow(epoch = 20000).copy(videoId = null, timeOffsetMs = 0, durationMs = 0)
        val owned = OwnerLibraryOperation(OwnerLibraryOperation.Kind.MEMBERSHIP, name = raw.name).projection(null, null, raw)!!
        val incoming = publicationRow(epoch = 10000)
        val admitted = OwnerLibraryHistoryPolicy.admitConditionalHistory(incoming, raw, owned)
        assertEquals(0L, admitted.conditionalHistory!!.priorEventEpochMs)
        assertEquals(0L, admitted.conditionalHistory!!.priorLastWatchedEpochMs)
        assertEquals(20000L, admitted.conditionalHistory!!.expected.nativeEventEpochMs)
        for (unproven in listOf<VortXSyncDoc.OwnerLibraryItem?>(null, owned.copy(historyOnly = true),
            owned.copy(declaredWatchFields = null), owned.copy(videoId = "tt1"), owned.copy(timesWatched = 1)))
            assertNull(OwnerLibraryHistoryPolicy.admitConditionalHistory(incoming, raw, unproven).conditionalHistory)
        for (changed in listOf(raw.copy(timeOffsetMs = 1), raw.copy(videoId = "tt1"), raw.copy(timesWatched = 1), raw.copy(watched = "opaque")))
            assertNull(OwnerLibraryHistoryPolicy.admitConditionalHistory(incoming, changed, owned).conditionalHistory)
    }

    @Test fun `delayed removal then separate invocation readd preserves only prior authorized history`() {
        for (uid in listOf(null, "shared")) {
            val persistence = MemoryLibraryProofPersistence()
            val proofs = OwnerLibraryPublicationProofs(persistence)
            val native = NativeLibraryOwner(uid)
            val transitions = OwnerLibraryPendingTransitions()
            val before = publicationRow().copy(watched = "opaque", timesWatched = 3)
            val authorized = before.copy(watched = null, timesWatched = null, wholeTitleWatched = null,
                currentVideoWatched = null, declaredWatchFields = emptySet())
            assertTrue(proofs.grantProjected("B", native, listOf(before to authorized)))
            var rows = listOf(before)
            val removal = OwnerLibraryPublicationLease("B", proofs) { it() }
            assertTrue(removal.mutateObserved(native, before.identity, { rows }, OwnerLibraryOperation(OwnerLibraryOperation.Kind.REMOVE), { rows.single() }) {})
            transitions.record(before.identity, "captured-owner-revision", removal)
            val removed = before.copy(removed = true, eventEpochMs = 3000, nativeEventEpochMs = 3000)
            rows = listOf(removed) // the native disk future completes after the invocation returns
            assertNull(proofs.published("B", native, removed))
            assertTrue(transitions.completePrior(before.identity, "captured-owner-revision") { rows })
            val removedOutbound = proofs.published("B", native, removed)!!
            assertTrue(removedOutbound.historyOnly)
            assertNull(removedOutbound.watched)
            assertEquals(before.lastWatched, removedOutbound.lastWatched)
            val readd = OwnerLibraryPublicationLease("B", proofs) { it() }
            assertTrue(readd.mutateObserved(native, before.identity, { rows }, OwnerLibraryOperation(OwnerLibraryOperation.Kind.MEMBERSHIP, name = before.name), { rows.single() }) {})
            val added = removed.copy(removed = false, eventEpochMs = 4000, nativeEventEpochMs = 4000)
            rows = listOf(added)
            assertTrue(readd.completePending(before.identity) { rows })
            val outbound = OwnerLibraryPublicationProofs(persistence).published("B", native, added)!!
            assertFalse(outbound.historyOnly)
            assertFalse(outbound.removed)
            assertEquals(before.eventEpochMs, outbound.eventEpochMs)
            assertEquals(before.lastWatched, outbound.lastWatched)
            assertNull(outbound.watched)
            assertEquals(emptySet<String>(), outbound.declaredWatchFields)
            val peer = publicationRow(epoch = 2500).copy(timeOffsetMs = 2500)
            val peerArray = JSONArray().put(OwnerLibraryHistoryPolicy.encode(peer, JSONObject()))
            val merged = OwnerLibraryHistoryPolicy.merge(peerArray, listOf(outbound), emptySet())
            assertEquals(2500L, VortXSyncDoc.ownerLibraryItem(merged.getJSONObject(0))!!.timeOffsetMs)
        }
    }

    @Test fun `deferred removal cannot grant absent foreign changed owner or failed storage rows`() {
        for (mode in listOf("absent", "foreign", "ownerChanged", "accountChanged", "failedRead", "failedCommit", "alteredPayload")) {
            val disk = MemoryLibraryProofPersistence()
            val proofs = OwnerLibraryPublicationProofs(disk)
            val native = NativeLibraryOwner(null)
            val before = publicationRow()
            if (mode != "foreign") assertTrue(proofs.grant("B", native, listOf(before)))
            var current = true
            val lease = OwnerLibraryPublicationLease("B", proofs) { if (current) it() else false }
            var rows: List<VortXSyncDoc.OwnerLibraryItem>? = when (mode) { "absent" -> emptyList(); "failedRead" -> null; else -> listOf(before) }
            val transitions = OwnerLibraryPendingTransitions()
            lease.mutateObserved(native, before.identity, { rows }, OwnerLibraryOperation(OwnerLibraryOperation.Kind.REMOVE), { rows?.singleOrNull() }) {}
            transitions.record(before.identity, "old-owner", lease)
            val removed = before.copy(removed = true, eventEpochMs = 3000, nativeEventEpochMs = 3000,
                watched = if (mode == "alteredPayload") "foreign" else before.watched)
            rows = listOf(removed)
            if (mode == "accountChanged") current = false
            if (mode == "failedCommit") disk.failWrites = true
            transitions.completePrior(before.identity, if (mode == "ownerChanged") "new-owner" else "old-owner") { rows }
            assertNull(mode, OwnerLibraryPublicationProofs(disk).published("B", native, removed))
        }
    }

    @Test fun `cold add pending witness chains to first playback through a separate lease`() {
        val proofs = OwnerLibraryPublicationProofs(MemoryLibraryProofPersistence())
        val native = NativeLibraryOwner("shared")
        val transitions = OwnerLibraryPendingTransitions()
        var rows = emptyList<VortXSyncDoc.OwnerLibraryItem>()
        val cold = publicationRow().copy(videoId = null, timeOffsetMs = 0, durationMs = 0)
        val add = OwnerLibraryPublicationLease("B", proofs) { it() }
        add.mutateObserved(native, cold.identity, { rows }, OwnerLibraryOperation(OwnerLibraryOperation.Kind.MEMBERSHIP, name = cold.name), { rows.singleOrNull() }) {}
        transitions.record(cold.identity, "B-revision", add)
        rows = listOf(cold)
        assertTrue(transitions.completePrior(cold.identity, "B-revision") { rows })
        assertNull(proofs.published("B", native, cold)!!.lastWatched)
        val play = OwnerLibraryPublicationLease("B", proofs) { it() }
        val played = publicationRow(epoch = 3000)
        play.mutateObserved(native, cold.identity, { rows }, OwnerLibraryOperation(OwnerLibraryOperation.Kind.PROGRESS, cold.metaId, 1000, 10000), { played }) { rows = listOf(played) }
        assertEquals(played.lastWatched, proofs.published("B", native, played)!!.lastWatched)
        assertFalse(proofs.published("B", native, played)!!.historyOnly)
    }

    @Test fun `manual movie series season and episode intents never contain membership or viewing fields`() {
        val disk = MemoryLibraryProofPersistence()
        val store = OwnerWatchedIntentStore(disk) { 1000.0 }
        assertTrue(store.record("A", "tt1", listOf("tt1"), true))
        assertTrue(store.record("A", "tt2", listOf("tt2:1:1", "tt2:1:2"), true))
        assertTrue(store.record("A", "tt2", listOf("tt2:1:2"), false))
        val wire = store.wire("A", null)
        assertEquals(3, wire.length())
        for (key in wire.keys()) assertEquals(setOf("t", "v", "w", "u", "a"), wire.getJSONObject(key).keys().asSequence().toSet())
        assertEquals(setOf("tt2:1:1"), OwnerWatchedIntentStore.effectiveVideos(store.entries("A"), "tt2", emptySet(), setOf("tt2:1:1", "tt2:1:2")))
        assertTrue(OwnerWatchedIntentStore(disk).entries("B").isEmpty())
        assertEquals(3, OwnerWatchedIntentStore(disk).entries("A").size)
    }

    @Test fun `whole title baseline exact newer overrides actor tie and older replay converge`() {
        val store = OwnerWatchedIntentStore(MemoryLibraryProofPersistence()) { 1.0 }
        fun row(video: String, watched: Boolean, stamp: Double, actor: String) = OwnerWatchedIntentStore.Entry("tt1", video, watched, stamp, actor)
        val entries = listOf(row("tt1", true, 2000.0, "a"), row("tt1:1:1", false, 1999.0, "z"), row("tt1:1:2", false, 2000.0, "b"))
        assertTrue(store.merge("A", JSONObject().apply { entries.forEach { put(it.key, it.json()) } }))
        assertEquals(setOf("tt1:1:1"), OwnerWatchedIntentStore.effectiveVideos(store.entries("A"), "tt1", emptySet(), setOf("tt1:1:1", "tt1:1:2")))
        assertTrue(store.record("A", "tt1", listOf("tt1"), false))
        assertTrue(OwnerWatchedIntentStore.effectiveVideos(store.entries("A"), "tt1", setOf("tt1:1:1"), setOf("tt1:1:1")).isEmpty())
        assertTrue(store.entries("A").first { it.video == "tt1" }.updated > 2000)
    }

    @Test fun `manual failed durability and expired captured account do not publish`() {
        val disk = MemoryLibraryProofPersistence()
        val store = OwnerWatchedIntentStore(disk)
        var owner = "A"
        val lease = OwnerWatchedIntentLease("A", store) { if (owner == "A") it() else false }
        owner = "B"
        assertFalse(lease.record("tt1", listOf("tt1"), true))
        owner = "A"
        disk.failWrites = true
        assertFalse(lease.record("tt1", listOf("tt1"), true))
        assertTrue(OwnerWatchedIntentStore(disk).entries("A").isEmpty())
    }

    @Test fun `owner history preserves opaque peers and never becomes saved library or tombstone`() {
        val opaque = JSONArray().put("future").put(JSONArray().put(7))
        val vortx = JSONObject().put("library", JSONArray().put(JSONObject().put("id", "tt9").put("type", "movie")))
            .put("byProfile", JSONObject().put(UserProfile.OWNER_ID, JSONObject().put("future", true).put("ownerHistory", opaque)))
        val history = publicationRow().copy(removed = true, historyOnly = true, timeOffsetMs = 0)
        VortXSyncDoc.mergeLocalOwnerHistory(vortx, listOf(history))
        val wire = vortx.getJSONObject("byProfile").getJSONObject(UserProfile.OWNER_ID)
        assertTrue(wire.getBoolean("future"))
        assertEquals("future", wire.getJSONArray("ownerHistory").get(0))
        assertFalse(wire.getJSONArray("ownerHistory").getJSONObject(2).has("removed"))
        val parsed = VortXSyncDoc.parse(JSONObject().put("vortx", vortx))
        assertEquals("tt9", parsed.ownerLibrary!!.single().metaId)
        assertEquals(0L, parsed.ownerHistory.single().timeOffsetMs)
        assertTrue(parsed.ownerHistory.single().historyOnly)
        assertTrue(OwnerLibraryHistoryPolicy.canonicalLibraryTombstones(parsed).isEmpty())
    }

    @Test fun `cold native add timestamp is stripped and genuine first progress is watch only`() {
        val native = NativeLibraryOwner(null)
        val proofs = OwnerLibraryPublicationProofs(MemoryLibraryProofPersistence())
        val lease = OwnerLibraryPublicationLease("B", proofs) { it() }
        var rows = emptyList<VortXSyncDoc.OwnerLibraryItem>()
        val cold = publicationRow().copy(videoId = null, timeOffsetMs = 0, durationMs = 0)
        val add = OwnerLibraryOperation(OwnerLibraryOperation.Kind.MEMBERSHIP, name = "Movie")
        assertTrue(lease.mutateObserved(native, cold.identity, { rows }, add, { cold }) { rows = listOf(cold) })
        val outbound = proofs.published("B", native, cold)!!
        assertNull(outbound.lastWatched)
        assertNull(OwnerLibraryHistoryPolicy.clock(outbound))
        assertFalse(outbound.removed)
        val unsaved = publicationRow("tt2").copy(removed = true)
        rows = listOf(cold)
        val progress = OwnerLibraryOperation(OwnerLibraryOperation.Kind.PROGRESS, "tt2", 1000, 10000)
        assertTrue(lease.mutateObserved(native, unsaved.identity, { rows }, progress, { unsaved }) { rows = listOf(cold, unsaved) })
        assertTrue(proofs.published("B", native, unsaved)!!.historyOnly)
    }

    @Test fun `deferred exact model disk witness persists authorized projection and rejects payload mismatch`() {
        for (mode in listOf("good", "payload", "expired", "replacement", "failedCommit", "restart")) {
            val disk = MemoryLibraryProofPersistence()
            val proofs = OwnerLibraryPublicationProofs(disk)
            var current = true
            val native = NativeLibraryOwner("shared")
            val lease = OwnerLibraryPublicationLease("B", proofs) { if (current) it() else false }
            val after = publicationRow().copy(removed = true)
            var rows = emptyList<VortXSyncDoc.OwnerLibraryItem>()
            val operation = OwnerLibraryOperation(OwnerLibraryOperation.Kind.PROGRESS, "tt1", 1000, 10000)
            assertTrue(lease.mutateObserved(native, after.identity, { rows }, operation, { after }) {})
            assertFalse(proofs.owns("B", native, after))
            rows = listOf(if (mode == "payload") after.copy(watched = "foreign") else after)
            if (mode == "expired") current = false
            if (mode == "replacement") lease.invalidate()
            if (mode == "failedCommit") disk.failWrites = true
            val completion = if (mode == "restart") OwnerLibraryPublicationLease("B", OwnerLibraryPublicationProofs(disk)) { it() } else lease
            completion.completePending(after.identity) { rows }
            assertEquals(mode, mode == "good", OwnerLibraryPublicationProofs(disk).owns("B", native, after))
            assertFalse(proofs.owns("A", native, after))
        }
    }

    @Test fun `resident foreign row and unrelated newly present row never acquire operation proof`() {
        val proofs = OwnerLibraryPublicationProofs(MemoryLibraryProofPersistence())
        val native = NativeLibraryOwner(null)
        val lease = OwnerLibraryPublicationLease("B", proofs) { it() }
        var rows = listOf(publicationRow(epoch = 1000))
        val after = publicationRow()
        lease.mutateObserved(native, after.identity, { rows }, OwnerLibraryOperation(OwnerLibraryOperation.Kind.PROGRESS, "tt1", 1000, 10000), { after }) {
            rows = listOf(after, publicationRow("tt99"))
        }
        assertFalse(proofs.owns("B", native, after))
        assertFalse(proofs.owns("B", native, rows.last()))
    }

    @Test fun `manual raw transition retains prior genuine viewing clock and outbound authority`() {
        val proofs = OwnerLibraryPublicationProofs(MemoryLibraryProofPersistence())
        val native = NativeLibraryOwner(null)
        val before = publicationRow().copy(removed = true)
        val outbound = before.copy(historyOnly = true)
        assertTrue(proofs.grantProjected("B", native, listOf(before to outbound)))
        var rows = listOf(before)
        val after = before.copy(nativeEventEpochMs = 3000, eventEpochMs = 3000, lastWatched = "1970-01-01T00:00:03Z", watched = "opaque-manual", timesWatched = 1)
        val lease = OwnerLibraryPublicationLease("B", proofs) { it() }
        lease.mutateObserved(native, before.identity, { rows }, OwnerLibraryOperation(OwnerLibraryOperation.Kind.MANUAL, manualWhole = true, manualWatched = true), { after }) { rows = listOf(after) }
        assertEquals(outbound, proofs.published("B", native, after))
    }

    @Test fun `actual model shape matches raw disk clocks zero and opaque watched exactly`() {
        val model = JSONObject("""{"_id":"tt1","type":"movie","name":"Movie","removed":true,"temp":true,"_mtime":"1970-01-01T00:00:03Z","state":{"lastWatched":"1970-01-01T00:00:02Z","timeOffset":0,"duration":10000,"timesWatched":1,"flaggedWatched":1,"video_id":"tt1","watched":"opaque"}}""")
        val candidate = OwnerLibraryOperation.modelCandidate(model)!!
        assertEquals(3000L, candidate.nativeEventEpochMs)
        assertEquals(2000L, OwnerLibraryHistoryPolicy.watchClock(candidate))
        assertEquals(0L, candidate.timeOffsetMs)
        assertEquals("opaque", candidate.watched)
        assertTrue(candidate.currentVideoWatched == true)
        model.getJSONObject("state").remove("lastWatched")
        assertNull(OwnerLibraryOperation.modelCandidate(model))
    }

    @Test fun `cold remote metadata admission needs positive absence and captured owner then admits real playback`() {
        for (uid in listOf(null, "shared")) for (mode in listOf("good", "readFailure", "foreign", "stale", "persistFailure")) {
            val disk = MemoryLibraryProofPersistence()
            val proofs = OwnerLibraryPublicationProofs(disk)
            val native = NativeLibraryOwner(uid)
            var current = true
            val lease = OwnerLibraryPublicationLease("B", proofs) { if (current) it() else false }
            val cold = publicationRow().copy(videoId = null, timeOffsetMs = 0, durationMs = 0)
            var rows: List<VortXSyncDoc.OwnerLibraryItem>? = when (mode) {
                "readFailure" -> null
                "foreign" -> listOf(publicationRow(epoch = 1000))
                else -> emptyList()
            }
            val add = OwnerLibraryOperation(OwnerLibraryOperation.Kind.MEMBERSHIP, name = "Movie")
            lease.mutateObserved(native, cold.identity, { rows }, add, { rows?.singleOrNull() }) { /* asynchronous metadata Add */ }
            rows = listOf(cold)
            if (mode == "stale") current = false
            if (mode == "persistFailure") disk.failWrites = true
            lease.completePending(cold.identity) { rows }
            assertEquals("$uid:$mode", mode == "good", proofs.owns("B", native, cold))
            if (mode == "good") {
                assertNull(proofs.published("B", native, cold)!!.lastWatched)
                val played = publicationRow(epoch = 3000).copy(lastWatched = "1970-01-01T00:00:03Z")
                lease.mutateObserved(native, cold.identity, { rows }, OwnerLibraryOperation(OwnerLibraryOperation.Kind.PROGRESS, "tt1", 1000, 10000), { played }) { rows = listOf(played) }
                assertEquals(3000L, OwnerLibraryHistoryPolicy.watchClock(proofs.published("B", native, played)!!))
            }
        }
    }

    @Test fun `ctx mtime refresh may complete original exact progress but changed video cannot`() {
        val proofs = OwnerLibraryPublicationProofs(MemoryLibraryProofPersistence())
        val native = NativeLibraryOwner(null)
        val lease = OwnerLibraryPublicationLease("B", proofs) { it() }
        var model = publicationRow().copy(removed = true)
        var rows = emptyList<VortXSyncDoc.OwnerLibraryItem>()
        lease.mutateObserved(native, model.identity, { rows }, OwnerLibraryOperation(OwnerLibraryOperation.Kind.PROGRESS, "tt1", 1000, 10000), { model }) {}
        val stamped = model.copy(nativeEventEpochMs = 2001, eventEpochMs = 2001)
        rows = listOf(stamped)
        model = stamped.copy(videoId = "tt99")
        assertFalse(lease.completePending(stamped.identity) { rows })
        assertFalse(proofs.owns("B", native, stamped))
        model = stamped
        assertTrue(lease.completePending(stamped.identity) { rows })
        assertTrue(proofs.published("B", native, stamped)!!.historyOnly)
    }

    @Test fun `first manual movie and episode use constructor clock only for raw proof then actual playback advances`() {
        for (uid in listOf(null, "shared")) for (type in listOf("movie", "series")) for (mode in listOf("good", "failedRead", "foreign", "expired", "badWitness")) {
            val proofs = OwnerLibraryPublicationProofs(MemoryLibraryProofPersistence())
            val native = NativeLibraryOwner(uid)
            var current = true
            val lease = OwnerLibraryPublicationLease("B", proofs) { if (current) it() else false }
            val model = JSONObject("""{"_id":"tt1","type":"$type","name":"Movie","removed":true,"temp":true,"_mtime":"1970-01-01T00:00:02Z","watchedVideoIds":[],"state":{"lastWatched":"1970-01-01T00:00:02Z","timeOffset":0,"duration":0,"timeWatched":0,"overallTimeWatched":0,"timesWatched":0,"flaggedWatched":0,"video_id":null,"watched":null}}""")
            // Raw detail wraps libraryItem; watchedVideoIds is an explicit sibling, not a parser default.
            val detail = JSONObject().put("libraryItem", model).put("watchedVideoIds", JSONArray())
            val base = OwnerLibraryOperation(OwnerLibraryOperation.Kind.MANUAL, name = "Movie", manualWatched = true,
                manualWhole = type == "movie", manualInventory = listOf("tt1:1:1", "tt1:1:2"), manualVideos = setOf("tt1:1:1"))
            val operation = base.copy(manualInitial = base.admitsInitialManual(detail, "$type:tt1"))
            assertTrue(operation.manualInitial)
            if (mode == "badWitness") detail.remove("watchedVideoIds")
            model.put("_mtime", "1970-01-01T00:00:03Z")
            model.getJSONObject("state").put("timesWatched", if (type == "movie") 1 else 0)
                .put("watched", if (type == "series") "opaque-episode" else JSONObject.NULL)
            if (mode != "badWitness") detail.put("watchedVideoIds", JSONArray().apply { if (type == "series") put("tt1:1:1") })
            val marked = OwnerLibraryOperation.modelCandidate(model)!!
            var rows: List<VortXSyncDoc.OwnerLibraryItem>? = when (mode) { "failedRead" -> null; "foreign" -> listOf(marked.copy(nativeEventEpochMs = 1000)); else -> emptyList() }
            lease.mutateObserved(native, marked.identity, { rows }, operation, { marked.takeIf { operation.acceptsManualModel(detail, it) } }) {}
            rows = listOf(marked)
            if (mode == "expired") current = false
            lease.completePending(marked.identity) { rows }
            val expected = mode == "good" || (mode == "badWitness" && type == "movie")
            assertEquals("$uid:$type:$mode", expected, proofs.owns("B", native, marked))
            if (expected) {
                val outgoing = proofs.published("B", native, marked)!!
                assertTrue(outgoing.historyOnly)
                assertNull(outgoing.lastWatched)
                assertNull(outgoing.eventEpochMs)
                assertNull(outgoing.watched)
                val played = marked.copy(videoId = if (type == "series") "tt1:1:1" else "tt1", timeOffsetMs = 2500, durationMs = 10000,
                    lastWatched = "1970-01-01T00:00:04Z", nativeEventEpochMs = 4000, eventEpochMs = 4000)
                lease.mutateObserved(native, marked.identity, { rows }, OwnerLibraryOperation(OwnerLibraryOperation.Kind.PROGRESS, played.videoId, 2500, 10000), { played }) { rows = listOf(played) }
                assertEquals(4000L, OwnerLibraryHistoryPolicy.watchClock(proofs.published("B", native, played)!!))
                assertTrue(proofs.published("B", native, played)!!.historyOnly)
            }
        }
    }

    @Test fun `disk absence with foreign memory flags grants progress only across later ticks and restart`() {
        val disk = MemoryLibraryProofPersistence()
        var proofs = OwnerLibraryPublicationProofs(disk)
        val native = NativeLibraryOwner(null)
        var rows = emptyList<VortXSyncDoc.OwnerLibraryItem>()
        val after = publicationRow().copy(removed = false, watched = "foreign-bits", timesWatched = 1, currentVideoWatched = true, wholeTitleWatched = true)
        var lease = OwnerLibraryPublicationLease("B", proofs) { it() }
        lease.mutateObserved(native, after.identity, { rows }, OwnerLibraryOperation(OwnerLibraryOperation.Kind.PROGRESS, "tt1", 1000, 10000), { after }) { rows = listOf(after) }
        val outbound = proofs.published("B", native, after)!!
        assertTrue(outbound.historyOnly)
        assertTrue(outbound.removed)
        assertNull(outbound.watched)
        assertNull(outbound.timesWatched)
        assertNull(outbound.wholeTitleWatched)
        proofs = OwnerLibraryPublicationProofs(disk)
        lease = OwnerLibraryPublicationLease("B", proofs) { it() }
        val later = after.copy(timeOffsetMs = 2000, eventEpochMs = 3000, nativeEventEpochMs = 3000)
        lease.mutateObserved(native, later.identity, { rows }, OwnerLibraryOperation(OwnerLibraryOperation.Kind.PROGRESS, "tt1", 2000, 10000), { later }) { rows = listOf(later) }
        val wire = OwnerLibraryHistoryPolicy.encode(proofs.published("B", native, later)!!, JSONObject())
        for (field in listOf("watched", "timesWatched", "currentVideoWatched", "wholeTitleWatched", "removed")) assertFalse(field, wire.has(field))
        val peer = JSONObject(wire.toString()).put("eventEpochMs", 1000).put("watched", "B-peer-bits").put("timesWatched", 4)
        val merged = OwnerLibraryHistoryPolicy.merge(JSONArray().put(peer), listOf(proofs.published("B", native, later)!!), emptySet(), VortXSyncDoc::ownerHistoryItem)
        assertEquals("B-peer-bits", merged.getJSONObject(0).getString("watched"))
        assertEquals(4, merged.getJSONObject(0).getInt("timesWatched"))
    }

    @Test fun `history schema refuses unsupported shapes malformed playback and overlimit without replacement`() {
        val history = publicationRow().copy(removed = true, historyOnly = true)
        val valid = OwnerLibraryHistoryPolicy.encode(history, JSONObject())
        assertNotNull(VortXSyncDoc.ownerHistoryItem(valid))
        for (mutate in listOf<(JSONObject) -> Unit>(
            { it.remove("eventEpochMs") }, { it.put("eventEpochMs", 2000.5) }, { it.put("eventEpochMs", 9_007_199_254_740_992L) },
            { it.put("v", "") }, { it.put("name", "") }, { it.put("d", 0) }, { it.put("t", 2_000_001) }, { it.put("d", 2_000_001) },
        )) assertNull(VortXSyncDoc.ownerHistoryItem(JSONObject(valid.toString()).also(mutate)))
        for (unsupported in listOf<Any>("future", JSONObject().put("format", 2), JSONArray((0..10_000).map { "future" }))) {
            val owner = JSONObject().put("ownerHistory", unsupported)
            val vortx = JSONObject().put("byProfile", JSONObject().put(UserProfile.OWNER_ID, owner))
            val original = owner.toString()
            VortXSyncDoc.mergeLocalOwnerHistory(vortx, listOf(history))
            assertEquals(original, owner.toString())
            assertTrue(VortXSyncDoc.ownerHistory(vortx).isEmpty())
        }
    }

    @Test fun `only fully pristine captured player permits first native completion fields`() {
        val raw = JSONObject("""{"_id":"tt1","type":"movie","name":"Movie","removed":true,"temp":true,"_mtime":"1970-01-01T00:00:02Z","state":{"lastWatched":"1970-01-01T00:00:02Z","timeOffset":0,"duration":0,"timeWatched":0,"overallTimeWatched":0,"timesWatched":0,"flaggedWatched":0,"video_id":null,"watched":null}}""")
        val model = JSONObject().put("libraryItem", raw)
        val operation = OwnerLibraryOperation(OwnerLibraryOperation.Kind.PROGRESS, "tt1", 9000, 10000, "Movie")
        assertTrue(operation.admitsInitialProgress(model, "movie:tt1"))
        for (field in listOf("timeWatched", "overallTimeWatched", "timesWatched", "flaggedWatched")) {
            raw.getJSONObject("state").put(field, 1)
            assertFalse(field, operation.admitsInitialProgress(model, "movie:tt1"))
            raw.getJSONObject("state").put(field, 0)
        }
        val after = publicationRow().copy(timeOffsetMs = 9000, timesWatched = 1, wholeTitleWatched = true, currentVideoWatched = true, removed = true)
        val authorized = operation.copy(progressInitial = true).projection(null, null, after)!!
        assertTrue(authorized.wholeTitleWatched == true)
        assertEquals(1L, authorized.timesWatched)
        assertTrue(authorized.historyOnly)
    }

    @Test fun `malformed durable field authority cannot promote a progress-only proof`() {
        val disk = MemoryLibraryProofPersistence()
        val proofs = OwnerLibraryPublicationProofs(disk)
        val raw = publicationRow()
        val native = NativeLibraryOwner(null)
        assertTrue(proofs.grantProjected("B", native, listOf(raw to raw.copy(historyOnly = true, declaredWatchFields = emptySet()))))
        val key = disk.data.keys.single()
        val ledger = JSONObject(disk.data.getValue(key))
        ledger.getJSONObject(ledger.keys().next()).getJSONObject("outbound").put("watchAuthority", "all")
        disk.data[key] = ledger.toString()
        assertNull(OwnerLibraryPublicationProofs(disk).published("B", native, raw))
    }
}
