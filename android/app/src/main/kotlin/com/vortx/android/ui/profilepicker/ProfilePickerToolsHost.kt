package com.vortx.android.ui.profilepicker

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.ContextWrapper
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
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.relocation.BringIntoViewRequester
import androidx.compose.foundation.relocation.bringIntoViewRequester
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
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
import com.vortx.android.sync.PickerAccountSnapshot
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.tv.TvProfileButton
import com.vortx.android.ui.viewmodel.ProfilePickerToolsViewModel

/** Sibling to the main picker, above all of its loading/early-return bodies. Opens no profile. */
@Composable
internal fun ProfilePickerToolsHost(
    model: ProfilePickerToolsViewModel,
    isTv: Boolean,
    diagnosticAdmission: () -> Boolean,
    recoveryPaused: Boolean = false,
    recoveryLanding: Boolean = recoveryPaused,
    openRecoverySignIn: ((PickerAccountSnapshot) -> Boolean)? = null,
    resumeRecoverySync: (suspend (PickerAccountSnapshot) -> Boolean)? = null,
    statusOnlyOwner: PickerAccountSnapshot? = null,
    statusOnlyAdmission: (() -> Boolean)? = null,
    entryInPicker: Boolean = false,
    picker: @Composable (toolsEntry: @Composable () -> Unit) -> Unit,
) {
    val context = LocalContext.current
    val controller = model.controller
    val state by model.state.collectAsStateWithLifecycle()
    val recoveryBusy by controller.recoveryBusy.collectAsStateWithLifecycle()
    check((statusOnlyOwner == null) == (statusOnlyAdmission == null))
    val attachment = if (statusOnlyOwner == null)
        remember(model, state.routeGeneration) { controller.attachPicker() }
    else remember(model, state.routeGeneration, statusOnlyOwner) { controller.attachPicker(statusOnlyOwner) }
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
    // A mode-mismatched attach may synchronously retire the previously collected presentation.
    val presentationCurrent = state.presentationId == controller.state.value.presentationId
    BackHandler(enabled = state.open && presentationCurrent, onBack = ::close)
    Box(Modifier.fillMaxSize()) {
        if (state.open && presentationCurrent && actionGrant != null) {
            val statusOnly = statusOnlyAdmission != null
            val fullDiagnosticsAllowed = !statusOnly && runCatching(requiredPolicy).getOrDefault(false)
            ProfilePickerToolsSurface(state, isTv,
                fullDiagnosticsAllowed = fullDiagnosticsAllowed,
                statusOnly = statusOnly,
                onBack = ::close,
                onDownload = { controller.download(actionGrant) },
                onRepair = if (controller.repairAvailable) ({ controller.repair(actionGrant) }) else null,
                onRepairDecision = { request, approved -> controller.confirmRepair(actionGrant, request, approved) },
                repairInput = { request ->
                    key(request.routeId, request.operationId) {
                        PickerToolsRepairInput(model, request, isTv)
                    }
                },
                onRestore = if (controller.restoreAvailable && actionGrant.original?.account != null)
                    ({ controller.restore(actionGrant, statusOnlyAdmission) }) else null,
                recoveryBusy = recoveryBusy || controller.recoveryBusy.value,
                recoveryLanding = recoveryLanding,
                onRecoverySignIn = openRecoverySignIn?.takeIf {
                    controller.restoreAvailable && !recoveryPaused && actionGrant.original?.let { it.account == null } == true
                }?.let { open -> { controller.beginRecoverySignIn(actionGrant, open) } },
                onResumeRecovery = resumeRecoverySync?.takeIf { recoveryPaused && actionGrant.original?.account != null }
                    ?.let { resume -> { controller.resumeRecoverySync(actionGrant, resume) } },
                onRestoreDecision = { request, approved -> controller.confirmRestore(actionGrant, request, approved) },
                onVerifyRestore = { request -> controller.verifyRestore(actionGrant, request, statusOnlyAdmission) },
                onDiagnostics = {
                    if (fullDiagnosticsAllowed) model.diagnostics(actionGrant, context) { requiredPolicy() }
                    else model.recoveryDiagnostics(actionGrant, context)
                },
                restoreInput = { request ->
                    key(request.routeId, request.operationId) {
                        PickerToolsRestoreInput(model, request, isTv)
                    }
                },
                destination = { request ->
                    // This composition identity and callback both belong to the original request.
                    // Rotation re-registers it without launching another GET or destination activity.
                    key(request.routeId, request.operationId) {
                        PickerToolsDestination(model, request, isTv)
                    }
                })
        } else {
            val toolsEntry: @Composable () -> Unit = {
                PickerToolsButton("Tools", isTv, true, Modifier.focusRequester(entryFocus).testTag("profile-picker-tools")) {
                    controller.open(attachment)
                }
            }
            picker(toolsEntry)
            if (!entryInPicker) Box(Modifier.align(Alignment.TopEnd).padding(24.dp)) {
                toolsEntry()
            }
        }
    }
    LaunchedEffect(state.open, restoreEntryFocus, recoveryLanding) {
        if (!state.open && (restoreEntryFocus || recoveryLanding)) {
            withFrameNanos { }
            runCatching { entryFocus.requestFocus() }
            restoreEntryFocus = false
        }
    }
}

