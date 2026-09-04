package com.vortx.android.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material3.Button
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import coil3.compose.AsyncImage
import com.vortx.android.VortXApplication
import com.vortx.android.model.Catalog
import com.vortx.android.model.MetaItem
import com.vortx.android.profile.LastStreamStore
import com.vortx.android.home.CollectionsHubSnapshot
import com.vortx.android.home.TOP_PICKS_CATALOG_ID
import com.vortx.android.home.SIMKL_WATCHLIST_CATALOG_ID
import com.vortx.android.home.TRAKT_WATCHLIST_CATALOG_ID
import com.vortx.android.home.UPCOMING_EPISODES_CATALOG_ID
import com.vortx.android.home.UPCOMING_MOVIES_CATALOG_ID
import com.vortx.android.home.HomeRail
import com.vortx.android.ui.home.PhoneHeroPolicy
import com.vortx.android.ui.home.PhoneHeroRequest
import com.vortx.android.ui.HomeRowItem
import com.vortx.android.ui.UiState
import com.vortx.android.ui.collectionsHubSlot
import com.vortx.android.ui.homeRowKey
import com.vortx.android.ui.homeRowsWithHub
import com.vortx.android.ui.normalizeHomeCatalogs
import com.vortx.android.ui.components.EmptyState
import com.vortx.android.ui.components.ErrorState
import com.vortx.android.ui.components.CollectionsBrowseScreen
import com.vortx.android.ui.components.CollectionsHub
import com.vortx.android.ui.components.LoadingRail
import com.vortx.android.ui.components.PosterRail
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.theme.rememberReducedMotion
import com.vortx.android.ui.viewmodel.HomeViewModel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay

/// Home: a featured hero (the first Continue Watching / Popular item) over the add-on catalog rails,
/// the same composition the iOS and Apple TV apps lead with (DESIGN-SYSTEM.md §4 "Home"). Driven by
/// [HomeViewModel] so loading and error are first-class states, not an empty screen.
@Composable
fun HomeScreen(
    viewModel: HomeViewModel,
    onItem: (MetaItem) -> Unit,
    modifier: Modifier = Modifier,
    onDirectResume: (MetaItem) -> Unit = onItem,
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val collections by viewModel.collections.collectAsStateWithLifecycle()
    val collectionBrowse by viewModel.collectionBrowse.collectAsStateWithLifecycle()
    val hubOrder by viewModel.collectionsHubOrder.collectAsStateWithLifecycle()
    val hubHidden by viewModel.collectionsHubHidden.collectAsStateWithLifecycle()
    val appContext = LocalContext.current.applicationContext
    val lastStreamStore = remember(appContext) { LastStreamStore(appContext) }

    if (collectionBrowse.target != null) {
        CollectionsBrowseScreen(
            state = collectionBrowse,
            onBack = viewModel::closeCollection,
            onItem = onItem,
            onCategory = viewModel::selectCollectionCategory,
            onRetry = viewModel::retryCollection,
            onLoadMore = viewModel::loadMoreCollection,
            modifier = modifier,
        )
        return
    }

    when (val s = state) {
        is UiState.Loading -> LoadingColumn(modifier)
        is UiState.Error -> ErrorState(s.message, onRetry = viewModel::load, modifier = modifier)
        is UiState.Success ->
            // Belt-and-braces: the ViewModel never publishes an empty Success today, but if that
            // contract ever regresses, render the composed empty state -- a bare black Home screen
            // (the S03 device-round symptom) must be unrepresentable here.
            if (s.data.isEmpty()) {
                EmptyState(
                    "No Home rows are visible. Turn rows back on in Settings > Appearance > Customize Home.",
                    modifier,
                )
            } else {
                HomeContent(
                    s.data,
                    collections,
                    hubOrder,
                    hubHidden,
                    onItem,
                    onDirectResume,
                    lastStreamStore,
                    viewModel,
                    modifier,
                )
            }
    }
}

