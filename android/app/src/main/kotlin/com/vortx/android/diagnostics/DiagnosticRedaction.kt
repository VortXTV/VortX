package com.vortx.android.diagnostics

import java.security.MessageDigest
import java.security.SecureRandom
import java.util.regex.Pattern

/**
 * The one durable-line formatter and sink-side scrubber for every diagnostic line this app writes, ported
 * rule for rule from Apple `VXProbeRedaction` so an exported Android log carries the same protections.
 *
 * It is PATTERN-BASED AND THEREFORE BEST-EFFORT. It removes credentials in URLs, authorization headers,
 * JWTs, credential-bearing query parameters, long hex runs (infohashes, passkeys, API keys) and catalog
 * identities (`tt…`, `tmdb:…`), and it neutralises control characters so one record can never forge a second
 * log line. It cannot recognise an identifier with no shape (a free-text title), so producers must not log
 * titles in the first place; [identityToken] is how a producer says WHICH title without naming it.
 *
 * Placeholders are `<tag:abc123>`: a salted SHA-256 prefix whose salt is random per process and never
 * written anywhere, so occurrences correlate within one exported run and nothing correlates across runs.
 */
internal object DiagnosticRedaction {
    /** Cap on one COMPLETE durable line, timestamp, category and newline included. */
    const val MAX_LINE_BYTES = 1024
    const val MAX_CATEGORY_BYTES = 24
    const val MAX_TIMESTAMP_BYTES = 32
    /** Bytes hashed for one placeholder; bounded before hashing so a hostile value is never copied whole. */
    const val MAX_TOKEN_INPUT_BYTES = 512

    private val salt: ByteArray = ByteArray(16).also(SecureRandom()::nextBytes)

    /** Short, stable, non-reversible stand-in for one redacted value. */
    fun token(tag: String, value: String): String {
        val digest = MessageDigest.getInstance("SHA-256")
        digest.update(salt)
        digest.update(clampBytes(value, MAX_TOKEN_INPUT_BYTES).toByteArray(Charsets.UTF_8))
        val hex = digest.digest().take(3).joinToString("") { "%02x".format(it) }
        return "<$tag:$hex>"
    }

    /** The producer-side spelling: the same placeholder the sink would produce, without building the id in. */
    fun identityToken(raw: String?): String = if (raw.isNullOrEmpty()) "-" else token("id", raw)

    // ---- Normalisation ----

    /** Glyphless scalars that exist, for our purposes, to break a pattern apart. They are dropped. */
    private fun isIgnorable(cp: Int): Boolean = when (cp) {
        0x00AD, 0x061C, 0xFEFF -> true
        in 0x200B..0x200F, in 0x202A..0x202E -> true
        in 0x2060..0x2064, in 0x2066..0x2069 -> true
        in 0x0300..0x036F, in 0x1AB0..0x1AFF -> true
        in 0x1DC0..0x1DFF, in 0x20D0..0x20FF -> true
        in 0xFE00..0xFE0F, in 0xFE20..0xFE2F -> true
        else -> false
    }

    /** Cyrillic and Greek letters that render as the ASCII our identifier shapes are built from. */
    private val confusables: Map<Int, Char> = mapOf(
        0x0430 to 'a', 0x0432 to 'b', 0x0435 to 'e', 0x043A to 'k', 0x043C to 'm',
        0x043D to 'h', 0x043E to 'o', 0x0440 to 'p', 0x0441 to 'c', 0x0442 to 't',
        0x0443 to 'y', 0x0445 to 'x', 0x0455 to 's', 0x0456 to 'i', 0x0458 to 'j',
        0x0410 to 'A', 0x0412 to 'B', 0x0415 to 'E', 0x041A to 'K', 0x041C to 'M',
        0x041D to 'H', 0x041E to 'O', 0x0420 to 'P', 0x0421 to 'C', 0x0422 to 'T',
        0x0425 to 'X', 0x0405 to 'S', 0x0406 to 'I', 0x0408 to 'J',
        0x03B1 to 'a', 0x03B5 to 'e', 0x03B9 to 'i', 0x03BA to 'k', 0x03BD to 'v',
        0x03BF to 'o', 0x03C1 to 'p', 0x03C4 to 't', 0x03C5 to 'u', 0x03C7 to 'x',
    )

    /** Drop the invisible, fold the lookalike, and pull fullwidth and mathematical digits back to ASCII. */
    fun fold(raw: String): String {
        val out = StringBuilder(raw.length)
        raw.codePoints().forEach { cp ->
            when {
                isIgnorable(cp) -> Unit
                cp in 0xFF01..0xFF5E -> out.appendCodePoint(cp - 0xFEE0)
                cp in 0x1D7CE..0x1D7FF -> out.append(('0'.code + (cp - 0x1D7CE) % 10).toChar())
                else -> {
                    val folded = confusables[cp]
                    if (folded != null) out.append(folded) else out.appendCodePoint(cp)
                }
            }
        }
        return out.toString()
    }

    /** Escape every character that could end or split a durable line, which is what stops log forgery. */
    fun neutralizeControls(raw: String): String {
        val out = StringBuilder(raw.length)
        raw.codePoints().forEach { cp ->
            when (cp) {
                0x0A -> out.append("\\n")
                0x0D -> out.append("\\r")
                0x09 -> out.append("\\t")
                in 0x00..0x08, 0x0B, 0x0C, in 0x0E..0x1F, 0x7F -> out.append("\\x%02x".format(cp))
                0x0085, 0x2028, 0x2029 -> out.append("\\u%04x".format(cp))
                else -> out.appendCodePoint(cp)
            }
        }
        return out.toString()
    }

