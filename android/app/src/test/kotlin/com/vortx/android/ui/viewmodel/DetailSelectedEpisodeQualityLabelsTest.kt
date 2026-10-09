package com.vortx.android.ui.viewmodel

import com.vortx.android.engine.SourceListState
import com.vortx.android.model.StreamSource
import com.vortx.android.sources.SourceRequestFence
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class DetailSelectedEpisodeQualityLabelsTest {
    private val source = StreamSource("fixture", "Addon", "4K", url = "https://example.invalid/fixture")
    private fun assembled(request: SourceRequestFence.Token) = SourceListState(
        resolutionOptions = listOf("4K" to source, "1080p" to source, "4K" to source),
        requestGeneration = request.generation,
        streamId = request.targetId,
    )

    @Test fun acceptedAssemblyReturnsOnlyItsDistinctResolutionLabels() {
        val fence = SourceRequestFence("main")
        val request = fence.begin("main", "opaque-episode-2")
        assertEquals(listOf("4K", "1080p"), selectedEpisodeQualityLabelsForCurrentRequest(
            assembled(request), fence, "main", "opaque-episode-2",
        ))
    }

    @Test fun anotherSelectedEpisodeCannotClaimTheCurrentEpisodesQuality() {
        val fence = SourceRequestFence("main")
        val request = fence.begin("main", "opaque-episode-2")
        assertTrue(selectedEpisodeQualityLabelsForCurrentRequest(assembled(request), fence, "main", "opaque-episode-1").isEmpty())
        assertTrue(selectedEpisodeQualityLabelsForCurrentRequest(
            assembled(request).copy(streamId = "opaque-episode-1"), fence, "main", "opaque-episode-2",
        ).isEmpty())
    }

    @Test fun targetRoundTripCannotReuseAnOldGeneration() {
        val fence = SourceRequestFence("main")
        val old = fence.begin("main", "episode-1")
        fence.begin("main", "episode-2")
        val current = fence.begin("main", "episode-1")
        assertTrue(selectedEpisodeQualityLabelsForCurrentRequest(assembled(old), fence, "main", "episode-1").isEmpty())
        assertEquals(listOf("4K", "1080p"), selectedEpisodeQualityLabelsForCurrentRequest(assembled(current), fence, "main", "episode-1"))
    }

    @Test fun profileSwitchInvalidatesOldClaimsEvenForTheSameEpisode() {
        val fence = SourceRequestFence("main")
        val old = fence.begin("main", "episode-1")
        assertTrue(selectedEpisodeQualityLabelsForCurrentRequest(assembled(old), fence, "other", "episode-1").isEmpty())
        fence.invalidate("other")
        assertTrue(selectedEpisodeQualityLabelsForCurrentRequest(assembled(old), fence, "other", "episode-1").isEmpty())
        val current = fence.begin("other", "episode-1")
        assertTrue(selectedEpisodeQualityLabelsForCurrentRequest(assembled(old), fence, "other", "episode-1").isEmpty())
        assertEquals(listOf("4K", "1080p"), selectedEpisodeQualityLabelsForCurrentRequest(assembled(current), fence, "other", "episode-1"))
    }

    @Test fun absentRequestOrAssemblyMakesNoQualityClaim() {
        val fence = SourceRequestFence("main")
        assertTrue(selectedEpisodeQualityLabelsForCurrentRequest(SourceListState(), fence, "main", "episode").isEmpty())
        val request = fence.begin("main", "episode")
        assertTrue(selectedEpisodeQualityLabelsForCurrentRequest(SourceListState(), fence, "main", "episode").isEmpty())
        assertTrue(selectedEpisodeQualityLabelsForCurrentRequest(assembled(request).copy(resolutionOptions = emptyList()), fence, "main", "episode").isEmpty())
        fence.begin("main", null)
        assertTrue(selectedEpisodeQualityLabelsForCurrentRequest(assembled(request), fence, "main", "episode").isEmpty())
    }

    @Test fun actualGetterDelegatesToTheAssemblyFenceWithoutRawStreamsFallback() {
        val source = listOf("src/main/kotlin/", "app/src/main/kotlin/", "android/app/src/main/kotlin/")
            .map { File(it + "com/vortx/android/ui/viewmodel/DetailViewModel.kt") }.first(File::isFile).readText()
        val getter = source.substringAfter("fun selectedEpisodeQualityLabels(selectedVideoId: String)")
            .substringBefore("/** The exact source")
        assertTrue(getter.contains("selectedEpisodeQualityLabelsForCurrentRequest("))
        assertTrue(getter.contains("sourceModel.state.value, sourceRequestFence, sourceSticky.currentProfileId(), selectedVideoId"))
        assertTrue(!getter.contains("_streams"))
    }
}
