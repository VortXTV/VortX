package com.vortx.android.ui.tv

import androidx.annotation.StringRes
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
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
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.error
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.tv.material3.Border
import androidx.tv.material3.ClickableSurfaceDefaults
import androidx.tv.material3.ExperimentalTvMaterial3Api
import androidx.tv.material3.Surface
import com.vortx.android.R
import com.vortx.android.debrid.DebridKeys
import com.vortx.android.debrid.DebridService
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXShapes
import com.vortx.android.ui.theme.VortXTheme

@Composable
internal fun TvDebridKeysScreen(
    keys: DebridKeys,
    accountIdentity: String,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val access = remember(keys) { DebridKeysTvAccess(keys) }
    val backFocus = remember { FocusRequester() }

    LazyColumn(
        modifier = modifier.fillMaxSize(),
        contentPadding = PaddingValues(TvDimens.edge),
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
    ) {
        item {
            TvDebridAction(
                label = stringResource(R.string.tv_debrid_action_back),
                onClick = onBack,
                modifier = Modifier.width(180.dp),
                focusRequester = backFocus,
                icon = { Icon(VortXIcons.back, contentDescription = null) },
            )
        }
        item {
            Column(verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs)) {
                Text(
                    stringResource(R.string.tv_debrid_services_title),
                    style = VortXTheme.type.sectionTitle,
                )
                Text(
                    stringResource(R.string.tv_debrid_services_description),
                    style = VortXTheme.type.body.copy(color = VortXTheme.colors.textSecondary),
                )
            }
        }
        DebridService.entries.forEach { service ->
            item(key = service.id) {
                val initialState = remember(access, accountIdentity, service) {
                    val snapshot = access.snapshot(service)
                    tvDebridEditorState(
                        hasValue = snapshot.hasValue,
                        durablyConfigured = snapshot.durablyConfigured,
                        storageUnavailable = snapshot.storageUnavailable,
                    )
                }
                TvDebridKeySection(
                    access = access,
                    service = service,
                    accountIdentity = accountIdentity,
                    initialState = initialState,
                )
            }
        }
    }

    LaunchedEffect(Unit) {
        if (tvDebridFocusTarget(TvDebridFocusEvent.SCREEN_ENTRY) == TvDebridFocusTarget.BACK) {
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

internal enum class TvDebridMutation {
    SAVE,
    CLEAR,
}

internal enum class TvDebridMutationTrigger {
    DPAD,
    IME,
}

internal enum class TvDebridFocusEvent {
    SCREEN_ENTRY,
    BACK_TO_SETTINGS,
}

internal enum class TvDebridFocusTarget {
    BACK,
    KEY_FIELD,
    SAVE,
    CLEAR,
    DEBRID_SERVICES,
}

internal fun tvDebridFocusTarget(event: TvDebridFocusEvent): TvDebridFocusTarget = when (event) {
    TvDebridFocusEvent.SCREEN_ENTRY -> TvDebridFocusTarget.BACK
    TvDebridFocusEvent.BACK_TO_SETTINGS -> TvDebridFocusTarget.DEBRID_SERVICES
}

internal enum class TvDebridStatus(@get:StringRes val textResource: Int) {
    NOT_SET(R.string.tv_debrid_status_not_set),
    SET(R.string.tv_debrid_status_set),
    CLEARED(R.string.tv_debrid_status_cleared),
    STORAGE_UNAVAILABLE(R.string.tv_debrid_status_storage_unavailable),
}

internal val TvDebridStatus.isAccessibilityError: Boolean
    get() = this == TvDebridStatus.STORAGE_UNAVAILABLE

internal data class TvDebridEditorState(
    val pendingKey: String,
    val hasValue: Boolean,
    val durablyConfigured: Boolean,
    val status: TvDebridStatus,
)

internal data class TvDebridStorageSnapshot(
    val hasValue: Boolean,
    val durablyConfigured: Boolean,
    val storageUnavailable: Boolean,
)

internal interface TvDebridKeyAccess {
    fun setKey(service: DebridService, value: String): Boolean
    fun snapshot(service: DebridService): TvDebridStorageSnapshot
}

private class DebridKeysTvAccess(
    private val keys: DebridKeys,
) : TvDebridKeyAccess {
    override fun setKey(service: DebridService, value: String): Boolean =
        keys.setKey(service, value)

    override fun snapshot(service: DebridService): TvDebridStorageSnapshot {
        val status = keys.status(service)
        return TvDebridStorageSnapshot(
            hasValue = status.hasValue,
            durablyConfigured = status.durablyConfigured,
            storageUnavailable = status.storageUnavailable,
        )
    }
}

internal data class TvDebridMutationResult(
    val editor: TvDebridEditorState,
    val focusTarget: TvDebridFocusTarget,
)

internal fun tvDebridEditorState(
    hasValue: Boolean,
    durablyConfigured: Boolean,
    storageUnavailable: Boolean,
): TvDebridEditorState = TvDebridEditorState(
    pendingKey = "",
    hasValue = hasValue,
    durablyConfigured = durablyConfigured,
    status = when {
        storageUnavailable -> TvDebridStatus.STORAGE_UNAVAILABLE
        durablyConfigured -> TvDebridStatus.SET
        else -> TvDebridStatus.NOT_SET
    },
)

internal fun TvDebridEditorState.afterMutation(
    mutation: TvDebridMutation,
    persisted: Boolean,
    hasValueAfter: Boolean,
    durablyConfiguredAfter: Boolean,
): TvDebridEditorState {
    val completed = persisted && when (mutation) {
        TvDebridMutation.SAVE -> hasValueAfter && durablyConfiguredAfter
        TvDebridMutation.CLEAR -> !hasValueAfter && !durablyConfiguredAfter
    }
    return copy(
        pendingKey = if (!completed && mutation == TvDebridMutation.SAVE) pendingKey else "",
        hasValue = hasValueAfter,
        durablyConfigured = durablyConfiguredAfter,
        status = when {
            !completed -> TvDebridStatus.STORAGE_UNAVAILABLE
            mutation == TvDebridMutation.SAVE -> TvDebridStatus.SET
            else -> TvDebridStatus.CLEARED
        },
    )
}

internal fun tvApplyDebridMutation(
    editor: TvDebridEditorState,
    access: TvDebridKeyAccess,
    service: DebridService,
    mutation: TvDebridMutation,
    value: String,
    trigger: TvDebridMutationTrigger,
): TvDebridMutationResult {
    val persisted = access.setKey(service, value)
    val after = access.snapshot(service)
    val updated = editor.afterMutation(
        mutation = mutation,
        persisted = persisted,
        hasValueAfter = after.hasValue,
        durablyConfiguredAfter = after.durablyConfigured,
    )
    return TvDebridMutationResult(
        editor = updated,
        focusTarget = when {
            trigger == TvDebridMutationTrigger.IME -> TvDebridFocusTarget.KEY_FIELD
            updated.status != TvDebridStatus.STORAGE_UNAVAILABLE ->
                TvDebridFocusTarget.KEY_FIELD
            mutation == TvDebridMutation.SAVE -> TvDebridFocusTarget.SAVE
            else -> TvDebridFocusTarget.CLEAR
        },
    )
}

@Composable
private fun TvDebridKeySection(
    access: TvDebridKeyAccess,
    service: DebridService,
    accountIdentity: String,
    initialState: TvDebridEditorState,
) {
    val colors = VortXTheme.colors
    val keyboardController = LocalSoftwareKeyboardController.current
    val keyFieldFocus = remember { FocusRequester() }
    val saveFocus = remember { FocusRequester() }
    val clearActionFocus = remember { FocusRequester() }
    var editor by remember(access, service, accountIdentity) { mutableStateOf(initialState) }

    fun requestFocus(target: TvDebridFocusTarget) {
        val requester = when (target) {
            TvDebridFocusTarget.KEY_FIELD -> keyFieldFocus
            TvDebridFocusTarget.SAVE -> saveFocus
            TvDebridFocusTarget.CLEAR -> clearActionFocus
            TvDebridFocusTarget.BACK,
            TvDebridFocusTarget.DEBRID_SERVICES,
            -> return
        }
        runCatching { requester.requestFocus() }
    }

    fun applyMutation(
        mutation: TvDebridMutation,
        value: String,
        trigger: TvDebridMutationTrigger,
    ) {
        val result = tvApplyDebridMutation(
            editor = editor,
            access = access,
            service = service,
            mutation = mutation,
            value = value,
            trigger = trigger,
        )
        editor = result.editor
        requestFocus(result.focusTarget)
        keyboardController?.hide()
    }

    fun save(trigger: TvDebridMutationTrigger) {
        if (editor.pendingKey.isBlank()) {
            if (trigger == TvDebridMutationTrigger.IME) {
                requestFocus(TvDebridFocusTarget.KEY_FIELD)
                keyboardController?.hide()
            }
            return
        }
        applyMutation(TvDebridMutation.SAVE, editor.pendingKey, trigger)
    }

    val statusColor = when (editor.status) {
        TvDebridStatus.SET -> colors.accent
        TvDebridStatus.STORAGE_UNAVAILABLE -> colors.danger
        TvDebridStatus.NOT_SET, TvDebridStatus.CLEARED -> colors.textTertiary
    }
    val statusText = stringResource(editor.status.textResource)

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(colors.surface1, RoundedCornerShape(18.dp))
            .padding(VortXTheme.spacing.md),
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(service.displayName, style = VortXTheme.type.cardTitle)
            Text(
                statusText,
                style = VortXTheme.type.label.copy(color = statusColor),
                modifier = Modifier.semantics {
                    liveRegion = LiveRegionMode.Polite
                    stateDescription = statusText
                    if (editor.status.isAccessibilityError) {
                        error(statusText)
                    }
                },
            )
        }
        OutlinedTextField(
            value = editor.pendingKey,
            onValueChange = { editor = editor.copy(pendingKey = it) },
            modifier = Modifier.fillMaxWidth().focusRequester(keyFieldFocus),
            label = {
                Text(
                    stringResource(
                        if (editor.hasValue) {
                            R.string.tv_debrid_replacement_api_key
                        } else {
                            R.string.tv_debrid_api_key
                        },
                    ),
                )
            },
            singleLine = true,
            visualTransformation = PasswordVisualTransformation(),
            keyboardOptions = KeyboardOptions(
                keyboardType = KeyboardType.Password,
                imeAction = ImeAction.Done,
            ),
            keyboardActions = KeyboardActions(
                onDone = { save(TvDebridMutationTrigger.IME) },
            ),
            colors = OutlinedTextFieldDefaults.colors(
                focusedBorderColor = colors.accent,
                unfocusedBorderColor = colors.hairline,
                cursorColor = colors.accent,
            ),
        )
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
        ) {
            TvDebridAction(
                label = stringResource(
                    if (editor.hasValue) {
                        R.string.tv_debrid_action_replace
                    } else {
                        R.string.tv_debrid_action_save
                    },
                ),
                onClick = { save(TvDebridMutationTrigger.DPAD) },
                enabled = editor.pendingKey.isNotBlank(),
                modifier = Modifier.weight(1f),
                focusRequester = saveFocus,
            )
            TvDebridAction(
                label = stringResource(R.string.tv_debrid_action_clear),
                onClick = {
                    applyMutation(
                        TvDebridMutation.CLEAR,
                        "",
                        TvDebridMutationTrigger.DPAD,
                    )
                },
                enabled = editor.hasValue || editor.status == TvDebridStatus.STORAGE_UNAVAILABLE,
                modifier = Modifier.weight(1f),
                focusRequester = clearActionFocus,
                danger = true,
            )
        }
    }
}

