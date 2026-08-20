package com.vortx.android.ui.tv

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.vortx.android.R
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXShapes
import com.vortx.android.ui.theme.VortXTheme
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.transformLatest

/// Process-wide connectivity signal for the 10-foot shell, the Android analogue of Apple
/// `SourcesShared/ConnectivityMonitor.swift`. It answers the ONE question the couch shell asks: does the
/// device currently have no usable (validated) internet path, so the quiet "You're offline" chip should show?
///
/// Semantics mirror Apple's live `isOffline`: the OFFLINE verdict applies immediately (the first "no path"
/// shows the chip at once), while the return to ONLINE is debounced (a brief Wi-Fi blip or a route handover
/// must not flicker the chip in and out). Everything under the chip keeps working; the chip only points at
/// what still plays (Downloads).
///
/// Wired through [ConnectivityManager.registerDefaultNetworkCallback]: a network counts as usable only when it
/// carries both INTERNET and VALIDATED capabilities, so a captive-portal / no-egress link reads as offline the
/// same way the OS itself treats it. The `ACCESS_NETWORK_STATE` permission the manifest already declares is the
/// only one this needs.

/// Live "no usable internet path" signal for Compose. False (online) is the seed so a launch never flashes the
/// chip before the first callback lands; the offline verdict shows immediately, the online return is debounced.
@Composable
fun rememberTvOffline(): Boolean {
    val context = LocalContext.current.applicationContext
    val flow = remember(context) { connectivityOfflineFlow(context) }
    return flow.collectAsStateWithLifecycle(initialValue = false).value
}

/// The quiet, persistent "You're offline" chip pinned to the bottom of the shell while the device has no
/// validated internet path, the couch analogue of Apple `RootTabView.offlineBanner`. A subdued surface capsule
/// (not an alert) that says the app knows and points at what still plays (Downloads). The caller renders it only
/// while offline and marks the surface non-focusable, so the D-pad never lands on it and the remote keeps
/// driving the content beneath.
@Composable
fun TvOfflineChip(modifier: Modifier = Modifier) {
    val colors = VortXTheme.colors
    Row(
        modifier = modifier
            .clip(VortXShapes.pill)
            .background(colors.surface2)
            .padding(horizontal = VortXTheme.spacing.lg, vertical = VortXTheme.spacing.sm),
        horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            imageVector = VortXIcons.wifiOff,
            contentDescription = null,
            tint = colors.textSecondary,
            modifier = Modifier.size(22.dp),
        )
        Text(
            text = stringResource(R.string.tv_offline_chip),
            style = VortXTheme.type.label.copy(color = colors.textSecondary),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

/// How long a return to online must hold before the chip clears, so a momentary reassociation does not flash
/// it. Mirrors the spirit of Apple's debounced offline-to-online transition.
private const val ONLINE_DEBOUNCE_MILLIS = 1_200L

/// A cold [Flow] of the offline verdict (true == no validated internet path). Registers a default-network
/// callback for the flow's lifetime and unregisters it on cancellation. The offline edge is emitted at once;
/// the online edge is delayed by [ONLINE_DEBOUNCE_MILLIS] and cancelled if connectivity drops again first, so a
/// flap never surfaces the interim "online".
@OptIn(ExperimentalCoroutinesApi::class)
private fun connectivityOfflineFlow(context: Context): Flow<Boolean> {
    val raw = callbackFlow {
        // getSystemService(Class) is a platform type; bind a non-null local via elvis so the reference resolves
        // inside the awaitClose closure below (a lambda-captured smart cast would not survive there).
        val manager: ConnectivityManager = context.getSystemService(ConnectivityManager::class.java)
            ?: run {
                trySend(false)
                awaitClose { }
                return@callbackFlow
            }
        val validated = HashSet<Network>()
        fun emitState() {
            trySend(synchronized(validated) { validated.isEmpty() })
        }
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
                val usable = capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                    capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
                synchronized(validated) { if (usable) validated.add(network) else validated.remove(network) }
                emitState()
            }

            override fun onLost(network: Network) {
                synchronized(validated) { validated.remove(network) }
                emitState()
            }

            override fun onUnavailable() {
                trySend(true)
            }
        }
        // Seed online so a launch never flashes the chip; the first callback corrects within a frame.
        trySend(false)
        val registered = runCatching { manager.registerDefaultNetworkCallback(callback) }.isSuccess
        if (!registered) trySend(false)
        awaitClose {
            if (registered) runCatching { manager.unregisterNetworkCallback(callback) }
        }
    }
    return raw
        .distinctUntilChanged()
        .transformLatest { offline ->
            if (offline) {
                emit(true)
            } else {
                delay(ONLINE_DEBOUNCE_MILLIS)
                emit(false)
            }
        }
        .distinctUntilChanged()
}
