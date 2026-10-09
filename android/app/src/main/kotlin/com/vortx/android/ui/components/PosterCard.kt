package com.vortx.android.ui.components

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.vortx.android.ui.prefs.PosterStylePreferences
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.graphics.toArgb
import com.vortx.android.VortXApplication
import com.vortx.android.data.CatalogRepository
import com.vortx.android.model.MetaItem
import com.vortx.android.library.WatchlistStore
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXMotion
import com.vortx.android.ui.theme.VortXShapes
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.theme.vortxShadow
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.CancellationException

enum class PosterCardMenu {
    NONE,
    CATALOG,
    CONTINUE_WATCHING,
}

/// The canonical poster card (DESIGN-SYSTEM.md §3 "Poster card"): 2:3 art, card radius, `rest` shadow,
/// title below in label style. Press/focus: lift + scale(~1.03) + glow + title brightens to
/// textPrimary. [watched] dims the art and shows a check badge; [progress] (0f..1f, null = not in
/// progress) draws a 3px accent track under the art. [art] is a placeholder-friendly slot — until Coil
/// lands (S03), it defaults to [DefaultPosterArt]; a real image loader drops in behind the same slot
/// with no call-site changes.
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun PosterCard(
    title: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    subtitle: String? = null,
    watched: Boolean = false,
    progress: Float? = null,
    enabled: Boolean = true,
    /// The catalog item behind this card, for the long-press quick-action menu (Mark as Watched /
    /// Mark as Unwatched / Add to Library). Null (the default) attaches no menu, so a plain card
    /// keeps its tap-only behavior -- the exact contract of Apple's `PosterContextMenu` `.none`
    /// case (iOSRootView.swift:4222). Actions fire straight at the app's one [com.vortx.android.
    /// data.CatalogRepository] (the Android twin of the menu firing at `CoreBridge.shared`); the
    /// affected surfaces refresh on their own through the repository's ctx tick.
    menuItem: MetaItem? = null,
    menu: PosterCardMenu = if (menuItem == null) PosterCardMenu.NONE else PosterCardMenu.CATALOG,
    onDetails: (() -> Unit)? = null,
    onRemoveFromContinueWatching: (() -> Unit)? = null,
    onQuickView: (() -> Unit)? = null,
    /** Touch presentation opts into the direct-accent cinema frame; TV retains its focus/elevation style. */
    cinema: Boolean = false,
    /** Cinema result/CW frames are wide even when the general poster preset remains portrait. */
    landscape: Boolean? = null,
    showLabels: Boolean? = null,
    description: String? = null,
    reserveLabelSpace: Boolean = false,
    art: @Composable BoxScope.() -> Unit = { DefaultPosterArt(title) },
) {
    val colors = VortXTheme.colors
    // Poster Style presentation prefs (item 5), on Apple's exact keys: corner-radius preset, hide-labels,
    // and the landscape 16:9 vs portrait 2:3 aspect. Reading the live StateFlow re-lays the card out the
    // moment a preset changes in the Poster Style screen.
    val posterStyle by PosterStylePreferences.state.collectAsStateWithLifecycle()
    val cardShape = RoundedCornerShape(posterStyle.radius.radius)
    val aspect = if (landscape ?: posterStyle.landscape) 16f / 9f else 2f / 3f
    val interactionSource = remember { MutableInteractionSource() }
    val pressed by interactionSource.collectIsPressedAsState()
    val reduced = VortXTheme.reducedMotion
    val active = pressed && enabled
    val scale by animateFloatAsState(
        targetValue = if (active) VortXMotion.POSTER_FOCUS_SCALE else 1f,
        animationSpec = VortXMotion.heroAware(reduced),
        label = "posterScale",
    )
    val elevationSpec = if (active) VortXTheme.elevation.glow(colors.accent) else VortXTheme.elevation.rest

    var menuOpen by remember { mutableStateOf(false) }
    val appContext = LocalContext.current.applicationContext

    Column(
        modifier = modifier
            .scale(scale)
            .combinedClickable(
                enabled = enabled,
                interactionSource = interactionSource,
                indication = null,
                onClick = onClick,
                // Long-press opens the quick-action menu only when a [menuItem] is attached; a card
                // without one behaves exactly as before (combinedClickable with a null onLongClick
                // is a plain clickable).
                onLongClick = if (menuItem != null && menu != PosterCardMenu.NONE) {
                    { menuOpen = true }
                } else {
                    null
                },
            ),
    ) {
        if (menuItem != null) {
            PosterQuickActionMenu(
                item = menuItem,
                menu = menu,
                expanded = menuOpen,
                onDismiss = { menuOpen = false },
                onDetails = onDetails,
                onRemoveFromContinueWatching = onRemoveFromContinueWatching,
                onQuickView = onQuickView,
                repository = { (appContext as? VortXApplication)?.catalogRepository },
            )
        }
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .aspectRatio(aspect)
                .then(if (cinema) Modifier else Modifier.vortxShadow(elevationSpec, cardShape))
                .clip(cardShape)
                .then(
                    if (cinema) Modifier.border(
                        width = if (active) 2.dp else 1.dp,
                        color = if (active) colors.accent else colors.hairline.copy(alpha = 0.82f),
                        shape = cardShape,
                    ) else Modifier,
                ),
        ) {
            art()
            if (watched) {
                Box(modifier = Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.45f)))
                Icon(
                    imageVector = VortXIcons.checkmarkCircle,
                    contentDescription = "Watched",
                    tint = colors.accentBright,
                    modifier = Modifier
                        .align(Alignment.TopEnd)
                        .padding(6.dp)
                        .size(20.dp),
                )
            }
            if (progress != null && progress in 0f..1f) {
                Box(
                    modifier = Modifier
                        .align(Alignment.BottomStart)
                        .fillMaxWidth()
                        .height(3.dp)
                        .background(colors.surface3.copy(alpha = 0.6f)),
                ) {
                    Box(
                        modifier = Modifier
                            .fillMaxWidth(progress.coerceIn(0f, 1f))
                            .fillMaxSize()
                            .background(colors.accent),
                    )
                }
            }
        }
        // Hide-labels preset (item 5): the poster art carries the identity, so the title/subtitle rows are
        // dropped when the user opts in. Labels shown is the default, today's look.
        if (showLabels ?: !posterStyle.hideLabels) {
            Text(
                text = title,
                style = VortXTheme.type.cardTitle.copy(color = if (active) colors.textPrimary else colors.textPrimary.copy(alpha = 0.92f)),
                maxLines = 2,
                minLines = if (reserveLabelSpace) 2 else 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.padding(top = 6.dp),
            )
            if (subtitle != null) {
                Text(
                    text = subtitle,
                    style = VortXTheme.type.label.copy(color = colors.textTertiary, fontSize = 12.sp),
                    maxLines = if (description != null || reserveLabelSpace) 2 else 1,
                    minLines = if (reserveLabelSpace) 2 else 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            description?.takeIf(String::isNotBlank)?.let {
                Text(
                    text = it,
                    style = VortXTheme.type.body.copy(color = colors.textSecondary),
                    maxLines = 3,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.padding(top = 6.dp),
                )
            }
        }
    }
}

