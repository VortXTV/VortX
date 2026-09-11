package com.vortx.android.ui

import com.vortx.android.ui.components.sourceAuthoredText
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SourcePresentationTest {
    @Test fun `authored formatting and unicode are retained`() {
        val name = "📺 Provider\n4K"
        val description = "  🎬 release.mkv\n\n🇫🇷 Français • 🇬🇧 English\n💾 12 GB  "
        assertEquals("$name\n$description", sourceAuthoredText(name, description))
    }

    @Test fun `description fallback already used as title is not repeated`() {
        assertEquals("file.mkv", sourceAuthoredText("file.mkv", "file.mkv"))
        assertEquals("name", sourceAuthoredText("name", null))
        assertEquals("name", sourceAuthoredText("name", " \n"))
        assertEquals("description", sourceAuthoredText("", "description"))
    }

    @Test fun `phone and TV main source lists keep the authored description wired`() {
        fun read(relative: String): String = listOf(File(relative), File("app/$relative"), File("android/app/$relative"))
            .first(File::isFile).readText()
        val prefix = "src/main/kotlin/com/vortx/android/ui/"
        assertTrue(read(prefix + "screens/DetailScreen.kt").contains("description = source.description"))
        assertTrue(read(prefix + "components/SourceRow.kt").contains("sourceAuthoredText(title, description)"))
        assertTrue(read(prefix + "tv/TvSourceList.kt").contains("sourceAuthoredText(source.title, source.description)"))
    }
}
