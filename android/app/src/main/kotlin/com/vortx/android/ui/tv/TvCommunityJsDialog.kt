package com.vortx.android.ui.tv

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import com.vortx.android.communityjs.CommunityJsProviderStore
import com.vortx.android.ui.theme.VortXTheme
import kotlinx.coroutines.launch

/** TV-friendly paste, refresh, and enable surface for community JavaScript providers. */
@Composable
internal fun TvCommunityJsDialog(onDismiss: () -> Unit) {
    val context = LocalContext.current.applicationContext
    val store = remember(context) { CommunityJsProviderStore(context) }
    val scope = rememberCoroutineScope()
    var manifest by remember { mutableStateOf(store.manifestUrl) }
    var message by remember { mutableStateOf<String?>(null) }
    var revision by remember { mutableIntStateOf(0) }
    val providers = remember(revision) { store.installedProviders() }

    Dialog(onDismissRequest = onDismiss) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
        ) {
            Text("Community JavaScript providers", style = VortXTheme.type.screenTitle)
            Text("Paste a trusted HTTPS manifest URL. Providers remain disabled until you turn them on.", style = VortXTheme.type.body)
            OutlinedTextField(
                value = manifest,
                onValueChange = { manifest = it },
                label = { Text("HTTPS manifest URL") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            TvAddonActionButton(label = if (providers.isEmpty()) "Install" else "Refresh", onClick = {
                scope.launch {
                    val result = store.install(manifest)
                    message = result.message
                    manifest = store.manifestUrl
                    revision += 1
                }
            })
            TvAddonActionButton(label = if (store.userEnabled) "Turn off" else "Turn on", onClick = {
                store.userEnabled = !store.userEnabled
                revision += 1
            })
            if (!store.featureEnabled) Text("Unavailable until enabled by the app configuration.", style = VortXTheme.type.label)
            message?.let { Text(it, style = VortXTheme.type.label) }
            providers.forEach { provider ->
                TvAddonActionButton(label = "${provider.name}: ${if (provider.enabled) "On" else "Off"}", onClick = {
                    store.setProviderEnabled(provider.id, !provider.enabled)
                    revision += 1
                })
            }
            TvAddonActionButton(label = "Back", onClick = onDismiss)
        }
    }
}
