package com.vortx.android.ui.tv

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.tv.material3.Border
import androidx.tv.material3.ClickableSurfaceDefaults
import androidx.tv.material3.ExperimentalTvMaterial3Api
import androidx.tv.material3.Surface
import com.vortx.android.R
import com.vortx.android.engine.AddonHealth
import com.vortx.android.engine.AddonHealthStore
import com.vortx.android.model.InstalledAddon
import com.vortx.android.ui.UiState
import com.vortx.android.ui.screens.AddonHealthIndicator
import com.vortx.android.ui.theme.VortXShapes
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.viewmodel.AddonsViewModel

internal enum class TvAddonsFocusEvent {
    SCREEN_ENTRY,
    BACK_TO_SETTINGS,
}

internal enum class TvAddonsFocusTarget {
    BACK,
    SETTINGS_ADDONS,
}

internal fun tvAddonsFocusTarget(event: TvAddonsFocusEvent): TvAddonsFocusTarget = when (event) {
    TvAddonsFocusEvent.SCREEN_ENTRY -> TvAddonsFocusTarget.BACK
    TvAddonsFocusEvent.BACK_TO_SETTINGS -> TvAddonsFocusTarget.SETTINGS_ADDONS
}

/** TV add-on status surface. Network ownership stays in the shared [AddonsViewModel]. */
@Composable
internal fun TvAddonsScreen(
    viewModel: AddonsViewModel,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val health by viewModel.health.collectAsStateWithLifecycle()
    val installed = (state as? UiState.Success)?.data.orEmpty()
    val backFocus = remember { FocusRequester() }

    LaunchedEffect(viewModel) {
        viewModel.onScreenEntry()
    }

    LazyColumn(
        modifier = modifier.fillMaxSize(),
        contentPadding = PaddingValues(TvDimens.edge),
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
    ) {
        item {
            TvAddonAction(
                label = stringResource(R.string.tv_debrid_action_back),
                onClick = onBack,
                focusRequester = backFocus,
                modifier = Modifier.width(180.dp),
            )
        }
        item {
            Column(verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs)) {
                Text(stringResource(R.string.addons_title), style = VortXTheme.type.screenTitle)
                Text(
                    stringResource(R.string.addon_health_tv_description),
                    style = VortXTheme.type.body.copy(color = VortXTheme.colors.textSecondary),
                )
            }
        }
        if (installed.isNotEmpty()) {
            item {
                TvAddonAction(
                    label = stringResource(R.string.addon_health_recheck),
                    onClick = viewModel::recheckHealth,
                    modifier = Modifier.width(240.dp),
                )
            }
        }
        when (val current = state) {
            UiState.Loading -> item {
                Text(stringResource(R.string.addon_health_loading), style = VortXTheme.type.body)
            }
            is UiState.Error -> item {
                TvAddonAction(
                    label = stringResource(R.string.addon_health_try_again, current.message),
                    onClick = viewModel::load,
                )
            }
            is UiState.Success -> {
                if (current.data.isEmpty()) {
                    item { Text(stringResource(R.string.addon_health_empty), style = VortXTheme.type.body) }
                } else {
                    items(current.data, key = InstalledAddon::transportUrl) { addon ->
                        TvAddonRow(
                            addon = addon,
                            health = health[AddonHealthStore.normalizeUrl(addon.transportUrl)]
                                ?: AddonHealth.Unknown,
                            onClick = { if (!addon.isProtected) viewModel.toggleAddon(addon) },
                        )
                    }
                }
            }
        }
    }

    LaunchedEffect(Unit) {
        if (tvAddonsFocusTarget(TvAddonsFocusEvent.SCREEN_ENTRY) == TvAddonsFocusTarget.BACK) {
            var focused = false
            repeat(3) {
                if (!focused) {
                    focused = runCatching { backFocus.requestFocus() }.getOrDefault(false)
                    if (!focused) withFrameNanos { }
                }
            }
        }
    }
}

@OptIn(ExperimentalTvMaterial3Api::class)
@Composable
private fun TvAddonRow(
    addon: InstalledAddon,
    health: AddonHealth,
    onClick: () -> Unit,
) {
    val colors = VortXTheme.colors
    Surface(
        onClick = onClick,
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
            focusedBorder = Border(
                border = BorderStroke(2.dp, colors.accentBright),
                shape = VortXShapes.control,
            ),
        ),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 16.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs),
            ) {
                Text(
                    addon.name,
                    style = VortXTheme.type.cardTitle,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    listOfNotNull(
                        if (addon.isDisabled) stringResource(R.string.addon_state_off) else null,
                        if (addon.providesStreams) stringResource(R.string.addon_capability_streams) else null,
                        addon.host,
                    ).joinToString(" · "),
                    style = VortXTheme.type.label.copy(color = colors.textTertiary),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                AddonHealthIndicator(health)
            }
            Spacer(Modifier.width(VortXTheme.spacing.md))
            Text(
                when {
                    addon.isProtected -> stringResource(R.string.addon_health_managed)
                    addon.isDisabled -> stringResource(R.string.addon_health_turn_on)
                    else -> stringResource(R.string.addon_health_turn_off)
                },
                style = VortXTheme.type.label.copy(
                    color = colors.textSecondary,
                    fontWeight = FontWeight.Medium,
                ),
            )
        }
    }
}

@OptIn(ExperimentalTvMaterial3Api::class)
@Composable
private fun TvAddonAction(
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    focusRequester: FocusRequester? = null,
) {
    val colors = VortXTheme.colors
    Surface(
        onClick = onClick,
        modifier = modifier.then(
            if (focusRequester == null) Modifier else Modifier.focusRequester(focusRequester),
        ),
        shape = ClickableSurfaceDefaults.shape(shape = VortXShapes.control),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = colors.surface1,
            contentColor = colors.textPrimary,
            focusedContainerColor = colors.accent,
            focusedContentColor = colors.onAccent,
        ),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1.03f),
        border = ClickableSurfaceDefaults.border(
            focusedBorder = Border(
                border = BorderStroke(2.dp, colors.accentBright),
                shape = VortXShapes.control,
            ),
        ),
    ) {
        Text(
            label,
            modifier = Modifier.padding(horizontal = 20.dp, vertical = 14.dp),
            style = VortXTheme.type.body.copy(fontWeight = FontWeight.SemiBold),
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
    }
}
