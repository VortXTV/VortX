package com.vortx.android.player.subtitles

import androidx.media3.common.text.Cue
import androidx.media3.common.util.Consumer
import androidx.media3.common.util.UnstableApi
import androidx.media3.extractor.text.CuesWithTiming
import androidx.media3.extractor.text.SubtitleParser
import androidx.media3.extractor.text.subrip.SubripParser
import java.util.Collections

/**
 * Ordinary, uncorrected sidecar rendering through the real Media3 1.11.1 parser. This creates no
 * alignment job/correction and no media source/track; the existing SubtitleView can show these cues
 * before an independently prepared correction is available, without reloading the playing video.
 */
@UnstableApi
internal object Media3OwnedSubtitlePresentation {
    /**
     * Worker-only. Input is the complete, bounded download after transport EOF. Null keeps the
     * existing ordinary Media3 sidecar path available; partial parser output is never adopted.
     */
    fun prepareSrt(bytes: ByteArray): SubtitleCuePresentation? {
        if (bytes.size !in 1..Media3OwnedSubtitleSrtEnvelope.maximumBytes) return null
        val owned = bytes.copyOf()
        val framing = Media3OwnedSubtitleSrtEnvelope.inspect(owned) ?: return null
        val cues = ArrayList<Cue>(framing.size)
        return try {
            SubripParser().parse(owned, 0, owned.size, SubtitleParser.OutputOptions.allCues(),
                Consumer<CuesWithTiming> { group ->
                    val expected = framing.getOrNull(cues.size) ?: throw Refused()
                    if (group.cues.size != 1 || group.startTimeUs != expected.startMs * 1000L ||
                        group.endTimeUs != expected.endMs * 1000L ||
                        group.durationUs != (expected.endMs - expected.startMs) * 1000L) throw Refused()
                    val cue = group.cues[0]
                    val text = cue.text ?: throw Refused()
                    if (cue.bitmap != null || text.length > SubtitleReferencePresentationCore.maximumTextBytes ||
                        !SubtitleReferencePresentationCore.validText(text.toString())) throw Refused()
                    // Keep Media3's styled and positioned Cue itself; do not flatten or reparse it.
                    cues.add(cue)
                })
            if (cues.size != framing.size) null else {
                val source = framing.map { SubtitleReferencePresentationCore.SourceCue(it.startMs, it.endMs, "") }
                Raw(Collections.unmodifiableList(cues), SubtitleReferencePresentationCore.IntervalIndex(source))
            }
        } catch (_: RuntimeException) { null }
        catch (_: LinkageError) { null }
    }

    private class Refused : RuntimeException()

    private class Raw(
        private val cues: List<Cue>,
        private val index: SubtitleReferencePresentationCore.IntervalIndex,
    ) : SubtitleCuePresentation {
        override fun lookup(mediaMs: Long): List<Cue> {
            val active = index.lookup(mediaMs)
            return if (active.isEmpty()) emptyList() else Collections.unmodifiableList(active.map { cues[it] })
        }

        override fun boundaryIdentity(mediaMs: Long): Int = index.boundaryAt(mediaMs)
    }
}
