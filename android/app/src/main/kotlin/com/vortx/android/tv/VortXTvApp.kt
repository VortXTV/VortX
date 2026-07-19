package com.vortx.android.tv

import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.vortx.android.data.AuthRepository
import com.vortx.android.data.CatalogRepository
import com.vortx.android.data.PreviewAuthRepository
import com.vortx.android.data.PreviewCatalogRepository
import com.vortx.android.model.MetaItem
import com.vortx.android.ui.components.Wordmark
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXMotion
import com.vortx.android.ui.theme.VortXShapes
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.viewmodel.HomeViewModel
import com.vortx.android.ui.viewmodel.StremioXViewModelFactory

/// The VortX shell for a television. Mounted by [com.vortx.android.MainActivity] instead of
/// [com.vortx.android.ui.StremioXApp] when [isTelevision] says so; both are compiled into every build
/// (there is no TV flavor -- ANDROID-PLAN.md §0 invariant #7).
///
/// The tab set mirrors the phone shell's `Tab` enum and tvOS `RootTabView`, so the three platforms have
/// one information architecture. What differs is everything about how it is driven: a top tab row rather
/// than a bottom NavigationBar (a bottom bar on TV is a long D-pad journey away from content and reads
/// as a phone app blown up), focus-to-select rather than tap-to-select, and depth-aware back.
///
/// SCOPE, stated plainly: this round ships the SHELL and HOME. Discover / Library / Search / Settings and
/// the Detail page are Week 2-3 of the approved plan and are NOT implemented here. They render
/// [TvComingSoon] -- an honest, focusable, on-brand panel that says so -- rather than a broken screen or
/// a dead card. Do not read those tabs as finished surfaces.
@Composable
fun VortXTvApp(
    repo: CatalogRepository = PreviewCatalogRepository(),
    auth: AuthRepository = PreviewAuthRepository(),
) {
    VortXTheme {
        // The 10-foot token overlay goes INSIDE VortXTheme (it derives its type scale from the colors
        // VortXTheme provides) and wraps everything, so every VortXTheme.type read below this point is
        // already TV-scaled with no call-site changes.
        ProvideTvTheme {
            var tab by remember { mutableStateOf(TvTab.HOME) }
            var detail by remember { mutableStateOf<MetaItem?>(null) }
            // Home pulls focus onto its first poster ONCE, at launch. This flag lives here, at the shell,
            // rather than inside Home, because Home leaves and re-enters composition every time the user
            // tabs away and back -- and the tab row selects on FOCUS, so "back to Home" happens while the
            // user's focus is still in the tab row. Home auto-focusing itself on every entry would rip
            // focus out of the tab row the moment they landed on Home, trapping them in the rails.
            var homeAutoFocusDone by remember { mutableStateOf(false) }
            val appContext = LocalContext.current.applicationContext
            val factory = StremioXViewModelFactory(repo = repo, auth = auth, appContext = appContext)

            // Depth-aware back, ported from tvOS RootTabView: pop the current depth, else return to Home,
            // else fall through. `enabled = false` at the Home root is the important half -- it lets the
            // system handle back, which on a TV means leaving to the launcher (TV-DB requires exactly
            // that, and an app that traps back at its root fails TV review).
            BackHandler(enabled = detail != null || tab != TvTab.HOME) {
                if (detail != null) detail = null else tab = TvTab.HOME
            }

            Box(modifier = Modifier.fillMaxSize().background(VortXTheme.colors.canvas)) {
                val current = detail
                if (current != null) {
                    TvComingSoon(
                        title = current.name,
                        detail = "The TV detail page, source list and player chrome land in the next round.",
                        onBack = { detail = null },
                    )
                } else {
                    Column(modifier = Modifier.fillMaxSize()) {
                        TvTabRow(selected = tab, onSelect = { tab = it })
                        Box(modifier = Modifier.fillMaxWidth().weight(1f)) {
                            when (tab) {
                                TvTab.HOME -> TvHomeScreen(
                                    viewModel = viewModel<HomeViewModel>(factory = factory),
                                    onItem = { detail = it },
                                    autoFocusFirstCard = !homeAutoFocusDone,
                                    onAutoFocusConsumed = { homeAutoFocusDone = true },
                                )
                                // Week 2-3 of the plan. Honest panels, not stubs pretending to work.
                                TvTab.DISCOVER -> TvComingSoon("Discover", DISCOVER_NOTE, onBack = null)
                                TvTab.LIBRARY -> TvComingSoon("Library", LIBRARY_NOTE, onBack = null)
                                TvTab.SEARCH -> TvComingSoon("Search", SEARCH_NOTE, onBack = null)
                                TvTab.SETTINGS -> TvComingSoon("Settings", SETTINGS_NOTE, onBack = null)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// The shell's tabs. Mirrors the phone shell's private `Tab` enum and tvOS `RootTabView`'s tab set.
/// Declared here rather than shared with the phone shell because that enum is `private` inside
/// StremioXApp.kt, and widening it would mean editing a file the phone department owns for no gain.
/// Live and Add-ons, which tvOS also carries, are cuts for this window (see the round's report).
private enum class TvTab(val label: String, val icon: ImageVector) {
    HOME("Home", VortXIcons.home),
    DISCOVER("Discover", VortXIcons.discover),
    LIBRARY("Library", VortXIcons.library),
    SEARCH("Search", VortXIcons.search),
    SETTINGS("Settings", VortXIcons.settings),
}

/// The top tab row: the wordmark, then the tabs.
///
/// Focus SELECTS, rather than requiring a click. This is the Android TV and tvOS convention both -- on a
/// remote, moving onto a tab and then having to press select to actually go there is one press of pure
/// friction, and it makes browsing across tabs feel stuck. The consequence is deliberate: pressing down
/// from the tab row into the rails leaves the tab you last focused selected.
@Composable
private fun TvTabRow(
    selected: TvTab,
    onSelect: (TvTab) -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .padding(
                start = TvMetrics.overscanHorizontal,
                end = TvMetrics.overscanHorizontal,
                top = TvMetrics.overscanVertical,
            ),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(TAB_GAP),
    ) {
        // The brand lockup sits where tvOS puts its header: top-leading, clear of everything else.
        Wordmark()
        // Extra air after the wordmark, on top of the row's own spacing: the lockup is brand, not a tab,
        // and should not read as the first item in the tab set.
        Spacer(modifier = Modifier.width(TAB_GAP))
        TvTab.entries.forEach { entry ->
            TvTabItem(tab = entry, selected = entry == selected, onFocused = { onSelect(entry) })
        }
    }
}

@Composable
private fun TvTabItem(tab: TvTab, selected: Boolean, onFocused: () -> Unit) {
    val colors = VortXTheme.colors
    val reduced = VortXTheme.reducedMotion
    var focused by remember { mutableStateOf(false) }
    val interactionSource = remember { MutableInteractionSource() }
    // Focused is the strongest state, then selected-but-not-focused (the tab you are in, while your
    // focus is down in the rails), then everything else. Three levels, so the row always answers both
    // "where am I" and "where is the D-pad" at a glance -- on a phone the bottom bar only has to answer
    // the first, which is why this is not just the NavigationBar restyled.
    val contentAlpha by animateFloatAsState(
        targetValue = when {
            focused -> 1f
            selected -> 0.92f
            else -> 0.55f
        },
        animationSpec = VortXMotion.stateAware(reduced),
        label = "tvTabAlpha",
    )
    val tint = when {
        focused -> colors.onAccent
        selected -> colors.accentBright
        else -> colors.textSecondary
    }

    Row(
        modifier = Modifier
            .clip(VortXShapes.pill)
            // The focused tab gets the accent fill (so the ink flips to onAccent above); the merely
            // selected one gets the soft accent wash; the rest stay on the canvas.
            .background(
                when {
                    focused -> colors.accent
                    selected -> colors.accentSoft
                    else -> Color.Transparent
                },
            )
            .onFocusChanged { state ->
                focused = state.isFocused
                if (state.isFocused) onFocused()
            }
            // Still clickable: focus-to-select drives the D-pad, but a click (DPAD_CENTER on the focused
            // tab, or a pointer on a Google TV remote's cursor) must not be a no-op.
            .clickable(interactionSource = interactionSource, indication = null, onClick = onFocused)
            .padding(horizontal = 16.dp, vertical = 8.dp)
            .alpha(contentAlpha),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(imageVector = tab.icon, contentDescription = null, tint = tint, modifier = Modifier.size(24.dp))
        Text(text = tab.label, style = VortXTheme.type.label.copy(color = tint))
    }
}

/// An honest "not on TV yet" panel.
///
/// This exists because the alternatives are worse. A tab that renders nothing looks broken; a card that
/// does nothing on click looks broken; a fake screen that mimics a finished surface is a lie that
/// survives into a review. This says what is true, stays inside overscan, and -- when [onBack] is given
/// -- offers a focusable control so the D-pad is never stranded (TV-DP: no dead ends).
///
/// [onBack] is null for a TAB, because back is already handled at the shell (it returns to Home), and a
/// second control saying the same thing would just be another thing to press past.
@Composable
private fun TvComingSoon(title: String, detail: String, onBack: (() -> Unit)?) {
    val colors = VortXTheme.colors
    Box(modifier = Modifier.fillMaxSize().tvSafeContentPadding(), contentAlignment = Alignment.Center) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
        ) {
            Text(text = title, style = VortXTheme.type.screenTitle, textAlign = TextAlign.Center)
            Text(
                text = detail,
                style = VortXTheme.type.body.copy(color = colors.textSecondary),
                textAlign = TextAlign.Center,
            )
            if (onBack != null) {
                TvTextButton(label = "Back", onClick = onBack, autoFocus = true)
            }
        }
    }
}

/// A focusable text button carrying the same ember focus treatment as a poster, so focus reads
/// identically wherever it lands.
///
/// [autoFocus] pulls focus onto it when it appears. Unlike Home's once-per-session case, requesting it
/// on every appearance is CORRECT here: this button only ever appears on a panel that just opened, and
/// it is that panel's only focusable, so without it the panel opens with focus nowhere and the first
/// D-pad press does nothing visible.
@Composable
private fun TvTextButton(label: String, onClick: () -> Unit, autoFocus: Boolean = false) {
    val colors = VortXTheme.colors
    var focused by remember { mutableStateOf(false) }
    val interactionSource = remember { MutableInteractionSource() }
    val requester = remember { FocusRequester() }
    if (autoFocus) {
        LaunchedEffect(Unit) {
            withFrameNanos { }
            runCatching { requester.requestFocus() }
        }
    }
    Text(
        text = label,
        style = VortXTheme.type.label.copy(color = if (focused) colors.onAccent else colors.textPrimary),
        modifier = Modifier
            .tvFocusScale(focused, focusedScale = TV_BUTTON_FOCUS_SCALE)
            .focusRequester(requester)
            .onFocusChanged { focused = it.isFocused }
            .clickable(interactionSource = interactionSource, indication = null, onClick = onClick)
            .tvFocusArt(focused, shape = VortXShapes.pill)
            .clip(VortXShapes.pill)
            .background(if (focused) colors.accent else colors.surface2)
            .padding(horizontal = 28.dp, vertical = 12.dp),
    )
}

/// A control lifts less than a poster does: 1.08 on a wide pill reads as a wobble rather than a lift.
private const val TV_BUTTON_FOCUS_SCALE = 1.04f

/// Gap between tabs (and, doubled, between the wordmark and the tab set).
private val TAB_GAP = 12.dp

private const val DISCOVER_NOTE =
    "Discover on TV lands in the next round: the engine's type, catalog and genre pivots as a focusable chip row over a browse grid."
private const val LIBRARY_NOTE =
    "Library on TV lands in the next round, with the same filter and sort pivots as your phone."
private const val SEARCH_NOTE =
    "Search on TV lands in the next round. It needs a 10-foot keyboard, so it is being done properly rather than quickly."
private const val SETTINGS_NOTE =
    "Settings on TV lands in the next round, reading and writing the SAME saved settings as your phone, so nothing you change here or there drifts apart."