    // ---- Rules, most specific first: credentials leave before the generic hex rule could hide them ----

    private class Rule(val tag: String, pattern: String, val group: Int) {
        val regex: Pattern = Pattern.compile(pattern, Pattern.CASE_INSENSITIVE)
    }

    private val rules = listOf(
        // user:password@host in any URL; the scheme repetition is bounded so a long line cannot go quadratic.
        Rule("cred", """[a-z][a-z0-9+.\-]{0,15}://([^\s/@]+)@""", 1),
        Rule("auth", """(?:proxy-)?authorization\s*[:=]\s*[a-z]+\s+([^\s"',;]+)""", 1),
        Rule("auth", """\bbearer\s+([a-z0-9._\-+/=]{8,})""", 1),
        Rule("jwt", """\beyj[a-z0-9._\-]{16,}""", 0),
        // A credential word anywhere inside a query parameter NAME (auth_token, x-api-key, dl_passkey, ...).
        Rule(
            "secret",
            """[?&][^=&\s]{0,40}(?:api[_-]?key|apikey|access[_-]?token|token|passkey|password|passwd|secret|signature|sig|session|sid|auth|key)[^=&\s]{0,40}=([^&\s"']+)""",
            1,
        ),
        // Any long hex run (v1 and v2 infohashes, passkeys, session ids, API keys); a lower bound, never exact.
        Rule("hex", """[0-9a-f]{32,}""", 0),
        // Catalog identities ARE viewing history. Six digits, no leading boundary, as the producers allow.
        Rule("tt", """tt[0-9]{6,}""", 0),
        Rule("id", """(?:tmdb|tvdb|kitsu|anidb|mal)[:_\-][0-9]+""", 0),
    )

    /** Apply every rule once, in order, with no length bounding (production goes through [scrub]). */
    fun redactAll(text: String): String = rules.fold(text) { out, rule -> apply(rule, out) }

    /** Normalise, bound, redact, then bound again (redaction can lengthen a line). */
    fun scrub(raw: String): String = bound(redactAll(bound(neutralizeControls(fold(raw)))))

    /** Form ONE complete durable line, terminated by exactly one newline and capped at [MAX_LINE_BYTES]. */
    fun durableLine(timestamp: String, category: String, message: String): String {
        val safeStamp = clampBytes(neutralizeControls(fold(timestamp)), MAX_TIMESTAMP_BYTES)
        val safeCategory = clampBytes(redactAll(neutralizeControls(fold(category))), MAX_CATEGORY_BYTES)
        return boundTo("$safeStamp [$safeCategory] ${scrub(message)}", MAX_LINE_BYTES - 1) + "\n"
    }

    private fun apply(rule: Rule, text: String): String {
        val matcher = rule.regex.matcher(text)
        val ranges = ArrayList<IntRange>()
        while (matcher.find()) {
            val start = matcher.start(rule.group)
            if (start >= 0) ranges += start until matcher.end(rule.group)
        }
        if (ranges.isEmpty()) return text
        val out = StringBuilder(text)
        // Reverse order so each replacement cannot invalidate the ranges still to be applied.
        for (range in ranges.asReversed()) {
            out.replace(range.first, range.last + 1, token(rule.tag, text.substring(range.first, range.last + 1)))
        }
        return out.toString()
    }

    private const val TRUNCATION_MARKER = " [truncated]"

    /** Characters no identifier shape contains, so a cut there cannot halve one. */
    private fun isTokenBoundary(cp: Int): Boolean = Character.isWhitespace(cp) || ",;)]}\"'|>".indexOf(cp.toChar()) >= 0

    private fun utf8Width(cp: Int): Int = when {
        cp < 0x80 -> 1
        cp < 0x800 -> 2
        cp < 0x10000 -> 3
        else -> 4
    }

    /** Hard byte clamp with no marker, for the short fixed fields of a line. */
    private fun clampBytes(text: String, budget: Int): String {
        if (text.toByteArray(Charsets.UTF_8).size <= budget) return text
        val out = StringBuilder()
        var used = 0
        for (cp in text.codePoints().toArray()) {
            val width = utf8Width(cp)
            if (used + width > budget) break
            out.appendCodePoint(cp)
            used += width
        }
        return out.toString()
    }

    private fun bound(text: String): String = boundTo(text, MAX_LINE_BYTES)

    /**
     * Truncate on a UTF-8 budget at the last token boundary that fits, so a value straddling the cap is removed
     * whole rather than halved, and say so. Idempotent: the marker counts inside the budget.
     */
    private fun boundTo(text: String, budgetBytes: Int): String {
        if (text.toByteArray(Charsets.UTF_8).size <= budgetBytes) return text
        val budget = budgetBytes - TRUNCATION_MARKER.length
        val out = StringBuilder()
        var used = 0
        var lastBoundary = -1
        for (cp in text.codePoints().toArray()) {
            val width = utf8Width(cp)
            if (used + width > budget) break
            out.appendCodePoint(cp)
            used += width
            if (isTokenBoundary(cp)) lastBoundary = out.length
        }
        val kept = if (lastBoundary >= 0) out.substring(0, lastBoundary) else ""
        return kept.trimEnd() + TRUNCATION_MARKER
    }
}
