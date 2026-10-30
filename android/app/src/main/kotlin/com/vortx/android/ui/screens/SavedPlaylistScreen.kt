package com.vortx.android.ui.screens

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.vortx.android.data.ContinueWatchingOwner
import com.vortx.android.player.queue.PlaybackQueueStore
import com.vortx.android.playlists.SavedPlaylistCatalog
import com.vortx.android.playlists.SavedPlaylistDetail
import com.vortx.android.playlists.SavedPlaylistDraftCatalog
import com.vortx.android.playlists.SavedPlaylistDraftHandle
import com.vortx.android.playlists.SavedPlaylistDraftSummary
import com.vortx.android.playlists.SavedPlaylistDraftView
import com.vortx.android.playlists.SavedPlaylistHandle
import com.vortx.android.playlists.SavedPlaylistImportResult
import com.vortx.android.playlists.SavedPlaylistStatus
import com.vortx.android.playlists.SavedPlaylistStore
import com.vortx.android.playlists.SavedPlaylistSummary
import com.vortx.android.playlists.SavedPlaylistWriteResult
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXTheme
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Owner-bound profile playlist library. Gateway-backed projections are always queried off the UI thread. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun SavedPlaylistScreen(
    store: SavedPlaylistStore,
    queue: PlaybackQueueStore,
    owner: ContinueWatchingOwner,
    ownerIsCurrent: Boolean,
    onBack: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    val ownerCurrentState by rememberUpdatedState(ownerIsCurrent)
    val changes by store.changes.collectAsStateWithLifecycle()
    val queueState by queue.state.collectAsStateWithLifecycle()
    var catalog by remember(owner, store) { mutableStateOf<SavedPlaylistCatalog?>(null) }
    var drafts by remember(owner, store) { mutableStateOf<SavedPlaylistDraftCatalog?>(null) }
    var loadError by remember(owner, store) { mutableStateOf<String?>(null) }
    var selectedHandle by remember(owner, store) { mutableStateOf<SavedPlaylistHandle?>(null) }
    var selectedDetail by remember(owner, store) { mutableStateOf<SavedPlaylistDetail?>(null) }
    var selectedDraftHandle by remember(owner, store) { mutableStateOf<SavedPlaylistDraftHandle?>(null) }
    var selectedDraft by remember(owner, store) { mutableStateOf<SavedPlaylistDraftView?>(null) }
    var draftViewGeneration by remember(owner, store) { mutableStateOf(0L) }
    var newName by remember(owner, store) { mutableStateOf("") }
    var editedName by remember(owner, store) { mutableStateOf("") }
    var deleteConfirmationTarget by remember(owner, store) { mutableStateOf<SavedPlaylistDetail.Supported?>(null) }
    var replaceConfirmationTarget by remember(owner, store) { mutableStateOf<SavedPlaylistDetail.Supported?>(null) }
    var statusMessage by remember(owner, store) { mutableStateOf<String?>(null) }

    LaunchedEffect(store, owner) { store.requestReload() }
    LaunchedEffect(store, owner, changes, selectedHandle, selectedDraftHandle) {
        val snapshot = withContext(Dispatchers.IO) {
            Triple(store.catalog(owner), store.drafts(owner), store.loadError(owner))
        }
        if (ownerCurrentState) {
            catalog = snapshot.first
            drafts = snapshot.second
            loadError = snapshot.third
        }
        val handle = selectedHandle
        selectedDetail = if (ownerCurrentState && handle != null) {
            withContext(Dispatchers.IO) { store.detail(owner, handle) }
        } else null
        val draftHandle = selectedDraftHandle
        selectedDraft = if (ownerCurrentState && draftHandle != null) {
            withContext(Dispatchers.IO) { store.draft(owner, draftHandle) }
        } else null
    }

    fun statusText(status: SavedPlaylistStatus): String = when (status) {
        SavedPlaylistStatus.CloudUnknown -> "Cloud status unknown"
        SavedPlaylistStatus.LocalPending -> "Waiting for account sync"
        is SavedPlaylistStatus.CloudSaved -> "Saved to cloud"
    }

    fun writeResultText(result: SavedPlaylistWriteResult): String = when (result) {
        is SavedPlaylistWriteResult.Accepted -> when (result.status) {
            SavedPlaylistStatus.CloudUnknown -> "Saved on this profile. Cloud acceptance is unknown."
            SavedPlaylistStatus.LocalPending -> "Saved on this profile. Waiting for account sync."
            is SavedPlaylistStatus.CloudSaved -> "Saved and accepted by account sync."
        }
        SavedPlaylistWriteResult.DraftRetained -> "The change could not be confirmed. Your edit remains in unresolved edits."
        SavedPlaylistWriteResult.Superseded -> "The profile changed before the edit completed. Reopen Saved playlists to continue."
    }

    fun commit(intent: SavedPlaylistStore.WriteIntent) {
        scope.launch {
            val result = store.commit(intent)
            if (ownerCurrentState) statusMessage = writeResultText(result)
        }
    }

    fun commitCaptured(intent: SavedPlaylistStore.WriteIntent?, failureMessage: String) {
        if (!ownerCurrentState) return
        if (intent == null) statusMessage = failureMessage else commit(intent)
    }

    fun importToQueue(handle: SavedPlaylistHandle) {
        if (!ownerCurrentState) return
        val intent = store.captureImport(owner, handle)
        if (intent == null) {
            statusMessage = "This playlist cannot be added to the current queue. Nothing changed."
            return
        }
        scope.launch {
            statusMessage = when (store.importIntoQueue(intent)) {
                SavedPlaylistImportResult.LOCAL_QUEUE_WRITE_ADMITTED -> "Added to your playback queue. Playback did not start."
                SavedPlaylistImportResult.REJECTED -> "The queue could not accept every title. Nothing was added."
                SavedPlaylistImportResult.SUPERSEDED -> "The profile or queue changed. Nothing was added."
            }
        }
    }

    fun backFromDetail() {
        draftViewGeneration = Math.incrementExact(draftViewGeneration)
        selectedHandle = null
        selectedDetail = null
        selectedDraftHandle = null
        selectedDraft = null
    }

    BackHandler(enabled = true) {
        when {
            deleteConfirmationTarget != null -> deleteConfirmationTarget = null
            replaceConfirmationTarget != null -> replaceConfirmationTarget = null
            selectedHandle != null || selectedDraftHandle != null -> backFromDetail()
            else -> onBack()
        }
    }

    Scaffold(
        modifier = Modifier.fillMaxSize(),
        topBar = {
            TopAppBar(
                title = {
                    Text(when {
                        !ownerIsCurrent -> "Saved playlists"
                        selectedDetail is SavedPlaylistDetail.Supported -> (selectedDetail as SavedPlaylistDetail.Supported).name
                        selectedDetail is SavedPlaylistDetail.ReadOnlyFuture -> "Newer playlist"
                        selectedDraft != null -> selectedDraft?.name ?: "Unresolved edit"
                        else -> "Saved playlists"
                    })
                },
                navigationIcon = {
                    IconButton(onClick = {
                        if (selectedHandle != null || selectedDraftHandle != null) backFromDetail() else onBack()
                    }) { Icon(VortXIcons.back, contentDescription = "Back") }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = Color.Transparent),
            )
        },
        bottomBar = {
            if (ownerIsCurrent) {
                statusMessage?.let { message ->
                    Column(
                        modifier = Modifier.fillMaxWidth().padding(
                            horizontal = VortXTheme.spacing.edge, vertical = VortXTheme.spacing.sm,
                        ),
                        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs),
                    ) {
                        Text(message, color = VortXTheme.colors.textSecondary,
                            modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite })
                        TextButton(onClick = { statusMessage = null }) { Text("Dismiss message") }
                    }
                }
            }
        },
    ) { padding ->
        if (!ownerIsCurrent) {
            Column(Modifier.fillMaxSize().padding(padding).padding(VortXTheme.spacing.edge)) {
                Text("This profile is no longer active. Its playlists are hidden until you open them again.")
            }
            return@Scaffold
        }

        val detail = selectedDetail
        val draft = selectedDraft
        when {
            detail is SavedPlaylistDetail.Supported -> SupportedPlaylistDetail(
                detail = detail,
                scaffoldPadding = padding,
                editedName = editedName,
                onNameChange = { editedName = it },
                statusText = ::statusText,
                onRename = { commitCaptured(store.captureRename(owner, detail.handle, editedName), "Enter a valid playlist name. Nothing changed.") },
                onReplace = { replaceConfirmationTarget = detail },
                onDelete = { deleteConfirmationTarget = detail },
                onImport = { importToQueue(detail.handle) },
                queueReady = queueState.ready && queueState.owner == owner,
            )
            detail is SavedPlaylistDetail.ReadOnlyFuture -> Column(
                Modifier.fillMaxSize().padding(padding).padding(VortXTheme.spacing.edge),
                verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
            ) {
                Text("This playlist was saved by a newer version. It is preserved and cannot be edited here.")
                Text(statusText(detail.status), color = VortXTheme.colors.textSecondary)
            }
            draft != null -> DraftDetail(
                draft = draft,
                scaffoldPadding = padding,
                onReload = {
                    store.requestReload()
                    statusMessage = "Saved playlists reloaded. Your unresolved edit was kept."
                },
                onSaveCopy = {
                    val copyHandle = draft.copyHandle
                    commitCaptured(copyHandle?.let { store.captureDraftAsCopy(owner, it) },
                        "This edit cannot be copied in the current profile.")
                },
                onDiscard = {
                    val capturedOwner = owner
                    val capturedHandle = draft.handle
                    val capturedViewGeneration = draftViewGeneration
                    scope.launch {
                        val discarded = withContext(Dispatchers.IO) {
                            store.discardDraft(capturedOwner, capturedHandle)
                        }
                        if (ownerCurrentState && owner == capturedOwner && selectedDraftHandle == capturedHandle &&
                            draftViewGeneration == capturedViewGeneration
                        ) {
                            if (discarded) {
                                selectedDraftHandle = null
                                selectedDraft = null
                                statusMessage = "The unresolved edit was discarded. Saved playlist data was not changed."
                            } else {
                                statusMessage = "This edit could not be discarded while it is being saved or its original profile is unavailable."
                            }
                        }
                    }
                },
            )
            selectedHandle != null || selectedDraftHandle != null -> Column(
                Modifier.fillMaxSize().padding(padding).padding(VortXTheme.spacing.edge),
                verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
            ) {
                Text("This item is no longer available for the selected profile.")
            }
            catalog != null -> {
                val renderedCatalog = requireNotNull(catalog)
                PlaylistLibrary(
                catalog = renderedCatalog,
                drafts = drafts,
                scaffoldPadding = padding,
                newName = newName,
                onNameChange = { newName = it },
                queueReady = queueState.ready && queueState.owner == owner,
                queueCount = queueState.entries.size.takeIf { queueState.owner == owner },
                loadError = loadError,
                statusText = ::statusText,
                onRefresh = { store.requestReload() },
                onSaveQueue = {
                    if (ownerCurrentState) {
                        commitCaptured(store.captureCreateFromQueue(owner, renderedCatalog.creationHandle, newName),
                            "The queue could not be saved as a playlist. Nothing changed.")
                    }
                },
                onOpen = { summary ->
                    draftViewGeneration = Math.incrementExact(draftViewGeneration)
                    selectedHandle = summary.handle
                    editedName = summary.name
                    selectedDetail = null
                    statusMessage = null
                },
                onOpenDraft = { summary ->
                    draftViewGeneration = Math.incrementExact(draftViewGeneration)
                    selectedDraftHandle = summary.handle
                    selectedDraft = null
                    statusMessage = null
                },
                )
            }
            loadError != null -> Column(
                Modifier.fillMaxSize().padding(padding).padding(VortXTheme.spacing.edge),
                verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
            ) {
                Text(loadError ?: "Saved playlists are unavailable.")
                Button(onClick = { store.requestReload() }) { Text("Try again") }
            }
            else -> Column(
                Modifier.fillMaxSize().padding(padding).padding(VortXTheme.spacing.edge),
                verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
            ) {
                CircularProgressIndicator()
                Text("Loading saved playlists…")
            }
        }
    }

    deleteConfirmationTarget?.let { target ->
        AlertDialog(
            onDismissRequest = { deleteConfirmationTarget = null },
            title = { Text("Delete playlist?") },
            text = { Text("This removes the playlist from the selected profile when the change is accepted. Your queue and playback will not change.") },
            confirmButton = {
                TextButton(onClick = {
                    deleteConfirmationTarget = null
                    commitCaptured(store.captureDelete(owner, target.handle), "The playlist could not be deleted. Nothing changed.")
                }) { Text("Delete") }
            },
            dismissButton = { TextButton(onClick = { deleteConfirmationTarget = null }) { Text("Cancel") } },
        )
    }
    replaceConfirmationTarget?.let { target ->
        AlertDialog(
            onDismissRequest = { replaceConfirmationTarget = null },
            title = { Text("Replace playlist from queue?") },
            text = { Text("The current queue will replace this playlist’s titles after the change is accepted. Playback will not start.") },
            confirmButton = {
                TextButton(onClick = {
                    replaceConfirmationTarget = null
                    commitCaptured(store.captureReplaceFromQueue(owner, target.handle), "The queue could not replace this playlist. Nothing changed.")
                }) { Text("Replace") }
            },
            dismissButton = { TextButton(onClick = { replaceConfirmationTarget = null }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun PlaylistLibrary(
    catalog: SavedPlaylistCatalog,
    drafts: SavedPlaylistDraftCatalog?,
    scaffoldPadding: PaddingValues,
    newName: String,
    onNameChange: (String) -> Unit,
    queueReady: Boolean,
    queueCount: Int?,
    loadError: String?,
    statusText: (SavedPlaylistStatus) -> String,
    onRefresh: () -> Unit,
    onSaveQueue: () -> Unit,
    onOpen: (SavedPlaylistSummary) -> Unit,
    onOpenDraft: (SavedPlaylistDraftSummary) -> Unit,
) {
    LazyColumn(
        modifier = Modifier.fillMaxSize().padding(scaffoldPadding),
        contentPadding = PaddingValues(horizontal = VortXTheme.spacing.edge, vertical = VortXTheme.spacing.sm),
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
    ) {
        item {
            Column(verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
                Text("Playlists are saved for this profile. They contain catalog titles only.")
                OutlinedTextField(value = newName, onValueChange = onNameChange,
                    label = { Text("Playlist name") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                Button(onClick = onSaveQueue, enabled = queueReady && !newName.isBlank()) {
                    Text(if (queueCount == null) "Save current queue" else "Save current queue ($queueCount titles)")
                }
                Column(verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs)) {
                    TextButton(onClick = onRefresh) { Text("Refresh") }
                    if (loadError != null) Text(loadError, color = VortXTheme.colors.textSecondary)
                }
            }
        }
        if (catalog.playlists.isEmpty()) item { Text("No saved playlists yet.", color = VortXTheme.colors.textSecondary) }
        items(catalog.playlists, key = { it.handle.field }) { summary ->
            Column(
                modifier = Modifier.fillMaxWidth().clickable(role = Role.Button, onClickLabel = "Open saved playlist") { onOpen(summary) }.padding(vertical = VortXTheme.spacing.sm),
                verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs),
            ) {
                Text(summary.name, style = VortXTheme.type.cardTitle)
                Text(summary.entryCount?.let { "$it titles · ${statusText(summary.status)}" }
                    ?: "Preserved read-only · ${statusText(summary.status)}", color = VortXTheme.colors.textSecondary)
            }
        }
        drafts?.drafts?.takeIf { it.isNotEmpty() }?.let { rows ->
            item { Text("Unresolved edits", style = VortXTheme.type.sectionTitle, modifier = Modifier.semantics { heading() }) }
            items(rows, key = { "draft:${it.handle.editID}" }) { draft ->
                Column(
                    modifier = Modifier.fillMaxWidth().clickable(role = Role.Button, onClickLabel = "Open unresolved edit") { onOpenDraft(draft) }.padding(vertical = VortXTheme.spacing.sm),
                    verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs),
                ) {
                    Text(draft.name, style = VortXTheme.type.cardTitle)
                    Text(if (draft.stale) "Kept from an earlier profile session · review or discard" else "Not yet confirmed",
                        color = VortXTheme.colors.textSecondary)
                }
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun SupportedPlaylistDetail(
    detail: SavedPlaylistDetail.Supported,
    scaffoldPadding: PaddingValues,
    editedName: String,
    onNameChange: (String) -> Unit,
    statusText: (SavedPlaylistStatus) -> String,
    onRename: () -> Unit,
    onReplace: () -> Unit,
    onDelete: () -> Unit,
    onImport: () -> Unit,
    queueReady: Boolean,
) {
    LazyColumn(
        modifier = Modifier.fillMaxSize().padding(scaffoldPadding),
        contentPadding = PaddingValues(horizontal = VortXTheme.spacing.edge, vertical = VortXTheme.spacing.sm),
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
    ) {
        item {
            Column(verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
                Text("${detail.entries.size} titles · ${statusText(detail.status)}", color = VortXTheme.colors.textSecondary)
                OutlinedTextField(value = editedName, onValueChange = onNameChange,
                    label = { Text("Playlist name") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                FlowRow(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
                    verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs),
                ) {
                    Button(onClick = onRename, enabled = editedName.isNotBlank() && editedName != detail.name) { Text("Save name") }
                    TextButton(onClick = onReplace) { Text("Replace from queue") }
                    TextButton(onClick = onDelete) { Text("Delete") }
                }
                Button(onClick = onImport, enabled = queueReady) { Text("Add all to queue") }
                Text("Adding titles changes the queue only. It does not start playback.", color = VortXTheme.colors.textSecondary)
            }
        }
        items(detail.entries, key = { it.entryID }) { entry ->
            Column(verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs)) {
                Text(entry.title, style = VortXTheme.type.body)
                entry.episodeLabel?.let { Text(it, color = VortXTheme.colors.textSecondary) }
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun DraftDetail(
    draft: SavedPlaylistDraftView,
    scaffoldPadding: PaddingValues,
    onReload: () -> Unit,
    onSaveCopy: () -> Unit,
    onDiscard: () -> Unit,
) {
    LazyColumn(
        modifier = Modifier.fillMaxSize().padding(scaffoldPadding),
        contentPadding = PaddingValues(horizontal = VortXTheme.spacing.edge, vertical = VortXTheme.spacing.sm),
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
    ) {
        item {
            Column(verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm)) {
                Text(if (draft.stale) "This edit is retained from an earlier session." else "This edit has not been confirmed.")
                Text("Reload checks the saved version and keeps your edit. Save as copy creates a separate playlist.",
                    color = VortXTheme.colors.textSecondary)
                FlowRow(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
                    verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs),
                ) {
                    TextButton(onClick = onReload) { Text("Reload saved playlists") }
                    if (!draft.deleting) TextButton(onClick = onSaveCopy) { Text("Save as copy") }
                    TextButton(onClick = onDiscard) { Text("Discard edit") }
                }
            }
        }
        items(draft.entries, key = { it.entryID }) { entry ->
            Column(verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs)) {
                Text(entry.title)
                entry.episodeLabel?.let { Text(it, color = VortXTheme.colors.textSecondary) }
            }
        }
    }
}
