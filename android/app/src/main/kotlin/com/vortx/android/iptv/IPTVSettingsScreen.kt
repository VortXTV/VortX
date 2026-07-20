package com.vortx.android.iptv

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import com.vortx.android.data.CatalogRepository
import com.vortx.android.ui.components.Chip
import com.vortx.android.ui.components.PrimaryButton
import com.vortx.android.ui.components.SurfaceCard
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXTheme
import kotlinx.coroutines.launch

/// Settings > Live TV (IPTV): add an M3U playlist or an Xtream Codes login (with an optional XMLTV EPG URL),
/// list the installed playlists, and remove them. Kotlin/Compose port of the Apple `IPTVSettingsView`.
///
/// Adding registers the source with the hosted `iptv.vortx.tv` converter, which returns a slug; the app then
/// installs `https://iptv.vortx.tv/c/<slug>/manifest.json` through the EXISTING add-on pipeline
/// ([CatalogRepository.installAddon]), so the channels appear as normal add-on catalogs with NO bespoke Live
/// playback code, exactly as on Apple (the converter output is a normal add-on). Removing uninstalls the
/// add-on ([CatalogRepository.removeAddon]) and revokes the slug server-side. Credentials stay in the
/// encrypted store (via [IPTVPlaylists] / [IPTVPlaylistStore]); only the non-secret metadata is kept locally.
///
/// It takes [repo] directly (like `LibraryTransferScreen`) because installing / uninstalling is an engine
/// action; the playlist record itself is driven through the [IPTVPlaylists] singleton, the same self-contained
/// way `MediaServersScreen` drives `MediaServerRepository`.
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun IPTVSettingsScreen(repo: CatalogRepository, onBack: () -> Unit, modifier: Modifier = Modifier) {
    val appContext = LocalContext.current.applicationContext
    LaunchedEffect(Unit) { IPTVPlaylists.init(appContext) }

    val scope = rememberCoroutineScope()
    var playlists by remember { mutableStateOf(runCatching { IPTVPlaylists.playlists() }.getOrDefault(emptyList())) }
    fun refresh() { playlists = IPTVPlaylists.playlists() }

    var kind by remember { mutableStateOf(IPTVKind.M3U) }
    var name by remember { mutableStateOf("") }
    var m3uUrl by remember { mutableStateOf("") }
    var xtreamHost by remember { mutableStateOf("") }
    var xtreamUser by remember { mutableStateOf("") }
    var xtreamPass by remember { mutableStateOf("") }
    var xmltvUrl by remember { mutableStateOf("") }

    var isWorking by remember { mutableStateOf(false) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    var removingSlug by remember { mutableStateOf<String?>(null) }

    fun clearForm() {
        name = ""; m3uUrl = ""; xtreamHost = ""; xtreamUser = ""; xtreamPass = ""; xmltvUrl = ""
        errorMessage = null
    }

    val canSubmit = when (kind) {
        IPTVKind.M3U -> m3uUrl.trim().isNotEmpty()
        IPTVKind.XTREAM ->
            xtreamHost.trim().isNotEmpty() && xtreamUser.trim().isNotEmpty() && xtreamPass.isNotEmpty()
    }

    fun submit() {
        errorMessage = null
        isWorking = true
        val chosen = kind
        val trimmedName = name.trim()
        val trimmedEpg = xmltvUrl.trim().ifEmpty { null }
        scope.launch {
            val result: Result<IPTVRegistration>
            val credentials: IPTVCredentials
            when (chosen) {
                IPTVKind.M3U -> {
                    val url = m3uUrl.trim()
                    result = IPTVConverterClient.registerM3U(url, trimmedEpg, trimmedName.ifEmpty { null })
                    credentials = IPTVCredentials(m3uUrl = url, xmltvUrl = trimmedEpg)
                }
                IPTVKind.XTREAM -> {
                    val host = xtreamHost.trim()
                    val user = xtreamUser.trim()
                    result = IPTVConverterClient.registerXtream(host, user, xtreamPass, trimmedEpg, trimmedName.ifEmpty { null })
                    credentials = IPTVCredentials(xtreamHost = host, xtreamUser = user, xtreamPass = xtreamPass, xmltvUrl = trimmedEpg)
                }
            }
            result.fold(
                onSuccess = { reg ->
                    // Install the returned manifest as a normal add-on through the existing pipeline. A failure
                    // here surfaces to the user and the playlist is NOT recorded (so a failed install is never
                    // left dangling in the list), matching Apple's ordering.
                    repo.installAddon(reg.manifestUrl).fold(
                        onSuccess = {
                            val displayName = trimmedName.ifEmpty { defaultName(chosen) }
                            IPTVPlaylists.add(
                                IPTVPlaylist(
                                    id = reg.slug,
                                    name = displayName,
                                    kind = chosen,
                                    transportUrl = reg.manifestUrl,
                                    createdAtMillis = System.currentTimeMillis(),
                                ),
                                credentials,
                            )
                            clearForm()
                            refresh()
                        },
                        onFailure = { errorMessage = it.message ?: "Could not install this playlist." },
                    )
                },
                onFailure = { errorMessage = it.message ?: "Could not add this playlist." },
            )
            isWorking = false
        }
    }

    fun remove(playlist: IPTVPlaylist) {
        removingSlug = playlist.id
        scope.launch {
            // Uninstall the engine add-on first (so the pipeline stops serving it), then revoke the slug
            // server-side (fail-soft), then drop the local record + credentials. Mirrors Apple's remove order.
            repo.installedAddons().getOrNull()
                ?.firstOrNull { it.transportUrl == playlist.transportUrl }
                ?.let { repo.removeAddon(it) }
            IPTVConverterClient.revoke(playlist.id)
            IPTVPlaylists.remove(playlist.id)
            refresh()
            removingSlug = null
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Live TV", style = VortXTheme.type.cardTitle) },
                navigationIcon = {
                    IconButton(onClick = onBack) { Icon(VortXIcons.back, contentDescription = "Back") }
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
                "Add an M3U playlist or an Xtream Codes login and its channels appear in your catalogs. Your " +
                    "details stay on this device and go only to VortX's converter over an encrypted connection. " +
                    "An optional XMLTV URL adds the now / next guide.",
                style = VortXTheme.type.body.copy(color = VortXTheme.colors.textSecondary),
            )

            if (playlists.isNotEmpty()) {
                InstalledSection(
                    playlists = playlists,
                    removingSlug = removingSlug,
                    isWorking = isWorking,
                    onRemove = ::remove,
                )
            }

            AddSection(
                kind = kind,
                onKindChange = { kind = it; errorMessage = null },
                name = name,
                onNameChange = { name = it },
                m3uUrl = m3uUrl,
                onM3uUrlChange = { m3uUrl = it },
                xtreamHost = xtreamHost,
                onXtreamHostChange = { xtreamHost = it },
                xtreamUser = xtreamUser,
                onXtreamUserChange = { xtreamUser = it },
                xtreamPass = xtreamPass,
                onXtreamPassChange = { xtreamPass = it },
                xmltvUrl = xmltvUrl,
                onXmltvUrlChange = { xmltvUrl = it },
                errorMessage = errorMessage,
                isWorking = isWorking,
                canSubmit = canSubmit,
                onSubmit = ::submit,
            )
        }
    }
}

/// The default display name when the user leaves the name blank (Apple `defaultName(for:)`).
private fun defaultName(kind: IPTVKind): String = when (kind) {
    IPTVKind.M3U -> "M3U playlist"
    IPTVKind.XTREAM -> "Xtream playlist"
}

@Composable
private fun InstalledSection(
    playlists: List<IPTVPlaylist>,
    removingSlug: String?,
    isWorking: Boolean,
    onRemove: (IPTVPlaylist) -> Unit,
) {
    val colors = VortXTheme.colors
    SurfaceCard(modifier = Modifier.fillMaxWidth()) {
        Column(
            modifier = Modifier.padding(VortXTheme.spacing.lg),
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
        ) {
            Text("Your playlists", style = VortXTheme.type.cardTitle)
            playlists.forEach { playlist ->
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(modifier = Modifier.fillMaxWidth(0.72f)) {
                        Text(playlist.name, style = VortXTheme.type.body.copy(color = colors.textPrimary))
                        Text(playlist.kind.label, style = VortXTheme.type.label.copy(color = colors.textTertiary))
                    }
                    if (removingSlug == playlist.id) {
                        CircularProgressIndicator(modifier = Modifier.size(20.dp), color = colors.accent)
                    } else {
                        IconButton(onClick = { onRemove(playlist) }, enabled = !isWorking) {
                            Icon(VortXIcons.delete, contentDescription = "Remove ${playlist.name}", tint = colors.accent)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun AddSection(
    kind: IPTVKind,
    onKindChange: (IPTVKind) -> Unit,
    name: String,
    onNameChange: (String) -> Unit,
    m3uUrl: String,
    onM3uUrlChange: (String) -> Unit,
    xtreamHost: String,
    onXtreamHostChange: (String) -> Unit,
    xtreamUser: String,
    onXtreamUserChange: (String) -> Unit,
    xtreamPass: String,
    onXtreamPassChange: (String) -> Unit,
    xmltvUrl: String,
    onXmltvUrlChange: (String) -> Unit,
    errorMessage: String?,
    isWorking: Boolean,
    canSubmit: Boolean,
    onSubmit: () -> Unit,
) {
    val colors = VortXTheme.colors
    SurfaceCard(modifier = Modifier.fillMaxWidth()) {
        Column(
            modifier = Modifier.padding(VortXTheme.spacing.lg),
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
        ) {
            Text("Add a playlist", style = VortXTheme.type.cardTitle)

            // Type toggle: two chips, the same shape MediaServersScreen uses to pick a server kind.
            Row(horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
                Chip(label = "M3U URL", selected = kind == IPTVKind.M3U, onClick = { onKindChange(IPTVKind.M3U) })
                Chip(label = "Xtream login", selected = kind == IPTVKind.XTREAM, onClick = { onKindChange(IPTVKind.XTREAM) })
            }

            IPTVField("Name (optional)", name, onNameChange, placeholder = "My IPTV", isUrl = false)

            if (kind == IPTVKind.M3U) {
                IPTVField("M3U URL", m3uUrl, onM3uUrlChange, placeholder = "https://provider.example/playlist.m3u", isUrl = true)
            } else {
                IPTVField("Server URL", xtreamHost, onXtreamHostChange, placeholder = "http://panel.example.com:8080", isUrl = true)
                IPTVField("Username", xtreamUser, onXtreamUserChange, placeholder = "username", isUrl = false)
                IPTVField("Password", xtreamPass, onXtreamPassChange, placeholder = "password", isUrl = false, secure = true)
            }
            IPTVField("XMLTV EPG URL (optional)", xmltvUrl, onXmltvUrlChange, placeholder = "https://provider.example/xmltv.php", isUrl = true)

            if (errorMessage != null) {
                Text(errorMessage, style = VortXTheme.type.label.copy(color = colors.danger))
            }

            PrimaryButton(
                text = if (isWorking) "Adding..." else "Add playlist",
                onClick = onSubmit,
                modifier = Modifier.fillMaxWidth(),
                enabled = !isWorking && canSubmit,
                loading = isWorking,
                leadingIcon = VortXIcons.add,
            )
        }
    }
}

/// One labelled text field for the add form. Mirrors the Apple `field(...)` helper: monospace-friendly value,
/// no autocapitalise / autocorrect (URLs and credentials must not be silently rewritten), a URL keyboard for
/// URL fields, and a password mask + visual transformation for the secret field.
@Composable
private fun IPTVField(
    label: String,
    value: String,
    onValueChange: (String) -> Unit,
    placeholder: String,
    isUrl: Boolean,
    secure: Boolean = false,
) {
    val colors = VortXTheme.colors
    Column(verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs)) {
        Text(label, style = VortXTheme.type.label.copy(color = colors.textSecondary))
        OutlinedTextField(
            value = value,
            onValueChange = onValueChange,
            modifier = Modifier.fillMaxWidth(),
            singleLine = true,
            placeholder = { Text(placeholder, style = VortXTheme.type.label.copy(color = colors.textTertiary)) },
            visualTransformation = if (secure) PasswordVisualTransformation() else androidx.compose.ui.text.input.VisualTransformation.None,
            keyboardOptions = KeyboardOptions(
                capitalization = KeyboardCapitalization.None,
                autoCorrectEnabled = false,
                keyboardType = when {
                    secure -> KeyboardType.Password
                    isUrl -> KeyboardType.Uri
                    else -> KeyboardType.Text
                },
                imeAction = ImeAction.Done,
            ),
        )
    }
}
