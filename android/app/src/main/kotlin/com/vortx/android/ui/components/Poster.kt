package com.vortx.android.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import coil3.compose.AsyncImage
import com.vortx.android.metadata.LocalizedMetadataStore
import com.vortx.android.metadata.PosterArtwork
import com.vortx.android.model.Catalog
import com.vortx.android.model.MetaItem
import com.vortx.android.ui.prefs.PosterStylePreferences
import com.vortx.android.ui.theme.VortXGlass
import com.vortx.android.ui.theme.VortXShapes
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.theme.vortxGlass

/// [PosterCard]'s `art` slot for a real catalog item: a Coil [AsyncImage] with crossfade when a poster
/// is present, falling back to [DefaultPosterArt] (the deterministic brand-tinted placeholder) when
/// it's null. This is the ONE place every poster image request in the app goes through, so cache
/// config and crossfade behavior stay consistent (see `VortXApplication`'s ImageLoader).
///
/// When [id] is supplied it routes the poster URL through [PosterArtwork] (the Kotlin port of Apple's
/// poster router): a localized-title poster override first (item 9, gated off for English), then the
/// baked-rating poster service (poster.vortx.tv / ERDB, default on) with the original art carried as
/// `fb=` for fail-soft. A [CardRatingBadge] is overlaid ONLY when the visible art is NOT itself baked
/// (a non-`tt`/`tmdb` id, or the feature off), so a baked poster is never double-badged.
@Composable
fun BoxScope.PosterArt(
    posterUrl: String?,
    title: String,
    id: String? = null,
    type: String = "movie",
    showRatingBadge: Boolean = true,
) {
    // Observe the localized-metadata store so a poster override that resolves after first paint re-renders.
    val l10nEntries by LocalizedMetadataStore.entries.collectAsStateWithLifecycle()
    val localizedPoster = remember(id, l10nEntries) { id?.let { LocalizedMetadataStore.poster(it) } }
    val base = localizedPoster ?: posterUrl
    val resolved = if (id != null) PosterArtwork.poster(id, base) else base

    if (resolved.isNullOrBlank()) {
        DefaultPosterArt(title)
    } else {
        AsyncImage(
            model = resolved,
            contentDescription = title,
            contentScale = ContentScale.Crop,
            modifier = Modifier.fillMaxSize(),
        )
    }
    // The rating badge sits over CLEAN art only: when the active provider will actually bake a rating onto
    // this id's poster, suppress it (no double badge). Placed top-start so it never collides with the
    // watched checkmark (top-end) or the Continue-Watching progress track (bottom).
    if (showRatingBadge && id != null && id.startsWith("tt")) {
        CardRatingBadge(
            id = id,
            type = type,
            active = !PosterArtwork.bakesRatings(forId = id),
            modifier = Modifier.align(Alignment.TopStart).padding(6.dp),
        )
    }
}

/// Eyebrow kicker + section title, the shared header for every rail (DESIGN-SYSTEM.md §2 typography
/// "eyebrow"/"section title" roles) — the same two-line editorial header the tvOS `RailHeader` uses,
/// so rows read with hierarchy, not a flat list of titles.
@Composable
fun RailHeader(title: String, eyebrow: String? = null, modifier: Modifier = Modifier) {
    Column(modifier = modifier.padding(start = VortXTheme.spacing.edge, bottom = VortXTheme.spacing.sm)) {
        if (eyebrow != null) {
            androidx.compose.material3.Text(text = eyebrow.uppercase(), style = VortXTheme.type.eyebrow)
        }
        androidx.compose.material3.Text(text = title, style = VortXTheme.type.sectionTitle)
    }
}

/// The Continue Watching rail's stable id (the repository's `homeSnapshot` contract: id =
/// "continue" is the CW rail, everything else is an add-on catalog row).
private const val CONTINUE_WATCHING_ROW_ID = "continue"

internal fun posterMenuFor(catalog: Catalog): PosterCardMenu = when {
    catalog.id == CONTINUE_WATCHING_ROW_ID && catalog.readOnly -> PosterCardMenu.NONE
    catalog.id == CONTINUE_WATCHING_ROW_ID -> PosterCardMenu.CONTINUE_WATCHING
    else -> PosterCardMenu.CATALOG
}

