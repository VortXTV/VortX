package com.vortx.android.player

import java.io.File
import org.junit.Assert.*
import org.junit.Test

/** Real maintained host-source joins, not Android/Compose/Media3/JNI execution. */
class SubtitleOriginalRequestWiringTest {
    @Test fun poolOriginalRequestIsCreatedBeforeIoAndCannotBeRecapturedAtCompletion() {
        val screen = source("main", "PlayerScreen.kt")
        val pool = screen.substringAfter("fun selectPooledSubtitle(")
            .substringBefore("LaunchedEffect(playbackSessionKey)")
        val request = pool.indexOf("val original = engine.beginSubtitleSelection() ?: return")
        val download = pool.indexOf("SubtitlePoolClient.download(")
        assertTrue(request >= 0 && download > request)
        assertEquals(request, pool.lastIndexOf("val original = engine.beginSubtitleSelection() ?: return"))
        assertTrue(pool.contains("engine.isSubtitleSelectionCurrent(original)"))
        assertTrue(pool.contains("sub.lang, \"Community\"), original)"))
        assertTrue(pool.contains("if (poolLoadingSelection === original)"))
        assertTrue(screen.contains("engine.addExternalSubtitle(sub.url, original)"))
        assertFalse(screen.contains("engine.addExternalSubtitle(sub.url)"))
        assertFalse(screen.contains("pendingSubSelectAbove"))
        assertFalse(screen.contains("mountedAddonSubs"))
    }

    @Test fun actualMpvFinalCommandSharesTheExistingSourceManualRetirementGateAfterBoundedIo() {
        val mpv = source("full", "mpv/MpvPlayer.kt")
        val add = mpv.substringAfter("override fun addExternalSubtitle(url: String, request: PlayerSubtitleSelection)")
            .substringBefore("private fun mountExternalSubtitle(")
        assertTrue(add.contains("request.sourceContext as? Long"))
        assertFalse(add.contains("generation = subtitleLoadGeneration.get()"))
        val mount = mpv.substringAfter("private fun mountExternalSubtitle(")
            .substringBefore("private suspend fun boundedSubtitleFile(")
        val fetch = mount.indexOf("boundedSubtitleFile(source)")
        val boundary = mount.indexOf("synchronized(subtitleGenerationGate)")
        val finalOriginal = mount.indexOf("isSubtitleSelectionCurrentLocked(original)")
        val command = mount.indexOf("mpv.command(arrayOf(\"sub-add\", local.absolutePath, \"select\"))")
        assertTrue(fetch >= 0 && boundary > fetch && finalOriginal > boundary && command > finalOriginal)
        assertFalse(mount.contains("beginSubtitleSelection()"))
        assertFalse(mount.contains("cancelChildren()"))
        assertFalse(mount.contains("mpv.destroy()"))
        assertTrue(mpv.contains("mountExternalSubtitle(sub, loadGeneration, initialSubtitleSelection)"))
    }

    @Test fun actualMpvLoadAndReleaseRemainSynchronousAndRetireAuthorityBeforeUnlockAndDestroy() {
        val mpv = source("full", "mpv/MpvPlayer.kt")
        assertFalse(mpv.contains("private fun loadSource("))
        assertFalse(mpv.contains("subtitleCommandExecutor"))
        val load = mpv.substringAfter("override fun load(playable: Playable) {")
            .substringBefore("private fun consumePendingResumeSeek()")
        assertTrue(load.contains("val original = subtitleSelections.beginSource(generation) ?: return"))
        assertTrue(load.contains("generation to original"))
        assertTrue(load.contains("mpv.loadFileWithEntryID(playable.url)"))
        assertTrue(load.contains("subtitleLoadScope.coroutineContext.cancelChildren()"))
        val release = mpv.substringAfter("override fun release() {").substringBefore("override fun")
        val boundary = release.indexOf("synchronized(subtitleGenerationGate)")
        val retire = release.indexOf("subtitleSelections.retire()")
        val cancel = release.indexOf("subtitleLoadScope.cancel()")
        val destroy = release.indexOf("mpv.destroy()")
        assertTrue(boundary >= 0 && retire > boundary && cancel > retire && destroy > cancel)
        assertTrue(release.contains("metadataLoadIdentity.retire()"))
    }

