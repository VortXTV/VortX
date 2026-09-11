package com.vortx.android.player.mpv

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MpvExternalAudioLoadContractTest {
    @Test
    fun `external audio is cleared and associated before each replacement file`() {
        val source = File("src/full/kotlin/com/vortx/android/player/mpv/MpvPlayer.kt").readText()
        val load = source.substringAfter("override fun load(").substringBefore("override fun play(")
        val clear = load.indexOf("mpv.command(arrayOf(\"change-list\", \"audio-files\", \"clr\", \"\"))")
        val append = load.indexOf("mpv.command(arrayOf(\"change-list\", \"audio-files\", \"append\", audio))")
        val open = load.indexOf("mpv.command(arrayOf(\"loadfile\", playable.url, \"replace\"))")
        assertTrue("clear even when next file has no sidecar", clear >= 0 && clear < load.indexOf("playable.audioUrl?.let"))
        assertTrue("raw URL append precedes asynchronous file initialization", clear < append && append < open)
        assertFalse("no race-prone post-load audio-add", load.contains("arrayOf(\"audio-add\""))
    }
}
