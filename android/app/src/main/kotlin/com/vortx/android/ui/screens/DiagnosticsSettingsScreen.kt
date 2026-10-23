package com.vortx.android.ui.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import com.vortx.android.diagnostics.DiagnosticsLog
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXTheme
import kotlinx.coroutines.launch

/// Settings > Diagnostics: the "Diagnostic logging" toggle (Apple's key) and "Save or share log", the Android
/// counterpart of the iPhone/iPad diagnostics rows. The shared file is a staged copy every line of which was
/// scrubbed again on the way out; the raw logs never leave the app's private cache.
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DiagnosticsSettingsScreen(onBack: () -> Unit, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var logging by remember { mutableStateOf(DiagnosticsLog.probeEnabled) }
    var status by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Diagnostics", style = VortXTheme.type.cardTitle) },
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
            SettingsSection(
                title = "Diagnostic log",
                footer = "Titles, links, keys and account details are scrubbed from every line before it is " +
                    "written and again when you share it. Turn logging on, reproduce the issue, then share the log.",
            ) {
                ToggleRow(
                    label = "Diagnostic logging",
                    detail = "Logs detailed activity for troubleshooting.",
                    checked = logging,
                    onCheckedChange = { on ->
                        logging = on
                        DiagnosticsLog.setProbeEnabled(on)
                    },
                )
                DiagnosticsActionRow(
                    label = "Save or share log",
                    detail = "Send the log to Files, mail or a chat.",
                    enabled = !busy,
                    onClick = {
                        busy = true
                        status = null
                        scope.launch {
                            try { status = shareDiagnosticLog(context).message }
                            finally { busy = false }
                        }
                    },
                )
            }
            status?.let { message ->
                Text(message, style = VortXTheme.type.label.copy(color = VortXTheme.colors.textSecondary))
            }
        }
    }
}

@Composable
private fun DiagnosticsActionRow(label: String, detail: String, enabled: Boolean, onClick: () -> Unit) {
    val colors = VortXTheme.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .padding(horizontal = VortXTheme.spacing.sm, vertical = VortXTheme.spacing.xs),
        horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(VortXIcons.download, contentDescription = null, tint = if (enabled) colors.accent else colors.textTertiary)
        Column(modifier = Modifier.fillMaxWidth()) {
            Text(
                label,
                style = VortXTheme.type.body.copy(
                    color = if (enabled) colors.textPrimary else colors.textTertiary,
                    fontWeight = FontWeight.SemiBold,
                ),
            )
            Text(detail, style = VortXTheme.type.label.copy(color = colors.textTertiary))
        }
    }
}
