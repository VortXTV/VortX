package com.vortx.android.home

import com.vortx.android.trickplay.TmdbImdbResolution
import java.io.ByteArrayInputStream
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.ArrayDeque
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CollectionsHubProductionTransportTest {
    @Test
    fun `list page preserves typed auth and HTTP failures`() = runBlocking {
        val connections = ArrayDeque(
            listOf(
                FakeHttpURLConnection(status = HttpURLConnection.HTTP_UNAUTHORIZED),
                FakeHttpURLConnection(status = HttpURLConnection.HTTP_UNAVAILABLE),
            ),
        )
        val source = source(connections)

        val auth = runCatching { source.page(discoverTarget(), movies(), "GB", 1, true) }.exceptionOrNull()
        val http = runCatching { source.page(discoverTarget(), movies(), "GB", 2, true) }.exceptionOrNull()

        assertTrue(auth is CollectionsHubTransportFailure.Auth)
        assertEquals(HttpURLConnection.HTTP_UNAUTHORIZED, (auth as CollectionsHubTransportFailure.Auth).statusCode)
        assertTrue(http is CollectionsHubTransportFailure.Http)
        assertEquals(HttpURLConnection.HTTP_UNAVAILABLE, (http as CollectionsHubTransportFailure.Http).statusCode)
    }

    @Test
    fun `discover page preserves malformed JSON and IOException failures`() = runBlocking {
        val transportFailure = IOException("offline")
        val connections = ArrayDeque(
            listOf(
                FakeHttpURLConnection(body = "not-json"),
                FakeHttpURLConnection(responseFailure = transportFailure),
            ),
        )
        val source = source(connections)

        val malformed = runCatching {
            source.page(CollectionsHubTarget.Discover(DiscoverList.UPCOMING), movies(), "GB", 1, true)
        }.exceptionOrNull()
        val io = runCatching {
            source.page(CollectionsHubTarget.Discover(DiscoverList.UPCOMING), movies(), "GB", 2, true)
        }.exceptionOrNull()

        assertTrue(malformed is CollectionsHubTransportFailure.MalformedJson)
        assertTrue(io is IOException)
        assertEquals(transportFailure.message, io?.message)
    }

    @Test
    fun `parsed payload without a results array is not an honest empty page`() = runBlocking {
        val source = source(ArrayDeque(listOf(FakeHttpURLConnection(body = "{}"))))

        val failure = runCatching { source.page(discoverTarget(), movies(), "GB", 1, true) }.exceptionOrNull()

        assertTrue(failure is CollectionsHubTransportFailure.MalformedJson)
    }

    @Test
    fun `valid zero results is an honest empty signed page`() = runBlocking {
        val connection = FakeHttpURLConnection(body = "{\"results\":[]}")
        val source = source(ArrayDeque(listOf(connection)))

        val page = source.page(discoverTarget(), movies(), "GB", 1, true)

        assertTrue(page.items.isEmpty())
        assertFalse(page.hasMore)
        assertNotNull(connection.getRequestProperty("X-VX-Ts"))
        assertNotNull(connection.getRequestProperty("X-VX-Kid"))
        assertNotNull(connection.getRequestProperty("X-VX-Sig"))
    }

    private fun source(connections: ArrayDeque<FakeHttpURLConnection>) = EdgeCollectionsHubSource(
        resolveExternalId = { _, _ -> TmdbImdbResolution.NoImdbId },
        transport = CollectionsHubHttpTransport(
            openConnection = { url -> connections.removeFirst().also { it.requestedUrl = url } },
        ),
    )

    private fun discoverTarget() = CollectionsHubTarget.Discover(DiscoverList.POPULAR)

    private fun movies() = CollectionsHubCategory("movies", com.vortx.android.R.string.collections_category_movies)
}

private class FakeHttpURLConnection(
    status: Int = HttpURLConnection.HTTP_OK,
    private val body: String = "",
    private val responseFailure: IOException? = null,
) : HttpURLConnection(URL("https://catalogs.vortx.tv/3/test")) {
    var requestedUrl: URL = url

    init {
        responseCode = status
    }

    override fun connect() = Unit

    override fun disconnect() = Unit

    override fun usingProxy(): Boolean = false

    override fun getURL(): URL = requestedUrl

    override fun getResponseCode(): Int {
        responseFailure?.let { throw it }
        return super.getResponseCode()
    }

    override fun getInputStream(): InputStream = ByteArrayInputStream(body.toByteArray(Charsets.UTF_8))
}
