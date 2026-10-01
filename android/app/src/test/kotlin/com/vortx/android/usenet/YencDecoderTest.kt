package com.vortx.android.usenet

import java.io.ByteArrayOutputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/// Pure-JVM tests for [YencDecoder], including a reference round-trip through an ENCODER built from the
/// yEnc v2 spec so any drift between encode and decode fails loudly here instead of corrupting playback.
class YencDecoderTest {

    /// Reference encoder per the yEnc draft: encoded = (byte + 42) mod 256; values colliding with
    /// NUL/LF/CR/'=' are escaped as '=' followed by (encodedValue + 64) mod 256.
    private fun encode(bytes: ByteArray): String {
        val builder = StringBuilder()
        for (byte in bytes) {
            var encoded = (byte.toInt() and 0xFF) + 42
            encoded %= 256
            if (encoded == 0x00 || encoded == 0x0A || encoded == 0x0D || encoded == 0x3D) {
                builder.append('=').append(((encoded + 64) % 256).toChar())
            } else {
                builder.append(encoded.toChar())
            }
        }
        return builder.toString()
    }

    private fun wrapBody(payload: ByteArray, declaredSize: Int? = null): String =
        "=ybegin line=128 size=${payload.size} name=test.mkv\r\n" +
            "=ypart begin=1 end=${payload.size}\r\n" +
            encode(payload) + "\r\n" +
            "=yend size=" + (declaredSize ?: payload.size) + "\r\n"

    @Test
    fun `round-trips every byte value including all escape collisions`() {
        // All 256 byte values: exercises NUL, LF, CR, '=' escapes AND high/wrap-around bytes.
        val allBytes = ByteArray(256) { it.toByte() }
        val decoded = decode(wrapBody(allBytes))
        assertArrayEqualsBytes(allBytes, decoded)
    }

    @Test
    fun `decodes plain unescaped payload`() {
        val payload = "Hello VortX usenet!".toByteArray(Charsets.ISO_8859_1)
        val decoded = decode(wrapBody(payload))
        assertArrayEqualsBytes(payload, decoded)
    }

    @Test
    fun `size mismatch against yend throws`() {
        val payload = byteArrayOf(1, 2, 3)
        val exception = assertThrows(YencDecoder.DecodeException::class.java) {
            decode(wrapBody(payload, declaredSize = 99))
        }
        assertEquals(true, exception.message!!.contains("size mismatch"))
    }

    @Test
    fun `zero or missing authoritative total is rejected before playback`() {
        assertThrows(YencDecoder.DecodeException::class.java) {
            decode("garbage before\r\n=ybegin size=0 name=x\r\n=yend size=0\r\n")
        }
        assertThrows(YencDecoder.DecodeException::class.java) {
            decode("=ybegin line=128 name=x\r\nabc\r\n=yend size=3\r\n")
        }
    }

    @Test
    fun `decoded size limit accepts its exact boundary and rejects the next byte before writing it`() {
        val boundary = byteArrayOf(10, 20, 30)
        val accepted = ByteArrayOutputStream()
        assertEquals(3L, YencDecoder.decodeTextTo(wrapBody(boundary), accepted, decodedLimit = 3))
        assertArrayEqualsBytes(boundary, accepted.toByteArray())

        val rejected = ByteArrayOutputStream()
        assertThrows(YencDecoder.DecodeException::class.java) {
            YencDecoder.decodeTextTo(wrapBody(boundary), rejected, decodedLimit = 2)
        }
        assertEquals("only bounded bytes reached the private output", 2, rejected.size())
    }

    @Test
    fun `ybegin whole size and ypart range are returned as authoritative coverage`() {
        val payload = byteArrayOf(10, 20, 30)
        val output = ByteArrayOutputStream()
        val decoder = YencDecoder.StreamingDecoder(output, decodedLimit = 3)
        ("=ybegin line=128 size=9 name=test.mkv\r\n" +
            "=ypart begin=4 end=6\r\n" + encode(payload) + "\r\n=yend size=3\r\n")
            .lineSequence().forEach(decoder::consumeLine)
        val part = decoder.finish()
        assertEquals(9L, part.totalBytes)
        assertEquals(4L, part.begin)
        assertEquals(6L, part.endInclusive)
        assertEquals(3L, part.decodedBytes)
        assertTrue(output.toByteArray().contentEquals(payload))
    }

    @Test
    fun `part range whose bytes do not match decoded article is rejected`() {
        assertThrows(YencDecoder.DecodeException::class.java) {
            decode("=ybegin line=128 size=5 name=test.mkv\r\n=ypart begin=1 end=4\r\n" +
                encode(byteArrayOf(1, 2, 3)) + "\r\n=yend size=3\r\n")
        }
    }

    private fun decode(body: String): ByteArray = ByteArrayOutputStream().also { output ->
        YencDecoder.decodeTextTo(body, output, decodedLimit = Long.MAX_VALUE)
    }.toByteArray()

    private fun assertArrayEqualsBytes(expected: ByteArray, actual: ByteArray) {
        assertEquals("length differs", expected.size, actual.size)
        for (index in expected.indices) {
            assertEquals("byte $index differs", expected[index], actual[index])
        }
    }
}
