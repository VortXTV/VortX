package com.vortx.android.ui.screens

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.ContextWrapper
import android.net.Uri
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.result.ActivityResultRegistry
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.focusRestorer
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelStore
import androidx.lifecycle.ViewModelStoreOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.tv.material3.Border
import androidx.tv.material3.ClickableSurfaceDefaults
import androidx.tv.material3.ExperimentalTvMaterial3Api
import com.vortx.android.R
import com.vortx.android.engine.NativeXperienceCatalogGateway.SourceStatus
import com.vortx.android.model.MetaItem
import com.vortx.android.ui.theme.VortXShapes
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.viewmodel.XperienceCollectionsViewModel
import com.vortx.android.ui.viewmodel.XperienceCollectionsViewModel.Browser
import com.vortx.android.ui.viewmodel.XperienceCollectionsViewModel.Failure
import com.vortx.android.ui.viewmodel.XperienceCollectionsViewModel.Phase
import com.vortx.android.ui.viewmodel.XperienceCollectionsViewModel.Preview
import com.vortx.android.xperience.XperienceCollections
import com.vortx.android.xperience.XperienceImportStore
import java.util.Locale

/** One retained entry store, following the existing ViewModelStore ownership convention. Rotation retains
 * this holder; explicit exit/reload clears the exact old store. No old controller is rebound to a new entry. */
internal class XperienceEntryOwner : ViewModel() {
    private class Entry(val id: String) : ViewModelStoreOwner {
        override val viewModelStore = ViewModelStore()
    }
    private var current: Entry? = null
    fun owner(id: String): ViewModelStoreOwner {
        current?.takeIf { it.id == id }?.let { return it }
        current?.viewModelStore?.clear()
        return Entry(id).also { current = it }
    }
    fun release(id: String) {
        val old = current?.takeIf { it.id == id } ?: return
        current = null
        old.viewModelStore.clear()
    }
    override fun onCleared() { current?.viewModelStore?.clear(); current = null }
}

/** Compose this host for the entire explicit entry, including while phone Detail temporarily covers it.
 * Saved state stores only entry/opened flags and scroll positions. Original authority stays in the VM. */
@Composable
internal fun XperienceCollectionsEntry(
    entryId: String,
    factory: ViewModelProvider.Factory,
    visible: Boolean,
    tv: Boolean,
    dialog: Boolean = false,
    onBack: () -> Unit,
    onReload: () -> Unit,
    onItem: (MetaItem) -> Unit,
    modifier: Modifier = Modifier,
) {
    val activity = LocalContext.current.activity() as? ComponentActivity
    if (activity == null) {
        Column(modifier.fillMaxSize().padding(16.dp)) {
            XperienceMessage(stringResource(R.string.xperience_unavailable))
            XperienceAction(stringResource(R.string.xperience_back), tv, onClick = onBack)
        }
        return
    }
    // Explicit Activity owner: a surrounding profile/detail CompositionLocal can never narrow this
    // holder's retention or lend it a different store. No SavedState handle carries command authority.
    val holder: XperienceEntryOwner = viewModel(viewModelStoreOwner = activity,
        key = "xperience-entry-owner", factory = ViewModelProvider.NewInstanceFactory())
    val owner = remember(holder, entryId) { holder.owner(entryId) }
    val controller: XperienceCollectionsViewModel = viewModel(
        viewModelStoreOwner = owner, key = "xperience:$entryId", factory = factory,
    )
    val originalRoute = remember(controller) { controller.route }
    val closeOriginal = { controller.stop(originalRoute); holder.release(entryId); onBack() }
    val reloadOriginal = { controller.stop(originalRoute); holder.release(entryId); onReload() }
    var opened by rememberSaveable(entryId) { mutableStateOf(false) }
    DisposableEffect(controller, originalRoute) {
        // Main-lane synchronous stage, before any UI-created coroutine or chooser suspension.
        if (!opened) { opened = true; controller.open(originalRoute) }
        onDispose {
            if (!activity.isChangingConfigurations) {
                controller.stop(originalRoute)
                holder.release(entryId)
            }
        }
    }
    val savedUi = rememberSaveableStateHolder()
    if (visible) savedUi.SaveableStateProvider(entryId) {
        if (dialog) androidx.compose.ui.window.Dialog(onDismissRequest = closeOriginal,
            properties = androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false)) {
            XperienceCollectionsScreen(controller, originalRoute, activity, tv, closeOriginal, reloadOriginal, onItem, modifier)
        } else XperienceCollectionsScreen(controller, originalRoute, activity, tv, closeOriginal, reloadOriginal, onItem, modifier)
    }
}

