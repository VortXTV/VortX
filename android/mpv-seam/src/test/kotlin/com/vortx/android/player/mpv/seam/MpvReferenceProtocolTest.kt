package com.vortx.android.player.mpv.seam

import org.junit.Assert.*
import org.junit.Test

class MpvReferenceProtocolTest {
    @Test fun `v2 hidden reference retains visible Off and actual stream identity`() {
        val capture = MpvReferenceProtocol.capture(MpvReferenceTestNodes.node(MpvReferenceTestNodes.fields()), 22L)!!
        assertEquals(3L, capture.referenceSID)
        assertEquals(1L, capture.referenceCommandIndex)
        assertEquals(5L, capture.referenceStreamIndex)
        assertEquals(0L, capture.primarySID)
        assertFalse(capture.primaryVisible)
        assertArrayEquals(longArrayOf(11, 22, 3, 1, 5, 0, 0), capture.witness())
        assertEquals(7, capture.witness().size) // packed flags keep native command below its eleven-argument ABI
    }

    @Test fun `v1 and mixed or malformed v2 capability never gain authority`() {
        val fields = MpvReferenceTestNodes.fields()
        for (changed in listOf(
            fields + ("version" to 1L), fields + ("intent-generation" to "11"),
            fields + ("reference-stream-index" to 1024L), fields + ("primary-sid" to -1L),
            fields + ("primary-external" to true), fields + ("demux-origin" to Double.NaN),
            fields + ("demux-origin" to 86_401.0), fields + ("unknown" to 1L),
        )) assertNull(MpvReferenceProtocol.capture(MpvReferenceTestNodes.node(changed), 22L))
        assertNull(MpvReferenceProtocol.capture(MpvReferenceTestNodes.node(fields), 23L))
    }

    @Test fun `all repeated and equal start cue occurrences survive transport`() {
        val fields = MpvReferenceTestNodes.fields(9L, true, true)
        val capture = MpvReferenceProtocol.capture(MpvReferenceTestNodes.node(fields), 22L)!!
        val receipt = MpvReferenceProtocol.read(MpvReferenceTestNodes.read(fields), capture)!!
        assertEquals(listOf(MpvReferenceTiming(100, 200), MpvReferenceTiming(100, 200), MpvReferenceTiming(300, 400)), receipt.cues)
        assertArrayEquals(longArrayOf(31, 11, 22, 41, 3, 1, 5, 9, 3), receipt.prepareWitness())
        assertEquals(9, receipt.prepareWitness().size)
    }

    @Test fun `reply cannot change the original primary choice or scalar types`() {
        val fields = MpvReferenceTestNodes.fields(9L, true, false)
        val capture = MpvReferenceProtocol.capture(MpvReferenceTestNodes.node(fields), 22L)!!
        assertNull(MpvReferenceProtocol.read(MpvReferenceTestNodes.read(fields + ("primary-visible" to true)), capture))
        assertNull(MpvReferenceProtocol.read(MpvReferenceTestNodes.read(fields + ("version" to 1L)), capture))
        assertNull(MpvReferenceProtocol.prepared(MpvReferenceTestNodes.node(mapOf("version" to 2L, "grant" to 32L, "ticket" to 8L)),
            MpvReferenceProtocol.read(MpvReferenceTestNodes.read(fields), capture)!!))
    }

    @Test fun `node owns its arrays and rejects malformed cue bounds`() {
        val keys = arrayOf("version")
        val values = longArrayOf(2)
        val node = MpvReferenceNode(keys, intArrayOf(4), values, doubleArrayOf(0.0), longArrayOf())
        keys[0] = "changed"; values[0] = 0
        assertEquals(2L, node.integer("version"))
        for (pairs in listOf(longArrayOf(-1, 2), longArrayOf(2, 2), longArrayOf(1, 1_080_001), longArrayOf(4, 5, 3, 6))) {
            assertNull(MpvReferenceNode(arrayOf("cues"), intArrayOf(7), longArrayOf(0), doubleArrayOf(0.0), pairs).timings())
        }
    }
}
