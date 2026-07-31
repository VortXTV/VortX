package com.vortx.android.ui.screens

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
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.vortx.android.mediaserver.MediaServerAuthException
import com.vortx.android.mediaserver.MediaServerAuthResult
import com.vortx.android.mediaserver.MediaServerAddResult
import com.vortx.android.mediaserver.MediaServerKind
import com.vortx.android.mediaserver.MediaServerRecord
import com.vortx.android.mediaserver.MediaServerRemovalResult
import com.vortx.android.mediaserver.MediaServerRepository
import com.vortx.android.mediaserver.MediaServerResolve
import com.vortx.android.mediaserver.PlexClient
import com.vortx.android.mediaserver.PlexServerCandidate
import com.vortx.android.mediaserver.JellyfinClient
import com.vortx.android.mediaserver.EmbyClient
import com.vortx.android.ui.components.Chip
import com.vortx.android.ui.components.PrimaryButton
import com.vortx.android.ui.components.SurfaceCard
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXTheme
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import java.util.UUID

/// Settings > Media servers: connect and manage the user's own Plex, Jellyfin, and Emby servers so a title
/// they already own plays straight from their box, ranked with every other source. Kotlin/Compose port of the
/// Apple `MediaServersSettingsView`; it drives the [MediaServerRepository] singleton directly (the same way
/// [IntegrationsScreen] drives the Trakt/SIMKL auth singletons), so it needs no ViewModel. A connect the user
/// navigates away from is simply cancelled with the composition scope; once a token is stored, reopening shows
/// the server connected.
///
/// DORMANT: with no server connected the app makes zero media-server network calls anywhere; this screen is
/// the only surface that originates one (in an add flow).
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MediaServersScreen(onBack: () -> Unit, modifier: Modifier = Modifier) {
    val appContext = LocalContext.current.applicationContext
    LaunchedEffect(Unit) { MediaServerRepository.init(appContext) }

    var servers by remember { mutableStateOf(MediaServerRepository.servers()) }
    var adding by remember { mutableStateOf<MediaServerKind?>(null) }
    var mutationError by remember { mutableStateOf<String?>(null) }
    fun refresh() { servers = MediaServerRepository.servers() }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Media servers", style = VortXTheme.type.cardTitle) },
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
                "Connect your own Plex, Jellyfin, or Emby server to play what you already own straight from " +
                    "your box. Your logins stay on this device (encrypted) and playback streams directly from " +
                    "the server to this device. Your servers rank against your other sources.",
                style = VortXTheme.type.body.copy(color = VortXTheme.colors.textSecondary),
            )
            mutationError?.let {
                Text(it, style = VortXTheme.type.label.copy(color = VortXTheme.colors.danger))
            }

            servers.forEach { record ->
                ServerCard(
                    record = record,
                    onRemove = {
                        mutationError = null
                        val result = MediaServerRepository.remove(record.id)
                        refresh()
                        when (result) {
                            MediaServerRemovalResult.REMOVED -> true
                            MediaServerRemovalResult.UNCHANGED -> {
                                mutationError =
                                    "Could not securely remove this server. It is still connected. Try again."
                                false
                            }
                            MediaServerRemovalResult.CLEANUP_PENDING -> {
                                mutationError =
                                    "The server is disconnected. Secure cleanup will retry after restart."
                                true
                            }
                        }
                    },
                )
            }

            val kind = adding
            if (kind != null) {
                AddServerFlow(
                    kind = kind,
                    onDone = { refresh(); adding = null },
                    onCancel = { adding = null },
                )
            } else {
                AddSection(hasServers = servers.isNotEmpty(), onPick = { adding = it })
            }
        }
    }
}

@Composable
private fun AddSection(hasServers: Boolean, onPick: (MediaServerKind) -> Unit) {
    SurfaceCard(modifier = Modifier.fillMaxWidth()) {
        Column(
            modifier = Modifier.padding(VortXTheme.spacing.lg),
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
        ) {
            Text(if (hasServers) "Add another server" else "Add a server", style = VortXTheme.type.cardTitle)
            Row(horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
                Chip(label = "Plex", selected = false, onClick = { onPick(MediaServerKind.PLEX) })
                Chip(label = "Jellyfin", selected = false, onClick = { onPick(MediaServerKind.JELLYFIN) })
                Chip(label = "Emby", selected = false, onClick = { onPick(MediaServerKind.EMBY) })
            }
        }
    }
}

