package com.vortx.android.engine

import org.junit.Assert.*
import org.junit.Test
import org.json.JSONObject
import java.util.UUID

class NativePlaylistCloudReceiptLedgerTest {
    @Test fun registerFingerprintIncludesClockActorAndValue() {
        val a = JSONObject().put("clock", 1).put("actor", "00000000-0000-0000-0000-000000000001").put("value", JSONObject.NULL)
        val b = JSONObject().put("clock", 2).put("actor", "00000000-0000-0000-0000-000000000001").put("value", JSONObject.NULL)
        val first = requireNotNull(NativePlaylist.canonicalReceiptRegister(a))
        val second = requireNotNull(NativePlaylist.canonicalReceiptRegister(b))
        assertNotEquals(NativePlaylistCloudReceiptLedger.Fingerprint.of(first), NativePlaylistCloudReceiptLedger.Fingerprint.of(second))
        val cycle = JSONObject().put("clock", 1).put("actor", "00000000-0000-0000-0000-000000000001").put("value", JSONObject.NULL)
        cycle.put("extra", cycle)
        assertNull(NativePlaylist.canonicalReceiptRegister(cycle))
    }
    @Test fun onlyFrozenExactRegisterCanBecomeSaved() {
        val ledger = NativePlaylistCloudReceiptLedger()
        val owner = Any()
        val field = "playlist.v1.00000000-0000-0000-0000-000000000101"
        val first = "{\"actor\":\"a\",\"clock\":1,\"value\":null}".toByteArray()
        val old = requireNotNull(ledger.register(owner, UUID.randomUUID(), field, first))
        val frozen = ledger.freeze().single()
        val next = requireNotNull(ledger.register(owner, UUID.randomUUID(), field, "{\"actor\":\"a\",\"clock\":2,\"value\":null}".toByteArray()))
        assertFalse(ledger.acknowledge(frozen, "{\"actor\":\"b\",\"clock\":1,\"value\":null}".toByteArray(), 7))
        assertTrue(ledger.acknowledge(frozen, first, 7))
        assertEquals(NativePlaylistCloudReceiptLedger.State.Pending, ledger.state(owner, next, next.fingerprint))
        assertEquals(NativePlaylistCloudReceiptLedger.State.Saved(7), ledger.state(owner, old, old.fingerprint))
        assertFalse(ledger.acknowledge(frozen, first, 8))
        assertEquals(NativePlaylistCloudReceiptLedger.State.Unknown, ledger.state(Any(), old, old.fingerprint))
        ledger.retire(owner)
        assertEquals(NativePlaylistCloudReceiptLedger.State.Unknown, ledger.state(owner, old, old.fingerprint))
        assertFalse(ledger.acknowledge(frozen, first, 9))
    }
    @Test fun boundsForgetReceiptsRatherThanSavedData() {
        val ledger = NativePlaylistCloudReceiptLedger()
        val owner = Any()
        val field = "playlist.v1.00000000-0000-0000-0000-000000000101"
        assertNull(ledger.register(owner, UUID.randomUUID(), field, ByteArray(513 * 1024 + 1)))
        val old = requireNotNull(ledger.register(owner, UUID.randomUUID(), field, ByteArray(513 * 1024)))
        repeat(9) { ledger.register(owner, UUID.randomUUID(), field, ByteArray(513 * 1024)) }
        assertEquals(NativePlaylistCloudReceiptLedger.State.Unknown, ledger.state(owner, old, old.fingerprint))
        assertTrue(ledger.freeze().size <= 64)
    }
    @Test fun coordinatorRetirementForgetsAllOwnersAndFrozenEdits() {
        val ledger = NativePlaylistCloudReceiptLedger()
        val a = Any(); val b = Any()
        val field = "playlist.v1.00000000-0000-0000-0000-000000000101"
        val bytes = "{\"actor\":\"fixture\",\"clock\":1,\"value\":null}".toByteArray()
        val first = requireNotNull(ledger.register(a, UUID.randomUUID(), field, bytes))
        val second = requireNotNull(ledger.register(b, UUID.randomUUID(), field, bytes))
        val frozen = ledger.freeze()
        ledger.retire()
        assertTrue(ledger.freeze().isEmpty())
        assertEquals(NativePlaylistCloudReceiptLedger.State.Unknown, ledger.state(a, first, first.fingerprint))
        assertEquals(NativePlaylistCloudReceiptLedger.State.Unknown, ledger.state(b, second, second.fingerprint))
        frozen.forEach { assertFalse(ledger.acknowledge(it, bytes, 1)) }
    }
}
