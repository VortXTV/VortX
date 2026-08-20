package com.vortx.android.stats

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.BarChart
import androidx.compose.material.icons.filled.CalendarMonth
import androidx.compose.material.icons.filled.Layers
import androidx.compose.material.icons.filled.Movie
import androidx.compose.material.icons.filled.PieChart
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.Theaters
import androidx.compose.material.icons.filled.Tv
import androidx.compose.material.icons.filled.Whatshot
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import coil3.compose.AsyncImage
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXShapes
import com.vortx.android.ui.theme.VortXTheme
import java.util.Locale
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * Personal watch stats / year in review, reached from Settings. Everything it shows is computed READ
 * ONLY from the active profile's existing watch history by [WatchStatsModel]; this screen never marks,
 * resumes, or writes any watched state. The Android port of Apple `app/SourcesiOS/WatchStatsView.swift`.
 *
 * Editorial layout: a big headline number (hours watched) anchors the scope, a compact stat grid gives
 * the movie / series / episode split, then the longest binge, the top genres, and the most-watched
 * titles. A scope menu switches between all-time and any year present in the history.
 */
@Composable
fun WatchStatsScreen(onBack: () -> Unit, modifier: Modifier = Modifier) {
    BackHandler(onBack = onBack)
    val context = LocalContext.current
    val model = remember(context) { WatchStatsModel(context.applicationContext.filesDir) }
    val state by model.state.collectAsStateWithLifecycle()
    androidx.compose.runtime.LaunchedEffect(Unit) { model.load() }

    Column(modifier = modifier.fillMaxSize().background(VortXTheme.colors.canvas)) {
        Header(onBack = onBack)
        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(VortXTheme.spacing.edge),
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.lg),
        ) {
            ScopePicker(
                selectedYear = state.selectedYear,
                availableYears = state.availableYears,
                onSelect = model::selectYear,
            )
            val stats = state.stats
            when {
                state.isLoading && stats == null -> LoadingState()
                stats != null && stats.hasData -> {
                    Hero(stats)
                    StatGrid(stats)
                    stats.longestBinge?.let { BingeCard(it) }
                    if (stats.topGenres.isNotEmpty()) GenresCard(stats)
                    if (stats.topTitles.isNotEmpty()) MostWatchedCard(stats)
                }
                else -> EmptyState(selectedYear = state.selectedYear)
            }
        }
    }
}

// MARK: Header

@Composable
private fun Header(onBack: () -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(VortXTheme.spacing.edge),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconButton(onClick = onBack) {
            Icon(VortXIcons.back, contentDescription = "Back", tint = VortXTheme.colors.textPrimary)
        }
        Spacer(Modifier.width(VortXTheme.spacing.sm))
        Text("Watch Stats", style = VortXTheme.type.screenTitle)
    }
}

// MARK: Scope

@Composable
private fun ScopePicker(selectedYear: Int?, availableYears: List<Int>, onSelect: (Int?) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    val label = selectedYear?.toString() ?: "All time"
    Box {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs),
            modifier = Modifier
                .clip(VortXShapes.pill)
                .background(VortXTheme.colors.surface2)
                .clickable { expanded = true }
                .padding(horizontal = VortXTheme.spacing.sm, vertical = VortXTheme.spacing.xs),
        ) {
            Icon(
                StatIcons.calendar,
                contentDescription = null,
                tint = VortXTheme.colors.textPrimary,
                modifier = Modifier.size(16.dp),
            )
            Text(
                label,
                style = VortXTheme.type.label.copy(color = VortXTheme.colors.textPrimary, fontWeight = FontWeight.SemiBold),
            )
            Icon(
                VortXIcons.chevronDown,
                contentDescription = null,
                tint = VortXTheme.colors.textSecondary,
                modifier = Modifier.size(16.dp),
            )
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            DropdownMenuItem(
                text = { Text("All time") },
                onClick = { onSelect(null); expanded = false },
            )
            for (year in availableYears) {
                DropdownMenuItem(
                    text = { Text(year.toString()) },
                    onClick = { onSelect(year); expanded = false },
                )
            }
        }
    }
}

// MARK: Hero

@Composable
private fun Hero(stats: WatchStats) {
    Column(
        modifier = Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Text(
            stats.scopeLabel.uppercase(),
            style = VortXTheme.type.eyebrow.copy(color = VortXTheme.colors.accent),
        )
        Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs)) {
            Text(
                heroValue(stats.totalWatchSeconds),
                style = VortXTheme.type.hero,
                color = VortXTheme.colors.textPrimary,
                maxLines = 1,
            )
            Text(
                heroUnit(stats.totalWatchSeconds),
                style = VortXTheme.type.sectionTitle,
                color = VortXTheme.colors.textSecondary,
            )
        }
        Text(
            "watched across ${stats.titlesCount} ${if (stats.titlesCount == 1) "title" else "titles"}",
            style = VortXTheme.type.body,
            color = VortXTheme.colors.textSecondary,
        )
    }
}

