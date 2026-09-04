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
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.error
import androidx.compose.ui.semantics.isTraversalGroup
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
import androidx.tv.material3.LocalContentColor
import androidx.tv.material3.Surface
import com.vortx.android.R
import com.vortx.android.debrid.DebridKeys
import com.vortx.android.debrid.DebridService
import com.vortx.android.usenet.UsenetProviderCredentials
import com.vortx.android.usenet.UsenetProviderStore
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
    val context = LocalContext.current.applicationContext
    val usenetStore = remember(keys) {
        UsenetProviderStore(context, keys::ownerToken, keys::mutateCurrentOwner)
    }
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
                icon = VortXIcons.back,
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
        item(key = "usenet-provider") {
            TvUsenetProviderSection(
                store = usenetStore,
                ownerKnown = keys.ownerToken() != null,
                accountIdentity = accountIdentity,
            )
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

@Composable
private fun TvUsenetProviderSection(
    store: UsenetProviderStore,
    ownerKnown: Boolean,
    accountIdentity: String,
) {
    val colors = VortXTheme.colors
    val keyboardController = LocalSoftwareKeyboardController.current
    val hostFocus = remember { FocusRequester() }
    val saveFocus = remember { FocusRequester() }
    val clearFocus = remember { FocusRequester() }
    var host by remember(accountIdentity) { mutableStateOf("") }
    var port by remember(accountIdentity) { mutableStateOf("563") }
    var username by remember(accountIdentity) { mutableStateOf("") }
    var password by remember(accountIdentity) { mutableStateOf("") }
    var connections by remember(accountIdentity) { mutableStateOf("4") }
    var status by remember(store, ownerKnown, accountIdentity) {
        mutableStateOf(if (ownerKnown && store.isConfigured()) "Configured (credentials redacted)" else "Not configured")
    }

    fun request(requester: FocusRequester) = runCatching { requester.requestFocus() }
    fun save() {
        val credentials = UsenetProviderCredentials(
            host = host,
            port = port.toIntOrNull() ?: 0,
            username = username,
            password = password,
            maxConnections = connections.toIntOrNull() ?: 0,
            useSSL = true,
        )
        val saved = ownerKnown && credentials.isValid && store.save(credentials)
        status = if (saved && store.isConfigured()) "Configured (credentials redacted)" else "Unable to save secure Usenet provider"
        if (saved) {
            username = ""
            password = ""
            keyboardController?.hide()
            request(hostFocus)
        } else {
            request(saveFocus)
        }
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(colors.surface1, RoundedCornerShape(18.dp))
            .semantics { isTraversalGroup = true }
            .padding(VortXTheme.spacing.md),
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
    ) {
        Text("Usenet provider", style = VortXTheme.type.cardTitle)
        Text(
            status,
            style = VortXTheme.type.label.copy(color = if (status.startsWith("Configured")) colors.accentBright else colors.textSecondary),
            modifier = Modifier.semantics {
                liveRegion = LiveRegionMode.Polite
                stateDescription = "Usenet provider: $status"
            },
        )
        Text("TLS is required. Credentials are encrypted and never displayed after saving.", style = VortXTheme.type.label.copy(color = colors.textSecondary))
        TvUsenetField("Host", host, { host = it }, hostFocus, KeyboardType.Uri)
        TvUsenetField("Port", port, { port = it }, null, KeyboardType.Number)
        TvUsenetField("Username", username, { username = it }, null, KeyboardType.Text)
        TvUsenetField("Password", password, { password = it }, null, KeyboardType.Password, password = true)
        TvUsenetField("Connections", connections, { connections = it }, null, KeyboardType.Number)
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
            TvDebridAction(
                label = "Save provider",
                accessibilityLabel = "Usenet provider: Save TLS credentials",
                onClick = ::save,
                enabled = ownerKnown && host.isNotBlank() && username.isNotBlank() && password.isNotBlank(),
                modifier = Modifier.weight(1f),
                focusRequester = saveFocus,
            )
            TvDebridAction(
                label = "Clear",
                accessibilityLabel = "Usenet provider: Clear credentials",
                onClick = {
                    if (ownerKnown && store.clear()) {
                        host = ""; username = ""; password = ""
                        status = "Not configured"
                        request(hostFocus)
                    } else {
                        status = "Unable to clear secure Usenet provider"
                        request(clearFocus)
                    }
                },
                enabled = ownerKnown && store.isConfigured(),
                modifier = Modifier.weight(1f),
                focusRequester = clearFocus,
                danger = true,
            )
        }
    }
}