@Composable
private fun HomeContent(
    catalogs: List<Catalog>,
    collections: CollectionsHubSnapshot,
    hubOrder: List<HomeRail>,
    hubHidden: Boolean,
    onItem: (MetaItem) -> Unit,
    onDirectResume: (MetaItem) -> Unit,
    lastStreamStore: LastStreamStore,
    viewModel: HomeViewModel,
    modifier: Modifier,
) {
    val visibleCatalogs = remember(catalogs) { normalizeHomeCatalogs(catalogs) }
    // The hub is not a catalog, so the hero candidate pool is unaffected by it.
    val heroCatalog = visibleCatalogs.firstOrNull()
    val heroCandidates = remember(visibleCatalogs) { PhoneHeroPolicy.candidates(visibleCatalogs) }
    val initialHero = heroCandidates.firstOrNull()
    val savedStream = initialHero?.let { lastStreamStore.load() }
    // WHY audit R01: direct resume belongs only to the first Continue Watching hero, never ordinary cards.
    val heroCanDirectResume = heroCatalog?.id == "continue" && initialHero != null && savedStream?.let {
        it.mediaId == initialHero.id && it.mediaType == initialHero.type && it.positionMs > 0L
    } == true
    val hubShown = collections.isVisible && !hubHidden
    val rows = remember(visibleCatalogs, hubShown, hubOrder) {
        homeRowsWithHub(visibleCatalogs, if (hubShown) collectionsHubSlot(visibleCatalogs, hubOrder) else null)
    }
    val lastCatalogId = visibleCatalogs.lastOrNull()?.id
    // The featured hero is the first item of the first rail (Continue Watching, else the leading add-on
    // catalog) -- the SAME data the rails below already render. It now loads that title's real
    // backdrop/poster art (see [HeroHeader]), so the earlier large-screen gate (which hid the hero on
    // tablets/foldables precisely BECAUSE it was an artwork-less flat gradient that stretched into a
    // "huge, mostly-empty black bar", the Tab S11 Ultra GROUP 3a finding) no longer applies: with real
    // art plus the height cap in [HeroHeader], the panel reads as intentional at any width. The blank
    // hero the device round hit was this billboard never binding any image at all.
    LazyColumn(
        modifier = modifier.fillMaxSize(),
        contentPadding = PaddingValues(bottom = VortXTheme.spacing.xl),
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xl),
    ) {
        if (initialHero != null) {
            item {
                PhoneHeroHeader(
                    candidates = heroCandidates,
                    onItem = onItem,
                    // Direct resume remains an affordance only for the leading Continue Watching title.
                    onDirectResume = onDirectResume.takeIf { heroCanDirectResume },
                    directResumeIdentity = initialHero.let(PhoneHeroPolicy::identity).takeIf { heroCanDirectResume },
                )
            }
        }
        itemsIndexed(rows, key = { _, row -> homeRowKey(row) }) { _, row ->
            when (row) {
                HomeRowItem.HubRow ->
                    CollectionsHub(collections, viewModel::openCollection, viewModel::retryCollectionsHub)
                is HomeRowItem.CatalogRow -> {
                    val catalog = row.catalog
                    if (catalog.id == lastCatalogId) {
                        LaunchedEffect(rows.size, catalog.id) { viewModel.loadMoreRows() }
                    }
                    // The leading Continue Watching rail carries the editorial kicker, like tvOS.
                    val eyebrow = when (catalog.id) {
                        "continue" -> "Pick up where you left off"
                        TOP_PICKS_CATALOG_ID -> "Based on what you watch"
                        UPCOMING_EPISODES_CATALOG_ID, UPCOMING_MOVIES_CATALOG_ID -> "Coming soon"
                        TRAKT_WATCHLIST_CATALOG_ID -> "From Trakt"
                        SIMKL_WATCHLIST_CATALOG_ID -> "From SIMKL"
                        else -> null
                    }
                    PosterRail(
                        catalog = catalog,
                        onItem = onItem,
                        onRemoveFromContinueWatching = viewModel::removeFromContinueWatching,
                        eyebrow = eyebrow,
                        onEndReached = if (catalog.hasNextPage) {
                            { viewModel.loadNextPage(catalog) }
                        } else {
                            null
                        },
                    )
                }
            }
        }
    }
}

@Composable
private fun LoadingColumn(modifier: Modifier) {
    LazyColumn(
        modifier = modifier.fillMaxSize(),
        contentPadding = PaddingValues(top = VortXTheme.spacing.xl, bottom = VortXTheme.spacing.xl),
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xl),
    ) {
        items(List(3) { it }) { LoadingRail() }
    }
}

