package com.vortx.android.engine

import java.io.File
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Test

class LegacyWatchedBitfieldDecoderTest {
    @Test fun `shared strict watched bitfield fixtures agree`() {
        val fixture = JSONObject(fixtureFile().readText())
        assertEquals(1, fixture.getInt("schemaVersion"))
        val cases = fixture.getJSONArray("cases")
        for (index in 0 until cases.length()) {
            val test = cases.getJSONObject(index)
            val serialized = if (test.has("serialized")) test.getString("serialized") else
                test.getString("serializedPrefix") + test.getString("payloadCharacter").repeat(test.getInt("payloadCount"))
            val inventory = test.getJSONArray("inventory").let { values ->
                (0 until values.length()).map { entry -> values.getJSONObject(entry).let {
                    LegacyWatchedBitfieldEpisode(it.getString("id"), it.getInt("season"), it.getInt("episode"),
                        if (it.isNull("releasedMs")) null else it.getLong("releasedMs"))
                } }
            }
            if (test.optBoolean("error")) {
                try {
                    LegacyWatchedBitfieldDecoder.decode(serialized, inventory)
                    fail("Expected decoder failure for ${test.getString("name")}")
                } catch (_: IllegalArgumentException) { }
            } else {
                val expected = test.getJSONArray("watched").let { watched -> (0 until watched.length()).map { requireNotNull(watched.getString(it)) } }
                assertEquals(test.getString("name"), expected, LegacyWatchedBitfieldDecoder.decode(serialized, inventory))
            }
        }
    }

    private fun fixtureFile(): File = generateSequence(File(System.getProperty("user.dir"))) { it.parentFile }
        .map { File(it, "test/fixtures/legacy-watched-bitfield.json") }
        .firstOrNull(File::isFile) ?: error("Shared watched-bitfield fixture is unavailable")
}
