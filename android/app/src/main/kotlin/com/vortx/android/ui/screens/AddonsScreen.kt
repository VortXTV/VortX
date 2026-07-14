package com.vortx.android.ui.screens

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
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import coil3.compose.AsyncImage
import com.vortx.android.model.InstalledAddon
import com.vortx.android.ui.UiState
import com.vortx.android.ui.components.Chip
import com.vortx.android.ui.components.EmptyState
import com.vortx.android.ui.components.ErrorState
import com.vortx.android.ui.components.SurfaceCard
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.viewmodel.AddonsViewModel

/// Add-on management (S04, DESIGN-SYSTEM.md §4 "Add-ons"): title + a short debrid explainer ->
/// install-by-URL form -> installed list as surface-card rows. Mirrors Apple `AddonsView`'s core loop;
/// health probing, QR pairing, drag-reorder, and the add-on catalog/store browser are deferred (see the
/// S04 handoff report -- the store browser has no engine model to drive it, and the rest are
/// secondary affordances beyond this session's "engine breadth" scope).
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AddonsScreen(viewModel: AddonsViewModel, onBack: () -> Unit, modifier: Modifier = Modifier) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val urlInput by viewModel.urlInput.collectAsStateWithLifecycle()
    val installing by viewModel.installing.collectAsStateWithLifecycle()
    val installMessage by viewModel.installMessage.collectAsStateWithLifecycle()
    val colors = VortXTheme.colors

    Column(modifier = modifier.fillMaxSize()) {
        TopAppBar(
            title = { Text("Add-ons", style = VortXTheme.type.screenTitle) },
            navigationIcon = {
                IconButton(onClick = onBack) {
                    Icon(VortXIcons.back, contentDescription = "Back")
                }
            },
        )
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
            when (val s = state) {
                is UiState.Loading -> item { EmptyState("Loading your add-ons…") }
                is UiState.Error -> item { ErrorState(s.message, onRetry = { viewModel.load() }) }
                is UiState.Success -> {
                    if (s.data.isEmpty()) {
                        item { EmptyState("No add-ons yet. Paste a manifest URL above to install one.") }
                    } else {
                        items(s.data, key = { it.transportUrl }) { addon ->
                            AddonRow(addon = addon, onRemove = { viewModel.remove(addon) })
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun AddonRow(addon: InstalledAddon, onRemove: () -> Unit) {
    val colors = VortXTheme.colors
    SurfaceCard(modifier = Modifier.fillMaxWidth()) {
        Row(
            modifier = Modifier.padding(VortXTheme.spacing.md),
            horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
        ) {
            Box(
                modifier = Modifier.size(48.dp),
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
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(addon.name, style = VortXTheme.type.cardTitle, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(
                    text = listOfNotNull(
                        if (addon.providesStreams) "Streams" else null,
                        addon.host,
                    ).joinToString(" · "),
                    style = VortXTheme.type.label.copy(color = colors.textTertiary),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            if (!addon.isProtected) {
                IconButton(onClick = onRemove) {
                    Icon(VortXIcons.delete, contentDescription = "Remove ${addon.name}", tint = colors.danger)
                }
            }
        }
    }
}