/// A titled horizontal rail of [PosterCard]s, the core building block of Home and Discover. [eyebrow]
/// adds the editorial kicker over the title (e.g. "Pick up where you left off" on Continue Watching).
@Composable
fun PosterRail(
    catalog: Catalog,
    onItem: (MetaItem) -> Unit,
    onRemoveFromContinueWatching: ((MetaItem) -> Unit)? = null,
    eyebrow: String? = null,
    onEndReached: (() -> Unit)? = null,
    modifier: Modifier = Modifier,
) {
    // Poster width preset (item 5): the rail card width follows the user's Poster Style choice (default
    // Balanced = 168dp), read live so a change re-lays out the rail. Also enqueue this page of ids for a
    // localized-metadata resolve (item 9), a cheap no-op for English / when the feature is off.
    val posterStyle by PosterStylePreferences.state.collectAsStateWithLifecycle()
    LaunchedEffect(catalog.items) {
        LocalizedMetadataStore.resolve(catalog.items.map { it.id })
    }
    Column(modifier = modifier) {
        RailHeader(title = catalog.title, eyebrow = eyebrow)
        LazyRow(contentPadding = PaddingValues(horizontal = VortXTheme.spacing.edge)) {
            itemsIndexed(catalog.items, key = { _, item -> "${item.type.name}|${item.id}" }) { index, item ->
                if (onEndReached != null && index == catalog.items.lastIndex) {
                    LaunchedEffect(catalog.engineIndex, catalog.items.size, item.type, item.id) {
                        onEndReached()
                    }
                }
                val menu = posterMenuFor(catalog)
                PosterCard(
                    title = item.name,
                    subtitle = item.caption ?: listOfNotNull(item.year, item.type.label).joinToString(" · "),
                    onClick = { onItem(item) },
                    // Continue Watching items carry a watched fraction; the card draws its accent
                    // progress track for them (null on plain catalog items = no track).
                    progress = item.progress,
                    watched = item.watched,
                    menuItem = item.takeIf { menu != PosterCardMenu.NONE },
                    menu = menu,
                    onDetails = if (menu == PosterCardMenu.CONTINUE_WATCHING) ({ onItem(item) }) else null,
                    onRemoveFromContinueWatching = if (
                        menu == PosterCardMenu.CONTINUE_WATCHING && onRemoveFromContinueWatching != null
                    ) ({ onRemoveFromContinueWatching(item) }) else null,
                    art = { PosterArt(item.poster, item.name, id = item.id, type = item.type.id) },
                    modifier = Modifier.width(posterStyle.width.compactWidth).padding(end = VortXTheme.spacing.sm),
                )
            }
        }
    }
}

/// Skeleton rail shown while add-ons are still answering — the shimmer loading state (DESIGN-SYSTEM.md
/// §3 "skeleton shimmer for loading, never a bare spinner as the whole state").
@Composable
fun LoadingRail(title: String = "Loading your library", modifier: Modifier = Modifier) {
    Column(modifier = modifier) {
        RailHeader(title = title)
        LazyRow(contentPadding = PaddingValues(horizontal = VortXTheme.spacing.edge)) {
            items(List(6) { it }) {
                androidx.compose.foundation.layout.Box(
                    modifier = Modifier
                        .width(124.dp)
                        .padding(end = VortXTheme.spacing.sm)
                        .aspectRatio(2f / 3f)
                        .clip(VortXShapes.card)
                        .shimmer(),
                )
            }
        }
    }
}

/// A small capsule label, e.g. the add-on name or a "TORRENT" tag on a source row: now the VortX glass
/// badge (warm translucent fill, lit top edge) rather than a flat `surface2` pill. It is chrome only,
/// used on source / episode rows and the sources list, NEVER painted over poster or backdrop art.
///
/// [prominent] carries meaning through an ember-accent fill + accent text (the cached / quality badge),
/// where a neutral badge (add-on name, TORRENT) stays warm glass -- the Android analogue of the Apple
/// source label's prominent-vs-neutral badge split.
@Composable
fun Badge(text: String, modifier: Modifier = Modifier, prominent: Boolean = false) {
    val accent = VortXTheme.colors.accent
    androidx.compose.material3.Text(
        text = text.uppercase(),
        style = VortXTheme.type.eyebrow.copy(
            color = if (prominent) accent else VortXTheme.colors.textSecondary,
            fontWeight = FontWeight.SemiBold,
        ),
        modifier = modifier
            .then(
                if (prominent) {
                    Modifier.background(accent.copy(alpha = 0.22f), VortXShapes.pill)
                } else {
                    Modifier.vortxGlass(
                        shape = VortXShapes.pill,
                        fillAlpha = VortXGlass.badgeFillAlpha,
                        shadow = VortXGlass.Shadow.flat,
                    )
                },
            )
            .padding(horizontal = 10.dp, vertical = 4.dp),
    )
}
