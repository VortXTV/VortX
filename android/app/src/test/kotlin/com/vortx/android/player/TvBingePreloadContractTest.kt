package com.vortx.android.player

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Integration contracts complement the executable preload-policy and task-owner regressions. */
class TvBingePreloadContractTest {
    @Test
    fun `TV wires preload natural end and binge boundary rather than exit defaults`() {
        val app = source("ui/tv/TvApp.kt")
        val player = app.substringAfter("PlayerScreen(").substringBefore("return@VortXTheme")
        for (hook in listOf("onWarmNext =", "onEnded =", "autoAdvanceCount =", "onBingePrompted =")) {
            assertTrue("Missing TV hook: $hook", player.contains(hook))
        }
        assertTrue(player.contains("preloadPolicy.evaluate("))
        assertTrue(player.contains("preloadTaskOwner.launch("))
        assertTrue(player.contains("vm.warmNextEpisode(next.id)"))
        assertTrue(player.contains("preloadPolicy.complete(attempt"))
        assertTrue(player.contains("historyIdentity.acceptedRevision"))
        assertTrue(player.contains("episodeHandoffRequest = PlayerEpisodeHandoffRequest("))
        assertTrue(player.contains("automatic = true"))
        assertTrue(player.contains("autoAdvanceStreak[0] = if (automatic) autoAdvanceStreak[0] + 1 else 0"))
        assertTrue(player.contains("!advancingEpisode"))
    }

    @Test
    fun `TV warm and advance ownership retire on back error and replacement`() {
        val app = source("ui/tv/TvApp.kt")
        assertTrue(app.contains("remember(historyIdentity, playerOwnerKey)"))
        assertTrue(app.contains("activeProfile?.id}:\$detailSourceEpoch"))
        assertTrue(app.contains("val launchedPlayerPrincipal = remember(playable) { currentPlayerPrincipal }"))
        assertTrue(app.contains("val launchedPlayerViewModel = remember(playable) { playerVm }"))
        assertTrue(app.contains("launchedPlayerViewModel !== playerVm && (advancingEpisode || retryingSource)"))
        assertTrue(app.contains("DisposableEffect(historyIdentity, playerOwnerKey)"))
        assertTrue(app.contains("onDispose { cancelPreload() }"))
        val exit = app.substringAfter("fun exitPlayer() {").substringBefore("LaunchedEffect(")
        assertTrue(exit.contains("cancelPreload()"))
        assertTrue(exit.contains("advancingEpisode = false"))
        assertTrue(exit.contains("retryingSource = false"))
        assertTrue(exit.contains("returnToBrowse()"))
        assertTrue(app.contains("playerVm?.abandonPlaybackRoute()"))
        assertTrue(app.contains("takeIf { it === launchedPlayerViewModel && !retryingSource }"))
        assertTrue(app.contains("if (advancingEpisode || retryingSource) return@onWarmNext"))
        assertTrue(app.contains("BackHandler(onBack = ::exitPlayer)"))
        assertTrue(app.contains("onBack = ::exitPlayer"))
        assertTrue(app.contains("onError = ::exitPlayer"))
        assertFalse(app.contains("LaunchedEffect(advancingEpisode, retryPlayback)"))
        val advance = app.substringAfter("onSwitchEpisode =").substringBefore("episodeHandoffRequest =")
        assertTrue(advance.contains("launchedPlayerPrincipal == currentPlayerPrincipal"))
        assertTrue(advance.contains("vm.resolveEpisodeSwitch(episodeId)"))
        assertFalse(advance.contains("exitPlayer()"))
    }

    @Test
    fun `both hosts cancel source warm scheduling before and after manual resolve`() {
        for (path in listOf("ui/tv/TvApp.kt", "ui/VortXApp.kt")) {
            val app = source(path)
            val manual = app.substringAfter("onSwitchSource =").substringBefore("onSwitchEpisode =")
            assertTrue(manual.contains("finally"))
            assertTrue(manual.contains("vm.resolveSourceSwitch(source)"))
            assertTrue(manual.contains("cancelPreload()") || manual.contains("preloadTaskOwner.cancel()"))
        }
    }

    @Test
    fun `only accepted manual source clears published next episode warm choice`() {
        val vm = source("ui/viewmodel/DetailViewModel.kt")
        val resolver = vm.substringAfter("suspend fun resolveSourceSwitch(")
            .substringBefore("suspend fun resolveEpisodeSwitch(")
        assertFalse(resolver.substringBefore("commitAccepted =").contains("invalidateWarmNextSource()"))
        val commit = resolver.substringAfter("commitAccepted = {")
        assertTrue(commit.contains("invalidateWarmNextSource()"))
        assertTrue(commit.indexOf("invalidateWarmNextSource()") < commit.indexOf("lastPlayedSource = source"))
        assertTrue(commit.contains("sourceSticky.record(it, source.addon, source.bingeGroup)"))
    }

    @Test
    fun `route abandonment clears queued auto intent without weakening source target replacement`() {
        val vm = source("ui/viewmodel/DetailViewModel.kt")
        val abandoned = vm.substringAfter("fun abandonPlaybackRoute() {").substringBefore("private fun canPublishPlaybackResolve")
        assertTrue(abandoned.contains("pendingAutoPick = false"))
        assertTrue(abandoned.contains("pendingAdvanceHint = null"))
        assertTrue(abandoned.contains("abandonPlaybackResolve()"))
        assertTrue(abandoned.contains("_playback.value = Playback.Idle"))
        val internal = vm.substringAfter("private fun cancelPlaybackResolveForSourceTargetInvalidation() {")
            .substringBefore("fun abandonPlaybackResolve()")
        assertFalse(internal.contains("abandonPlaybackRoute()"))
        assertTrue(vm.contains("autoPickIntent.consume(update.selectionReady)"))
        assertTrue(vm.contains("if (!autoPickIntent.accepts(autoPickLease)) return@collect"))
    }

    private fun source(path: String): String {
        val relative = "src/main/kotlin/com/vortx/android/$path"
        return listOf(File(relative), File("app/$relative"), File("android/app/$relative"))
            .firstOrNull(File::isFile)?.readText() ?: error("Missing $relative")
    }
}