private fun Context.activity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.activity()
    else -> null
}

@Composable
private fun XperienceCollectionsScreen(
    viewModel: XperienceCollectionsViewModel,
    originalRoute: XperienceCollectionsViewModel.Route,
    activity: ComponentActivity,
    tv: Boolean,
    onBack: () -> Unit,
    onReload: () -> Unit,
    onItem: (MetaItem) -> Unit,
    modifier: Modifier,
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    var pasteVisible by remember { mutableStateOf(false) }
    var pasteTarget by remember { mutableStateOf<Preview?>(null) }
    val originalPasteTarget = pasteTarget
    // The retained controller alone owns this original ticket. No saveable/parcel/UI authority copy.
    val originalFileTicket = state.fileTicket
    val originalPreview = state.preview
    val originalBrowser = state.browser
    val confirmation = state.confirmation
    val backFocus = remember { FocusRequester() }
    LaunchedEffect(tv, originalBrowser?.page, originalBrowser?.collectionId, originalBrowser?.folderId,
        originalBrowser?.sourceIndex, originalPreview != null) {
        if (tv && originalBrowser == null) { withFrameNanos { }; backFocus.requestFocus() }
    }
    val usable = state.phase == Phase.READY || state.phase == Phase.LOCAL_ACCEPTED
    val back: () -> Unit = {
        when {
            confirmation != null -> viewModel.cancelConfirmation(confirmation)
            pasteVisible -> pasteVisible = false
            originalFileTicket != null -> viewModel.cancelFileImport(originalFileTicket)
            originalBrowser != null -> viewModel.back(originalBrowser)
            originalPreview != null -> viewModel.clearPreview(originalPreview)
            else -> onBack()
        }
    }
    BackHandler(onBack = back)
    Column(modifier.fillMaxSize().background(VortXTheme.colors.canvas).padding(if (tv) 32.dp else 16.dp).focusRestorer().focusGroup()) {
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            XperienceAction(stringResource(R.string.xperience_back), tv, modifier = Modifier.focusRequester(backFocus), onClick = back)
            Text(stringResource(R.string.xperience_title), style = VortXTheme.type.sectionTitle,
                modifier = Modifier.weight(1f), maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
        if (state.busy) CircularProgressIndicator(modifier = Modifier.padding(12.dp))
        state.failure?.let { XperienceMessage(failureLabel(it)) }
        if (state.phase == Phase.LOCAL_ACCEPTED) XperienceMessage(stringResource(R.string.xperience_local_accepted))
        if (state.phase in setOf(Phase.IDLE, Phase.RETIRED, Phase.ERROR, Phase.CLOSED)) {
            // IDLE after process death never silently reopens under the new process/account.
            XperienceMessage(stringResource(R.string.xperience_reload_required))
            XperienceAction(stringResource(R.string.xperience_reload), tv, onClick = onReload)
        } else if (originalBrowser != null) {
            XperienceBrowser(viewModel, originalBrowser, tv, onItem, Modifier.weight(1f), backFocus)
        } else if (originalPreview != null) {
            XperiencePreview(viewModel, originalPreview, tv, !state.busy, Modifier.weight(1f), onReplaceFile = {
                viewModel.beginFileImport(originalRoute, originalPreview)
            }, onReplacePaste = { pasteTarget = originalPreview; pasteVisible = true })
        } else {
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                XperienceAction(stringResource(R.string.xperience_import_file), tv, usable) {
                    viewModel.beginFileImport(originalRoute)
                }
                XperienceAction(stringResource(R.string.xperience_paste), tv, usable) { pasteTarget = null; pasteVisible = true }
            }
            if (state.records.isEmpty() && !state.busy) XperienceMessage(stringResource(R.string.xperience_empty_saved))
            LazyColumn(modifier = Modifier.weight(1f).focusRestorer().focusGroup(),
                contentPadding = PaddingValues(vertical = 16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                items(state.records, key = { it.handle }) { record ->
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text(record.label ?: stringResource(R.string.xperience_unnamed), style = VortXTheme.type.body,
                            maxLines = 2, overflow = TextOverflow.Ellipsis)
                        if (record.kind == XperienceImportStore.RecordKind.SUPPORTED) {
                            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                                XperienceAction(stringResource(R.string.xperience_browse), tv, usable) {
                                    viewModel.browse(originalRoute, record.handle)
                                }
                                XperienceAction(stringResource(R.string.xperience_review), tv, usable) {
                                    viewModel.review(originalRoute, record.handle)
                                }
                                XperienceAction(stringResource(R.string.xperience_delete), tv, usable) {
                                    viewModel.stageDelete(originalRoute, record.handle)
                                }
                            }
                        } else XperienceMessage(stringResource(if (record.kind == XperienceImportStore.RecordKind.TOMBSTONE)
                            R.string.xperience_tombstone else R.string.xperience_read_only))
                    }
                }
            }
        }
    }
    originalFileTicket?.let { originalTicket -> key(originalTicket.id) {
        XperienceFilePresenter(viewModel, originalTicket, activity)
    } }
    if (pasteVisible) XperiencePasteDialog(tv, onDismiss = { pasteVisible = false; pasteTarget = null }, onSubmit = { text ->
        viewModel.previewPaste(originalRoute, text, originalPasteTarget)
        pasteVisible = false
        pasteTarget = null
    })
    confirmation?.let { original -> key(original) {
        AlertDialog(onDismissRequest = { viewModel.cancelConfirmation(original) },
            title = { Text(stringResource(when (original.kind) {
                XperienceCollectionsViewModel.Confirmation.Kind.APPEND -> R.string.xperience_confirm_append
                XperienceCollectionsViewModel.Confirmation.Kind.REPLACE -> R.string.xperience_confirm_replace
                XperienceCollectionsViewModel.Confirmation.Kind.REBIND -> R.string.xperience_confirm_rebind
                XperienceCollectionsViewModel.Confirmation.Kind.DELETE -> R.string.xperience_confirm_delete
            })) }, text = { Text(original.label, maxLines = 3, overflow = TextOverflow.Ellipsis) },
            confirmButton = { XperienceAction(stringResource(R.string.xperience_confirm), tv, !state.busy) { viewModel.confirm(original) } },
            dismissButton = { XperienceAction(stringResource(R.string.xperience_cancel), tv) { viewModel.cancelConfirmation(original) } })
    } }
}

