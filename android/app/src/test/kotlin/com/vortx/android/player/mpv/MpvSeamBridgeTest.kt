package com.vortx.android.player.mpv

import com.vortx.android.player.mpv.seam.MpvSeam
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.lang.reflect.Modifier

/// Drives the REAL production bridge ([MpvSeamBridge] -- the object registered with the native event
/// loop) with raw seam callbacks and asserts the exact VortX-contract translation. This is the
/// "actual callback mapping" half of the W1-B seam tests: raw (reason, error) ints in, typed terminal
/// events out, no native handle involved.
class MpvSeamBridgeTest {
    /// Records every contract callback in delivery order.
    private class RecordingObserver : MPVLib.EventObserver {
        val properties = mutableListOf<Pair<String, Any?>>()
        val terminals = mutableListOf<MpvTerminalEvent>()
        val rawEvents = mutableListOf<Int>()

        override fun eventProperty(name: String) {
            properties += name to null
        }
        override fun eventProperty(name: String, value: Long) {
            properties += name to value
        }
        override fun eventProperty(name: String, value: Double) {
            properties += name to value
        }
        override fun eventProperty(name: String, value: Boolean) {
            properties += name to value
        }
        override fun eventProperty(name: String, value: String) {
            properties += name to value
        }
        override fun eventTerminal(event: MpvTerminalEvent) {
            terminals += event
        }
        override fun event(id: Int) {
            rawEvents += id
        }
    }

    private fun bridgeWith(observer: RecordingObserver): MpvSeamBridge =
        MpvSeamBridge { listOf(observer) }

    @Test
    fun `end file payloads map to typed terminal callbacks`() {
        val observer = RecordingObserver()
        val bridge = bridgeWith(observer)

        bridge.eventEndFile(MpvSeam.MpvEndFileReason.EOF, 0)
        bridge.eventEndFile(MpvSeam.MpvEndFileReason.STOP, 0)
        bridge.eventEndFile(MpvSeam.MpvEndFileReason.QUIT, 0)
        bridge.eventEndFile(MpvSeam.MpvEndFileReason.ERROR, -13)
        bridge.eventEndFile(MpvSeam.MpvEndFileReason.REDIRECT, 0)
        // An undefined future reason code must arrive as UNKNOWN, unchanged by the bridge.
        bridge.eventEndFile(99, -7)

        assertEquals(
            listOf(
                MpvTerminalReason.EOF,
                MpvTerminalReason.STOP,
                MpvTerminalReason.QUIT,
                MpvTerminalReason.ERROR,
                MpvTerminalReason.REDIRECT,
                MpvTerminalReason.UNKNOWN,
            ),
            observer.terminals.map { it.reason },
        )
        assertEquals(-13, observer.terminals[3].nativeError)
        assertNull(observer.terminals[0].nativeError)
        assertNull(observer.terminals[5].nativeError)
        assertTrue("END_FILE must not also surface as a raw event", MPVLib.Event.END_FILE !in observer.rawEvents)
    }

    @Test
    fun `non terminal lifecycle events keep their raw ids`() {
        val observer = RecordingObserver()
        val bridge = bridgeWith(observer)

        bridge.event(MPVLib.Event.START_FILE)
        bridge.event(MPVLib.Event.PLAYBACK_RESTART)
        bridge.event(MPVLib.Event.FILE_LOADED)

        assertEquals(
            listOf(MPVLib.Event.START_FILE, MPVLib.Event.PLAYBACK_RESTART, MPVLib.Event.FILE_LOADED),
            observer.rawEvents,
        )
        assertTrue(observer.terminals.isEmpty())
    }

    @Test
    fun `property updates fan out per format overload`() {
        val observer = RecordingObserver()
        val bridge = bridgeWith(observer)

        bridge.eventProperty("track-list")
        bridge.eventProperty("time-pos", 1.5)
        bridge.eventProperty("pause", true)
        bridge.eventProperty("chapter-list/count", 3L)
        bridge.eventProperty("video-codec", "h264")

        assertEquals(
            listOf<Pair<String, Any?>>(
                "track-list" to null,
                "time-pos" to 1.5,
                "pause" to true,
                "chapter-list/count" to 3L,
                "video-codec" to "h264",
            ),
            observer.properties,
        )
    }

    @Test
    fun `every registered observer receives each callback`() {
        val a = RecordingObserver()
        val b = RecordingObserver()
        val bridge = MpvSeamBridge { listOf(a, b) }

        bridge.eventEndFile(4, -13)
        bridge.event(MPVLib.Event.START_FILE)

        assertEquals(listOf(MpvTerminalReason.ERROR), a.terminals.map { it.reason })
        assertEquals(-13, a.terminals[0].nativeError)
        assertEquals(a.terminals, b.terminals)
        assertEquals(a.rawEvents, b.rawEvents)
    }

    @Test
    fun `observers removed from the sink stop receiving callbacks`() {
        val a = RecordingObserver()
        var registered = listOf<RecordingObserver>(a)
        val bridge = MpvSeamBridge { registered }

        bridge.eventEndFile(0, 0)
        registered = emptyList() // mirrors removeObserver before destroy
        bridge.eventEndFile(4, -13)

        assertEquals(1, a.terminals.size)
        assertEquals(MpvTerminalReason.EOF, a.terminals[0].reason)
    }

    @Test
    fun `seam dispatchers keep the names and signatures the native side resolves`() {
        // libvortx_mpv_seam.so binds every dispatcher by NAME + DESCRIPTOR through GetMethodID
        // (jni_utils.cpp); a rename or signature change would surface only as NoSuchMethodError on a
        // device. Pin the exact native lookup contract here so it can never drift silently.
        // Class.forName(..., initialize = false) loads the class WITHOUT running its companion's
        // System.loadLibrary, keeping this a pure JVM test.
        val seamClass = Class.forName(
            "com.vortx.android.player.mpv.seam.MpvSeam",
            false,
            MpvSeam::class.java.classLoader,
        )
        val stringKlass = String::class.java
        val intPrim = Integer.TYPE
        val nativeLookups = listOf(
            Triple("event", arrayOf<Any>(intPrim), "(I)V"),
            Triple("eventEndFile", arrayOf<Any>(intPrim, intPrim), "(II)V"),
            Triple("eventProperty", arrayOf<Any>(stringKlass), "(Ljava/lang/String;)V"),
            Triple("eventProperty", arrayOf<Any>(stringKlass, java.lang.Boolean.TYPE), "(Ljava/lang/String;Z)V"),
            Triple("eventProperty", arrayOf<Any>(stringKlass, java.lang.Long.TYPE), "(Ljava/lang/String;J)V"),
            Triple("eventProperty", arrayOf<Any>(stringKlass, java.lang.Double.TYPE), "(Ljava/lang/String;D)V"),
            Triple("eventProperty", arrayOf<Any>(stringKlass, stringKlass), "(Ljava/lang/String;Ljava/lang/String;)V"),
            Triple("logMessage", arrayOf<Any>(stringKlass, intPrim, stringKlass), "(Ljava/lang/String;ILjava/lang/String;)V"),
        )
        for ((name, params, descriptor) in nativeLookups) {
            val method = seamClass.getDeclaredMethod(name, *params.map { it as Class<*> }.toTypedArray())
            assertTrue(
                "$name$descriptor must stay public: the native event thread resolves it reflectively",
                Modifier.isPublic(method.modifiers),
            )
            assertEquals("$name$descriptor must return void", Void.TYPE, method.returnType)
        }
    }
}
