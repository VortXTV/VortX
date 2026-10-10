package com.vortx.android.ui.tv

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.tv.material3.Border
import androidx.tv.material3.ClickableSurfaceDefaults
import androidx.tv.material3.ExperimentalTvMaterial3Api
import androidx.tv.material3.Surface
import com.vortx.android.BuildConfig
import com.vortx.android.VortXApplication
import com.vortx.android.profile.ProfileStore
import com.vortx.android.profile.ContinueWatchingOwnerGate
import com.vortx.android.profile.ProfileSelectionRequest
import com.vortx.android.profile.captureProfileSelection
import com.vortx.android.profile.UserProfile
import com.vortx.android.ui.screens.profiles.normalizeCustomAvatar
import com.vortx.android.ui.theme.VortXAccents
import com.vortx.android.ui.theme.VortXShapes
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.viewmodel.NativeStreamingAccountViewModel
import kotlinx.coroutines.CancellationException

/** Presentation adapter only: all durable roster, overlay and tombstone operations stay in ProfileStore. */
internal interface TvProfileGateway {
    data class Snapshot(val profiles: List<UserProfile>, val activeID: String?, val selectionPending: Boolean = false)
    class Admission internal constructor(internal val commit: (() -> Unit) -> Boolean)
    fun read(): Snapshot
    fun capture(profile: UserProfile, adding: Boolean = false, selection: Boolean = false): Admission?
    fun select(profile: UserProfile, admission: Admission): Result<ProfileSelectionRequest>
    fun save(profile: UserProfile, adding: Boolean, admission: Admission): Boolean
    fun remove(profile: UserProfile, admission: Admission): Boolean
}

/** Ordinary admission failures are actionable UI results; coroutine cancellation stays cancellation. */
private inline fun <T> tvProfileResult(block: () -> T): Result<T> = try {
    Result.success(block())
} catch (cancel: CancellationException) {
    throw cancel
} catch (error: Exception) {
    Result.failure(error)
}

internal fun legacyTvProfileAdmission(commit: (() -> Unit) -> Unit): TvProfileGateway.Admission =
    TvProfileGateway.Admission { action -> tvProfileResult { commit(action); true }.getOrDefault(false) }

/** Shared by the store adapter and its synthetic admission tests; retains the exact typed request. */
internal fun selectTvProfile(
    admission: TvProfileGateway.Admission,
    selection: () -> ProfileSelectionRequest,
): Result<ProfileSelectionRequest> = tvProfileResult {
    var request: ProfileSelectionRequest? = null
    check(admission.commit { request = selection() }) { "The profile changed. Open it again before switching." }
    checkNotNull(request)
}