@Composable
private fun ServerCard(record: MediaServerRecord, onRemove: () -> Boolean) {
    val colors = VortXTheme.colors
    var confirmRemove by remember { mutableStateOf(false) }
    SurfaceCard(modifier = Modifier.fillMaxWidth()) {
        Column(
            modifier = Modifier.padding(VortXTheme.spacing.lg),
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
        ) {
            Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(record.name, style = VortXTheme.type.cardTitle, modifier = Modifier.fillMaxWidth(0.7f))
                Text(
                    record.kind.label,
                    style = VortXTheme.type.label.copy(color = colors.textTertiary),
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            record.urls.firstOrNull()?.let {
                Text(it, style = VortXTheme.type.label.copy(color = colors.textTertiary))
            }
            if (record.needsReauth) {
                Text("Sign in again to use this server.", style = VortXTheme.type.label.copy(color = colors.danger))
            }
            if (confirmRemove) {
                Row(horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
                    Chip(
                        label = "Remove server",
                        selected = false,
                        onClick = {
                            if (onRemove()) confirmRemove = false
                        },
                        accent = colors.danger,
                        accentText = colors.danger,
                    )
                    Chip(label = "Keep", selected = false, onClick = { confirmRemove = false })
                }
            } else {
                Chip(label = "Remove", selected = false, onClick = { confirmRemove = true })
            }
        }
    }
}

// MARK: - Add-server flows

@Composable
private fun AddServerFlow(kind: MediaServerKind, onDone: () -> Unit, onCancel: () -> Unit) {
    SurfaceCard(modifier = Modifier.fillMaxWidth()) {
        Column(
            modifier = Modifier.padding(VortXTheme.spacing.lg),
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
        ) {
            when (kind) {
                MediaServerKind.PLEX -> PlexAddFlow(onDone)
                MediaServerKind.JELLYFIN -> JellyfinAddFlow(onDone)
                MediaServerKind.EMBY -> EmbyAddFlow(onDone)
            }
            Chip(label = "Cancel", selected = false, onClick = onCancel)
        }
    }
}

@Composable
private fun PlexAddFlow(onDone: () -> Unit) {
    val colors = VortXTheme.colors
    val scope = rememberCoroutineScope()
    val uriHandler = LocalUriHandler.current
    var code by remember { mutableStateOf<String?>(null) }
    var candidates by remember { mutableStateOf<List<PlexServerCandidate>>(emptyList()) }
    var accountToken by remember { mutableStateOf<String?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    val retryIdentities = remember { MediaServerRetryIdentities() }

    fun connect(candidate: PlexServerCandidate) {
        val retryKey = candidate.machineId.ifEmpty { candidate.urls.joinToString(separator = "|") }
        val result = MediaServerRepository.add(
            record = MediaServerRecord(
                id = retryIdentities.idFor(retryKey),
                name = candidate.name,
                kind = MediaServerKind.PLEX,
                urls = candidate.urls,
                userId = "",
                machineId = candidate.machineId,
                addedAtMillis = System.currentTimeMillis(),
                needsReauth = false,
            ),
            token = candidate.accessToken,
            plexAccountToken = accountToken,
        )
        when (result) {
            MediaServerAddResult.CONNECTED -> {
                retryIdentities.forget(retryKey)
                error = null
                onDone()
            }
            MediaServerAddResult.NOT_CONNECTED -> {
                error = "Could not connect this server. It is not connected. Try again."
            }
            MediaServerAddResult.RECOVERY_PENDING -> {
                error =
                    "Could not confirm the server connection. Secure recovery will finish after restart. " +
                        "Do not retry it yet."
            }
        }
    }

    Text("Plex", style = VortXTheme.type.cardTitle)
    when {
        candidates.isNotEmpty() -> {
            Text("Choose a server to connect.", style = VortXTheme.type.body.copy(color = colors.textSecondary))
            candidates.forEach { c -> Chip(label = c.name, selected = false, onClick = { connect(c) }) }
        }

        code != null -> PairingPanel(
            code = code!!,
            instruction = "On plex.tv/link, enter this code to connect your Plex account.",
            openLabel = "Open plex.tv/link",
            onOpen = { uriHandler.openUri("https://plex.tv/link") },
        )

        else -> {
            Text(
                "Link your Plex account, then pick a server. This device shows up as a signed-in device on plex.tv.",
                style = VortXTheme.type.body.copy(color = colors.textSecondary),
            )
            PrimaryButton(
                text = "Connect Plex",
                loading = busy,
                onClick = {
                    scope.launch {
                        busy = true
                        error = null
                        try {
                            val clientId = MediaServerRepository.plexClientId
                            val pin = PlexClient.requestPin(clientId)
                            code = pin.code
                            val token = PlexClient.pollForToken(pin, clientId)
                            accountToken = token
                            val found = PlexClient.discoverServers(token, clientId)
                            code = null
                            when {
                                found.size == 1 -> connect(found.first())
                                found.isEmpty() -> error = "No Plex Media Server was found on your account."
                                else -> candidates = found
                            }
                        } catch (e: CancellationException) {
                            throw e
                        } catch (e: Exception) {
                            code = null
                            error = e.message ?: "Could not connect to Plex."
                        } finally {
                            busy = false
                        }
                    }
                },
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
    error?.let { Text(it, style = VortXTheme.type.label.copy(color = colors.danger)) }
}

@Composable
private fun JellyfinAddFlow(onDone: () -> Unit) {
    val colors = VortXTheme.colors
    val scope = rememberCoroutineScope()
    val quickConnectLifecycle = remember(scope) { JellyfinQuickConnectLifecycle(scope) }
    DisposableEffect(quickConnectLifecycle) {
        onDispose { quickConnectLifecycle.cancel() }
    }
    var phase by remember { mutableStateOf(Phase.URL) }
    var base by remember { mutableStateOf("") }
    var username by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var qcCode by remember { mutableStateOf<String?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    var pendingResult by remember { mutableStateOf<MediaServerAuthResult?>(null) }
    val retryIdentities = remember { MediaServerRetryIdentities() }

    fun finish(result: MediaServerAuthResult) {
        val root = MediaServerResolve.normalizedBase(base)
        if (root == null) { error = MediaServerAuthException.BadUrl.message; return }
        val retryKey = "jellyfin|$root|${result.serverId}|${result.userId}"
        val addResult = MediaServerRepository.add(
            record = MediaServerRecord(
                id = retryIdentities.idFor(retryKey),
                name = result.serverName ?: hostOf(root) ?: "Jellyfin",
                kind = MediaServerKind.JELLYFIN,
                urls = listOf(root),
                userId = result.userId,
                machineId = result.serverId,
                addedAtMillis = System.currentTimeMillis(),
                needsReauth = false,
            ),
            token = result.accessToken,
        )
        when (addResult) {
            MediaServerAddResult.CONNECTED -> {
                retryIdentities.forget(retryKey)
                pendingResult = null
                error = null
                onDone()
            }
            MediaServerAddResult.NOT_CONNECTED -> {
                pendingResult = result
                error = "Could not connect this server. It is not connected. Try again."
            }
            MediaServerAddResult.RECOVERY_PENDING -> {
                pendingResult = null
                error =
                    "Could not confirm the server connection. Secure recovery will finish after restart. " +
                        "Do not retry it yet."
            }
        }
    }

    Text("Jellyfin", style = VortXTheme.type.cardTitle)
    when (phase) {
        Phase.URL -> {
            ServerUrlField(base) { base = it }
            PrimaryButton(
                text = "Continue",
                enabled = MediaServerResolve.normalizedBase(base) != null && !busy,
                loading = busy,
                onClick = {
                    quickConnectLifecycle.cancel()
                    scope.launch {
                        busy = true
                        error = null
                        try {
                            val deviceId = MediaServerRepository.deviceId
                            if (!JellyfinClient.quickConnectEnabled(base, deviceId)) {
                                phase = Phase.PASSWORD
                            } else {
                                val init = JellyfinClient.initiateQuickConnect(base, deviceId)
                                qcCode = init.code
                                phase = Phase.QUICK_CONNECT
                                quickConnectLifecycle.start(
                                    await = {
                                        JellyfinClient.awaitQuickConnect(base, init.secret, deviceId)
                                    },
                                    onSuccess = ::finish,
                                    onFailure = {
                                        phase = Phase.PASSWORD
                                        error = it.message ?: "Could not finish Quick Connect."
                                    },
                                )
                            }
                        } catch (e: CancellationException) {
                            throw e
                        } catch (e: Exception) {
                            phase = Phase.PASSWORD
                            error = e.message
                        } finally {
                            busy = false
                        }
                    }
                },
                modifier = Modifier.fillMaxWidth(),
            )
        }

        Phase.QUICK_CONNECT -> {
            qcCode?.let {
                PairingPanel(
                    code = it,
                    instruction = "In your Jellyfin app or on the web, open Quick Connect and enter this code.",
                    openLabel = null,
                    onOpen = {},
                )
            }
            Chip(
                label = "Use username & password instead",
                selected = false,
                onClick = {
                    quickConnectLifecycle.cancel()
                    qcCode = null
                    error = null
                    busy = false
                    phase = Phase.PASSWORD
                },
            )
        }

        Phase.PASSWORD -> {
            CredentialFields(username, password, { username = it }, { password = it })
            PrimaryButton(
                text = "Sign in",
                enabled = username.isNotEmpty() && password.isNotEmpty() && !busy,
                loading = busy,
                onClick = {
                    scope.launch {
                        busy = true
                        error = null
                        try {
                            finish(JellyfinClient.authByPassword(base, username, password, MediaServerRepository.deviceId))
                        } catch (e: CancellationException) {
                            throw e
                        } catch (e: Exception) {
                            error = e.message ?: "Could not sign in."
                        } finally {
                            busy = false
                        }
                    }
                },
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
    pendingResult?.let { result ->
        PrimaryButton(
            text = "Retry saving server",
            onClick = { finish(result) },
            modifier = Modifier.fillMaxWidth(),
        )
    }
    error?.let { Text(it, style = VortXTheme.type.label.copy(color = colors.danger)) }
}

@Composable
private fun EmbyAddFlow(onDone: () -> Unit) {
    val colors = VortXTheme.colors
    val scope = rememberCoroutineScope()
    var base by remember { mutableStateOf("") }
    var username by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    var pendingResult by remember { mutableStateOf<MediaServerAuthResult?>(null) }
    val retryIdentities = remember { MediaServerRetryIdentities() }

    fun finish(result: MediaServerAuthResult) {
        val root = MediaServerResolve.normalizedBase(base)
        if (root == null) { error = MediaServerAuthException.BadUrl.message; return }
        val retryKey = "emby|$root|${result.serverId}|${result.userId}"
        val addResult = MediaServerRepository.add(
            record = MediaServerRecord(
                id = retryIdentities.idFor(retryKey),
                name = result.serverName ?: hostOf(root) ?: "Emby",
                kind = MediaServerKind.EMBY,
                urls = listOf(root),
                userId = result.userId,
                machineId = result.serverId,
                addedAtMillis = System.currentTimeMillis(),
                needsReauth = false,
            ),
            token = result.accessToken,
        )
        when (addResult) {
            MediaServerAddResult.CONNECTED -> {
                retryIdentities.forget(retryKey)
                pendingResult = null
                error = null
                onDone()
            }
            MediaServerAddResult.NOT_CONNECTED -> {
                pendingResult = result
                error = "Could not connect this server. It is not connected. Try again."
            }
            MediaServerAddResult.RECOVERY_PENDING -> {
                pendingResult = null
                error =
                    "Could not confirm the server connection. Secure recovery will finish after restart. " +
                        "Do not retry it yet."
            }
        }
    }

    Text("Emby", style = VortXTheme.type.cardTitle)
    ServerUrlField(base) { base = it }
    CredentialFields(username, password, { username = it }, { password = it })
    PrimaryButton(
        text = "Sign in",
        enabled = MediaServerResolve.normalizedBase(base) != null && username.isNotEmpty() && !busy,
        loading = busy,
        onClick = {
            scope.launch {
                busy = true
                error = null
                try {
                    finish(EmbyClient.authByPassword(base, username, password, MediaServerRepository.deviceId))
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    error = e.message ?: "Could not sign in."
                } finally {
                    busy = false
                }
            }
        },
        modifier = Modifier.fillMaxWidth(),
    )
    pendingResult?.let { result ->
        PrimaryButton(
            text = "Retry saving server",
            onClick = { finish(result) },
            modifier = Modifier.fillMaxWidth(),
        )
    }
    error?.let { Text(it, style = VortXTheme.type.label.copy(color = colors.danger)) }
}

// MARK: - Shared pieces

private enum class Phase { URL, QUICK_CONNECT, PASSWORD }

internal class MediaServerRetryIdentities(
    private val generate: () -> UUID = UUID::randomUUID,
) {
    private val ids = mutableMapOf<String, UUID>()

    fun idFor(key: String): UUID = ids.getOrPut(key, generate)

    fun forget(key: String) {
        ids.remove(key)
    }
}

/**
 * Owns one Jellyfin Quick Connect poll and invalidates all of its callbacks when the user falls back to
 * password sign-in or leaves the add flow. Cancellation alone is not enough here: the poll's blocking
 * HTTP call may take a moment to return, so [generation] also prevents a stale success from adding a
 * server after the user has explicitly abandoned Quick Connect.
 */
internal class JellyfinQuickConnectLifecycle(private val scope: CoroutineScope) {
    private var generation = 0L
    private var pollJob: Job? = null

    internal val isPolling: Boolean
        get() = pollJob?.isActive == true

    internal fun <T> start(
        await: suspend () -> T,
        onSuccess: (T) -> Unit,
        onFailure: (Exception) -> Unit,
    ) {
        cancel()
        val token = generation
        val launched = scope.launch(start = CoroutineStart.LAZY) {
            try {
                val result = await()
                if (token == generation) onSuccess(result)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                if (token == generation) onFailure(e)
            } finally {
                if (token == generation) pollJob = null
            }
        }
        pollJob = launched
        launched.start()
    }

    internal fun cancel() {
        generation += 1
        pollJob?.cancel()
        pollJob = null
    }
}

@Composable
private fun PairingPanel(code: String, instruction: String, openLabel: String?, onOpen: () -> Unit) {
    val colors = VortXTheme.colors
    Column(verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
        Text(
            code,
            style = VortXTheme.type.screenTitle.copy(color = colors.accent, textAlign = TextAlign.Center),
            modifier = Modifier.fillMaxWidth(),
        )
        Text(instruction, style = VortXTheme.type.label.copy(color = colors.textSecondary))
        Row(
            horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            CircularProgressIndicator(color = colors.accent, modifier = Modifier.size(20.dp))
            Text("Waiting for you to authorize…", style = VortXTheme.type.body.copy(color = colors.textSecondary))
        }
        if (openLabel != null) {
            PrimaryButton(text = openLabel, onClick = onOpen, modifier = Modifier.fillMaxWidth())
        }
    }
}

@Composable
private fun ServerUrlField(value: String, onChange: (String) -> Unit) {
    OutlinedTextField(
        value = value,
        onValueChange = onChange,
        label = { Text("Server address") },
        placeholder = { Text("http://192.168.1.10:8096") },
        singleLine = true,
        keyboardOptions = KeyboardOptions(
            capitalization = KeyboardCapitalization.None,
            keyboardType = KeyboardType.Uri,
            imeAction = ImeAction.Next,
        ),
        modifier = Modifier.fillMaxWidth(),
    )
}

@Composable
private fun CredentialFields(
    username: String,
    password: String,
    onUsername: (String) -> Unit,
    onPassword: (String) -> Unit,
) {
    OutlinedTextField(
        value = username,
        onValueChange = onUsername,
        label = { Text("Username") },
        singleLine = true,
        keyboardOptions = KeyboardOptions(
            capitalization = KeyboardCapitalization.None,
            imeAction = ImeAction.Next,
        ),
        modifier = Modifier.fillMaxWidth(),
    )
    OutlinedTextField(
        value = password,
        onValueChange = onPassword,
        label = { Text("Password") },
        singleLine = true,
        visualTransformation = PasswordVisualTransformation(),
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = ImeAction.Done),
        modifier = Modifier.fillMaxWidth(),
    )
}

private fun hostOf(url: String): String? =
    url.substringAfter("://", "").substringBefore('/').substringBefore(':').takeIf { it.isNotEmpty() }
