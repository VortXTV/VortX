package com.vortx.android.ui.screens

import androidx.compose.foundation.Image
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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.ExperimentalMaterial3Api
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
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.vortx.android.ui.components.Chip
import com.vortx.android.ui.components.SurfaceCard
import com.vortx.android.ui.components.qrBitmap
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.viewmodel.AddonPairingViewModel

/// Install by QR (Apple `AddonPairingView`, TV/keyboardless flow): this device shows a QR of the relay
/// page URL; a phone opens that page and pastes add-on manifest URLs; this device installs each through the
/// hardened install path and shows its progress. Shared by phone + TV entry points.
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AddonPairingScreen(viewModel: AddonPairingViewModel, onBack: () -> Unit, modifier: Modifier = Modifier) {
    val state by viewModel.state.collectAsStateWithLifecycle()

    Column(modifier = modifier.fillMaxSize()) {
        TopAppBar(
            title = { Text("Install by QR", style = VortXTheme.type.screenTitle) },
            navigationIcon = {
                IconButton(onClick = onBack) { Icon(VortXIcons.back, contentDescription = "Back") }
            },
        )
        AddonPairingContent(state = state, onRetry = viewModel::start, modifier = Modifier.fillMaxSize())
    }
}

/// The pairing body, without app-bar chrome, so a TV host can drop it into its own focus scaffold.
@Composable
fun AddonPairingContent(
    state: AddonPairingViewModel.UiState,
    onRetry: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = VortXTheme.colors
    LazyColumn(
        modifier = modifier,
        contentPadding = PaddingValues(horizontal = VortXTheme.spacing.edge, vertical = VortXTheme.spacing.md),
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        when (state) {
            AddonPairingViewModel.UiState.Starting -> item {
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
                    modifier = Modifier.fillMaxWidth().padding(top = VortXTheme.spacing.xl),
                ) {
                    CircularProgressIndicator(color = colors.accent)
                    Text("Starting pairing…", style = VortXTheme.type.body.copy(color = colors.textSecondary))
                }
            }

            is AddonPairingViewModel.UiState.Failed -> item {
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
                    modifier = Modifier.fillMaxWidth().padding(top = VortXTheme.spacing.xl),
                ) {
                    Text(
                        state.message,
                        style = VortXTheme.type.body.copy(color = colors.danger),
                        textAlign = TextAlign.Center,
                    )
                    if (state.canRetry) {
                        Chip(label = "Try again", selected = true, onClick = onRetry)
                    }
                }
            }

            is AddonPairingViewModel.UiState.Active -> {
                item { QrBlock(state.pageUrl) }
                item {
                    Text(
                        "Scan with your phone, then paste any add-on's manifest URL on the page that opens. " +
                            "Each one installs here and syncs to your account.",
                        style = VortXTheme.type.body.copy(color = colors.textSecondary),
                        textAlign = TextAlign.Center,
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
                if (state.items.isNotEmpty()) {
                    items(state.items, key = { it.deliveryId }) { item -> PairingItemRow(item) }
                }
            }

            is AddonPairingViewModel.UiState.Ended -> {
                item {
                    Text(
                        "Pairing ended.",
                        style = VortXTheme.type.cardTitle,
                        modifier = Modifier.fillMaxWidth().padding(top = VortXTheme.spacing.lg),
                        textAlign = TextAlign.Center,
                    )
                }
                if (state.items.isNotEmpty()) {
                    items(state.items, key = { it.deliveryId }) { item -> PairingItemRow(item) }
                }
                item { Chip(label = "Pair again", selected = false, onClick = onRetry) }
            }
        }
    }
}

@Composable
private fun QrBlock(pageUrl: String) {
    val bitmap = remember(pageUrl) { qrBitmap(pageUrl) }
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
    ) {
        if (bitmap != null) {
            Box(
                modifier = Modifier
                    .clip(RoundedCornerShape(16.dp))
                    .background(Color.White)
                    .padding(VortXTheme.spacing.md),
            ) {
                Image(
                    bitmap = bitmap.asImageBitmap(),
                    contentDescription = "Pairing QR code",
                    modifier = Modifier.size(240.dp),
                )
            }
        }
        Text(
            pageUrl,
            style = VortXTheme.type.label.copy(color = VortXTheme.colors.textTertiary),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun PairingItemRow(item: AddonPairingViewModel.PairingItem) {
    val colors = VortXTheme.colors
    SurfaceCard(modifier = Modifier.fillMaxWidth()) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(VortXTheme.spacing.md),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
        ) {
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(item.label, style = VortXTheme.type.cardTitle, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(
                    item.url,
                    style = VortXTheme.type.label.copy(color = colors.textTertiary),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            when (item.status) {
                AddonPairingViewModel.PairingItemStatus.INSTALLING ->
                    CircularProgressIndicator(color = colors.accent, modifier = Modifier.size(18.dp))
                AddonPairingViewModel.PairingItemStatus.INSTALLED -> StatusDot("Installed", colors.accentBright)
                AddonPairingViewModel.PairingItemStatus.FAILED -> StatusDot("Failed", colors.danger)
            }
        }
    }
}

@Composable
private fun StatusDot(label: String, color: Color) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Box(modifier = Modifier.size(8.dp).clip(CircleShape).background(color))
        Text(label, style = VortXTheme.type.label.copy(color = color))
    }
}