internal class StoreTvProfileGateway(
    private val store: ProfileStore,
    private val native: NativeStreamingAccountViewModel?,
) : TvProfileGateway {
    override fun read(): TvProfileGateway.Snapshot = if (BuildConfig.NATIVE_ENGINE_ENABLED) {
        val state = native?.state?.value
        TvProfileGateway.Snapshot(state?.profiles.orEmpty(), state?.activeID, store.selectionPending)
    } else TvProfileGateway.Snapshot(store.profiles, store.activeID, store.selectionPending)

    override fun capture(profile: UserProfile, adding: Boolean, selection: Boolean): TvProfileGateway.Admission? {
        if (BuildConfig.NATIVE_ENGINE_ENABLED) {
            val model = native ?: return null
            val editor = if (selection) model.captureSelection(profile) else model.captureEditor(profile, adding)
            return editor?.let { TvProfileGateway.Admission { action -> model.commitEditor(it, action) } }
        }
        val (before, revision) = ContinueWatchingOwnerGate.serialized { read() to it }
        if ((!selection && !adding && before.activeID != profile.id) ||
            (if (adding) before.profiles.any { it.id == profile.id } else before.profiles.none { it == profile })) return null
        return legacyTvProfileAdmission { action -> ContinueWatchingOwnerGate.serialized { currentRevision ->
            val current = read()
            check(currentRevision == revision)
            check(current.profiles === before.profiles)
            check(current.activeID == before.activeID)
            check(if (adding) current.profiles.none { it.id == profile.id } else current.profiles.any { it == profile })
            action()
        } }
    }

    override fun select(profile: UserProfile, admission: TvProfileGateway.Admission): Result<ProfileSelectionRequest> =
        selectTvProfile(admission) {
            val outcome = store.select(profile)
            val after = if (BuildConfig.NATIVE_ENGINE_ENABLED) checkNotNull(native?.captureSelection(checkNotNull(store.active))) else null
            captureProfileSelection(store, profile, outcome,
                nativeAdmission = after?.let { captured -> { checkNotNull(native).commitEditor(captured) {} } })
        }

    override fun save(profile: UserProfile, adding: Boolean, admission: TvProfileGateway.Admission): Boolean = admission.commit {
        if (adding) store.add(profile) else store.update(profile)
        val saved = checkNotNull(store.profiles.singleOrNull { it.id == profile.id })
        check(saved.name == profile.name && saved.avatar == profile.avatar && saved.accentID == profile.accentID &&
            saved.oled == profile.oled && saved.isKids == profile.isKids && saved.pin == profile.pin) {
            "Saved profile changes could not be read back"
        }
    }

    override fun remove(profile: UserProfile, admission: TvProfileGateway.Admission): Boolean = admission.commit {
        check(!profile.isOwner && store.profiles.size > 1) { "The main or last profile cannot be deleted" }
        store.remove(profile)
        check(store.profiles.none { it.id == profile.id })
    }
}

/** Same native capture/commit admission as the phone editor. A missing mount never borrows a legacy roster. */
@Composable
internal fun rememberTvProfileGateway(): TvProfileGateway? {
    val store = ProfileStore.sharedOrNull()
    val native: NativeStreamingAccountViewModel? = if (BuildConfig.NATIVE_ENGINE_ENABLED) {
        val app = LocalContext.current.applicationContext as? VortXApplication
        val accounts = remember(app) { runCatching { app?.nativeStreamingAccounts() }.getOrNull() }
        if (accounts == null) null else viewModel(key = "tv-profile-management", factory = NativeStreamingAccountViewModel.Creator(accounts))
    } else null
    DisposableEffect(native) { onDispose { native?.close() } }
    val state = native?.state?.collectAsState()?.value
    // Observe active edits as well as selection; native roster updates are observed above.
    store?.activeProfile?.collectAsState()?.value
    if (store == null || (BuildConfig.NATIVE_ENGINE_ENABLED && state?.mounted != true)) return null
    return remember(store, native, state) { StoreTvProfileGateway(store, native) }
}

@Composable
fun TvProfilesScreen(onBack: () -> Unit, onSelected: (ProfileSelectionRequest) -> Unit, modifier: Modifier = Modifier) {
    val gateway = rememberTvProfileGateway()
    if (gateway == null) {
        Column(modifier.fillMaxSize().padding(TvDimens.edge), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Text("Profiles are unavailable. Open account setup, then try again.", style = VortXTheme.type.body)
            TvProfileButton("Back", onClick = onBack)
        }
        BackHandler(onBack = onBack)
        return
    }
    TvProfileManagement(gateway, onBack = onBack, onSelected = onSelected, modifier = modifier)
}