    @Test fun actualMpvManualPrimarySecondaryAndTimingUseOriginalGateNotJustCallerChecks() {
        val mpv = source("full", "mpv/MpvPlayer.kt")
        val primary = mpv.substringAfter("override fun selectSubtitleTrack(id: Int?) {")
            .substringBefore("override fun addExternalSubtitle(url: String)")
        assertTrue(primary.contains("synchronized(subtitleGenerationGate)"))
        assertTrue(primary.contains("subtitleSelections.beginChoice()"))
        val secondary = mpv.substringAfter("override fun setSecondarySubtitleTrack(id: Int?) {")
            .substringBefore("override fun setHardwareDecoding")
        assertTrue(secondary.contains("synchronized(subtitleGenerationGate)"))
        assertTrue(secondary.contains("subtitleSelections.beginChoice()"))
        val timing = mpv.substringAfter("override fun setSubtitleDelay(seconds: Double, request: PlayerSubtitleSelection)")
            .substringBefore("override fun setSecondarySubtitleTrack")
        assertTrue(timing.contains("synchronized(subtitleGenerationGate)"))
        assertTrue(timing.indexOf("isSubtitleSelectionCurrentLocked(request)") <
            timing.indexOf("mpv.setPropertyString(PROP_SUB_DELAY"))
    }

    @Test fun actualMedia3PendingIdRetainsOriginalRequestUntilFinalLooperConfinedOverride() {
        val exo = source("main", "ExoPlayerEngine.kt")
        assertTrue(exo.contains("PendingSidecar(val formatId: String, val original: PlayerSubtitleSelection)"))
        assertTrue(exo.contains("PendingSidecar(sidecarIdentities.idFor(url), request)"))
        val add = exo.substringAfter("override fun addExternalSubtitle(url: String, request: PlayerSubtitleSelection)")
            .substringBefore("private fun selectPendingSidecar()")
        assertTrue(add.contains("if (!isSubtitleSelectionCurrent(request)) return false"))
        assertFalse(add.contains("beginSource"))
        assertFalse(add.contains("beginChoice"))
        val finalMount = exo.substringAfter("private fun selectPendingSidecar() {")
            .substringBefore("internal data class ExoSubtitleRemountIntent")
        assertTrue(finalMount.contains("Looper.myLooper() !== player.applicationLooper"))
        assertTrue(finalMount.indexOf("isSubtitleSelectionCurrent(pending.original)") <
            finalMount.indexOf("uniqueOwnedSubtitleTrack(pending.formatId, candidates)"))
        assertTrue(finalMount.indexOf("pendingSidecar = null") < finalMount.indexOf("player.trackSelectionParameters ="))
        assertTrue(exo.contains("subtitleSelections.retire()"))
    }

    @Test fun automaticDefaultsDoNotCreateChoicesButManualTimingRevokesBeforeFinalPropertyAndMemory() {
        val screen = source("main", "PlayerScreen.kt")
        val automatic = screen.substringAfter("if (defaults.selectSubtitle) {")
            .substringBefore("trackSelectionPhases = trackSelectionPhases.apply(defaults)")
        assertTrue(automatic.contains("engine.captureSubtitleSelection()"))
        assertTrue(automatic.contains("engine.selectSubtitleTrack(subId?.takeIf { it >= 0 }, original)"))
        assertFalse(automatic.contains("beginSubtitleSelection"))
        val manual = screen.substringAfter("onAdjustSubtitleDelay = { delta ->")
            .substringBefore("subtitleStyle = subtitleStyle")
        assertTrue(manual.indexOf("val original = engine.beginSubtitleSelection()") <
            manual.indexOf("engine.setSubtitleDelay(seconds, original)"))
        assertTrue(manual.indexOf("engine.setSubtitleDelay(seconds, original)") <
            manual.indexOf("SubtitleOffsetMemory.save("))
        val community = screen.substringAfter("LaunchedEffect(playbackSessionKey, engine, subtitlePoolQuery, poolThin, poolSignedIn)")
            .substringBefore("fun selectPooledSubtitle(")
        assertTrue(community.indexOf("val original = engine.captureSubtitleSelection()") <
            community.indexOf("SubtitlePoolClient.fetchPooled("))
        assertTrue(community.contains("engine.setSubtitleDelay(seconds, original)"))
    }

    private fun source(flavor: String, name: String): String {
        val relative = "src/$flavor/kotlin/com/vortx/android/player/$name"
        return listOf(File(relative), File("app/$relative"), File("android/app/$relative"))
            .firstOrNull(File::isFile)?.readText() ?: error("Could not find actual $relative")
    }
}
