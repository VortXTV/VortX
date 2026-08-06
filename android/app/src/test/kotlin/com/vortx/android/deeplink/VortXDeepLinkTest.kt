package com.vortx.android.deeplink

import com.vortx.android.model.MediaType
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class VortXDeepLinkTest {
    @Test
    fun `movie and series links accept case and decoded identifiers`() {
        assertEquals(
            VortXDeepLink(MediaType.MOVIE, "tt123"),
            VortXDeepLinks.parse("VORTX://OPEN?type=Movie&id=%20tt123%20"),
        )
        assertEquals(
            VortXDeepLink(MediaType.SERIES, "series:id/1"),
            VortXDeepLinks.parse("vortx://open?type=series&id=series%3Aid%2F1"),
        )
    }

    @Test
    fun `first duplicate query value wins`() {
        assertEquals(
            VortXDeepLink(MediaType.MOVIE, "first"),
            VortXDeepLinks.parse("vortx://open?type=movie&type=series&id=first&id=second"),
        )
    }

    @Test
    fun `malformed unsupported and oversized links fail closed`() {
        val oversized = "x".repeat(257)
        listOf(
            null,
            "",
            "https://open?type=movie&id=tt1",
            "vortx://closed?type=movie&id=tt1",
            "vortx://open?type=channel&id=tt1",
            "vortx://open?type=movie&id=",
            "vortx://open?type=movie&id=$oversized",
            "vortx://open?type=movie&id=%ZZ",
        ).forEach { assertNull(it, VortXDeepLinks.parse(it)) }
    }

    @Test
    fun `one browsable router forwards to two single task launchers`() {
        val manifest = readProjectFile("src/main/AndroidManifest.xml")

        assertEquals(2, Regex("android:launchMode=\"singleTask\"").findAll(manifest).count())
        assertEquals(1, Regex("android:name=\"android.intent.action.VIEW\"").findAll(manifest).count())
        assertEquals(1, Regex("android:scheme=\"vortx\" android:host=\"open\"").findAll(manifest).count())
        assertTrue(manifest.contains("android:name=\".MainActivity\""))
        assertTrue(manifest.contains("android:name=\".ui.tv.TvActivity\""))
        assertTrue(manifest.contains("android:name=\".deeplink.DeepLinkActivity\""))
    }

    private fun readProjectFile(relativePath: String): String {
        val candidates = listOf(File(relativePath), File("app/$relativePath"), File("android/app/$relativePath"))
        return candidates.firstOrNull(File::isFile)?.readText()
            ?: error("Could not locate $relativePath from ${File(".").absolutePath}")
    }
}
