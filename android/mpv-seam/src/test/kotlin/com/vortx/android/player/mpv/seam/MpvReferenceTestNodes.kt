package com.vortx.android.player.mpv.seam

internal object MpvReferenceTestNodes {
    fun fields(primary: Long = 0L, external: Boolean = false, visible: Boolean = false): Map<String, Any> = linkedMapOf(
        "version" to 2L, "intent-generation" to 11L, "entry-id" to 22L,
        "reference-sid" to 3L, "reference-command-index" to 1L,
        "reference-stream-index" to 5L, "primary-sid" to primary,
        "primary-external" to external, "primary-visible" to visible, "demux-origin" to 90.0,
    )

    fun node(fields: Map<String, Any>): MpvReferenceNode {
        val keys = fields.keys.toTypedArray()
        val formats = IntArray(keys.size)
        val integers = LongArray(keys.size)
        val numbers = DoubleArray(keys.size)
        var cues = longArrayOf()
        for ((index, key) in keys.withIndex()) {
            when (val value = fields.getValue(key)) {
                is Long -> { formats[index] = 4; integers[index] = value }
                is Double -> { formats[index] = 5; numbers[index] = value }
                is Boolean -> { formats[index] = 3; integers[index] = if (value) 1L else 0L }
                is List<*> -> {
                    formats[index] = 7
                    cues = value.flatMap {
                        val pair = it as Pair<*, *>
                        listOf(pair.first as Long, pair.second as Long)
                    }.toLongArray()
                }
                else -> formats[index] = 1 // deliberately unsupported native type
            }
        }
        return MpvReferenceNode(keys, formats, integers, numbers, cues)
    }

    fun read(fields: Map<String, Any> = MpvReferenceTestNodes.fields(), grant: Long = 31L): MpvReferenceNode = node(fields + linkedMapOf(
        "grant" to grant, "source-generation" to 41L, "response-generation" to 51L,
        "source-epoch" to 61L, "demux-epoch" to 71L, "origin" to 90.0,
        "prefix-start-ms" to 0L, "prefix-end-ms" to 1_080_000L,
        "cues" to listOf(100L to 200L, 100L to 200L, 300L to 400L),
    ))
}
