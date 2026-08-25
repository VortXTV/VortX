package com.vortx.android.ui

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
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
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

/** Audit row 12 cross-cut offline surface: phone parity with the validated-capability TV signal. */
@Composable
fun OfflineChip(modifier: Modifier = Modifier) {
    val context = LocalContext.current.applicationContext
    val offline = remember(context) { offlineFlow(context) }
        .collectAsStateWithLifecycle(initialValue = false).value
    if (!offline) return

    val colors = VortXTheme.colors
    Row(
        modifier = modifier
            .clip(VortXShapes.pill)
            .background(colors.surface2)
            .padding(horizontal = VortXTheme.spacing.md, vertical = VortXTheme.spacing.sm),
        horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            imageVector = VortXIcons.wifiOff,
            contentDescription = null,
            tint = colors.textSecondary,
            modifier = Modifier.size(18.dp),
        )
        Text(
            text = "Offline - showing saved data",
            style = VortXTheme.type.label.copy(color = colors.textSecondary),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

private const val ONLINE_DEBOUNCE_MILLIS = 800L

private fun NetworkCapabilities.isValidated(): Boolean =
    hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
        hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)

@OptIn(ExperimentalCoroutinesApi::class)
private fun offlineFlow(context: Context): Flow<Boolean> {
    val raw = callbackFlow {
        val manager = context.getSystemService(ConnectivityManager::class.java)
            ?: run {
                trySend(false)
                awaitClose { }
                return@callbackFlow
            }
        val validated = HashSet<Network>()
        fun emitState() = trySend(synchronized(validated) { validated.isEmpty() })
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
                val usable = capabilities.isValidated()
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
        trySend(false) // Avoid a false offline flash before the platform reports the default network.
        val registered = runCatching { manager.registerDefaultNetworkCallback(callback) }.isSuccess
        if (registered) {
            runCatching {
                val active = manager.activeNetwork
                val capabilities = active?.let(manager::getNetworkCapabilities)
                synchronized(validated) {
                    validated.clear()
                    if (active != null && capabilities?.isValidated() == true) validated.add(active)
                }
                emitState()
            }.onFailure { trySend(false) }
        } else {
            trySend(false)
        }
        awaitClose {
            if (registered) runCatching { manager.unregisterNetworkCallback(callback) }
        }
    }
    return raw.distinctUntilChanged().transformLatest { offline ->
        if (offline) emit(true) else {
            delay(ONLINE_DEBOUNCE_MILLIS)
            emit(false)
        }
    }.distinctUntilChanged()
}
