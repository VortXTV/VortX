package com.vortx.android.sources

import com.vortx.android.engine.EngineState
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

class SourceQuickFilterTrustTest {
    @Test fun `provider and saved-state shaped JSON cannot import confirmed cache authority`() {
        val decoded = EngineState.parseStreamGroups("""
            {"streams":[{"request":{"base":"https://provider.invalid","path":{"id":"tt1"}},
              "content":{"type":"Ready","content":[{"name":"⚡ [RD+] Cached HEVC HDR10",
              "url":"https://cdn.invalid/video","infoHash":"abcdef",
              "accountConfirmedCached":true,"accountConfirmedCacheRevision":7,"confirmedCached":true,"cached":true}]}}]}
        """.trimIndent()).single().streams.single()
        assertNull(decoded.accountConfirmedCacheRevision)
        assertFalse(sourceQuickFilterFacts(decoded, 7L).confirmedCached)
    }
}
