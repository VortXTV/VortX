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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import com.vortx.android.metadata.MetadataProviderKeys
import com.vortx.android.ui.components.PrimaryButton
import com.vortx.android.ui.components.SurfaceCard
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXTheme

/// Settings > Metadata keys (SET-2, Apple `MetadataKeysView` / `ApiKeys.swift`). Three encrypted credential
/// fields (TMDB / MDBList / fanart.tv) persisted under Apple's EXACT keys via [MetadataProviderKeys], so a
/// value syncs to the platforms that call these providers directly.
///
/// HONEST ANDROID STATUS: metadata on Android is fetched through VortX's own keyless edge proxy, so a value
/// entered here is stored + synced but is not used to re-route this device's requests today (see the class
/// doc on [MetadataProviderKeys]). The intro copy says so rather than implying local use.
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MetadataKeysScreen(onBack: () -> Unit, modifier: Modifier = Modifier) {
    val context = LocalContext.current.applicationContext
    val keys = remember { MetadataProviderKeys(context) }
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Metadata keys", style = VortXTheme.type.cardTitle) },
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
                "Add your own metadata provider keys. VortX works fully without them. On this device metadata " +
                    "is fetched through VortX's own service, so a key here is saved securely and synced to your " +
                    "other devices, where it is used by platforms that call these providers directly.",
                style = VortXTheme.type.body.copy(color = VortXTheme.colors.textSecondary),
            )
            MetadataProviderKeys.Slot.entries.forEach { slot ->
                MetadataKeySection(slot = slot, keys = keys)
            }
        }
    }
}

@Composable
private fun MetadataKeySection(slot: MetadataProviderKeys.Slot, keys: MetadataProviderKeys) {
    val colors = VortXTheme.colors
    val focusManager = LocalFocusManager.current
    var hasValue by remember(slot) { mutableStateOf(keys.hasValue(slot)) }
    var pending by remember(slot) { mutableStateOf("") }
    var storageUnavailable by remember(slot) { mutableStateOf(false) }

    val statusText = when {
        storageUnavailable -> "Secure storage unavailable"
        hasValue -> "Set"
        else -> "Not set"
    }
    val statusColor = when {
        storageUnavailable -> colors.textPrimary
        hasValue -> colors.accentBright
        else -> colors.textTertiary
    }
    val fieldLabel = if (hasValue) "Replacement key" else "Key"
    val saveLabel = if (hasValue) "Replace" else "Save"

    fun save() {
        if (pending.isBlank()) return
        val durable = keys.set(slot, pending)
        storageUnavailable = !durable
        if (durable) {
            hasValue = keys.hasValue(slot)
            pending = ""
            focusManager.clearFocus()
        }
    }

    SurfaceCard {
        Column(
            modifier = Modifier.padding(VortXTheme.spacing.md),
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(slot.displayName, style = VortXTheme.type.cardTitle)
                Text(statusText, style = VortXTheme.type.label.copy(color = statusColor))
            }
            Text(slot.hint, style = VortXTheme.type.label.copy(color = colors.textTertiary))
            OutlinedTextField(
                value = pending,
                onValueChange = { pending = it },
                modifier = Modifier.fillMaxWidth(),
                label = { Text(fieldLabel) },
                singleLine = true,
                visualTransformation = PasswordVisualTransformation(),
                keyboardOptions = KeyboardOptions(
                    keyboardType = KeyboardType.Password,
                    imeAction = ImeAction.Done,
                ),
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
                    modifier = Modifier.weight(1f),
                    enabled = pending.isNotBlank(),
                )
                TextButton(
                    enabled = hasValue,
                    onClick = {
                        val durable = keys.set(slot, "")
                        storageUnavailable = !durable
                        if (durable) hasValue = keys.hasValue(slot)
                        focusManager.clearFocus()
                    },
                ) {
                    Text("Clear", color = if (hasValue) colors.danger else colors.textTertiary)
                }
            }
        }
    }
}