// MARK: Stat grid

@Composable
private fun StatGrid(stats: WatchStats) {
    Column(verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
        Row(horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
            StatTile("${stats.moviesCount}", "Movies", StatIcons.movie, Modifier.weight(1f))
            StatTile("${stats.seriesCount}", "Series", StatIcons.series, Modifier.weight(1f))
        }
        Row(horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
            StatTile("${stats.episodesCount}", "Episodes", StatIcons.episodes, Modifier.weight(1f))
            StatTile(compactHM(stats.totalWatchSeconds), "Total time", StatIcons.clock, Modifier.weight(1f))
        }
    }
}

@Composable
private fun StatTile(value: String, label: String, icon: ImageVector, modifier: Modifier = Modifier) {
    Column(
        modifier = modifier
            .heightIn(min = 96.dp)
            .clip(VortXShapes.card)
            .background(VortXTheme.colors.surface1)
            .padding(VortXTheme.spacing.sm),
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs),
    ) {
        Icon(icon, contentDescription = null, tint = VortXTheme.colors.accent, modifier = Modifier.size(20.dp))
        Text(value, style = VortXTheme.type.screenTitle, color = VortXTheme.colors.textPrimary, maxLines = 1)
        Text(label, style = VortXTheme.type.label, color = VortXTheme.colors.textTertiary)
    }
}

// MARK: Longest binge

@Composable
private fun BingeCard(binge: BingeStat) {
    Card(title = "Longest Binge", icon = StatIcons.flame) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(
                    binge.name,
                    style = VortXTheme.type.sectionTitle,
                    color = VortXTheme.colors.textPrimary,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(bingeSubtitle(binge), style = VortXTheme.type.body, color = VortXTheme.colors.textSecondary)
            }
            Icon(
                if (binge.type == "series") StatIcons.series else StatIcons.movie,
                contentDescription = null,
                tint = VortXTheme.colors.accentSoft,
                modifier = Modifier.size(34.dp),
            )
        }
    }
}

// MARK: Top genres

@Composable
private fun GenresCard(stats: WatchStats) {
    val peak = stats.topGenres.maxOfOrNull { it.seconds } ?: 1.0
    Card(title = "Top Genres", icon = StatIcons.masks) {
        Column(verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
            for (genre in stats.topGenres) {
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(genre.name, style = VortXTheme.type.cardTitle, color = VortXTheme.colors.textPrimary)
                        Spacer(Modifier.weight(1f))
                        Text(compactHM(genre.seconds), style = VortXTheme.type.label, color = VortXTheme.colors.textSecondary)
                    }
                    StatBar(fraction = if (peak > 0.0) genre.seconds / peak else 0.0)
                }
            }
            if (stats.genreCoverage < stats.titlesCount) {
                Text(
                    "Based on the ${stats.genreCoverage} of ${stats.titlesCount} titles VortX has genre data for.",
                    style = VortXTheme.type.label,
                    color = VortXTheme.colors.textTertiary,
                    modifier = Modifier.padding(top = 2.dp),
                )
            }
        }
    }
}

/** A horizontal magnitude bar (track + accent fill) for the top-genres card. */
@Composable
private fun StatBar(fraction: Double) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(8.dp)
            .clip(VortXShapes.pill)
            .background(VortXTheme.colors.surface2),
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth(fraction.coerceIn(0.0, 1.0).toFloat())
                .fillMaxHeight()
                .clip(VortXShapes.pill)
                .background(VortXTheme.colors.accent),
        )
    }
}

// MARK: Most watched

@Composable
private fun MostWatchedCard(stats: WatchStats) {
    Card(title = "Most Watched", icon = StatIcons.chart) {
        Column {
            stats.topTitles.forEachIndexed { index, title ->
                if (index > 0) HorizontalDivider(color = VortXTheme.colors.hairline)
                MostWatchedRow(rank = index + 1, title = title)
            }
        }
    }
}

@Composable
private fun MostWatchedRow(rank: Int, title: TitleStat) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = VortXTheme.spacing.xs),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
    ) {
        Text(
            "$rank",
            style = VortXTheme.type.cardTitle.copy(fontWeight = FontWeight.Bold),
            color = VortXTheme.colors.textTertiary,
            modifier = Modifier.width(22.dp),
        )
        PosterThumb(title.poster)
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(
                title.name,
                style = VortXTheme.type.cardTitle,
                color = VortXTheme.colors.textPrimary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(rowSubtitle(title), style = VortXTheme.type.label, color = VortXTheme.colors.textTertiary)
        }
        Text(
            compactHM(title.seconds),
            style = VortXTheme.type.label.copy(fontWeight = FontWeight.SemiBold),
            color = VortXTheme.colors.accent,
        )
    }
}

