package com.vortx.android.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.error
import androidx.compose.ui.semantics.isTraversalGroup
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import com.vortx.android.debrid.DebridKeys
import com.vortx.android.debrid.DebridKeyStatus
import com.vortx.android.debrid.DebridService
import com.vortx.android.usenet.UsenetProviderCredentials
import com.vortx.android.usenet.UsenetProviderStore
import com.vortx.android.ui.components.PrimaryButton
import com.vortx.android.ui.components.SurfaceCard
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXTheme

internal const val DEBRID_STORAGE_UNAVAILABLE_STATUS = "Secure storage unavailable"

internal data class DebridEditorStateKey(
    val service: DebridService,
    val accountIdentity: String,
)

internal fun debridEditorStateKey(
    service: DebridService,
    accountIdentity: String,
): DebridEditorStateKey = DebridEditorStateKey(service, accountIdentity)

internal data class DebridKeyEditorState(
    val pendingKey: String,
    val hasValue: Boolean,
    val durablyConfigured: Boolean,
    val storageUnavailable: Boolean,
) {
    val statusText: String
        get() = when {
            storageUnavailable -> DEBRID_STORAGE_UNAVAILABLE_STATUS
            durablyConfigured -> "Set"
            else -> "Not set"
        }

    fun afterSave(attemptedKey: String, status: DebridKeyStatus): DebridKeyEditorState =
        from(status).copy(
            // A rejected secure write keeps the attempted replacement available for an explicit retry.
            // A successful reread clears it. The stored credential itself never enters this field.
            pendingKey = attemptedKey.takeIf { status.storageUnavailable }.orEmpty(),
        )

    fun afterClear(status: DebridKeyStatus): DebridKeyEditorState =
        from(status).copy(
            pendingKey = pendingKey.takeIf { status.storageUnavailable }.orEmpty(),
        )

    companion object {
        fun from(status: DebridKeyStatus): DebridKeyEditorState =
            DebridKeyEditorState(
                // Stored credentials are represented only by status. They never become field text.
                pendingKey = "",
                hasValue = status.hasValue,
                durablyConfigured = status.durablyConfigured,
                storageUnavailable = status.storageUnavailable,
            )
    }
}

internal fun debridKeyVisualTransformation(): VisualTransformation = PasswordVisualTransformation()

internal val debridKeyKeyboardOptions = KeyboardOptions(
    keyboardType = KeyboardType.Password,
    imeAction = ImeAction.Done,
)

internal fun debridMutationStatus(saved: Boolean, reread: DebridKeyStatus): DebridKeyStatus =
    if (saved || reread.storageUnavailable) {
        reread
    } else {
        reread.copy(
            durablyConfigured = false,
            storageUnavailable = true,
        )
    }

internal fun debridControlAccessibilityLabel(service: DebridService, control: String): String =
    "${service.displayName}: $control"

internal fun DebridKeyEditorState.shouldClearMutationFocus(): Boolean = !storageUnavailable

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DebridKeysScreen(
    keys: DebridKeys,
    accountIdentity: String,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current.applicationContext
    val usenetStore = remember(keys) { UsenetProviderStore(context, keys::ownerToken, keys::mutateCurrentOwner) }
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Debrid services", style = VortXTheme.type.cardTitle) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(VortXIcons.back, contentDescription = "Back")
                    }
                },
            )
        },
    ) { padding ->
        Column(
            modifier = modifier
                .fillMaxSize()
                .padding(padding)
                .padding(VortXTheme.spacing.edge)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
        ) {
            Text(
                "Add a provider API key to play cached torrents through your own debrid account.",
                style = VortXTheme.type.body.copy(color = VortXTheme.colors.textSecondary),
            )
            DebridService.entries.forEach { service ->
                val editorStateKey = debridEditorStateKey(service, accountIdentity)
                val initialState = remember(keys, editorStateKey) {
                    DebridKeyEditorState.from(keys.status(service))
                }
                DebridKeySection(
                    service = service,
                    editorStateKey = editorStateKey,
                    initialState = initialState,
                    onSave = { value ->
                        val saved = keys.setKey(service, value)
                        debridMutationStatus(saved, keys.status(service))
                    },
                    onClear = {
                        val cleared = keys.setKey(service, "")
                        debridMutationStatus(cleared, keys.status(service))
                    },
                )
            }
            UsenetProviderSection(
                store = usenetStore,
                ownerKnown = keys.ownerToken() != null,
                accountIdentity = accountIdentity,
            )
        }
    }
}

