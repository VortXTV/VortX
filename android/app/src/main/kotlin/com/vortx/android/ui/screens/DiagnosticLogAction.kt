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
import com.vortx.android.ui.tv.TvProfileButton
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Export remains independent of account/native readiness and works with detailed logging disabled. */
@Composable
internal fun DiagnosticLogAction(
    modifier: Modifier = Modifier,
    isTv: Boolean = false,
    recoveryOnly: Boolean = false,
    mayShare: () -> Boolean = { true },
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val currentMayShare by rememberUpdatedState(mayShare)
    var busy by remember { mutableStateOf(false) }
    var status by remember { mutableStateOf<String?>(null) }
    Column(modifier) {
        val label = when {
            busy -> "Preparing diagnostic log…"
            recoveryOnly -> "Share account recovery diagnostics"
            else -> "Save or share diagnostic log"
        }
        val share: () -> Unit = {
            val admission = currentMayShare
            busy = true
            status = null
            scope.launch {
                try {
                    status = if (recoveryOnly) shareAccountRecoveryDiagnostics(context, admission).message
                    else shareDiagnosticLog(context, admission).message
                }
                finally { busy = false }
            }
        }
        if (isTv) TvProfileButton(label, enabled = !busy, onClick = share)
        else TextButton(enabled = !busy, onClick = share) { Text(label) }
        status?.let {
            Text(it, style = VortXTheme.type.label.copy(color = VortXTheme.colors.textSecondary),
                modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite })
        }
    }
}

internal suspend fun shareDiagnosticLog(context: Context, mayShare: () -> Boolean = { true }): DiagnosticShareOutcome =
    shareDiagnosticExport(context, mayShare) { DiagnosticsLog.stageExport(context) }

internal suspend fun shareAccountRecoveryDiagnostics(context: Context, mayShare: () -> Boolean): DiagnosticShareOutcome =
    shareDiagnosticExport(context, mayShare) { DiagnosticsLog.stageAccountRecoveryExport(context) }

private suspend fun shareDiagnosticExport(
    context: Context,
    mayShare: () -> Boolean,
    stageFile: () -> java.io.File,
): DiagnosticShareOutcome = performDiagnosticShare(
    stage = { withContext(Dispatchers.IO) { stageFile() } },
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
