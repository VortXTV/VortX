package com.vortx.android.player.subtitles

import java.util.Locale
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class SubtitleReferenceQueryTest {
    private val job = "7C7456B1-7B5A-45C9-8630-66CF5D708E20"
    private val external = "1\n00:00:01,000 --> 00:00:02,000\nOriginal\n\n".toByteArray(Charsets.UTF_8)
    private val reference = List(8) { SubtitleReferenceQuery.Timing(it * 10_000L, it * 10_000L + 2000) }

    private fun cue(start: Long = 1250, end: Long = 2250, text: String = "Native text") =
        JSONObject().put("startMs", start).put("endMs", end).put("text", text)

    private fun reply(cues: JSONArray = JSONArray().put(cue())): JSONObject = JSONObject().put("kind", "subtitle_reference")
        .put("result", JSONObject().put("version", 1).put("status", "aligned").put("originalJob", job)
            .put("correction", JSONObject().put("offsetMs", 250).put("driftPpm", 200).put("confidence", 800).put("matched", 8).put("total", 10))
            .put("medianResidualMs", 150).put("workUsed", 40_000_000).put("cues", cues))

    private fun align(reply: JSONObject = reply()) = SubtitleReferenceQuery.align(external, reference, job) { reply.toString() }
    private fun result(reply: JSONObject) = reply.getJSONObject("result")
    private fun correction(reply: JSONObject) = result(reply).getJSONObject("correction")

    @Test fun requestUsesTheAdditiveKindAndStringPayloadWithTheCompleteExternalAndReference() {
        val complete = ("1\n00:00:01,000 --> 00:00:02,000\n第一\n\n" +
            "2\n00:30:00,000 --> 00:30:01,000\nBeyond scoring window\n\n").toByteArray(Charsets.UTF_8)
        val duplicates = reference.toMutableList().also { it[1] = it[0] }
        var calls = 0
        assertNotNull(SubtitleReferenceQuery.align(complete, duplicates, job) { request ->
            calls++
            val outer = JSONObject(request)
            assertEquals("subtitle_reference", outer.get("kind"))
            assertTrue(outer.get("payload") is String)
            val body = JSONObject(outer.getString("payload"))
            assertEquals(1, body.getInt("version"))
            assertEquals(job, body.getString("originalJob"))
            assertEquals("srt", body.getJSONObject("external").getString("kind"))
            assertEquals(String(complete, Charsets.UTF_8), body.getJSONObject("external").getString("text"))
            assertEquals(0L, body.getLong("windowStartMs"))
            assertEquals(900_000L, body.getLong("windowEndMs"))
            assertTrue(body.getBoolean("allowDrift"))
            val rows = body.getJSONArray("referenceCues")
            assertEquals(duplicates.size, rows.length())
            duplicates.forEachIndexed { index, timing ->
                assertEquals(timing.startMs, rows.getJSONObject(index).getLong("startMs"))
                assertEquals(timing.endMs, rows.getJSONObject(index).getLong("endMs"))
            }
            reply().toString()
        })
        assertEquals(1, calls)
    }

    @Test fun oldKindErrorsResolveFailuresLowConfidenceAndWrongJobsFailClosed() {
        assertNull(SubtitleReferenceQuery.align(external, reference, job) { "{\"kind\":\"error\",\"error\":\"unknown kind\"}" })
        assertNull(SubtitleReferenceQuery.align(external, reference, job) { error("unavailable") })
        assertNull(SubtitleReferenceQuery.align(external, reference, job) { throw UnsatisfiedLinkError("unsupported") })
        listOf("kind", "version", "status", "originalJob").forEach { field ->
            val changed = reply()
            if (field == "kind") changed.put(field, "legacy")
            else result(changed).put(field, when (field) { "version" -> 2; "status" -> "low_confidence"; else -> "foreign-job" })
            assertNull("Reject $field", align(changed))
        }
        assertNull(align(reply().also { correction(it).put("confidence", 699) }))
        assertNull(align(reply().also { correction(it).put("confidence", 801) }))
    }

    @Test fun invalidInputNeverCallsResolveIncludingMalformedUtf8NulAndReferenceOrder() {
        var calls = 0
        val resolve: (String) -> String = { calls++; reply().toString() }
        for (bytes in listOf(byteArrayOf(), ByteArray(1024 * 1024 + 1) { 65 }, byteArrayOf(0xc3.toByte(), 0x28),
            byteArrayOf(0xc0.toByte(), 0x80.toByte()), byteArrayOf(65, 0, 66))) {
            assertNull(SubtitleReferenceQuery.align(bytes, reference, job, resolve))
        }
        for (rows in listOf(reference.take(7), List(1025) { reference[0] }, reference.reversed(),
            reference.toMutableList().also { it[0] = SubtitleReferenceQuery.Timing(-1, 10) },
            reference.toMutableList().also { it[0] = SubtitleReferenceQuery.Timing(1, 1) },
            reference.toMutableList().also { it[7] = SubtitleReferenceQuery.Timing(1_000_000, 1_080_001) })) {
            assertNull(SubtitleReferenceQuery.align(external, rows, job, resolve))
        }
        assertNull(SubtitleReferenceQuery.align(external, reference, "not-a-job", resolve))
        assertEquals(0, calls)
    }

    @Test fun equalStartDialogueLongCuesAndEveryFullOutputCueSurviveWithoutReparse() {
        val rows = JSONArray()
        rows.put(cue(1250, 25_000, "<i>First</i>\n{\\an8}第二"))
        rows.put(cue(1250, 3000, "Second same-start cue"))
        rows.put(cue(1_800_000, 1_801_000, "Outside estimation window"))
        val aligned = requireNotNull(align(reply(rows)))
        assertEquals(listOf(1250L, 1250L, 1_800_000L), aligned.cues.map { it.startMs })
        assertEquals(listOf("<i>First</i>\n{\\an8}第二", "Second same-start cue", "Outside estimation window"), aligned.cues.map { it.text })
        assertEquals("1\n00:00:01,250 --> 00:00:25,000\n<i>First</i>\n{\\an8}第二\n\n" +
            "2\n00:00:01,250 --> 00:00:03,000\nSecond same-start cue\n\n" +
            "3\n00:30:00,000 --> 00:30:01,000\nOutside estimation window\n\n", String(aligned.srt, Charsets.UTF_8))
        assertEquals(250L, aligned.offsetMs)
        assertEquals(200, aligned.driftPpm)
        assertEquals(800, aligned.confidence)
        val renderer = JSONObject(requireNotNull(SubtitleReferenceQuery.payload(aligned, "日本語")))
        assertEquals(1, renderer.getInt("version"))
        assertEquals("日本語", renderer.getString("language"))
        assertEquals(rows.toString(), renderer.getJSONArray("cues").toString())
        val bytes = aligned.srt
        bytes[0] = 0
        assertEquals('1', String(aligned.srt, Charsets.UTF_8)[0])
    }

    @Test fun allCorrectionResidualAndWorkBoundsAreEnforcedBeforeNarrowing() {
        val invalid = mapOf("offsetMs" to listOf(-120_001L, 120_001L), "driftPpm" to listOf(-50_001L, 50_001L),
            "confidence" to listOf(-1L, 1001L), "matched" to listOf(7L, 11L, Long.MAX_VALUE), "total" to listOf(7L, 1025L))
        invalid.forEach { (field, values) -> values.forEach { value ->
            assertNull("$field=$value", align(reply().also { correction(it).put(field, value) }))
        } }
        listOf(-1L, 151L).forEach { assertNull(align(reply().also { row -> result(row).put("medianResidualMs", it) })) }
        listOf(0L, 40_000_001L).forEach { assertNull(align(reply().also { row -> result(row).put("workUsed", it) })) }
        listOf(-120_000L, 120_000L).forEach { assertNotNull(align(reply().also { row -> correction(row).put("offsetMs", it) })) }
        listOf(-50_000L, 50_000L).forEach { assertNotNull(align(reply().also { row -> correction(row).put("driftPpm", it) })) }
        assertNotNull(align(reply().also { correction(it).put("matched", 8).put("total", 8).put("confidence", 1000) }))
        assertNotNull(align(reply().also { correction(it).put("matched", 700).put("total", 1000).put("confidence", 700) }))
    }

    @Test fun overflowFractionalAndStringNumbersMalformedJsonAndBrokenUnicodeAreRejected() {
        val good = reply().toString()
        for (token in listOf("9223372036854775808", "18446744073709551615", "1e100", "250.5", "250.0000000000000000001",
            "1e-1000", "\"250\"", "null", "true")) {
            val raw = good.replace("\"offsetMs\":250", "\"offsetMs\":$token")
            assertNotEquals(good, raw)
            assertNull("offsetMs=$token", SubtitleReferenceQuery.align(external, reference, job) { raw })
        }
        val badRows = listOf(good + "{}", good.dropLast(1), good.replace("\"kind\":", "'kind':"),
            good.replace("\"Native text\"", "\"\\uD800\""), good.replace("\"Native text\"", "\"bad\ntext\""),
            good.replace("\"Native text\"", "\"bad\uD800text\""), good.replace("\"kind\":", "kind="))
        badRows.forEach { raw -> assertNull(SubtitleReferenceQuery.align(external, reference, job) { raw }) }
    }

    @Test fun cueCountTimingTextAndOrderingLimitsFailTheWholeResultWithoutTruncation() {
        val badCues = listOf(cue(-1, 1000), cue(1000, 1000), cue(1001, 1000), cue(0, 91_000_001),
            cue(text = ""), cue(text = "a\u0000b"), cue(text = "é".repeat(8193)))
        badCues.forEach { assertNull(align(reply(JSONArray().put(it)))) }
        assertNull(align(reply(JSONArray())))
        val tooMany = JSONArray(List(12_001) { cue() })
        assertNull(align(reply(tooMany)))
        val reversed = JSONArray().put(cue(2000, 3000)).put(cue(1000, 1500))
        assertNull(align(reply(reversed)))
        val maximum = JSONArray().put(cue(0, 91_000_000, "é".repeat(8192)))
        assertNotNull(align(reply(maximum)))
        val lastInvalid = JSONArray(List(100) { cue(it * 1000L, it * 1000L + 500) }).put(cue(1, 2))
        assertNull(align(reply(lastInvalid)))
    }

    @Test fun serializedSrtAndRawReplyLimitsRejectTheWholeResult() {
        // Raw response remains below 16 MiB, while numbered SRT exceeds its independent 8 MiB cap.
        val rows = JSONArray(List(520) { cue(it * 1000L, it * 1000L + 500, "x".repeat(16_384)) })
        assertNull(align(reply(rows)))
        val oversized = " ".repeat(16 * 1024 * 1024) + reply().toString()
        assertNull(SubtitleReferenceQuery.align(external, reference, job) { oversized })
        val full = JSONArray(List(12_000) { cue(it * 1000L, it * 1000L + 500, "cue $it") })
        val aligned = requireNotNull(align(reply(full)))
        assertEquals(12_000, aligned.cues.size)
        assertTrue(String(aligned.srt, Charsets.UTF_8).endsWith("cue 11999\n\n"))
    }

    @Test fun rendererHasIndependentUtf8LanguageAndNineMiBLimitsAndIsLocaleIndependent() {
        val aligned = requireNotNull(align())
        assertNotNull(SubtitleReferenceQuery.payload(aligned, "a".repeat(255)))
        assertNull(SubtitleReferenceQuery.payload(aligned, "a".repeat(256)))
        assertNull(SubtitleReferenceQuery.payload(aligned, "é".repeat(128)))
        assertNull(SubtitleReferenceQuery.payload(aligned, "a\u0000b"))
        assertNull(SubtitleReferenceQuery.payload(aligned, "\uD800"))
        val escaped = JSONArray(List(100) { cue(it * 1000L, it * 1000L + 500, "\u0001".repeat(16_384)) })
        val largeRenderer = requireNotNull(align(reply(escaped)))
        assertNull(SubtitleReferenceQuery.payload(largeRenderer, "en"))
        val previous = Locale.getDefault()
        try {
            Locale.setDefault(Locale.forLanguageTag("ar-EG"))
            assertEquals(String(aligned.srt, Charsets.UTF_8), String(requireNotNull(align()).srt, Charsets.UTF_8))
        } finally { Locale.setDefault(previous) }
    }
}
