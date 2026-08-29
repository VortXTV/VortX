package com.vortx.android.profile

import java.io.File
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test

class ContinueWatchingDedupeTest {
    private data class Item(
        val key: String,
        val id: String,
        val type: String,
        val aliases: List<String>,
        val position: Double,
        val duration: Double,
        val updatedAt: Double?,
        val removed: Boolean,
    )

    @Test
    fun sharedCrossPlatformFixturesMatch() {
        val fixture = JSONObject(fixtureFile().readText())
        assertEquals(1, fixture.getInt("version"))
        val cases = fixture.getJSONArray("cases")
        for (caseIndex in 0 until cases.length()) {
            val testCase = cases.getJSONObject(caseIndex)
            val rawItems = testCase.getJSONArray("items")
            val items = (0 until rawItems.length()).map { itemIndex ->
                val raw = rawItems.getJSONObject(itemIndex)
                val rawAliases = raw.getJSONArray("aliases")
                Item(
                    key = raw.getString("key"),
                    id = raw.getString("id"),
                    type = raw.getString("type"),
                    aliases = (0 until rawAliases.length()).map(rawAliases::getString),
                    position = raw.getDouble("position"),
                    duration = raw.getDouble("duration"),
                    updatedAt = raw.optDouble("updatedAt").takeIf { raw.has("updatedAt") },
                    removed = raw.optBoolean("removed", false),
                )
            }
            val expectedRaw = testCase.getJSONArray("expected")
            val expected = (0 until expectedRaw.length()).map(expectedRaw::getString)
            val actual = ContinueWatchingDedupe.fold(items) { item ->
                ContinueWatchingDedupe.Identity(
                    id = item.id,
                    type = item.type,
                    aliases = item.aliases,
                    freshness = item.updatedAt,
                    hasValidProgress = item.position.isFinite() && item.duration.isFinite() &&
                        item.position > 0 && item.duration >= 0,
                    removed = item.removed,
                )
            }.map(Item::key)
            assertEquals(testCase.getString("name"), expected, actual)
        }
    }

    private fun fixtureFile(): File {
        val start = System.getProperty("user.dir") ?: "."
        var directory = File(start).canonicalFile
        repeat(6) {
            val candidate = File(directory, "test-fixtures/continue-watching-dedupe.json")
            if (candidate.isFile) return candidate
            directory.parentFile?.let { directory = it }
        }
        error("test-fixtures/continue-watching-dedupe.json was not found from $start")
    }
}
