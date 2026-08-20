package com.vortx.android.metadata

import android.content.Context
import androidx.compose.ui.graphics.Color

/**
 * Bundled, first-party brand marks for the "Streaming Services" tiles, the Kotlin port of Apple
 * `app/SourcesShared/ProviderBrandLogo.swift`. The owner rejected the TMDB-logo path (it fill-cropped badly
 * and, on a miss, collapsed to a single-letter placeholder), so real transparent-background brand PNGs are
 * bundled under `res/drawable-nodpi/brand_<slug>.png` and a mapped major ALWAYS renders its own logo
 * instantly, with NO network and NO letters.
 *
 * Two pieces mirror Apple so the phone and TV tile layers share one source of truth:
 *   - [bundledLogoName]: TMDB/JustWatch provider id -> logo slug, or null when we don't bundle a mark.
 *   - [drawableRes]: the `brand_<slug>` drawable resource id, or 0 when the PNG isn't present (name fallback).
 * Plus [brandStyle]: the per-provider full-bleed brand fill (top/bottom gradient + tintWhite) the tiles paint
 * behind the centered mark, the Apple TV look the owner asked for.
 */
object ProviderBrandLogo {

    /**
     * TMDB/JustWatch provider id -> bundled logo slug. Alias ids (Prime 9/119, Max 1899/384, Apple 2/350,
     * Discovery+ 520/524, Disney/Hotstar) all resolve to the same mark. Only ids we ship a PNG for appear.
     * Byte-identical to Apple `idToSlug`.
     */
    private val idToSlug: Map<Int, String> = mapOf(
        8 to "netflix",
        9 to "primevideo",
        119 to "primevideo",
        337 to "disneyplus",
        122 to "hotstar",
        2336 to "hotstar",
        1899 to "max",
        384 to "max",
        350 to "appletv",
        2 to "appletv",
        531 to "paramountplus",
        15 to "hulu",
        386 to "peacock",
        283 to "crunchyroll",
        520 to "discoveryplus",
        524 to "discoveryplus",
        43 to "starz",
        37 to "showtime",
        526 to "amcplus",
        73 to "tubi",
        300 to "plutotv",
        38 to "bbciplayer",
        11 to "mubi",
        344 to "viki",
        232 to "zee5",
        237 to "sonyliv",
    )

    /** The bundled logo slug for a provider, or null when we don't ship a mark (fall back to TMDB logoURL). */
    fun bundledLogoName(providerId: Int): String? = idToSlug[providerId]

    /** Whether we bundle a first-party logo for this provider (drives the "logo-first" tile branch). */
    fun hasBundledLogo(providerId: Int): Boolean = idToSlug.containsKey(providerId)

    /**
     * The `brand_<slug>` drawable resource id for a provider, or 0 when the provider has no slug or the PNG
     * is not bundled. 0 lets the caller fall back to the remote TMDB mark / full-name text (never a letter).
     */
    fun drawableRes(context: Context, providerId: Int): Int {
        val slug = idToSlug[providerId] ?: return 0
        return context.resources.getIdentifier("brand_$slug", "drawable", context.packageName)
    }

    /** Per-provider full-bleed brand fill, or null for a provider with no curated style. Apple `brandStyle`. */
    fun brandStyle(providerId: Int): BrandTileStyle? = brandStyles[providerId]

    private fun srgb(r: Int, g: Int, b: Int): Color = Color(red = r / 255f, green = g / 255f, blue = b / 255f)

