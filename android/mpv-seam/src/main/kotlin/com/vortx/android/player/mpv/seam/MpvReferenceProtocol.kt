package com.vortx.android.player.mpv.seam

/** A bounded owned copy of a native NODE map. No borrowed node, URL or header escapes JNI. */
class MpvReferenceNode internal constructor(
    keys: Array<String>, formats: IntArray, integers: LongArray,
    numbers: DoubleArray, cuePairs: LongArray,
) {
    private val valid = keys.size in 1..24 && formats.size == keys.size &&
        integers.size == keys.size && numbers.size == keys.size &&
        cuePairs.size <= 2048 && cuePairs.size % 2 == 0 && keys.toSet().size == keys.size
    private val keys = if (valid) keys.copyOf() else emptyArray()
    private val formats = if (valid) formats.copyOf() else intArrayOf()
    private val integers = if (valid) integers.copyOf() else longArrayOf()
    private val numbers = if (valid) numbers.copyOf() else doubleArrayOf()
    private val cuePairs = if (valid) cuePairs.copyOf() else longArrayOf()

    internal fun hasKeys(expected: Set<String>): Boolean = valid && keys.toSet() == expected
    internal fun integer(key: String): Long? = keys.indexOf(key).takeIf { it >= 0 && formats[it] == 4 }
        ?.let { integers[it] }
    internal fun number(key: String): Double? = keys.indexOf(key).takeIf { it >= 0 && formats[it] == 5 }
        ?.let { numbers[it] }?.takeIf(Double::isFinite)
    internal fun flag(key: String): Boolean? = keys.indexOf(key).takeIf { it >= 0 && formats[it] == 3 }
        ?.let { when (integers[it]) { 0L -> false; 1L -> true; else -> null } }
    internal fun timings(): List<MpvReferenceTiming>? {
        val at = keys.indexOf("cues")
        if (at < 0 || formats[at] != 7 || cuePairs.size !in 2..2048) return null
        val result = ArrayList<MpvReferenceTiming>(cuePairs.size / 2)
        var previous = -1L
        for (index in cuePairs.indices step 2) {
            val start = cuePairs[index]
            val end = cuePairs[index + 1]
            if (start < 0 || start < previous || end <= start || end > 1_080_000L) return null
            result.add(MpvReferenceTiming(start, end))
            previous = start // equal starts and repeated occurrences are retained
        }
        return java.util.Collections.unmodifiableList(result)
    }
}

data class MpvReferenceTiming(val startMs: Long, val endMs: Long)

/** Version 2 separates a hidden embedded reference from the viewer's visible primary choice. */
data class MpvReferenceCapture internal constructor(
    val intent: Long,
    val entry: Long,
    val referenceSID: Long,
    val referenceCommandIndex: Long,
    val referenceStreamIndex: Long,
    val primarySID: Long,
    val primaryExternal: Boolean,
    val primaryVisible: Boolean,
    val origin: Double,
) {
    internal fun witness(): LongArray = longArrayOf(
        intent, entry, referenceSID, referenceCommandIndex, referenceStreamIndex, primarySID,
        (if (primaryExternal) 1L else 0L) or (if (primaryVisible) 2L else 0L),
    )
}

data class MpvReferenceReceipt internal constructor(
    val capture: MpvReferenceCapture,
    val grant: Long,
    val source: Long,
    val response: Long,
    val sourceEpoch: Long,
    val demuxEpoch: Long,
    val origin: Double,
    val cues: List<MpvReferenceTiming>,
) {
    internal fun prepareWitness(): LongArray = longArrayOf(
        grant, capture.intent, capture.entry, source, capture.referenceSID,
        capture.referenceCommandIndex, capture.referenceStreamIndex, capture.primarySID,
        (if (capture.primaryExternal) 1L else 0L) or (if (capture.primaryVisible) 2L else 0L),
    )
}

sealed interface MpvReferenceReply {
    data class Read(val receipt: MpvReferenceReceipt) : MpvReferenceReply
    data class Prepared(val grant: Long, val ticket: Long) : MpvReferenceReply
    data class Committed(val grant: Long, val ticket: Long) : MpvReferenceReply
    data class Rejected(val nativeError: Int) : MpvReferenceReply
    data object Unconfirmed : MpvReferenceReply
    data object Cancelled : MpvReferenceReply
}