/** Explicit registry identity prevents a restored result from borrowing a new process/operation.
 * Only these nonsecret IDs survive framework registry restoration; account bytes/URI authority do not. */
@Composable
private fun PickerToolsDestination(model: ProfilePickerToolsViewModel, request: PickerToolsDestinationRequest, isTv: Boolean) {
    val registry = LocalActivityResultRegistryOwner.current?.activityResultRegistry
    var launcher by remember(registry, request) { mutableStateOf<ActivityResultLauncher<Uri?>?>(null) }
    DisposableEffect(registry, request) {
        val originalRequest = request
        val registered = registry?.register("picker-tools-tree-${request.routeId}-${request.operationId}",
            ActivityResultContracts.OpenDocumentTree()) { tree -> model.destinationReturned(originalRequest, tree) }
        launcher = registered
        onDispose { registered?.unregister(); launcher = null }
    }
    PickerToolsButton("Choose folder", isTv, true, Modifier.testTag("picker-tools-destination"), primary = true,
        initialTvFocus = true) {
        if (!model.controller.claimDestinationLaunch(request)) return@PickerToolsButton
        val originalLauncher = launcher
        if (originalLauncher == null)
            model.controller.destinationRefused(request, PickerToolsFailure.NO_FILE_PROVIDER)
        else try { originalLauncher.launch(null) }
        catch (_: ActivityNotFoundException) { model.controller.destinationRefused(request, PickerToolsFailure.NO_FILE_PROVIDER) }
        catch (_: SecurityException) { model.controller.destinationRefused(request, PickerToolsFailure.DESTINATION_UNAVAILABLE) }
        catch (_: IllegalStateException) { model.controller.destinationRefused(request, PickerToolsFailure.DESTINATION_UNAVAILABLE) }
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
    PickerToolsButton("Choose backup file", isTv, true, Modifier.testTag("picker-tools-repair-input"), primary = true,
        initialTvFocus = true) {
        if (!model.controller.claimRepairInputLaunch(request)) return@PickerToolsButton
        val originalLauncher = launcher
        if (originalLauncher == null) model.controller.repairInputRefused(request, PickerToolsFailure.NO_FILE_PROVIDER)
        else try { originalLauncher.launch(arrayOf("application/json", "application/octet-stream", "text/plain")) }
        catch (_: ActivityNotFoundException) { model.controller.repairInputRefused(request, PickerToolsFailure.NO_FILE_PROVIDER) }
        catch (_: SecurityException) { model.controller.repairInputRefused(request, PickerToolsFailure.DESTINATION_UNAVAILABLE) }
        catch (_: IllegalStateException) { model.controller.repairInputRefused(request, PickerToolsFailure.DESTINATION_UNAVAILABLE) }
    }
}

/** The URI callback is bound to the retained Restore input request, including after rotation. */
@Composable
private fun PickerToolsRestoreInput(model: ProfilePickerToolsViewModel, request: PickerToolsRestoreInputRequest, isTv: Boolean) {
    val registry = LocalActivityResultRegistryOwner.current?.activityResultRegistry
    var launcher by remember(registry, request) { mutableStateOf<ActivityResultLauncher<Array<String>>?>(null) }
    DisposableEffect(registry, request) {
        val originalRequest = request
        val registered = registry?.register("picker-tools-restore-input-${request.routeId}-${request.operationId}",
            ActivityResultContracts.OpenDocument()) { uri -> model.restoreInputReturned(originalRequest, uri) }
        launcher = registered
        onDispose { registered?.unregister(); launcher = null }
    }
    PickerToolsButton("Choose backup file", isTv, true, Modifier.testTag("picker-tools-restore-input"), primary = true,
        initialTvFocus = true) {
        if (!model.controller.claimRestoreInputLaunch(request)) return@PickerToolsButton
        val originalLauncher = launcher
        if (originalLauncher == null) model.controller.restoreInputRefused(request, PickerToolsFailure.NO_FILE_PROVIDER)
        else try { originalLauncher.launch(arrayOf("application/json", "application/octet-stream", "text/plain")) }
        catch (_: ActivityNotFoundException) { model.controller.restoreInputRefused(request, PickerToolsFailure.NO_FILE_PROVIDER) }
        catch (_: SecurityException) { model.controller.restoreInputRefused(request, PickerToolsFailure.DESTINATION_UNAVAILABLE) }
        catch (_: IllegalStateException) { model.controller.restoreInputRefused(request, PickerToolsFailure.DESTINATION_UNAVAILABLE) }
    }
}

@Composable
internal fun ProfilePickerToolsSurface(
    state: PickerToolsState,
    isTv: Boolean,
    fullDiagnosticsAllowed: Boolean,
    statusOnly: Boolean,
    onBack: () -> Unit,
    onDownload: () -> Unit,
    onRepair: (() -> Unit)?,
    onRepairDecision: (PickerToolsRepairInputRequest, Boolean) -> Unit,
    repairInput: @Composable (PickerToolsRepairInputRequest) -> Unit,
    onRestore: (() -> Unit)?,
    recoveryBusy: Boolean,
    recoveryLanding: Boolean,
    onRecoverySignIn: (() -> Unit)?,
    onResumeRecovery: (() -> Unit)?,
    onRestoreDecision: (PickerToolsRestoreInputRequest, Boolean) -> Unit,
    onVerifyRestore: (PickerToolsRestoreVerifyRequest) -> Unit,
    restoreInput: @Composable (PickerToolsRestoreInputRequest) -> Unit,
    onDiagnostics: () -> Unit,
    destination: @Composable (PickerToolsDestinationRequest) -> Unit,
) {
    val colors = VortXTheme.colors
    val firstFocus = remember { FocusRequester() }
    val feedback = remember { BringIntoViewRequester() }
    val showFeedback = state.busy || state.message != null || state.restoreStatus != null
    Surface(Modifier.fillMaxSize(), color = colors.canvas, contentColor = colors.textPrimary) {
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(if (isTv) 48.dp else 24.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
            horizontalAlignment = Alignment.CenterHorizontally) {
            Text("Tools", style = VortXTheme.type.sectionTitle)
            Text(if (statusOnly) "Check a retained backup restore or verify the cloud backup."
                else "Manage encrypted backups and share diagnostics.",
                style = VortXTheme.type.body, modifier = Modifier.widthIn(max = 680.dp))
            PickerToolsButton(when {
                statusOnly -> "Back to profile tools"
                recoveryLanding -> "Back to recovery"
                else -> "Back to profiles"
            }, isTv, true,
                Modifier.focusRequester(firstFocus).testTag("picker-tools-back"), onClick = onBack)
            if (showFeedback) {
                Surface(Modifier.widthIn(max = 680.dp).fillMaxWidth().bringIntoViewRequester(feedback),
                    color = colors.surface2, contentColor = colors.textPrimary, shape = VortXTheme.shapes.control) {
                    Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        state.restoreStatus?.let { status ->
                            Text(status.message, style = VortXTheme.type.body,
                                modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite })
                            status.verify?.let { request ->
                                PickerToolsButton("Verify cloud backup", isTv, !state.busy && !recoveryBusy,
                                    Modifier.testTag("picker-tools-restore-verify"), primary = true, initialTvFocus = true) {
                                    onVerifyRestore(request)
                                }
                            }
                        }
                        CompositionLocalProvider(LocalTextStyle provides VortXTheme.type.body) {
                            ProfilePickerToolsProgress(state, isTv, onRepairDecision, repairInput,
                                onRestoreDecision, restoreInput, destination)
                        }
                        state.message?.let {
                            Text(it, style = VortXTheme.type.body,
                                modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite }.testTag("picker-tools-status"))
                        }
                    }
                }
            }
            if (!statusOnly) {
                PickerToolsButton("Download backup", isTv, !state.busy, Modifier.testTag("picker-tools-download"), onClick = onDownload)
                if (onRepair != null)
                    PickerToolsButton("Repair backup", isTv, !state.busy, Modifier.testTag("picker-tools-repair"), onClick = onRepair)
            }
            if (onRestore != null) {
                PickerToolsButton(if (statusOnly || state.restoreStatus != null) "Check restore status" else "Restore backup",
                    isTv, !state.busy && !recoveryBusy, Modifier.testTag("picker-tools-restore"), onClick = onRestore)
            }
            if (onRecoverySignIn != null)
                PickerToolsButton("Sign in for backup recovery", isTv, !state.busy && !recoveryBusy,
                    Modifier.testTag("picker-tools-recovery-sign-in"), primary = true, onClick = onRecoverySignIn)
            if (onResumeRecovery != null)
                PickerToolsButton("Resume regular sync", isTv, !state.busy && !recoveryBusy,
                    Modifier.testTag("picker-tools-recovery-resume"), onClick = onResumeRecovery)
            if (!statusOnly) {
                PickerToolsButton(if (fullDiagnosticsAllowed) "Save or share diagnostic log" else "Share account recovery diagnostics",
                    isTv, !state.busy, Modifier.testTag(if (fullDiagnosticsAllowed)
                        "picker-tools-diagnostics" else "picker-tools-recovery-diagnostics"), onClick = onDiagnostics)
            }
            if (onRestore == null && onRecoverySignIn == null) Text("Account-file restore is not available here yet.",
                style = VortXTheme.type.label,
                modifier = Modifier.widthIn(max = 680.dp))
        }
    }
    LaunchedEffect(Unit) {
        if (!showFeedback) {
            withFrameNanos { }
            runCatching { firstFocus.requestFocus() }
        }
    }
    LaunchedEffect(showFeedback, state.phase, state.restoreStatus?.message, state.message) {
        if (showFeedback) {
            withFrameNanos { }
            feedback.bringIntoView()
        }
    }
}