    /**
     * Curated full-bleed brand fills keyed by TMDB/JustWatch provider id, byte-identical to Apple
     * `brandStyles`. `tintWhite` is true for every dark/saturated fill (the mark re-renders white); false
     * only where the mark keeps its natural color (Netflix red on white, Hulu green on black).
     */
    private val brandStyles: Map<Int, BrandTileStyle> = mapOf(
        8 to BrandTileStyle(srgb(255, 255, 255), srgb(255, 255, 255), false), // Netflix
        9 to BrandTileStyle(srgb(19, 153, 255), srgb(15, 121, 198), true),    // Prime Video
        119 to BrandTileStyle(srgb(19, 153, 255), srgb(15, 121, 198), true),  // Prime Video (alias)
        337 to BrandTileStyle(srgb(12, 22, 103), srgb(27, 44, 138), true),    // Disney+
        122 to BrandTileStyle(srgb(12, 22, 103), srgb(27, 44, 138), true),    // Disney+ Hotstar
        2336 to BrandTileStyle(srgb(12, 22, 103), srgb(27, 44, 138), true),   // JioHotstar (canonical)
        1899 to BrandTileStyle(srgb(10, 30, 220), srgb(59, 10, 160), true),   // Max
        384 to BrandTileStyle(srgb(10, 30, 220), srgb(59, 10, 160), true),    // HBO Max (alias)
        350 to BrandTileStyle(srgb(10, 10, 10), srgb(0, 0, 0), true),         // Apple TV+
        2 to BrandTileStyle(srgb(10, 10, 10), srgb(0, 0, 0), true),           // Apple TV (aliased to +)
        531 to BrandTileStyle(srgb(0, 100, 255), srgb(0, 71, 179), true),     // Paramount+
        15 to BrandTileStyle(srgb(11, 12, 15), srgb(11, 12, 15), false),      // Hulu (green mark on black)
        386 to BrandTileStyle(srgb(10, 10, 10), srgb(0, 0, 0), true),         // Peacock (black wordmark, tint to show)
        283 to BrandTileStyle(srgb(244, 117, 33), srgb(224, 100, 15), true),  // Crunchyroll
        520 to BrandTileStyle(srgb(11, 92, 214), srgb(10, 70, 168), true),    // Discovery+
        524 to BrandTileStyle(srgb(11, 92, 214), srgb(10, 70, 168), true),    // Discovery+ (alias)
        43 to BrandTileStyle(srgb(10, 10, 10), srgb(0, 0, 0), true),          // Starz
        37 to BrandTileStyle(srgb(200, 16, 46), srgb(142, 11, 32), true),     // Showtime
        526 to BrandTileStyle(srgb(10, 10, 10), srgb(0, 0, 0), true),         // AMC+
        73 to BrandTileStyle(srgb(122, 8, 250), srgb(90, 6, 189), true),      // Tubi
        300 to BrandTileStyle(srgb(10, 10, 10), srgb(0, 0, 0), true),         // Pluto TV (black wordmark, tint to show)
        38 to BrandTileStyle(srgb(255, 78, 152), srgb(214, 60, 124), true),   // BBC iPlayer
        11 to BrandTileStyle(srgb(10, 10, 10), srgb(0, 0, 0), true),          // MUBI
        344 to BrandTileStyle(srgb(18, 179, 227), srgb(14, 144, 182), true),  // Rakuten Viki
        232 to BrandTileStyle(srgb(140, 20, 140), srgb(90, 12, 96), true),    // ZEE5
        237 to BrandTileStyle(srgb(16, 16, 22), srgb(8, 8, 12), true),        // Sony LIV
        220 to BrandTileStyle(srgb(16, 16, 18), srgb(8, 8, 10), true),        // JioCinema
        121 to BrandTileStyle(srgb(60, 24, 120), srgb(40, 14, 84), true),     // Voot
        515 to BrandTileStyle(srgb(20, 20, 24), srgb(10, 10, 12), true),      // MX Player
        532 to BrandTileStyle(srgb(214, 30, 38), srgb(150, 18, 24), true),    // Aha
        218 to BrandTileStyle(srgb(16, 16, 20), srgb(8, 8, 10), true),        // Eros Now
        442 to BrandTileStyle(srgb(16, 16, 18), srgb(8, 8, 10), true),        // Lionsgate Play
    )
}

/**
 * The full-bleed brand fill for one streaming-service tile: a top->bottom gradient (top == bottom for a
 * solid) filling the whole rounded pill, plus whether the bundled logo re-renders white on top. Apple
 * `BrandTileStyle`.
 */
data class BrandTileStyle(
    val top: Color,
    val bottom: Color,
    val tintWhite: Boolean,
)