/// Phone-specific featured hero. The stable candidate pool is built from visible editorial rails; a manual
/// selection pauses the slideshow until the viewer explicitly resumes it. Trailer playback deliberately
/// stays TV-only: the existing Android route owns a TV player surface and its lifecycle assumptions do not
/// hold for a scrollable, touch-first phone header.
@Composable
private fun PhoneHeroHeader(
    candidates: List<MetaItem>,
    onItem: (MetaItem) -> Unit,
    onDirectResume: ((MetaItem) -> Unit)?,
    directResumeIdentity: String?,
) {
    val reducedMotion = rememberReducedMotion()
    val candidateIds = remember(candidates) { candidates.map(PhoneHeroPolicy::identity) }
    var selectedIdentity by remember { mutableStateOf(candidateIds.firstOrNull()) }
    var selectedIndex by remember { mutableLongStateOf(0L) }
    var interactionHeld by remember { mutableStateOf(false) }
    var generation by remember { mutableLongStateOf(0L) }

    // Preserve the currently visible identity across Home publication updates. A disappeared item returns
    // deterministically to the leading editorial candidate rather than jumping to a random list position.
    LaunchedEffect(candidateIds) {
        val index = PhoneHeroPolicy.initialIndex(candidates, selectedIdentity)
        selectedIndex = index.toLong()
        selectedIdentity = candidates[index].let(PhoneHeroPolicy::identity)
        generation += 1
    }
    val index = selectedIndex.toInt().coerceIn(0, candidates.lastIndex)
    val selected = candidates[index]
    LaunchedEffect(selectedIdentity, candidateIds, interactionHeld, reducedMotion) {
        if (!PhoneHeroPolicy.shouldRotate(candidates.size, reducedMotion, interactionHeld)) return@LaunchedEffect
        delay(PhoneHeroPolicy.ROTATION_INTERVAL_MS)
        val next = PhoneHeroPolicy.nextIndex(index, candidates.size, forward = true)
        selectedIndex = next.toLong()
        selectedIdentity = PhoneHeroPolicy.identity(candidates[next])
        generation += 1
    }
    val item = rememberPhoneEnrichedHeroItem(selected, generation)
    val logoUrl = item.logo?.takeUnless { it.isBlank() }
    // A nonblank URL is not proof the logo rendered. Persist failure only for this URL: composition drops
    // the broken AsyncImage, showing the accessible type/title fallback without retrying it each frame.
    var failedLogoUrl by remember(logoUrl) { mutableStateOf<String?>(null) }
    val choose: (Boolean) -> Unit = { forward ->
        interactionHeld = true
        val next = PhoneHeroPolicy.nextIndex(index, candidates.size, forward)
        selectedIndex = next.toLong()
        selectedIdentity = PhoneHeroPolicy.identity(candidates[next])
        generation += 1
    }
    val colors = VortXTheme.colors
    // The featured title's real artwork, drawn from the SAME catalog data the rails use: prefer the
    // wide featured backdrop ([MetaItem.background], what browse pages lead with and what the engine's
    // `parseMetaPreview` fills for add-on catalog items), fall back to the poster (Continue Watching
    // items carry only that). Both go through the one app-wide Coil loader, exactly like [PosterArt].
    // Null/blank on both (the offline preview, or a still-hydrating first item) keeps the plain
    // gradient so the panel stays intentional rather than empty -- the sensible fallback.
    val backdropUrl = item.background?.takeUnless { it.isBlank() } ?: item.poster?.takeUnless { it.isBlank() }
    Box(
        modifier = Modifier
            .fillMaxWidth()
            // Cap the hero's height BEFORE applying the aspect ratio: on a large-screen portrait
            // window (tablet / unfolded foldable, width 800-1000dp) an unclamped 16:10 of full width
            // is a 500-640dp block that swallows the viewport (S03 device-round finding on the Tab S11
            // Ultra). Phones stay under the cap, so their ratio is untouched; when the cap binds, the
            // box goes full-width at 420dp tall instead.
            .heightIn(max = 420.dp)
            .aspectRatio(16f / 10f)
            // GROUP 3a: a Box does not clip its children by default, so a title tall enough to exceed
            // this box's bounds (a long name at the large `type.hero` style, most likely on a wide
            // window where the box's aspect-ratio math yields a shorter box for the same font size)
            // drew past the bottom edge and, because the next LazyColumn item (the first rail) paints
            // AFTER this one, appeared to render "behind" it -- the device-round "Obsession" overlap
            // finding. Clipping plus the title's own line/overflow limit below are the two guards.
            .clipToBounds()
            // Tap the billboard to open the featured title, the same action a poster tap performs.
            .clickable { onItem(item) }
            // Placeholder fill for when there is no artwork yet; hidden behind the image when there is.
            .background(Brush.verticalGradient(listOf(colors.surface2, colors.canvas))),
    ) {
        if (backdropUrl != null) {
            AsyncImage(
                model = backdropUrl,
                contentDescription = item.name,
                contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize(),
            )
            // Bottom-anchored scrim so the eyebrow/title/meta stay legible over any artwork: the
            // DESIGN-SYSTEM hero's fade to canvas, without dimming the top of the image.
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(
                        Brush.verticalGradient(
                            0.35f to Color.Transparent,
                            1f to colors.canvas,
                        ),
                    ),
            )
        }
        Column(modifier = Modifier.align(Alignment.BottomStart).padding(VortXTheme.spacing.edge)) {
            if (PhoneHeroPolicy.shouldShowLogo(logoUrl, failedLogoUrl)) {
                AsyncImage(
                    model = logoUrl,
                    contentDescription = item.name,
                    contentScale = ContentScale.Fit,
                    alignment = Alignment.BottomStart,
                    modifier = Modifier.heightIn(max = 96.dp).fillMaxWidth(0.64f),
                    onError = { failedLogoUrl = logoUrl },
                )
            } else {
                Text(text = item.type.label.uppercase(), style = VortXTheme.type.eyebrow)
                Text(
                    text = item.name,
                    style = VortXTheme.type.hero,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.padding(top = VortXTheme.spacing.xs),
                )
            }
            val meta = listOfNotNull(
                item.year,
                item.imdbRating?.let { "★ $it" },
                item.genres.firstOrNull(),
            ).joinToString("   ·   ")
            if (meta.isNotBlank()) {
                Text(
                    text = meta,
                    style = VortXTheme.type.label.copy(color = colors.textSecondary),
                    modifier = Modifier.padding(top = 4.dp),
                )
            }
            item.description?.takeIf { it.isNotBlank() }?.let { synopsis ->
                Text(
                    text = synopsis,
                    style = VortXTheme.type.body.copy(color = colors.textSecondary),
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.padding(top = VortXTheme.spacing.sm),
                )
            }
            onDirectResume?.takeIf { PhoneHeroPolicy.identity(item) == directResumeIdentity }?.let { resume ->
                Button(
                    onClick = { resume(item) },
                    modifier = Modifier.padding(top = VortXTheme.spacing.sm),
                ) {
                    Text("Resume")
                }
            }
            if (candidates.size > 1) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.padding(top = VortXTheme.spacing.sm),
                ) {
                    TextButton(onClick = { choose(false) }) { Text("Previous") }
                    Text(
                        text = candidates.indices.joinToString(" ") { if (it == index) "●" else "○" },
                        style = VortXTheme.type.label.copy(color = colors.textSecondary),
                        modifier = Modifier.padding(horizontal = VortXTheme.spacing.xs),
                    )
                    TextButton(onClick = { choose(true) }) { Text("Next") }
                    if (interactionHeld) {
                        TextButton(onClick = { interactionHeld = false }) { Text("Resume") }
                    }
                }
            }
        }
    }
}

