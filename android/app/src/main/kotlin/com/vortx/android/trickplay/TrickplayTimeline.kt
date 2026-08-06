package com.vortx.android.trickplay

import java.util.Locale
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.roundToLong

/** One genuine, half-open time window mapped to a sprite-sheet tile. */
data class TrickplayTimelineCue(
    val start: Double,
    val end: Double,
    val x: Int,
    val y: Int,
    val width: Int,
    val height: Int,
    val tileIndex: Int,
) {
    fun contains(time: Double): Boolean = time.isFinite() && time >= start && time < end
}

/**
 * Pure timeline rules shared by community-sheet upload and playback.
 *
 * New sheets use actual capture timestamps and explicit VTT coverage. Legacy sheets which did not
 * advertise a VTT remain readable through [cue]'s interval path. An advertised but invalid VTT is
 * represented by an empty cue list, which deliberately has no invented coverage.
 */
object TrickplayTimeline {

    /** Derive an ordinary retained cadence without allowing a sparse seek gap to become the cadence. */
    fun nominalCadence(captureTimes: List<Double>, fallbackInterval: Double): Double {
        if (!fallbackInterval.isFinite() || fallbackInterval <= 0.0) return 0.0
        val sorted = captureTimes.asSequence()
            .filter { it.isFinite() && it >= 0.0 }
            .distinct()
            .sorted()
            .toList()
        val deltas = sorted.zipWithNext { first, second -> second - first }
            .filter { it.isFinite() && it > 0.0 }
            .sorted()
        if (deltas.size < 8) return fallbackInterval
        val lowerMedian = deltas[(deltas.size - 1) / 2]
        return max(fallbackInterval, lowerMedian)
    }

    /**
     * Preserve a real gap found between selected sheet samples. A fence belongs to the selected tile at
     * the same position and ends it one retained cadence after the last pre-gap capture.
     */
    fun selectedCueEndFences(
        retainedCaptureTimes: List<Double>,
        selectedIndices: List<Int>,
        retainedCadence: Double,
    ): List<Double?>? {
        if (!retainedCadence.isFinite() || retainedCadence <= 0.0) return null
        if (!isStrictTimeline(retainedCaptureTimes)) return null
        if (selectedIndices.any { it !in retainedCaptureTimes.indices }) return null
        if (selectedIndices.zipWithNext().any { (first, second) -> second <= first }) return null

        val fences = MutableList<Double?>(selectedIndices.size) { null }
        if (selectedIndices.size <= 1) return fences
        val discontinuityThreshold = retainedCadence * 2.0
        for (selectedPosition in 0 until selectedIndices.lastIndex) {
            val startIndex = selectedIndices[selectedPosition]
            val endIndex = selectedIndices[selectedPosition + 1]
            for (retainedIndex in startIndex until endIndex) {
                val delta = retainedCaptureTimes[retainedIndex + 1] - retainedCaptureTimes[retainedIndex]
                if (delta > discontinuityThreshold) {
                    fences[selectedPosition] = retainedCaptureTimes[retainedIndex] + retainedCadence
                    break
                }
            }
        }
        return fences
    }

    fun makeCues(
        captureTimes: List<Double>,
        nominalInterval: Double,
        gapFenceInterval: Double = nominalInterval,
        cueEndFences: List<Double?>? = null,
        cols: Int,
        tileW: Int,
        tileH: Int,
    ): List<TrickplayTimelineCue>? {
        if (captureTimes.isEmpty() || !nominalInterval.isFinite() || nominalInterval <= 0.0 ||
            !gapFenceInterval.isFinite() || gapFenceInterval <= 0.0 ||
            cols <= 0 || tileW <= 0 || tileH <= 0 || !isStrictTimeline(captureTimes)
        ) {
            return null
        }
        if (cueEndFences != null) {
            if (cueEndFences.size != captureTimes.size) return null
            cueEndFences.forEachIndexed { index, fence ->
                if (fence != null && (index >= captureTimes.lastIndex || !fence.isFinite() ||
                        fence <= captureTimes[index] || fence > captureTimes[index + 1])
                ) {
                    return null
                }
            }
        }

        return captureTimes.indices.map { index ->
            val start = captureTimes[index]
            val end = if (index < captureTimes.lastIndex) {
                val next = captureTimes[index + 1]
                if (cueEndFences != null) {
                    min(cueEndFences[index] ?: next, next)
                } else {
                    val discontinuityThreshold = nominalInterval + gapFenceInterval
                    if (next - start > discontinuityThreshold) min(start + gapFenceInterval, next) else next
                }
            } else {
                start + if (cueEndFences == null) nominalInterval else gapFenceInterval
            }
            TrickplayTimelineCue(
                start = start,
                end = end,
                x = (index % cols) * tileW,
                y = (index / cols) * tileH,
                width = tileW,
                height = tileH,
                tileIndex = index,
            )
        }
    }

