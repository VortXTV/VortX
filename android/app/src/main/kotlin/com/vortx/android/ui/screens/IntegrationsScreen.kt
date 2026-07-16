package com.vortx.android.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
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
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.vortx.android.integrations.SIMKLAuth
import com.vortx.android.integrations.ScrobbleService
import com.vortx.android.integrations.TraktAuth
import com.vortx.android.ui.components.PrimaryButton
import com.vortx.android.ui.components.SurfaceCard
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXTheme
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

/// Settings > Integrations: connect Trakt (device-code flow: show the user code + verification URL, poll to
/// connected) and SIMKL (PIN flow), with a per-provider scrobble toggle and Disconnect when connected.
/// Mirrors the Apple `ExternalServicesSettingsView`. Self-contained: it drives [TraktAuth] / [SIMKLAuth]
/// directly on a composition-scoped coroutine (a connect the user navigates away from is simply cancelled;
/// once authorized, the token is already stored, so reopening shows Connected).
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun IntegrationsScreen(onBack: () -> Unit, modifier: Modifier = Modifier) {
    val appContext = LocalContext.current.applicationContext
    val uriHandler = LocalUriHandler.current
    val scope = rememberCoroutineScope()

    var traktState by remember { mutableStateOf<ConnectUi>(ConnectUi.Idle) }
    var simklState by remember { mutableStateOf<ConnectUi>(ConnectUi.Idle) }
    var traktScrobble by remember { mutableStateOf(true) }
    var simklScrobble by remember { mutableStateOf(true) }

    // Reflect the persisted connection + toggle state on open (both are synchronous reads).
    LaunchedEffect(Unit) {
        ScrobbleService.init(appContext)
        if (TraktAuth.isSignedIn) traktState = ConnectUi.Connected
        if (SIMKLAuth.isSignedIn) simklState = ConnectUi.Connected
        traktScrobble = ScrobbleService.isTraktScrobbleEnabled()
        simklScrobble = ScrobbleService.isSimklScrobbleEnabled()
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Integrations", style = VortXTheme.type.cardTitle) },
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
                "Sync your watch progress and history to Trakt or SIMKL. Playback scrobbles automatically " +
                    "while connected.",
                style = VortXTheme.type.body.copy(color = VortXTheme.colors.textSecondary),
            )

            ProviderCard(
                name = "Trakt",
                description = "Scrobble movies and episodes as you watch, and record what you finish.",
                configured = TraktAuth.isConfigured,
                state = traktState,
                scrobbleEnabled = traktScrobble,
                onScrobbleChange = {
                    traktScrobble = it
                    ScrobbleService.setTraktScrobbleEnabled(it)
                },
                onOpenUrl = { uriHandler.openUri(it) },
                onConnect = {
                    runConnect(
                        scope = scope,
                        onState = { traktState = it },
                        requestCode = {
                            val code = TraktAuth.requestDeviceCode()
                            ConnectStep(
                                userCode = code.userCode,
                                verificationUrl = code.verificationUrl,
                                awaitAuthorized = {
                                    TraktAuth.pollForToken(code.deviceCode, code.interval, code.expiresIn)
                                },
                            )
                        },
                    )
                },
                onDisconnect = {
                    TraktAuth.signOut()
                    traktState = ConnectUi.Idle
                },
            )

            ProviderCard(
                name = "SIMKL",
                description = "Record movies and episodes you finish to your SIMKL history.",
                configured = SIMKLAuth.isConfigured,
                state = simklState,
                scrobbleEnabled = simklScrobble,
                onScrobbleChange = {
                    simklScrobble = it
                    ScrobbleService.setSimklScrobbleEnabled(it)
                },
                onOpenUrl = { uriHandler.openUri(it) },
                onConnect = {
                    runConnect(
                        scope = scope,
                        onState = { simklState = it },
                        requestCode = {
                            val pin = SIMKLAuth.requestPin()
                            ConnectStep(
                                userCode = pin.userCode,
                                verificationUrl = pin.verificationUrl,
                                awaitAuthorized = {
                                    SIMKLAuth.pollForToken(pin.userCode, pin.interval, pin.expiresIn)
                                },
                            )
                        },
                    )
                },
                onDisconnect = {
                    SIMKLAuth.signOut()
                    simklState = ConnectUi.Idle
                },
            )
        }
    }
}