/// The card's long-press quick actions, ported from Apple's catalog-card context menu
/// (iOSRootView.swift:4253-4268 `PosterContextMenu.catalog`): Add to Library, Mark as Watched, Mark
/// as Unwatched -- same actions, same order. Watched marks go through the repository's card-level
/// `setCatalogWatched` (the engine's `MetaItemMarkAsWatched`, which creates a temporary library item
/// when none exists), NOT the detail screen's open-meta `setWatched`, because no detail page is open
/// from a card. Fire-and-forget on a process-lifetime scope so a rail scrolling the card out of
/// composition can never cancel the engine write mid-flight.
@Composable
internal fun PosterQuickActionMenu(
    item: MetaItem,
    menu: PosterCardMenu,
    expanded: Boolean,
    onDismiss: () -> Unit,
    onDetails: (() -> Unit)? = null,
    onRemoveFromContinueWatching: (() -> Unit)? = null,
    onQuickView: (() -> Unit)? = null,
    repository: () -> CatalogRepository?,
) {
    val context = LocalContext.current.applicationContext
    val store = if (menu == PosterCardMenu.CATALOG) remember(context) { runCatching { WatchlistStore.shared(context) }.getOrNull() } else null
    val watchlist = store?.items?.collectAsStateWithLifecycle()?.value.orEmpty()
    var busy by remember(item.type, item.id) { mutableStateOf(false) }
    var actionMessage by remember(item.type, item.id) { mutableStateOf<String?>(null) }
    val repo = if (expanded && menu == PosterCardMenu.CATALOG) repository() else null
    val watchlistReady = expanded && store != null && runCatching { store.captureToggle(item) }.isSuccess
    val watchedReady = repo != null && repo.continueWatchingOwner().profileId != "native-unavailable"
    val actions = posterCatalogActions(item, onQuickView != null, watchlistReady, watchedReady)
    fun launchAction(action: suspend () -> Unit) {
        busy = true
        actionMessage = null
        posterActionScope.launch {
            try {
                action()
                onDismiss()
            } catch (error: Exception) {
                if (error is CancellationException) throw error
                actionMessage = "Could not save this change. Try again."
            } finally { busy = false }
        }
    }
    DropdownMenu(expanded = expanded, onDismissRequest = onDismiss) {
        when (menu) {
            PosterCardMenu.NONE -> Unit
            PosterCardMenu.CATALOG -> {
                if (PosterCatalogAction.QUICK_VIEW in actions) onQuickView?.let { quickView ->
                    DropdownMenuItem(
                        text = { Text("Quick view") },
                        onClick = { onDismiss(); quickView() },
                    )
                }
                if (PosterCatalogAction.WATCHLIST in actions) DropdownMenuItem(
                    text = { Text(if (watchlist.any { it.id == item.id && it.type == item.type }) "Remove from Watchlist" else "Add to Watchlist") },
                    enabled = !busy,
                    onClick = {
                        val action = try { capturePosterAction({ checkNotNull(store).captureToggle(item) }) { intent -> checkNotNull(store).toggle(intent) } }
                        catch (_: Exception) { actionMessage = "Watchlist is unavailable. Try again."; return@DropdownMenuItem }
                        launchAction { action(); Unit }
                    },
                )
                for (watched in listOf(true, false)) {
                    val kind = if (watched) PosterCatalogAction.MARK_WATCHED else PosterCatalogAction.MARK_UNWATCHED
                    if (kind in actions) DropdownMenuItem(
                        text = { Text(if (watched) "Mark as Watched" else "Mark as Unwatched") },
                        enabled = !busy,
                        onClick = {
                            val capturedRepo = checkNotNull(repo)
                            val action = capturePosterAction(capturedRepo::continueWatchingOwner) { owner ->
                                capturedRepo.setCatalogWatched(item, watched, owner).getOrThrow()
                            }
                            launchAction(action)
                        },
                    )
                }
                actionMessage?.let { message -> DropdownMenuItem(text = { Text(message) }, enabled = false, onClick = {}) }
            }
            PosterCardMenu.CONTINUE_WATCHING -> {
                onDetails?.let { details ->
                    DropdownMenuItem(
                        text = { Text("Details") },
                        onClick = {
                            onDismiss()
                            details()
                        },
                    )
                }
                onRemoveFromContinueWatching?.let { remove ->
                    DropdownMenuItem(
                        text = { Text("Remove from Continue Watching") },
                        onClick = {
                            onDismiss()
                            remove()
                        },
                    )
                }
            }
        }
    }
}

