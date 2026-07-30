package com.vortx.android.player.mpv

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MpvConfigTlsTest {
    @Test
    fun `security policy is complete and cannot be shadowed by base options`() {
        val caPath = "/data/user/0/com.vortx.android/no_backup/system-ca.pem"
        val options = MpvConfig.requiredSecurityOptions(caPath)

        assertEquals(
            listOf(
                "config",
                "load-scripts",
                "resume-playback",
                "tls-verify",
                "tls-ca-file",
                "stream-lavf-o",
                "demuxer-lavf-o",
                "demuxer-lavf-propagate-opts",
            ),
            options.map { it.first },
        )
        assertEquals("yes", options.toMap()["tls-verify"])
        assertEquals(caPath, options.toMap()["tls-ca-file"])
        assertEquals(
            "tls_verify=1,ca_file=$caPath,reconnect=1,reconnect_streamed=1,reconnect_delay_max=7",
            options.toMap()["stream-lavf-o"],
        )
        assertEquals("tls_verify=1,ca_file=$caPath", options.toMap()["demuxer-lavf-o"])
        assertFalse(
            MpvConfig.baseOptions.any { (name, _) ->
                name in options.map { it.first }
            },
        )
    }

    @Test
    fun `security policy rejects paths that can escape lavf dictionaries`() {
        for (path in listOf("", "   ", "/data/ca,bypass=1.pem", "/data/ca\u0000.pem")) {
            assertTrue(runCatching { MpvConfig.requiredSecurityOptions(path) }.isFailure)
        }
    }

    @Test
    fun `rejected security option fails initialization contract`() {
        val failure = runCatching {
            requireMpvSecurityOption("tls-verify", -5)
        }.exceptionOrNull()

        assertTrue(failure is IllegalStateException)
        assertTrue(failure?.message.orEmpty().contains("tls-verify"))
        requireMpvSecurityOption("tls-verify", 0)
    }
}
