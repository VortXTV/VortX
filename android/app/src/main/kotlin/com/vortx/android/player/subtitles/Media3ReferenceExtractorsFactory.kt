package com.vortx.android.player.subtitles

import android.net.Uri
import androidx.media3.common.C
import androidx.media3.common.util.UnstableApi
import androidx.media3.extractor.DefaultExtractorsFactory
import androidx.media3.extractor.Extractor
import androidx.media3.extractor.ExtractorInput
import androidx.media3.extractor.ExtractorOutput
import androidx.media3.extractor.ExtractorsFactory
import androidx.media3.extractor.PositionHolder
import androidx.media3.extractor.TrackOutput
import androidx.media3.extractor.text.DefaultSubtitleParserFactory
import androidx.media3.extractor.text.SubtitleParser
import java.io.IOException

/** Inject only into the primary PROGRESSIVE source, never HLS, a sidecar or a merged audio leg. */
@UnstableApi
internal class Media3ReferenceExtractorsFactory private constructor(
    private val capture: Media3EmbeddedReferenceCapture,
    private val delegate: DefaultExtractorsFactory,
) : ExtractorsFactory by delegate {
    constructor(capture: Media3EmbeddedReferenceCapture) : this(capture, DefaultExtractorsFactory())

    override fun createExtractors(): Array<Extractor> = wrap(delegate.createExtractors())

    override fun createExtractors(uri: Uri, responseHeaders: Map<String, List<String>>): Array<Extractor> =
        wrap(delegate.createExtractors(uri, responseHeaders))

    override fun setSubtitleParserFactory(subtitleParserFactory: SubtitleParser.Factory): ExtractorsFactory {
        // Preserve the downstream request while refusing an unreviewed parser as occurrence evidence.
        if (subtitleParserFactory.javaClass != DefaultSubtitleParserFactory::class.java) capture.fail()
        delegate.setSubtitleParserFactory(subtitleParserFactory)
        return this
    }

    private fun wrap(extractors: Array<Extractor>): Array<Extractor> =
        Array(extractors.size) { Media3ReferenceExtractor(extractors[it], capture) }
}

/** One real extraction context. Sniff-only candidates never initialize or retire the witness. */
@UnstableApi
internal class Media3ReferenceExtractor(
    private val delegate: Extractor,
    private val capture: Media3EmbeddedReferenceCapture,
) : Extractor by delegate {
    private class Tee(val downstream: TrackOutput, val output: Media3ReferenceTrackOutput)
    private val extractorIdentity = Any()
    private val textOutputs = LinkedHashMap<Int, Tee>()
    private var initialized = false

    override fun getUnderlyingImplementation(): Extractor = delegate.underlyingImplementation

    override fun init(output: ExtractorOutput) {
        if (!capture.initialize(extractorIdentity)) {
            capture.fail() // A replacement extractor must not reuse the former extractor's EOS witness.
            delegate.init(output)
            return
        }
        initialized = true
        val observingOutput = object : ExtractorOutput by output {
            override fun track(id: Int, type: Int): TrackOutput {
                val downstream = output.track(id, type)
                if (type != C.TRACK_TYPE_TEXT) {
                    if (textOutputs.containsKey(id)) capture.fail()
                    return downstream
                }
                val existing = textOutputs[id]
                if (existing != null) {
                    if (existing.downstream === downstream) return existing.output
                    capture.fail()
                    return downstream
                }
                val track = capture.track(extractorIdentity, id) ?: return downstream
                return Media3ReferenceTrackOutput(downstream, capture, track).also {
                    textOutputs[id] = Tee(downstream, it)
                }
            }
        }
        try {
            delegate.init(observingOutput)
        } catch (error: RuntimeException) {
            capture.fail()
            throw error
        }
    }

    override fun read(input: ExtractorInput, seekPosition: PositionHolder): Int {
        capture.beginRead(extractorIdentity, input.position)
        val result = try {
            delegate.read(input, seekPosition)
        } catch (error: IOException) {
            capture.fail()
            throw error
        } catch (error: RuntimeException) {
            capture.fail()
            throw error
        }
        val capturedResult = when (result) {
            Extractor.RESULT_CONTINUE -> Media3EmbeddedReferenceCapture.ReadResult.CONTINUE
            Extractor.RESULT_SEEK -> Media3EmbeddedReferenceCapture.ReadResult.SEEK_REQUIRED
            Extractor.RESULT_END_OF_INPUT -> {
                textOutputs.values.forEach { it.output.endOfInput() }
                Media3EmbeddedReferenceCapture.ReadResult.END_OF_INPUT
            }
            else -> { capture.fail(); Media3EmbeddedReferenceCapture.ReadResult.CONTINUE }
        }
        capture.endRead(extractorIdentity, input.position, capturedResult)
        return result
    }

    override fun seek(position: Long, timeUs: Long) {
        if (initialized) capture.seek(extractorIdentity, position, timeUs)
        delegate.seek(position, timeUs)
    }

    override fun release() {
        if (initialized) {
            capture.retire()
            textOutputs.values.forEach { it.output.release() }
            textOutputs.clear()
        }
        delegate.release()
    }
}
