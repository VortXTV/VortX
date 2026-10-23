package com.vortx.android.diagnostics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Ported from Apple `VXProbeRedactionTests`: the known bypasses stay closed and the known limits are asserted. */
class DiagnosticRedactionTest {
    private fun scrub(text: String) = DiagnosticRedaction.scrub(text)

    @Test fun `catalog ids leave while episode coordinates and counts stay readable`() {
        val episode = scrub("resume tt0903747:3:5 seen=4")
        assertFalse(episode.contains("0903747"))
        assertTrue(episode.contains(":3:5"))
        assertTrue(episode.contains("seen=4"))
        assertFalse(scrub("open tmdb:94997").contains("94997"))
    }

    @Test fun `placeholders correlate within a run and differ between titles`() {
        assertEquals(scrub("a tt0903747"), scrub("a tt0903747"))
        assertNotEquals(scrub("tt0903747"), scrub("tt1375666"))
        assertEquals(DiagnosticRedaction.token("id", "tt0903747"), DiagnosticRedaction.identityToken("tt0903747"))
        assertEquals("-", DiagnosticRedaction.identityToken(null))
        assertEquals("-", DiagnosticRedaction.identityToken(""))
        assertFalse(DiagnosticRedaction.identityToken("Breaking Bad").contains("Breaking"))
    }

    @Test fun `hashes passkeys and URL credentials are removed but hosts stay`() {
        val hash = "a".repeat(40)
        val passkey = "0123456789abcdef0123456789abcdef"
        val hexes = scrub("engine $hash tracker passkey $passkey")
        assertFalse(hexes.contains(hash) || hexes.contains(passkey))
        val creds = scrub("GET https://user:hunter2@host.example/x?apikey=SECRET-abc123&q=1")
        assertFalse(creds.contains("hunter2"))
        assertFalse(creds.contains("SECRET-abc123"))
        assertTrue(creds.contains("host.example") && creds.contains("q=1"))
    }

    @Test fun `the seven known bypasses stay closed`() {
        // A six-digit tt id, and an id glued to a word prefix.
        assertFalse(scrub("tt123456").contains("123456"))
        assertFalse(scrub("id_tt0903747").contains("0903747"))
        // Near-miss hex lengths: 41 and a 64-character v2 infohash.
        assertFalse(scrub("x ${"b".repeat(41)}").contains("b".repeat(41)))
        assertFalse(scrub("x ${"c".repeat(64)}").contains("c".repeat(64)))
        // A credential parameter spelled with an affix (Real-Debrid's own auth_token).
        val rd = scrub("https://api.example/x?auth_token=RD-9f8e7d6c5b&limit=10")
        assertFalse(rd.contains("RD-9f8e7d6c5b"))
        assertTrue(rd.contains("limit=10"))
        // A forged second line through a newline.
        val forged = scrub("ok\n2026-01-01 00:00:00.000 [auth] fake")
        assertFalse(forged.contains("\n") || forged.contains("\r"))
        assertTrue(forged.contains("\\n"))
        // Zero-width and lookalike padding inside an id.
        assertFalse(scrub("tt​0903747").contains("0903747"))
        assertFalse(scrub("тт0903747").contains("0903747"))
        assertFalse(scrub("ｔｔ０９０３７４７").contains("0903747"))
        // An eleven-digit typed id.
        assertFalse(scrub("tmdb:12345678901").contains("12345678901"))
    }

    @Test fun `authorization headers and jwts are removed`() {
        assertFalse(scrub("Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.payload.sig").contains("eyJhbGciOiJIUzI1NiJ9"))
        assertFalse(scrub("token bearer 9f8e7d6c5b4a3928xyz").contains("9f8e7d6c5b4a3928"))
    }

    @Test fun `control characters are escaped, never written raw`() {
        val out = scrub("a\rb c\u0085d\u0007e")
        assertFalse(out.contains("\r") || out.contains(" ") || out.contains("\u0085") || out.contains("\u0007"))
    }

    @Test fun `long lines are capped and a straddling identifier is removed whole`() {
        val huge = scrub("x ".repeat(2_000) + "tt0903747")
        assertTrue(huge.toByteArray().size <= DiagnosticRedaction.MAX_LINE_BYTES)
        assertTrue(huge.endsWith("[truncated]"))
        assertEquals("short line", scrub("short line"))
        val straddle = scrub("y ".repeat(505) + "a".repeat(40))
        assertFalse(straddle.contains("aaaaaaaaaa"))
    }

    @Test fun `a pathological line cannot stall the scrubber`() {
        val started = System.nanoTime()
        DiagnosticRedaction.redactAll("a".repeat(200_000) + "://")
        scrub("h".repeat(200_000))
        assertTrue((System.nanoTime() - started) / 1_000_000_000.0 < 5.0)
    }

    @Test fun `the honest limit is asserted, a shapeless title passes untouched`() {
        assertEquals("open Breaking Bad S03E05", scrub("open Breaking Bad S03E05"))
    }

    @Test fun `a durable line is one capped line with every field scrubbed`() {
        val stamp = "2026-10-13 12:00:00.000"
        assertEquals("$stamp [dv] route ok\n", DiagnosticRedaction.durableLine(stamp, "dv", "route ok"))
        assertFalse(DiagnosticRedaction.durableLine(stamp, "tt0903747", "x").contains("0903747"))
        assertEquals(1, DiagnosticRedaction.durableLine(stamp, "a\nb", "c\nd").count { it == '\n' })
        val long = DiagnosticRedaction.durableLine(stamp, "cat", "z ".repeat(2_000))
        assertTrue(long.toByteArray().size <= DiagnosticRedaction.MAX_LINE_BYTES)
        assertEquals(1, long.count { it == '\n' })
        assertEquals(1, DiagnosticRedaction.durableLine("1\n2", "c", "m").count { it == '\n' })
    }
}
