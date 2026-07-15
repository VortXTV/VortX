package com.vortx.android.ui.components

import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import com.vortx.android.model.Catalog
import com.vortx.android.model.MetaItem
import com.vortx.android.ui.theme.VortXGlass
import com.vortx.android.ui.theme.VortXShapes
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.theme.vortxGlass

/// [PosterCard]'s `art` slot for a real catalog item: a Coil [AsyncImage] with crossfade when
/// [posterUrl] is present, falling back to [DefaultPosterArt] (the deterministic brand-tinted
/// placeholder) when it's null -- an unloaded add-on preview, or a still-hydrating row. This is the
/// ONE place every poster/backdrop image request in the app goes through, so cache config and
/// crossfade behavior stay consistent call-site to call-site (see `VortXApplication`'s ImageLoader,
/// wired app-wide via Coil's `SingletonImageLoader.Factory` install in that class).
@Composable
fun BoxScope.PosterArt(posterUrl: String?, title: String) {
    if (posterUrl.isNullOrBlank()) {
        DefaultPosterArt(title)
    } else {
        AsyncImage(
            model = posterUrl,
            contentDescription = title,
            contentScale = ContentScale.Crop,
            modifier = Modifier.fillMaxSize(),
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

/// A titled horizontal rail of [PosterCard]s, the core building block of Home and Discover. [eyebrow]
/// adds the editorial kicker over the title (e.g. "Pick up where you left off" on Continue Watching).
@Composable
fun PosterRail(
    catalog: Catalog,
    onItem: (MetaItem) -> Unit,
    eyebrow: String? = null,
    modifier: Modifier = Modifier,
) {
    Column(modifier = modifier) {
        RailHeader(title = catalog.title, eyebrow = eyebrow)
        LazyRow(contentPadding = PaddingValues(horizontal = VortXTheme.spacing.edge)) {
            items(catalog.items, key = { it.id }) { item ->
                PosterCard(
                    title = item.name,
                    subtitle = listOfNotNull(item.year, item.type.label).joinToString(" · "),
                    onClick = { onItem(item) },
                    // Continue Watching items carry a watched fraction; the card draws its accent
                    // progress track for them (null on plain catalog items = no track).
                    progress = item.progress,
                    art = { PosterArt(item.poster, item.name) },
                    modifier = Modifier.width(124.dp).padding(end = VortXTheme.spacing.sm),
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
@Composable
fun Badge(text: String, modifier: Modifier = Modifier) {
    androidx.compose.material3.Text(
        text = text.uppercase(),
        style = VortXTheme.type.eyebrow.copy(color = VortXTheme.colors.textSecondary, fontWeight = FontWeight.SemiBold),
        modifier = modifier
            .vortxGlass(
                shape = VortXShapes.pill,
                fillAlpha = VortXGlass.badgeFillAlpha,
                shadow = VortXGlass.Shadow.flat,
            )
            .padding(horizontal = 10.dp, vertical = 4.dp),
    )
}
