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
            phone.substringAfter("onOpenTitle = { item ->", "").substringBefore("modifier =") to "titleTarget = item",
            phone.substringAfter("val openRelated: (MetaItem) -> Unit = { item ->", "").substringBefore("// Per-title") to "relatedLookupFence.begin()",
            phone.substringAfter("onPersonTap = { person ->", "").substringBefore("SeasonSelector(") to "personTarget = person",
        )
        handlers.forEach { (handler, navigation) ->
            // Browsing leaves the queued target, unlike manual source selection for that target.
            val cancel = handler.indexOf("if (onQueueInteraction())")
            val retire = handler.indexOf("viewModel.clearRandomEpisodePick()")
            val navigate = handler.indexOf(navigation)
            assertTrue("Browse must reject stale route callbacks before dispatch", cancel >= 0)
            assertTrue("Browse must retire any pending episode pick after route admission", retire > cancel)
            assertTrue("Browse must retire its pending pick before navigation", navigate > retire)
        }
        assertTrue("Unspecified queue callbacks retain manual cancellation", phone.contains(
            "onQueueInteraction: () -> Boolean = onAutoWatchCancelled,",
        ))
        val shell = source("ui/VortXApp.kt").substringAfter("onQueueInteraction = {", "")
            .substringBefore("onQueueAdd = {")
        val rejection = shell.substringBefore("} else {")
        assertTrue(rejection.contains("val request = randomRequestForDetail"))
        assertTrue(rejection.contains("val owner = queueOwner"))
        assertTrue(rejection.contains("!randomDetailRouteIsCurrent()"))
        assertTrue(rejection.contains("queueTokenForDetail != null && (owner == null || !queueOwnerIsSelected(owner))"))
        assertTrue(rejection.contains("request != null && !request.sameIntent(pendingRandomTitlePlayRequest)"))
        assertTrue("A stale browse callback must fail closed", rejection.contains("false"))
        assertFalse("A stale callback must not retire a successor", rejection.contains("pendingRandomTitlePlayRequest =") ||
            rejection.contains("pendingQueueToken =") || rejection.contains("quickWatchIdentity ="))
        val accepted = shell.substringAfter("} else {", "")
        val admission = accepted.indexOf("val admitted = request == null || randomTitlePlayIsCurrent()")
        val routeCall = "detailVm.abandonPlaybackRoute(preserveRandomEpisodePick = true)"
        val routeRetirement = accepted.indexOf(routeCall)
        assertFalse("Ordinary Quick View must retire its running resolver too",
            accepted.contains("if (request != null) detailVm.abandonPlaybackRoute"))
        assertTrue("Browse must retain its original request admission", admission >= 0)
        listOf("pendingRandomTitlePlayRequest = null", "pendingQueueToken = null",
            "pendingQueueAccepted = false", "pendingQueueAutomatic = false", "quickWatchIdentity = null").forEach { cleanup ->
            val retirement = accepted.indexOf(cleanup)
            assertTrue("Browse must retire $cleanup after original admission", retirement > admission)
            assertTrue("Browse must clear queue and Quick View state before abandoning playback", routeRetirement > retirement)
        }
        assertTrue("Browse must return its captured admission after retiring playback",
            accepted.indexOf("admitted", routeRetirement + routeCall.length) > routeRetirement)
        val vm = source("ui/viewmodel/DetailViewModel.kt")
        val ordinary = vm.substringAfter("fun abandonPlaybackRoute() {", "")
            .substringBefore("internal fun abandonPlaybackRoute(preserveRandomEpisodePick: Boolean)")
        assertTrue("Existing no-argument callers still invalidate their preview",
            ordinary.contains("abandonPlaybackRoute(preserveRandomEpisodePick = false)"))
        val abandonment = vm.substringAfter("internal fun abandonPlaybackRoute(preserveRandomEpisodePick: Boolean) {", "")
            .substringBefore("private fun canPublishPlaybackResolve")
        assertTrue("Preserving the next explicit preview still retires old random playback",
            abandonment.contains("if (preserveRandomEpisodePick) retireRandomEpisodePlayback() else clearRandomEpisodePick()"))
        listOf("pendingAutoPick = false", "pendingAdvanceHint = null", "resetPlaybackAudioIntent()",
            "abandonPlaybackResolve()", "episodeBudgetJob?.cancel()", "automaticEpisodeBudget = null").forEach { cleanup ->
            assertTrue("Every abandonment must retain $cleanup", abandonment.contains(cleanup))
        }
        val pendingReady = abandonment.indexOf("val abandonedReady = _playback.value as? Playback.Ready")
        val idle = abandonment.indexOf("_playback.value = Playback.Idle")
        val close = abandonment.indexOf("abandonedReady?.playable?.playbackLease?.close()")
        assertTrue("Only the currently pending Ready is captured", pendingReady >= 0)
        assertTrue("The old Ready cannot launch behind an overlay", idle > pendingReady)
        assertTrue("A discarded, unhanded Ready releases its progressive producer", close > idle)
        assertFalse("Browse keeps metadata/source loading available", abandonment.contains("sourceLoadJob?.cancel()"))
        val tvShell = source("ui/tv/TvApp.kt").substringAfter("onQueueInteraction = {", "")
            .substringBefore("queueCount =")
        val tvAdmission = tvShell.substringBefore("if (admitted) {")
        assertTrue(tvAdmission.contains("val request = libraryPlayRequest"))
        assertTrue(tvAdmission.contains("detailGeneration == routeGeneration"))
        assertTrue(tvAdmission.contains("detail?.type == current.type && detail?.id == current.id"))
        assertTrue(tvAdmission.contains("request.sameIntent(pendingLibraryPlay) && isLibraryPlayCurrent(request)"))
        assertTrue(tvAdmission.contains("pendingQueuePlay === queuePlayRequest &&"))
        assertTrue(tvAdmission.contains("queueOwnerIsSelected(currentQueueOwner)"))
        assertFalse("Rejected TV callbacks must not retire a successor",
            Regex("""\b(?:pendingQueuePlay|pendingLibraryPlay)\s*=(?!=)""").containsMatchIn(tvAdmission))
        val tvAccepted = tvShell.substringAfter("if (admitted) {", "")
        val tvRetirement = tvAccepted.indexOf(routeCall)
        listOf("pendingQueuePlay = null", "pendingQueueAccepted = false", "pendingQueueAutomatic = false",
            "pendingLibraryPlay = null").forEach { cleanup ->
            assertTrue("Admitted TV browsing must clear $cleanup before retiring its resolver",
                tvAccepted.indexOf(cleanup) >= 0 && tvAccepted.indexOf(cleanup) < tvRetirement)
        }
        assertTrue("TV also preserves its admitted episode preview while retiring playback", tvRetirement >= 0)
    }

    private fun source(relative: String): String {
        val prefix = "src/main/kotlin/com/vortx/android/"
        return listOf(File(prefix + relative), File("app/" + prefix + relative), File("android/app/" + prefix + relative))
            .firstOrNull(File::isFile)?.readText() ?: error("Missing source: $relative")
    }
}
