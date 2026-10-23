package com.vortx.android.ui.screens

import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Context
import android.content.Intent
import androidx.compose.foundation.layout.Column
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.core.content.FileProvider
import com.vortx.android.diagnostics.DiagnosticsLog
import com.vortx.android.diagnostics.DiagnosticShareOutcome
import com.vortx.android.diagnostics.performDiagnosticShare
import com.vortx.android.ui.theme.VortXTheme
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Export remains independent of account/native readiness and works with detailed logging disabled. */
@Composable
internal fun DiagnosticLogAction(modifier: Modifier = Modifier, mayShare: () -> Boolean = { true }) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val currentMayShare by rememberUpdatedState(mayShare)
    var busy by remember { mutableStateOf(false) }
    var status by remember { mutableStateOf<String?>(null) }
    Column(modifier) {
        TextButton(enabled = !busy, onClick = {
            val admission = currentMayShare
            busy = true
            status = null
            scope.launch {
                try { status = shareDiagnosticLog(context, admission).message }
                finally { busy = false }
            }
        }) {
            Text(if (busy) "Preparing diagnostic log…" else "Save or share diagnostic log")
        }
        status?.let {
            Text(it, style = VortXTheme.type.label.copy(color = VortXTheme.colors.textSecondary),
                modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite })
        }
    }
}

internal suspend fun shareDiagnosticLog(context: Context, mayShare: () -> Boolean = { true }): DiagnosticShareOutcome = performDiagnosticShare(
    // Always include the device header, always-on startup breadcrumbs and pending crashes. Requiring the
    // optional probe log first would make this action unusable for a failed first sign-in.
    stage = { withContext(Dispatchers.IO) { DiagnosticsLog.stageExport(context) } },
    mayShare = mayShare,
    present = { file ->
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
        val send = Intent(Intent.ACTION_SEND)
            .setType("text/plain")
            .putExtra(Intent.EXTRA_STREAM, uri)
            .putExtra(Intent.EXTRA_SUBJECT, "VortX diagnostic log")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        send.clipData = ClipData.newRawUri("VortX diagnostic log", uri)
        try {
            context.startActivity(Intent.createChooser(send, "Share diagnostic log")
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            true
        } catch (_: ActivityNotFoundException) { false }
    },
)