/// Process-lifetime scope for the quick-action engine writes (the same pattern as the shell's
/// `appScope`): a menu action must complete even if the card leaves composition the next frame, so
/// it must not ride a `rememberCoroutineScope`. SupervisorJob so one failed write cancels nothing
/// else; Dispatchers.Default because the repository calls are JNI + JSON work, never main-thread.
private val posterActionScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

/// Deterministic brand-tinted gradient placeholder, seeded by [title] so a grid of unloaded posters
/// still reads as intentional/varied rather than identical gray boxes (the load-time placeholder
/// behind a real image once Coil lands, S03).
@Composable
fun DefaultPosterArt(title: String) {
    val accent = VortXTheme.colors.accent
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(posterBrush(title, accent)),
    ) {
        Text(
            text = title,
            style = VortXTheme.type.label.copy(color = Color.White.copy(alpha = 0.92f)),
            maxLines = 3,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.align(Alignment.BottomStart).padding(10.dp),
        )
    }
}

/// Deterministic two-stop gradient from a seed string, hued around the live accent so a whole grid of
/// placeholders stays in the current theme's family while every card still differs.
private fun posterBrush(seed: String, accent: Color): Brush {
    val hsv = FloatArray(3)
    android.graphics.Color.colorToHSV(accent.toArgb(), hsv)
    val h = seed.hashCode()
    val hueShift = ((h ushr 8) % 60) - 30
    val hue = ((hsv[0] + hueShift) % 360f + 360f) % 360f
    val top = Color(android.graphics.Color.HSVToColor(floatArrayOf(hue, 0.45f, 0.30f)))
    val bottom = Color(android.graphics.Color.HSVToColor(floatArrayOf(hue, 0.55f, 0.14f)))
    return Brush.verticalGradient(listOf(top, bottom))
}
