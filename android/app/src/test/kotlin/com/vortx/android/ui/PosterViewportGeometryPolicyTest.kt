package com.vortx.android.ui

import com.vortx.android.ui.prefs.PosterStylePreferences
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PosterViewportGeometryPolicyTest {

    private val touchViewports = listOf(320f, 390f, 599f, 760f, 1024f)
    private val narrowTouchViewports = listOf(200f, 280f)
    private val tvViewports = listOf(1280f, 1600f, 1920f)

    @Test
    fun `touch matrix keeps portrait preset ladder and uses Apple measured landscape geometry`() {
        val preset = PosterStylePreferences.WidthPreset.BALANCED
        val expectedPortrait = mapOf(
            320f to 168f,
            390f to 168f,
            599f to 168f,
            760f to 224f,
            1024f to 224f,
        )
        val expectedLandscape = mapOf(
            320f to 134f,
            390f to 169f,
            599f to 273.5f,
            760f to 224f,
            1024f to 237f,
        )

        touchViewports.forEach { viewport ->
            val portrait = PosterViewportGeometryPolicy.resolve(
                viewport,
                preset,
                PosterViewportGeometryPolicy.Surface.TOUCH,
                PosterViewportGeometryPolicy.CardKind.CATALOG,
                landscape = false,
            )
            val landscapeCatalog = PosterViewportGeometryPolicy.resolve(
                viewport,
                preset,
                PosterViewportGeometryPolicy.Surface.TOUCH,
                PosterViewportGeometryPolicy.CardKind.CATALOG,
                landscape = true,
            )
            val landscapeContinueWatching = PosterViewportGeometryPolicy.resolve(
                viewport,
                preset,
                PosterViewportGeometryPolicy.Surface.TOUCH,
                PosterViewportGeometryPolicy.CardKind.CONTINUE_WATCHING,
                landscape = true,
            )

            assertEquals(expectedPortrait.getValue(viewport), portrait.cardWidth, 0.001f)
            assertEquals(expectedLandscape.getValue(viewport), landscapeCatalog.cardWidth, 0.001f)
            assertEquals(landscapeCatalog.cardWidth, landscapeContinueWatching.cardWidth, 0.001f)
            assertEquals(12f, landscapeCatalog.cardGap, 0.001f)
            assertTrue(landscapeContinueWatching.landscape)
            assertTrue(portrait.cardWidth <= portrait.contentWidth)
        }
    }

    @Test
    fun `regular continue watching keeps its identity and default card width`() {
        val catalog = PosterViewportGeometryPolicy.resolve(
            viewportWidth = 760f,
            widthPreset = PosterStylePreferences.WidthPreset.DEFAULT,
            surface = PosterViewportGeometryPolicy.Surface.TOUCH,
            cardKind = PosterViewportGeometryPolicy.CardKind.CATALOG,
            landscape = true,
        )
        val geometry = PosterViewportGeometryPolicy.resolve(
            viewportWidth = 760f,
            widthPreset = PosterStylePreferences.WidthPreset.DEFAULT,
            surface = PosterViewportGeometryPolicy.Surface.TOUCH,
            cardKind = PosterViewportGeometryPolicy.CardKind.CONTINUE_WATCHING,
            landscape = true,
        )

        assertEquals(224f, geometry.cardWidth, 0.001f)
        assertEquals(catalog.cardWidth, geometry.cardWidth, 0.001f)
        assertEquals(760f, geometry.viewportWidth, 0.001f)
        assertTrue(!geometry.compact)
        assertTrue(geometry.landscape)
    }

    @Test
    fun `explicit width presets survive compact regular and TV selection`() {
        val compact = PosterViewportGeometryPolicy.resolve(
            390f,
            PosterStylePreferences.WidthPreset.LARGE,
            PosterViewportGeometryPolicy.Surface.TOUCH,
            PosterViewportGeometryPolicy.CardKind.CATALOG,
            landscape = true,
        )
        val regular = PosterViewportGeometryPolicy.resolve(
            760f,
            PosterStylePreferences.WidthPreset.LARGE,
            PosterViewportGeometryPolicy.Surface.TOUCH,
            PosterViewportGeometryPolicy.CardKind.CATALOG,
            landscape = true,
        )
        val tv = PosterViewportGeometryPolicy.resolve(
            1280f,
            PosterStylePreferences.WidthPreset.LARGE,
            PosterViewportGeometryPolicy.Surface.TV,
            PosterViewportGeometryPolicy.CardKind.CATALOG,
        )

        assertEquals(200f, compact.cardWidth, 0.001f)
        assertEquals(320f, regular.cardWidth, 0.001f)
        assertEquals(286f, tv.cardWidth, 0.001f)
    }

    @Test
    fun `positive narrow measurements stay real and are bounded without safe minimum inflation`() {
        val expectedCardWidths = mapOf(200f to 160f, 280f to 168f)
        val expectedLandscapeCardWidths = mapOf(200f to 74f, 280f to 114f)

        narrowTouchViewports.forEach { viewport ->
            val geometry = PosterViewportGeometryPolicy.resolve(
                viewport,
                PosterStylePreferences.WidthPreset.DEFAULT,
                PosterViewportGeometryPolicy.Surface.TOUCH,
                PosterViewportGeometryPolicy.CardKind.CATALOG,
                landscape = false,
            )

            assertEquals(viewport, geometry.viewportWidth, 0.001f)
            assertEquals(expectedCardWidths.getValue(viewport), geometry.cardWidth, 0.001f)
            assertTrue(geometry.cardWidth <= geometry.contentWidth)

            val landscape = PosterViewportGeometryPolicy.resolve(
                viewport,
                PosterStylePreferences.WidthPreset.DEFAULT,
                PosterViewportGeometryPolicy.Surface.TOUCH,
                PosterViewportGeometryPolicy.CardKind.CONTINUE_WATCHING,
                landscape = true,
            )
            assertEquals(expectedLandscapeCardWidths.getValue(viewport), landscape.cardWidth, 0.001f)
            assertEquals(12f, landscape.cardGap, 0.001f)
        }

        val narrowTv = PosterViewportGeometryPolicy.resolve(
            viewportWidth = 400f,
            widthPreset = PosterStylePreferences.WidthPreset.DEFAULT,
            surface = PosterViewportGeometryPolicy.Surface.TV,
            cardKind = PosterViewportGeometryPolicy.CardKind.CONTINUE_WATCHING,
        )
        assertEquals(400f, narrowTv.viewportWidth, 0.001f)
        assertEquals(304f, narrowTv.contentWidth, 0.001f)
        assertEquals(304f, narrowTv.cardWidth, 0.001f)
    }

    @Test
    fun `TV cinematic continue watching uses Apple baseline across wide viewports`() {
        tvViewports.forEach { viewport ->
            val geometry = PosterViewportGeometryPolicy.resolve(
                viewport,
                PosterStylePreferences.WidthPreset.DEFAULT,
                PosterViewportGeometryPolicy.Surface.TV,
                PosterViewportGeometryPolicy.CardKind.CONTINUE_WATCHING,
            )

            assertEquals(390f, geometry.cardWidth, 0.001f)
            assertTrue(geometry.landscape)
            assertTrue(geometry.cardWidth <= geometry.contentWidth)
        }
    }

    @Test
    fun `invalid viewport measurements fail safe to a finite minimum`() {
        listOf(0f, -1f, Float.NaN, Float.POSITIVE_INFINITY, Float.NEGATIVE_INFINITY).forEach { value ->
            val geometry = PosterViewportGeometryPolicy.resolve(
                value,
                PosterStylePreferences.WidthPreset.DEFAULT,
                PosterViewportGeometryPolicy.Surface.TOUCH,
                PosterViewportGeometryPolicy.CardKind.CATALOG,
            )

            assertEquals(PosterViewportGeometryPolicy.SAFE_MIN_VIEWPORT_WIDTH, geometry.viewportWidth, 0.001f)
            assertTrue(geometry.cardWidth.isFinite())
            assertTrue(geometry.cardWidth > 0f)
            assertTrue(geometry.cardWidth <= geometry.contentWidth)
        }
    }

    @Test
    fun `all matrix cards remain inside their safe content region`() {
        val presets = PosterStylePreferences.WidthPreset.entries
        (narrowTouchViewports + touchViewports).forEach { viewport ->
            presets.forEach { preset ->
                listOf(
                    PosterViewportGeometryPolicy.CardKind.CATALOG,
                    PosterViewportGeometryPolicy.CardKind.CONTINUE_WATCHING,
                ).forEach { kind ->
                    val geometry = PosterViewportGeometryPolicy.resolve(
                        viewport,
                        preset,
                        PosterViewportGeometryPolicy.Surface.TOUCH,
                        kind,
                        landscape = kind == PosterViewportGeometryPolicy.CardKind.CONTINUE_WATCHING,
                    )
                    assertTrue(geometry.cardWidth <= geometry.contentWidth)
                }
            }
        }
        (listOf(400f) + tvViewports).forEach { viewport ->
            presets.forEach { preset ->
                listOf(
                    PosterViewportGeometryPolicy.CardKind.CATALOG,
                    PosterViewportGeometryPolicy.CardKind.CONTINUE_WATCHING,
                ).forEach { kind ->
                    val geometry = PosterViewportGeometryPolicy.resolve(
                        viewport,
                        preset,
                        PosterViewportGeometryPolicy.Surface.TV,
                        kind,
                        landscape = kind == PosterViewportGeometryPolicy.CardKind.CONTINUE_WATCHING,
                    )
                    assertTrue(geometry.cardWidth <= geometry.contentWidth)
                }
            }
        }
    }
}
