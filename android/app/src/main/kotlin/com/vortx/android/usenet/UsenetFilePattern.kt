package com.vortx.android.usenet

/**
 * Compiles a Stremio `fileMustInclude`: either a bare regex or the JavaScript form `/pattern/flags` with the
 * `i`, `m` and `s` flags, matching Apple and the native engine. Null for an empty, oversized or invalid
 * pattern, so a broken hint never matches by accident.
 */
internal object UsenetFilePattern {
    fun compile(input: String): Regex? {
        if (input.isEmpty() || input.toByteArray(Charsets.UTF_8).size > 512) return null
        var pattern = input
        val options = mutableSetOf<RegexOption>()
        if (input.startsWith("/")) {
            val end = input.lastIndexOf('/')
            if (end <= 0) return null
            pattern = input.substring(1, end).replace("\\/", "/")
            val flags = input.substring(end + 1)
            if (flags.toSet().size != flags.length) return null
            for (flag in flags) when (flag) {
                'i' -> options += RegexOption.IGNORE_CASE
                'm' -> options += RegexOption.MULTILINE
                's' -> options += RegexOption.DOT_MATCHES_ALL
                else -> return null
            }
        }
        if (pattern.isEmpty()) return null
        return runCatching { Regex(pattern, options) }.getOrNull()
    }
}
