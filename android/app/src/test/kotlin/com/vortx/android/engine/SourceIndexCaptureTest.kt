package com.vortx.android.engine

import com.vortx.android.model.StreamGroup
import com.vortx.android.model.StreamSource
import com.vortx.android.singularity.SourceIndexClient
import com.vortx.android.singularity.SourceUploadPacer
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SourceIndexCaptureTest {
    @Test
    fun `descriptor extraction normalizes and deduplicates only canonical torrent hashes`() {
        val privateUrl = "https://debrid.example/file?token=private-token"
        val privateNzb = "https://indexer.example/file.nzb?apikey=private-key"
        val streams = listOf(
            torrent(UPPER_HASH, url = privateUrl),
            torrent(VALID_HASH),
            direct(privateUrl),
            StreamSource(
                id = privateNzb,
                addon = "Private indexer",
                title = "1080p",
                nzbUrl = privateNzb,
            ),
            torrent("a".repeat(39)),
            torrent("a".repeat(41)),
            torrent("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"),
            torrent("g".repeat(40)),
        )

        val descriptors = SourceIndexClient.descriptors(listOf(StreamGroup("Provider secret", streams)))

        assertEquals(1, descriptors.size)
        assertEquals("torrent", descriptors.single().kind)
        assertEquals(VALID_HASH, descriptors.single().id)
        assertEquals("1080p", descriptors.single().quality)

        val body = requireNotNull(SourceIndexClient.contributionBody("tt1234567", descriptors))
        val source = JSONObject(body).getJSONArray("sources").getJSONObject(0)
        assertEquals(
            setOf("kind", "id", "quality", "sizeBytes", "seeders"),
            source.keys().asSequence().toSet(),
        )
        assertFalse(body.contains(privateUrl))
        assertFalse(body.contains(privateNzb))
        assertFalse(body.contains("Provider secret"))
        assertFalse(body.contains("sourceTag"))
        assertFalse(body.contains("url"))
        assertFalse(body.contains("nzbUrl"))
    }

    @Test
    fun `upload boundary admits only normalized torrent infohashes`() {
        val privateUrl = "https://debrid.example/file?token=private-token"
        val crafted = listOf(
            SourceIndexClient.Descriptor("torrent", UPPER_HASH, privateUrl, -1, 1_000_001),
            descriptor(VALID_HASH),
            descriptor(privateUrl),
            descriptor("a".repeat(41)),
            descriptor("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"),
            SourceIndexClient.Descriptor("direct", VALID_HASH, "4K", 1, null),
            SourceIndexClient.Descriptor("usenet", privateUrl, "4K", 1, null),
        )

        val uploadable = SourceIndexClient.uploadableDescriptors(crafted)
        assertEquals(listOf(VALID_HASH), uploadable.map { it.id })
        assertTrue(uploadable.all { it.kind == "torrent" })
        assertEquals("Other", uploadable.single().quality)
        assertEquals(0, uploadable.single().sizeBytes)
        assertEquals(null, uploadable.single().seeders)

        val body = requireNotNull(SourceIndexClient.contributionBody("tt1234567", crafted))
        val sources = JSONObject(body).getJSONArray("sources")
        assertEquals(1, sources.length())
        assertEquals(VALID_HASH, sources.getJSONObject(0).getString("id"))
        assertFalse(body.contains(privateUrl))
        assertFalse(body.contains("direct"))
        assertFalse(body.contains("usenet"))
        assertFalse(body.contains("private-token"))
        assertEquals(null, SourceIndexClient.contributionBody("user@example.com", crafted))
        assertEquals(
            null,
            SourceIndexClient.contributionBody(
                "tt1234567",
                listOf(SourceIndexClient.Descriptor("direct", VALID_HASH, "4K", 1, null)),
            ),
        )

        val seventeen = (0 until 17).map { descriptor(it.toString(16).padStart(40, '0')) }
        assertEquals(listOf(16, 1), SourceIndexClient.uploadBatches(seventeen).map { it.size })
        assertTrue(SourceIndexClient.contributionBody("tt1234567", seventeen.take(16)) != null)
        assertEquals(null, SourceIndexClient.contributionBody("tt1234567", seventeen))
    }

    @Test
    fun `served rows admit only lowercase canonical torrent hashes`() {
        val privateMetadata = "https://debrid.example/file?token=private-token"
        val pooled = listOf(
            pooled("torrent", VALID_HASH).copy(
                quality = privateMetadata,
                sizeBytes = 9_007_199_254_740_991L,
                seeders = 1_000_000,
            ),
            pooled("torrent", SECOND_HASH).copy(corroboration = null),
            pooled("torrent", "c".repeat(40)).copy(corroboration = 0),
            pooled("torrent", "d".repeat(40)).copy(corroboration = 1),
            pooled("torrent", UPPER_HASH),
            pooled("torrent", "a".repeat(39)),
            pooled("torrent", "a".repeat(41)),
            pooled("torrent", "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"),
            pooled("torrent", "https://example.invalid/file"),
            pooled("direct", "https://example.invalid/file"),
            pooled("usenet", "https://example.invalid/file.nzb"),
        )

        val streams = SourceIndexClient.streams(pooled)

        assertEquals(1, streams.size)
        assertEquals(VALID_HASH, streams.single().infoHash)
        assertTrue(streams.single().isTorrent)
        assertEquals(null, streams.single().url)
        assertEquals(null, streams.single().nzbUrl)
        assertEquals("Other · Singularity", streams.single().title)
        assertEquals("Singularity source", streams.single().description)
        assertEquals("Other", streams.single().quality)
        assertFalse(streams.single().id.contains(privateMetadata))
        assertEquals(100, SourceIndexClient.streams(List(101) { pooled("torrent", VALID_HASH) }).size)
    }

    @Test
    fun `pooled parser caps 101 rows and malformed JSON is empty`() {
        val rows = JSONArray()
        repeat(101) {
            rows.put(
                JSONObject()
                    .put("kind", "torrent")
                    .put("id", VALID_HASH)
                    .put("quality", "Other")
                    .put("sizeBytes", 0)
                    .put("seeders", 0)
                    .put("corroboration", 2),
            )
        }
        val parsed = SourceIndexClient.parsePooled(JSONObject().put("sources", rows).toString())
        assertEquals(100, parsed.size)
        assertTrue(SourceIndexClient.parsePooled("{not-json").isEmpty())
    }

    @Test
    fun `direct first does not consume the late torrent dedup slot`() {
        val ledger = SourceHoardLedger()
        val directFirst = SourceListModel.contributionDescriptors(
            raw = listOf(StreamGroup("Addon", listOf(direct("https://cdn.example/video?token=secret")))),
            torboxStreams = emptyList(),
            disabledAddons = emptySet(),
        )
        assertTrue(ledger.takeNew("tt1234567", directFirst).isEmpty())

        val lateTorrent = SourceListModel.contributionDescriptors(
            raw = listOf(StreamGroup("Addon", listOf(torrent(VALID_HASH)))),
            torboxStreams = emptyList(),
            disabledAddons = emptySet(),
        )
        assertEquals(listOf(VALID_HASH), ledger.takeNew("tt1234567", lateTorrent).map { it.id })
        assertTrue(ledger.takeNew("tt1234567", lateTorrent).isEmpty())
    }

    @Test
    fun `pool first does not consume a raw torrent that arrives later`() {
        val ledger = SourceHoardLedger()
        val pooled = torrent(VALID_HASH, addon = "Singularity")
        val poolFirstDisplay = SourceListModel.assemble(
            raw = emptyList(),
            torboxStreams = emptyList(),
            singularityStreams = listOf(pooled),
            mediaServerGroups = emptyList(),
            ctx = SourceListModel.Context(),
        )
        assertTrue(poolFirstDisplay.groups.flatMap { it.streams }.any { it.infoHash == VALID_HASH })

        val poolExcluded = SourceListModel.contributionDescriptors(emptyList(), emptyList(), emptySet())
        assertTrue(ledger.takeNew("tt1234567", poolExcluded).isEmpty())

        val rawLater = SourceListModel.contributionDescriptors(
            listOf(StreamGroup("Addon", listOf(torrent(VALID_HASH)))),
            emptyList(),
            emptySet(),
        )
        assertEquals(listOf(VALID_HASH), ledger.takeNew("tt1234567", rawLater).map { it.id })
    }

    @Test
    fun `capture precedes direct only display filtering and excludes media server tokens`() {
        val torrent = torrent(VALID_HASH)
        val mediaUrl = "https://plex.example/library/parts/1?X-Plex-Token=private"
        val media = direct(mediaUrl, addon = "Plex").copy(isMediaServer = true, vortxProvider = "server-id")
        val raw = listOf(StreamGroup("Addon", listOf(torrent)))
        val ctx = SourceListModel.Context(directLinksOnly = true)

        val display = SourceListModel.assemble(
            raw = raw,
            torboxStreams = emptyList(),
            singularityStreams = emptyList(),
            mediaServerGroups = listOf(StreamGroup("Plex", listOf(media))),
            ctx = ctx,
        )
        assertFalse(display.groups.flatMap { it.streams }.any { it.infoHash == VALID_HASH })

        val captured = SourceListModel.contributionDescriptors(raw, emptyList(), emptySet())
        assertEquals(listOf(VALID_HASH), captured.map { it.id })
        val body = requireNotNull(SourceIndexClient.contributionBody("tt1234567", captured))
        assertFalse(body.contains(mediaUrl))
        assertFalse(body.contains("X-Plex-Token"))
    }

    @Test
    fun `TorBox torrents are included but its direct results are excluded`() {
        val privateUrl = "https://torbox.example/download?token=private"
        val captured = SourceListModel.contributionDescriptors(
            raw = emptyList(),
            torboxStreams = listOf(torrent(VALID_HASH, addon = "TorBox"), direct(privateUrl, addon = "TorBox")),
            disabledAddons = emptySet(),
        )

        assertEquals(listOf(VALID_HASH), captured.map { it.id })
        val body = requireNotNull(SourceIndexClient.contributionBody("tt1234567", captured))
        assertFalse(body.contains(privateUrl))
        assertFalse(body.contains("private"))
    }

    @Test
    fun `quality aliases close to the shared torrent enum`() {
        val aliases = listOf(
            "2160p" to "4K",
            "UHD" to "4K",
            "1440p" to "1440p",
            "1080P" to "1080p",
            "720p" to "720p",
            "576p" to "576p",
            "540p" to "540p",
            "SD" to "480p",
            "unknown-provider-label" to "Other",
        )
        val crafted = aliases.mapIndexed { index, (quality, _) ->
            descriptor(index.toString(16).padStart(40, '0')).copy(quality = quality)
        }

        val normalized = SourceIndexClient.uploadableDescriptors(crafted)

        assertEquals(aliases.map { it.second }, normalized.map { it.quality })
    }

    @Test
    fun `serve boundary rejects invalid Unicode episodic and user shaped ids before URL construction`() {
        assertEquals(null, SourceIndexClient.serveUrl("user@example.com"))
        assertEquals(null, SourceIndexClient.serveUrl("tt١٢٣٤٥٦"))
        assertEquals(null, SourceIndexClient.serveUrl("tt1234567:1"))
        assertEquals(null, SourceIndexClient.serveUrl("tmdb:123:1"))
        assertEquals(null, SourceIndexClient.serveUrl("TMDB:123"))
        assertEquals(
            "https://sources.vortx.tv/sources?content_id=tmdb%3A123%3A1%3A2&kind=torrent",
            SourceIndexClient.serveUrl("tmdb:123:1:2"),
        )
    }

    @Test
    fun `Android stays dormant until live closure gates cancel clear and fence late work`() = runBlocking {
        var postAttempts = 0
        SourceIndexClient.contributeUsing("tt1234567", listOf(descriptor(VALID_HASH))) { _, _, _, _ ->
            postAttempts += 1
        }

        var moatAttempts = 0
        var getAttempts = 0
        val pooled = SourceIndexClient.fetchPooledUsing(
            contentId = "tt1234567",
            isSignedIn = true,
            moatProvider = {
                moatAttempts += 1
                "must-not-be-read"
            },
            request = { _, _, _ ->
                getAttempts += 1
                listOf(pooled("torrent", VALID_HASH))
            },
        )

        assertFalse(SourceIndexClient.isEnabled)
        assertEquals(0, postAttempts)
        assertEquals(0, moatAttempts)
        assertEquals(0, getAttempts)
        assertTrue(pooled.isEmpty())
    }

    @Test
    fun `process wide pacer serializes overlapping callers and carries delay across invocations`() = runBlocking {
        var now = 10_000L
        val sleeps = mutableListOf<Long>()
        val actions = mutableListOf<String>()
        val firstStarted = CompletableDeferred<Unit>()
        val releaseFirst = CompletableDeferred<Unit>()
        val pacer = SourceUploadPacer(
            intervalMs = 1_100,
            nowMs = { now },
            sleepMs = { duration ->
                sleeps += duration
                now += duration
            },
        )

        coroutineScope {
            val first = async {
                pacer.pace {
                    actions += "first"
                    firstStarted.complete(Unit)
                    releaseFirst.await()
                }
            }
            firstStarted.await()
            val second = async { pacer.pace { actions += "second" } }
            yield()
            releaseFirst.complete(Unit)
            first.await()
            second.await()
        }

        assertEquals(listOf("first", "second"), actions)
        assertEquals(listOf(1_100L), sleeps)
    }

    @Test
    fun `dedup is scoped by content and marks only the submitted limit`() {
        val ledger = SourceHoardLedger()
        val descriptors = listOf(
            descriptor(VALID_HASH),
            descriptor(SECOND_HASH),
        )

        assertEquals(listOf(VALID_HASH), ledger.takeNew("tt1234567", descriptors, limit = 1).map { it.id })
        assertEquals(listOf(SECOND_HASH), ledger.takeNew("tt1234567", descriptors, limit = 1).map { it.id })
        assertEquals(listOf(VALID_HASH), ledger.takeNew("tt7654321", descriptors, limit = 1).map { it.id })
    }

    @Test
    fun `bounded ledger saturates without evicting the oldest process claim`() {
        val ledger = SourceHoardLedger(maxEntries = 2)
        val first = descriptor(VALID_HASH)
        val second = descriptor(SECOND_HASH)
        val third = descriptor("cccccccccccccccccccccccccccccccccccccccc")

        assertEquals(listOf(first, second), ledger.takeNew("tt1234567", listOf(first, second)))
        assertTrue(ledger.takeNew("tt1234567", listOf(third)).isEmpty())
        assertTrue(ledger.takeNew("tt1234567", listOf(second)).isEmpty())
        assertTrue(ledger.takeNew("tt1234567", listOf(first)).isEmpty())
        assertTrue(ledger.takeNew("user@example.com", listOf(third)).isEmpty())
    }

    @Test
    fun `content ids reject trailing junk overlong imdb and user shaped values`() {
        assertEquals("tt1234567:1:2", SourceIndexClient.contentId("tt1234567", 1, 2))
        assertEquals(null, SourceIndexClient.contentId("tt1234567junk"))
        assertEquals(null, SourceIndexClient.contentId("tt12345678901"))
        assertEquals(null, SourceIndexClient.contentId("user@example.com"))
        assertEquals(null, SourceIndexClient.contentId("tt١٢٣٤٥٦"))
    }

    private fun descriptor(hash: String) = SourceIndexClient.Descriptor(
        kind = SourceIndexClient.Kind.TORRENT.wire,
        id = hash,
        quality = "1080p",
        sizeBytes = 0,
        seeders = null,
    )

    private fun pooled(kind: String, id: String) = SourceIndexClient.PooledSource(
        kind = kind,
        id = id,
        quality = "1080p",
        sizeBytes = 0,
        seeders = null,
        corroboration = 2,
    )

    private fun torrent(hash: String, addon: String = "Addon", url: String? = null) = StreamSource(
        id = "$hash#1080p",
        addon = addon,
        title = "1080p Seeders: 12",
        isTorrent = true,
        infoHash = hash,
        url = url,
    )

    private fun direct(url: String, addon: String = "Addon") = StreamSource(
        id = url,
        addon = addon,
        title = "1080p",
        url = url,
    )

    private companion object {
        const val VALID_HASH = "abcdef0123456789abcdef0123456789abcdef01"
        const val UPPER_HASH = "ABCDEF0123456789ABCDEF0123456789ABCDEF01"
        const val SECOND_HASH = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    }
}