@OptIn(ExperimentalTvMaterial3Api::class)
@Composable
private fun TvDebridAction(
    label: String,
    onClick: () -> Unit,
    modifier: Modifier,
    enabled: Boolean = true,
    danger: Boolean = false,
    focusRequester: FocusRequester? = null,
    icon: (@Composable () -> Unit)? = null,
) {
    val colors = VortXTheme.colors
    val baseColor = when {
        !enabled -> colors.surface2
        danger -> colors.danger.copy(alpha = 0.16f)
        else -> colors.surface2
    }
    val contentColor = when {
        !enabled -> colors.textTertiary
        danger -> colors.danger
        else -> colors.textPrimary
    }
    Surface(
        onClick = onClick,
        enabled = enabled,
        modifier = modifier.then(
            if (focusRequester != null) {
                Modifier.focusRequester(focusRequester)
            } else {
                Modifier
            },
        ),
        shape = ClickableSurfaceDefaults.shape(shape = VortXShapes.control),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = baseColor,
            contentColor = contentColor,
            focusedContainerColor = if (danger) colors.danger else colors.accent,
            focusedContentColor = if (danger) Color.White else colors.onAccent,
        ),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1.04f),
        border = ClickableSurfaceDefaults.border(
            focusedBorder = Border(
                border = BorderStroke(2.dp, colors.accentBright),
                shape = VortXShapes.control,
            ),
        ),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 14.dp),
            horizontalArrangement = Arrangement.Center,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            icon?.invoke()
            if (icon != null) Spacer(Modifier.width(VortXTheme.spacing.xs))
            Text(label, style = VortXTheme.type.body.copy(fontWeight = FontWeight.SemiBold))
        }
    }
}
