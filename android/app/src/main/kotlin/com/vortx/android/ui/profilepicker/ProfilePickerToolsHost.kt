package com.vortx.android.ui.profilepicker

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.activity.compose.LocalActivityResultRegistryOwner
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.tv.TvProfileButton
import com.vortx.android.ui.viewmodel.ProfilePickerToolsViewModel

/** Sibling to the main picker, above all of its loading/early-return bodies. Opens no profile. */
@Composable
internal fun ProfilePickerToolsHost(
    model: ProfilePickerToolsViewModel,
    isTv: Boolean,
    diagnosticAdmission: () -> Boolean,
    canOpenTree: (Context) -> Boolean = ::pickerCanOpenDocumentTree,
    picker: @Composable () -> Unit,
) {
    val context = LocalContext.current
    val controller = model.controller
    val state by model.state.collectAsStateWithLifecycle()
    val attachment = remember(model, state.routeGeneration) { controller.attachPicker() }
    val actionGrant = remember(model, attachment, state.presentationId) { controller.renderedActions(attachment) }
    val requiredPolicy by rememberUpdatedState(diagnosticAdmission)
    val entryFocus = remember { FocusRequester() }
    var restoreEntryFocus by remember { mutableStateOf(false) }
    fun close() { restoreEntryFocus = true; controller.closeTools(attachment) }
    DisposableEffect(model, attachment, context) {
        onDispose {
            controller.detachPicker(attachment, pickerActivity(context)?.isChangingConfigurations == true)
        }
    }
    BackHandler(enabled = state.open, onBack = ::close)
    Box(Modifier.fillMaxSize()) {
        if (state.open) {
            ProfilePickerToolsSurface(state, isTv, diagnosticAllowed = runCatching(requiredPolicy).getOrDefault(false),
                onBack = ::close,
                onDownload = { actionGrant?.let(controller::download) },
                onRepair = if (controller.repairAvailable) ({ actionGrant?.let(controller::repair) }) else null,
                onRepairDecision = { request, approved -> actionGrant?.let { controller.confirmRepair(it, request, approved) } },
                repairInput = { request ->
                    key(request.routeId, request.operationId) {
                        PickerToolsRepairInput(model, request, isTv)
                    }
                },
                onDiagnostics = { actionGrant?.let { grant -> model.diagnostics(grant, context) { requiredPolicy() } } },
                destination = { request ->
                    // This composition identity and callback both belong to the original request.
                    // Rotation re-registers it without launching another GET or destination activity.
                    key(request.routeId, request.operationId) {
                        PickerToolsDestination(model, request, isTv, canOpenTree)
                    }
                })
        } else {
            picker()
            PickerToolsButton("Tools", isTv, true,
                Modifier.align(Alignment.TopEnd).padding(24.dp).focusRequester(entryFocus).testTag("profile-picker-tools")) {
                controller.open(attachment)
            }
        }
    }
    LaunchedEffect(state.open, restoreEntryFocus) {
        if (!state.open && restoreEntryFocus) {
            withFrameNanos { }
            runCatching { entryFocus.requestFocus() }
            restoreEntryFocus = false
        }
    }
}

/** Explicit registry identity prevents a restored result from borrowing a new process/operation.
 * Only these nonsecret IDs survive framework registry restoration; account bytes/URI authority do not. */
@Composable
private fun PickerToolsDestination(model: ProfilePickerToolsViewModel, request: PickerToolsDestinationRequest,
    isTv: Boolean, canOpenTree: (Context) -> Boolean) {
    val context = LocalContext.current
    val registry = LocalActivityResultRegistryOwner.current?.activityResultRegistry
    var launcher by remember(registry, request) { mutableStateOf<ActivityResultLauncher<Uri?>?>(null) }
    DisposableEffect(registry, request) {
        val originalRequest = request
        val registered = registry?.register("picker-tools-tree-${request.routeId}-${request.operationId}",
            ActivityResultContracts.OpenDocumentTree()) { tree -> model.destinationReturned(originalRequest, tree) }
        launcher = registered
        onDispose { registered?.unregister(); launcher = null }
    }
    PickerToolsButton("Choose folder", isTv, true, Modifier.testTag("picker-tools-destination")) {
        if (!model.controller.claimDestinationLaunch(request)) return@PickerToolsButton
        val originalLauncher = launcher
        if (originalLauncher == null || !canOpenTree(context))
            model.controller.destinationRefused(request, PickerToolsFailure.NO_FILE_PROVIDER)
        else try { originalLauncher.launch(null) }
        catch (_: ActivityNotFoundException) { model.controller.destinationRefused(request, PickerToolsFailure.NO_FILE_PROVIDER) }
        catch (_: SecurityException) { model.controller.destinationRefused(request, PickerToolsFailure.DESTINATION_UNAVAILABLE) }
    }
}

/** The selected URI is delivered only to the original operation and never enters saved state. */
@Composable
private fun PickerToolsRepairInput(model: ProfilePickerToolsViewModel, request: PickerToolsRepairInputRequest, isTv: Boolean) {
    val registry = LocalActivityResultRegistryOwner.current?.activityResultRegistry
    var launcher by remember(registry, request) { mutableStateOf<ActivityResultLauncher<Array<String>>?>(null) }
    DisposableEffect(registry, request) {
        val originalRequest = request
        val registered = registry?.register("picker-tools-input-${request.routeId}-${request.operationId}",
            ActivityResultContracts.OpenDocument()) { uri -> model.repairInputReturned(originalRequest, uri) }
        launcher = registered
        onDispose { registered?.unregister(); launcher = null }
    }
    PickerToolsButton("Choose backup file", isTv, true, Modifier.testTag("picker-tools-repair-input")) {
        if (!model.controller.claimRepairInputLaunch(request)) return@PickerToolsButton
        val originalLauncher = launcher
        if (originalLauncher == null) model.controller.repairInputRefused(request, PickerToolsFailure.NO_FILE_PROVIDER)
        else try { originalLauncher.launch(arrayOf("application/json", "application/octet-stream", "text/plain")) }
        catch (_: ActivityNotFoundException) { model.controller.repairInputRefused(request, PickerToolsFailure.NO_FILE_PROVIDER) }
        catch (_: SecurityException) { model.controller.repairInputRefused(request, PickerToolsFailure.DESTINATION_UNAVAILABLE) }
    }
}