/// One connect flow's two async steps, kept together so [runConnect] can drive request -> await -> connected
/// uniformly for both providers (Trakt device code, SIMKL PIN).
private class ConnectStep(
    val userCode: String,
    val verificationUrl: String,
    val awaitAuthorized: suspend () -> Any?,
)

/// Drive a provider's connect flow, pushing [ConnectUi] transitions through [onState]. Rethrows
/// [CancellationException] (never swallow it) so navigating away cleanly cancels the poll; any other failure
/// surfaces as [ConnectUi.Error].
private fun runConnect(
    scope: CoroutineScope,
    onState: (ConnectUi) -> Unit,
    requestCode: suspend () -> ConnectStep,
) {
    scope.launch {
        onState(ConnectUi.Requesting)
        try {
            val step = requestCode()
            onState(ConnectUi.Awaiting(step.userCode, step.verificationUrl))
            step.awaitAuthorized()
            onState(ConnectUi.Connected)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            onState(ConnectUi.Error(e.message ?: "Could not connect. Please try again."))
        }
    }
}

@Composable
private fun ProviderCard(
    name: String,
    description: String,
    configured: Boolean,
    state: ConnectUi,
    scrobbleEnabled: Boolean,
    onScrobbleChange: (Boolean) -> Unit,
    onOpenUrl: (String) -> Unit,
    onConnect: () -> Unit,
    onDisconnect: () -> Unit,
) {
    val colors = VortXTheme.colors
    SurfaceCard(modifier = Modifier.fillMaxWidth()) {
        Column(
            modifier = Modifier.padding(VortXTheme.spacing.lg),
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
        ) {
            Text(name, style = VortXTheme.type.cardTitle)
            Text(description, style = VortXTheme.type.body.copy(color = colors.textSecondary))

            when {
                !configured -> Text(
                    "Not available in this build.",
                    style = VortXTheme.type.label.copy(color = colors.textTertiary),
                )

                state is ConnectUi.Connected -> {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(VortXIcons.checkmarkCircle, contentDescription = null, tint = colors.accent)
                        Text("Connected", style = VortXTheme.type.cardTitle, modifier = Modifier.fillMaxWidth(0.6f))
                    }
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            "Scrobble playback",
                            style = VortXTheme.type.body,
                            modifier = Modifier.fillMaxWidth(0.7f),
                        )
                        Switch(checked = scrobbleEnabled, onCheckedChange = onScrobbleChange)
                    }
                    PrimaryButton(text = "Disconnect", onClick = onDisconnect, modifier = Modifier.fillMaxWidth())
                }

                state is ConnectUi.Awaiting -> {
                    Text(
                        "Enter this code to link $name:",
                        style = VortXTheme.type.label.copy(color = colors.textSecondary),
                    )
                    Text(
                        state.userCode,
                        style = VortXTheme.type.screenTitle.copy(color = colors.accent, textAlign = TextAlign.Center),
                        modifier = Modifier.fillMaxWidth(),
                    )
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        CircularProgressIndicator(color = colors.accent, modifier = Modifier.size(20.dp))
                        Text(
                            "Waiting for you to authorize…",
                            style = VortXTheme.type.body.copy(color = colors.textSecondary),
                        )
                    }
                    PrimaryButton(
                        text = "Open $name",
                        onClick = { onOpenUrl(state.verificationUrl) },
                        modifier = Modifier.fillMaxWidth(),
                    )
                }

                state is ConnectUi.Requesting -> Row(
                    horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    CircularProgressIndicator(color = colors.accent, modifier = Modifier.size(20.dp))
                    Text("Requesting a code…", style = VortXTheme.type.body.copy(color = colors.textSecondary))
                }

                else -> {
                    (state as? ConnectUi.Error)?.let {
                        Text(it.message, style = VortXTheme.type.body.copy(color = colors.danger))
                    }
                    PrimaryButton(text = "Connect $name", onClick = onConnect, modifier = Modifier.fillMaxWidth())
                }
            }
        }
    }
}

/// The per-provider connect UI state. Kept local to this screen (the auth objects hold the real token
/// truth); mirrors the Apple settings view's connect/awaiting/connected states.
private sealed interface ConnectUi {
    data object Idle : ConnectUi
    data object Requesting : ConnectUi
    data class Awaiting(val userCode: String, val verificationUrl: String) : ConnectUi
    data object Connected : ConnectUi
    data class Error(val message: String) : ConnectUi
}