@Composable
private fun UsenetProviderSection(
    store: UsenetProviderStore,
    ownerKnown: Boolean,
    accountIdentity: String,
) {
    // A settings host can switch profiles in place. Every transient credential field is keyed by the exact
    // account identity, so even unsaved text from A is discarded before B's editor becomes visible.
    var host by remember(accountIdentity) { mutableStateOf("") }; var port by remember(accountIdentity) { mutableStateOf("563") }
    var username by remember(accountIdentity) { mutableStateOf("") }; var password by remember(accountIdentity) { mutableStateOf("") }
    var connections by remember(accountIdentity) { mutableStateOf("4") }; var status by remember(ownerKnown, accountIdentity) {
        mutableStateOf(if (ownerKnown && store.isConfigured()) "Configured (credentials redacted)" else "Not configured")
    }
    fun save() {
        val credentials = UsenetProviderCredentials(host, port.toIntOrNull() ?: 0, username, password, connections.toIntOrNull() ?: 0, true)
        status = if (ownerKnown && credentials.isValid && store.save(credentials)) "Configured (credentials redacted)" else "Unable to save secure Usenet provider"
        if (status.startsWith("Configured")) { password = ""; username = "" }
    }
    SurfaceCard {
        Column(Modifier.padding(VortXTheme.spacing.md), verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
            Text("Usenet provider", style = VortXTheme.type.cardTitle)
            Text(status, style = VortXTheme.type.label.copy(color = VortXTheme.colors.textSecondary))
            listOf("Host" to host, "Port" to port, "Username" to username, "Password" to password, "Connections" to connections).forEach { (label, value) ->
                OutlinedTextField(value, { next -> when (label) { "Host" -> host=next; "Port" -> port=next; "Username" -> username=next; "Password" -> password=next; else -> connections=next } }, Modifier.fillMaxWidth(), label={Text(label)}, singleLine=true, visualTransformation=if(label=="Password") PasswordVisualTransformation() else VisualTransformation.None)
            }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
                PrimaryButton("Save provider", { save() }, Modifier.weight(1f), enabled = ownerKnown)
                TextButton(onClick = { if (ownerKnown && store.clear()) status="Not configured" }, enabled=ownerKnown) { Text("Clear", color=VortXTheme.colors.danger) }
            }
        }
    }
}

@Composable
private fun DebridKeySection(
    service: DebridService,
    editorStateKey: DebridEditorStateKey,
    initialState: DebridKeyEditorState,
    onSave: (String) -> DebridKeyStatus,
    onClear: () -> DebridKeyStatus,
) {
    val colors = VortXTheme.colors
    val focusManager = LocalFocusManager.current
    var editor by remember(editorStateKey) { mutableStateOf(initialState) }

    fun save() {
        if (editor.pendingKey.isBlank()) return
        val attemptedKey = editor.pendingKey
        val updated = editor.afterSave(attemptedKey, onSave(attemptedKey))
        editor = updated
        if (updated.shouldClearMutationFocus()) focusManager.clearFocus()
    }

    val statusColor = when {
        editor.storageUnavailable -> colors.textPrimary
        editor.durablyConfigured -> colors.accentBright
        else -> colors.textTertiary
    }
    val statusAccessibilityText = debridControlAccessibilityLabel(service, editor.statusText)
    val fieldLabel = if (editor.hasValue) "Replacement API key" else "API key"
    val saveLabel = if (editor.hasValue) "Replace" else "Save"

    SurfaceCard {
        Column(
            modifier = Modifier
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
                    editor.statusText,
                    style = VortXTheme.type.label.copy(color = statusColor),
                    modifier = Modifier.semantics {
                        liveRegion = LiveRegionMode.Polite
                        stateDescription = statusAccessibilityText
                        if (editor.storageUnavailable) {
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
                        contentDescription = debridControlAccessibilityLabel(service, fieldLabel)
                        if (editor.storageUnavailable) {
                            error(statusAccessibilityText)
                        }
                    },
                label = { Text(fieldLabel) },
                supportingText = if (editor.storageUnavailable) {
                    { Text(statusAccessibilityText, color = colors.textPrimary) }
                } else {
                    null
                },
                isError = editor.storageUnavailable,
                singleLine = true,
                visualTransformation = debridKeyVisualTransformation(),
                keyboardOptions = debridKeyKeyboardOptions,
                keyboardActions = KeyboardActions(onDone = { save() }),
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = colors.accent,
                    cursorColor = colors.accent,
                ),
            )
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                PrimaryButton(
                    text = saveLabel,
                    onClick = { save() },
                    modifier = Modifier
                        .weight(1f)
                        .semantics {
                            contentDescription = debridControlAccessibilityLabel(
                                service,
                                "$saveLabel API key",
                            )
                        },
                    enabled = editor.pendingKey.isNotBlank(),
                )
                TextButton(
                    enabled = editor.hasValue || editor.storageUnavailable,
                    modifier = Modifier.semantics {
                        contentDescription = debridControlAccessibilityLabel(service, "Clear API key")
                    },
                    onClick = {
                        val updated = editor.afterClear(onClear())
                        editor = updated
                        if (updated.shouldClearMutationFocus()) focusManager.clearFocus()
                    },
                ) {
                    Text(
                        "Clear",
                        color = if (editor.hasValue || editor.storageUnavailable) {
                            colors.danger
                        } else {
                            colors.textTertiary
                        },
                    )
                }
            }
        }
    }
}
