package com.vortx.android.ui.tv

import android.graphics.Bitmap
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.tv.material3.Border
import androidx.tv.material3.ClickableSurfaceDefaults
import androidx.tv.material3.ExperimentalTvMaterial3Api
import androidx.tv.material3.Surface
import com.vortx.android.engine.AddonHealth
import com.vortx.android.engine.AddonHealthStore
import com.vortx.android.model.InstalledAddon
import com.vortx.android.model.StoreAddon
import com.vortx.android.ui.components.qrBitmap
import com.vortx.android.ui.screens.AddonHealthIndicator
import com.vortx.android.ui.screens.AddonPairingContent
import com.vortx.android.ui.theme.VortXShapes
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.viewmodel.AddonPairingViewModel
import com.vortx.android.ui.viewmodel.AddonStoreViewModel

/// Install-by-QR on TV (Apple `AddonPairingView` tvOS flow): a Back action above the shared pairing body,
/// which shows the QR of the relay page URL and the install progress. The phone opens that page and pastes
/// manifest URLs; this TV installs each.
@Composable
internal fun TvAddonPairingScreen(
    viewModel: AddonPairingViewModel,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    Column(modifier = modifier.fillMaxSize().padding(TvDimens.edge)) {
        TvAddonActionButton(label = "Back", onClick = onBack, modifier = Modifier.width(180.dp))
        Spacer(Modifier.size(VortXTheme.spacing.md))
        AddonPairingContent(
            state = state,
            onRetry = viewModel::start,
            modifier = Modifier.fillMaxWidth().weight(1f),
        )
    }
}