/** Actual registry binding, separated only so controlled schedules exercise the same register/launch/
 * dispose body. Callbacks are immutable original-ticket closures; this object holds no command target. */
internal class XperienceDocumentRegistration(
    registry: ActivityResultRegistry,
    launcherKey: String,
    private val claimOriginalLaunch: () -> Boolean,
    onOriginalResult: (Uri?) -> Unit,
    private val cancelOriginal: () -> Unit,
) {
    private var closed = false
    private var resultDelivered = false // Platform receiver state only; never a ticket/command target.
    // Register first: Android may synchronously deliver an already-pending original result here.
    private val launcher = registry.register(launcherKey, ActivityResultContracts.OpenDocument()) { uri ->
        resultDelivered = true
        onOriginalResult(uri)
    }

    fun launchIfUnclaimed() {
        if (closed || !claimOriginalLaunch()) return
        try { launcher.launch(arrayOf("application/json", "text/plain", "application/octet-stream")) }
        catch (_: ActivityNotFoundException) { dispose(changingConfigurations = false) }
    }

    fun dispose(changingConfigurations: Boolean) {
        if (closed) return
        closed = true
        launcher.unregister()
        if (!changingConfigurations && !resultDelivered) cancelOriginal()
    }
}

/** Recreate only the platform receiver on configuration change. The controller retains the SAME
 * original ticket/key and launch claim. Process death has no ticket to re-register or permission to recapture. */
