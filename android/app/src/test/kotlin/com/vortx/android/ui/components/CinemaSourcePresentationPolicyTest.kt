package com.vortx.android.ui.components

import com.vortx.android.model.StreamGroup
import com.vortx.android.model.StreamSource
import com.vortx.android.engine.EngineState
import com.vortx.android.engine.VortxResourceAddon
import com.vortx.android.engine.VortxResourceGroup
import com.vortx.android.engine.VortxResourceProjection
import com.vortx.android.engine.VortxResourceRequest
import com.vortx.android.engine.VortxResourceSnapshot
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CinemaSourcePresentationPolicyTest {
    @Test fun `jump preserves installed order and all neighboring source sections`() {
        val groups = listOf(group("Z first", 4), group("A second", 4), group("Middle last", 4))
        val target = cinemaSourceGroupKey(groups[1], 1)
        val entries = cinemaSourceWindow(groups, emptySet(), 60, target)

        assertEquals(groups.map { it.addon }, entries.filterIsInstance<CinemaSourceItem.Header>().map { it.addon })
        assertEquals(groups.flatMap { it.streams }, entries.filterIsInstance<CinemaSourceItem.Row>().map { it.source })
    }

    @Test fun `late selected addon renders bounded nearby rows not preceding thousands`() {
        val groups = listOf(group("Large first", 5_000), group("Late", 2_000))
        val target = cinemaSourceGroupKey(groups[1], 1)
        val rows = cinemaSourceWindow(groups, emptySet(), 60, target).filterIsInstance<CinemaSourceItem.Row>()

        assertEquals(120, rows.size)
        assertEquals(60, rows.count { it.groupKey == target })
        assertEquals(groups[1].streams.take(60), rows.filter { it.groupKey == target }.map { it.source })
    }

    @Test fun `identical display labels do not alias transport selection or collapse state`() {
        val groups = listOf(group("Shared", 4, "https://one.invalid"), group("Shared", 4, "https://two.invalid"))
        val first = cinemaSourceGroupKey(groups[0], 0)
        val second = cinemaSourceGroupKey(groups[1], 1)
        assertNotEquals(first, second)

        val entries = cinemaSourceWindow(groups, setOf(first), 60, second)
        assertTrue(entries.filterIsInstance<CinemaSourceItem.Header>().first().collapsed)
        assertFalse(entries.filterIsInstance<CinemaSourceItem.Header>().last().collapsed)
        assertTrue(entries.filterIsInstance<CinemaSourceItem.Row>().all { it.groupKey == second })
        assertNull(cinemaSourceSelectedGroupKey(groups.take(1), second))
    }

    @Test fun `selected transport survives asynchronous arrival reorder and changed display label`() {
        val selected = group("Late", 80, "https://late.invalid")
        val key = cinemaSourceGroupKey(selected, 1)
        val earlier = group("Earlier", 5_000, "https://earlier.invalid")
        assertNull(cinemaSourceSelectedGroupKey(listOf(earlier), key))

        val arrived = listOf(earlier, selected)
        assertEquals(key, cinemaSourceSelectedGroupKey(arrived, key))
        val reordered = listOf(selected.copy(addon = "Renamed"), earlier)
        assertEquals(key, cinemaSourceSelectedGroupKey(reordered, key))
        val rows = cinemaSourceWindow(reordered, emptySet(), 60, key).filterIsInstance<CinemaSourceItem.Row>()
        assertEquals(selected.streams.take(60), rows.filter { it.groupKey == key }.map { it.source })
    }

    @Test fun `unknown transport uses distinct ordinal identity and cannot borrow same-name base`() {
        val first = group("Alias", 1)
        val second = group("Alias", 1)
        assertNotEquals(cinemaSourceGroupKey(first, 0), cinemaSourceGroupKey(second, 1))
        assertNull(cinemaSourceSelectedGroupKey(listOf(group("Alias", 1, "https://real.invalid")), cinemaSourceGroupKey(first, 0)))
    }

    @Test fun `All clears extra target window while Show more reaches the genuine complete set`() {
        val groups = listOf(group("First", 100), group("Second", 100))
        val target = cinemaSourceGroupKey(groups[1], 1)
        assertEquals(120, cinemaSourceWindow(groups, emptySet(), 60, target).filterIsInstance<CinemaSourceItem.Row>().size)
        assertEquals(60, cinemaSourceWindow(groups, emptySet(), 60, null).filterIsInstance<CinemaSourceItem.Row>().size)
        assertNull(cinemaSourceSelectedGroupKey(groups, null))
        assertEquals(groups.flatMap { it.streams }, cinemaSourceWindow(groups, emptySet(), 240, null).filterIsInstance<CinemaSourceItem.Row>().map { it.source })
    }

    @Test fun `collapsed and empty sections remain present without spending normal row budget`() {
        val groups = listOf(group("Collapsed", 100), group("Empty", 0), group("Visible", 100))
        val entries = cinemaSourceWindow(groups, setOf(cinemaSourceGroupKey(groups[0], 0)), 60, cinemaSourceGroupKey(groups[1], 1))
        assertEquals(3, entries.filterIsInstance<CinemaSourceItem.Header>().size)
        assertEquals(groups[2].streams.take(60), entries.filterIsInstance<CinemaSourceItem.Row>().map { it.source })
    }

    @Test fun `existing per-group sort and row objects are preserved without cross-group ranking`() {
        val groups = listOf(group("Z", 3), group("A", 3))
        val entries = cinemaSourceWindow(groups, emptySet(), 60, null) { it.reversed() }
        assertEquals(listOf("Z", "A"), entries.filterIsInstance<CinemaSourceItem.Header>().map { it.addon })
        assertEquals(groups.flatMap { it.streams.reversed() }, entries.filterIsInstance<CinemaSourceItem.Row>().map { it.source })
    }

    @Test fun `negative budget and removed target cannot invent source rows`() {
        val groups = listOf(group("Real", 3))
        assertEquals(0, cinemaSourceWindow(groups, emptySet(), -1, "removed").filterIsInstance<CinemaSourceItem.Row>().size)
        assertNull(cinemaSourceSelectedGroupKey(groups, "removed"))
        assertEquals(emptyList<CinemaSourceItem>(), cinemaSourceWindow(emptyList(), emptySet(), 60, "removed"))
    }

    @Test fun `real embedded and stream projection shares one provider tab anchor and nearby budget`() {
        val groups = projectedEmbeddedAndStreamGroups()
        assertEquals(3, groups.size)
        assertEquals(groups[1].base, groups[2].base)
        val target = cinemaSourceGroupKey(groups[1], 1)
        val tabs = cinemaSourceTabs(groups)
        assertEquals(listOf(groups[0].base, target), tabs.map { it.key })
        assertEquals(listOf(120, 120), tabs.map { it.count })

        val entries = cinemaSourceWindow(groups, emptySet(), 60, target)
        val headers = entries.filterIsInstance<CinemaSourceItem.Header>()
        val rows = entries.filterIsInstance<CinemaSourceItem.Row>()
        assertEquals(groups.map { it.addon }, headers.map { it.addon })
        assertEquals(1, headers.count { it.key == target && it.firstProviderSection })
        assertEquals(120, rows.size)
        assertEquals(60, rows.count { it.groupKey == target })
        assertEquals(groups[1].streams + groups[2].streams.take(30), rows.filter { it.groupKey == target }.map { it.source })
        assertEquals(groups.flatMap { it.streams }, cinemaSourceWindow(groups, emptySet(), 240, target).filterIsInstance<CinemaSourceItem.Row>().map { it.source })
    }

    @Test fun `shared transport folds both original sections and survives a later embedded response`() {
        val groups = projectedEmbeddedAndStreamGroups()
        val target = cinemaSourceGroupKey(groups[2], 2)
        val initiallyStreamOnly = listOf(groups[0], groups[2])
        assertEquals(target, cinemaSourceSelectedGroupKey(initiallyStreamOnly, target))
        assertEquals(target, cinemaSourceSelectedGroupKey(groups, target))
        assertEquals(1, cinemaSourceTabs(groups).count { it.key == target })

        val folded = cinemaSourceWindow(groups, setOf(target), 60, target)
        assertEquals(2, folded.filterIsInstance<CinemaSourceItem.Header>().count { it.key == target && it.collapsed })
        assertFalse(folded.filterIsInstance<CinemaSourceItem.Row>().any { it.groupKey == target })
    }

    /** Actual public native projection -> shipping parser, with no transport, JNI, account or provider. */
    private fun projectedEmbeddedAndStreamGroups(): List<StreamGroup> {
        val video = "fixture:1:2"
        val registry = listOf(
            VortxResourceAddon("first", "https://first.invalid/manifest.json"),
            VortxResourceAddon("shared", "https://shared.invalid/manifest.json"),
        )
        val urls = registry.associate { it.id to it.transportUrl }
        fun streams(prefix: String, count: Int) = JSONArray().also { array ->
            repeat(count) { index -> array.put(JSONObject().put("name", "$prefix $index").put("url", "https://media.invalid/$prefix/$index.mp4")) }
        }
        fun embedded(addon: String, prefix: String, count: Int) = VortxResourceGroup(
            addon, "ready", JSONObject().put("meta", JSONObject().put("id", "fixture").put("type", "series")
                .put("videos", JSONArray().put(JSONObject().put("id", video).put("streams", streams(prefix, count))))).toString(), null,
        )
        val metaRequest = VortxResourceRequest(VortxResourceRequest.Resource.META, "series", "fixture")
        val streamRequest = VortxResourceRequest(VortxResourceRequest.Resource.STREAM, "series", video)
        val meta = VortxResourceSnapshot("owner", "meta", 1, metaRequest,
            listOf(embedded("first", "first-embedded", 120), embedded("shared", "shared-embedded", 30)), urls)
        val streamed = VortxResourceSnapshot("owner", "streams", 2, streamRequest,
            listOf(VortxResourceGroup("shared", "ready", JSONObject().put("streams", streams("shared-streamed", 90)).toString(), null)), urls)
        return EngineState.parseStreamGroups(VortxResourceProjection.metaDetails(meta, streamed, streamRequest, registry), video)
    }

    private fun group(name: String, count: Int, base: String = "") = StreamGroup(
        addon = name,
        streams = (0 until count).map { StreamSource("$name-$it", name, "Source $it") },
        base = base,
    )
}
