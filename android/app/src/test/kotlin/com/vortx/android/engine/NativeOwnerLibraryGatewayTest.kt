package com.vortx.android.engine

import com.vortx.android.sync.OwnerLibraryHistoryPolicy
import com.vortx.android.sync.VortXSyncDoc
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.time.Instant

class NativeOwnerLibraryGatewayTest {
    @Test fun `restore ownership witness requires successful exact receipt and matching postread`() {
        for (mode in listOf("exact", "noOp", "wrongReceipt", "unavailablePost", "alteredPost", "expiredPost", "metadata")) {
            val requested = item().copy(currentVideoWatched = null)
            var current = if (mode == "noOp") listOf(requested) else emptyList()
            var restored = false
            var active = true
            var witnessed = emptyList<VortXSyncDoc.OwnerLibraryItem>()
            val gateway = NativeOwnerLibraryGateway(read = {
                if (restored && mode == "expiredPost") active = false
                if (restored && mode == "unavailablePost") "null" else projection(current)
            }, restore = { request ->
                restored = true
                current = listOf(if (mode == "alteredPost") requested.copy(timeOffsetMs = 999) else requested)
                if (mode == "wrongReceipt") "null" else receipt(request)
            }, add = {})
            val incoming = if (mode == "metadata") requested.copy(lastWatched = null, eventEpochMs = null, watched = null, timesWatched = 0) else requested
            gateway.apply("native", listOf(incoming), { operation -> active && operation() }) { witnessed = it }
            assertEquals(mode, if (mode == "exact") 1 else 0, witnessed.size)
        }
    }

    private val permit: ((() -> Boolean) -> Boolean) = { it() }
    private fun item(id: String = "tt1", epoch: Long = 2000, type: String = "series") = VortXSyncDoc.OwnerLibraryItem(
        id, type, "Title", null, if (type == "movie") id else "$id:1:2", 0, 50_000,
        Instant.ofEpochMilli(epoch).toString(), watched = "exact-opaque-bitfield", currentVideoWatched = false,
        timesWatched = 1, eventEpochMs = epoch,
    )
    private fun projection(items: List<VortXSyncDoc.OwnerLibraryItem>, uid: String? = "native") = JSONObject()
        .put("uid", uid ?: JSONObject.NULL).put("events", JSONArray(items.map { i -> JSONObject()
            .put("meta", JSONObject().put("id", i.metaId).put("type", i.type).put("name", i.name))
            .put("currentVideoId", i.videoId ?: JSONObject.NULL).put("timeOffsetMs", i.timeOffsetMs).put("durationMs", i.durationMs)
            .put("eventEpochMs", i.nativeEventEpochMs ?: i.eventEpochMs ?: 1000)
            .put("lastWatchedEpochMs", OwnerLibraryHistoryPolicy.watchClock(i) ?: JSONObject.NULL)
            .put("watched", i.watched ?: JSONObject.NULL).put("currentVideoWatched", i.currentVideoWatched ?: JSONObject.NULL)
            .put("wholeTitleWatched", i.wholeTitleWatched ?: JSONObject.NULL).put("timesWatched", i.timesWatched ?: 0)
            .put("removed", i.removed) })).toString()

    private fun receipt(request: String): String {
        val root = JSONObject(request)
        return JSONObject().put("uid", root.get("ownerUid")).put("events", JSONArray(
            (0 until root.getJSONArray("events").length()).map { n -> root.getJSONArray("events").getJSONObject(n).let { row ->
                JSONObject().put("id", row.getJSONObject("meta").get("id")).put("type", row.getJSONObject("meta").get("type"))
                    .put("currentVideoId", row.get("currentVideoId")).put("eventEpochMs", row.get("genuineEventEpochMs"))
            } },
        )).toString()
    }

    @Test fun `zero rewind and partial series state survive native request and projection`() {
        val expected = item()
        var sent: JSONObject? = null
        val gateway = NativeOwnerLibraryGateway({ projection(listOf(item(epoch = 1000))) }, { request ->
            sent = JSONObject(request).getJSONArray("events").getJSONObject(0); receipt(request)
        }, { fail("History must not use metadata AddToLibrary") })
        assertTrue(gateway.apply("native", listOf(expected), permit))
        val row = requireNotNull(sent)
        assertEquals(0L, row.getLong("timeOffsetMs"))
        assertEquals("exact-opaque-bitfield", row.getString("watched"))
        assertFalse(row.getBoolean("currentVideoWatched"))
        assertEquals(1, row.getInt("timesWatched"))
        assertTrue(row.isNull("wholeTitleWatched"))
        assertEquals(expected, gateway.parseProjection(projection(listOf(expected)), "native")!!.single().copy(nativeEventEpochMs = null))
    }

