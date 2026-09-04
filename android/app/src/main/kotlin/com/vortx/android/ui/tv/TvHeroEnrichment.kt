package com.vortx.android.ui.tv

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import com.vortx.android.VortXApplication
import com.vortx.android.model.MetaDetail
import com.vortx.android.model.MetaItem
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay

/// Post-focus enrichment for the TV living-backdrop hero -- the Android parity twin of Apple
/// `SourcesTV/SharedUI.swift`'s `FocusedItemModel` (backdrop enrichment) + `HomeView.swift`'s
/// `HomeHeroTrailerModel` (trailer resolution). A catalog-preview [MetaItem] is sparse: the Home rails,
/// Discover grid, and Library grid all hand the hero a preview that usually carries no backdrop logo,
/// synopsis, rating, genres, OR trailer id. This composable fills those in AFTER focus settles, so the
/// focused item's hero reads like the detail page and its muted ambient trailer can actually play.
///
/// REUSE-ONLY (no new fetch/extractor): enrichment reads the meta through the EXISTING engine meta route
/// ([com.vortx.android.data.CatalogRepository.peekMeta] -> [MetaDetail]); the trailer id it surfaces
/// ([MetaDetail.trailerYouTubeId]) is threaded onto [MetaItem.trailerYouTubeId] so the hero's existing
/// [rememberHeroTrailerPlayable] -> [com.vortx.android.trailer.TrailerCoordinator] path lights up with no
/// new trailer fetch. Metahub art seeding for `tt` ids is a pure URL derivation (mirrors
/// [MetaDetail.placeholder]), not a network call.
///
/// SETTLE + FAIL-SOFT: keyed on the focused item id, so a D-pad move to another tile cancels the pending
/// enrichment before any engine round-trip fires (mirrors Apple's 150 ms focus dwell). A `peekMeta` miss
/// or error keeps the seeded item (never a crash, never a blank band). CancellationException is rethrown so
/// a focus move that cancels the effect stays cancelled (coroutine contract).

/// Focus dwell before the hero enriches, matching Apple `FocusedItemModel.focus`'s 150 ms settle: flicking
/// a rail catalog-to-catalog never fires an enrichment; only the tile the viewer lands on enriches.
internal const val HERO_ENRICH_DWELL_MS = 150L

/**
 * The preview fields that determine both whether enrichment is needed and whether an existing enrichment
 * still belongs to the focused preview.  A stable media id alone is not sufficient: catalog refreshes can
 * replace the art, synopsis, or trailer for that id while the D-pad remains on the same tile.
 */
internal data class HeroPreviewKey(
    val id: String,
    val type: String,
    val name: String,
    val poster: String?,
    val background: String?,
    val logo: String?,
    val description: String?,
    val imdbRating: String?,
    val genres: List<String>,
    val year: String?,
    val caption: String?,
    val trailerYouTubeId: String?,
)

internal fun MetaItem.heroPreviewKey(): HeroPreviewKey = HeroPreviewKey(
    id = id,
    type = type.name,
    name = name,
    poster = poster,
    background = background,
    logo = logo,
    description = description,
    imdbRating = imdbRating,
    genres = genres,
    year = year,
    caption = caption,
    trailerYouTubeId = trailerYouTubeId,
)

/** A hero is complete only when every field its visual/trailer surface consumes is already supplied. */
internal fun MetaItem.needsHeroEnrichment(): Boolean =
    background.isNullOrBlank() ||
        logo.isNullOrBlank() ||
        description.isNullOrBlank() ||
        imdbRating.isNullOrBlank() ||
        genres.isEmpty() ||
        year.isNullOrBlank() ||
        trailerYouTubeId.isNullOrBlank()

/// Metahub art base (mirrors Apple `SharedUI.metahubBackground` / [MetaDetail.placeholder]). Only `tt`
/// (IMDb) ids resolve here; every other id scheme (tmdb:/kitsu:/...) is left to the meta enrichment.
private const val METAHUB_BACKDROP_BASE = "https://images.metahub.space/background/big"

/// Enrich [item] for the hero band: seed a metahub backdrop instantly for a `tt` item that has none, then
/// (after the settle) merge the engine meta's richer backdrop, logo, synopsis, rating, genres, and trailer
/// id. Returns the best item known so far, so the hero paints art immediately and refines in place.
@Composable
internal fun rememberEnrichedHeroItem(item: MetaItem?): MetaItem? {
    val context = LocalContext.current
    val previewKey = item?.heroPreviewKey()
    val seeded = remember(previewKey) { item?.let(::seedHeroBackdrop) }
    var enriched by remember(previewKey) { mutableStateOf(seeded) }
    LaunchedEffect(previewKey) {
        enriched = seeded
        val current = seeded ?: return@LaunchedEffect
        // Do not confuse a synopsis + trailer with a complete hero.  The screen also consumes art, logo,
        // rating, genre, and year, and a catalog refresh can change any of them without changing the id.
        if (!current.needsHeroEnrichment()) return@LaunchedEffect
        delay(HERO_ENRICH_DWELL_MS)
        val repo = (context.applicationContext as? VortXApplication)?.catalogRepository ?: return@LaunchedEffect
        val detail = try {
            repo.peekMeta(current.type, current.id)
        } catch (cancellation: CancellationException) {
            throw cancellation
        } catch (_: Exception) {
            null
        }
        // The effect key already cancels on a focus move, so reaching here means focus still rests on this
        // item; merge the meta and publish the enriched hero.
        if (detail != null) enriched = current.mergedWith(detail)
    }
    return enriched
}

/// Seed a metahub backdrop on a `tt` preview that has no art yet, so the hero shows a cinematic backdrop the
/// instant focus lands instead of a brand-tinted placeholder. Only the backdrop is seeded, never the logo: a
/// metahub logo URL 404s for titles without a clearlogo, and the hero overlay would then show a blank image
/// instead of the title text -- the real logo (when it exists) arrives via [mergedWith] from the meta.
private fun seedHeroBackdrop(item: MetaItem): MetaItem {
    if (!item.background.isNullOrBlank()) return item
    if (!item.id.startsWith("tt")) return item
    return item.copy(background = "$METAHUB_BACKDROP_BASE/${item.id}/img")
}

/// Merge the engine meta detail over the preview: prefer the meta's richer values, falling back to the
/// preview's when the meta omits one. Fills the trailer id ([MetaDetail.trailerYouTubeId]) so the hero's
/// ambient trailer can resolve through the existing route.
private fun MetaItem.mergedWith(detail: MetaDetail): MetaItem = copy(
    background = detail.background ?: background,
    logo = detail.logo ?: logo,
    description = detail.description ?: description,
    imdbRating = detail.imdbRating ?: imdbRating,
    genres = detail.genres.ifEmpty { genres },
    year = detail.releaseInfo ?: year,
    trailerYouTubeId = detail.trailerYouTubeId ?: trailerYouTubeId,
)
