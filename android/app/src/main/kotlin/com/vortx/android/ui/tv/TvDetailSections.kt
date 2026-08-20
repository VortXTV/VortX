package com.vortx.android.ui.tv

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.tv.material3.Border
import androidx.tv.material3.ClickableSurfaceDefaults
import androidx.tv.material3.ExperimentalTvMaterial3Api
import androidx.tv.material3.Surface
import coil3.compose.AsyncImage
import com.vortx.android.model.Episode
import com.vortx.android.model.MetaDetail
import com.vortx.android.model.MetaItem
import com.vortx.android.person.CastMember
import com.vortx.android.person.PersonSeed
import com.vortx.android.ui.screens.PersonScreen
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXShapes
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.viewmodel.PersonViewModel

/// The 10-foot season picker + episode browser for the TV Detail page, the couch analogue of the phone
/// `DetailScreen`'s `SeasonSelector` + `EpisodeRow` list and the mirror of Apple `app/SourcesTV/DetailView`.
/// It renders OVER the SAME [com.vortx.android.ui.viewmodel.DetailViewModel] the phone drives -- the season
/// list is the ViewModel's `selectedSeason`, choosing a season calls [onSelectSeason]
/// ([DetailViewModel.selectSeason]) and choosing an episode calls [onSelectEpisode]
/// ([DetailViewModel.selectEpisode]), so the hero Watch/Resume button and the source list retarget to that
/// episode exactly as they do on the phone.
///
/// PER-PROFILE HISTORY: the per-episode and per-season watched toggles route straight into
/// [onToggleWatched]/[onMarkSeasonWatched] ([DetailViewModel.setVideoWatched]/[setSeasonWatched]), which write
/// through the SAME `CatalogRepository` seam the phone uses. That seam is where the main-profile-via-engine /
/// overlay-profile-via-local-overlay split is enforced (`EngineStremioRepository.overlayProfiles()`); this UI
/// never touches history directly, so an overlay profile can never mutate the account library from the couch.
@Composable
fun TvSeasonEpisodeSection(
    detail: MetaDetail,
    selectedSeason: Int?,
    selectedEpisodeId: String?,
    onSelectSeason: (Int) -> Unit,
    onSelectEpisode: (String) -> Unit,
    onToggleWatched: (Episode, Boolean) -> Unit,
    onMarkSeasonWatched: (Int, Boolean) -> Unit,
) {
    val seasons = remember(detail.videos) {
        detail.videos.map { it.season }.distinct().sorted()
    }
    val activeSeason = selectedSeason ?: seasons.firstOrNull() ?: detail.videos.firstOrNull()?.season ?: 1
    val episodes = remember(detail.videos, activeSeason) {
        detail.videos.filter { it.season == activeSeason }.sortedBy { it.episode }
    }
    val seasonAllWatched = episodes.isNotEmpty() && episodes.all { it.id in detail.watchedVideoIds }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = TvDimens.rowGap),
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
    ) {
        Text(
            text = "Episodes",
            style = VortXTheme.type.sectionTitle,
            modifier = Modifier.padding(horizontal = TvDimens.edge),
        )

        if (seasons.size > 1) {
            LazyRow(
                contentPadding = PaddingValues(horizontal = TvDimens.edge),
                horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
            ) {
                items(seasons, key = { it }) { season ->
                    TvFilterChip(
                        label = if (season > 0) "Season $season" else "Specials",
                        selected = season == activeSeason,
                        onClick = { onSelectSeason(season) },
                    )
                }
            }
        }

        // Bulk mark-the-season control (mirrors the phone SeasonSelector's season-level toggle).
        if (episodes.isNotEmpty()) {
            Row(modifier = Modifier.padding(horizontal = TvDimens.edge)) {
                TvFilterChip(
                    label = if (seasonAllWatched) "Mark season unwatched" else "Mark season watched",
                    selected = false,
                    onClick = { onMarkSeasonWatched(activeSeason, !seasonAllWatched) },
                )
            }
        }

        LazyRow(
            contentPadding = PaddingValues(horizontal = TvDimens.edge),
            horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
        ) {
            itemsIndexed(episodes, key = { _, ep -> ep.id }) { _, episode ->
                val watched = episode.id in detail.watchedVideoIds
                TvEpisodeCard(
                    episode = episode,
                    watched = watched,
                    isCurrent = episode.id == selectedEpisodeId,
                    onSelect = { onSelectEpisode(episode.id) },
                    onToggleWatched = { onToggleWatched(episode, !watched) },
                )
            }
        }
    }
}

