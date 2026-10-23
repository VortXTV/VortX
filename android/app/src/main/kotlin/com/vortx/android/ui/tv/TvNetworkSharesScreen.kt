package com.vortx.android.ui.tv

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.Movie
import androidx.compose.material.icons.filled.Storage
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.tv.material3.Border
import androidx.tv.material3.ClickableSurfaceDefaults
import androidx.tv.material3.ExperimentalTvMaterial3Api
import androidx.tv.material3.Icon
import androidx.tv.material3.Surface
import androidx.tv.material3.Text
import com.vortx.android.model.Playable
import com.vortx.android.network.NetworkShare
import com.vortx.android.network.NetworkShareStore
import com.vortx.android.ui.network.addReportingError
import com.vortx.android.ui.network.rememberNetworkShareBrowser
import com.vortx.android.ui.network.sizeLabel
import com.vortx.android.ui.theme.VortXShapes
import com.vortx.android.ui.theme.VortXTheme
import kotlinx.coroutines.launch

/**
 * Library > Network shares on TV (Apple `TVNetworkSharesView`): the shares saved on this device, adding one,
 * and a folder browser that plays a video straight from the share. Long-press a share to remove it.
 */
@Composable
internal fun TvNetworkSharesScreen(onBack: () -> Unit, onPlay: (Playable) -> Unit) {
    val browser = rememberNetworkShareBrowser()
    val shares by browser.store.shares.collectAsStateWithLifecycle()
    var adding by remember { mutableStateOf(false) }
    var removing by remember { mutableStateOf<NetworkShare?>(null) }
    val leave = { if (!browser.back()) onBack() }
    if (adding) {
        BackHandler { adding = false }
        TvAddShareForm(browser.store, onDone = { adding = false })
        return
    }
    removing?.let { share ->
        BackHandler { removing = null }
        Column(
            modifier = Modifier.fillMaxSize().background(VortXTheme.colors.canvas).padding(TvDimens.edge),
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
        ) {
            Text("Remove ${share.name}?", style = VortXTheme.type.sectionTitle)
            Text("Its address and saved password are deleted from this device. Nothing on the share changes.",
                style = VortXTheme.type.body.copy(color = VortXTheme.colors.textSecondary))
            Row(horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
                TvFilterChip(label = "Remove", selected = false, onClick = { browser.store.remove(share); removing = null })
                TvFilterChip(label = "Cancel", selected = false, onClick = { removing = null })
            }
        }
        return
    }
    BackHandler { leave() }
    val level = browser.current
    Column(modifier = Modifier.fillMaxSize().background(VortXTheme.colors.canvas)) {
        TvLibraryRouteHeader(level?.title ?: "Network shares", onBack = leave)
        LazyColumn(
            contentPadding = PaddingValues(start = TvDimens.edge, end = TvDimens.edge, bottom = TvDimens.edge),
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
        ) {
            if (level == null) {
                item {
                    Column(verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
                        Text("Play videos straight from a NAS or computer on your network: an SMB share (smb://nas/Movies), a WebDAV address, or a web server's folder listing.",
                            style = VortXTheme.type.body.copy(color = VortXTheme.colors.textSecondary))
                        TvFilterChip(label = "Add a share", selected = false, onClick = { adding = true }, leadingIcon = Icons.Filled.Add)
                        if (shares.isEmpty()) TvShareNote("No shares yet. On a Synology, QNAP or TrueNAS, turn on its WebDAV service and add that address here.")
                    }
                }
                items(shares, key = { it.id }) { share ->
                    TvShareRow(Icons.Filled.Storage, share.name, "${share.kind.label} · ${share.url} · hold to remove",
                        onClick = { browser.open(share) }, onLongClick = { removing = share })
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
                            TvShareNote(error)
                            TvFilterChip(label = "Try again", selected = false, onClick = { browser.reload() })
                        }
                    }
                    entries == null -> item { TvShareNote("Loading…") }
                    entries.isEmpty() -> item { TvShareNote("No folders or videos here.") }
                    else -> items(entries, key = { it.url }) { entry ->
                        if (entry.isFolder) TvShareRow(Icons.Filled.Folder, entry.name, null, onClick = { browser.enter(entry) })
                        else TvShareRow(Icons.Filled.Movie, entry.name, entry.sizeLabel(), onClick = { browser.play(entry, onPlay) })
                    }
                }
            }
        }
    }
}