/**
 * Phone equivalent of TV's focus enrichment. It reads the established resident-meta seam only, so it is
 * best-effort rather than a new network fetch. The dwell avoids needless reads during catalog churn, while
 * typed identity and generation fencing keep a late result from replacing a newer hero. Compose cancels
 * the effect when Home leaves composition or the selected title changes.
 */
@Composable
private fun rememberPhoneEnrichedHeroItem(item: MetaItem, generation: Long): MetaItem {
    val context = LocalContext.current.applicationContext
    val itemIdentity = PhoneHeroPolicy.identity(item)
    val request = PhoneHeroRequest(itemIdentity, generation)
    val visibleRequest by rememberUpdatedState(request)
    var enriched by remember(itemIdentity, generation) { mutableStateOf(seedPhoneHeroBackdrop(item)) }
    LaunchedEffect(request) {
        val seeded = seedPhoneHeroBackdrop(item)
        enriched = seeded
        if (!seeded.description.isNullOrBlank() && !seeded.background.isNullOrBlank()) return@LaunchedEffect
        delay(150L)
        val repository = (context as? VortXApplication)?.catalogRepository
            ?: return@LaunchedEffect
        val detail = try {
            repository.peekMeta(seeded.type, seeded.id)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            null
        } ?: return@LaunchedEffect
        // A repository implementation may complete after cancellation. The visible request is read at
        // publication time, so that late result cannot overwrite a newer title's header.
        if (PhoneHeroPolicy.acceptsEnrichment(
                request.identity,
                visibleRequest.identity,
                request.generation,
                visibleRequest.generation,
            )
        ) {
            enriched = seeded.copy(
                background = detail.background ?: seeded.background,
                logo = detail.logo ?: seeded.logo,
                description = detail.description ?: seeded.description,
                imdbRating = detail.imdbRating ?: seeded.imdbRating,
                genres = detail.genres.ifEmpty { seeded.genres },
                year = detail.releaseInfo ?: seeded.year,
            )
        }
    }
    return enriched
}

private fun seedPhoneHeroBackdrop(item: MetaItem): MetaItem = when {
    !item.background.isNullOrBlank() || !item.id.startsWith("tt") -> item
    else -> item.copy(background = "https://images.metahub.space/background/big/${item.id}/img")
}