/// One episode as a focusable card + its own watched toggle, a horizontal-rail card the couch analogue of the
/// phone `EpisodeRow`. Selecting the card retargets the ViewModel to this episode; the toggle beneath it is a
/// second D-pad target that marks it watched/unwatched. [isCurrent] rings the episode whose sources are shown
/// in the hero above, so "what Watch/Resume will play" stays legible while browsing the season.
@OptIn(ExperimentalTvMaterial3Api::class)
@Composable
private fun TvEpisodeCard(
    episode: Episode,
    watched: Boolean,
    isCurrent: Boolean,
    onSelect: () -> Unit,
    onToggleWatched: () -> Unit,
) {
    val colors = VortXTheme.colors
    Column(
        modifier = Modifier.width(288.dp),
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs),
    ) {
        Surface(
            onClick = onSelect,
            modifier = Modifier.fillMaxWidth(),
            shape = ClickableSurfaceDefaults.shape(shape = VortXShapes.card),
            colors = ClickableSurfaceDefaults.colors(
                containerColor = colors.surface1,
                contentColor = colors.textPrimary,
                focusedContainerColor = colors.surface3,
                focusedContentColor = colors.textPrimary,
            ),
            scale = ClickableSurfaceDefaults.scale(focusedScale = 1.04f),
            border = ClickableSurfaceDefaults.border(
                focusedBorder = Border(
                    border = BorderStroke(TvDimens.focusBorder, colors.accentBright),
                    shape = VortXShapes.card,
                ),
            ),
        ) {
            Column {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(162.dp)
                        .clip(VortXShapes.card)
                        .background(colors.surface2),
                ) {
                    if (!episode.thumbnail.isNullOrBlank()) {
                        AsyncImage(
                            model = episode.thumbnail,
                            contentDescription = null,
                            contentScale = ContentScale.Crop,
                            modifier = Modifier.fillMaxSize(),
                        )
                    }
                    if (watched) {
                        Box(modifier = Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.45f)))
                        Icon(
                            imageVector = VortXIcons.checkmarkCircle,
                            contentDescription = "Watched",
                            tint = colors.accentBright,
                            modifier = Modifier.align(Alignment.TopEnd).padding(8.dp).size(24.dp),
                        )
                    }
                    if (isCurrent) {
                        Box(
                            modifier = Modifier
                                .align(Alignment.BottomStart)
                                .padding(8.dp)
                                .clip(VortXShapes.pill)
                                .background(colors.accent)
                                .padding(horizontal = 10.dp, vertical = 2.dp),
                        ) {
                            Text(
                                text = "Selected",
                                style = VortXTheme.type.eyebrow.copy(color = colors.onAccent),
                            )
                        }
                    }
                }
                Column(modifier = Modifier.padding(horizontal = 14.dp, vertical = 12.dp)) {
                    Text(
                        text = episodeCode(episode),
                        style = VortXTheme.type.label.copy(color = colors.textSecondary),
                    )
                    Text(
                        text = episode.title,
                        style = VortXTheme.type.body.copy(fontWeight = FontWeight.SemiBold),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.padding(top = 2.dp),
                    )
                    episode.overview?.takeIf { it.isNotBlank() }?.let {
                        Text(
                            text = it,
                            style = VortXTheme.type.label.copy(color = colors.textTertiary),
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.padding(top = 4.dp),
                        )
                    }
                }
            }
        }
        TvFilterChip(
            label = if (watched) "Watched" else "Mark watched",
            selected = watched,
            onClick = onToggleWatched,
        )
    }
}

/// "S2 · E5" / "Episode 5", numeric and not localized (episode numbering is universal), matching the phone
/// `EpisodeRow`'s code line.
private fun episodeCode(episode: Episode): String =
    if (episode.season > 0) "S${episode.season} · E${episode.episode}" else "Episode ${episode.episode}"

/// The 10-foot Cast & Crew rail, the couch analogue of the phone `DetailScreen`'s `CreditsSection` +
/// `CastRail` and the mirror of Apple `app/SourcesTV/DetailView`'s cast row. [castMembers] is the SAME
/// keyless, signed TMDB credits path the phone detail screen fetches view-locally
/// ([com.vortx.android.person.TMDBPersonClient.credits]); a tappable tile (a real TMDB person id) hands a
/// [PersonSeed] up through [onPersonTap] so the caller can push the Person page. When TMDB has not resolved
/// (no `tt` id / edge miss) it falls back to the meta's plain-name cast/crew lines, exactly as the phone does.
@Composable
fun TvCastCreditsSection(
    detail: MetaDetail,
    castMembers: List<CastMember>,
    onPersonTap: (PersonSeed) -> Unit,
) {
    val hasAny = castMembers.isNotEmpty() || detail.cast.isNotEmpty() ||
        detail.directors.isNotEmpty() || detail.writers.isNotEmpty()
    if (!hasAny) return

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = TvDimens.rowGap, bottom = TvDimens.edge),
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
    ) {
        Text(
            text = "Cast & Crew",
            style = VortXTheme.type.sectionTitle,
            modifier = Modifier.padding(horizontal = TvDimens.edge),
        )
        if (castMembers.isNotEmpty()) {
            LazyRow(
                contentPadding = PaddingValues(horizontal = TvDimens.edge),
                horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
            ) {
                items(castMembers) { member ->
                    TvCastTile(
                        member = member,
                        onTap = if (member.isTappable) {
                            { onPersonTap(PersonSeed(member.id, member.name, member.profileUrl)) }
                        } else {
                            null
                        },
                    )
                }
            }
        } else {
            Column(
                modifier = Modifier.padding(horizontal = TvDimens.edge),
                verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs),
            ) {
                detail.cast.takeIf { it.isNotEmpty() }?.let { TvCreditLine("Cast", it) }
                detail.directors.takeIf { it.isNotEmpty() }?.let { TvCreditLine("Director", it) }
                detail.writers.takeIf { it.isNotEmpty() }?.let { TvCreditLine("Writer", it) }
            }
        }
    }
}