/** The actual TV route is injectable for synthetic gateway / Compose remote tests without an account. */
@Composable
internal fun TvProfileManagement(
    gateway: TvProfileGateway,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
    onSelected: (ProfileSelectionRequest) -> Unit = {},
    startAdding: Boolean = false,
    startEditing: Boolean = false,
    returnAfterEditor: Boolean = false,
) {
    var refresh by remember { mutableStateOf(0) }
    val snapshot = gateway.read()
    var editing by remember { mutableStateOf<UserProfile?>(null) }
    var adding by remember { mutableStateOf(false) }
    var admission by remember { mutableStateOf<TvProfileGateway.Admission?>(null) }
    var pending by remember { mutableStateOf<Pair<UserProfile, TvProfileGateway.Admission>?>(null) }
    var message by remember { mutableStateOf<String?>(null) }
    var restoreKey by remember { mutableStateOf<String?>(null) }
    val listState = rememberLazyListState()
    val focus = remember { mutableMapOf<String, FocusRequester>() }
    fun requester(key: String) = focus.getOrPut(key) { FocusRequester() }

    fun edit(profile: UserProfile, isNew: Boolean) {
        val captured = gateway.capture(profile, adding = isNew)
        if (captured == null) { message = "The profile changed. Open it again before editing."; return }
        editing = profile; adding = isNew; admission = captured
        restoreKey = if (isNew) "add" else profile.id
    }
    fun add() = edit(UserProfile(name = "", avatar = "🎬", accentID = snapshot.profiles.find { it.id == snapshot.activeID }?.accentID ?: "ember"), true)
    fun finishEditor() {
        editing = null; admission = null; refresh++
        if (returnAfterEditor) onBack()
        else if (restoreKey != "add" && gateway.read().profiles.none { it.id == restoreKey }) restoreKey = gateway.read().activeID ?: "add"
    }
    fun select(profile: UserProfile, captured: TvProfileGateway.Admission) {
        gateway.select(profile, captured).fold(onSuccess = onSelected, onFailure = {
            message = "The profile changed. Open it again before switching."
        })
        pending = null; restoreKey = profile.id; refresh++
    }

    LaunchedEffect(Unit) {
        when {
            startAdding -> add()
            startEditing -> snapshot.profiles.find { it.id == snapshot.activeID }?.let { edit(it, false) }
            else -> restoreKey = snapshot.activeID ?: "add"
        }
    }
    // Reading refresh is intentional: ProfileStore has plain roster fields in comparison mode.
    @Suppress("UNUSED_VARIABLE") val redraw = refresh
    val original = editing
    if (original != null) {
        TvProfileEditor(gateway, original, adding, checkNotNull(admission), onDone = ::finishEditor, onBack = ::finishEditor, modifier = modifier)
        return
    }
    BackHandler(onBack = onBack)
    Box(modifier.fillMaxSize().background(VortXTheme.colors.canvas)) {
        LazyColumn(state = listState, modifier = Modifier.fillMaxSize().padding(TvDimens.edge).testTag("tv-profile-list"), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            item { Text("Profiles", style = VortXTheme.type.sectionTitle) }
            item { Text("Select a profile to switch. Select the active profile to edit it.", style = VortXTheme.type.label) }
            items(snapshot.profiles, key = { it.id }) { profile ->
                TvProfileButton(
                    label = "${profile.avatar}  ${profile.name.ifBlank { "Profile" }}",
                    detail = listOfNotNull(if (profile.id == snapshot.activeID) "Active · Edit" else "Switch profile", if (profile.isKids) "Kids" else null, if (profile.hasPin) "PIN set" else null).joinToString(" · "),
                    modifier = Modifier.focusRequester(requester(profile.id)).testTag("tv-profile-${profile.id}"),
                    onClick = {
                        if (profile.id == snapshot.activeID) edit(profile, false) else {
                            val captured = gateway.capture(profile, selection = true)
                            if (captured == null) message = "The profile changed. Open it again before switching."
                            else if (profile.hasPin) { restoreKey = profile.id; pending = profile to captured }
                            else select(profile, captured)
                        }
                    },
                )
            }
            item { TvProfileButton("Add profile", modifier = Modifier.focusRequester(requester("add")).testTag("tv-profile-add"), onClick = ::add) }
            message?.let { item { Text(it, style = VortXTheme.type.label.copy(color = VortXTheme.colors.danger)) } }
            item { TvProfileButton("Back", onClick = onBack) }
        }
        pending?.let { (profile, captured) ->
            TvWhosWatchingPinGate(profile, onUnlock = { select(profile, captured) }, onCancel = { pending = null; refresh++ })
        }
    }
    LaunchedEffect(restoreKey, refresh, pending) {
        if (pending != null) return@LaunchedEffect
        val key = restoreKey ?: return@LaunchedEffect
        val index = snapshot.profiles.indexOfFirst { it.id == key }
        listState.scrollToItem(if (key == "add") snapshot.profiles.size + 2 else (index.coerceAtLeast(0) + 2))
        withFrameNanos { }
        runCatching { requester(key).requestFocus() }
        restoreKey = null
    }
}