@Composable
private fun XperienceFilePresenter(
    viewModel: XperienceCollectionsViewModel,
    originalTicket: XperienceCollectionsViewModel.FileTicket,
    activity: ComponentActivity,
) {
    DisposableEffect(originalTicket, activity) {
        val originalRegistration = XperienceDocumentRegistration(activity.activityResultRegistry, originalTicket.launcherKey,
            claimOriginalLaunch = { viewModel.claimFileLaunch(originalTicket) },
            onOriginalResult = { uri -> viewModel.fileResult(originalTicket,
                uri?.let { originalUri -> { activity.contentResolver.openInputStream(originalUri) } }) },
            cancelOriginal = { viewModel.cancelFileImport(originalTicket) })
        originalRegistration.launchIfUnclaimed()
        onDispose { originalRegistration.dispose(changingConfigurations = activity.isChangingConfigurations) }
    }
}

@Composable
private fun XperiencePasteDialog(tv: Boolean, onDismiss: () -> Unit, onSubmit: (String) -> Unit) {
    var text by remember { mutableStateOf("") }
    DisposableEffect(Unit) { onDispose { text = "" } }
    val clearAndDismiss = { text = ""; onDismiss() }
    AlertDialog(onDismissRequest = clearAndDismiss,
        title = { Text(stringResource(R.string.xperience_paste)) },
        text = { Column {
            Text(stringResource(R.string.xperience_paste_privacy))
            OutlinedTextField(value = text, onValueChange = { text = it }, label = { Text(stringResource(R.string.xperience_json)) },
                minLines = 3, maxLines = 6,
                visualTransformation = PasswordVisualTransformation(), keyboardOptions = KeyboardOptions(
                    autoCorrectEnabled = false, keyboardType = KeyboardType.Password), modifier = Modifier.fillMaxWidth())
        } },
        confirmButton = { XperienceAction(stringResource(R.string.xperience_preview), tv, text.isNotBlank()) {
            val originalText = text; text = ""; onSubmit(originalText)
        } }, dismissButton = { XperienceAction(stringResource(R.string.xperience_cancel), tv, onClick = clearAndDismiss) })
}

