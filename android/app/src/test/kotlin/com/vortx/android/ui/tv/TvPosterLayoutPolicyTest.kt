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

        assertEquals(286.dp, layout.width)
        assertEquals(6.dp, layout.cornerRadius)
        assertEquals(16f / 9f, layout.aspectRatio)
        assertFalse(layout.showLabels)
    }

    @Test
    fun `portrait default preserves labels and portrait ratio`() {
        val layout = TvPosterLayoutPolicy.layout(PosterStylePreferences.State())

        assertEquals(200.dp, layout.width)
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

    @Test
    fun `continue watching uses the shared cinematic baseline and bounds narrow windows`() {
        assertEquals(390.dp, TvPosterLayoutPolicy.continueWatchingWidth(1280f))
        assertEquals(390.dp, TvPosterLayoutPolicy.continueWatchingWidth(1920f))
        assertEquals(224.dp, TvPosterLayoutPolicy.continueWatchingWidth(320f))
    }

    @Test
    fun `Library continue watching rail forwards its measured viewport to cinema cards`() {
        val source = sourceFile("TvCinemaCards.kt")
        val rail = source.substringAfter("fun TvContinueWatchingRail(")

        assertTrue(rail.contains("BoxWithConstraints(modifier = Modifier.fillMaxWidth())"))
        assertTrue(rail.contains("val viewportWidth = maxWidth.value"))
        assertTrue(rail.contains("TvCinemaCard("))
        assertTrue(rail.contains("viewportWidth = viewportWidth"))
        assertTrue(rail.contains("continueWatching = true"))
        assertFalse(rail.contains("PosterStylePreferences"))
        assertFalse(rail.contains("collectAsStateWithLifecycle"))
        assertFalse(rail.contains("width = TvPosterLayoutPolicy.layout("))
        assertFalse(rail.contains("width = 300.dp"))
    }

    @Test
    fun `Home catalog row measures viewport while preserving focus and row callbacks`() {
        val source = sourceFile("TvHomeScreen.kt")
        val row = source
            .substringAfter("private fun TvCatalogRow(")
            .substringBefore("private fun TvCatalogWall(")

        assertTrue(row.contains("BoxWithConstraints(modifier = Modifier.fillMaxWidth())"))
        assertTrue(row.contains("val viewportWidth = maxWidth.value"))
        assertTrue(row.contains("state = rowState"))
        assertTrue(row.contains("width = TvPosterLayoutPolicy.continueWatchingWidth(viewportWidth)"))
        assertTrue(row.contains("viewportWidth = viewportWidth"))
        assertTrue(row.contains("recovery?.key == focusKey"))
        assertTrue(row.contains("onFocused = { onFocused(item)"))
        assertTrue(row.contains("onRemoveFromContinueWatching"))
        assertFalse(row.contains("width = 300.dp"))
    }

    @Test
    fun `touch poster rail uses measured card width and policy gap`() {
        val source = sourceFile("Poster.kt")
        val rail = source
            .substringAfter("fun PosterRail(")
            .substringBefore("/// Skeleton rail")

        assertTrue(rail.contains("BoxWithConstraints(modifier = Modifier.fillMaxWidth())"))
        assertTrue(rail.contains("surface = PosterViewportGeometryPolicy.Surface.TOUCH"))
        assertTrue(rail.contains("landscape = posterStyle.landscape || cardKind == PosterViewportGeometryPolicy.CardKind.CONTINUE_WATCHING"))
        assertTrue(rail.contains("horizontalArrangement = Arrangement.spacedBy(geometry.cardGap.dp)"))
        assertTrue(rail.contains("modifier = Modifier.width(geometry.cardWidth.dp)"))
        assertFalse(rail.contains("padding(end = VortXTheme.spacing.sm)"))
        assertFalse(rail.contains("maxOf(240.dp)"))
    }

    private fun sourceFile(name: String): String = listOf(
        File("src/main/kotlin/com/vortx/android/ui/tv/$name"),
        File("app/src/main/kotlin/com/vortx/android/ui/tv/$name"),
        File("android/app/src/main/kotlin/com/vortx/android/ui/tv/$name"),
        File("app/src/main/kotlin/com/vortx/android/ui/components/$name"),
        File("android/app/src/main/kotlin/com/vortx/android/ui/components/$name"),
    ).firstOrNull(File::isFile)?.readText() ?: error("Could not locate $name")
}
