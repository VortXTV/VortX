package com.vortx.android.ui.screens

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
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.IconButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import coil3.compose.AsyncImage
import com.vortx.android.engine.AddonHealth
import com.vortx.android.engine.AddonHealthStore
import com.vortx.android.model.StoreAddon
import com.vortx.android.ui.components.Chip
import com.vortx.android.ui.components.EmptyState
import com.vortx.android.ui.components.SurfaceCard
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.viewmodel.AddonStoreViewModel

/// Discover add-ons: a browsable, searchable store over the official community collection (Apple
/// `AddonStoreView`). One-tap Install goes through the engine, so an installed add-on syncs to the account
/// and the official apps exactly like a pasted manifest URL; each row carries a live reachability badge.
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AddonStoreScreen(viewModel: AddonStoreViewModel, onBack: () -> Unit, modifier: Modifier = Modifier) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val query by viewModel.query.collectAsStateWithLifecycle()
    val filtered by viewModel.filtered.collectAsStateWithLifecycle()
    val installed by viewModel.installed.collectAsStateWithLifecycle()
    val installing by viewModel.installing.collectAsStateWithLifecycle()
    val health by viewModel.health.collectAsStateWithLifecycle()
    val colors = VortXTheme.colors

    Column(modifier = modifier.fillMaxSize()) {
        TopAppBar(
            title = { Text("Discover add-ons", style = VortXTheme.type.screenTitle) },
            navigationIcon = {
                IconButton(onClick = onBack) { Icon(VortXIcons.back, contentDescription = "Back") }
            },
        )
        LazyColumn(
            contentPadding = PaddingValues(horizontal = VortXTheme.spacing.edge, vertical = VortXTheme.spacing.md),
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
            modifier = Modifier.fillMaxSize(),
        ) {
            item {
                Text(
                    text = "Browse the community add-on collection and install with one tap. Each shows " +
                        "whether it is reachable right now. Installed add-ons sync to your account and the " +
                        "official apps.",
                    style = VortXTheme.type.body.copy(color = colors.textSecondary),
                )
            }
            item {
                OutlinedTextField(
                    value = query,
                    onValueChange = viewModel::onQueryChange,
                    placeholder = { Text("Search add-ons", style = VortXTheme.type.body) },
                    leadingIcon = { Icon(VortXIcons.search, contentDescription = null, tint = colors.textTertiary) },
                    singleLine = true,
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedBorderColor = colors.accent,
                        unfocusedBorderColor = colors.hairline,
                        cursorColor = colors.accent,
                    ),
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            when (val s = state) {
                AddonStoreViewModel.StoreState.Loading -> item { EmptyState("Loading the add-on catalog…") }
                AddonStoreViewModel.StoreState.Failed -> item {
                    EmptyState(
                        hint = "Couldn't load the add-on catalog. Check your connection and try again.",
                        actionLabel = "Try again",
                        onAction = viewModel::load,
                    )
                }
                is AddonStoreViewModel.StoreState.Content -> {
                    if (filtered.isEmpty()) {
                        item { EmptyState("No add-ons match \"$query\".") }
                    } else {
                        items(filtered, key = { it.transportUrl }) { addon ->
                            StoreRow(
                                addon = addon,
                                health = health[AddonHealthStore.normalizeUrl(addon.transportUrl)] ?: AddonHealth.Unknown,
                                // Read the observed `installed` set so a row flips to Installed the instant
                                // its install confirms (isInstalled reads the same underlying state).
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
}

@Composable
private fun StoreRow(
    addon: StoreAddon,
    health: AddonHealth,
    isInstalled: Boolean,
    isInstalling: Boolean,
    onInstall: () -> Unit,
) {
    val colors = VortXTheme.colors
    SurfaceCard(modifier = Modifier.fillMaxWidth()) {
        Column(
            modifier = Modifier.padding(VortXTheme.spacing.md),
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
        ) {
            Row(horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md)) {
                Box(
                    modifier = Modifier
                        .size(52.dp)
                        .clip(RoundedCornerShape(12.dp)),
                    contentAlignment = Alignment.Center,
                ) {
                    if (addon.logo.isNullOrBlank()) {
                        Icon(VortXIcons.addon, contentDescription = null, tint = colors.textTertiary)
                    } else {
                        AsyncImage(model = addon.logo, contentDescription = addon.name, modifier = Modifier.fillMaxSize())
                    }
                }
                Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(addon.name, style = VortXTheme.type.cardTitle, maxLines = 2, overflow = TextOverflow.Ellipsis)
                    if (addon.summary.isNotBlank()) {
                        Text(
                            addon.summary,
                            style = VortXTheme.type.label.copy(color = colors.textSecondary),
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                    if (addon.types.isNotEmpty()) {
                        Text(
                            addon.types.take(4).joinToString(" · ") { it.replaceFirstChar(Char::uppercase) },
                            style = VortXTheme.type.label.copy(color = colors.textTertiary),
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                    AddonHealthIndicator(health)
                }
            }
            Row(modifier = Modifier.fillMaxWidth()) {
                Spacer(Modifier.weight(1f))
                if (isInstalled) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        Icon(VortXIcons.checkmarkCircle, contentDescription = null, tint = colors.accentBright, modifier = Modifier.size(18.dp))
                        Text("Installed", style = VortXTheme.type.label.copy(color = colors.accentBright))
                    }
                } else {
                    Chip(
                        label = if (isInstalling) "Installing…" else "Install",
                        selected = true,
                        enabled = !isInstalling,
                        leadingIcon = VortXIcons.add,
                        onClick = onInstall,
                    )
                }
            }
        }
    }
}
