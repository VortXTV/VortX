package com.stremiox.android.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.stremiox.android.model.Catalog
import com.stremiox.android.model.MetaItem

/// Eyebrow kicker + section title, the shared header for every rail — the same two-line editorial
/// header the tvOS `RailHeader` uses, so rows read with hierarchy, not a flat list of titles.
@Composable
fun RailHeader(title: String, eyebrow: String? = null, modifier: Modifier = Modifier) {
    Column(modifier = modifier.padding(start = 16.dp, bottom = 10.dp)) {
        if (eyebrow != null) {
            Text(
                text = eyebrow.uppercase(),
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.primary,
            )
        }
        Text(
            text = title,
            style = MaterialTheme.typography.titleLarge,
            color = MaterialTheme.colorScheme.onBackground,
        )
    }
}

/// A 2:3 poster. Until the engine supplies real poster URLs, each card renders a deterministic
/// brand-tinted gradient derived from the item id, so a rail of cards reads as intentional and
/// varied rather than a grid of identical gray boxes. When [MetaItem.poster] is wired, the gradient
/// becomes the load-time placeholder behind the image.
@Composable
fun PosterCard(item: MetaItem, onClick: () -> Unit, modifier: Modifier = Modifier) {
    Column(modifier = modifier.clickable(onClick = onClick)) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .aspectRatio(2f / 3f)
                .clip(RoundedCornerShape(12.dp))
                .background(posterBrush(item.id)),
        ) {
            Text(
                text = item.name,
                style = MaterialTheme.typography.titleMedium,
                color = Color.White.copy(alpha = 0.92f),
                maxLines = 3,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.align(Alignment.BottomStart).padding(10.dp),
            )
        }
        Text(
            text = listOfNotNull(item.year, item.type.label).joinToString(" · "),
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.padding(top = 6.dp, start = 2.dp),
        )
    }
}

/// A titled horizontal rail of posters, the core building block of Home and Discover. [eyebrow] adds
/// the editorial kicker over the title (e.g. "Pick up where you left off" on Continue Watching).
@Composable
fun PosterRail(
    catalog: Catalog,
    onItem: (MetaItem) -> Unit,
    eyebrow: String? = null,
    modifier: Modifier = Modifier,
) {
    Column(modifier = modifier) {
        RailHeader(title = catalog.title, eyebrow = eyebrow)
        LazyRow(contentPadding = PaddingValues(horizontal = 16.dp)) {
            items(catalog.items, key = { it.id }) { item ->
                PosterCard(
                    item = item,
                    onClick = { onItem(item) },
                    modifier = Modifier.width(124.dp).padding(end = 12.dp),
                )
            }
        }
    }
}

/// Skeleton rail shown while add-ons are still answering — calmer than a spinner, the same intent as
/// the tvOS `LoadingRail`. Placeholder cards use the surface tone, not the brand gradient, so they
/// read as "not yet loaded" rather than real content.
@Composable
fun LoadingRail(title: String = "Loading your library", modifier: Modifier = Modifier) {
    Column(modifier = modifier) {
        RailHeader(title = title)
        LazyRow(contentPadding = PaddingValues(horizontal = 16.dp)) {
            items(List(6) { it }) {
                Box(
                    modifier = Modifier
                        .width(124.dp)
                        .padding(end = 12.dp)
                        .aspectRatio(2f / 3f)
                        .clip(RoundedCornerShape(12.dp))
                        .background(MaterialTheme.colorScheme.surfaceVariant),
                )
            }
        }
    }
}

/// A small capsule label, e.g. the add-on name or a "TORRENT" tag on a source row — mirrors the
/// tvOS `badge`.
@Composable
fun Badge(text: String, modifier: Modifier = Modifier) {
    Text(
        text = text.uppercase(),
        style = MaterialTheme.typography.labelSmall.copy(fontWeight = FontWeight.SemiBold),
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = modifier
            .clip(RoundedCornerShape(50))
            .background(MaterialTheme.colorScheme.surfaceVariant)
            .padding(horizontal = 10.dp, vertical = 4.dp),
    )
}

/// Deterministic two-stop gradient from an id, biased toward the violet brand family so the whole
/// grid stays in one palette while every card differs.
private fun posterBrush(seed: String): Brush {
    val h = seed.hashCode()
    val hue = ((h ushr 8) % 80) - 20            // -20..60 around violet/blue/magenta
    val top = hsl(260f + hue, 0.42f, 0.34f)
    val bottom = hsl(260f + hue, 0.50f, 0.16f)
    return Brush.verticalGradient(listOf(top, bottom))
}

private fun hsl(hDeg: Float, s: Float, l: Float): Color {
    val h = ((hDeg % 360f) + 360f) % 360f
    val c = (1f - kotlin.math.abs(2 * l - 1f)) * s
    val x = c * (1f - kotlin.math.abs((h / 60f) % 2f - 1f))
    val m = l - c / 2f
    val (r, g, b) = when {
        h < 60f -> Triple(c, x, 0f)
        h < 120f -> Triple(x, c, 0f)
        h < 180f -> Triple(0f, c, x)
        h < 240f -> Triple(0f, x, c)
        h < 300f -> Triple(x, 0f, c)
        else -> Triple(c, 0f, x)
    }
    return Color(r + m, g + m, b + m)
}