/// One cast entry: a circular headshot (initials-disc fallback), the name, and the character beneath,
/// mirroring the phone `CastTile`. A focusable tv `Surface` only when [onTap] is non-null (a real TMDB person
/// id); a name-only entry is a plain, non-focusable tile with nothing to look up.
@OptIn(ExperimentalTvMaterial3Api::class)
@Composable
private fun TvCastTile(member: CastMember, onTap: (() -> Unit)?) {
    val colors = VortXTheme.colors
    val body: @Composable () -> Unit = {
        Column(
            modifier = Modifier.width(140.dp).padding(vertical = 10.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs),
        ) {
            Box(
                modifier = Modifier.size(96.dp).clip(CircleShape).background(colors.surface2),
                contentAlignment = Alignment.Center,
            ) {
                if (member.profileUrl.isNullOrBlank()) {
                    Text(
                        text = castInitials(member.name),
                        style = VortXTheme.type.sectionTitle.copy(color = colors.textTertiary),
                    )
                } else {
                    AsyncImage(
                        model = member.profileUrl,
                        contentDescription = member.name,
                        contentScale = ContentScale.Crop,
                        modifier = Modifier.fillMaxSize(),
                    )
                }
            }
            Text(
                text = member.name,
                style = VortXTheme.type.label.copy(fontWeight = FontWeight.SemiBold),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            member.character?.takeIf { it.isNotBlank() }?.let {
                Text(
                    text = it,
                    style = VortXTheme.type.eyebrow.copy(color = colors.textTertiary),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
    if (onTap == null) {
        body()
    } else {
        Surface(
            onClick = onTap,
            shape = ClickableSurfaceDefaults.shape(shape = VortXShapes.card),
            colors = ClickableSurfaceDefaults.colors(
                containerColor = Color.Transparent,
                contentColor = colors.textPrimary,
                focusedContainerColor = colors.surface3,
                focusedContentColor = colors.textPrimary,
            ),
            scale = ClickableSurfaceDefaults.scale(focusedScale = 1.06f),
            border = ClickableSurfaceDefaults.border(
                focusedBorder = Border(
                    border = BorderStroke(TvDimens.focusBorder, colors.accentBright),
                    shape = VortXShapes.card,
                ),
            ),
        ) {
            body()
        }
    }
}

/// A "Director: A, B" style credit line for the plain-name fallback, mirroring the phone `CreditLine`.
@Composable
private fun TvCreditLine(role: String, names: List<String>) {
    val colors = VortXTheme.colors
    Row(horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs)) {
        Text(
            text = "$role:",
            style = VortXTheme.type.label.copy(color = colors.textTertiary, fontWeight = FontWeight.SemiBold),
        )
        Text(
            text = names.joinToString(", "),
            style = VortXTheme.type.label.copy(color = colors.textSecondary),
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

private fun castInitials(name: String): String =
    name.split(" ").filter { it.isNotBlank() }.take(2).mapNotNull { it.firstOrNull()?.uppercase() }.joinToString("")

/// The Person page hosted as a detail-local overlay on TV, reusing the SAME phone
/// [com.vortx.android.ui.screens.PersonScreen] and [PersonViewModel] (the keyless TMDB person + filmography
/// path). Keyed per person id so an actor -> co-star walk gets a fresh instance. [onOpenTitle] hands a
/// resolved filmography title back up so the caller can open it as a new detail.
@Composable
fun TvPersonOverlay(seed: PersonSeed, onOpenTitle: (MetaItem) -> Unit, onBack: () -> Unit) {
    val personVm: PersonViewModel = viewModel(
        key = "tv-person-${seed.id}",
        factory = PersonViewModel.Factory(seed.id),
    )
    Box(modifier = Modifier.fillMaxSize().background(VortXTheme.colors.canvas)) {
        PersonScreen(
            viewModel = personVm,
            seed = seed,
            onBack = onBack,
            onOpenTitle = onOpenTitle,
        )
    }
}
