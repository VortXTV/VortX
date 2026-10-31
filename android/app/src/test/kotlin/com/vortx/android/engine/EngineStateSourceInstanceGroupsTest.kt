package com.vortx.android.engine

import com.vortx.android.ui.tv.TvSourceItem
import com.vortx.android.ui.tv.TvSourceJumpLease
import com.vortx.android.ui.tv.tvSourceGroupKey
import com.vortx.android.ui.tv.tvSourceSectionIndex
import com.vortx.android.ui.tv.tvSourceWindow
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class EngineStateSourceInstanceGroupsTest {
    private val baseA = "https://aio.example.invalid/config-a/manifest.json?fixture=a"
    private val baseB = "https://aio.example.invalid/config-b/manifest.json?fixture=b"
    private val target = "tt123"

    @Test
    fun actualProjectionCanSupplyBothLanesForOneConfiguredAddon() {
        val addon = VortxResourceAddon(baseA, baseA)
        val metaRequest = VortxResourceRequest(VortxResourceRequest.Resource.META, "movie", target)
        val streamRequest = VortxResourceRequest(VortxResourceRequest.Resource.STREAM, "movie", target)
        val embedded = stream("embedded")
        val resource = stream("resource")
        val metadata = JSONObject().put("meta", JSONObject().put("id", target).put("type", "movie")
            .put("streams", JSONArray().put(embedded)))
        val meta = snapshot(metaRequest, addon, metadata)
        val streams = snapshot(streamRequest, addon, JSONObject().put("streams", JSONArray().put(resource)))

        val projection = VortxResourceProjection.metaDetails(meta, streams, streamRequest, listOf(addon))
        val wire = JSONObject(projection)
        assertEquals(1, wire.getJSONArray("metaStreams").length())
        assertEquals(1, wire.getJSONArray("streams").length())
        val groups = EngineState.parseStreamGroups(projection, target)

        assertEquals(1, groups.size)
        assertEquals(baseA, groups.single().base)
        assertEquals(listOf(url("embedded"), url("resource")), groups.single().streams.map { it.url })
    }

    @Test
    fun sameHostConfigurationsRemainSeparateAndKeepFirstSeenOrder() {
        val same = stream("shared")
        val json = payload(
            listOf(entry(baseB, listOf(same)), entry(baseA, listOf(same))),
            listOf(entry(baseA, listOf(stream("a-tail"))), entry(baseB, listOf(stream("b-tail")))),
        )

        val groups = EngineState.parseStreamGroups(json, target)

        assertEquals(listOf(baseB, baseA), groups.map { it.base })
        assertEquals(1, groups.map { it.addon }.distinct().size)
        assertEquals(listOf(url("shared"), url("b-tail")), groups[0].streams.map { it.url })
        assertEquals(listOf(url("shared"), url("a-tail")), groups[1].streams.map { it.url })
    }

    @Test
    fun deduplicatesOnlyFullRecordsAndPreservesEqualIdTransportVariants() {
        val original = stream("same").put("fileIdx", 0).put("behaviorHints", headers("first"))
        val otherFile = JSONObject(original.toString()).put("fileIdx", 1)
        val otherHeaders = JSONObject(original.toString()).put("behaviorHints", headers("second"))
        val json = payload(
            listOf(entry(baseA, listOf(original))),
            listOf(entry(baseA, listOf(JSONObject(original.toString()), otherFile, otherHeaders))),
        )

        val streams = EngineState.parseStreamGroups(json, target).single().streams

        assertEquals(3, streams.size)
        assertEquals(1, streams.map { it.id }.distinct().size)
        assertEquals(listOf(0, 1, 0), streams.map { it.fileIdx })
        assertEquals(listOf("first", "first", "second"), streams.map { it.requestHeaders["X-Fixture"] })
    }

    @Test
    fun loneConfiguredReadyGroupPreservesRepeatedRows() {
        val repeated = stream("same")
        val groups = EngineState.parseStreamGroups(payload(emptyList(),
            listOf(entry(baseA, listOf(repeated, JSONObject(repeated.toString()))))), target)

        assertEquals(1, groups.size)
        assertEquals(2, groups.single().streams.size)
        assertEquals(groups.single().streams[0], groups.single().streams[1])
    }

    @Test
    fun selectedEpisodeFilteringOccursBeforeCoalescing() {
        val old = entry(baseA, listOf(stream("old")), "show:1:1")
        val embedded = entry(baseA, listOf(stream("selected-meta")), "show:1:2")
        val resource = entry(baseA, listOf(stream("selected-resource")), "show:1:2")

        val groups = EngineState.parseStreamGroups(payload(listOf(old, embedded), listOf(resource)), "show:1:2")

        assertEquals(1, groups.size)
        assertEquals(listOf(url("selected-meta"), url("selected-resource")), groups.single().streams.map { it.url })
    }

    @Test
    fun absentConfiguredBaseRetainsIndependentGroupsAndOriginalRows() {
        val repeated = stream("same")
        val groups = EngineState.parseStreamGroups(payload(
            listOf(entry("", listOf(repeated, JSONObject(repeated.toString())))),
            listOf(entry("", listOf(stream("tail")))),
        ), target)

        assertEquals(2, groups.size)
        assertEquals(listOf(2, 1), groups.map { it.streams.size })
    }

    @Test
    fun tvTabsFocusCollapseAndCountsUseOneGroupPerExactConfiguration() {
        val duplicate = stream("shared")
        val groups = EngineState.parseStreamGroups(payload(
            listOf(entry(baseA, listOf(duplicate)), entry(baseB, listOf(stream("b")))),
            listOf(entry(baseA, listOf(JSONObject(duplicate.toString()), stream("a-tail")))),
        ), target)
        val keys = groups.mapIndexed { index, group -> tvSourceGroupKey(group, index) }
        val window = tvSourceWindow(groups, setOf(keys[0]), 40, keys[1])
        val headers = window.filterIsInstance<TvSourceItem.Header>()
        val rows = window.filterIsInstance<TvSourceItem.Row>()

        assertEquals(2, keys.size)
        assertEquals(keys.size, keys.toSet().size)
        assertEquals(listOf(2, 1), headers.map { it.count })
        assertTrue(headers[0].collapsed)
        assertFalse(headers[1].collapsed)
        assertEquals(listOf(keys[1]), rows.map { it.groupKey })
        assertEquals(keys[1], (window[requireNotNull(tvSourceSectionIndex(window, keys[1]))] as TvSourceItem.Header).key)
        val lease = TvSourceJumpLease(keys[1], requestRevision = 3, focusRevision = 5L)
        assertTrue(lease.stillOwns(3, 5L, keys))
        assertFalse(lease.stillOwns(3, 6L, keys))
    }

    private fun snapshot(request: VortxResourceRequest, addon: VortxResourceAddon, content: JSONObject) =
        VortxResourceSnapshot("owner", "request", 1L, request,
            listOf(VortxResourceGroup(addon.id, "ready", content.toString(), null)), mapOf(addon.id to addon.transportUrl))

    private fun entry(base: String, streams: List<JSONObject>, streamId: String = target) = JSONObject()
        .put("request", JSONObject().put("base", base).put("path", JSONObject().put("id", streamId)))
        .put("content", JSONObject().put("type", "Ready").put("content", JSONArray(streams)))

    private fun payload(meta: List<JSONObject>, streams: List<JSONObject>) = JSONObject()
        .put("metaStreams", JSONArray(meta)).put("streams", JSONArray(streams)).toString()

    private fun stream(name: String) = JSONObject().put("url", url(name)).put("name", "Fixture")
    private fun url(name: String) = "https://media.example.invalid/$name"
    private fun headers(value: String) = JSONObject().put("proxyHeaders",
        JSONObject().put("request", JSONObject().put("X-Fixture", value)))
}