internal class MpvReferenceCommand(
    val operation: Int, val integers: LongArray, val origin: Double, val payload: ByteArray? = null,
) {
    companion object {
        const val READ = 0
        const val PREPARE = 1
        const val COMMIT = 2
    }
}

internal object MpvReferenceProtocol {
    const val VERSION = 2L
    const val MAX_PAYLOAD_BYTES = 9 * 1024 * 1024
    private val captureKeys = setOf(
        "version", "intent-generation", "entry-id", "reference-sid", "reference-command-index",
        "reference-stream-index", "primary-sid", "primary-external", "primary-visible", "demux-origin",
    )
    private val readKeys = captureKeys + setOf(
        "grant", "source-generation", "response-generation", "source-epoch", "demux-epoch",
        "origin", "prefix-start-ms", "prefix-end-ms", "cues",
    )

    fun capture(node: MpvReferenceNode?, expectedEntry: Long): MpvReferenceCapture? {
        if (node == null || !node.hasKeys(captureKeys)) return null
        return captureFields(node)?.takeIf { it.entry == expectedEntry }
    }

    private fun captureFields(node: MpvReferenceNode): MpvReferenceCapture? {
        if (node.integer("version") != VERSION) return null
        val intent = positive(node, "intent-generation") ?: return null
        val entry = positive(node, "entry-id") ?: return null
        val sid = positive(node, "reference-sid")?.takeIf { it <= Int.MAX_VALUE } ?: return null
        val command = node.integer("reference-command-index")?.takeIf { it in 0L..127L } ?: return null
        val stream = node.integer("reference-stream-index")?.takeIf { it in 0L..1023L } ?: return null
        val primary = node.integer("primary-sid")?.takeIf { it in 0L..Int.MAX_VALUE.toLong() } ?: return null
        val external = node.flag("primary-external") ?: return null
        val visible = node.flag("primary-visible") ?: return null
        if (primary == 0L && external) return null
        val origin = node.number("demux-origin")?.takeIf { kotlin.math.abs(it) <= 86_400 } ?: return null
        return MpvReferenceCapture(intent, entry, sid, command, stream, primary, external, visible, origin)
    }

    fun read(node: MpvReferenceNode?, expected: MpvReferenceCapture): MpvReferenceReceipt? {
        if (node == null || !node.hasKeys(readKeys) || captureFields(node) != expected ||
            node.integer("prefix-start-ms") != 0L || node.integer("prefix-end-ms") != 1_080_000L) return null
        return MpvReferenceReceipt(
            expected, positive(node, "grant") ?: return null,
            positive(node, "source-generation") ?: return null,
            positive(node, "response-generation") ?: return null,
            positive(node, "source-epoch") ?: return null,
            positive(node, "demux-epoch") ?: return null,
            node.number("origin")?.takeIf { kotlin.math.abs(it) <= 86_400 } ?: return null,
            node.timings() ?: return null,
        )
    }

    fun prepared(node: MpvReferenceNode?, receipt: MpvReferenceReceipt): Long? {
        if (node == null || !node.hasKeys(setOf("version", "grant", "ticket")) ||
            node.integer("version") != VERSION || node.integer("grant") != receipt.grant) return null
        return positive(node, "ticket")
    }

    fun committed(node: MpvReferenceNode?, receipt: MpvReferenceReceipt, ticket: Long): Boolean =
        node != null && node.hasKeys(setOf("version", "grant", "ticket", "committed")) &&
            node.integer("version") == VERSION && node.integer("grant") == receipt.grant &&
            node.integer("ticket") == ticket && node.flag("committed") == true

    fun active(node: MpvReferenceNode?, receipt: MpvReferenceReceipt, ticket: Long): Boolean =
        node != null && node.hasKeys(captureKeys + setOf("grant", "ticket", "source-generation")) &&
            captureFields(node) == receipt.capture && node.integer("grant") == receipt.grant &&
            node.integer("ticket") == ticket && node.integer("source-generation") == receipt.source

    private fun positive(node: MpvReferenceNode, key: String): Long? = node.integer(key)?.takeIf { it > 0 }
}
