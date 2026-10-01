package com.vortx.android.nzb

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import org.xml.sax.Attributes
import org.xml.sax.EntityResolver
import org.xml.sax.InputSource
import org.xml.sax.helpers.DefaultHandler
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URI
import java.net.URLEncoder
import java.net.URL
import javax.xml.parsers.SAXParserFactory
import kotlin.coroutines.coroutineContext

/** Small, bounded Newznab RSS client. Request URLs with the API key are never returned or logged. */
internal class NzbIndexerClient(
    private val transport: NzbTransport = UrlConnectionNzbTransport,
) {
    suspend fun search(config: NzbIndexerConfig, apiKey: String, search: NzbSearch): Result<List<NzbRelease>> = try {
        require(config.isValidMetadata() && apiKey.isNotBlank() && search.isValid())
        val endpoint = NzbIndexerEndpointPolicy.validate(config.endpoint).getOrThrow()
        val typed = request(endpoint, apiKey, search, fallback = false)
        val primary = decodeResponse(transport.fetch(typed, TIMEOUT_MS))
        val releases = when (primary) {
            is Response.Releases -> primary.releases
            is Response.Error -> {
                // Newznab 203 is the contract's sole "optional function unavailable" response.
                if (primary.code != 203) throw NzbFailure.Api(primary.code)
                val fallback = request(endpoint, apiKey, search, fallback = true)
                when (val fallbackResponse = decodeResponse(transport.fetch(fallback, TIMEOUT_MS))) {
                    is Response.Releases -> fallbackResponse.releases
                    is Response.Error -> throw NzbFailure.Api(fallbackResponse.code)
                }
            }
        }
        Result.success(
            if (search.isEpisode) releases.filter { episodeTokenMatches(it.title, requireNotNull(search.season), requireNotNull(search.episode)) }
            else releases,
        )
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (error: Throwable) {
        Result.failure(error)
    }

    internal fun request(endpoint: URI, apiKey: String, search: NzbSearch, fallback: Boolean): URI {
        require(NzbIndexerEndpointPolicy.validate(endpoint).isSuccess && apiKey.isNotBlank() && search.isValid())
        val params = linkedMapOf("limit" to MAX_RESULTS.toString(), "o" to "xml", "apikey" to apiKey)
        if (fallback) {
            params["t"] = "search"
            params["q"] = if (search.isEpisode) "${search.title} S%02dE%02d".format(search.season, search.episode) else search.title
        } else if (search.isEpisode) {
            params["t"] = "tvsearch"
            params["q"] = search.title
            NzbSearch.imdbDigits(search.seriesImdbId)?.let { params["imdbid"] = it }
            params["season"] = "S%02d".format(search.season)
            params["ep"] = search.episode.toString()
        } else {
            params["t"] = "movie"
            params["q"] = search.title
            NzbSearch.imdbDigits(search.movieImdbId)?.let { params["imdbid"] = it }
            search.year?.let { params["year"] = it.toString() }
        }
        val query = params.entries.joinToString("&") { (key, value) -> "${encode(key)}=${encode(value)}" }
        // The five-argument URI constructor treats an already-percent-encoded query as data and can
        // double-escape `%`. Endpoint policy has already excluded queries/fragments/userinfo.
        return URI.create(endpoint.toASCIIString() + "?" + query)
    }

    private suspend fun decodeResponse(response: NzbHttpResponse): Response {
        if (response.code !in 200..299) throw NzbFailure.Transport
        if (response.body.size > MAX_RESPONSE_BYTES) throw NzbFailure.TooLarge
        return parse(response.body)
    }

    internal fun parse(bytes: ByteArray): Response {
        if (bytes.size > MAX_RESPONSE_BYTES || containsXmlDeclarationAttack(bytes)) throw NzbFailure.Malformed
        val handler = RssHandler()
        try {
            SAXParserFactory.newInstance().apply {
                isNamespaceAware = false
                setFeature("http://apache.org/xml/features/disallow-doctype-decl", true)
                setFeature("http://xml.org/sax/features/external-general-entities", false)
                setFeature("http://xml.org/sax/features/external-parameter-entities", false)
                setFeature("http://apache.org/xml/features/nonvalidating/load-external-dtd", false)
            }.newSAXParser().xmlReader.apply {
                contentHandler = handler
                entityResolver = EntityResolver { _, _ -> InputSource(ByteArrayInputStream(ByteArray(0))) }
                parse(InputSource(ByteArrayInputStream(bytes)))
            }
        } catch (failure: NzbFailure) {
            throw failure
        } catch (_: Exception) {
            throw NzbFailure.Malformed
        }
        return handler.errorCode?.let(Response::Error) ?: Response.Releases(handler.releases)
    }

    private fun containsXmlDeclarationAttack(bytes: ByteArray): Boolean {
        val text = when {
            bytes.hasPrefix(0xFF.toByte(), 0xFE.toByte()) -> bytes.toString(Charsets.UTF_16LE)
            bytes.hasPrefix(0xFE.toByte(), 0xFF.toByte()) -> bytes.toString(Charsets.UTF_16BE)
            else -> bytes.toString(Charsets.UTF_8)
        }
        return text.contains("<!DOCTYPE", true) || text.contains("<!ENTITY", true)
    }

    private class RssHandler : DefaultHandler() {
        val releases = mutableListOf<NzbRelease>()
        var errorCode: Int? = null
        private var rootSeen = false
        private var validRoot = false
        private var inItem = false
        private var readingTitle = false
        private var title: StringBuilder? = null
        private var enclosure: String? = null
        private var size: Long? = null

        override fun startElement(uri: String?, localName: String?, qName: String?, attributes: Attributes) {
            val name = (localName?.takeIf(String::isNotEmpty) ?: qName.orEmpty()).substringAfter(':').lowercase()
            if (!rootSeen) { rootSeen = true; validRoot = name == "rss" || name == "error" }
            if (!validRoot) throw NzbFailure.Malformed
            if (name == "error") errorCode = attributes.getValue("code")?.toIntOrNull() ?: throw NzbFailure.Malformed
            if (name == "item") { inItem = true; title = attributes.getValue("title")?.take(MAX_TITLE_BYTES)?.let(::StringBuilder); enclosure = null; size = null }
            if (inItem && name == "title" && title == null) { title = StringBuilder(); readingTitle = true }
            if (inItem && name == "enclosure") {
                validEnclosure(attributes.getValue("url"))?.let { enclosure = it }
                size = attributes.getValue("length")?.toLongOrNull()?.takeIf { it >= 0 }
            }
        }

        override fun characters(ch: CharArray, start: Int, length: Int) {
            val target = title ?: return
            if (!readingTitle || target.length >= MAX_TITLE_BYTES) return
            target.append(ch, start, minOf(length, MAX_TITLE_BYTES - target.length))
        }

        override fun endElement(uri: String?, localName: String?, qName: String?) {
            val name = (localName?.takeIf(String::isNotEmpty) ?: qName.orEmpty()).substringAfter(':').lowercase()
            if (name == "title") readingTitle = false
            if (name != "item") return
            inItem = false
            val safeTitle = title?.toString()?.trim().orEmpty()
            val safeUrl = enclosure
            if (safeTitle.isNotEmpty() && safeUrl != null && releases.size < MAX_RESULTS) releases += NzbRelease(safeTitle, safeUrl, size)
        }

        private fun validEnclosure(raw: String?): String? {
            val value = raw ?: return null
            return runCatching { URI(value) }.getOrNull()?.takeIf { uri ->
            value.toByteArray().size <= MAX_ENCLOSURE_BYTES && uri.scheme.equals("https", true) &&
                !uri.host.isNullOrBlank() && uri.userInfo == null && uri.fragment == null &&
                !uri.rawQuery.orEmpty().contains(Regex("(^|&)(apikey|api_key)=", RegexOption.IGNORE_CASE))
            }?.toString()
        }
    }

    internal sealed interface Response { data class Releases(val releases: List<NzbRelease>) : Response; data class Error(val code: Int) : Response }
    private fun encode(value: String): String = URLEncoder.encode(value, Charsets.UTF_8.name()).replace("+", "%20")
    private fun episodeTokenMatches(title: String, season: Int, episode: Int): Boolean = Regex("(?i)s%02de%02d(?![0-9])".format(season, episode)).containsMatchIn(title)

    internal companion object { const val MAX_RESPONSE_BYTES = 1_500_000; const val MAX_RESULTS = 50; const val TIMEOUT_MS = 15_000; const val MAX_TITLE_BYTES = 8_192; const val MAX_ENCLOSURE_BYTES = 8_192 }
}

private fun ByteArray.hasPrefix(first: Byte, second: Byte): Boolean = size >= 2 && this[0] == first && this[1] == second

internal sealed class NzbFailure(message: String) : Exception(message) { data object Transport : NzbFailure("transport"); data object TooLarge : NzbFailure("too large"); data object Malformed : NzbFailure("malformed"); data class Api(val code: Int) : NzbFailure("api $code") }
internal data class NzbHttpResponse(val code: Int, val body: ByteArray)
internal fun interface NzbTransport { suspend fun fetch(url: URI, timeoutMs: Int): NzbHttpResponse }

internal object UrlConnectionNzbTransport : NzbTransport {
    override suspend fun fetch(url: URI, timeoutMs: Int): NzbHttpResponse = withContext(Dispatchers.IO) {
        coroutineContext.ensureActive()
        var connection: HttpURLConnection? = null
        try {
            connection = (URL(url.toASCIIString()).openConnection() as HttpURLConnection).apply { connectTimeout = timeoutMs; readTimeout = timeoutMs; instanceFollowRedirects = false; requestMethod = "GET" }
            val code = connection.responseCode
            val stream = (if (code in 200..299) connection.inputStream else connection.errorStream) ?: ByteArrayInputStream(ByteArray(0))
            NzbHttpResponse(code, stream.use { input ->
                ByteArrayOutputStream().use { out ->
                    val buffer = ByteArray(8_192); var total = 0
                    while (true) { coroutineContext.ensureActive(); val count = input.read(buffer); if (count < 0) break; total += count; if (total > NzbIndexerClient.MAX_RESPONSE_BYTES) throw NzbFailure.TooLarge; out.write(buffer, 0, count) }
                    out.toByteArray()
                }
            })
        } catch (failure: NzbFailure) { throw failure
        } catch (_: Exception) { throw NzbFailure.Transport
        } finally { connection?.disconnect() }
    }
}