/// Discover add-ons on TV (Apple `AddonStoreView` tvOS): browse the community collection and install with a
/// click. No text search here (TV text entry is painful); the full catalog is listed with a live health
/// badge per row and an Installed state.
@Composable
internal fun TvAddonStoreScreen(
    viewModel: AddonStoreViewModel,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val filtered by viewModel.filtered.collectAsStateWithLifecycle()
    val installed by viewModel.installed.collectAsStateWithLifecycle()
    val installing by viewModel.installing.collectAsStateWithLifecycle()
    val health by viewModel.health.collectAsStateWithLifecycle()

    LazyColumn(
        modifier = modifier.fillMaxSize(),
        contentPadding = PaddingValues(TvDimens.edge),
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
    ) {
        item { TvAddonActionButton(label = "Back", onClick = onBack, modifier = Modifier.width(180.dp)) }
        item {
            Column(verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs)) {
                Text("Discover add-ons", style = VortXTheme.type.screenTitle)
                Text(
                    "Browse the community add-on collection and install with one click. Each shows whether it " +
                        "is reachable right now.",
                    style = VortXTheme.type.body.copy(color = VortXTheme.colors.textSecondary),
                )
            }
        }
        when (val s = state) {
            AddonStoreViewModel.StoreState.Loading -> item {
                Text("Loading the add-on catalog…", style = VortXTheme.type.body)
            }
            AddonStoreViewModel.StoreState.Failed -> item {
                TvAddonActionButton(label = "Try again", onClick = viewModel::load, modifier = Modifier.width(240.dp))
            }
            is AddonStoreViewModel.StoreState.Content -> {
                if (filtered.isEmpty()) {
                    item { Text("No add-ons available.", style = VortXTheme.type.body) }
                } else {
                    items(filtered, key = { it.transportUrl }) { addon ->
                        TvStoreRow(
                            addon = addon,
                            health = health[AddonHealthStore.normalizeUrl(addon.transportUrl)] ?: AddonHealth.Unknown,
                            // Read the observed `installed` set so a row recomposes to Installed the moment
                            // its install confirms (isInstalled itself reads the same underlying state).
                            isInstalled = installed.let { viewModel.isInstalled(addon) },
                            isInstalling = addon.transportUrl in installing,
                            onInstall = { viewModel.install(addon) },
                        )
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalTvMaterial3Api::class)
@Composable
private fun TvStoreRow(
    addon: StoreAddon,
    health: AddonHealth,
    isInstalled: Boolean,
    isInstalling: Boolean,
    onInstall: () -> Unit,
) {
    val colors = VortXTheme.colors
    Surface(
        onClick = { if (!isInstalled) onInstall() },
        modifier = Modifier.fillMaxWidth(),
        shape = ClickableSurfaceDefaults.shape(shape = VortXShapes.control),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = colors.surface1,
            contentColor = colors.textPrimary,
            focusedContainerColor = colors.surface3,
            focusedContentColor = colors.textPrimary,
        ),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1.02f),
        border = ClickableSurfaceDefaults.border(
            focusedBorder = Border(border = BorderStroke(2.dp, colors.accentBright), shape = VortXShapes.control),
        ),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 16.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs)) {
                Text(addon.name, style = VortXTheme.type.cardTitle, maxLines = 1, overflow = TextOverflow.Ellipsis)
                if (addon.summary.isNotBlank()) {
                    Text(
                        addon.summary,
                        style = VortXTheme.type.label.copy(color = colors.textSecondary),
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                AddonHealthIndicator(health)
            }
            Spacer(Modifier.width(VortXTheme.spacing.md))
            Text(
                when {
                    isInstalled -> "Installed"
                    isInstalling -> "Installing…"
                    else -> "Install"
                },
                style = VortXTheme.type.label.copy(color = if (isInstalled) colors.accentBright else colors.accent),
            )
        }
    }
}

/// Configure an add-on on TV (Apple `ConfigureAddonView` tvOS): a full-screen QR of the add-on's
/// configuration page to finish on a phone, then paste the configured link back into Install by URL.
@Composable
internal fun TvAddonConfigureDialog(addon: InstalledAddon, onDismiss: () -> Unit) {
    val colors = VortXTheme.colors
    val url = addon.configureUrl
    val bitmap: Bitmap? = remember(url) { url?.let { qrBitmap(it) } }
    Dialog(onDismissRequest = onDismiss) {
        Column(
            modifier = Modifier
                .clip(RoundedCornerShape(20.dp))
                .background(colors.surface1)
                .padding(VortXTheme.spacing.xl),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
        ) {
            Text("Configure", style = VortXTheme.type.sectionTitle)
            Text(addon.name, style = VortXTheme.type.body.copy(color = colors.textSecondary))
            if (bitmap != null) {
                Box(
                    modifier = Modifier
                        .clip(RoundedCornerShape(16.dp))
                        .background(Color.White)
                        .padding(VortXTheme.spacing.md),
                ) {
                    Image(
                        bitmap = bitmap.asImageBitmap(),
                        contentDescription = "Configuration QR code",
                        modifier = Modifier.size(280.dp),
                    )
                }
            }
            Text(
                "Scan with your phone to open this add-on's settings, then paste the configured add-on link " +
                    "back into Install an add-on.",
                style = VortXTheme.type.label.copy(color = colors.textSecondary),
                textAlign = TextAlign.Center,
                modifier = Modifier.width(360.dp),
            )
            TvAddonActionButton(label = "Done", onClick = onDismiss, modifier = Modifier.width(200.dp))
        }
    }
}

/// A focusable TV action button local to this file (the one in TvAddonsScreen.kt is private there).
@OptIn(ExperimentalTvMaterial3Api::class)
@Composable
internal fun TvAddonActionButton(label: String, onClick: () -> Unit, modifier: Modifier = Modifier) {
    val colors = VortXTheme.colors
    Surface(
        onClick = onClick,
        modifier = modifier,
        shape = ClickableSurfaceDefaults.shape(shape = VortXShapes.control),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = colors.surface1,
            contentColor = colors.textPrimary,
            focusedContainerColor = colors.accent,
            focusedContentColor = colors.onAccent,
        ),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1.03f),
        border = ClickableSurfaceDefaults.border(
            focusedBorder = Border(border = BorderStroke(2.dp, colors.accentBright), shape = VortXShapes.control),
        ),
    ) {
        Text(
            label,
            modifier = Modifier.padding(horizontal = 20.dp, vertical = 14.dp),
            style = VortXTheme.type.body,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}
