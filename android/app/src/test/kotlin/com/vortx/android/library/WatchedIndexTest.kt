package com.vortx.android.library

import com.vortx.android.model.Catalog
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import com.vortx.android.profile.WatchEntry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files

class WatchedIndexTest {
    @Test
    fun `bucket parser accepts only matching account and positive watched count`() {
        val json = bucket(
            uid = "account-a",
            items = """
                "tt1":{"state":{"timesWatched":1}},
                "tt2":{"state":{"timesWatched":0}},
                "tt3":{"state":{"timesWatched":4}}
            """.trimIndent(),
        )

        assertEquals(setOf("tt1", "tt3"), WatchedIndex.parseBucketJson(json, "account-a"))
        assertTrue(WatchedIndex.parseBucketJson(json, "account-b").isEmpty())
    }

    @Test
    fun `signed-out bucket accepts only null uid`() {
        assertEquals(
            setOf("tt1"),
            WatchedIndex.parseBucketJson(bucket(null, "\"tt1\":{\"state\":{\"timesWatched\":1}}"), null),
        )
        assertTrue(
            WatchedIndex.parseBucketJson(bucket("account-a", "\"tt1\":{\"state\":{\"timesWatched\":1}}"), null)
                .isEmpty(),
        )
    }

    @Test
    fun `overlay index uses only titles with watched videos`() {
        val watch = mapOf(
            "tt1" to WatchEntry(watchedVideoIds = listOf("tt1")),
            "tt2" to WatchEntry(watchedVideoIds = emptyList()),
            "tt3" to WatchEntry(watchedVideoIds = listOf("tt3:1:1")),
        )

        assertEquals(setOf("tt1", "tt3"), WatchedIndex.overlayIds(watch))
    }

    @Test
    fun `badges apply to catalog rails but never Continue Watching`() {
        val item = MetaItem("tt1", MediaType.MOVIE, "One")
        val rows = listOf(
            Catalog("continue", "Continue Watching", listOf(item)),
            Catalog("popular", "Popular", listOf(item)),
        )

        val marked = WatchedIndex.apply(rows, setOf("tt1"))

        assertFalse(marked[0].items.single().watched)
        assertTrue(marked[1].items.single().watched)
    }

    @Test
    fun `raised account fence blocks every engine watched input from dimming covers`() {
        val rows = listOf(
            Catalog(
                "popular",
                "Popular",
                listOf(
                    MetaItem("tt-bucket", MediaType.MOVIE, "Bucket"),
                    MetaItem("tt-library", MediaType.MOVIE, "Library"),
                    MetaItem("tt-preview", MediaType.MOVIE, "Preview"),
                ),
            ),
        )
        val watchedIds = WatchedIndex.engineHomeIds(
            bucketIds = setOf("tt-bucket"),
            libraryIds = setOf("tt-library"),
            continueWatchingIds = setOf("tt-preview"),
            suppressAccountHistory = true,
        )

        assertTrue(watchedIds.isEmpty())
        assertTrue(WatchedIndex.apply(rows, watchedIds).single().items.none { it.watched })
    }

    @Test
    fun `matching empty account buckets are authoritative and mismatched buckets are rejected`() {
        val dir = Files.createTempDirectory("vortx-watched-uid").toFile()
        try {
            dir.resolve("library.json").writeText(bucket("account-a", ""))
            dir.resolve("library_recent.json").writeText(bucket("account-a", ""))
            assertTrue(WatchedIndex.storageMatchesUid(dir, "account-a"))

            dir.resolve("library.json").writeText(bucket("account-b", ""))
            assertFalse(WatchedIndex.storageMatchesUid(dir, "account-a"))
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test
    fun `file cache refreshes when a bucket changes`() {
        val dir = Files.createTempDirectory("vortx-watched-index").toFile()
        try {
            val file = dir.resolve("library.json")
            file.writeText(bucket("account-a", "\"tt1\":{\"state\":{\"timesWatched\":1}}"))
            val index = WatchedIndex(dir)
            assertEquals(setOf("tt1"), index.engineIds("account-a"))

            file.writeText(bucket("account-a", "\"tt22\":{\"state\":{\"timesWatched\":2}}"))
            assertEquals(setOf("tt22"), index.engineIds("account-a"))
        } finally {
            dir.deleteRecursively()
        }
    }

    private fun bucket(uid: String?, items: String): String {
        val uidJson = uid?.let { "\"$it\"" } ?: "null"
        return """{"uid":$uidJson,"items":{$items}}"""
    }
}