/** A small poster thumbnail for the most-watched rows, with a neutral placeholder when the image is missing. */
@Composable
private fun PosterThumb(poster: String?) {
    Box(
        modifier = Modifier
            .size(width = 42.dp, height = 62.dp)
            .clip(RoundedCornerShape(8.dp))
            .background(VortXTheme.colors.surface2),
        contentAlignment = Alignment.Center,
    ) {
        if (poster.isNullOrBlank()) {
            Icon(StatIcons.movie, contentDescription = null, tint = VortXTheme.colors.textTertiary, modifier = Modifier.size(16.dp))
        } else {
            AsyncImage(
                model = poster,
                contentDescription = null,
                contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize(),
            )
        }
    }
}

// MARK: States

@Composable
private fun LoadingState() {
    Box(modifier = Modifier.fillMaxWidth().heightIn(min = 200.dp), contentAlignment = Alignment.Center) {
        CircularProgressIndicator(color = VortXTheme.colors.accent)
    }
}

@Composable
private fun EmptyState(selectedYear: Int?) {
    Column(
        modifier = Modifier.fillMaxWidth().heightIn(min = 240.dp).padding(VortXTheme.spacing.lg),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm, Alignment.CenterVertically),
    ) {
        Icon(StatIcons.pie, contentDescription = null, tint = VortXTheme.colors.textTertiary, modifier = Modifier.size(44.dp))
        Text("No watch history yet", style = VortXTheme.type.sectionTitle, color = VortXTheme.colors.textPrimary)
        Text(
            if (selectedYear == null) {
                "Watch something and your stats will show up here."
            } else {
                "Nothing watched in $selectedYear. Try another year."
            },
            style = VortXTheme.type.body,
            color = VortXTheme.colors.textSecondary,
        )
    }
}

// MARK: Card chrome

@Composable
private fun Card(title: String, icon: ImageVector, content: @Composable () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(VortXShapes.card)
            .background(VortXTheme.colors.surface1)
            .padding(VortXTheme.spacing.md),
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs)) {
            Icon(icon, contentDescription = null, tint = VortXTheme.colors.accent, modifier = Modifier.size(16.dp))
            Text(title.uppercase(), style = VortXTheme.type.eyebrow)
        }
        content()
    }
}

// MARK: Formatting

/**
 * The big headline number: hours when there is at least an hour (one decimal below 10h, whole above),
 * otherwise minutes. Pairs with [heroUnit].
 */
private fun heroValue(seconds: Double): String {
    val hours = seconds / 3600.0
    if (hours >= 1.0) {
        return if (hours >= 10.0) hours.roundToInt().toString() else String.format(Locale.US, "%.1f", hours)
    }
    return (seconds / 60.0).roundToInt().toString()
}

private fun heroUnit(seconds: Double): String = if (seconds >= 3600.0) "hours" else "minutes"

/** Compact "12h 30m" / "45m" / "0m" for a duration in seconds. */
private fun compactHM(seconds: Double): String {
    val total = seconds.roundToInt()
    val h = total / 3600
    val m = (total % 3600) / 60
    return if (h > 0) "${h}h ${m}m" else "${m}m"
}

private fun bingeSubtitle(binge: BingeStat): String {
    if (binge.episodes > 0) {
        return "${binge.episodes} ${if (binge.episodes == 1) "episode" else "episodes"} · ${compactHM(binge.seconds)}"
    }
    return compactHM(binge.seconds)
}

private fun rowSubtitle(title: TitleStat): String {
    if (title.type == "series") {
        return "${title.plays} ${if (title.plays == 1) "episode" else "episodes"}"
    }
    return if (title.plays > 1) "Movie · ${title.plays}×" else "Movie"
}

/**
 * The Watch Stats screen's local glyph set. Kept private to the feature (not added to the shared
 * [VortXIcons]) so this one screen's stat/section marks stay confined to it. Names mirror the SF Symbols
 * Apple's `WatchStatsView` uses, resolved to the closest Material Symbol.
 */
private object StatIcons {
    val calendar: ImageVector = Icons.Filled.CalendarMonth
    val movie: ImageVector = Icons.Filled.Movie              // SF `film`
    val series: ImageVector = Icons.Filled.Tv                // SF `tv`
    val episodes: ImageVector = Icons.Filled.Layers          // SF `rectangle.stack.fill`
    val clock: ImageVector = Icons.Filled.Schedule           // SF `clock`
    val flame: ImageVector = Icons.Filled.Whatshot           // SF `flame.fill`
    val masks: ImageVector = Icons.Filled.Theaters           // SF `theatermasks.fill`
    val chart: ImageVector = Icons.Filled.BarChart           // SF `chart.bar.fill`
    val pie: ImageVector = Icons.Filled.PieChart             // SF `chart.pie`
}
