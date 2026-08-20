package com.vortx.android.ui.tv

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import com.vortx.android.catalog.WatchProvider
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import com.vortx.android.ratings.MdbListRatings
import com.vortx.android.ui.theme.VortXShapes
import com.vortx.android.ui.theme.VortXTheme

/// The 10-foot detail-breadth rails for the TV Detail page, the couch analogue of the phone
/// [com.vortx.android.ui.screens.DetailScreen]'s `RatingsRow`, `WhereToWatchRail`, and `SimilarRail`, and the
/// mirror of Apple `app/SourcesTV/DetailView.swift`'s ratings row, `whereToWatchSection`, and
/// `moreLikeThisSection`. Every rail here is driven by the SAME keyless, edge-signed phone clients the phone
/// detail screen fetches view-locally -- `VortXRatingsClient` -> [MdbListRatings], `WatchProvidersClient` ->
/// [WatchProvider], and `SimilarClient` -> [MetaItem] -- so there is no second data path; this file is purely
/// the couch RENDERING of that already-built breadth.

/// Whether a title has the kind of metadata these rails need: live content (a channel / TV type) carries no
/// TMDB recommendations or watch providers, so the More Like This and Where to Watch rails are gated off it,
/// mirroring the phone `isLiveType` / Apple's `LiveTypes` guard.
fun tvIsLiveType(type: MediaType): Boolean = type == MediaType.CHANNEL || type == MediaType.TV

/// The VortX cross-provider ratings token strip: Rotten Tomatoes / Metacritic / TMDB critic scores from the
/// keyless `VortXRatingsClient`, as compact score tokens. IMDb already shows in the hero meta line, so this
/// surfaces the three critic providers the engine meta does not carry, mirroring the phone `RatingsRow`. The
/// caller renders it only when [MdbListRatings.hasAny], so it never leaves an empty strip.
@Composable
fun TvRatingsStrip(ratings: MdbListRatings, modifier: Modifier = Modifier) {
    Row(
        modifier = modifier,
        horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xl),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        ratings.rottenTomatoes?.let { TvRatingToken("Rotten Tomatoes", "$it%") }
        ratings.metacritic?.let { TvRatingToken("Metacritic", it.toString()) }
        ratings.tmdb?.let { TvRatingToken("TMDB", "$it%") }
    }
}

/// One provider score token: the emphasized value over its muted provider label (the phone `RatingBadge`).
@Composable
private fun TvRatingToken(label: String, value: String) {
    val colors = VortXTheme.colors
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(
            text = value,
            style = VortXTheme.type.sectionTitle.copy(
                color = colors.textPrimary,
                fontWeight = FontWeight.SemiBold,
            ),
        )
        Text(text = label, style = VortXTheme.type.eyebrow.copy(color = colors.textTertiary))
    }
}

/// "Where to Watch": a horizontal rail of legal region streaming providers (TMDB watch/providers off the
/// keyless edge, via `WatchProvidersClient`). Each dark brand mark sits on a warm near-white plate so it stays
/// legible on the app's dark chrome, mirroring the phone `WhereToWatchRail` / Apple's plate treatment.
/// Informational (no navigation target), so the tiles are plain non-focusable panels; the caller already
/// dropped an empty list, so this always has providers to show.
@Composable
fun TvWhereToWatchRail(providers: List<WatchProvider>, modifier: Modifier = Modifier) {
    val colors = VortXTheme.colors
    Column(
        modifier = modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
    ) {
        Text(
            text = "Where to Watch",
            style = VortXTheme.type.sectionTitle,
            modifier = Modifier.padding(horizontal = TvDimens.edge),
        )
        LazyRow(
            contentPadding = PaddingValues(horizontal = TvDimens.edge),
            horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
        ) {
            items(providers, key = { it.name }) { provider ->
                Column(
                    modifier = Modifier.width(96.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Box(
                        modifier = Modifier
                            .size(72.dp)
                            .clip(VortXShapes.control)
                            .background(TV_WATCH_PROVIDER_PLATE),
                        contentAlignment = Alignment.Center,
                    ) {
                        if (!provider.logoUrl.isNullOrBlank()) {
                            AsyncImage(
                                model = provider.logoUrl,
                                contentDescription = provider.name,
                                contentScale = ContentScale.Fit,
                                modifier = Modifier.fillMaxSize().padding(8.dp),
                            )
                        } else {
                            Text(
                                text = tvProviderInitials(provider.name),
                                style = VortXTheme.type.sectionTitle.copy(color = Color(0xFF1A1712)),
                            )
                        }
                    }
                    Text(
                        text = provider.name,
                        style = VortXTheme.type.label.copy(color = colors.textTertiary),
                        textAlign = TextAlign.Center,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        }
    }
}

/// The warm near-white plate behind a Where-to-Watch provider mark: TMDB provider logos are dark / brand-hued
/// app icons that read as "very dark" on the app's dark chrome, so each sits on a light plate to stay legible,
/// the Android analogue of the phone `WATCH_PROVIDER_PLATE` / Apple's `BundledLogo.plateFill`.
private val TV_WATCH_PROVIDER_PLATE = Color(0xFFF3F0EA)

private fun tvProviderInitials(name: String): String =
    name.split(" ").filter { it.isNotBlank() }.take(2).mapNotNull { it.firstOrNull()?.uppercase() }.joinToString("")

/// "More Like This": a horizontal rail of related-title poster tiles (TMDB recommendations off the keyless
/// edge, via `SimilarClient`), each a focusable [TvPosterCard] that opens the title through [onOpen]. Mirrors
/// the phone `SimilarRail` / Apple's `moreLikeThisSection`; the caller resolves the tile's `tmdb:` id to a
/// `tt` id before opening (the same fail-soft resolve the phone screen does) and already dropped an empty
/// list, so this always has tiles to show. Reuses the SAME [TvPosterCard] tile every TV rail uses.
@Composable
fun TvSimilarRail(
    type: MediaType,
    titles: List<MetaItem>,
    onOpen: (MetaItem) -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
    ) {
        Column(modifier = Modifier.padding(horizontal = TvDimens.edge)) {
            Text(
                text = (if (type == MediaType.SERIES) "Similar Series" else "Similar Movies").uppercase(),
                style = VortXTheme.type.eyebrow,
            )
            Text(text = "More Like This", style = VortXTheme.type.sectionTitle)
        }
        LazyRow(
            contentPadding = PaddingValues(horizontal = TvDimens.edge),
            horizontalArrangement = Arrangement.spacedBy(TvDimens.cardGap),
        ) {
            // No item key: TMDB ids are effectively unique here, but keying by a possibly-repeated id risks
            // the duplicate-key crash the grid screens guard against, and this list is static per title.
            items(titles) { item ->
                TvPosterCard(item = item, onClick = { onOpen(item) }, onFocused = {})
            }
        }
    }
}