@Composable
private fun ProfilePickerToolsProgress(
    state: PickerToolsState,
    isTv: Boolean,
    onRepairDecision: (PickerToolsRepairInputRequest, Boolean) -> Unit,
    repairInput: @Composable (PickerToolsRepairInputRequest) -> Unit,
    onRestoreDecision: (PickerToolsRestoreInputRequest, Boolean) -> Unit,
    restoreInput: @Composable (PickerToolsRestoreInputRequest) -> Unit,
    destination: @Composable (PickerToolsDestinationRequest) -> Unit,
) {
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
            PickerToolsButton("Save repaired copy", isTv, true, Modifier.testTag("picker-tools-repair-confirm"),
                primary = true, initialTvFocus = true) {
                onRepairDecision(review.request, true)
            }
            PickerToolsButton("Cancel repair", isTv, true, Modifier.testTag("picker-tools-repair-cancel")) {
                onRepairDecision(review.request, false)
            }
        }
        PickerToolsPhase.CHECKING_RESTORE -> Text("Checking retained restore status…")
        PickerToolsPhase.CHOOSING_RESTORE_INPUT -> {
            Text("Choose an encrypted VortX backup for your signed-in account.")
            state.restoreInput?.let { restoreInput(it) }
        }
        PickerToolsPhase.READING_RESTORE -> Text("Reading the selected backup…")
        PickerToolsPhase.REVIEWING_RESTORE -> state.restoreReview?.let { review ->
            Text("Restore this file to the signed-in account’s cloud backup?")
            Text("Selected file: ${review.byteCount} bytes.")
            Text("Restoring may replace the existing cloud backup. Your selected file and local profiles will stay in place.")
            PickerToolsButton("Restore cloud backup", isTv, true, Modifier.testTag("picker-tools-restore-confirm"),
                primary = true, initialTvFocus = true) {
                onRestoreDecision(review.request, true)
            }
            PickerToolsButton("Cancel restore", isTv, true, Modifier.testTag("picker-tools-restore-cancel")) {
                onRestoreDecision(review.request, false)
            }
        }
        PickerToolsPhase.RESTORING -> Text("Restoring the cloud backup…")
        PickerToolsPhase.VERIFYING_RESTORE -> Text("Verifying the retained restore against the cloud backup…")
        PickerToolsPhase.OPENING_RECOVERY_SIGN_IN -> Text("Opening backup recovery sign-in…")
        PickerToolsPhase.RESUMING_RECOVERY_SYNC -> Text("Resuming regular sync…")
        PickerToolsPhase.AWAITING_DESTINATION -> {
            Text("Choose a folder to save a new copy. If Downloads is unavailable, choose or create a subfolder.")
            state.destination?.let { destination(it) }
        }
        PickerToolsPhase.SAVING -> Text("Saving and verifying the new encrypted copy…")
        PickerToolsPhase.SHARING_DIAGNOSTICS -> Text("Preparing diagnostic log…")
        PickerToolsPhase.CANCELLING -> Text(if (state.cancellingFileSave)
            "Waiting for the previous save to finish cancelling. A new copy may remain in its folder."
        else "Waiting for the previous operation to finish cancelling.")
        PickerToolsPhase.IDLE -> Unit
    }
}
/** The cold entry can be dismissed. An authenticated pause exits only through Resume or Sign out. */
@Composable
internal fun PickerFileRecoveryLanding(isTv: Boolean, accountControl: ProfilePickerAccountControl?, toolsEntry: @Composable () -> Unit,
    onContinue: (() -> Unit)?,
) {
    BackHandler(enabled = onContinue != null) { onContinue?.invoke() }
    Column(Modifier.fillMaxSize().background(VortXTheme.colors.canvas)
        .verticalScroll(rememberScrollState()).padding(if (isTv) 48.dp else 24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
        horizontalAlignment = Alignment.CenterHorizontally) {
        Text(if (onContinue == null) "Regular sync is paused" else "Restore an account backup?",
            style = VortXTheme.type.sectionTitle)
        Text(if (onContinue == null) "Use Tools to restore a backup, check an earlier restore, or resume regular sync."
            else "Open Tools to sign in for backup recovery.",
            style = VortXTheme.type.body, modifier = Modifier.widthIn(max = 680.dp))
        toolsEntry()
        if (onContinue != null)
            PickerToolsButton("Continue to VortX", isTv, true, Modifier.testTag("picker-recovery-continue"), onClick = onContinue)
        accountControl?.let {
            PickerToolsButton(it.label, isTv, true, Modifier.testTag("picker-recovery-account"), onClick = it.onClick)
        }
    }
}

@Composable
internal fun PickerRestoreStatusLanding(isTv: Boolean, onBack: () -> Unit) {
    BackHandler(onBack = onBack)
    Column(Modifier.fillMaxSize().background(VortXTheme.colors.canvas)
        .verticalScroll(rememberScrollState()).padding(if (isTv) 48.dp else 24.dp).padding(top = 56.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
        horizontalAlignment = Alignment.CenterHorizontally) {
        Text("Profile picker tools", style = VortXTheme.type.sectionTitle)
        Text("Open Tools to check a retained backup restore.", style = VortXTheme.type.body)
        PickerToolsButton("Back to Settings", isTv, true, Modifier.testTag("picker-restore-status-back"), onClick = onBack)
    }
}

@Composable
internal fun PickerToolsButton(label: String, isTv: Boolean, enabled: Boolean, modifier: Modifier,
    primary: Boolean = false, initialTvFocus: Boolean = false, onClick: () -> Unit) {
    if (isTv) {
        val focus = if (initialTvFocus && enabled) remember { FocusRequester() } else null
        val button = if (focus != null) modifier.focusRequester(focus) else modifier
        TvProfileButton(label, enabled = enabled, modifier = button.widthIn(min = 280.dp, max = 680.dp), onClick = onClick)
        if (focus != null) LaunchedEffect(focus) {
            withFrameNanos { }
            runCatching { focus.requestFocus() }
        }
    } else if (primary) {
        val colors = VortXTheme.colors
        Button(enabled = enabled, modifier = modifier, onClick = onClick,
            colors = ButtonDefaults.buttonColors(containerColor = colors.surface3, contentColor = colors.textPrimary)) {
            Text(label)
        }
    } else OutlinedButton(enabled = enabled, modifier = modifier, onClick = onClick) { Text(label) }
}
private fun pickerActivity(context: Context): Activity? {
    var next = context
    val seen = java.util.Collections.newSetFromMap(java.util.IdentityHashMap<Context, Boolean>())
    while (seen.add(next)) {
        if (next is Activity) return next
        next = (next as? ContextWrapper)?.baseContext ?: return null
    }
    return null
}
