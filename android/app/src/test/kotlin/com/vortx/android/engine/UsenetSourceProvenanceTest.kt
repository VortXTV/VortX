package com.vortx.android.engine

import com.vortx.android.torbox.TorBoxSearch
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class UsenetSourceProvenanceTest {

    @Test
    fun torBoxResponseMapsItsNzbHashWithoutUsingTorrentInfoHash() {
        val body = """
            {
              "data": {
                "nzbs": [{
                  "hash": "ABCDEF0123456789",
                  "raw_title": "Neutral release",
                  "nzb": "https://example.invalid/fetch/neutral",
                  "type": "usenet"
                }]
              }
            }
        """.trimIndent()

        val source = TorBoxSearch.decodeStreams(body).single()

        assertEquals("abcdef0123456789", source.usenetKnownHash)
        assertNull(source.infoHash)
    }

    @Test
    fun engineStreamMapsFirstUsenetHashMarkerWithoutUsingTorrentInfoHash() {
        val state = """
            {
              "streams": [{
                "request": {"base": "https://addon.example/manifest.json"},
                "content": {
                  "type": "Ready",
                  "content": [{
                    "name": "Neutral release",
                    "nzbUrl": "https://example.invalid/fetch/neutral",
                    "sources": [
                      "tracker:https://tracker.invalid/announce",
                      "usenethash:ABCDEF0123456789",
                      "usenethash:ignored-second-marker"
                    ]
                  }]
                }
              }]
            }
        """.trimIndent()

        val source = EngineState.parseStreamGroups(state).single().streams.single()

        assertEquals("abcdef0123456789", source.usenetKnownHash)
        assertNull(source.infoHash)
    }
}
