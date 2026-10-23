package com.vortx.android.iptv

import com.vortx.android.model.Catalog
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The TV guide, the same cases as Apple `LiveGuideTests`. */
class LiveGuideTest {
    private val base = 1_800_000_000_000L   // 2027-01-15T08:00:00Z
    private fun iso(minutes: Long) = java.time.Instant.ofEpochMilli(base + minutes * 60_000).toString()
    private fun video(id: String, title: String, released: String) = JSONObject().put("id", id).put("title", title).put("released", released)

    private val programmes = LiveGuidePolicy.programmes(JSONArray(listOf(
        video("ev2", "Evening News", iso(90)),
        video("ev0", "Morning Show", iso(0)),
        video("ev1", "  ", iso(60)),
        video("bad", "No time", "not a date"),
        video("plain", "Late Film", "2027-01-15T11:00:00Z"),
    )))

    @Test fun `schedules come from videos in start order`() {
        assertEquals(listOf("ev0", "ev1", "ev2", "plain"), programmes.map { it.id })
        assertEquals(base + 3_600_000, programmes[0].endMs)
        assertEquals(base + 5_400_000, programmes[1].endMs)
        assertEquals(programmes[3].startMs + 3_600_000, programmes[3].endMs)
        assertEquals("Programme", programmes[1].title)
        assertEquals(base + 3 * 3_600_000, programmes[3].startMs)
        assertTrue(programmes[0].isOn(base))
        assertFalse(programmes[0].isOn(base + 3_600_000))
        assertTrue(LiveGuidePolicy.programmes(null).isEmpty())
    }

    @Test fun `windows start at the half hour and page by half hours`() {
        val window = LiveGuidePolicy.window(base + 17 * 60_000, 3)
        assertEquals(LiveGuideWindow(base, base + 3 * 3_600_000), window)
        assertEquals(base + 5_400_000, LiveGuidePolicy.shifted(window, 3).startMs)
        assertEquals(6, LiveGuidePolicy.marks(window).size)
    }

    @Test fun `window duration widens hours before multiplication`() {
        assertEquals(7_730_941_129_200_000L, LiveGuidePolicy.window(0L, Int.MAX_VALUE).endMs)
        assertEquals(-7_730_941_132_800_000L, LiveGuidePolicy.window(0L, Int.MIN_VALUE).endMs)
    }

    @Test fun `cells are clipped to the window and slivers dropped`() {
        val cells = LiveGuidePolicy.cells(programmes, LiveGuideWindow(base + 5_400_000, base + 12_600_000), 10f)
        assertEquals(listOf("ev2", "plain"), cells.map { it.programme.id })
        assertEquals(0f, cells[0].x)
        assertEquals(900f, cells[0].width)
        assertEquals(900f, cells[1].x)
        assertEquals(300f, cells[1].width)
        val sliver = LiveGuidePolicy.cells(programmes, LiveGuideWindow(base + 3_599_000, base + 7_200_000), 1f)
        assertTrue(sliver.none { it.programme.id == "ev0" })
    }

    @Test fun `segments use spacers for gaps and trim overlaps`() {
        val laid = LiveGuidePolicy.segments(listOf(
            LiveGuideCell(programmes[2], 100f, 200f), LiveGuideCell(programmes[0], 0f, 50f), LiveGuideCell(programmes[1], 250f, 100f),
        ))
        assertEquals(listOf(
            LiveGuideSegment.Cell(LiveGuideCell(programmes[0], 0f, 50f)), LiveGuideSegment.Gap(50f),
            LiveGuideSegment.Cell(LiveGuideCell(programmes[2], 100f, 200f)),
            LiveGuideSegment.Cell(LiveGuideCell(programmes[1], 300f, 50f)),
        ), laid)
    }

    @Test fun `meta URLs sit beside the manifest and channels are unique`() {
        val channel = LiveGuideChannel("vortx-iptv:ab/c d", "tv", "One", null, "https://iptv.vortx.tv/c/slug/manifest.json")
        assertEquals("https://iptv.vortx.tv/c/slug/meta/tv/vortx-iptv:ab%2Fc%20d.json", LiveGuidePolicy.metaUrl(channel))
        assertNull(LiveGuidePolicy.metaUrl(channel.copy(addonBase = "https://a.example/")))
        val channels = LiveGuidePolicy.channels(listOf(
            Catalog("https://a/manifest.json|tv|x", "A", listOf(MetaItem("1", MediaType.TV, "One"), MetaItem("2", MediaType.TV, "Two"))),
            Catalog("https://b/manifest.json|tv|y", "B", listOf(MetaItem("1", MediaType.TV, "One again"), MetaItem("1", MediaType.CHANNEL, "Other type"))),
        ))
        assertEquals(listOf("One", "Two", "Other type"), channels.map { it.name })
        assertEquals("https://a/manifest.json", channels[0].addonBase)
    }

    @OptIn(ExperimentalCoroutinesApi::class)
    @Test fun `the loader fetches each schedule once and marks failures unavailable`() = runTest {
        val fetched = mutableListOf<String>()
        val loader = LiveGuideLoader(this) { url ->
            fetched += url
            if (url.contains("/2.json")) null
            else JSONObject().put("meta", JSONObject().put("videos", JSONArray(listOf(video("p", "Show", iso(0)))))).toString()
        }
        val one = LiveGuideChannel("1", "tv", "One", null, "https://a/manifest.json")
        val two = LiveGuideChannel("2", "tv", "Two", null, "https://a/manifest.json")
        loader.request(one)
        loader.request(one)
        loader.request(two)
        advanceUntilIdle()
        assertEquals(2, fetched.size)
        assertEquals(listOf("Show"), (loader.schedules.value["1"] as LiveGuideLoader.Schedule.Loaded).programmes.map { it.title })
        assertEquals(LiveGuideLoader.Schedule.Unavailable, loader.schedules.value["2"])
        loader.request(one)
        advanceUntilIdle()
        assertEquals("a fresh schedule is not fetched again", 2, fetched.size)
    }
}