@Composable
private fun TvAddShareForm(store: NetworkShareStore, onDone: () -> Unit) {
    val scope = rememberCoroutineScope()
    var address by remember { mutableStateOf("") }
    var name by remember { mutableStateOf("") }
    var username by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    Box(modifier = Modifier.fillMaxSize().background(VortXTheme.colors.canvas), contentAlignment = Alignment.TopStart) {
        Column(
            modifier = Modifier.padding(TvDimens.edge).widthIn(max = 900.dp),
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
        ) {
            Text("Add a network share", style = VortXTheme.type.sectionTitle)
            Text("For example smb://192.168.1.20/Movies for a shared folder, or 192.168.1.20:5005/video for a Synology WebDAV share. Leave the username empty if the share has no login.",
                style = VortXTheme.type.label.copy(color = VortXTheme.colors.textSecondary))
            TvShareField("Address", address, { address = it }, KeyboardType.Uri)
            TvShareField("Name (optional)", name, { name = it }, KeyboardType.Text)
            TvShareField("Username", username, { username = it }, KeyboardType.Text)
            TvShareField("Password", password, { password = it }, KeyboardType.Password, password = true)
            error?.let { Text(it, style = VortXTheme.type.label.copy(color = VortXTheme.colors.danger)) }
            Row(horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
                TvFilterChip(
                    label = if (busy) "Checking…" else "Add share",
                    selected = false,
                    enabled = !busy && address.isNotBlank(),
                    onClick = {
                        busy = true
                        error = null
                        scope.launch {
                            error = store.addReportingError(name, address, username, password)
                            busy = false
                            if (error == null) onDone()
                        }
                    },
                )
                TvFilterChip(label = "Cancel", selected = false, enabled = !busy, onClick = onDone)
            }
        }
    }
}

@Composable
private fun TvShareField(label: String, value: String, onChange: (String) -> Unit, keyboard: KeyboardType, password: Boolean = false) {
    val colors = VortXTheme.colors
    OutlinedTextField(
        value = value,
        onValueChange = onChange,
        modifier = Modifier.fillMaxWidth(),
        label = { androidx.compose.material3.Text(label) },
        singleLine = true,
        visualTransformation = if (password) PasswordVisualTransformation() else VisualTransformation.None,
        keyboardOptions = KeyboardOptions(keyboardType = keyboard, imeAction = ImeAction.Next),
        colors = OutlinedTextFieldDefaults.colors(
            focusedBorderColor = colors.accent,
            unfocusedBorderColor = colors.hairline,
            cursorColor = colors.accent,
        ),
    )
}

@OptIn(ExperimentalTvMaterial3Api::class)
@Composable
private fun TvShareRow(icon: ImageVector, title: String, detail: String?, onClick: () -> Unit, onLongClick: (() -> Unit)? = null) {
    val colors = VortXTheme.colors
    Surface(
        onClick = onClick,
        onLongClick = onLongClick,
        modifier = Modifier.fillMaxWidth(),
        shape = ClickableSurfaceDefaults.shape(shape = VortXShapes.control),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = colors.surface1,
            contentColor = colors.textPrimary,
            focusedContainerColor = colors.surface3,
            focusedContentColor = colors.textPrimary,
        ),
        border = ClickableSurfaceDefaults.border(
            focusedBorder = Border(BorderStroke(TvDimens.focusBorder, colors.accentBright), shape = VortXShapes.control),
        ),
    ) {
        Row(
            modifier = Modifier.padding(VortXTheme.spacing.md),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
        ) {
            Icon(icon, contentDescription = null, tint = colors.accent, modifier = Modifier.size(32.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(title, style = VortXTheme.type.cardTitle, maxLines = 1)
                detail?.let { Text(it, style = VortXTheme.type.label.copy(color = colors.textSecondary), maxLines = 1) }
            }
        }
    }
}

@Composable
private fun TvShareNote(text: String) {
    Text(text, style = VortXTheme.type.label.copy(color = VortXTheme.colors.textTertiary))
}