/** Remote controls use TV Surfaces; text fields open the platform keyboard, as TV Settings already does. */
@Composable
private fun TvProfileEditor(
    gateway: TvProfileGateway,
    original: UserProfile,
    adding: Boolean,
    admission: TvProfileGateway.Admission,
    onDone: () -> Unit,
    onBack: () -> Unit,
    modifier: Modifier,
) {
    var name by remember(original.id) { mutableStateOf(original.name) }
    var avatar by remember(original.id) { mutableStateOf(original.avatar) }
    var accent by remember(original.id) { mutableStateOf(original.accentID) }
    var oled by remember(original.id) { mutableStateOf(original.oled) }
    var kids by remember(original.id) { mutableStateOf(original.isKids) }
    var pin by remember(original.id) { mutableStateOf("") }
    var removePin by remember(original.id) { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var confirming by remember { mutableStateOf(false) }
    val nameFocus = remember { FocusRequester() }
    val deleteFocus = remember { FocusRequester() }
    val cancelFocus = remember { FocusRequester() }
    var restoreDeleteFocus by remember { mutableStateOf(false) }
    val list = rememberLazyListState()
    val canDelete = !adding && !original.isOwner && gateway.read().profiles.size > 1
    fun save() {
        var draft = original.copy(name = name.trim(), avatar = avatar, accentID = accent, oled = oled, isKids = !original.isOwner && kids)
        draft = when {
            removePin -> draft.copy(pin = null)
            pin.length == 4 -> draft.copy(pin = UserProfile.pinHash(pin, original.id))
            else -> draft
        }
        if (gateway.save(draft, adding, admission)) onDone()
        else error = "Changes could not be confirmed. Reopen this profile before trying again."
    }
    BackHandler { if (confirming) { confirming = false; restoreDeleteFocus = true } else onBack() }
    Box(modifier.fillMaxSize().background(VortXTheme.colors.canvas)) {
        if (!confirming) LazyColumn(state = list, modifier = Modifier.fillMaxSize().padding(TvDimens.edge).testTag("tv-profile-editor-list"), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            item { Text(if (adding) "New profile" else "Edit profile", style = VortXTheme.type.sectionTitle) }
            item {
                OutlinedTextField(name, { name = it }, label = { Text("Name") }, singleLine = true,
                    modifier = Modifier.fillMaxWidth().focusRequester(nameFocus).testTag("tv-profile-name"))
            }
            item {
                OutlinedTextField(avatar, { normalizeCustomAvatar(it)?.let { value -> avatar = value } }, label = { Text("Avatar · emoji or letter") }, singleLine = true,
                    modifier = Modifier.fillMaxWidth().testTag("tv-profile-avatar"))
            }
            item { Text("Accent", style = VortXTheme.type.cardTitle) }
            items(VortXAccents.curated, key = { it.id }) { option ->
                TvProfileButton(option.label, if (accent == option.id) "Selected" else null, onClick = { accent = option.id })
            }
            item { TvProfileButton("Background", if (oled) "OLED Black" else "Warm", onClick = { oled = !oled }) }
            if (!original.isOwner) item {
                TvProfileButton("Kids profile", if (kids) "On · hides adult and CAM/fake sources" else "Off", onClick = { kids = !kids })
            }
            item {
                TvProfileButton("Profile PIN", when { removePin -> "Removed on Save"; pin.isNotEmpty() -> "New PIN: ${"•".repeat(pin.length)}"; original.hasPin -> "Set · select digits below to replace"; else -> "No PIN · select four digits below" }, onClick = { pin = ""; removePin = false })
            }
            // Numeric TV buttons keep PIN entry independent of soft-keyboard availability.
            items(listOf("123", "456", "789", "0")) { digits ->
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    digits.forEach { digit -> TvProfileButton(digit.toString(), modifier = Modifier.weight(1f), onClick = { if (pin.length < 4) { pin += digit; removePin = false } }) }
                }
            }
            item { TvProfileButton("Delete PIN digit", onClick = { pin = pin.dropLast(1) }) }
            if (original.hasPin) item { TvProfileButton("Remove PIN", onClick = { removePin = true; pin = "" }) }
            item { Text("A new profile shares this account and keeps its own history. This editor keeps existing account bindings.", style = VortXTheme.type.label) }
            error?.let { item { Text(it, style = VortXTheme.type.label.copy(color = VortXTheme.colors.danger)) } }
            item { TvProfileButton("Save", enabled = name.trim().isNotEmpty() && (pin.isEmpty() || pin.length == 4), modifier = Modifier.testTag("tv-profile-save"), onClick = ::save) }
            if (canDelete) item {
                TvProfileButton("Delete profile", modifier = Modifier.focusRequester(deleteFocus).testTag("tv-profile-delete"), onClick = { confirming = true })
            } else if (!adding) item { Text("The main or last profile cannot be deleted.", style = VortXTheme.type.label) }
            item { TvProfileButton("Cancel", onClick = onBack) }
        }
        if (confirming) {
            Box(Modifier.fillMaxSize().background(VortXTheme.colors.canvas), contentAlignment = Alignment.Center) {
                Column(Modifier.widthIn(max = 560.dp).padding(24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                    Text("Delete ${original.name}?", style = VortXTheme.type.cardTitle, maxLines = 2, overflow = TextOverflow.Ellipsis)
                    Text("This removes this profile and its saved profile data. Your other profiles stay available.", style = VortXTheme.type.body)
                    TvProfileButton("Keep profile", modifier = Modifier.focusRequester(cancelFocus), onClick = { confirming = false; restoreDeleteFocus = true })
                    TvProfileButton("Confirm delete", modifier = Modifier.testTag("tv-profile-confirm-delete"), onClick = {
                        if (gateway.remove(original, admission)) onDone()
                        else { confirming = false; error = "Deletion could not be confirmed. Reopen this profile before trying again."; restoreDeleteFocus = true }
                    })
                }
            }
        }
    }
    LaunchedEffect(Unit) { withFrameNanos { }; runCatching { nameFocus.requestFocus() } }
    LaunchedEffect(confirming, restoreDeleteFocus) {
        withFrameNanos { }
        if (confirming) runCatching { cancelFocus.requestFocus() }
        else if (restoreDeleteFocus) { runCatching { deleteFocus.requestFocus() }; restoreDeleteFocus = false }
    }
}

@OptIn(ExperimentalTvMaterial3Api::class)
@Composable
internal fun TvProfileButton(label: String, detail: String? = null, enabled: Boolean = true, modifier: Modifier = Modifier, onClick: () -> Unit) {
    val colors = VortXTheme.colors
    Surface(onClick = onClick, enabled = enabled, modifier = modifier.fillMaxWidth(),
        shape = ClickableSurfaceDefaults.shape(shape = VortXShapes.control),
        colors = ClickableSurfaceDefaults.colors(containerColor = colors.surface1, contentColor = colors.textPrimary,
            focusedContainerColor = colors.surface3, focusedContentColor = colors.textPrimary),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1.02f),
        border = ClickableSurfaceDefaults.border(focusedBorder = Border(BorderStroke(2.dp, colors.accentBright), shape = VortXShapes.control))) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 14.dp)) {
            Text(label, style = VortXTheme.type.body, maxLines = 1, overflow = TextOverflow.Ellipsis)
            detail?.let { Text(it, style = VortXTheme.type.label.copy(color = colors.textSecondary), maxLines = 2, overflow = TextOverflow.Ellipsis) }
        }
    }
}