    fun makeVtt(
        captureTimes: List<Double>,
        nominalInterval: Double,
        gapFenceInterval: Double = nominalInterval,
        cueEndFences: List<Double?>? = null,
        cols: Int,
        tileW: Int,
        tileH: Int,
    ): String? {
        val cues = makeCues(
            captureTimes = captureTimes,
            nominalInterval = nominalInterval,
            gapFenceInterval = gapFenceInterval,
            cueEndFences = cueEndFences,
            cols = cols,
            tileW = tileW,
            tileH = tileH,
        ) ?: return null
        return buildString {
            append("WEBVTT\n\n")
            cues.forEach { cue ->
                append(vttTime(cue.start))
                append(" --> ")
                append(vttTime(cue.end))
                append('\n')
                append("sprite#xywh=${cue.x},${cue.y},${cue.width},${cue.height}\n\n")
            }
        }.trimEnd()
    }

    /** Parse the worker's VTT subset, rejecting the entire index on any timing or geometry mismatch. */
    fun parseVtt(
        raw: String,
        frameCount: Int,
        cols: Int,
        tileW: Int,
        tileH: Int,
    ): List<TrickplayTimelineCue>? {
        if (frameCount <= 0 || cols <= 0 || tileW <= 0 || tileH <= 0) return null
        val lines = raw.replace("\r\n", "\n").replace('\r', '\n').split('\n')
        val header = lines.firstOrNull()?.removePrefix("\uFEFF")?.trimEnd() ?: return null
        if (!WEBVTT_HEADER.matches(header)) return null

        val parsed = mutableListOf<TrickplayTimelineCue>()
        var lineIndex = 1
        while (lineIndex < lines.size) {
            val timing = lines[lineIndex].trim()
            lineIndex += 1
            if (!timing.contains("-->")) continue
            val timingMatch = VTT_TIMING_LINE.matchEntire(timing) ?: return null
            val start = parseVttTime(timingMatch.groupValues[1]) ?: return null
            val end = parseVttTime(timingMatch.groupValues[2]) ?: return null
            if (start < 0.0 || end <= start) return null

            var coordinates: Coordinates? = null
            while (lineIndex < lines.size) {
                val payload = lines[lineIndex].trim()
                if (payload.isEmpty()) {
                    lineIndex += 1
                    break
                }
                if (payload.contains("-->")) break
                // This protocol subset has exactly one payload line and that line must be valid geometry.
                // Rejecting extras prevents a conflicting second xywh row from being silently ignored.
                if (coordinates != null) return null
                coordinates = parseCoordinates(payload) ?: return null
                lineIndex += 1
            }
            val rect = coordinates ?: return null
            if (rect.x < 0 || rect.y < 0 || rect.width != tileW || rect.height != tileH ||
                rect.x % tileW != 0 || rect.y % tileH != 0
            ) {
                return null
            }
            val col = rect.x / tileW
            val row = rect.y / tileH
            if (col >= cols) return null
            val tileIndexLong = row.toLong() * cols.toLong() + col.toLong()
            if (tileIndexLong !in 0 until frameCount.toLong()) return null
            val tileIndex = tileIndexLong.toInt()
            parsed.lastOrNull()?.let { prior ->
                if (start < prior.end || tileIndex <= prior.tileIndex) return null
            }
            parsed += TrickplayTimelineCue(
                start = start,
                end = end,
                x = rect.x,
                y = rect.y,
                width = rect.width,
                height = rect.height,
                tileIndex = tileIndex,
            )
        }
        return parsed.takeIf { it.size == frameCount }
    }

    /**
     * Preserve the fetch contract's three distinct states: null means legacy metadata never advertised
     * a VTT, a nonempty list is a valid advertised index, and an empty list is an advertised index that
     * was unavailable or invalid. Only the first state may use legacy uniform timing.
     */
    fun fetchedCues(
        advertised: Boolean,
        rawVtt: String?,
        frameCount: Int,
        cols: Int,
        tileW: Int,
        tileH: Int,
    ): List<TrickplayTimelineCue>? {
        if (!advertised) return null
        val raw = rawVtt ?: return emptyList()
        return parseVtt(raw, frameCount, cols, tileW, tileH) ?: emptyList()
    }

    /** Find true VTT coverage, or finite interval coverage for metadata which never advertised a VTT. */
    fun cue(
        time: Double,
        parsedCues: List<TrickplayTimelineCue>?,
        frameCount: Int,
        legacyInterval: Double,
        cols: Int,
        tileW: Int,
        tileH: Int,
    ): TrickplayTimelineCue? {
        if (!time.isFinite() || time < 0.0) return null
        if (parsedCues != null) {
            var lower = 0
            var upper = parsedCues.size
            while (lower < upper) {
                val middle = lower + (upper - lower) / 2
                if (parsedCues[middle].start <= time) lower = middle + 1 else upper = middle
            }
            if (lower == 0) return null
            return parsedCues[lower - 1].takeIf { it.contains(time) }
        }

        if (frameCount <= 0 || cols <= 0 || tileW <= 0 || tileH <= 0 ||
            !legacyInterval.isFinite() || legacyInterval <= 0.0
        ) {
            return null
        }
        val coverageEnd = frameCount.toDouble() * legacyInterval
        if (!coverageEnd.isFinite() || time >= coverageEnd) return null
        val tileIndex = (time / legacyInterval).toInt()
        return TrickplayTimelineCue(
            start = tileIndex * legacyInterval,
            end = (tileIndex + 1) * legacyInterval,
            x = (tileIndex % cols) * tileW,
            y = (tileIndex / cols) * tileH,
            width = tileW,
            height = tileH,
            tileIndex = tileIndex,
        )
    }