@Composable
private fun TvUsenetField(
    label: String,
    value: String,
    onValueChange: (String) -> Unit,
    focusRequester: FocusRequester?,
    keyboardType: KeyboardType,
    password: Boolean = false,
) {
    val colors = VortXTheme.colors
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        modifier = Modifier.fillMaxWidth().then(if (focusRequester != null) Modifier.focusRequester(focusRequester) else Modifier)
            .semantics { contentDescription = "Usenet provider: $label" },
        label = { Text(label) },
        singleLine = true,
        visualTransformation = if (password) PasswordVisualTransformation() else androidx.compose.ui.text.input.VisualTransformation.None,
        keyboardOptions = KeyboardOptions(keyboardType = keyboardType, imeAction = ImeAction.Next),
        colors = OutlinedTextFieldDefaults.colors(
            focusedBorderColor = colors.accent,
            unfocusedBorderColor = colors.hairline,
            cursorColor = colors.accent,
        ),
    )
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

internal fun tvDebridControlAccessibilityLabel(service: DebridService, control: String): String =
    "${service.displayName}: $control"

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
        TvDebridStatus.SET -> colors.accentBright
        TvDebridStatus.STORAGE_UNAVAILABLE -> colors.textPrimary
        TvDebridStatus.NOT_SET, TvDebridStatus.CLEARED -> colors.textTertiary
    }
    val statusText = stringResource(editor.status.textResource)
    val statusAccessibilityText = tvDebridControlAccessibilityLabel(service, statusText)
    val keyFieldLabel = stringResource(
        if (editor.hasValue) {
            R.string.tv_debrid_replacement_api_key
        } else {
            R.string.tv_debrid_api_key
        },
    )
    val saveActionLabel = stringResource(
        if (editor.hasValue) {
            R.string.tv_debrid_action_replace
        } else {
            R.string.tv_debrid_action_save
        },
    )
    val clearActionLabel = stringResource(R.string.tv_debrid_action_clear)

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(colors.surface1, RoundedCornerShape(18.dp))
            .semantics { isTraversalGroup = true }
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
                    stateDescription = statusAccessibilityText
                    if (editor.status.isAccessibilityError) {
                        error(statusAccessibilityText)
                    }
                },
            )
        }
        OutlinedTextField(
            value = editor.pendingKey,
            onValueChange = { editor = editor.copy(pendingKey = it) },
            modifier = Modifier
                .fillMaxWidth()
                .semantics {
                    contentDescription = tvDebridControlAccessibilityLabel(service, keyFieldLabel)
                }
                .focusRequester(keyFieldFocus),
            label = { Text(keyFieldLabel) },
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
                label = saveActionLabel,
                accessibilityLabel = tvDebridControlAccessibilityLabel(
                    service,
                    "$saveActionLabel API key",
                ),
                onClick = { save(TvDebridMutationTrigger.DPAD) },
                enabled = editor.pendingKey.isNotBlank(),
                modifier = Modifier.weight(1f),
                focusRequester = saveFocus,
            )
            TvDebridAction(
                label = clearActionLabel,
                accessibilityLabel = tvDebridControlAccessibilityLabel(
                    service,
                    "$clearActionLabel API key",
                ),
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
    accessibilityLabel: String = label,
    icon: ImageVector? = null,
) {
    val colors = VortXTheme.colors
    val baseColor = when {
        !enabled -> colors.surface2
        danger -> colors.danger.copy(alpha = 0.16f)
        else -> colors.surface2
    }
    val contentColor = when {
        !enabled -> colors.textTertiary
        danger -> colors.textPrimary
        else -> colors.textPrimary
    }
    Surface(
        onClick = onClick,
        enabled = enabled,
        modifier = modifier
            .semantics { contentDescription = accessibilityLabel }
            .then(
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
            focusedContainerColor = colors.surface3,
            focusedContentColor = colors.textPrimary,
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
            if (icon != null) {
                Icon(icon, contentDescription = null, tint = LocalContentColor.current)
            }
            if (icon != null) Spacer(Modifier.width(VortXTheme.spacing.xs))
            Text(
                label,
                style = VortXTheme.type.body.copy(fontWeight = FontWeight.SemiBold),
                color = LocalContentColor.current,
            )
        }
    }
}
