package com.vortx.android.engine

import com.vortx.android.data.StreamLoadUpdate
import com.vortx.android.debrid.DebridOwnerScope
import com.vortx.android.debrid.DebridOwnerToken
import com.vortx.android.model.StreamGroup
import com.vortx.android.model.StreamSource
import com.vortx.android.nzb.NzbIndexerStore
import org.junit.Assert.assertEquals
import org.junit.Test

class NzbSourceAggregationTest {
    @Test fun indexersAppendAfterNormalGroupsInConfiguredOrder() {
        val normal = listOf(StreamGroup("Preferred add-on", listOf(StreamSource("normal", "Preferred add-on", "Normal"))))
        val indexers = listOf(
            StreamGroup("First indexer", listOf(StreamSource("nzbindexer:a:hash#one", "First indexer", "One", nzbUrl = "https://a.example/nzb?r=x")), "nzbindexer:a"),
            StreamGroup("Second indexer", listOf(StreamSource("nzbindexer:b:hash#two", "Second indexer", "Two", nzbUrl = "https://b.example/nzb?r=x")), "nzbindexer:b"),
        )
        val result = mergeNzbGroups(normal, indexers)
        assertEquals(listOf("Preferred add-on", "First indexer", "Second indexer"), result.map(StreamGroup::addon))
        assertEquals("https://a.example/nzb?r=x", result[1].streams.single().nzbUrl)
        assertEquals(null, result[1].streams.single().url)
    }

    @Test fun onlyTerminalUpdateAdmitsIndexersSoPrewarmLastSeesTheCompleteGroups() {
        val normal = StreamGroup("Normal", emptyList())
        val indexer = StreamGroup("Indexer", emptyList(), "nzbindexer:one")
        val partial = StreamLoadUpdate(listOf(normal), loaded = 1, total = 2, terminal = false)
        val terminal = StreamLoadUpdate(listOf(normal), loaded = 2, total = 2, terminal = true)
        assertEquals(listOf(normal), appendNzbGroupsAtTerminal(partial, listOf(indexer)).groups)
        assertEquals(listOf(normal, indexer), appendNzbGroupsAtTerminal(terminal, listOf(indexer)).groups)
    }

    @Test fun cancelledOrChangedConfigAdmissionCannotPublishLateSearches() {
        val scope = NzbIndexerStore.Scope(DebridOwnerToken(DebridOwnerScope.Account("a"), 1), "profile")
        val admission = NzbSearchAdmission(scope, configRevision = 4)
        assertEquals(true, admission.accepts(scopeCurrent = true, currentRevision = 4, coroutineActive = true))
        assertEquals(false, admission.accepts(scopeCurrent = false, currentRevision = 4, coroutineActive = true))
        assertEquals(false, admission.accepts(scopeCurrent = true, currentRevision = 5, coroutineActive = true))
        assertEquals(false, admission.accepts(scopeCurrent = true, currentRevision = 4, coroutineActive = false))
    }
}