    @Test fun `manual movie watched event preserves null viewing clock and separate mutation clock`() {
        val movie = item(type = "movie").copy(lastWatched = null, wholeTitleWatched = true, currentVideoWatched = true)
        var sent: JSONObject? = null
        val gateway = NativeOwnerLibraryGateway({ projection(emptyList(), null) }, { request ->
            sent = JSONObject(request).getJSONArray("events").getJSONObject(0); receipt(request)
        }, {})
        assertTrue(gateway.apply(null, listOf(movie), permit))
        assertTrue(sent!!.isNull("lastWatchedEpochMs"))
        assertTrue(sent!!.getBoolean("wholeTitleWatched"))
        assertEquals("tt1", sent!!.getString("currentVideoId"))
        val laterMutation = item().copy(eventEpochMs = 9000, nativeEventEpochMs = 9000)
        val restored = gateway.parseProjection(projection(listOf(laterMutation)), "native")!!.single()
        assertEquals(9000L, OwnerLibraryHistoryPolicy.clock(restored))
        assertEquals(2000L, OwnerLibraryHistoryPolicy.watchClock(restored))
    }

    @Test fun `metadata only adds missing membership without restore or invented history`() {
        val meta = item().copy(lastWatched = null, eventEpochMs = null, watched = null, timesWatched = 0, currentVideoWatched = false)
        var added = 0
        val gateway = NativeOwnerLibraryGateway({ projection(emptyList()) }, { fail("No history restore"); "null" }, { added++ })
        assertTrue(gateway.apply("native", listOf(meta), permit))
        assertEquals(1, added)
        val existing = NativeOwnerLibraryGateway({ projection(listOf(meta)) }, { fail("No history restore"); "null" }, { fail("Already present") })
        assertTrue(existing.apply("native", listOf(meta), permit))
        assertNull(existing.snapshot("native", permit)!!.single().eventEpochMs)
    }

    @Test fun `fresh native read filters older equal and newer peer events by native mutation floor`() {
        val local = item(epoch = 1000).copy(nativeEventEpochMs = 3000)
        var count = 0
        val gateway = NativeOwnerLibraryGateway({ projection(listOf(local)) }, { count++; receipt(it) }, {})
        for (epoch in listOf(999L, 2000L, 3000L)) assertTrue(gateway.apply("native", listOf(item(epoch = epoch)), permit))
        assertEquals(0, count)
        assertTrue(gateway.apply("native", listOf(item(epoch = 3001)), permit))
        assertEquals(1, count)
    }

    @Test fun `literal null wrong uid missing nullable fields and duplicate receipts never acknowledge`() {
        val events = listOf(item(), item(id = "tt2"))
        for (mode in listOf("null", "wrongUid", "missingUid", "duplicates", "wrongVideo", "wrongEpoch", "missingVideo")) {
            val gateway = NativeOwnerLibraryGateway({ projection(emptyList()) }, { request ->
                if (mode == "null") "null" else JSONObject(receipt(request)).apply {
                    when (mode) {
                        "wrongUid" -> put("uid", "other")
                        "missingUid" -> remove("uid")
                        "duplicates" -> getJSONArray("events").put(1, getJSONArray("events").getJSONObject(0))
                        "wrongVideo" -> getJSONArray("events").getJSONObject(0).put("currentVideoId", "other")
                        "wrongEpoch" -> getJSONArray("events").getJSONObject(0).put("eventEpochMs", 2001)
                        "missingVideo" -> getJSONArray("events").getJSONObject(0).remove("currentVideoId")
                    }
                }.toString()
            }, { fail("Failed batch must not continue to membership writes") })
            assertFalse(mode, gateway.apply("native", events, permit))
        }
        val gateway = NativeOwnerLibraryGateway({ "null" }, { "null" }, {})
        assertNull(gateway.parseProjection("{\"events\":[]}", null))
        assertNull(gateway.parseProjection(projection(emptyList(), "wrong"), "native"))
    }

