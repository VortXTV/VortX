package com.vortx.android.usenet

import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlin.io.path.createTempDirectory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class UsenetProgressiveSessionTest {
    @Test
    fun `loopback range headers arrive before the requested ordered bytes`() {
        val home = createTempDirectory("usenet-progressive").toFile()
        val file = java.io.File(home, "title.mkv")
        val session = UsenetProgressiveSession(file, declaredBytes = 6)
        try {
            val url = URL(session.url)
            val connection = (url.openConnection() as HttpURLConnection).apply { setRequestProperty("Range", "bytes=2-5") }
            assertEquals(206, connection.responseCode)
            assertEquals("bytes 2-5/6", connection.getHeaderField("Content-Range"))
            assertEquals("bytes", connection.getHeaderField("Accept-Ranges"))
            val body = AtomicReference<ByteArray?>()
            val done = CountDownLatch(1)
            Thread {
                body.set(connection.inputStream.readBytes())
                done.countDown()
            }.start()
            assertFalse("range read must wait for the ordered append frontier", done.await(150, TimeUnit.MILLISECONDS))
            FileOutputStream(file, true).use { it.write("abcdef".toByteArray()) }
            session.appendCommitted(6)
            session.finish()
            assertTrue("range read did not resume after ordered bytes committed", done.await(2, TimeUnit.SECONDS))
            assertEquals("cdef", body.get()!!.toString(Charsets.UTF_8))
        } finally {
            session.close()
            home.deleteRecursively()
        }
    }

    @Test
    fun `HEAD describes the bounded loopback resource without downloading`() {
        val home = createTempDirectory("usenet-progressive").toFile()
        val session = UsenetProgressiveSession(java.io.File(home, "title.mkv"), declaredBytes = 9)
        try {
            val connection = (URL(session.url).openConnection() as HttpURLConnection).apply { requestMethod = "HEAD" }
            assertEquals(200, connection.responseCode)
            assertEquals("9", connection.getHeaderField("Content-Length"))
            assertEquals("bytes", connection.getHeaderField("Accept-Ranges"))
        } finally {
            session.close()
            home.deleteRecursively()
        }
    }
}
