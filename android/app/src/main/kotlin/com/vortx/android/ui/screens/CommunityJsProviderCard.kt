package com.vortx.android.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
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
import com.vortx.android.communityjs.CommunityJsProviderStore
import com.vortx.android.ui.components.Chip
import com.vortx.android.ui.components.SurfaceCard
import com.vortx.android.ui.theme.VortXTheme
import kotlinx.coroutines.launch

/** Phone management surface for user-installed community JavaScript providers. */
@Composable
internal fun CommunityJsProviderCard(modifier: Modifier = Modifier) {
    val context = LocalContext.current.applicationContext
    val store = remember(context) { CommunityJsProviderStore(context) }
    val scope = rememberCoroutineScope()
    var manifest by remember { mutableStateOf(store.manifestUrl) }
    var message by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    var revision by remember { mutableIntStateOf(0) }
    val providers = remember(revision) { store.installedProviders() }
    val colors = VortXTheme.colors

    SurfaceCard(modifier = modifier.fillMaxWidth()) {
        Column(
            modifier = Modifier.padding(VortXTheme.spacing.md),
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
        ) {
            Text("Community JavaScript providers", style = VortXTheme.type.cardTitle)
            Text(
                "Install only a manifest you trust. Providers run with bounded network access and stay off until enabled.",
                style = VortXTheme.type.body.copy(color = colors.textSecondary),
            )
            OutlinedTextField(
                value = manifest,
                onValueChange = { manifest = it },
                label = { Text("HTTPS manifest URL") },
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
                    label = if (busy) "Working…" else if (providers.isEmpty()) "Install" else "Refresh",
                    selected = true,
                    enabled = !busy && manifest.isNotBlank(),
                    onClick = {
                        busy = true
                        scope.launch {
                            val result = store.install(manifest)
                            message = result.message
                            manifest = store.manifestUrl
                            revision += 1
                            busy = false
                        }
                    },
                )
                Chip(
                    label = if (store.userEnabled) "Turn off" else "Turn on",
                    selected = store.userEnabled,
                    enabled = !busy,
                    onClick = {
                        store.userEnabled = !store.userEnabled
                        revision += 1
                    },
                )
            }
            if (!store.featureEnabled) {
                Text("Unavailable until enabled by the app configuration.", style = VortXTheme.type.label.copy(color = colors.textTertiary))
            }
            message?.let { Text(it, style = VortXTheme.type.label.copy(color = colors.textSecondary)) }
            providers.forEach { provider ->
                Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
                    Text(provider.name, style = VortXTheme.type.body, modifier = Modifier.weight(1f))
                    Chip(
                        label = if (provider.enabled) "On" else "Off",
                        selected = provider.enabled,
                        onClick = {
                            store.setProviderEnabled(provider.id, !provider.enabled)
                            revision += 1
                        },
                    )
                }
            }
        }
    }
}
