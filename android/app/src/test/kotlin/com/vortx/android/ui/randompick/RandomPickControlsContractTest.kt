package com.vortx.android.ui.randompick

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** Source contract only; physical remote focus, layout and accessibility remain device gates. */
class RandomPickControlsContractTest {
    @Test fun touchAndTvKeepThemedFocusableChipsAndHorizontalScrolling() {
        val source = source("ui/randompick/RandomPickControls.kt")
        assertTrue(source.contains("TvFilterChip(label = label"))
        assertTrue(source.contains("Chip(label = label"))
        assertTrue(source.contains(".horizontalScroll(rememberScrollState())"))
        assertTrue(source.contains("!loading && playEnabled"))
        assertFalse(source.contains("focusable(false)"))
    }

    @Test fun episodePickerPreservesPhoneEpisodeFocusAndTvTargets() {
        val phone = source("ui/screens/DetailScreen.kt")
        assertTrue(phone.contains("item {\n                    Column {\n                    ActionsCluster("))
        assertTrue(phone.contains("restoreEpisodeFocusId = episode.id"))
        assertTrue(phone.contains("detailListState.scrollToItem(railItemIndex)"))
        val tv = source("ui/tv/TvDetailScreen.kt")
        assertTrue(tv.contains("focusRestoreEpisodeId = episode.id"))
        assertTrue(tv.contains("focusRestoreRevision++"))
        assertTrue(tv.contains("tv = true"))
    }

    @Test fun bothScreensCheckImmutableReadyAdmissionBeforeHandoff() {
        listOf("ui/screens/DetailScreen.kt", "ui/tv/TvDetailScreen.kt").forEach { path ->
            val source = source(path)
            assertTrue(source.contains("ready != null && !ready.isAdmitted()"))
            assertTrue(source.contains("viewModel.playback.value !== playback"))
            assertTrue(source.contains("ready.playable.playbackLease?.close()"))
            assertTrue(source.contains("if (!onAutoWatchConsumed()) return@LaunchedEffect"))
            assertTrue(source.contains("viewModel.playBestWhen(autoWatchAdmission)"))
        }
    }

    @Test fun deliberatePhoneBrowsingRetiresPendingRandomPlaybackBeforeNavigation() {
        val phone = source("ui/screens/DetailScreen.kt")
        val handlers = listOf(
            phone.substringAfter("onOpenTitle = { item ->").substringBefore("modifier ="),
            phone.substringAfter("val openRelated: (MetaItem) -> Unit = { item ->").substringBefore("// Per-title"),
            phone.substringAfter("onPersonTap = { person ->").substringBefore("personTarget = person"),
        )
        handlers.forEach { handler ->
            val cancel = handler.indexOf("if (onAutoWatchCancelled())")
            val retire = handler.indexOf("viewModel.clearRandomEpisodePick()")
            assertTrue("Browse must reject stale route callbacks before dispatch", cancel >= 0)
            assertTrue("Browse must retire any pending episode pick after route admission", retire > cancel)
        }
        val shell = source("ui/VortXApp.kt").substringAfter("onAutoWatchCancelled = {")
        val ordinaryCancellation = shell.substringAfter("else if (randomRequestForDetail == null) {")
            .substringBefore("} else {")
        assertTrue("Manual browsing also retires the existing Quick View auto-watch", ordinaryCancellation.contains("quickWatchIdentity = null"))
    }

    private fun source(relative: String): String {
        val prefix = "src/main/kotlin/com/vortx/android/"
        return listOf(File(prefix + relative), File("app/" + prefix + relative), File("android/app/" + prefix + relative))
            .firstOrNull(File::isFile)?.readText() ?: error("Missing source: $relative")
    }
}
