package com.vortx.android.ui.tv

import androidx.compose.ui.unit.dp
import com.vortx.android.ui.prefs.PosterStylePreferences
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class TvPosterLayoutPolicyTest {

    @Test
    fun `maps every shared poster style property to TV geometry`() {
        val layout = TvPosterLayoutPolicy.layout(
            PosterStylePreferences.State(
                width = PosterStylePreferences.WidthPreset.LARGE,
                radius = PosterStylePreferences.RadiusPreset.SUBTLE,
                landscape = true,
                hideLabels = true,
            ),
        )

        assertEquals(200.dp, layout.width)
        assertEquals(6.dp, layout.cornerRadius)
        assertEquals(16f / 9f, layout.aspectRatio)
        assertFalse(layout.showLabels)
    }

    @Test
    fun `portrait default preserves labels and portrait ratio`() {
        val layout = TvPosterLayoutPolicy.layout(PosterStylePreferences.State())

        assertEquals(168.dp, layout.width)
        assertEquals(16.dp, layout.cornerRadius)
        assertEquals(2f / 3f, layout.aspectRatio)
        assertTrue(layout.showLabels)
    }

    @Test
    fun `failed nonblank landscape backdrop falls back to poster art`() {
        assertEquals("https://art.example/backdrop.jpg", tvLandscapeBackdropUrl(" https://art.example/backdrop.jpg ", false))
        assertNull(tvLandscapeBackdropUrl("https://art.example/backdrop.jpg", true))
    }

    @Test
    fun `Upcoming grid uses the live poster layout width`() {
        val source = listOf(
            File("src/main/kotlin/com/vortx/android/ui/tv/TvUpcomingScreen.kt"),
            File("app/src/main/kotlin/com/vortx/android/ui/tv/TvUpcomingScreen.kt"),
            File("android/app/src/main/kotlin/com/vortx/android/ui/tv/TvUpcomingScreen.kt"),
        ).firstOrNull(File::isFile)?.readText() ?: error("Could not locate TvUpcomingScreen.kt")

        assertTrue(source.contains("val posterStyle by PosterStylePreferences.state.collectAsStateWithLifecycle()"))
        assertTrue(source.contains("columns = GridCells.Adaptive(minSize = layout.width)"))
    }
}
