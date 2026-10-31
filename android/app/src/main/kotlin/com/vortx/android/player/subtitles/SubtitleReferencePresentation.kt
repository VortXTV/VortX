package com.vortx.android.player.subtitles

import android.graphics.Typeface
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.SpannedString
import android.text.style.ForegroundColorSpan
import android.text.style.StyleSpan
import android.text.style.UnderlineSpan
import androidx.media3.common.text.Cue
import androidx.media3.common.util.UnstableApi
import java.util.Collections

/** Prepared text ownership shared by ordinary Media3 SRT and successfully corrected output. */
@UnstableApi
internal interface SubtitleCuePresentation {
    fun lookup(mediaMs: Long): List<Cue>
    fun boundaryIdentity(mediaMs: Long): Int
}

/**
 * Worker-prepared app-owned text for the existing Media3 SubtitleView. Preparation creates no
 * engine track and conveys no player authority; adoption is a prepared-reference swap.
 */
@UnstableApi
internal object SubtitleReferencePresentation {
    class Prepared internal constructor(
        val originalJob: String,
        srt: ByteArray,
        source: List<SubtitleReferenceQuery.RetimedCue>,
        val correction: SubtitleReferenceQuery.Correction,
        private val rendered: List<Cue>,
        private val index: SubtitleReferencePresentationCore.IntervalIndex,
    ) : SubtitleCuePresentation {
        private val ownedSrt = srt
        /** Exact corrected native output, never the uncorrected external sidecar. */
        val srt: ByteArray get() = ownedSrt.copyOf()
        val cues: List<SubtitleReferenceQuery.RetimedCue> = Collections.unmodifiableList(ArrayList(source))
        val boundaryCount: Int get() = index.boundaryCount

        /**
         * All overlapping cues in original file order; [startMs, endMs). The immutable index supports
         * backward seeks and equal-start occurrences. Use Clock to avoid repeating work within a
         * boundary; a cold lookup visits only matching cues and the tree paths needed to find them.
         */
        override fun lookup(mediaMs: Long): List<Cue> {
            val active = index.lookup(mediaMs)
            if (active.isEmpty()) return emptyList()
            return Collections.unmodifiableList(active.map { rendered[it] })
        }

        override fun boundaryIdentity(mediaMs: Long): Int = index.boundaryAt(mediaMs)
    }

    data class Update(val changed: Boolean, val cues: List<Cue>, val boundaryIdentity: Int)

    /**
     * Main-looper publication state. Pass player.currentPosition at each tick and after seeks.
     * Within the same prepared boundary the exact immutable list is reused, with no cue scan or
     * SubtitleView redraw. A replacement Prepared refreshes even when its boundary number matches.
     */
    class Clock {
        private val identity = SubtitleReferencePresentationCore.BoundaryClock()
        private var visible: List<Cue> = emptyList()

        fun sample(prepared: SubtitleCuePresentation, mediaMs: Long): Update {
            val boundary = prepared.boundaryIdentity(mediaMs)
            val changed = identity.changed(prepared, boundary)
            if (changed) visible = prepared.lookup(mediaMs)
            return Update(changed, visible, boundary)
        }

        fun reset() { identity.reset(); visible = emptyList() }
    }

    /** The bounded subtitle worker must prepare the complete result before main-looper adoption. */
    fun prepare(file: SubtitleReferenceQuery.Aligned): Prepared? {
        if (file.cues.size !in 1..SubtitleReferencePresentationCore.maximumCues) return null
        val srt = file.srt
        if (srt.size !in 1..SubtitleReferencePresentationCore.maximumSrtBytes) return null
        val parsed = SubtitleReferencePresentationCore.prepare(
            srt.size,
            file.cues.map { SubtitleReferencePresentationCore.SourceCue(it.startMs, it.endMs, it.text) },
        ) ?: return null
        val rendered = ArrayList<Cue>(parsed.cues.size)
        for (cue in parsed.cues) rendered.add(render(cue.runs))
        return Prepared(file.originalJob, srt, file.cues, file.correction,
            Collections.unmodifiableList(rendered), parsed.index)
    }

    private fun render(runs: List<SubtitleReferencePresentationCore.Run>): Cue {
        val text = SpannableStringBuilder()
        for (run in runs) {
            val start = text.length
            text.append(run.text)
            val end = text.length
            val style = run.style
            val typeface = when {
                style.bold && style.italic -> Typeface.BOLD_ITALIC
                style.bold -> Typeface.BOLD
                style.italic -> Typeface.ITALIC
                else -> null
            }
            typeface?.let { text.setSpan(StyleSpan(it), start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE) }
            if (style.underline) text.setSpan(UnderlineSpan(), start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            style.foregroundRgb?.let {
                text.setSpan(ForegroundColorSpan(0xff000000.toInt() or it), start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            }
        }
        return Cue.Builder().setText(SpannedString(text)).build()
    }
}
