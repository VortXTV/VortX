package com.vortx.android.iptv

import com.vortx.android.model.Catalog
import java.net.URLEncoder
import java.time.Instant
import java.time.OffsetDateTime
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import org.json.JSONArray
import org.json.JSONObject

/**
 * The TV guide (Apple `LiveGuide.swift`): channels down the side, a few hours of programmes across, built from
 * the schedule each live channel's add-on publishes in its meta (`videos`, one per programme, `released` = start;
 * the VortX IPTV converter fills it from the playlist's XMLTV). Schedules load lazily for the rows on screen.
 */
data class LiveGuideChannel(val id: String, val type: String, val name: String, val logo: String?, val addonBase: String)

data class LiveGuideProgramme(val id: String, val title: String, val startMs: Long, val endMs: Long, val overview: String?) {
    fun isOn(nowMs: Long): Boolean = nowMs in startMs until endMs
}

data class LiveGuideWindow(val startMs: Long, val endMs: Long) {
    operator fun contains(timeMs: Long): Boolean = timeMs in startMs until endMs
}

/** One programme on the time axis: offset and width (dp) from the window's start. */
data class LiveGuideCell(val programme: LiveGuideProgramme, val x: Float, val width: Float)

sealed interface LiveGuideSegment {
    data class Gap(val width: Float) : LiveGuideSegment
    data class Cell(val cell: LiveGuideCell) : LiveGuideSegment
}

object LiveGuidePolicy {
    const val DEFAULT_LENGTH_MS = 3_600_000L
    const val MIN_CELL_WIDTH = 24f
    private const val HALF_HOUR_MS = 1_800_000L

    /** Programmes from a channel's `videos`, in start order; each ends where the next begins, the last runs an hour. */
    fun programmes(videos: JSONArray?): List<LiveGuideProgramme> {
        if (videos == null) return emptyList()
        val dated = (0 until videos.length()).mapNotNull { index ->
            val video = videos.optJSONObject(index) ?: return@mapNotNull null
            val start = parseTime(video.optString("released")) ?: return@mapNotNull null
            video to start
        }.sortedBy { it.second }
        return dated.mapIndexed { index, (video, start) ->
            val next = dated.drop(index + 1).firstOrNull { it.second > start }?.second
            val title = (video.optString("title").ifBlank { video.optString("name") }).trim()
            LiveGuideProgramme(
                id = video.optString("id").ifEmpty { "p$index" },
                title = title.ifEmpty { "Programme" },
                startMs = start,
                endMs = next ?: (start + DEFAULT_LENGTH_MS),
                overview = video.optString("overview").takeIf { it.isNotBlank() },
            )
        }
    }

    /** The window the guide opens on: from the current half hour, [hours] long. */
    fun window(nowMs: Long, hours: Int): LiveGuideWindow {
        val start = nowMs / HALF_HOUR_MS * HALF_HOUR_MS
        return LiveGuideWindow(start, start + hours.toLong() * 2 * HALF_HOUR_MS)
    }

    fun shifted(window: LiveGuideWindow, halfHours: Int): LiveGuideWindow =
        LiveGuideWindow(window.startMs + halfHours * HALF_HOUR_MS, window.endMs + halfHours * HALF_HOUR_MS)

    /** The programmes overlapping [window], clipped to it and laid out at [dpPerMinute]. */
    fun cells(programmes: List<LiveGuideProgramme>, window: LiveGuideWindow, dpPerMinute: Float): List<LiveGuideCell> =
        programmes.mapNotNull { programme ->
            val start = maxOf(programme.startMs, window.startMs)
            val end = minOf(programme.endMs, window.endMs)
            if (end <= start) return@mapNotNull null
            val x = (start - window.startMs) / 60_000f * dpPerMinute
            val width = (end - start) / 60_000f * dpPerMinute
            if (width < MIN_CELL_WIDTH) null else LiveGuideCell(programme, x, width)
        }

    /** A row left to right: empty time as spacers, programmes as cells, so focus sees real layout positions. */
    fun segments(cells: List<LiveGuideCell>): List<LiveGuideSegment> {
        val result = mutableListOf<LiveGuideSegment>()
        var cursor = 0f
        for (cell in cells.sortedBy { it.x }) {
            if (cell.x + cell.width <= cursor) continue
            val start = maxOf(cell.x, cursor)
            if (start - cursor > 0.5f) result += LiveGuideSegment.Gap(start - cursor)
            result += LiveGuideSegment.Cell(cell.copy(x = start, width = cell.x + cell.width - start))
            cursor = cell.x + cell.width
        }
        return result
    }

