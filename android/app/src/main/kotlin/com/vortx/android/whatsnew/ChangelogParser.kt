package com.vortx.android.whatsnew

enum class ChangelogBlockKind {
    VERSION,
    SUBHEAD,
    BULLET,
    PARAGRAPH,
}

data class ChangelogBlock(
    val kind: ChangelogBlockKind,
    val text: String,
)

object ChangelogParser {
    fun parse(text: String): List<ChangelogBlock> = buildList {
        var started = false
        text.lineSequence().forEach { raw ->
            val line = raw.trim()
            when {
                line.startsWith("## ") -> {
                    started = true
                    add(ChangelogBlock(ChangelogBlockKind.VERSION, line.drop(3).trim()))
                }
                !started || line.isEmpty() -> Unit
                line.startsWith("### ") ->
                    add(ChangelogBlock(ChangelogBlockKind.SUBHEAD, line.drop(4).trim()))
                line.startsWith("- ") || line.startsWith("* ") ->
                    add(ChangelogBlock(ChangelogBlockKind.BULLET, line.drop(2).trim()))
                line.startsWith("#") -> Unit
                else -> add(ChangelogBlock(ChangelogBlockKind.PARAGRAPH, line))
            }
        }
    }

    fun inlineText(markdown: String): String = markdown
        .replace(Regex("\\[([^]]+)]\\([^)]+\\)"), "\$1")
        .replace("**", "")
        .replace("__", "")
        .replace("`", "")
}