    /** Keep both timeline endpoints and evict the most temporally redundant interior samples. */
    fun retainedIndices(captureTimes: List<Double>, limit: Int): List<Int> {
        if (limit <= 0) return emptyList()
        var retained = captureTimes.mapIndexedNotNull { index, time ->
            if (time.isFinite() && time >= 0.0) IndexedTime(index, time) else null
        }.sortedWith(compareBy<IndexedTime> { it.time }.thenBy { it.index }).toMutableList()

        val deduplicated = mutableListOf<IndexedTime>()
        retained.forEach { candidate ->
            if (deduplicated.lastOrNull()?.time == candidate.time) {
                deduplicated[deduplicated.lastIndex] = candidate
            } else {
                deduplicated += candidate
            }
        }
        retained = deduplicated
        if (limit == 1) return retained.lastOrNull()?.let { listOf(it.index) }.orEmpty()
        while (retained.size > limit) {
            var removal = 1
            var narrowestSpan = retained[2].time - retained[0].time
            for (index in 2 until retained.lastIndex) {
                val span = retained[index + 1].time - retained[index - 1].time
                if (span < narrowestSpan) {
                    narrowestSpan = span
                    removal = index
                }
            }
            retained.removeAt(removal)
        }
        return retained.map { it.index }
    }

    /** Row-major selection that preserves both endpoints and the requested sample count. */
    fun evenlySpacedIndices(count: Int, targetCount: Int): List<Int> {
        if (count <= 0 || targetCount <= 0) return emptyList()
        if (targetCount >= count) return (0 until count).toList()
        if (targetCount == 1) return listOf(count - 1)
        return (0 until targetCount).map { index ->
            (index.toDouble() * (count - 1).toDouble() / (targetCount - 1).toDouble()).roundToInt()
        }
    }

    private fun isStrictTimeline(captureTimes: List<Double>): Boolean = captureTimes.indices.all { index ->
        val time = captureTimes[index]
        time.isFinite() && time >= 0.0 && (index == 0 || time > captureTimes[index - 1])
    }

    private fun parseCoordinates(payload: String): Coordinates? {
        val marker = payload.indexOf("#xywh=")
        if (marker < 0 || marker != payload.lastIndexOf("#xywh=")) return null
        val rawValues = payload.substring(marker + 6)
        if (!VTT_COORDINATES.matches(rawValues)) return null
        val numbers = rawValues.split(',').map { it.toIntOrNull() ?: return null }
        return Coordinates(numbers[0], numbers[1], numbers[2], numbers[3])
    }

    private fun parseVttTime(raw: String): Double? {
        val match = VTT_TIMESTAMP.matchEntire(raw) ?: return null
        val hours = match.groupValues[1].ifEmpty { "0" }.toLongOrNull() ?: return null
        val minutes = match.groupValues[2].toLongOrNull() ?: return null
        val seconds = match.groupValues[3].toLongOrNull() ?: return null
        val milliseconds = match.groupValues[4].toLongOrNull() ?: return null
        val total = hours.toDouble() * 3_600.0 + minutes.toDouble() * 60.0 +
            seconds.toDouble() + milliseconds.toDouble() / 1_000.0
        return total.takeIf { it.isFinite() }
    }

    private fun vttTime(seconds: Double): String {
        val totalMilliseconds = (seconds * 1000.0).roundToLong()
        val milliseconds = totalMilliseconds % 1000L
        val totalSeconds = totalMilliseconds / 1000L
        val hours = totalSeconds / 3600L
        val minutes = (totalSeconds % 3600L) / 60L
        val remainder = totalSeconds % 60L
        return String.format(Locale.US, "%02d:%02d:%02d.%03d", hours, minutes, remainder, milliseconds)
    }

    private data class Coordinates(val x: Int, val y: Int, val width: Int, val height: Int)
    private data class IndexedTime(val index: Int, val time: Double)

    private val WEBVTT_HEADER = Regex("^WEBVTT(?:[ \\t].*)?$")
    private val VTT_TIMING_LINE = Regex("^([^\\s]+)\\s+-->\\s+([^\\s]+)(?:\\s+.*)?$")
    private val VTT_TIMESTAMP = Regex("^(?:(\\d{2,}):)?([0-5]\\d):([0-5]\\d)\\.(\\d{3})$")
    private val VTT_COORDINATES = Regex("^\\d+,\\d+,\\d+,\\d+$")
}
