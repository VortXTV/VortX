package com.vortx.android.trickplay

import java.net.HttpURLConnection
import java.net.URL
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TrickplayConsentGateTest {

    @Test
    fun `opt out after admission before post revokes permit and disconnects active request`() {
        val gate = TrickplayConsentGate()
        val request = CommunityTrickplayRequestControl()
        val connection = RecordingConnection()
        val admission = gate.admit()

        request.register(connection)
        assertTrue(gate.permits(admission))
        assertTrue(request.isActive())

        gate.revoke()
        request.cancel()

        assertFalse(gate.permits(admission))
        assertFalse(request.isActive())
        assertTrue(connection.disconnected)
    }

    private class RecordingConnection : HttpURLConnection(URL("https://example.invalid")) {
        var disconnected = false

        override fun disconnect() {
            disconnected = true
        }

        override fun usingProxy(): Boolean = false

        override fun connect() = Unit
    }
}
