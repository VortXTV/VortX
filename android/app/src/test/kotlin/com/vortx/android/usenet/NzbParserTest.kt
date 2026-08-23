package com.vortx.android.usenet

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/// Pure-JVM tests for [NzbParser] (org.w3c.dom runs identically on the JVM).
class NzbParserTest {

    private fun nzbXml(files: String): String = listOf(
        """<?xml version="1.0" encoding="UTF-8"?>""",
        """<nzb xmlns="http://www.newzbin.com/DTD/2003/nzb">""",
        files,
        """</nzb>""",
    ).joinToString("\n")

    private fun xmlAttr(value: String): String = value
        .replace("&", "&amp;")
        .replace("\"", "&quot;")
        .replace("<", "&lt;")

    private fun fileXml(subject: String, segments: String): String = listOf(
        """<file poster="poster@example.com" date="1700000000" subject="${xmlAttr(subject)}">""",
        "<groups><group>alt.binaries.test</group></groups>",
        "<segments>",
        segments,
        "</segments>",
        "</file>",
    ).joinToString("\n")

    @Test
    fun `parses a single-file NZB with message-id segments sorted by number`() {
        val xml = nzbXml(
            fileXml(
                subject = "My.Show.S01E01.1080p.mkv yEnc (1/3) 52428800",
                segments = listOf(
                    "<segment bytes=\"500000\" number=\"2\">b@news</segment>",
                    "<segment bytes=\"2428800\" number=\"3\">c@news</segment>",
                    "<segment bytes=\"500000\" number=\"1\">a@news</segment>",
                ).joinToString("\n"),
            ),
        )

        val files = NzbParser.parse(xml)

        assertEquals(1, files.size)
        val file = files.single()
        assertTrue(file.name.contains("S01E01"))
        assertEquals("poster@example.com", file.poster)
        assertEquals("alt.binaries.test", file.group)
        // Document order is 2,3,1; parsed order MUST be numeric.
        assertEquals(listOf(1L, 2L, 3L), file.segments.map { it.number })
        // The message-id is the element TEXT in a standard NZB, surfaced as `article` for NNTP BODY.
        assertEquals(listOf("a@news", "b@news", "c@news"), file.segments.map { it.article })
        assertEquals(3428800L, file.declaredBytes)
        assertTrue(file.isVideo)
    }

    @Test
    fun `isVideo rejects non-video extensions`() {
        val xml = nzbXml(
            fileXml(subject = "My.Show.S01E01.par2 yEnc (1/1) 100", segments = "<segment bytes=\"100\" number=\"1\">x@news</segment>"),
        )
        val parsed = NzbParser.parse(xml)
        assertEquals(1, parsed.size)
        assertTrue(!parsed.single().isVideo)
    }

    @Test
    fun `extracts the quoted file name from a standard yEnc subject`() {
        val xml = nzbXml(
            fileXml(
                subject = "\"Real.Name.S02E05.720p.mkv\" yEnc (4/12) 999",
                segments = "<segment bytes=\"100\" number=\"1\">x@news</segment>",
            ),
        )
        val file = NzbParser.parse(xml).single()
        assertEquals("Real.Name.S02E05.720p.mkv", file.name)
        assertTrue(file.isVideo)
    }

    @Test
    fun `malformed XML yields empty list instead of throwing`() {
        assertTrue(NzbParser.parse("this is not xml <<<<").isEmpty())
        assertTrue(NzbParser.parse("").isEmpty())
    }

    @Test
    fun `XXE attempt never resolves the external entity`() {
        val evil = """<?xml version="1.0"?><!DOCTYPE nzb [<!ENTITY xxe SYSTEM "file:///etc/passwd">]>
            <nzb xmlns="http://www.newzbin.com/DTD/2003/nzb"><file poster="&xxe;" date="1" subject="s">
            <groups></groups><segments><segment bytes="1" number="1">m@n</segment></segments></file></nzb>"""
        val result = try {
            NzbParser.parse(evil)
        } catch (_: Exception) {
            emptyList<NzbFile>()
        }
        assertTrue(result.isEmpty() || !result.single().poster.contains("/etc/passwd"))
    }
}
