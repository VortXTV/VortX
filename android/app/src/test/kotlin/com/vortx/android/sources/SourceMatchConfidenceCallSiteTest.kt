package com.vortx.android.sources

import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** Source-only boundary checks complement actual rank/assembly/crypto execution without starting media. */
class SourceMatchConfidenceCallSiteTest {
    @Test fun allDetailAndAssemblySelectionsPassFrozenRequestEvidence() {
        for (path in listOf("ui/viewmodel/DetailViewModel.kt", "engine/SourceListModel.kt")) {
            val source = read(path)
            val calls = Regex("StreamRanking\\.(best|rankedCandidates|rankedGroups|applyUserFilters)\\(").findAll(source).toList()
            assertTrue("Actual selection calls in $path", calls.isNotEmpty())
            for (call in calls) {
                val body = balanced(source, call.range.last, '(', ')')
                assertTrue("Frozen context for ${call.value} in $path", body.contains("matchContext") || body.contains("ctx.matchContext"))
                assertTrue("Frozen prefs for ${call.value} in $path", body.contains("prefs") || body.contains("ctx.prefs"))
            }
            assertTrue("No installed preference fallback in $path", !source.contains("StreamRanking.reading()"))
        }
    }

    @Test fun directDownloadsAndPicksValidateCurrentFencedContextAndProfilesCarryTheSetting() {
        val detail = read("ui/viewmodel/DetailViewModel.kt")
        for (header in listOf("private fun play(\n", "suspend fun resolveSourceSwitch(", "fun download(source:")) {
            val start = detail.indexOf(header)
            assertTrue("$header exists", start >= 0)
            val body = balanced(detail, detail.indexOf('{', start), '{', '}')
            assertTrue("$header guards direct sources", body.contains("sourceMatchesCurrentRequest(source)"))
        }
        val contextStart = detail.indexOf("private fun currentSourceContext()")
        val context = balanced(detail, detail.indexOf('{', contextStart), '{', '}')
        assertTrue(context.contains("sourceRequestFence.accepts(request, sourceSticky.currentProfileId())"))
        assertTrue(context.contains("it.requestGeneration == request.generation && it.streamId == request.targetId"))
        assertTrue(read("profile/ProfileStore.kt").contains("SourcePreferencesStore.applyProfileMatchConfidence(e, p?.matchConfidenceThreshold, resetUnset)"))
        assertTrue(read("ui/screens/SmartSourceSelection.kt").contains("onValueChangeFinished = { ProfileStore.sharedOrNull()?.capturePlayback() }"))
    }

    @Test fun livePhoneAndTvVariantPickersDelegateToTheCurrentFencedViewModel() {
        val detail = read("ui/viewmodel/DetailViewModel.kt")
        val start = detail.indexOf("fun sourceVariantOptions(")
        assertTrue(start >= 0)
        val body = balanced(detail, detail.indexOf('{', start), '{', '}')
        assertTrue(body.contains("currentSourceContext() ?: return emptyList()"))
        assertTrue(body.contains("matchContext = ctx.matchContext"))
        assertTrue(body.contains("prefs = ctx.prefs"))
        for (path in listOf("ui/screens/DetailScreen.kt", "ui/tv/TvDetailScreen.kt")) {
            assertTrue("$path wires its real ViewModel", read(path).contains("onSourceVariantOptions = viewModel::sourceVariantOptions"))
        }
        for (path in listOf("ui/screens/DetailScreen.kt", "ui/tv/TvSourceList.kt")) {
            val source = read(path)
            assertTrue("$path invokes captured callback", Regex("onSourceVariantOptions\\((?:filteredGroups|groups), activeTier\\)").containsMatchIn(source))
            assertTrue("$path never recomputes from a global reading", !Regex("StreamRanking\\.variantOptions\\(").containsMatchIn(source))
        }
    }

    private fun balanced(source: String, start: Int, open: Char, close: Char): String {
        var depth = 0
        for (index in start until source.length) {
            if (source[index] == open) depth++
            if (source[index] == close && --depth == 0) return source.substring(start, index + 1)
        }
        error("Unclosed $open at $start")
    }

    private fun read(path: String): String = listOf("src/main/kotlin/", "app/src/main/kotlin/", "android/app/src/main/kotlin/")
        .map { File(it + "com/vortx/android/" + path) }.firstOrNull(File::isFile)?.readText()
        ?: error("Could not locate $path from ${File(".").absolutePath}")
}
