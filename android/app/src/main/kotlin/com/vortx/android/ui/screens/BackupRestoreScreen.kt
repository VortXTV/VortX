package com.vortx.android.ui.screens

import android.content.Context
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
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
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import com.vortx.android.backup.SettingsBackup
import com.vortx.android.profile.ProfileStore
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXTheme
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/// Settings > Backup: export this device's syncable settings to a file and import one back (TV-5), the
/// Android port of the Apple `SettingsBackup.makeBackup` / `restore` file transfer. This is DISTINCT from
/// the account sync: nothing here touches the `doc.settings` sync blob. It is a plain, no-account way to
/// carry your settings (profiles included) to another device or to keep an offline copy.
///
/// TWO INVARIANTS, both enforced in [SettingsBackup] and only surfaced here:
///   - Device-local keys are excluded. [SettingsBackup.makeBackup] keeps only `isSyncable` keys, so a
///     backup never carries a per-device streaming cache size, server URL, or DV toggle onto another
///     device (the same filter Apple's `makeBackup` and the sync carrier use).
///   - Restore is a SET-ONLY merge. It only `put`s the keys the file names; a key absent from the file
///     keeps its current value, so importing an older backup never wipes settings you changed since
///     (Apple `restore`'s never-wipe contract). It never `clear`s.
///
/// The roster round-trips as one of those keys (`stremiox.profiles` is a syncable String), so after a
/// restore [ProfileStore.reloadFromDefaults] re-reads it, keeping THIS device's active selection.
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BackupRestoreScreen(onBack: () -> Unit, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val appContext = context.applicationContext
    val scope = rememberCoroutineScope()
    val prefs = remember(appContext) {
        appContext.getSharedPreferences(ProfileStore.PREFS_FILE, Context.MODE_PRIVATE)
    }

    // The last outcome, shown inline (the settings surface has no snackbar; an inline line says the same
    // and, for import, keeps the result readable rather than dismissing it).
    var status by remember { mutableStateOf<String?>(null) }
    // The serialized bytes waiting for the picker to hand back a destination. Encoded BEFORE the picker
    // opens, so the "nothing to back up" case is caught first and the write cannot fail on a late read.
    var pending by remember { mutableStateOf<ByteArray?>(null) }
    var busy by remember { mutableStateOf(false) }

    val exportLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.CreateDocument("application/json"),
    ) { uri ->
        val payload = pending
        pending = null
        // A null uri is the viewer backing out of the picker: deliberately silent, they know they cancelled.
        if (uri == null || payload == null) return@rememberLauncherForActivityResult
        scope.launch {
            status = runCatching {
                withContext(Dispatchers.IO) {
                    // "wt" (truncate) so re-exporting over an older, longer file leaves no trailing bytes past
                    // the new JSON (which would make a later import fail to parse).
                    context.contentResolver.openOutputStream(uri, "wt")?.use { it.write(payload) }
                        ?: error("Could not open that location for writing.")
                }
                "Settings backed up. Import this file on another device to bring your settings and profiles across."
            }.getOrElse { "Backup failed: ${it.message ?: "the file could not be written."}" }
        }
    }

    val importLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument(),
    ) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult // cancelled, see above
        busy = true
        scope.launch {
            status = runCatching {
                val bytes = withContext(Dispatchers.IO) {
                    context.contentResolver.openInputStream(uri)?.use { it.readBytes() }
                        ?: error("Could not open that file for reading.")
                }
                val values = SettingsBackup.restoreValues(bytes)
                    ?: error("That file is not a VortX settings backup.")
                withContext(Dispatchers.IO) { applyRestore(prefs, values) }
                // The roster is one of the restored keys; re-read it while KEEPING this device's selection.
                ProfileStore.sharedOrNull()?.reloadFromDefaults()
                if (values.isEmpty()) {
                    "That backup held no restorable settings."
                } else {
                    "Settings restored from your backup. Existing settings not in the file were left as they were."
                }
            }.getOrElse { "Import failed: ${it.message ?: "the file could not be read."}" }
            busy = false
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Backup", style = VortXTheme.type.cardTitle) },
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
                title = "Settings backup",
                footer = "Backs up your syncable settings and profiles to a file, no account needed. " +
                    "Device-only settings such as the streaming cache size and server address are left out. " +
                    "Importing merges a backup in and never removes settings that are not in the file.",
            ) {
                ActionRow(
                    icon = VortXIcons.download,
                    label = "Back up settings",
                    detail = "Save your settings and profiles to a file.",
                    enabled = !busy,
                    onClick = {
                        busy = true
                        scope.launch {
                            val bytes = withContext(Dispatchers.IO) {
                                SettingsBackup.makeBackup(prefs.all, bundleId = appContext.packageName)
                            }
                            if (bytes == null) {
                                status = "Nothing to back up yet. Change a setting or add a profile first."
                                busy = false
                                return@launch
                            }
                            pending = bytes
                            status = null
                            busy = false
                            exportLauncher.launch(backupFileName())
                        }
                    },
                )
                ActionRow(
                    icon = VortXIcons.library,
                    label = "Restore from a backup",
                    detail = "Import settings from a backup file.",
                    enabled = !busy,
                    // "*/*", not "application/json": many file providers do not tag a user-saved .json as
                    // application/json, so restricting the picker to that type hides the very file we wrote.
                    // restoreValues() validates the content, which is the real gate.
                    onClick = { importLauncher.launch(arrayOf("*/*")) },
                )
            }

            status?.let { message ->
                Text(
                    message,
                    style = VortXTheme.type.label.copy(color = VortXTheme.colors.textSecondary),
                    modifier = Modifier.padding(horizontal = VortXTheme.spacing.xs),
                )
            }
        }
    }
}

