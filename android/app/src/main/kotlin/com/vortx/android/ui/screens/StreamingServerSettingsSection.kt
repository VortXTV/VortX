package com.vortx.android.ui.screens

import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.vortx.android.engine.StreamingServerSelection
import com.vortx.android.engine.StreamingServerSelectionStore
import com.vortx.android.engine.StreamingServerTransport
import com.vortx.android.ui.components.Chip
import com.vortx.android.ui.components.PrimaryButton
import com.vortx.android.ui.theme.VortXShapes
import com.vortx.android.ui.theme.VortXTheme
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

/** A probe belongs to one exact edit/composition, even if a later edit returns to the same URL. */
internal class StreamingServerProbeOwner {
    private var token: Any? = null
    private var disposed = false

    fun begin(): Any {
        check(!disposed)
        return Any().also { token = it }
    }

    fun owns(candidate: Any): Boolean = !disposed && token === candidate
    fun invalidate() { token = null }
    fun dispose() { disposed = true; invalidate() }
}

/** Shared phone/TV control. Merely editing or testing a URL never changes the active server. */
@Composable
internal fun StreamingServerSettingsSection() {
    val appContext = LocalContext.current.applicationContext
    val store = remember(appContext) { StreamingServerSelectionStore.instance(appContext) }
    val scope = rememberCoroutineScope()
    val probeOwner = remember { StreamingServerProbeOwner() }
    var currentBase by remember(store) { mutableStateOf(store.currentBase()) }
    var entered by remember(store) { mutableStateOf(currentBase.orEmpty()) }
    var probeJob by remember { mutableStateOf<Job?>(null) }
    var probing by remember { mutableStateOf(false) }
    var status by remember { mutableStateOf<String?>(null) }

    fun invalidateProbe() {
        probeOwner.invalidate()
        probeJob?.cancel()
        probeJob = null
        probing = false
    }

    fun probe(save: Boolean) {
        invalidateProbe()
        val originalInput = entered
        val target = StreamingServerSelection.normalizedBase(originalInput)
        if (target == null) {
            status = "Enter a server address without a username, password, query or fragment."
            return
        }
        val token = probeOwner.begin()
        probing = true
        status = null
        probeJob = scope.launch {
            try {
                val reachable = StreamingServerTransport.probe(target)
                // The operation retains its original input and owner; it never adopts a newer edit.
                if (!probeOwner.owns(token) || entered != originalInput) return@launch
                status = when {
                    !reachable -> "Couldn't reach a compatible streaming server. Check its address and connection."
                    !save -> "Server responded. Choose Save & Use to make it active."
                    store.save(target) -> {
                        currentBase = store.currentBase()
                        entered = currentBase.orEmpty()
                        "Server saved for the next playback on this device."
                    }
                    else -> "Couldn't save the server. Your active server has not changed."
                }
            } catch (_: CancellationException) {
                // Editing, using the on-device server or leaving Settings cancels only this probe.
            } catch (_: Exception) {
                if (probeOwner.owns(token) && entered == originalInput) {
                    status = "Couldn't check the server. Your active server has not changed."
                }
            } finally {
                if (probeOwner.owns(token)) {
                    probeOwner.invalidate()
                    probing = false
                    probeJob = null
                }
            }
        }
    }

    DisposableEffect(probeOwner) {
        onDispose {
            probeOwner.dispose()
            probeJob?.cancel()
        }
    }

    val colors = VortXTheme.colors
    SettingsSection(
        title = "Streaming server",
        footer = "Use a compatible server on your home network or Tailscale for torrent playback. " +
            "This setting stays on this device and applies to the next playback. " +
            "A Cast receiver must also be able to reach that server; it does not use this device's VPN connection.",
    ) {
        Column(
            modifier = Modifier.padding(horizontal = VortXTheme.spacing.sm, vertical = VortXTheme.spacing.xs),
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
        ) {
            Text(
                text = if (currentBase == null) "Active: on-device server" else "Active: $currentBase",
                style = VortXTheme.type.label.copy(color = colors.textSecondary),
            )
            OutlinedTextField(
                value = entered,
                onValueChange = {
                    invalidateProbe()
                    entered = it
                    status = null
                },
                modifier = Modifier.fillMaxWidth(),
                label = { Text("Server address") },
                placeholder = { Text("http://192.168.1.20:11470") },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                singleLine = true,
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = colors.accent,
                    cursorColor = colors.accent,
                ),
            )
            PrimaryButton(
                text = "Save & Use",
                onClick = { probe(save = true) },
                modifier = Modifier.fillMaxWidth().streamingServerActionFocus(VortXShapes.control),
                loading = probing,
                enabled = entered.isNotBlank(),
            )
            FlowRow(
                horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs),
                verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs),
            ) {
                Chip(
                    label = "Test connection",
                    selected = false,
                    enabled = !probing && entered.isNotBlank(),
                    modifier = Modifier.streamingServerActionFocus(VortXShapes.chip),
                    onClick = { probe(save = false) },
                )
                Chip(
                    label = "Use on-device server",
                    selected = currentBase == null,
                    modifier = Modifier.streamingServerActionFocus(VortXShapes.chip),
                    onClick = {
                        invalidateProbe()
                        status = if (store.useEmbedded()) {
                            currentBase = store.currentBase()
                            entered = currentBase.orEmpty()
                            "On-device server selected for the next playback."
                        } else {
                            "Couldn't save the selection. Your active server has not changed."
                        }
                    },
                )
            }
            status?.let {
                Text(
                    text = it,
                    style = VortXTheme.type.label.copy(color = colors.textSecondary),
                    modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
                )
            }
        }
    }
}

/** Observe the action's existing clickable target; adding focusable() would create a second stop. */
@Composable
private fun Modifier.streamingServerActionFocus(shape: Shape): Modifier {
    var focused by remember { mutableStateOf(false) }
    val focusColor = VortXTheme.colors.accentBright
    return this
        .onFocusChanged { focused = it.isFocused }
        .then(if (focused) Modifier.border(3.dp, focusColor, shape) else Modifier)
}
