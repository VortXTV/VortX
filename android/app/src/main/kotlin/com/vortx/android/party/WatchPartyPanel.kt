package com.vortx.android.party

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.DialogProperties
import androidx.compose.ui.window.SecureFlagPolicy
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.google.zxing.BarcodeFormat
import com.google.zxing.MultiFormatWriter
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** Shared touch/D-pad surface. No saved state, network request, or implicit join from opening a link. */
@Composable
internal fun WatchPartyButton(session: WatchPartyClientSession?, open: () -> Unit) {
    TextButton(onClick = open, enabled = session != null) { Text("Watch party") }
}

@Composable
internal fun WatchPartyPanel(session: WatchPartyClientSession, onDismiss: () -> Unit) {
    val state by session.state.collectAsStateWithLifecycle()
    val context = LocalContext.current
    var rawInvite by remember { mutableStateOf("") }
    var invalidInvite by remember { mutableStateOf(false) }
    var sharedLink by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(state.phase, state.canShare) {
        if (!state.canShare || state.phase != WatchPartyClientSession.UiState.Phase.CONNECTED) sharedLink = null
    }
    fun close() { sharedLink = null; rawInvite = ""; onDismiss() }
    AlertDialog(
        onDismissRequest = ::close,
        properties = DialogProperties(securePolicy = SecureFlagPolicy.SecureOn),
        title = { Text("Watch together") },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(when (state.phase) {
                    WatchPartyClientSession.UiState.Phase.IDLE -> "Choose the same title at 1× speed on each device. Everyone uses their own sources and account."
                    WatchPartyClientSession.UiState.Phase.CONNECTING -> "Connecting…"
                    WatchPartyClientSession.UiState.Phase.CONNECTED -> "${state.members} connected · ${if (state.leader) "You control playback" else "Following the host"}"
                    WatchPartyClientSession.UiState.Phase.CLOSED -> "Party ended. You can start or join another."
                    WatchPartyClientSession.UiState.Phase.FAILED -> "The party could not connect or its permission expired. Check your connection and join again."
                })
                Text("Invites include a private room key. Share them only with people you want to watch with. Leaving closes this party for everyone. Rooms last up to 20 minutes; invite links work for two minutes.")
                val busy = state.phase == WatchPartyClientSession.UiState.Phase.CONNECTING
                val connected = state.phase == WatchPartyClientSession.UiState.Phase.CONNECTED
                if (!connected) {
                    Button(onClick = { invalidInvite = false; rawInvite = ""; session.create() }, enabled = !busy) { Text("Start a party") }
                    OutlinedTextField(
                        value = rawInvite,
                        onValueChange = { if (it.toByteArray(Charsets.UTF_8).size <= 1024) { rawInvite = it; invalidInvite = false } },
                        label = { Text("Paste an invite link") },
                        visualTransformation = PasswordVisualTransformation(),
                        singleLine = true,
                        isError = invalidInvite,
                        modifier = Modifier.fillMaxWidth(),
                    )
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Button(onClick = {
                            val invite = WatchPartyInvite.parse(rawInvite)
                            if (invite == null) invalidInvite = true
                            else { rawInvite = ""; invalidInvite = false; session.join(invite) }
                        }, enabled = !busy && rawInvite.isNotEmpty()) { Text("Join") }
                    }
                    if (invalidInvite) Text("This invite is invalid or has expired. Ask the host to restart the party and share a fresh link.")
                }
                if (state.leader && connected && !state.canShare) Text("The invite window has closed. Restart the party to invite someone else.")
                if (state.canShare && connected) {
                    Button(onClick = { sharedLink = session.shareLink() }) { Text("Show invite QR") }
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        TextButton(onClick = {
                            session.shareLink()?.let { link ->
                                val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
                                clipboard?.setPrimaryClip(ClipData.newPlainText("Watch party invite", link))
                            }
                        }) { Text("Copy invite") }
                        TextButton(onClick = {
                            session.shareLink()?.let { link ->
                                val intent = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, link)
                                context.startActivity(Intent.createChooser(intent, "Share watch party"))
                            }
                        }) { Text("Share") }
                    }
                    sharedLink?.let { link ->
                        Text("Copy the complete invite from your message or QR scanner and paste it into Watch party in VortX. Automatic app links are not enabled.")
                        PartyQr(link)
                    }
                }
                if (connected || busy) TextButton(onClick = { sharedLink = null; rawInvite = ""; session.leave() }) { Text("Leave party") }
            }
        },
        confirmButton = { TextButton(onClick = ::close) { Text("Done") } },
    )
}

@Composable
private fun PartyQr(link: String) {
    val bitmap by produceState<Bitmap?>(null, link) {
        value = withContext(Dispatchers.Default) {
            runCatching {
                val matrix = MultiFormatWriter().encode(link, BarcodeFormat.QR_CODE, 256, 256,
                    mapOf(EncodeHintType.ERROR_CORRECTION to ErrorCorrectionLevel.M, EncodeHintType.MARGIN to 2))
                val pixels = IntArray(256 * 256) { offset -> if (matrix[offset % 256, offset / 256]) 0xff000000.toInt() else 0xffffffff.toInt() }
                Bitmap.createBitmap(pixels, 256, 256, Bitmap.Config.ARGB_8888)
            }.getOrNull()
        }
    }
    bitmap?.let { Image(it.asImageBitmap(), contentDescription = "Private watch party invite QR code", modifier = Modifier.size(256.dp)) }
}