/// Set-only merge into SharedPreferences, each value written back under its exact original type (the type
/// codes [SettingsBackup] recorded), so a later typed getter never hits a ClassCastException. Never clears.
private fun applyRestore(
    prefs: android.content.SharedPreferences,
    values: Map<String, SettingsBackup.BackupValue>,
) {
    val editor = prefs.edit()
    for ((key, value) in values) {
        when (value) {
            is SettingsBackup.BackupValue.Bool -> editor.putBoolean(key, value.value)
            is SettingsBackup.BackupValue.IntValue -> editor.putInt(key, value.value)
            is SettingsBackup.BackupValue.LongValue -> editor.putLong(key, value.value)
            is SettingsBackup.BackupValue.FloatValue -> editor.putFloat(key, value.value)
            is SettingsBackup.BackupValue.Str -> editor.putString(key, value.value)
            is SettingsBackup.BackupValue.StrSet -> editor.putStringSet(key, value.value)
        }
    }
    editor.apply()
}

private fun backupFileName(): String =
    "VortX-Backup-${SimpleDateFormat("yyyy-MM-dd", Locale.US).format(Date())}.json"

/// One tappable settings action: an icon, a label, and a detail line, the whole row a single button so a
/// screen reader announces one target and the disabled state is real rather than a colour that still taps.
@Composable
private fun ActionRow(
    icon: ImageVector,
    label: String,
    detail: String?,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    val colors = VortXTheme.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .padding(horizontal = VortXTheme.spacing.sm, vertical = VortXTheme.spacing.xs),
        horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, contentDescription = null, tint = if (enabled) colors.accent else colors.textTertiary)
        Column(modifier = Modifier.fillMaxWidth()) {
            Text(
                label,
                style = VortXTheme.type.body.copy(
                    color = if (enabled) colors.textPrimary else colors.textTertiary,
                    fontWeight = FontWeight.SemiBold,
                ),
            )
            if (detail != null) {
                Text(detail, style = VortXTheme.type.label.copy(color = colors.textTertiary))
            }
        }
    }
}