@Composable
private fun XperiencePreview(viewModel: XperienceCollectionsViewModel, original: Preview, tv: Boolean, enabled: Boolean, modifier: Modifier,
    onReplaceFile: () -> Unit, onReplacePaste: () -> Unit) {
    // Binding refresh keeps the same document/handle. A newly imported replacement gets its own draft.
    var labelDraft by rememberSaveable(original.document, original.replacing) { mutableStateOf(original.label) }
    LazyColumn(modifier.focusRestorer().focusGroup(), verticalArrangement = Arrangement.spacedBy(12.dp), contentPadding = PaddingValues(vertical = 16.dp)) {
        item {
            OutlinedTextField(value = labelDraft, onValueChange = { labelDraft = it }, enabled = enabled,
                label = { Text(stringResource(R.string.xperience_label)) }, modifier = Modifier.fillMaxWidth())
            XperienceMessage(stringResource(R.string.xperience_preview_counts, original.document.collections.size,
                original.document.collections.sumOf { it.folders.size }))
            if (original.document.notices.isNotEmpty()) XperienceMessage(stringResource(R.string.xperience_preserved_notice))
            if (original.replacing != null) {
                XperienceAction(stringResource(R.string.xperience_replace_file), tv, enabled, onClick = onReplaceFile)
                XperienceAction(stringResource(R.string.xperience_replace_paste), tv, enabled, onClick = onReplacePaste)
            }
        }
        items(original.bindings, key = { it.key }) { row ->
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(stringResource(R.string.xperience_source_number, row.ordinal), style = VortXTheme.type.body)
                XperienceMessage(sourceLabel(row.status))
                XperienceAction(stringResource(R.string.xperience_leave_unavailable), tv, enabled) { viewModel.chooseBinding(original, row.key, null) }
                var choosing by remember(original, row.key) { mutableStateOf(false) }
                if (row.choices.isNotEmpty()) XperienceAction(stringResource(R.string.xperience_choose_option), tv, enabled) { choosing = true }
                if (choosing) AlertDialog(onDismissRequest = { choosing = false },
                    title = { Text(stringResource(R.string.xperience_choose_option)) },
                    text = {
                        LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            itemsIndexed(row.choices) { index, choice ->
                                XperienceAction(stringResource(if (row.selected === choice) R.string.xperience_selected_option else R.string.xperience_option, index + 1), tv, enabled) {
                                    viewModel.chooseBinding(original, row.key, choice)
                                    choosing = false
                                }
                            }
                        }
                    }, confirmButton = { XperienceAction(stringResource(R.string.xperience_cancel), tv) { choosing = false } })
            }
        }
        item {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                if (original.replacing == null) XperienceAction(stringResource(R.string.xperience_append), tv, enabled) { viewModel.stageAppend(original, labelDraft) }
                else {
                    XperienceAction(stringResource(R.string.xperience_replace), tv, enabled) { viewModel.stageReplace(original, labelDraft) }
                    XperienceAction(stringResource(R.string.xperience_rebind), tv, enabled) { viewModel.stageRebind(original, labelDraft) }
                }
                XperienceAction(stringResource(R.string.xperience_cancel), tv) { viewModel.clearPreview(original) }
            }
        }
    }
}

