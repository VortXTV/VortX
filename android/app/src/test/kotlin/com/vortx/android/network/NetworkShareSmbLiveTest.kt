package com.vortx.android.network

import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Assume.assumeTrue
import org.junit.Test

/**
 * smbj and the playback relay against a real Samba server: the fixture from test/fixtures/smb-share.sh, reached at
 * VORTX_SMB_LIVE_SERVER (host:port). Skipped without it, like the live engine tests without VORTX_JNI_LIBRARY.
 */
class NetworkShareSmbLiveTest {
    private val server: String? = System.getenv("VORTX_SMB_LIVE_SERVER")
    private val login = NetworkShareClient.Login("tester", "s3cret")
    private val client = NetworkShareSmbClient()

    /** The fixture movie's bytes (test/fixtures/smb-share.sh writes the same pattern). */
    private fun movieByte(i: Int): Byte = (((i * 31 + 7) xor (i shr 8)) and 255).toByte()

    private fun reason(block: suspend () -> Unit): NetworkShareException.Reason? = runBlocking {
        try { block(); null } catch (failure: NetworkShareException) { failure.reason }
    }

    @Test fun `a real share lists, refuses a wrong login and streams exact bytes through the relay`() = runBlocking {
        assumeTrue("no live SMB server", server != null)
        val movies = NetworkSharePolicy.smbRootUrl("smb://$server/Movies")!!
        val root = client.list(movies, movies, login)
        assertEquals(listOf("Season 1", "Test Movie (2024).mkv"), root.map { it.name })
        assertEquals(listOf("S01E01.mp4"), client.list(root[0].url, movies, login).map { it.name })
        val public = NetworkSharePolicy.smbRootUrl("smb://$server/Public")!!
        assertEquals(2, client.list(public, public, NetworkShareClient.Login("", "")).size)
        assertEquals(NetworkShareException.Reason.UNAUTHORIZED, reason { client.list(movies, movies, NetworkShareClient.Login("tester", "wrong")) })
        val missing = NetworkSharePolicy.smbRootUrl("smb://$server/NoSuchShare")!!
        assertEquals(NetworkShareException.Reason.NOT_A_SHARE, reason { client.list(missing, missing, login) })
        val bare = NetworkSharePolicy.smbRootUrl("smb://$server")!!
        assertEquals(NetworkShareException.Reason.SMB_SHARE_REQUIRED, reason { client.list(bare, bare, login) })

        val relay = NetworkShareSmbRelay(client::open)
        try {
            val location = NetworkSharePolicy.smbLocation(root[1].url)!!
            val address = relay.address(SmbTarget(location, login, location.path.substringAfterLast('\\')))!!
            assertTrue(!address.contains("s3cret") && !address.contains("tester"))
            val whole = (URL(address).openConnection() as HttpURLConnection).run {
                assertEquals(200, responseCode); assertEquals("5000000", getHeaderField("Content-Length"))
                inputStream.use { it.readBytes() }
            }
            val expected = ByteArray(5_000_000) { movieByte(it) }
            assertEquals(sha(expected), sha(whole))
            val slice = (URL(address).openConnection() as HttpURLConnection).run {
                setRequestProperty("Range", "bytes=4000000-4000999")
                assertEquals(206, responseCode); assertEquals("bytes 4000000-4000999/5000000", getHeaderField("Content-Range"))
                inputStream.use { it.readBytes() }
            }
            assertTrue(slice.contentEquals(expected.copyOfRange(4_000_000, 4_001_000)))
        } finally {
            relay.close()
        }
        Unit
    }

    @Test fun `a file the login cannot open is refused before any byte`() {
        assumeTrue("no live SMB server", server != null)
        val location = NetworkSharePolicy.smbLocation("smb://$server/Movies/Test%20Movie%20(2024).mkv")!!
        try {
            client.open(SmbTarget(location, NetworkShareClient.Login("tester", "wrong"), "x.mkv")).close()
            fail("opened with a wrong password")
        } catch (failure: NetworkShareException) {
            assertEquals(NetworkShareException.Reason.UNAUTHORIZED, failure.reason)
        }
    }

    private fun sha(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
}