    /** Half-hour marks inside [window], for the time ruler. */
    fun marks(window: LiveGuideWindow): List<Long> =
        generateSequence(window.startMs) { it + HALF_HOUR_MS }.takeWhile { it < window.endMs }.toList()

    /** `<add-on>/meta/<type>/<id>.json` beside the manifest, or null when the add-on address is not a manifest URL. */
    fun metaUrl(channel: LiveGuideChannel): String? {
        if (!channel.addonBase.endsWith("/manifest.json")) return null
        val base = channel.addonBase.removeSuffix("manifest.json")
        return "${base}meta/${pathSegment(channel.type)}/${pathSegment(channel.id)}.json"
    }

    /** Unique channels from the live catalog rows (id `<add-on manifest URL>|<type>|<catalog>`), in row order. */
    fun channels(catalogs: List<Catalog>): List<LiveGuideChannel> {
        val seen = HashSet<String>()
        return catalogs.flatMap { catalog ->
            val base = catalog.id.substringBefore('|')
            catalog.items.mapNotNull { item ->
                if (!seen.add("${item.type.id}|${item.id}")) return@mapNotNull null
                LiveGuideChannel(item.id, item.type.id, item.name, item.logo ?: item.poster, base)
            }
        }
    }

    /** Percent-encodes one path segment like Apple's `.urlPathAllowed` minus "/": keeps ":" and "@". */
    private fun pathSegment(raw: String): String =
        URLEncoder.encode(raw, "UTF-8").replace("+", "%20").replace("%3A", ":").replace("%40", "@")
            .replace("%28", "(").replace("%29", ")").replace("%21", "!").replace("%27", "'").replace("%2A", "*")

    private fun parseTime(raw: String?): Long? {
        if (raw.isNullOrBlank()) return null
        return runCatching { Instant.parse(raw).toEpochMilli() }.getOrNull()
            ?: runCatching { OffsetDateTime.parse(raw).toInstant().toEpochMilli() }.getOrNull()
    }
}

/** Loads channel schedules on demand, a few at a time, and keeps them for a while (Apple `LiveGuideModel`). */
class LiveGuideLoader(
    private val scope: CoroutineScope,
    private val fetch: suspend (String) -> String? = { url ->
        IPTVHttp.request("GET", url, timeoutMs = 15_000).takeIf { it.isSuccess }?.body
    },
) {
    sealed interface Schedule {
        data object Loading : Schedule
        data class Loaded(val programmes: List<LiveGuideProgramme>) : Schedule
        data object Unavailable : Schedule
    }

    private val _schedules = MutableStateFlow<Map<String, Schedule>>(emptyMap())
    val schedules: StateFlow<Map<String, Schedule>> = _schedules.asStateFlow()
    private val fetchedAt = HashMap<String, Long>()
    private val permits = Semaphore(MAX_CONCURRENT)

    fun request(channel: LiveGuideChannel, nowMs: Long = System.currentTimeMillis()) {
        val current = _schedules.value[channel.id]
        if (current == Schedule.Loading) return
        val at = synchronized(fetchedAt) { fetchedAt[channel.id] }
        if (current != null && at != null && nowMs - at < FRESH_FOR_MS) return
        _schedules.update { it + (channel.id to Schedule.Loading) }
        scope.launch {
            val schedule = permits.withPermit { load(channel) }
            synchronized(fetchedAt) { fetchedAt[channel.id] = System.currentTimeMillis() }
            _schedules.update { it + (channel.id to schedule) }
        }
    }

    private suspend fun load(channel: LiveGuideChannel): Schedule {
        val url = LiveGuidePolicy.metaUrl(channel) ?: return Schedule.Unavailable
        val body = try {
            fetch(url)
        } catch (cancel: kotlinx.coroutines.CancellationException) {
            throw cancel
        } catch (_: Exception) {
            null
        } ?: return Schedule.Unavailable
        val videos = runCatching { JSONObject(body).optJSONObject("meta")?.optJSONArray("videos") }.getOrNull()
        val programmes = LiveGuidePolicy.programmes(videos)
        return if (programmes.isEmpty()) Schedule.Unavailable else Schedule.Loaded(programmes)
    }

    private companion object {
        const val MAX_CONCURRENT = 4
        const val FRESH_FOR_MS = 15 * 60_000L
    }
}