@Composable
private fun XperienceBrowser(viewModel: XperienceCollectionsViewModel, original: Browser, tv: Boolean, onItem: (MetaItem) -> Unit,
    modifier: Modifier, fallbackFocus: FocusRequester) {
    // IDs select only original document nodes; source indices remain original folder indices.
    val collection = original.document.collections.firstOrNull { it.id == original.collectionId }
    val folder = collection?.folders?.firstOrNull { it.id == original.folderId }
    val listState = rememberLazyListState()
    var focusedTitle by rememberSaveable(original.collectionId, original.folderId, original.sourceIndex) { mutableStateOf<Int?>(null) }
    val titleFocus = remember { FocusRequester() }
    val restoreIndex = focusedTitle?.takeIf { it in original.items.indices } ?: 0
    LaunchedEffect(tv, original.page, original.collectionId, original.folderId, original.sourceIndex, original.items.isNotEmpty()) {
        if (tv) {
            if (original.page == XperienceCollectionsViewModel.Page.CATALOG && original.items.isNotEmpty()) {
                listState.scrollToItem(restoreIndex + 2) // Label + source status precede the original title rows.
                withFrameNanos { }
                titleFocus.requestFocus()
            } else { withFrameNanos { }; fallbackFocus.requestFocus() }
        }
    }
    LazyColumn(modifier.focusRestorer().focusGroup(), state = listState,
        verticalArrangement = Arrangement.spacedBy(12.dp), contentPadding = PaddingValues(vertical = 16.dp)) {
        item { Text(original.label, style = VortXTheme.type.sectionTitle, maxLines = 2, overflow = TextOverflow.Ellipsis) }
        when (original.page) {
            XperienceCollectionsViewModel.Page.COLLECTIONS -> items(original.document.collections.sortedByDescending { it.pinToTop }, key = { it.id }) { entry ->
                XperienceAction(entry.title, tv, detail = stringResource(if (entry.pinToTop) R.string.xperience_pinned else R.string.xperience_collection)) {
                    viewModel.openCollection(original, entry.id)
                }
            }
            XperienceCollectionsViewModel.Page.FOLDERS -> {
                item {
                    collection?.let {
                        XperienceMessage(stringResource(when (it.viewMode.uppercase(Locale.ROOT)) {
                            "ROWS" -> R.string.xperience_layout_rows
                            "FOLLOW_LAYOUT" -> R.string.xperience_layout_follow
                            else -> R.string.xperience_layout_tabs
                        }))
                        if (it.showAllTab) XperienceMessage(stringResource(R.string.xperience_all_folders))
                        if (it.folders.isEmpty()) XperienceMessage(stringResource(R.string.xperience_empty_folders))
                    }
                }
                if (collection?.viewMode?.uppercase(Locale.ROOT) == "ROWS") {
                    items(collection?.folders.orEmpty(), key = { it.id }) { entry -> XperienceFolder(viewModel, original, entry, tv, Modifier.fillMaxWidth(), false) }
                } else {
                    items(collection?.folders.orEmpty().chunked(if (tv) 4 else 2)) { row ->
                        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                            row.forEach { entry -> key(entry.id) {
                                XperienceFolder(viewModel, original, entry, tv, Modifier.weight(1f), true)
                            } }
                        }
                    }
                }
            }
            XperienceCollectionsViewModel.Page.SOURCES -> {
                if (folder?.sources.isNullOrEmpty()) item { XperienceMessage(stringResource(R.string.xperience_empty_sources)) }
                itemsIndexed(folder?.sources.orEmpty()) { index, _ ->
                    XperienceAction(stringResource(R.string.xperience_source_number, index + 1), tv) { viewModel.openSource(original, index) }
                }
            }
            XperienceCollectionsViewModel.Page.CATALOG -> {
                item {
                    original.status?.takeIf { it != SourceStatus.RESOLVED }?.let { XperienceMessage(sourceLabel(it)) }
                    original.failure?.let { XperienceMessage(failureLabel(it)) }
                    if (original.limited) XperienceMessage(stringResource(R.string.xperience_catalog_limit,
                        XperienceCollectionsViewModel.MAX_CATALOG_ITEMS))
                    if (original.loading) CircularProgressIndicator()
                    else if (original.items.isEmpty() && original.status == SourceStatus.RESOLVED && original.failure == null)
                        XperienceMessage(stringResource(R.string.xperience_empty_catalog))
                    if (!original.loading && original.failure != null) XperienceAction(stringResource(R.string.xperience_retry), tv) { viewModel.retryCatalog(original) }
                }
                itemsIndexed(original.items) { index, item ->
                    XperienceAction(item.name, tv, detail = item.year,
                        modifier = if (index == restoreIndex) Modifier.focusRequester(titleFocus) else Modifier,
                        onFocus = { if (it) focusedTitle = index }) { viewModel.openItem(original, item, onItem) }
                }
                if (!original.loading && original.hasMore) item {
                    XperienceAction(stringResource(R.string.xperience_more), tv) { viewModel.loadMoreCatalog(original) }
                }
            }
        }
    }
}

@Composable
private fun XperienceFolder(viewModel: XperienceCollectionsViewModel, original: Browser, folder: XperienceCollections.Folder,
    tv: Boolean, modifier: Modifier, shaped: Boolean) {
    val shape = when (folder.tileShape.uppercase(Locale.ROOT)) {
        "POSTER" -> R.string.xperience_shape_poster to (2f / 3f)
        "LANDSCAPE", "WIDE" -> R.string.xperience_shape_wide to (16f / 9f)
        else -> R.string.xperience_shape_square to 1f
    }
    // Static shape only: raw artwork/animation addresses never become fetch authority.
    XperienceAction(if (folder.hideTitle) stringResource(R.string.xperience_folder) else folder.title,
        tv, detail = stringResource(shape.first), modifier = if (shaped) modifier.aspectRatio(shape.second) else modifier) {
        viewModel.openFolder(original, folder.id)
    }
}