    @Test fun `one native conflict rejects complete batch and prevents metadata continuation`() {
        var writes = 0
        val gateway = NativeOwnerLibraryGateway({ projection(emptyList()) }, { request ->
            assertEquals(2, JSONObject(request).getJSONArray("events").length())
            // Native transaction discovered a conflict after the read; its all-or-nothing failure is final.
            writes++; "null"
        }, { fail("No partial fallback") })
        assertFalse(gateway.apply("native", listOf(item(), item(id = "tt2"), item(id = "tt3").copy(lastWatched = null, eventEpochMs = null)), permit))
        assertEquals(1, writes)
    }

    @Test fun `same native uid account replacement before dispatch or after read cannot write or publish`() {
        for (switchAfterRead in listOf(false, true)) {
            var account = "A"
            val admit: ((() -> Boolean) -> Boolean) = { action -> account == "A" && action() }
            val gateway = NativeOwnerLibraryGateway({
                if (switchAfterRead) account = "B"
                projection(emptyList())
            }, { fail("Stale A cannot write native uid shared with B"); "null" }, { fail("Stale A cannot add") })
            if (!switchAfterRead) account = "B"
            assertFalse(gateway.apply("native", listOf(item()), admit))
            account = "A"
            if (!switchAfterRead) account = "B"
            assertNull(gateway.snapshot("native", admit))
        }
    }

    @Test fun `same native uid replacement after response cannot acknowledge`() {
        var current = true
        val gateway = NativeOwnerLibraryGateway({ projection(emptyList()) }, { current = false; receipt(it) }, {})
        assertFalse(gateway.apply("native", listOf(item()), { action -> current && action() }))
    }

    @Test fun `local LWW updates existing row only when newer and preserves all opaque peer data`() {
        val prior = JSONObject().put("id", "tt1").put("type", "series").put("name", "Peer metadata")
            .put("v", "tt1:1:1").put("t", 40).put("d", 50).put("lastWatched", Instant.ofEpochMilli(2000).toString())
            .put("opaque", JSONObject().put("nested", true)).put("watched", "peer-bitfield")
        for (local in listOf(item(epoch = 1000), item(), item().copy(lastWatched = null, eventEpochMs = null))) {
            assertEquals(prior.toString(), OwnerLibraryHistoryPolicy.merge(JSONArray().put(prior), listOf(local), emptySet()).getJSONObject(0).toString())
        }
        val merged = OwnerLibraryHistoryPolicy.merge(JSONArray().put(prior), listOf(item(epoch = 3000)), emptySet()).getJSONObject(0)
        assertTrue(merged.getJSONObject("opaque").getBoolean("nested"))
        assertEquals(0.0, merged.getDouble("t"), 0.0)
        assertEquals("exact-opaque-bitfield", merged.getString("watched"))
        val malformed = JSONObject(prior.toString()).put("lastWatched", "not-a-clock")
        assertEquals(malformed.toString(), OwnerLibraryHistoryPolicy.merge(JSONArray().put(malformed), listOf(item(epoch = 3000)), emptySet()).getJSONObject(0).toString())
    }

    @Test fun `malformed progress cannot become an authenticated zero rewind`() {
        val row = JSONObject().put("id", "tt1").put("type", "movie").put("t", "bad").put("d", 10)
            .put("lastWatched", Instant.ofEpochMilli(2000).toString())
        assertNull(VortXSyncDoc.ownerLibraryItem(row))
    }

    @Test fun `removed membership contributes genuine tombstone while newer explicit readd survives`() {
        val row = JSONObject().put("id", "tt1").put("type", "movie").put("t", 0).put("d", 0).put("removed", true).put("eventEpochMs", 2000)
        val doc = JSONObject().put("vortx", JSONObject().put("library", JSONArray().put(row)))
            .put("webProgress", JSONObject().put("tt2", JSONObject().put("removed", true)))
        val stamps = OwnerLibraryHistoryPolicy.canonicalLibraryTombstones(VortXSyncDoc.parse(doc))
        assertEquals(mapOf("tt1" to mapOf("removedAt" to 2000.0)), stamps)
        assertTrue(OwnerLibraryHistoryPolicy.merge(JSONArray(), listOf(item()), setOf("tt1")).length() == 0)
    }
}
