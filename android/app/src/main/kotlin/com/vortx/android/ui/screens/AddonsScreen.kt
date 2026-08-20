package com.vortx.android.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.focusable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.DragHandle
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.toMutableStateList
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.zIndex
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import coil3.compose.AsyncImage
import com.vortx.android.R
import com.vortx.android.engine.AddonHealth
import com.vortx.android.engine.AddonHealthStore
import com.vortx.android.model.InstalledAddon
import com.vortx.android.ui.UiState
import com.vortx.android.ui.components.Chip
import com.vortx.android.ui.components.EmptyState
import com.vortx.android.ui.components.ErrorState
import com.vortx.android.ui.components.SurfaceCard
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXAccents
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.viewmodel.AddonsViewModel
import kotlin.math.roundToInt

/// Add-on management (S04, DESIGN-SYSTEM.md §4 "Add-ons"): title + a short debrid explainer ->
/// install-by-URL form -> installed list as surface-card rows. Mirrors Apple `AddonsView`'s core
/// loop, plus two ported affordances: the per-profile on/off eye toggle per row (Apple
/// `AddonsView.swift:424` -> `toggleAddon`) and drag-reorder priority mode (Apple
/// `AddonsView.swift:476 .onMove` / `AddonReorderView`). QR pairing and the add-on catalog/store
/// browser remain separate parity work.
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AddonsScreen(
    viewModel: AddonsViewModel,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
    onDiscover: () -> Unit = {},
    onInstallByQr: () -> Unit = {},
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val urlInput by viewModel.urlInput.collectAsStateWithLifecycle()
    val installing by viewModel.installing.collectAsStateWithLifecycle()
    val installMessage by viewModel.installMessage.collectAsStateWithLifecycle()
    val health by viewModel.health.collectAsStateWithLifecycle()
    val pendingUpdate by viewModel.pendingUpdate.collectAsStateWithLifecycle()
    val colors = VortXTheme.colors
    val context = LocalContext.current

    LaunchedEffect(viewModel) {
        viewModel.onScreenEntry()
    }

    // Change-URL sheet state (Apple `EditAddonURLView`): the add-on being edited, or null when closed.
    var changeUrlAddon by remember { mutableStateOf<InstalledAddon?>(null) }
    changeUrlAddon?.let { addon ->
        ChangeAddonUrlDialog(
            addon = addon,
            viewModel = viewModel,
            onDismiss = { changeUrlAddon = null },
        )
    }

    // Update-if-installed confirm (SRC-8, Apple `AddonsView` confirmationDialog): pasting a URL that is
    // already installed pops this instead of silently re-installing, so an accidental re-paste is a
    // deliberate refresh, and the success line reads "Updated." rather than "Installed.".
    if (pendingUpdate != null) {
        AlertDialog(
            onDismissRequest = viewModel::cancelUpdate,
            title = { Text(stringResource(R.string.addon_update_confirm_title), style = VortXTheme.type.cardTitle) },
            text = { Text(stringResource(R.string.addon_update_confirm_message), style = VortXTheme.type.body) },
            confirmButton = {
                TextButton(onClick = viewModel::confirmUpdate) {
                    Text(stringResource(R.string.addon_update_confirm_button), color = colors.accent)
                }
            },
            dismissButton = {
                TextButton(onClick = viewModel::cancelUpdate) {
                    Text(stringResource(R.string.addon_update_confirm_cancel), color = colors.textSecondary)
                }
            },
            containerColor = colors.surface2,
        )
    }

    // Reorder mode (the Android twin of Apple's separate `AddonReorderView` screen, kept in-place as
    // a mode toggle): the normal management list swaps for a drag list of the same add-ons.
    var reorderMode by remember { mutableStateOf(false) }
    val installed = (state as? UiState.Success)?.data.orEmpty()

    Column(modifier = modifier.fillMaxSize()) {
        TopAppBar(
            title = { Text(if (reorderMode) "Reorder Add-ons" else "Add-ons", style = VortXTheme.type.screenTitle) },
            navigationIcon = {
                IconButton(onClick = { if (reorderMode) reorderMode = false else onBack() }) {
                    Icon(VortXIcons.back, contentDescription = "Back")
                }
            },
            actions = {
                // Reorder needs at least two add-ons to mean anything (same practical gate as
                // Apple's Reorder entry point). Each drop applies immediately, so "Done" just exits.
                if (installed.size > 1) {
                    TextButton(onClick = { reorderMode = !reorderMode }) {
                        Text(if (reorderMode) "Done" else "Reorder", color = colors.accent, style = VortXTheme.type.label)
                    }
                }
            },
        )
        if (reorderMode) {
            AddonReorderList(
                addons = installed,
                onApply = viewModel::applyOrder,
                modifier = Modifier.fillMaxSize(),
            )
            return@Column
        }
        LazyColumn(
            contentPadding = PaddingValues(horizontal = VortXTheme.spacing.edge, vertical = VortXTheme.spacing.md),
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
            modifier = Modifier.fillMaxSize(),
        ) {
            item {
                Text(
                    text = "Add-ons provide catalogs and sources: direct HTTPS links play instantly, " +
                        "while a debrid add-on unlocks cached torrents through your own debrid account " +
                        "(its key lives in the add-on's own configured manifest URL, not in VortX).",
                    style = VortXTheme.type.body.copy(color = colors.textSecondary),
                )
            }
            item {
                SurfaceCard(modifier = Modifier.fillMaxWidth()) {
                    Column(
                        modifier = Modifier.padding(VortXTheme.spacing.md),
                        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
                    ) {
                        Text("Install an add-on", style = VortXTheme.type.cardTitle)
                        OutlinedTextField(
                            value = urlInput,
                            onValueChange = viewModel::onUrlChange,
                            placeholder = { Text("https://…/manifest.json", style = VortXTheme.type.body) },
                            singleLine = true,
                            colors = OutlinedTextFieldDefaults.colors(
                                focusedBorderColor = colors.accent,
                                unfocusedBorderColor = colors.hairline,
                                cursorColor = colors.accent,
                            ),
                            modifier = Modifier.fillMaxWidth(),
                        )
                        Row(horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
                            Chip(
                                label = if (installing) "Installing…" else "Install",
                                selected = true,
                                enabled = !installing && urlInput.isNotBlank(),
                                onClick = viewModel::install,
                            )
                            // Install by QR: pair a phone once, then paste as many add-on URLs there as you
                            // like and install each here. Handy without a keyboard, offered on every platform
                            // (Apple `AddonsView` "Install by QR").
                            Chip(
                                label = "Install by QR",
                                selected = false,
                                leadingIcon = VortXIcons.qrCode,
                                onClick = onInstallByQr,
                            )
                        }
                        installMessage?.let { (message, failed) ->
                            Text(
                                text = message,
                                style = VortXTheme.type.label.copy(color = if (failed) colors.danger else colors.textSecondary),
                            )
                        }
                    }
                }
            }
            item {
                // Discover add-ons: browse the community collection and install with one tap (Apple
                // `AddonsView.discoverLink` -> `AddonStoreView`).
                SurfaceCard(modifier = Modifier.fillMaxWidth()) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable(onClick = onDiscover)
                            .padding(VortXTheme.spacing.md),
                        horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(VortXIcons.discover, contentDescription = null, tint = colors.accent)
                        Text("Discover add-ons", style = VortXTheme.type.cardTitle, modifier = Modifier.weight(1f))
                        Icon(VortXIcons.chevronRight, contentDescription = null, tint = colors.textTertiary)
                    }
                }
            }
            if (installed.isNotEmpty()) {
                item {
                    Row(modifier = Modifier.fillMaxWidth()) {
                        Chip(
                            label = stringResource(R.string.addon_health_recheck),
                            selected = false,
                            onClick = viewModel::recheckHealth,
                            modifier = Modifier.focusable(),
                        )
                    }
                }
            }
            when (val s = state) {
                is UiState.Loading -> item { EmptyState("Loading your add-ons…") }
                is UiState.Error -> item { ErrorState(s.message, onRetry = { viewModel.load() }) }
                is UiState.Success -> {
                    if (s.data.isEmpty()) {
                        item { EmptyState("No add-ons yet. Paste a manifest URL above to install one.") }
                    } else {
                        items(s.data, key = { it.transportUrl }) { addon ->
                            AddonRow(
                                addon = addon,
                                health = health[AddonHealthStore.normalizeUrl(addon.transportUrl)] ?: AddonHealth.Unknown,
                                onToggle = { viewModel.toggleAddon(addon) },
                                onRemove = { viewModel.remove(addon) },
                                onConfigure = { addon.configureUrl?.let { openInBrowser(context, it) } },
                                onChangeUrl = { changeUrlAddon = addon },
                            )
                        }
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun AddonRow(
    addon: InstalledAddon,
    health: AddonHealth,
    onToggle: () -> Unit,
    onRemove: () -> Unit,
    onConfigure: () -> Unit,
    onChangeUrl: () -> Unit,
) {
    val colors = VortXTheme.colors
    SurfaceCard(modifier = Modifier.fillMaxWidth()) {
        // Info row + a separate actions row (mirrors Apple `AddonsView.addonRow`): the fixed-size action
        // chips never steal width from the name/detail column, so a narrow phone wraps them instead of
        // clipping Remove off the edge.
        Column(
            modifier = Modifier.padding(VortXTheme.spacing.md),
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
        ) {
            Row(horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md)) {
                // Info block dims when the add-on is turned OFF for this profile, so the state reads at
                // a glance even before the eye icon does.
                Box(
                    modifier = Modifier
                        .size(48.dp)
                        .alpha(if (addon.isDisabled) 0.45f else 1f),
                    contentAlignment = Alignment.Center,
                ) {
                    if (addon.logo.isNullOrBlank()) {
                        Icon(VortXIcons.addon, contentDescription = null, tint = colors.accent)
                    } else {
                        AsyncImage(
                            model = addon.logo,
                            contentDescription = addon.name,
                            modifier = Modifier.fillMaxSize(),
                        )
                    }
                }
                Column(
                    modifier = Modifier
                        .weight(1f)
                        .alpha(if (addon.isDisabled) 0.45f else 1f),
                    verticalArrangement = Arrangement.spacedBy(2.dp),
                ) {
                    Text(addon.name, style = VortXTheme.type.cardTitle, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(
                        text = listOfNotNull(
                            if (addon.isDisabled) "Off" else null,
                            addon.capabilities,
                            addon.host,
                        ).joinToString(" · "),
                        style = VortXTheme.type.label.copy(color = colors.textTertiary),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    AddonHealthIndicator(health)
                }
            }
            // Actions wrap (Apple `addonActionChips`): Configure shows for any configurable add-on; the
            // Change-URL / eye / Remove trio is gated on !isProtected (protected defaults are not editable).
            FlowRow(horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
                if (addon.isConfigurable) {
                    Chip(
                        label = "Configure",
                        selected = false,
                        leadingIcon = VortXIcons.sources,
                        onClick = onConfigure,
                    )
                }
                if (!addon.isProtected) {
                    Chip(
                        label = "Change URL",
                        selected = false,
                        leadingIcon = VortXIcons.link,
                        onClick = onChangeUrl,
                    )
                    // Per-profile on/off (local overlay). Distinct from Remove, which uninstalls
                    // account-wide -- the same eye / eye-slash pair as Apple `AddonsView.swift:424-428`,
                    // gated the same way (protected defaults have no toggle).
                    IconButton(onClick = onToggle) {
                        Icon(
                            imageVector = if (addon.isDisabled) Icons.Filled.VisibilityOff else Icons.Filled.Visibility,
                            contentDescription = if (addon.isDisabled) "Turn on ${addon.name}" else "Turn off ${addon.name}",
                            tint = if (addon.isDisabled) colors.textTertiary else colors.accent,
                        )
                    }
                    IconButton(onClick = onRemove) {
                        Icon(VortXIcons.delete, contentDescription = "Remove ${addon.name}", tint = colors.danger)
                    }
                }
            }
        }
    }
}

/// Open [url] in the phone's browser (Apple `ConfigureAddonView` phone path opens the config page in a
/// browser). The add-on hands back a NEW manifest URL after configuration, which the user pastes into
/// "Install an add-on".
private fun openInBrowser(context: android.content.Context, url: String) {
    runCatching {
        context.startActivity(
            android.content.Intent(android.content.Intent.ACTION_VIEW, android.net.Uri.parse(url))
                .addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK),
        )
    }
}

/// The Change-URL sheet (Apple `EditAddonURLView`): replace an installed add-on's manifest URL, for
/// example after reconfiguring it. The ViewModel installs the new URL first, then drops the old without
/// tombstoning; on success this dismisses, on failure it shows the error inline.
@Composable
private fun ChangeAddonUrlDialog(
    addon: InstalledAddon,
    viewModel: AddonsViewModel,
    onDismiss: () -> Unit,
) {
    val colors = VortXTheme.colors
    val changing by viewModel.changingUrl.collectAsStateWithLifecycle()
    val message by viewModel.changeUrlMessage.collectAsStateWithLifecycle()
    val doneToken by viewModel.changeUrlDone.collectAsStateWithLifecycle()
    var url by remember { mutableStateOf(addon.transportUrl) }
    var submittedToken by remember { mutableStateOf(doneToken) }

    LaunchedEffect(addon.transportUrl) { viewModel.onChangeUrlOpen() }
    // A successful swap bumps changeUrlDone; close the sheet once when that happens.
    LaunchedEffect(doneToken) {
        if (doneToken != submittedToken) {
            submittedToken = doneToken
            onDismiss()
        }
    }

    AlertDialog(
        onDismissRequest = { if (!changing) onDismiss() },
        title = { Text("Change add-on URL", style = VortXTheme.type.cardTitle) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
                Text(addon.name, style = VortXTheme.type.label.copy(color = colors.textSecondary))
                Text(
                    "Replace this add-on's manifest URL, for example after reconfiguring it. The new URL is " +
                        "installed first, then the old one removed.",
                    style = VortXTheme.type.label.copy(color = colors.textSecondary),
                )
                OutlinedTextField(
                    value = url,
                    onValueChange = { url = it },
                    placeholder = { Text("https://…/manifest.json", style = VortXTheme.type.body) },
                    singleLine = true,
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedBorderColor = colors.accent,
                        unfocusedBorderColor = colors.hairline,
                        cursorColor = colors.accent,
                    ),
                    modifier = Modifier.fillMaxWidth(),
                )
                message?.let { (text, failed) ->
                    if (failed) Text(text, style = VortXTheme.type.label.copy(color = colors.danger))
                }
            }
        },
        confirmButton = {
            TextButton(
                onClick = { viewModel.changeAddonUrl(addon, url) },
                enabled = !changing && url.isNotBlank() && url.trim() != addon.transportUrl,
            ) {
                Text(if (changing) "Updating…" else "Update", color = colors.accent)
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss, enabled = !changing) {
                Text("Cancel", color = colors.textSecondary)
            }
        },
        containerColor = colors.surface2,
    )
}

@Composable
internal fun AddonHealthIndicator(health: AddonHealth) {
    val colors = VortXTheme.colors
    val label = when (health) {
        AddonHealth.Unknown -> stringResource(R.string.addon_health_not_checked)
        AddonHealth.Checking -> stringResource(R.string.addon_health_checking)
        is AddonHealth.Online -> stringResource(R.string.addon_health_online_ms, health.latencyMillis)
        is AddonHealth.Slow -> stringResource(R.string.addon_health_slow_ms, health.latencyMillis)
        AddonHealth.Unreachable -> stringResource(R.string.addon_health_unreachable)
    }
    val color = when (health) {
        AddonHealth.Unknown, AddonHealth.Checking -> colors.textTertiary
        is AddonHealth.Online -> VortXAccents.forest.base
        is AddonHealth.Slow -> VortXAccents.gold.base
        AddonHealth.Unreachable -> colors.danger
    }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Box(modifier = Modifier.size(8.dp).background(color, CircleShape))
        Text(label, style = VortXTheme.type.label.copy(color = color))
    }
}

/// The drag-reorder list (Apple `AddonReorderView`, AddonsView.swift:449-501): fixed-height rows,
/// drag by the trailing handle; crossing half a row height swaps, and releasing applies the order
/// immediately (each drop persists, like Apple's `.onMove` writing `applyInAppAddonOrder` per drop).
/// Fixed-height rows keep the swap math exact with no per-row measurement bookkeeping; add-on lists
/// are small (tens of rows), so a plain scrollable Column beats lazy-list drag complexity.
@Composable
private fun AddonReorderList(
    addons: List<InstalledAddon>,
    onApply: (List<String>) -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = VortXTheme.colors
    // Local working order, re-seeded whenever the applied list itself changes shape/order (the
    // post-apply reload echoes back the order just dropped, so the re-seed is visually a no-op).
    val order = remember(addons.map { it.transportUrl }) { addons.toMutableStateList() }
    var draggingUrl by remember { mutableStateOf<String?>(null) }
    var dragOffset by remember { mutableStateOf(0f) }
    val rowHeightPx = with(LocalDensity.current) { (REORDER_ROW_HEIGHT_DP + REORDER_ROW_GAP_DP).dp.toPx() }

    Column(
        modifier = modifier
            .verticalScroll(rememberScrollState())
            .padding(horizontal = VortXTheme.spacing.edge, vertical = VortXTheme.spacing.md),
        verticalArrangement = Arrangement.spacedBy(REORDER_ROW_GAP_DP.dp),
    ) {
        Text(
            text = "Drag to set your add-on priority: the first add-on's catalogs and sources come first.",
            style = VortXTheme.type.body.copy(color = colors.textSecondary),
            modifier = Modifier.padding(bottom = VortXTheme.spacing.sm),
        )
        order.forEach { addon ->
            key(addon.transportUrl) {
                val dragging = draggingUrl == addon.transportUrl
                SurfaceCard(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(REORDER_ROW_HEIGHT_DP.dp)
                        .zIndex(if (dragging) 1f else 0f)
                        .graphicsLayer { translationY = if (dragging) dragOffset else 0f },
                ) {
                    Row(
                        modifier = Modifier
                            .fillMaxSize()
                            .padding(horizontal = VortXTheme.spacing.md),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
                    ) {
                        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                            Text(addon.name, style = VortXTheme.type.cardTitle, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            Text(
                                text = addon.host,
                                style = VortXTheme.type.label.copy(color = colors.textTertiary),
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                        Icon(
                            imageVector = Icons.Filled.DragHandle,
                            contentDescription = "Reorder ${addon.name}",
                            tint = colors.textTertiary,
                            // The HANDLE owns the drag (immediate, no long-press), so the rest of the
                            // row stays free for the Column's scroll gesture.
                            modifier = Modifier.pointerInput(addon.transportUrl) {
                                detectDragGestures(
                                    onDragStart = {
                                        draggingUrl = addon.transportUrl
                                        dragOffset = 0f
                                    },
                                    onDrag = { change, amount ->
                                        change.consume()
                                        dragOffset += amount.y
                                        // Row identity by URL, not captured index: swaps move this
                                        // composable, so the live index must be re-derived per event.
                                        val from = order.indexOfFirst { it.transportUrl == addon.transportUrl }
                                        if (from < 0) return@detectDragGestures
                                        val target = (from + (dragOffset / rowHeightPx).roundToInt())
                                            .coerceIn(0, order.lastIndex)
                                        if (target != from) {
                                            order.add(target, order.removeAt(from))
                                            // Keep the dragged row visually under the finger after
                                            // the list shifted beneath it.
                                            dragOffset -= (target - from) * rowHeightPx
                                        }
                                    },
                                    onDragEnd = {
                                        draggingUrl = null
                                        dragOffset = 0f
                                        onApply(order.map { it.transportUrl })
                                    },
                                    onDragCancel = {
                                        draggingUrl = null
                                        dragOffset = 0f
                                    },
                                )
                            },
                        )
                    }
                }
            }
        }
    }
}

/// Reorder row geometry (fixed so the drag's swap threshold is exact).
private const val REORDER_ROW_HEIGHT_DP = 64
private const val REORDER_ROW_GAP_DP = 10
