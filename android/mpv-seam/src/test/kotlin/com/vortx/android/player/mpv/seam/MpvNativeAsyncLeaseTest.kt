package com.vortx.android.player.mpv.seam

import java.util.concurrent.atomic.AtomicBoolean
import org.junit.Assert.*
import org.junit.Test

class MpvNativeAsyncLeaseTest {
    @Test fun `retirement denies new work but exact original cleanup remains leased`() {
        val owner = AtomicBoolean(true)
        val gate = MpvNativeHandleGate(17L)
        assertTrue(gate.bindOriginalOwner(owner))
        var cancellation = 0
        var destruction = 0
        val lease = gate.acquireAsyncLease { cancellation++ }!!
        owner.set(false)
        assertEquals(-1L, gate.withHandle(-1L) { it })
        assertEquals(-1L, lease.submit(-1L) { it })
        assertNull(gate.requestDestroy { destruction++ })
        assertEquals(1, cancellation)
        assertEquals(17L, lease.cleanup(-1L) { it })
        assertEquals(0, destruction)
        lease.close(); lease.close()
        assertEquals(1, destruction)
        assertEquals(-1L, lease.cleanup(-1L) { it })
    }

    @Test fun `real terminal before enqueue returns cannot destroy the active JNI call`() {
        val gate = MpvNativeHandleGate(23L)
        gate.bindOriginalOwner(AtomicBoolean(true))
        var destroyed = 0
        val lease = gate.acquireAsyncLease {}!!
        assertEquals(23L, lease.submit(-1L) { handle ->
            gate.requestDestroy { destroyed++ }
            lease.close() // terminal delivery wins before the submitting JNI call returns
            assertEquals(0, destroyed)
            handle
        })
        assertEquals(1, destroyed)
    }

    @Test fun `unbound initialization handle cannot open an owner qualified async effect`() {
        val gate = MpvNativeHandleGate(29L)
        assertEquals(29L, gate.withHandle(-1L) { it }) // pre-init ordinary behavior is unchanged
        assertNull(gate.acquireAsyncLease {})
    }
}
