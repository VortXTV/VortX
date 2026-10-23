package com.vortx.android.ui.screens

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.Movie
import androidx.compose.material.icons.filled.Storage
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
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
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.vortx.android.model.Playable
import com.vortx.android.network.NetworkShare
import com.vortx.android.network.NetworkShareStore
import com.vortx.android.ui.components.Chip
import com.vortx.android.ui.network.addReportingError
import com.vortx.android.ui.network.rememberNetworkShareBrowser
import com.vortx.android.ui.network.sizeLabel
import com.vortx.android.ui.theme.VortXGlass
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXShapes
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.theme.vortxGlass
import kotlinx.coroutines.launch

/**
 * Library > Network shares on phone and tablet (Apple `iOSNetworkSharesView`): the shares saved on this device,
 * adding one, and a folder browser that plays a video straight from the share (SMB, WebDAV or a web folder).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun NetworkSharesScreen(onBack: () -> Unit, onPlay: (Playable) -> Unit, modifier: Modifier = Modifier) {
    val browser = rememberNetworkShareBrowser()
    val shares by browser.store.shares.collectAsStateWithLifecycle()
    var adding by remember { mutableStateOf(false) }
    var removing by remember { mutableStateOf<NetworkShare?>(null) }
    val leave = { if (!browser.back()) onBack() }
    BackHandler { leave() }
    val level = browser.current
    Column(modifier = modifier.fillMaxSize()) {
        TopAppBar(
            title = { Text(level?.title ?: "Network shares", style = VortXTheme.type.screenTitle) },
            navigationIcon = { IconButton(onClick = leave) { Icon(VortXIcons.back, "Back") } },
        )
        LazyColumn(
            contentPadding = PaddingValues(horizontal = VortXTheme.spacing.edge, vertical = VortXTheme.spacing.sm),
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
        ) {
            if (level == null) {
                item {
                    Column(verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
                        Text("Play videos straight from a NAS or computer on your network: an SMB share (smb://nas/Movies), a WebDAV address, or a web server's folder listing.",
                            style = VortXTheme.type.body.copy(color = VortXTheme.colors.textSecondary))
                        Chip(label = "Add a share", selected = false, onClick = { adding = true }, leadingIcon = Icons.Filled.Add)
                        if (shares.isEmpty()) Note("No shares yet. On a Synology, QNAP or TrueNAS, turn on its WebDAV service and add that address here.")
                    }
                }
                items(shares, key = { it.id }) { share ->
                    ShareRow(Icons.Filled.Storage, share.name, "${share.kind.label} · ${share.url}", onClick = { browser.open(share) },
                        trailing = { IconButton(onClick = { removing = share }) { Icon(Icons.Filled.Delete, "Remove ${share.name}") } })
                }
            } else {
                browser.playError?.let { message ->
                    item { Text(message, style = VortXTheme.type.label.copy(color = VortXTheme.colors.danger)) }
                }
                val entries = browser.entries
                val error = browser.error
                when {
                    error != null -> item {
                        Column(verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
                            Note(error)
                            Chip(label = "Try again", selected = false, onClick = { browser.reload() })
                        }
                    }
                    entries == null -> item { CircularProgressIndicator(color = VortXTheme.colors.accent) }
                    entries.isEmpty() -> item { Note("No folders or videos here.") }
                    else -> items(entries, key = { it.url }) { entry ->
                        if (entry.isFolder) ShareRow(Icons.Filled.Folder, entry.name, null, onClick = { browser.enter(entry) })
                        else ShareRow(Icons.Filled.Movie, entry.name, entry.sizeLabel(), onClick = { browser.play(entry, onPlay) })
                    }
                }
            }
        }
    }
    if (adding) AddShareDialog(browser.store, onDone = { adding = false })
    removing?.let { share ->
        AlertDialog(
            onDismissRequest = { removing = null },
            title = { Text("Remove this share?") },
            text = { Text("Its address and saved password are deleted from this device. Nothing on the share changes.") },
            confirmButton = { TextButton(onClick = { browser.store.remove(share); removing = null }) { Text("Remove") } },
            dismissButton = { TextButton(onClick = { removing = null }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun AddShareDialog(store: NetworkShareStore, onDone: () -> Unit) {
    val scope = rememberCoroutineScope()
    var address by remember { mutableStateOf("") }
    var name by remember { mutableStateOf("") }
    var username by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    AlertDialog(
        onDismissRequest = { if (!busy) onDone() },
        title = { Text("Add a share") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs)) {
                OutlinedTextField(address, { address = it }, label = { Text("Address") }, singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri), modifier = Modifier.fillMaxWidth())
                OutlinedTextField(name, { name = it }, label = { Text("Name (optional)") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                OutlinedTextField(username, { username = it }, label = { Text("Username") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                OutlinedTextField(password, { password = it }, label = { Text("Password") }, singleLine = true,
                    visualTransformation = PasswordVisualTransformation(),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password), modifier = Modifier.fillMaxWidth())
                Text("For example smb://192.168.1.20/Movies for a shared folder, or 192.168.1.20:5005/video for a Synology WebDAV share. Leave the username empty if the share has no login.",
                    style = VortXTheme.type.label.copy(color = VortXTheme.colors.textSecondary))
                error?.let { Text(it, style = VortXTheme.type.label.copy(color = VortXTheme.colors.danger)) }
            }
        },
        confirmButton = {
            TextButton(enabled = !busy && address.isNotBlank(), onClick = {
                busy = true
                error = null
                scope.launch {
                    error = store.addReportingError(name, address, username, password)
                    busy = false
                    if (error == null) onDone()
                }
            }) { Text(if (busy) "Checking…" else "Add") }
        },
        dismissButton = { TextButton(enabled = !busy, onClick = onDone) { Text("Cancel") } },
    )
}

@Composable
private fun ShareRow(icon: ImageVector, title: String, detail: String?, onClick: () -> Unit, trailing: @Composable () -> Unit = {}) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .vortxGlass(shape = VortXShapes.card, fillAlpha = VortXGlass.cardFillAlpha, shadow = VortXGlass.Shadow.flat)
            .padding(VortXTheme.spacing.md),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
    ) {
        Icon(icon, contentDescription = null, tint = VortXTheme.colors.accent, modifier = Modifier.size(VortXTheme.spacing.lg))
        Column(modifier = Modifier.weight(1f)) {
            Text(title, style = VortXTheme.type.cardTitle, maxLines = 2)
            detail?.let { Text(it, style = VortXTheme.type.label.copy(color = VortXTheme.colors.textSecondary), maxLines = 1) }
        }
        trailing()
    }
}

@Composable
private fun Note(text: String) {
    Text(text, style = VortXTheme.type.label.copy(color = VortXTheme.colors.textTertiary))
}
