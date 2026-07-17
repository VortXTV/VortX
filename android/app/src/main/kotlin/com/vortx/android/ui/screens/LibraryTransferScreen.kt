package com.vortx.android.ui.screens

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
import com.vortx.android.data.CatalogRepository
import com.vortx.android.library.LibraryTransfer
import com.vortx.android.model.LibraryPortability
import com.vortx.android.profile.ProfileStore
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXTheme
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/// Settings > Library: export the active profile's saved titles + watch progress to a file, and import one
/// back. The Android port of the Apple settings library-transfer controls (`iOSSettingsView.swift:222-256`,
/// the `.fileExporter`/`.fileImporter` pair, and `:1437-1452` `exportActiveLibrary`).
///
/// WHY THIS SCREEN EXISTS: [LibraryPortability] (the wire format) and [LibraryTransfer] (the read/write half
/// over the engine + overlay) were both finished, reviewed and compiling with ZERO callers. The engine could
/// already produce portable items and merge them back; nothing in `ui/` could reach either, so the whole
/// feature was dead. This file is the missing piece and only that piece: the file picker that binds them. No
/// transfer logic lives here.
///
/// ORDERING, mirroring Apple exactly: Export SERIALIZES FIRST and only then presents the picker, so an empty
/// library reports "nothing to export" instead of writing an empty file that would look like a valid backup
/// and silently restore nothing later. Cancelling the picker is not a failure and says nothing.
///
/// PER-PROFILE INVARIANT: not re-derived here. [LibraryTransfer] owns the engine-vs-overlay routing on both
/// sides, and this screen only reports what it returns, including the one branch it cannot do yet (importing
/// into a guest profile), which is surfaced as its own message rather than folded into the generic skipped
/// copy, whose stated reason ("only standard catalog titles…") would be untrue for it.
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LibraryTransferScreen(
    repo: CatalogRepository,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val appContext = context.applicationContext
    val scope = rememberCoroutineScope()
    // Read once per composition rather than held: ProfileStore is a process singleton and Android surfaces no
    // profile picker yet, so the active profile cannot change while this screen is open.
    val profiles = ProfileStore.sharedOrNull()

    // The last outcome, shown inline. Apple raises an alert; this codebase has no alert/snackbar helper in
    // settings, and an inline line is the smaller surface that says the same thing, with one advantage: the
    // import result (how many titles landed, how many did not) stays readable instead of being dismissed.
    var status by remember { mutableStateOf<String?>(null) }
    // Serialized payload waiting for the picker to hand back a destination. This is Apple's `libraryDocument`
    // @State, for the same reason: the file is encoded BEFORE the picker opens, so the empty-library case is
    // caught first and the write itself cannot fail on a missing library read.
    var pending by remember { mutableStateOf<String?>(null) }
    // Guards both actions while an export read or an import merge is in flight, so a double tap cannot start
    // a second engine read or run the same import twice.
    var busy by remember { mutableStateOf(false) }

    val exportLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.CreateDocument("application/json"),
    ) { uri ->
        val payload = pending
        pending = null
        // A null uri is the viewer backing out of the picker. Deliberately silent: they know they cancelled,
        // and Apple's exporter reports nothing on cancellation either.
        if (uri == null || payload == null) return@rememberLauncherForActivityResult
        scope.launch {
            status = runCatching {
                withContext(Dispatchers.IO) {
                    // "wt" (truncate), not the default "w": overwriting an EXISTING longer export with "w"
                    // leaves the old file's trailing bytes past the new content on many providers, which
                    // yields trailing garbage after the JSON and an import that fails to parse. The truncate
                    // mode is what makes re-exporting over yesterday's file safe.
                    context.contentResolver.openOutputStream(uri, "wt")?.use { out ->
                        out.write(payload.toByteArray(Charsets.UTF_8))
                    } ?: error("Could not open that location for writing.")
                }
                "Library exported. Import it on another device or profile to bring these titles across."
            }.getOrElse { "Export failed: ${it.message ?: "the file could not be written."}" }
        }
    }

    val importLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument(),
    ) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult   // cancelled, see above
        busy = true
        scope.launch {
            status = runCatching {
                val text = withContext(Dispatchers.IO) {
                    context.contentResolver.openInputStream(uri)?.bufferedReader(Charsets.UTF_8)
                        ?.use { it.readText() } ?: error("Could not open that file for reading.")
                }
                // decode() throws NotALibraryException on anything that is not a VortX export, which is the
                // real gate on the file's content (see the mime note at the launch site below).
                val items = LibraryPortability.decode(text)
                val target = profiles?.active?.name ?: "this profile"
                importMessage(LibraryTransfer.importLibraryItems(repo, profiles, items), target)
            }.getOrElse { error ->
                // NotALibraryException already carries the viewer-facing sentence; anything else is an IO
                // failure whose message is not, hence the fallback.
                "Import failed: ${error.message ?: "the file could not be read."}"
            }
            busy = false
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Library", style = VortXTheme.type.cardTitle) },
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
            SettingsSection(
                title = "Transfer",
                footer = "Export carries this profile's saved titles and watch progress to a file, no " +
                    "account needed. Import merges a file like that back in. Your account library is not " +
                    "changed by exporting.",
            ) {
                ActionRow(
                    label = "Export library",
                    detail = "Save this profile's titles and progress to a file.",
                    enabled = !busy,
                    onClick = {
                        busy = true
                        scope.launch {
                            // Serialize first, exactly as Apple's `exportActiveLibrary` does, so an empty
                            // library never reaches the picker.
                            val items = LibraryTransfer.exportActiveLibraryItems(repo, profiles)
                            if (items.isEmpty()) {
                                status = "Nothing to export. This profile has no saved titles or watch " +
                                    "history yet."
                                busy = false
                                return@launch
                            }
                            // Apple's two fallbacks differ ("Profile" in the envelope, "Library" in the
                            // filename) and are mirrored rather than unified: the envelope value is data a
                            // future importer may key on, so it must match the Apple file byte for byte.
                            status = runCatching {
                                pending = LibraryPortability.encode(
                                    items = items,
                                    profile = profiles?.active?.name ?: "Profile",
                                )
                                null
                            }.getOrElse { "Export failed: ${it.message ?: "the library could not be read."}" }
                            busy = false
                            if (pending != null) {
                                // defaultFilename documents that the caller appends the extension.
                                val base = LibraryPortability.defaultFilename(
                                    profile = profiles?.active?.name ?: "Library",
                                )
                                exportLauncher.launch("$base.json")
                            }
                        }
                    },
                )
                ActionRow(
                    label = "Import library",
                    detail = "Merge a library file from another device or profile.",
                    enabled = !busy,
                    onClick = {
                        status = null
                        // Not filtered to application/json alone. An export that has been round-tripped
                        // through Drive, a messenger or Downloads commonly comes back typed
                        // application/octet-stream or text/plain, and a strict json-only filter greys out
                        // the very file this screen just wrote. The content check is the real gate here:
                        // LibraryPortability.decode rejects anything without the VortX format tag, so a
                        // broader picker filter costs nothing and a narrower one loses real files.
                        importLauncher.launch(
                            arrayOf("application/json", "application/octet-stream", "text/plain"),
                        )
                    },
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

/// One tappable settings action (a button, not a choice). [SettingsControls] deliberately carries no such
/// row: its rows are radio / toggle / picker / stepper, all of which state a VALUE, and none of those is
/// honest for "do this now". Kept private here rather than added to the shared file because these two
/// buttons are its only caller today.
@Composable
private fun ActionRow(
    label: String,
    detail: String?,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    val colors = VortXTheme.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            // The whole row is one button (role + enabled on the row itself), so a screen reader announces
            // one target and the disabled state is real rather than a colour that still accepts taps.
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .padding(horizontal = VortXTheme.spacing.sm, vertical = VortXTheme.spacing.xs),
        horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            VortXIcons.library,
            contentDescription = null,   // the label beside it already names the action
            tint = if (enabled) colors.accent else colors.textTertiary,
        )
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

/// The import outcome as one viewer-facing sentence. Mirrors the Apple message at `iOSSettingsView.swift:
/// 243-250`, including its singular/plural switch, plus the overlay branch Apple has no equivalent of.
private fun importMessage(result: LibraryTransfer.ImportResult, target: String): String {
    // Reported on its own terms: applied is 0 and skipped is everything, so the generic copy below would
    // blame the file's ids, which is not why they were skipped.
    if (result.overlayUnsupported) {
        return "Importing into a guest profile is not supported yet. Switch to the main profile to import."
    }
    val added = if (result.applied == 1) "1 title" else "${result.applied} titles"
    var message = "$added added to $target."
    if (result.skipped > 0) {
        val skipped = if (result.skipped == 1) "1 title was" else "${result.skipped} titles were"
        message += " $skipped skipped: only standard catalog titles can be added to the account library."
    }
    return message
}
