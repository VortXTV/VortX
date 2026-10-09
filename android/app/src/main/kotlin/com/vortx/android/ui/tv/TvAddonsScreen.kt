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
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
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
import com.vortx.android.data.AddonManagementTarget
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

internal enum class TvAddonMoveDirection(val delta: Int) { UP(-1), DOWN(1) }

internal data class TvAddonMoveResult(
    val order: List<String>,
    val focusDirection: TvAddonMoveDirection,
)

/** Pure one-step priority move. Keys are transport URLs so identity survives list movement. */
internal fun tvAddonMove(
    currentUrls: List<String>,
    transportUrl: String,
    direction: TvAddonMoveDirection,
): TvAddonMoveResult? {
    val from = currentUrls.indexOf(transportUrl)
    val to = from + direction.delta
    if (from < 0 || to !in currentUrls.indices) return null
    val next = currentUrls.toMutableList().apply { add(to, removeAt(from)) }
    val focusDirection = when {
        direction == TvAddonMoveDirection.UP && to == 0 -> TvAddonMoveDirection.DOWN
        direction == TvAddonMoveDirection.DOWN && to == next.lastIndex -> TvAddonMoveDirection.UP
        else -> direction
    }
    return TvAddonMoveResult(next, focusDirection)
}

/** TV add-on status surface. Network ownership stays in the shared [AddonsViewModel]. */
@Composable
internal fun TvAddonsScreen(
    viewModel: AddonsViewModel,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
    onDiscover: () -> Unit = {},
    onInstallByQr: () -> Unit = {},
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val health by viewModel.health.collectAsStateWithLifecycle()
    val access by viewModel.managementAccess.collectAsStateWithLifecycle()
    // Plain composition value: callbacks must retain their render's owner, not read delegated State later.
    val renderedOwner = access.owner
    val urlInput by viewModel.urlInput.collectAsStateWithLifecycle()
    val installing by viewModel.installing.collectAsStateWithLifecycle()
    val installMessage by viewModel.installMessage.collectAsStateWithLifecycle()
    val pendingUpdate by viewModel.pendingUpdate.collectAsStateWithLifecycle()
    val mutating by viewModel.mutating.collectAsStateWithLifecycle()
    val changeMessage by viewModel.changeUrlMessage.collectAsStateWithLifecycle()
    val changeDone by viewModel.changeUrlDone.collectAsStateWithLifecycle()
    val actionMessage by viewModel.actionMessage.collectAsStateWithLifecycle()
    val removeDone by viewModel.removeDone.collectAsStateWithLifecycle()
    val installed = (state as? UiState.Success)?.data.orEmpty()
    val latestInstalled by rememberUpdatedState(installed)
    val backFocus = remember { FocusRequester() }
    val listState = rememberLazyListState()
    var moveFocus by remember { mutableStateOf<TvAddonMoveFocus?>(null) }
    var moveFocusSequence by remember { mutableStateOf(0) }
    var changeTarget by remember { mutableStateOf<AddonManagementTarget?>(null) }
    var removeTarget by remember { mutableStateOf<AddonManagementTarget?>(null) }
    var replacementUrl by remember { mutableStateOf("") }
    var actionFocus by remember { mutableStateOf<TvAddonActionFocus?>(null) }
    var actionFocusSequence by remember { mutableStateOf(0) }
    var backFocusSequence by remember { mutableStateOf(0) }
    var observedDone by remember { mutableStateOf(changeDone to removeDone) }

    fun closeManagementDialog() {
        val target = changeTarget ?: removeTarget
        val kind = if (changeTarget != null) TvAddonDialogKind.CHANGE_URL else TvAddonDialogKind.REMOVE
        changeTarget = null; removeTarget = null
        target?.addon?.let { actionFocus = TvAddonActionFocus(it.transportUrl, kind); actionFocusSequence += 1 }
    }

    LaunchedEffect(access.owner) {
        if (changeTarget?.owner?.let { it != access.owner } == true || removeTarget?.owner?.let { it != access.owner } == true) {
            closeManagementDialog()
            actionFocus = null
            backFocusSequence += 1
        }
    }
    LaunchedEffect(changeDone, removeDone) {
        if (observedDone != (changeDone to removeDone)) {
            observedDone = changeDone to removeDone
            closeManagementDialog()
            // The success reload is asynchronous: never focus an old row that is about to disappear.
            actionFocus = null
            backFocusSequence += 1
        }
    }
    LaunchedEffect(backFocusSequence) {
        if (backFocusSequence > 0) {
            listState.scrollToItem(0)
            withFrameNanos { }; runCatching { backFocus.requestFocus() }
        }
    }
    LaunchedEffect(actionFocusSequence, installed) {
        if (actionFocus != null && installed.none { it.transportUrl == actionFocus?.transportUrl }) {
            listState.scrollToItem(0)
            withFrameNanos { }; runCatching { backFocus.requestFocus() }
            actionFocus = null
        }
    }

    changeTarget?.let { target ->
        TvAddonManagementDialog(
            title = "Change URL — ${target.addon?.name.orEmpty()}",
            description = "Paste the configured manifest URL. The new add-on is validated before the old endpoint is replaced.",
            confirmLabel = "Change URL", busy = mutating, message = changeMessage,
            url = replacementUrl, onUrlChange = { replacementUrl = it },
            confirmEnabled = replacementUrl.isNotBlank() && replacementUrl.trim() != target.addon?.transportUrl,
            onConfirm = { viewModel.changeAddonUrl(target, replacementUrl) }, onDismiss = ::closeManagementDialog,
        )
    }
    removeTarget?.let { target ->
        TvAddonManagementDialog(title = "Remove ${target.addon?.name.orEmpty()}?",
            description = "Remove this add-on from the account. Its catalogs and sources will no longer be available to profiles using it.",
            confirmLabel = "Remove", busy = mutating, message = actionMessage,
            onConfirm = { viewModel.remove(target) }, onDismiss = ::closeManagementDialog)
    }
    if (pendingUpdate != null) {
        TvAddonManagementDialog(
            title = stringResource(R.string.addon_update_confirm_title),
            description = stringResource(R.string.addon_update_confirm_message),
            confirmLabel = stringResource(R.string.addon_update_confirm_button), busy = mutating,
            message = null, onConfirm = viewModel::confirmUpdate, onDismiss = viewModel::cancelUpdate,
        )
    }

    fun moveAddon(transportUrl: String, direction: TvAddonMoveDirection) {
        // Re-read the latest observed set on every press: a stale row callback must not resurrect an
        // add-on removed since composition, and newly installed rows participate in the move order.
        val latestUrls = latestInstalled.map(InstalledAddon::transportUrl)
        val result = tvAddonMove(latestUrls, transportUrl, direction) ?: return
        viewModel.applyOrder(result.order, renderedOwner)
        moveFocusSequence += 1
        moveFocus = TvAddonMoveFocus(transportUrl, result.focusDirection)
    }

    // Per-add-on Configure QR (Apple `ConfigureAddonView` tvOS path): TV has no browser, so it shows the
    // add-on's configuration page as a QR to finish on a phone. Null when no Configure sheet is open.
    var configureAddon by remember { mutableStateOf<InstalledAddon?>(null) }
    configureAddon?.let { addon ->
        TvAddonConfigureDialog(addon = addon, onDismiss = { configureAddon = null })
    }
    var showCommunityProviders by remember { mutableStateOf(false) }
    if (showCommunityProviders) {
        TvCommunityJsDialog(onDismiss = { showCommunityProviders = false })
    }

    LaunchedEffect(viewModel) {
        viewModel.onScreenEntry()
    }

    LazyColumn(
        state = listState,
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
        item {
            Column(verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md)) {
                TvAddonUrlField(urlInput, viewModel::onUrlChange, !mutating && access.canManageInstalled)
                TvAddonAction(if (installing) "Installing…" else "Install by URL", { viewModel.install(renderedOwner) },
                    Modifier.width(260.dp), enabled = !mutating && access.canManageInstalled && urlInput.isNotBlank())
                access.reason?.let { Text(it, style = VortXTheme.type.label.copy(color = VortXTheme.colors.textSecondary)) }
                installMessage?.let { (message, failed) -> Text(message,
                    style = VortXTheme.type.label.copy(color = if (failed) VortXTheme.colors.danger else VortXTheme.colors.textSecondary)) }
                actionMessage?.let { (message, failed) -> Text(message,
                    style = VortXTheme.type.label.copy(color = if (failed) VortXTheme.colors.danger else VortXTheme.colors.textSecondary)) }
            }
        }
        item {
            Row(horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md)) {
                TvAddonAction(
                    label = stringResource(R.string.addon_install_by_qr),
                    onClick = onInstallByQr,
                    modifier = Modifier.width(260.dp),
                )
                TvAddonAction(
                    label = stringResource(R.string.addon_discover),
                    onClick = onDiscover,
                    modifier = Modifier.width(260.dp),
                )
                TvAddonAction(
                    label = "Community JS providers",
                    onClick = { showCommunityProviders = true },
                    modifier = Modifier.width(260.dp),
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
                        val actions = tvAddonManagementActions(addon, access.canManageInstalled)
                        TvAddonRow(
                            addon = addon,
                            health = health[AddonHealthStore.normalizeUrl(addon.transportUrl)]
                                ?: AddonHealth.Unknown,
                            onClick = { if (!addon.isProtected) viewModel.toggleAddon(addon, renderedOwner) },
                            enabled = !mutating,
                            onConfigure = if (actions.configure) {
                                { configureAddon = addon }
                            } else {
                                null
                            },
                            onChangeUrl = if (actions.changeUrl) { {
                                viewModel.captureManagementTarget(addon, renderedOwner)?.let { target ->
                                    viewModel.onChangeUrlOpen(target); replacementUrl = addon.transportUrl; changeTarget = target
                                }
                            } } else null,
                            onRemove = if (actions.remove) { {
                                viewModel.captureManagementTarget(addon, renderedOwner)?.let { viewModel.onRemoveOpen(); removeTarget = it }
                            } } else null,
                            onMoveUp = { moveAddon(addon.transportUrl, TvAddonMoveDirection.UP) },
                            onMoveDown = { moveAddon(addon.transportUrl, TvAddonMoveDirection.DOWN) },
                            canMoveUp = current.data.indexOfFirst { it.transportUrl == addon.transportUrl } > 0,
                            canMoveDown = current.data.indexOfFirst { it.transportUrl == addon.transportUrl } < current.data.lastIndex,
                            moveFocus = moveFocus,
                            moveFocusSequence = moveFocusSequence,
                            actionFocus = actionFocus,
                            actionFocusSequence = actionFocusSequence,
                            onActionFocusRestored = { actionFocus = null },
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

private data class TvAddonMoveFocus(
    val transportUrl: String,
    val direction: TvAddonMoveDirection,
)
private data class TvAddonActionFocus(val transportUrl: String, val kind: TvAddonDialogKind)

@OptIn(ExperimentalTvMaterial3Api::class)
@Composable
private fun TvAddonRow(
    addon: InstalledAddon,
    health: AddonHealth,
    onClick: () -> Unit,
    enabled: Boolean,
    onConfigure: (() -> Unit)? = null,
    onChangeUrl: (() -> Unit)? = null,
    onRemove: (() -> Unit)? = null,
    onMoveUp: () -> Unit,
    onMoveDown: () -> Unit,
    canMoveUp: Boolean,
    canMoveDown: Boolean,
    moveFocus: TvAddonMoveFocus?,
    moveFocusSequence: Int,
    actionFocus: TvAddonActionFocus?,
    actionFocusSequence: Int,
    onActionFocusRestored: () -> Unit,
) {
    val colors = VortXTheme.colors
    val upFocus = remember(addon.transportUrl) { FocusRequester() }
    val downFocus = remember(addon.transportUrl) { FocusRequester() }
    val changeFocus = remember(addon.transportUrl) { FocusRequester() }
    val removeFocus = remember(addon.transportUrl) { FocusRequester() }
    LaunchedEffect(actionFocusSequence, actionFocus, enabled) {
        if (actionFocus?.transportUrl == addon.transportUrl) {
            withFrameNanos { }
            val focused = runCatching { if (actionFocus.kind == TvAddonDialogKind.CHANGE_URL) changeFocus.requestFocus() else removeFocus.requestFocus() }.getOrDefault(false)
            if (focused) onActionFocusRestored()
        }
    }
    LaunchedEffect(moveFocusSequence, moveFocus) {
        if (moveFocus?.transportUrl == addon.transportUrl) {
            withFrameNanos { }
            runCatching {
                when (moveFocus.direction) {
                    TvAddonMoveDirection.UP -> upFocus.requestFocus()
                    TvAddonMoveDirection.DOWN -> downFocus.requestFocus()
                }
            }
        }
    }
    Column(
        modifier = Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
    ) {
        Surface(
            onClick = onClick,
            enabled = enabled && !addon.isProtected,
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
                            addon.capabilities,
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
        Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md)) {
            if (onConfigure != null) {
                TvAddonAction(
                    label = stringResource(R.string.addon_configure),
                    onClick = onConfigure,
                    modifier = Modifier.weight(1f), enabled = enabled,
                )
            }
            if (onChangeUrl != null) TvAddonAction("Change URL", onChangeUrl, Modifier.weight(1f), changeFocus, enabled)
            if (onRemove != null) TvAddonAction("Remove", onRemove, Modifier.weight(1f), removeFocus, enabled)
            TvAddonAction(
                label = "Move up",
                onClick = onMoveUp,
                modifier = Modifier.weight(1f),
                focusRequester = upFocus,
                enabled = canMoveUp && enabled,
            )
            TvAddonAction(
                label = "Move down",
                onClick = onMoveDown,
                modifier = Modifier.weight(1f),
                focusRequester = downFocus,
                enabled = canMoveDown && enabled,
            )
        }
    }
}

@OptIn(ExperimentalTvMaterial3Api::class)
@Composable
internal fun TvAddonAction(
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    focusRequester: FocusRequester? = null,
    enabled: Boolean = true,
) {
    val colors = VortXTheme.colors
    Surface(
        onClick = onClick,
        enabled = enabled,
        modifier = modifier.then(
            if (focusRequester == null) Modifier else Modifier.focusRequester(focusRequester),
        ),
        shape = ClickableSurfaceDefaults.shape(shape = VortXShapes.control),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = colors.surface1,
            contentColor = if (enabled) colors.textPrimary else colors.textTertiary,
            focusedContainerColor = colors.accent,
            focusedContentColor = colors.onAccent,
            disabledContainerColor = colors.surface1,
            disabledContentColor = colors.textTertiary,
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
