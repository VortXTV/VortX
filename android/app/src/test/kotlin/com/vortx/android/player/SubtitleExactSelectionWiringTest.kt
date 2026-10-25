package com.vortx.android.player

import java.io.File
import org.junit.Assert.*
import org.junit.Test

/** Maintained source joins only. This does not execute Media3, Compose, JNI or a native player. */
class SubtitleExactSelectionWiringTest {
    @Test fun eachConcreteEngineSelectsItsExactFileWithoutScreenCountOrderOrUriSuppression() {
        val screen = source("main", "PlayerScreen.kt")
        assertFalse(screen.contains("mountedAddonSubs"))
        assertFalse(screen.contains("pendingSubSelectAbove"))
        assertFalse(screen.contains("tracks.lastOrNull()?.let { engine.selectSubtitleTrack(it.id) }"))
        assertTrue(screen.contains("engine.addExternalSubtitle(sub.url, original)"))
        val mpv = source("full", "mpv/MpvPlayer.kt")
        assertTrue(mpv.contains("mpv.command(arrayOf(\"sub-add\", local.absolutePath, \"select\"))"))
        assertFalse(mpv.contains("subtitleCommandExecutor"))
        assertFalse(mpv.contains("private fun loadSource("))
    }

    @Test fun media3UsesExactOwnedIdAndExistingUriReselectionPreservesSameSourceRemountIntent() {
        val exo = source("main", "ExoPlayerEngine.kt")
        assertTrue(exo.contains(".setId(sidecarIdentities.idFor(subUrl))"))
        val add = exo.substringAfter("override fun addExternalSubtitle(url: String) {")
            .substringBefore("private fun selectPendingSidecar()")
        assertTrue(add.contains("Looper.myLooper() !== player.applicationLooper"))
        assertTrue(add.contains("if (existing > 1) return"))
        assertTrue(add.contains("if (existing == 1) {"))
        assertTrue(add.contains("selectPendingSidecar()"))
        assertTrue(add.contains("val updated = withAdditionalExternalSubtitle(base, url)"))
        assertTrue(add.contains("load(updated, playWhenReady = intent.playWhenReady, remountPositionMs = intent.positionMs)"))
        assertFalse(add.contains("sidecarIdentities.reset()"))
        val select = exo.substringAfter("private fun selectPendingSidecar() {")
            .substringBefore("internal data class ExoSubtitleRemountIntent")
        assertTrue(select.contains("group.getTrackFormat(trackIndex).id"))
        assertTrue(select.contains("uniqueOwnedSubtitleTrack(pending.formatId, candidates)"))
        assertTrue(select.contains(".setTrackTypeDisabled(C.TRACK_TYPE_TEXT, false)"))
        assertTrue(select.indexOf("pendingSidecar = null") < select.indexOf("player.trackSelectionParameters ="))
        assertFalse(select.contains("lastOrNull()"))
        assertTrue(exo.contains("publish(tracks = player.currentTracks)"))
    }

    @Test fun explicitPrimaryNewLoadAndReleaseClearPendingBeforeNativeLifecycleOrSelection() {
        val exo = source("main", "ExoPlayerEngine.kt")
        val primary = exo.substringAfter("override fun selectSubtitleTrack(id: Int?) {")
            .substringBefore("private fun selectTrack(")
        assertTrue(primary.indexOf("pendingSidecar = null") < primary.indexOf("player.trackSelectionParameters ="))
        val load = exo.substringAfter("override fun load(playable: Playable) {")
            .substringBefore("private fun load(playable: Playable,")
        assertTrue(load.contains("sidecarIdentities.reset()"))
        assertTrue(load.indexOf("pendingSidecar = null") < load.indexOf("load(playable, playWhenReady = true)"))
        val release = exo.substringAfter("override fun release() {").substringBefore("@Composable")
        assertTrue(release.indexOf("subtitleReleased = true") < release.indexOf("player.release()"))
        assertTrue(release.indexOf("pendingSidecar = null") < release.indexOf("player.release()"))
        assertTrue(release.contains("sidecarIdentities.reset()"))
    }

    private fun source(flavor: String, name: String): String {
        val relative = "src/$flavor/kotlin/com/vortx/android/player/$name"
        return listOf(File(relative), File("app/$relative"), File("android/app/$relative"))
            .firstOrNull(File::isFile)?.readText() ?: error("Could not find actual $relative")
    }
}