@Composable
internal fun ProfilePickerToolsSurface(
    state: PickerToolsState,
    isTv: Boolean,
    diagnosticAllowed: Boolean,
    onBack: () -> Unit,
    onDownload: () -> Unit,
    onRepair: (() -> Unit)?,
    onRepairDecision: (PickerToolsRepairInputRequest, Boolean) -> Unit,
    repairInput: @Composable (PickerToolsRepairInputRequest) -> Unit,
    onDiagnostics: () -> Unit,
    destination: @Composable (PickerToolsDestinationRequest) -> Unit,
) {
    val firstFocus = remember { FocusRequester() }
    Column(Modifier.fillMaxSize().background(VortXTheme.colors.canvas)
        .verticalScroll(rememberScrollState()).padding(if (isTv) 48.dp else 24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
        horizontalAlignment = Alignment.CenterHorizontally) {
        Text("Tools", style = VortXTheme.type.sectionTitle)
        Text("Download an encrypted account backup, repair a selected backup into a separate copy, or share a diagnostic log.",
            style = VortXTheme.type.body, modifier = Modifier.widthIn(max = 680.dp))
        PickerToolsButton("Back to profiles", isTv, true,
            Modifier.focusRequester(firstFocus).testTag("picker-tools-back"), onBack)
        PickerToolsButton("Download backup", isTv, !state.busy, Modifier.testTag("picker-tools-download"), onDownload)
        if (onRepair != null)
            PickerToolsButton("Repair backup", isTv, !state.busy, Modifier.testTag("picker-tools-repair"), onRepair)
        if (diagnosticAllowed) PickerToolsButton("Save or share diagnostic log", isTv, !state.busy,
            Modifier.testTag("picker-tools-diagnostics"), onDiagnostics)
        else Text("Diagnostic sharing is unavailable while profiles are locked or their roster is unavailable.",
            style = VortXTheme.type.label, modifier = Modifier.widthIn(max = 680.dp))
        when (state.phase) {
            PickerToolsPhase.DOWNLOADING -> Text("Downloading encrypted account backup…")
            PickerToolsPhase.CHOOSING_REPAIR_INPUT -> {
                Text("Choose an encrypted VortX backup for your signed-in account.")
                state.repairInput?.let { repairInput(it) }
            }
            PickerToolsPhase.PREPARING_REPAIR -> Text("Checking the selected backup and preparing a repaired copy…")
            PickerToolsPhase.REVIEWING_REPAIR -> state.repairReview?.let { review ->
                Text("Ready to save a repaired encrypted copy with ${review.profileCount} profiles (schema ${review.nativeSchema}, ${review.byteCount} bytes).")
                Text("The original backup and your cloud backup will stay in place.")
                PickerToolsButton("Save repaired copy", isTv, true, Modifier.testTag("picker-tools-repair-confirm")) {
                    onRepairDecision(review.request, true)
                }
                PickerToolsButton("Cancel repair", isTv, true, Modifier.testTag("picker-tools-repair-cancel")) {
                    onRepairDecision(review.request, false)
                }
            }
            PickerToolsPhase.AWAITING_DESTINATION -> {
                Text("Choose a folder for a separate new copy. Your existing files will stay in place.")
                state.destination?.let { destination(it) }
            }
            PickerToolsPhase.SAVING -> Text("Saving and verifying the new encrypted copy…")
            PickerToolsPhase.SHARING_DIAGNOSTICS -> Text("Preparing diagnostic log…")
            PickerToolsPhase.CANCELLING -> Text("Waiting for the previous operation to finish cancelling. A new copy may remain in its folder.")
            PickerToolsPhase.IDLE -> Unit
        }
        state.message?.let { Text(it, style = VortXTheme.type.body,
            modifier = Modifier.widthIn(max = 680.dp).semantics { liveRegion = LiveRegionMode.Polite }.testTag("picker-tools-status")) }
        Text("Account-file restore is not available here yet.", style = VortXTheme.type.label,
            modifier = Modifier.widthIn(max = 680.dp))
    }
    LaunchedEffect(Unit) { withFrameNanos { }; runCatching { firstFocus.requestFocus() } }
}
@Composable
private fun PickerToolsButton(label: String, isTv: Boolean, enabled: Boolean, modifier: Modifier, onClick: () -> Unit) {
    if (isTv) TvProfileButton(label, enabled = enabled, modifier = modifier.widthIn(min = 280.dp, max = 680.dp), onClick = onClick)
    else TextButton(enabled = enabled, modifier = modifier, onClick = onClick) { Text(label) }
}
internal fun pickerCanOpenDocumentTree(context: Context): Boolean = runCatching {
    Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).resolveActivity(context.packageManager) != null
}.getOrDefault(false)
private fun pickerActivity(context: Context): Activity? {
    var next = context
    val seen = java.util.Collections.newSetFromMap(java.util.IdentityHashMap<Context, Boolean>())
    while (seen.add(next)) {
        if (next is Activity) return next
        next = (next as? ContextWrapper)?.baseContext ?: return null
    }
    return null
}
