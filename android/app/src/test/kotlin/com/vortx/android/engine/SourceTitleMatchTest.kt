package com.vortx.android.engine

import com.vortx.android.model.StreamGroup
import com.vortx.android.model.StreamSource
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File

/** Runs the fixtures the Apple twin also runs, so both platforms score every case the same way (#172). */
class SourceTitleMatchTest {
    @Test
    fun `scores match the shared fixtures`() {
        val fixture = fixture()
        assertEquals(1, fixture.getInt("schemaVersion"))
        val scores = fixture.getJSONArray("scores")
        for (index in 0 until scores.length()) {
            val case = scores.getJSONObject(index)
            val expected = if (case.isNull("expected")) null else case.getInt("expected")
            assertEquals(case.getString("case"), expected, SourceTitleMatch.score(texts(case), target(case)))
        }
    }

    @Test
    fun `threshold decisions match the shared fixtures`() {
        val passes = fixture().getJSONArray("passes")
        for (index in 0 until passes.length()) {
            val case = passes.getJSONObject(index)
            assertEquals(case.getString("case"), case.getBoolean("expected"),
                SourceTitleMatch.passes(texts(case), target(case), case.getInt("threshold")))
        }
    }

    @Test
    fun `the setting offers off and three thresholds`() {
        assertEquals(listOf(0, 50, 70, 90), SourceTitleMatch.thresholds)
        assertEquals("leon the professional 1994", SourceTitleMatch.normalized("  Léon: The Professional (1994) "))
    }

    @Test
    fun `the source filter hides mismatched releases but keeps unnamed sources`() {
        val target = SourceTitleMatch.Target("The Bear", season = 2, episode = 3)
        val groups = listOf(
            StreamGroup("A", listOf(
                stream("right", filename = "The.Bear.S02E03.1080p.WEB.mkv"),
                stream("wrong", filename = "The.Bear.S02E04.1080p.WEB.mkv"),
            )),
            StreamGroup("B", listOf(stream("unnamed", title = "Debridio 1080p"))),
            StreamGroup("C", listOf(stream("other", filename = "Severance.S02E03.1080p.mkv"))),
        )
        val kept = StreamRanking.titleMatched(groups, target, 70)
        assertEquals(listOf("A" to listOf("right"), "B" to listOf("unnamed")), kept.map { group -> group.addon to group.streams.map { it.id } })
        assertEquals(groups, StreamRanking.titleMatched(groups, target, 0))
        assertEquals(groups, StreamRanking.titleMatched(groups, null, 90))
    }

    @Test
    fun `the source filter never leaves a title without sources`() {
        val groups = listOf(StreamGroup("A", listOf(stream("wrong", filename = "Severance.S02E03.1080p.mkv"))))
        assertEquals(groups, StreamRanking.titleMatched(groups, SourceTitleMatch.Target("The Bear", season = 2, episode = 3), 90))
    }

    @Test
    fun `only offered thresholds and plausible years are read`() {
        assertEquals(70, SourceTitleMatchThreshold.admitted(70))
        assertEquals(null, SourceTitleMatchThreshold.admitted(65))
        assertEquals(2019, SourceTitleMatch.year("2019-2023"))
        assertEquals(null, SourceTitleMatch.year("123456"))
    }

    private fun stream(id: String, filename: String? = null, title: String = id) =
        StreamSource(id = id, addon = "Fixture", title = title, filename = filename)

    private fun target(case: JSONObject) = SourceTitleMatch.Target(
        title = case.getString("title"),
        year = case.optInt("year").takeIf { case.has("year") },
        season = case.optInt("season").takeIf { case.has("season") },
        episode = case.optInt("episode").takeIf { case.has("episode") },
    )

    private fun texts(case: JSONObject): List<String?> {
        val texts = case.getJSONArray("texts")
        return (0 until texts.length()).map { texts.getString(it) }
    }

    private fun fixture(): JSONObject = JSONObject(fixtureFile().readText())

    private fun fixtureFile(): File = generateSequence(File(System.getProperty("user.dir"))) { it.parentFile }
        .map { File(it, "test/fixtures/source-title-match.json") }
        .firstOrNull(File::isFile) ?: error("Shared title-match fixture is unavailable")
}
