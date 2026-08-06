package com.vortx.android.whatsnew

import com.vortx.android.ui.tv.TvSettingsRoute
import com.vortx.android.ui.tv.changelogReleases
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ChangelogParserTest {
    @Test
    fun `parser mirrors the Apple block grammar`() {
        val blocks = ChangelogParser.parse(
            """
            # Changelog
            Intro before a release is ignored.
            ## 0.3.14 - Current
            ### Playback
            - First bullet
            * Second bullet
            Ordinary paragraph
            #### Dropped heading
            ## 0.3.13
            - Older bullet
            """.trimIndent(),
        )

        assertEquals(
            listOf(
                ChangelogBlock(ChangelogBlockKind.VERSION, "0.3.14 - Current"),
                ChangelogBlock(ChangelogBlockKind.SUBHEAD, "Playback"),
                ChangelogBlock(ChangelogBlockKind.BULLET, "First bullet"),
                ChangelogBlock(ChangelogBlockKind.BULLET, "Second bullet"),
                ChangelogBlock(ChangelogBlockKind.PARAGRAPH, "Ordinary paragraph"),
                ChangelogBlock(ChangelogBlockKind.VERSION, "0.3.13"),
                ChangelogBlock(ChangelogBlockKind.BULLET, "Older bullet"),
            ),
            blocks,
        )
    }

    @Test
    fun `TV groups every version into one release card`() {
        val releases = changelogReleases(
            listOf(
                ChangelogBlock(ChangelogBlockKind.VERSION, "One"),
                ChangelogBlock(ChangelogBlockKind.BULLET, "A"),
                ChangelogBlock(ChangelogBlockKind.VERSION, "Two"),
                ChangelogBlock(ChangelogBlockKind.PARAGRAPH, "B"),
            ),
        )

        assertEquals(listOf("One", "Two"), releases.map { it.title })
        assertEquals(listOf("A"), releases[0].blocks.map { it.text })
        assertEquals(listOf("B"), releases[1].blocks.map { it.text })
    }

    @Test
    fun `inline markdown is readable as plain Compose text`() {
        assertEquals(
            "Title, notes and code",
            ChangelogParser.inlineText("**Title**, [notes](https://example.test) and `code`"),
        )
    }

    @Test
    fun `build copies the root changelog without committing a duplicate asset`() {
        val gradle = readProjectFile("build.gradle.kts")
        assertTrue(gradle.contains("rootProject.file(\"../CHANGELOG.md\")"))
        assertTrue(gradle.contains("assets.srcDir(generatedChangelogAssets)"))
        assertTrue(gradle.contains("dependsOn(copyChangelogAsset)"))
        assertFalse(
            listOf(
                File("src/main/assets/CHANGELOG.md"),
                File("app/src/main/assets/CHANGELOG.md"),
                File("android/app/src/main/assets/CHANGELOG.md"),
            ).any(File::isFile),
        )
    }

    @Test
    fun `every nested TV settings route returns to root`() {
        assertEquals(TvSettingsRoute.ROOT, TvSettingsRoute.ROOT.back())
        assertEquals(TvSettingsRoute.ROOT, TvSettingsRoute.DEBRID.back())
        assertEquals(TvSettingsRoute.ROOT, TvSettingsRoute.WHATS_NEW.back())
    }

    private fun readProjectFile(relativePath: String): String {
        val candidates = listOf(File(relativePath), File("app/$relativePath"), File("android/app/$relativePath"))
        return candidates.firstOrNull(File::isFile)?.readText()
            ?: error("Could not locate $relativePath from ${File(".").absolutePath}")
    }
}
