package com.vortx.android.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.PasswordVisualTransformation
import com.vortx.android.nzb.NzbIndexerConfig
import com.vortx.android.nzb.NzbIndexerEndpointPolicy
import com.vortx.android.nzb.NzbIndexerStore
import com.vortx.android.ui.components.PrimaryButton
import com.vortx.android.ui.components.SurfaceCard
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXTheme
import kotlinx.coroutines.launch

/**
 * Reusable phone/TV-ready Newznab editor. Hosts own navigation and construct the owner-scoped [store].
 * Stored API keys never populate Compose state; a blank key in Edit deliberately retains the saved value.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun NzbIndexerSettingsScreen(
    store: NzbIndexerStore,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
    /** Optional because a host may deliberately offer no network test. It receives only explicit typed key text. */
    testIndexer: (suspend (NzbIndexerConfig, String) -> Boolean)? = null,
) {
    var revision by remember { mutableStateOf(0) }
    var editing by remember { mutableStateOf<NzbIndexerConfig?>(null) }
    var deleting by remember { mutableStateOf<NzbIndexerConfig?>(null) }
    var message by remember { mutableStateOf<String?>(null) }
    val snapshot = remember(revision) { store.read() }
    val document = (snapshot as? NzbIndexerStore.Read.Ready)?.document

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("NZB indexers", style = VortXTheme.type.cardTitle) },
                navigationIcon = { IconButton(onClick = onBack) { Icon(VortXIcons.back, contentDescription = "Back") } },
            )
        },
    ) { padding ->
        Column(
            modifier = modifier.fillMaxSize().padding(padding).padding(VortXTheme.spacing.edge).verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
        ) {
            Text("Connect your own Newznab-compatible indexer. Its API key is encrypted on this device and is never shown here.")
            when (snapshot) {
                NzbIndexerStore.Read.Corrupt -> Text("Saved indexer settings could not be read. They have not been changed.", color = VortXTheme.colors.danger)
                NzbIndexerStore.Read.Unavailable -> Text("Secure storage is unavailable. Existing indexers have not been changed.", color = VortXTheme.colors.danger)
                NzbIndexerStore.Read.Stale -> Text("Your account or profile changed. Reopen this page.", color = VortXTheme.colors.danger)
                else -> Unit
            }
            message?.let { Text(it, color = VortXTheme.colors.danger) }
            document?.indexers?.forEach { config ->
                SurfaceCard(modifier = Modifier.fillMaxWidth()) {
                    Column(Modifier.padding(VortXTheme.spacing.md), verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
                        Text(config.name, style = VortXTheme.type.cardTitle)
                        Text(NzbIndexerEndpointPolicy.hostOnly(config.endpoint) ?: "Invalid endpoint")
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Checkbox(checked = config.enabled, onCheckedChange = { enabled ->
                                if (!store.save(config.copy(enabled = enabled), "")) message = "Could not update this indexer."
                                revision++
                            })
                            Text(if (config.enabled) "Enabled" else "Disabled")
                            TextButton(onClick = { editing = config; message = null }) { Text("Edit") }
                            TextButton(onClick = { deleting = config }) { Text("Delete") }
                        }
                    }
                }
            }
            PrimaryButton(text = "Add indexer", onClick = { editing = NzbIndexerConfig(name = "", endpoint = "") }, modifier = Modifier.fillMaxWidth())
        }
    }
    editing?.let { initial ->
        NzbIndexerEditor(
            initial = initial,
            isNew = document?.indexers?.none { it.id == initial.id } != false,
            testIndexer = testIndexer,
            onDismiss = { editing = null },
            onSave = { config, key ->
                if (store.save(config, key)) { editing = null; message = null; revision++ } else message = "Could not save. Check the endpoint, API key and secure storage."
            },
        )
    }
    deleting?.let { config ->
        AlertDialog(
            onDismissRequest = { deleting = null },
            title = { Text("Delete ${config.name}?") },
            text = { Text("This removes the encrypted API key for this indexer from the current account and profile.") },
            confirmButton = { TextButton(onClick = { if (!store.remove(config.id)) message = "Could not delete this indexer."; deleting = null; revision++ }) { Text("Delete") } },
            dismissButton = { TextButton(onClick = { deleting = null }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun NzbIndexerEditor(
    initial: NzbIndexerConfig,
    isNew: Boolean,
    testIndexer: (suspend (NzbIndexerConfig, String) -> Boolean)?,
    onDismiss: () -> Unit,
    onSave: (NzbIndexerConfig, String) -> Unit,
) {
    val scope = rememberCoroutineScope()
    var name by remember(initial.id) { mutableStateOf(initial.name) }
    var endpoint by remember(initial.id) { mutableStateOf(initial.endpoint) }
    var key by remember(initial.id) { mutableStateOf("") }
    var enabled by remember(initial.id) { mutableStateOf(initial.enabled) }
    var status by remember { mutableStateOf<String?>(null) }
    val draft = NzbIndexerConfig(id = initial.id, name = name, endpoint = endpoint, enabled = enabled)
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(if (isNew) "Add Newznab indexer" else "Edit Newznab indexer") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
                OutlinedTextField(name, { name = it }, label = { Text("Name") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                OutlinedTextField(endpoint, { endpoint = it }, label = { Text("HTTPS API endpoint") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                OutlinedTextField(
                    key, { key = it }, label = { Text(if (isNew) "API key" else "New API key (leave blank to keep current)") },
                    singleLine = true, modifier = Modifier.fillMaxWidth(), visualTransformation = PasswordVisualTransformation(),
                )
                Row(verticalAlignment = Alignment.CenterVertically) { Checkbox(enabled, { enabled = it }); Text("Enabled") }
                status?.let { Text(it, color = VortXTheme.colors.danger) }
            }
        },
        confirmButton = {
            Row {
                testIndexer?.let { test -> TextButton(onClick = { scope.launch { status = if (test(draft, key)) "Connection succeeded" else "Connection failed" } }) { Text("Test") } }
                TextButton(onClick = { onSave(draft, key) }) { Text("Save") }
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}
