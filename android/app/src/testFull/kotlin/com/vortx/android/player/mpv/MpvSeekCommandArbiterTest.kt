package com.vortx.android.player.mpv

import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class MpvSeekCommandArbiterTest {
    @Test fun `actual player load warm and explicit seeks use the recorded command boundary`() {
        val relative = "src/full/kotlin/com/vortx/android/player/mpv/MpvPlayer.kt"
        val player = listOf(File(relative), File("app/$relative"), File("android/app/$relative"))
            .first(File::isFile).readText()
        assertTrue(player.contains("MpvSeekCommandArbiter(mpv::command)"))
        assertTrue(player.contains("seekCommands.load(seekLoad, playable.url, playable.startPositionMs)"))
        assertTrue(player.contains("seekCommands.onWarm()"))
        assertTrue(player.contains("seekCommands.seekTo(positionMs)"))
        assertTrue(player.contains("seekCommands.seekBy(deltaMs)"))
        val load = player.substringAfter("override fun load(playable: Playable)").substringBefore("private fun consumePendingResumeSeek")
        assertTrue(load.indexOf("seekCommands.beginLoad {") < load.indexOf("streamHttpPropertyWrites(playable)"))
        assertTrue(load.substringAfter("seekCommands.beginLoad {").substringBefore("} ?: return").contains("terminalGate.beginReplacementLoad()"))
        assertTrue(player.contains("seekCommands.onTerminal(retiresLoad = event.reason != MpvTerminalReason.REDIRECT) {\n                terminalGate.onTerminal(event)"))
        val release = player.substringAfter("override fun release()")
        assertTrue(release.indexOf("seekCommands.release()") < release.indexOf("mpv.destroy()"))
        assertTrue(player.contains("MPVLib.Event.START_FILE -> terminalGate.onSourceStarted()"))
    }

    @Test fun `explicit zero seek retires automatic resume before the first frame`() {
        val commands = mutableListOf<List<String>>()
        val subject = MpvSeekCommandArbiter({ commands += it.toList() }, { 3_600_000L })
        subject.load("fixture-a", 120_000L)
        subject.seekTo(0L)
        subject.onWarm()
        subject.onWarm()
        assertEquals(listOf(listOf("loadfile", "fixture-a", "replace"), listOf("seek", "0.0", "absolute")), commands)
    }

    @Test fun `explicit relative rewind retires automatic resume`() {
        val commands = mutableListOf<List<String>>()
        val subject = MpvSeekCommandArbiter({ commands += it.toList() }, { 3_600_000L })
        subject.load("fixture-a", 120_000L)
        subject.seekBy(-10_000L)
        subject.onWarm()
        assertEquals(listOf(listOf("loadfile", "fixture-a", "replace"), listOf("seek", "-10.0", "relative")), commands)
    }

    @Test fun `resume is armed when loadfile synchronously admits its first warm callback`() {
        val commands = mutableListOf<List<String>>()
        lateinit var subject: MpvSeekCommandArbiter
        subject = MpvSeekCommandArbiter({
            commands += it.toList()
            if (it[0] == "loadfile") subject.onWarm()
        }, { 3_600_000L })
        subject.load("fixture-a", 120_000L)
        assertEquals(listOf(listOf("loadfile", "fixture-a", "replace"), listOf("seek", "120.0", "absolute")), commands)
    }

    @Test fun `ordinary warm resume is one shot and keeps existing floor and tail bounds`() {
        for ((target, duration, expected) in listOf(
            Triple(5_000L, 60_000L, emptyList()),
            Triple(5_001L, 60_000L, listOf(listOf("seek", "5.001", "absolute"))),
            Triple(50_000L, 60_000L, emptyList()),
            Triple(49_999L, 60_000L, listOf(listOf("seek", "49.999", "absolute"))),
            Triple(120_000L, 0L, listOf(listOf("seek", "120.0", "absolute"))),
        )) {
            val commands = mutableListOf<List<String>>()
            val subject = MpvSeekCommandArbiter({ commands += it.toList() }, { duration })
            subject.load("fixture-a", target)
            commands.clear()
            subject.onWarm()
            subject.onWarm()
            assertEquals("target=$target duration=$duration", expected, commands)
        }
    }

    @Test fun `load entry retires old resume before setup and reused callbacks cannot rearm it`() {
        val commands = mutableListOf<List<String>>()
        val subject = MpvSeekCommandArbiter({ commands += it.toList() }, { 3_600_000L })
        val terminal = MpvTerminalGate { _, _, _, _ -> }
        subject.load("fixture-a", 120_000L)
        for (name in listOf("fixture-b", "fixture-c")) {
            val ticket = requireNotNull(subject.beginLoad())
            terminal.beginReplacementLoad()
            // A queued old START_FILE closes the existing terminal window, but proves no seek authority.
            terminal.onSourceStarted()
            subject.onWarm() // during setup, before the next loadfile
            assertTrue(subject.load(ticket, name, 240_000L))
            terminal.onSourceStarted()
            subject.onWarm()
        }
        subject.seekTo(0L)
        subject.seekBy(10_000L)
        subject.onWarm()
        assertEquals(listOf(
            listOf("loadfile", "fixture-a", "replace"),
            listOf("loadfile", "fixture-b", "replace"),
            listOf("loadfile", "fixture-c", "replace"),
            listOf("seek", "0.0", "absolute"), listOf("seek", "10.0", "relative"),
        ), commands)
    }

    @Test fun `manual seek during first load preparation prevents later automatic arming`() {
        val commands = mutableListOf<List<String>>()
        val subject = MpvSeekCommandArbiter({ commands += it.toList() }, { 0L })
        val ticket = requireNotNull(subject.beginLoad())
        subject.seekTo(0L)
        assertTrue(subject.load(ticket, "fixture-a", 120_000L))
        subject.onWarm()
        assertEquals(listOf(listOf("seek", "0.0", "absolute"), listOf("loadfile", "fixture-a", "replace")), commands)
    }

    @Test fun `ticket replacement and actual terminal reset exclude an old terminal in their boundary`() {
        val commands = mutableListOf<List<String>>()
        val subject = MpvSeekCommandArbiter({ commands += it.toList() }, { 0L })
        val terminal = MpvTerminalGate { _, _, _, _ -> }
        val first = requireNotNull(subject.beginLoad { terminal.beginFirstLoad() })
        assertTrue(subject.load(first, "fixture-a", 120_000L))
        val enteredReset = CountDownLatch(1)
        val finishReset = CountDownLatch(1)
        val oldTerminalStarted = CountDownLatch(1)
        val oldTerminalDone = CountDownLatch(1)
        val executor = Executors.newFixedThreadPool(2)
        try {
            val replacement = executor.submit<MpvSeekCommandArbiter.Load?> {
                subject.beginLoad {
                    enteredReset.countDown()
                    assertTrue(finishReset.await(5, TimeUnit.SECONDS))
                    terminal.beginReplacementLoad()
                }
            }
            assertTrue(enteredReset.await(5, TimeUnit.SECONDS))
            val oldTerminal = executor.submit<MpvTerminalState?> {
                oldTerminalStarted.countDown()
                subject.onTerminal { terminal.onTerminal(MpvTerminalEvent(MpvTerminalReason.ERROR, -13)) }
                    .also { oldTerminalDone.countDown() }
            }
            assertTrue(oldTerminalStarted.await(5, TimeUnit.SECONDS))
            assertFalse(oldTerminalDone.await(100, TimeUnit.MILLISECONDS))
            finishReset.countDown()
            val second = requireNotNull(replacement.get(5, TimeUnit.SECONDS))
            assertNull(oldTerminal.get(5, TimeUnit.SECONDS))
            assertTrue(subject.load(second, "fixture-b", 240_000L))
            terminal.onSourceStarted()
            subject.onWarm()
            assertEquals(listOf(listOf("loadfile", "fixture-a", "replace"), listOf("loadfile", "fixture-b", "replace")), commands)
        } finally {
            finishReset.countDown()
            executor.shutdownNow()
            assertTrue(executor.awaitTermination(5, TimeUnit.SECONDS))
        }
    }

    @Test fun `reentrant manual command from loadfile is not overwritten on return`() {
        val commands = mutableListOf<List<String>>()
        lateinit var subject: MpvSeekCommandArbiter
        subject = MpvSeekCommandArbiter({
            commands += it.toList()
            if (it[0] == "loadfile") subject.seekTo(0L)
        }, { 0L })
        subject.load("fixture-a", 120_000L)
        subject.onWarm()
        assertEquals(listOf(listOf("loadfile", "fixture-a", "replace"), listOf("seek", "0.0", "absolute")), commands)
    }

    @Test fun `reentrant release from loadfile prevents every later command`() {
        val commands = mutableListOf<List<String>>()
        lateinit var subject: MpvSeekCommandArbiter
        subject = MpvSeekCommandArbiter({
            commands += it.toList()
            subject.release()
        }, { 0L })
        val ticket = requireNotNull(subject.beginLoad())
        assertFalse(subject.load(ticket, "fixture-a", 120_000L))
        subject.onWarm()
        subject.seekTo(0L)
        subject.seekBy(10_000L)
        assertNull(subject.beginLoad())
        assertFalse(subject.commandForLoad(ticket, arrayOf("unexpected")))
        assertFalse(subject.load(ticket, "fixture-b", 120_000L))
        assertEquals(listOf(listOf("loadfile", "fixture-a", "replace")), commands)
    }

    @Test fun `reentrant load replacement cannot restore original pending resume`() {
        val commands = mutableListOf<List<String>>()
        lateinit var subject: MpvSeekCommandArbiter
        subject = MpvSeekCommandArbiter({
            commands += it.toList()
            if (it.contentEquals(arrayOf("loadfile", "fixture-a", "replace"))) subject.load("fixture-b", 240_000L)
        }, { 0L })
        val ticket = requireNotNull(subject.beginLoad())
        assertFalse(subject.load(ticket, "fixture-a", 120_000L))
        subject.onWarm()
        assertEquals(listOf(listOf("loadfile", "fixture-a", "replace"), listOf("loadfile", "fixture-b", "replace")), commands)
    }

    @Test fun `stale or released preparation cannot dispatch audio setup or loadfile`() {
        val commands = mutableListOf<List<String>>()
        val subject = MpvSeekCommandArbiter({ commands += it.toList() }, { 0L })
        val first = requireNotNull(subject.beginLoad())
        val second = requireNotNull(subject.beginLoad())
        assertFalse(subject.commandForLoad(first, arrayOf("unexpected")))
        assertFalse(subject.load(first, "fixture-a", 120_000L))
        subject.release()
        assertFalse(subject.commandForLoad(second, arrayOf("unexpected")))
        assertFalse(subject.load(second, "fixture-b", 120_000L))
        assertTrue(commands.isEmpty())
    }

    @Test fun `failed load or audio setup clears automatic authority without retry`() {
        for (failSetup in listOf(false, true)) {
            val commands = mutableListOf<List<String>>()
            val subject = MpvSeekCommandArbiter({
                commands += it.toList()
                throw IllegalStateException("synthetic command failure")
            }, { 0L })
            val ticket = requireNotNull(subject.beginLoad())
            assertThrows(IllegalStateException::class.java) {
                if (failSetup) subject.commandForLoad(ticket, arrayOf("change-list", "audio-files", "clr", ""))
                else subject.load(ticket, "fixture-a", 120_000L)
            }
            subject.onWarm()
            assertFalse(subject.load(ticket, "fixture-a", 120_000L))
            assertEquals(1, commands.size)
        }
    }

    @Test fun `only accepted terminal retires pending resume and load dispatch`() {
        val commands = mutableListOf<List<String>>()
        val subject = MpvSeekCommandArbiter({ commands += it.toList() }, { 0L })
        val terminal = MpvTerminalGate { _, _, _, _ -> }
        val ticket = requireNotNull(subject.beginLoad())
        terminal.beginFirstLoad()
        assertNull(subject.onTerminal<Any> { null })
        assertTrue(subject.load(ticket, "fixture-a", 120_000L))
        assertNotNull(subject.onTerminal { terminal.onTerminal(MpvTerminalEvent(MpvTerminalReason.ERROR, -13)) })
        subject.onWarm()
        assertFalse(subject.load(ticket, "fixture-a", 120_000L))
        assertEquals(listOf(listOf("loadfile", "fixture-a", "replace")), commands)
    }

    @Test fun `fresh source redirect and its START_FILE retain normal first warm resume`() {
        val commands = mutableListOf<List<String>>()
        val subject = MpvSeekCommandArbiter({ commands += it.toList() }, { 0L })
        val terminal = MpvTerminalGate { _, _, _, _ -> }
        terminal.beginFirstLoad()
        subject.load("fixture-a", 120_000L)
        assertNotNull(subject.onTerminal(retiresLoad = false) { terminal.onTerminal(MpvTerminalEvent(MpvTerminalReason.REDIRECT)) })
        terminal.onSourceStarted()
        subject.onWarm()
        assertEquals(listOf(listOf("loadfile", "fixture-a", "replace"), listOf("seek", "120.0", "absolute")), commands)
    }

    @Test fun `reentrant terminal during loadfile does not leave an automatic seek`() {
        val commands = mutableListOf<List<String>>()
        lateinit var subject: MpvSeekCommandArbiter
        subject = MpvSeekCommandArbiter({
            commands += it.toList()
            subject.onTerminal { Unit }
        }, { 0L })
        assertFalse(subject.load("fixture-a", 120_000L))
        subject.onWarm()
        assertEquals(listOf(listOf("loadfile", "fixture-a", "replace")), commands)
    }

    @Test fun `reentrant state read cannot dispatch captured target after manual release or replacement`() {
        for (action in listOf<(MpvSeekCommandArbiter) -> Unit>({ it.seekTo(0L) }, { it.release() }, { it.beginLoad() })) {
            val commands = mutableListOf<List<String>>()
            lateinit var subject: MpvSeekCommandArbiter
            subject = MpvSeekCommandArbiter({ commands += it.toList() }, { action(subject); 0L })
            subject.load("fixture-a", 120_000L)
            subject.onWarm()
            assertFalse(commands.contains(listOf("seek", "120.0", "absolute")))
        }
    }

    @Test fun `automatic native dispatch and racing manual seek have a total command order`() {
        val entered = CountDownLatch(1)
        val finishCommand = CountDownLatch(1)
        val manualStarted = CountDownLatch(1)
        val manualDone = CountDownLatch(1)
        val commands = mutableListOf<List<String>>()
        val subject = MpvSeekCommandArbiter({
            if (it.contentEquals(arrayOf("seek", "120.0", "absolute"))) {
                entered.countDown()
                assertTrue(finishCommand.await(5, TimeUnit.SECONDS))
            }
            commands += it.toList()
        }, { 0L })
        val executor = Executors.newFixedThreadPool(2)
        try {
            subject.load("fixture-a", 120_000L)
            val warm = executor.submit { subject.onWarm() }
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            val manual = executor.submit { manualStarted.countDown(); subject.seekTo(0L); manualDone.countDown() }
            assertTrue(manualStarted.await(5, TimeUnit.SECONDS))
            assertFalse("manual cannot complete ahead of an in-flight automatic dispatch", manualDone.await(100, TimeUnit.MILLISECONDS))
            finishCommand.countDown()
            warm.get(5, TimeUnit.SECONDS)
            manual.get(5, TimeUnit.SECONDS)
            subject.onWarm()
            assertEquals(listOf(listOf("loadfile", "fixture-a", "replace"), listOf("seek", "120.0", "absolute"), listOf("seek", "0.0", "absolute")), commands)
        } finally {
            finishCommand.countDown()
            executor.shutdownNow()
            assertTrue(executor.awaitTermination(5, TimeUnit.SECONDS))
        }
    }

    @Test fun `manual native dispatch wins over concurrently arriving warm callback`() {
        val entered = CountDownLatch(1)
        val finishCommand = CountDownLatch(1)
        val commands = mutableListOf<List<String>>()
        val subject = MpvSeekCommandArbiter({
            if (it[0] == "seek") { entered.countDown(); assertTrue(finishCommand.await(5, TimeUnit.SECONDS)) }
            commands += it.toList()
        }, { 0L })
        val executor = Executors.newFixedThreadPool(2)
        try {
            subject.load("fixture-a", 120_000L)
            val manual = executor.submit { subject.seekTo(0L) }
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            val warm = executor.submit { subject.onWarm() }
            finishCommand.countDown()
            manual.get(5, TimeUnit.SECONDS)
            warm.get(5, TimeUnit.SECONDS)
            assertEquals(listOf(listOf("loadfile", "fixture-a", "replace"), listOf("seek", "0.0", "absolute")), commands)
        } finally {
            finishCommand.countDown()
            executor.shutdownNow()
            assertTrue(executor.awaitTermination(5, TimeUnit.SECONDS))
        }
    }

    @Test fun `audio clear and raw sidecar association retain order before file dispatch`() {
        val commands = mutableListOf<List<String>>()
        val subject = MpvSeekCommandArbiter({ commands += it.toList() }, { 0L })
        val ticket = requireNotNull(subject.beginLoad())
        assertTrue(subject.commandForLoad(ticket, arrayOf("change-list", "audio-files", "clr", "")))
        assertTrue(subject.commandForLoad(ticket, arrayOf("change-list", "audio-files", "append", "fixture:audio,one")))
        assertTrue(subject.load(ticket, "fixture-a", 0L))
        assertFalse(subject.commandForLoad(ticket, arrayOf("unexpected")))
        assertEquals(listOf(listOf("change-list", "audio-files", "clr", ""), listOf("change-list", "audio-files", "append", "fixture:audio,one"), listOf("loadfile", "fixture-a", "replace")), commands)
    }

    private fun MpvSeekCommandArbiter.load(url: String, resumeMs: Long): Boolean =
        beginLoad()?.let { load(it, url, resumeMs) } ?: false
}
