package com.vortx.android.player

import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.Timeline
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.analytics.AnalyticsListener
import androidx.media3.exoplayer.source.MediaSource.MediaPeriodId

/** Application-looper-owned, bounded input facts. A URL, READY state or display cannot admit facts. */
@UnstableApi
internal class ExoMetadataInputs {
    class Load internal constructor()
    data class Context(val load: Load, val period: MediaPeriodId)
    private data class Input(val context: Context, val format: Format)
    private var load: Load? = null
    private var current: Context? = null
    private var video: Input? = null
    private var audio: Input? = null
    var isReleased: Boolean = false
        private set

    fun begin(): Load {
        val next = Load()
        fail()
        if (!isReleased) load = next
        return next
    }
    fun fail() { load = null; current = null; video = null; audio = null }
    fun release() { isReleased = true; fail() }
    private fun accepts(context: Context?): Boolean =
        !isReleased && load != null && context != null && context.load === load &&
            !context.period.isAd && context.period.windowSequenceNumber >= 0L

    fun observeCurrent(context: Context?) {
        if (context == null) current = null
        else if (accepts(context)) current = context
    }
    fun video(context: Context?, format: Format) {
        if (accepts(context)) video = Input(requireNotNull(context), format)
    }
    fun audio(context: Context?, format: Format) {
        if (accepts(context)) audio = Input(requireNotNull(context), format)
    }
    fun disableVideo(context: Context?) {
        // Input events describe the reading period; disable describes the playing period.
        // A same-load disable retires even a prebuffered successor's decoder input.
        if (context == null || accepts(context)) video = null
    }
    fun disableAudio(context: Context?) {
        if (context == null || accepts(context)) audio = null
    }
    /** Event, playing period and actual tagged item must all identify this exact physical load. */
    fun acceptsPresentation(event: Context?, playing: Context?, actualTag: Any?, actualPeriodUID: Any?): Boolean =
        accepts(event) && event == playing && event == current && actualTag === load &&
            actualPeriodUID != null && event?.period?.periodUid == actualPeriodUID
    fun snapshot(actualTag: Any?, actualPeriodUID: Any?): Pair<Format?, Format?> {
        val active = current
        if (!accepts(active) || actualTag !== load || actualPeriodUID == null ||
            active?.period?.periodUid != actualPeriodUID) return null to null
        return video?.takeIf { it.context == active }?.format to
            audio?.takeIf { it.context == active }?.format
    }
}

@UnstableApi
internal fun exoMetadataEventContext(time: AnalyticsListener.EventTime): ExoMetadataInputs.Context? =
    exoMetadataContext(time.timeline, time.windowIndex, time.mediaPeriodId)

@UnstableApi
internal fun exoMetadataCurrentContext(time: AnalyticsListener.EventTime): ExoMetadataInputs.Context? =
    exoMetadataContext(time.currentTimeline, time.currentWindowIndex, time.currentMediaPeriodId)

@UnstableApi
internal fun exoMetadataContext(timeline: Timeline, windowIndex: Int,
    id: MediaPeriodId?): ExoMetadataInputs.Context? {
    if (id == null || id.isAd || id.windowSequenceNumber < 0L ||
        windowIndex !in 0 until timeline.windowCount) return null
    val index = timeline.getIndexOfPeriod(id.periodUid)
    if (index == C.INDEX_UNSET) return null
    if (timeline.getPeriod(index, Timeline.Period()).windowIndex != windowIndex) return null
    val tag = timeline.getWindow(windowIndex, Timeline.Window()).mediaItem.localConfiguration?.tag
        as? ExoMetadataInputs.Load ?: return null
    return ExoMetadataInputs.Context(tag, id)
}