@OptIn(ExperimentalTvMaterial3Api::class)
@Composable
internal fun XperienceAction(label: String, tv: Boolean, enabled: Boolean = true, detail: String? = null, modifier: Modifier = Modifier,
    onFocus: (Boolean) -> Unit = {}, onClick: () -> Unit) {
    var focused by remember { mutableStateOf(false) }
    if (tv) androidx.tv.material3.Surface(onClick = onClick, enabled = enabled, modifier = modifier.onFocusChanged { focused = it.hasFocus; onFocus(it.hasFocus) },
        shape = ClickableSurfaceDefaults.shape(shape = VortXShapes.control),
        colors = ClickableSurfaceDefaults.colors(containerColor = VortXTheme.colors.surface1, contentColor = VortXTheme.colors.textPrimary,
            focusedContainerColor = VortXTheme.colors.accent, focusedContentColor = VortXTheme.colors.onAccent),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1.03f),
        border = ClickableSurfaceDefaults.border(focusedBorder = Border(BorderStroke(2.dp, VortXTheme.colors.accentBright), VortXShapes.control))) {
        Column(Modifier.padding(16.dp)) {
            Text(label, style = VortXTheme.type.body, color = if (focused) VortXTheme.colors.onAccent else VortXTheme.colors.textPrimary,
                maxLines = 2, overflow = TextOverflow.Ellipsis)
            detail?.let { Text(it, style = VortXTheme.type.body, color = if (focused) VortXTheme.colors.onAccent else VortXTheme.colors.textSecondary,
                maxLines = 2, overflow = TextOverflow.Ellipsis) }
        }
    } else Button(onClick = onClick, enabled = enabled, modifier = modifier, shape = VortXShapes.control) {
        Column { Text(label, maxLines = 2, overflow = TextOverflow.Ellipsis); detail?.let { Text(it, maxLines = 2, overflow = TextOverflow.Ellipsis) } }
    }
}

@Composable
private fun XperienceMessage(text: String) { Text(text, style = VortXTheme.type.body.copy(color = VortXTheme.colors.textSecondary), modifier = Modifier.padding(vertical = 8.dp)) }

@Composable
private fun sourceLabel(status: SourceStatus): String = stringResource(when (status) {
    SourceStatus.RESOLVED -> R.string.xperience_source_resolved
    SourceStatus.MISSING -> R.string.xperience_source_missing
    SourceStatus.AMBIGUOUS -> R.string.xperience_source_ambiguous
    SourceStatus.MAPPING_UNAVAILABLE -> R.string.xperience_source_mapping
    SourceStatus.UNSUPPORTED -> R.string.xperience_source_unsupported
    SourceStatus.INVALID_REGISTRY -> R.string.xperience_source_registry
})

@Composable
private fun failureLabel(failure: Failure): String = stringResource(when (failure) {
    Failure.TOO_LARGE -> R.string.xperience_too_large
    Failure.INVALID_INPUT -> R.string.xperience_invalid
    Failure.READ_ONLY -> R.string.xperience_read_only
    Failure.CANCELLED -> R.string.xperience_cancelled
    Failure.STALE -> R.string.xperience_stale
    Failure.MISSING -> R.string.xperience_missing
    Failure.MISSING_SOURCE -> R.string.xperience_source_missing
    Failure.AMBIGUOUS_SOURCE -> R.string.xperience_source_ambiguous
    Failure.MAPPING_UNAVAILABLE -> R.string.xperience_source_mapping
    Failure.UNSUPPORTED_SOURCE -> R.string.xperience_source_unsupported
    Failure.INVALID_REGISTRY -> R.string.xperience_source_registry
    Failure.UNAVAILABLE -> R.string.xperience_unavailable
})
