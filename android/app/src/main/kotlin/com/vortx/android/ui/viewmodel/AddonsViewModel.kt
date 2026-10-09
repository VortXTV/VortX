package com.vortx.android.ui.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.vortx.android.data.CatalogRepository
import com.vortx.android.data.AddonManagementTarget
import com.vortx.android.data.ContinueWatchingOwner
import com.vortx.android.data.requireCurrentAddonTarget
import com.vortx.android.engine.AddonHealth
import com.vortx.android.engine.AddonHealthStore
import com.vortx.android.model.InstalledAddon
import com.vortx.android.model.AddonOrder
import com.vortx.android.ui.UiState
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch

/// Add-on management (S04, DESIGN-SYSTEM.md §4 "Add-ons"): the installed list read live from
/// `ctx.profile.addons`, install-by-URL, remove, and bounded manifest health probes. QR pairing and
/// the add-on catalog/store browser remain separate parity work.
class AddonsViewModel(
    private val repo: CatalogRepository,
    private val healthStore: AddonHealthStore = AddonHealthStore(),
) : ViewModel() {
    private val _state = MutableStateFlow<UiState<List<InstalledAddon>>>(UiState.Loading)
    val state: StateFlow<UiState<List<InstalledAddon>>> = _state.asStateFlow()
    private val _managementAccess = MutableStateFlow(repo.addonManagementAccess())
    val managementAccess = _managementAccess.asStateFlow()
    private var loadedOwner: ContinueWatchingOwner? = null
    private var loadGeneration = 0L
    private val _mutating = MutableStateFlow(false)
    val mutating = _mutating.asStateFlow()
    private val _actionMessage = MutableStateFlow<Pair<String, Boolean>?>(null)
    val actionMessage = _actionMessage.asStateFlow()
    private val _removeDone = MutableStateFlow(0)
    val removeDone = _removeDone.asStateFlow()

    val health = healthStore.status

    /// The install-by-URL form's live value, so the screen can be a thin render of ViewModel state
    /// (same shape as [com.vortx.android.ui.viewmodel.SearchViewModel.query]).
    private val _urlInput = MutableStateFlow("")
    val urlInput: StateFlow<String> = _urlInput.asStateFlow()

    private val _installing = MutableStateFlow(false)
    val installing: StateFlow<Boolean> = _installing.asStateFlow()

    /// Last install attempt's user-facing outcome (mirrors Apple `installMessage`/`installFailed`).
    /// `null` = no message shown; `first` = the text, `second` = true if it was a failure.
    private val _installMessage = MutableStateFlow<Pair<String, Boolean>?>(null)
    val installMessage: StateFlow<Pair<String, Boolean>?> = _installMessage.asStateFlow()

    private val healthRefreshRequests = MutableSharedFlow<HealthRefreshRequest>(
        replay = 1,
        onBufferOverflow = BufferOverflow.DROP_OLDEST,
    )
    private var lastHealthUrls: List<String>? = null
    private var pendingHealthUrls: List<String>? = null
    private var activeHealthUrls: List<String>? = null
    private var everLoaded = false

    /** The raw URL awaiting explicit Update confirmation, with its original item/owner beside it. */
    private val _pendingUpdate = MutableStateFlow<String?>(null)
    val pendingUpdate: StateFlow<String?> = _pendingUpdate.asStateFlow()
    private var pendingUpdateTarget: AddonManagementTarget? = null
    /** Failed replacement keeps the dialog open; successful replacement advances the done token. */
    private val _changeUrlMessage = MutableStateFlow<Pair<String, Boolean>?>(null)
    val changeUrlMessage: StateFlow<Pair<String, Boolean>?> = _changeUrlMessage.asStateFlow()
    private val _changingUrl = MutableStateFlow(false)
    val changingUrl: StateFlow<Boolean> = _changingUrl.asStateFlow()
    private val _changeUrlDone = MutableStateFlow(0)
    val changeUrlDone: StateFlow<Int> = _changeUrlDone.asStateFlow()
    private var changeUrlOwner: ContinueWatchingOwner? = null

    /// Group-1 reactivity (see [CatalogRepository.ctxUpdates]): re-reads the installed list on every
    /// ctx change (an install/remove from this screen, but also a sign-in pulling in the account's own
    /// add-ons), not just this ViewModel's own [install]/[remove] actions -- so a sign-in that happens
    /// while this screen is open shows the account's add-ons live instead of needing a restart. The
    /// FIRST tick (fired immediately, see [CatalogRepository.ctxUpdates]) is the screen's normal
    /// entry-point load, replacing the old `init { load() }`.
    init {
        viewModelScope.launch {
            healthRefreshRequests.collectLatest { request ->
                if (pendingHealthUrls == request.urls) pendingHealthUrls = null
                activeHealthUrls = request.urls
                try {
                    when {
                        request.urls.isEmpty() -> healthStore.refresh(emptyList())
                        request.force -> healthStore.refresh(request.urls, force = true)
                        !request.retryWhenRateLimited -> healthStore.refresh(request.urls)
                        else -> while (!healthStore.refresh(request.urls)) {
                            delay(healthStore.bulkRetryDelayMillis().coerceAtLeast(1L))
                        }
                    }
                } finally {
                    if (activeHealthUrls == request.urls) activeHealthUrls = null
                }
            }
        }
        viewModelScope.launch {
            repo.ctxUpdates().collect { load(showLoading = !everLoaded) }
        }
    }

    fun load(showLoading: Boolean = true) {
        val generation = ++loadGeneration
        val access = repo.addonManagementAccess()
        if (_managementAccess.value.owner != access.owner) {
            cancelUpdate()
            _installMessage.value = null
            _changeUrlMessage.value = null
            _actionMessage.value = null
            loadedOwner = null
            _state.value = UiState.Loading
        }
        _managementAccess.value = access
        viewModelScope.launch {
            if (showLoading) _state.value = UiState.Loading
            val result = repo.installedAddons()
            if (generation != loadGeneration || repo.continueWatchingOwner() != access.owner) return@launch
            result.fold(
                onSuccess = {
                    loadedOwner = access.owner
                    _state.value = UiState.Success(it)
                    probeHealth(it)
                },
                onFailure = { _state.value = UiState.Error(it.message ?: "Couldn't load your add-ons.") },
            )
            everLoaded = true
        }
    }

    fun onUrlChange(value: String) {
        _urlInput.value = value
        _installMessage.value = null
    }

    /** Snapshot the rendered item and full native/account/profile token before opening a dialog. */
    fun captureManagementTarget(
        addon: InstalledAddon? = null,
        expectedRenderedOwner: ContinueWatchingOwner? = null,
    ): AddonManagementTarget? {
        val owner = loadedOwner
        val installed = (_state.value as? UiState.Success)?.data
        if (owner == null || installed == null || owner != repo.continueWatchingOwner() ||
            (expectedRenderedOwner != null && owner != expectedRenderedOwner)) {
            _actionMessage.value = "Add-on account or profile changed. Reload installed add-ons." to true
            load(showLoading = false)
            return null
        }
        val target = AddonManagementTarget(owner, addon)
        if (runCatching { requireCurrentAddonTarget(target, repo.continueWatchingOwner(), installed) }.isFailure) {
            _actionMessage.value = "Add-on changed or was removed. Reload installed add-ons." to true
            load(showLoading = false)
            return null
        }
        return target
    }

    private fun current(target: AddonManagementTarget): Boolean = runCatching {
        requireCurrentAddonTarget(target, repo.continueWatchingOwner(), (_state.value as? UiState.Success)?.data.orEmpty())
    }.isSuccess

    private fun acceptReceipt(receipt: ContinueWatchingOwner): Boolean {
        val access = repo.addonManagementAccess()
        if (access.owner != receipt) return false
        _managementAccess.value = access
        return true
    }

    fun install() = installForOwner(null)

    fun install(expectedRenderedOwner: ContinueWatchingOwner) = installForOwner(expectedRenderedOwner)

    private fun installForOwner(expectedRenderedOwner: ContinueWatchingOwner?) {
        val url = _urlInput.value.trim()
        if (url.isEmpty() || _mutating.value) return
        val target = captureManagementTarget(expectedRenderedOwner = expectedRenderedOwner) ?: return
        if (!_managementAccess.value.canManageInstalled) {
            _installMessage.value = (_managementAccess.value.reason ?: "Change installed add-ons from the owner profile.") to true
            return
        }
        // A pasted /configure PAGE is not an installable manifest (it mints a per-user manifest only after
        // sign-in + debrid key). Guide the user to finish configuration rather than installing a dead copy
        // (Apple `AddonsView.install`'s Beta 17 guard). The repository repeats this as a backstop; here it
        // also avoids the wasted fetch and the misleading Update prompt.
        if (com.vortx.android.engine.AddonConfiguration.isConfigurationPageUrl(url)) {
            _installMessage.value = com.vortx.android.engine.AddonConfiguration.NEEDS_CONFIGURATION_MESSAGE to true
            return
        }
        // Already installed? Offer to UPDATE (re-fetch the manifest) instead of a silent re-install (SRC-8,
        // Apple `AddonsView.install`). Match on the engine's normalized transport URL, the exact key the
        // installed list carries. A repository that does not normalize (the offline preview) returns null and
        // simply installs, byte-identical to the previous behavior.
        val normalized = repo.normalizedAddonUrl(url)
        val installed = (state.value as? UiState.Success)?.data.orEmpty()
        val existing = normalized?.let { key -> installed.singleOrNull { AddonOrder.normalize(it.transportUrl) == AddonOrder.normalize(key) } }
        if (existing != null) {
            pendingUpdateTarget = target.copy(addon = existing)
            _pendingUpdate.value = url
            return
        }
        runInstall(url, target, replacingExisting = false)
    }

    /// Confirm the Update-if-installed dialog: re-install the pending URL and report "Updated." on success.
    fun confirmUpdate() {
        val url = _pendingUpdate.value ?: return
        val target = pendingUpdateTarget ?: return
        _pendingUpdate.value = null
        pendingUpdateTarget = null
        runInstall(url, target, replacingExisting = true)
    }

    /// Dismiss the Update-if-installed dialog, leaving the add-on and the typed URL untouched.
    fun cancelUpdate() {
        _pendingUpdate.value = null
        pendingUpdateTarget = null
    }

    private fun runInstall(url: String, target: AddonManagementTarget, replacingExisting: Boolean) {
        if (_mutating.value) return
        if (!current(target)) {
            _installMessage.value = "Add-on changed or was removed. Reopen Update." to true
            load(showLoading = false)
            return
        }
        _mutating.value = true
        _installing.value = true
        viewModelScope.launch {
            try { repo.installAddon(url, target).fold(
                onSuccess = { receipt -> if (acceptReceipt(receipt)) {
                    _installMessage.value = (if (replacingExisting) "Updated." else "Installed.") to false
                    if (_urlInput.value.trim() == url) _urlInput.value = ""
                    load(showLoading = false)
                } },
                onFailure = { if (repo.continueWatchingOwner() == target.owner) _installMessage.value = (it.message ?: "Couldn't install that add-on.") to true },
            ) } finally { _installing.value = false; _mutating.value = false }
        }
    }

    fun remove(addon: InstalledAddon) {
        captureManagementTarget(addon)?.let(::remove)
    }

    fun onRemoveOpen() { _actionMessage.value = null }

    fun remove(target: AddonManagementTarget) {
        if (_mutating.value) return
        _mutating.value = true
        _actionMessage.value = null
        viewModelScope.launch {
            try { repo.removeAddon(target).fold(
                onSuccess = { receipt -> if (acceptReceipt(receipt)) {
                    _actionMessage.value = "Removed." to false
                    _removeDone.value += 1
                    load(showLoading = false)
                } },
                onFailure = { if (repo.continueWatchingOwner() == target.owner) _actionMessage.value = (it.message ?: "Couldn't remove that add-on.") to true },
            ) } finally { _mutating.value = false }
        }
    }

    fun onChangeUrlOpen() {
        changeUrlOwner = loadedOwner
        _changeUrlMessage.value = null
    }

    fun onChangeUrlOpen(target: AddonManagementTarget) {
        changeUrlOwner = target.owner
        _changeUrlMessage.value = null
    }

    /// Swap an installed add-on's manifest URL (Apple `EditAddonURLView.update`): install the new URL
    /// first, then drop the old without tombstoning. On success the sheet dismisses; on failure it stays
    /// open with the error so the user can fix the URL.
    fun changeAddonUrl(addon: InstalledAddon, newUrl: String) {
        val owner = changeUrlOwner ?: loadedOwner ?: return
        changeAddonUrl(AddonManagementTarget(owner, addon), newUrl)
    }

    fun changeAddonUrl(target: AddonManagementTarget, newUrl: String) {
        val addon = target.addon ?: return
        val trimmed = newUrl.trim()
        if (trimmed.isEmpty() || trimmed == addon.transportUrl || _mutating.value) return
        _mutating.value = true
        _changingUrl.value = true
        _changeUrlMessage.value = null
        viewModelScope.launch {
            try { repo.changeAddonUrl(target, trimmed).fold(
                onSuccess = { receipt -> if (acceptReceipt(receipt)) {
                    _changeUrlDone.value += 1
                    load(showLoading = false)
                } },
                onFailure = { if (repo.continueWatchingOwner() == target.owner) _changeUrlMessage.value = (it.message ?: "Couldn't change that add-on's URL.") to true },
            ) } finally { _changingUrl.value = false; _mutating.value = false }
        }
    }

    /** The visible Re-check action bypasses the store's bulk rate limit. */
    fun recheckHealth() {
        val addons = (state.value as? UiState.Success)?.data.orEmpty()
        val urls = normalizedHealthUrls(addons)
        if (urls.isEmpty()) return
        lastHealthUrls = urls
        emitHealthRefresh(HealthRefreshRequest(urls = urls, force = true))
    }

    /** A screen visit requests fresh truth without bypassing or waiting out the bulk limiter. */
    fun onScreenEntry() {
        val addons = (state.value as? UiState.Success)?.data.orEmpty()
        val urls = normalizedHealthUrls(addons)
        if (urls.isEmpty()) return
        val checking = healthStore.status.value
        if (
            urls == pendingHealthUrls ||
            urls == activeHealthUrls ||
            urls.any { checking[it] == AddonHealth.Checking }
        ) {
            return
        }
        emitHealthRefresh(
            HealthRefreshRequest(
                urls = urls,
                force = false,
                retryWhenRateLimited = false,
            ),
        )
    }

    private fun probeHealth(addons: List<InstalledAddon>) {
        val urls = normalizedHealthUrls(addons)
        if (urls == lastHealthUrls) return
        lastHealthUrls = urls
        emitHealthRefresh(
            HealthRefreshRequest(
                urls = urls,
                force = false,
                retryWhenRateLimited = true,
            ),
        )
    }

    private fun emitHealthRefresh(request: HealthRefreshRequest) {
        pendingHealthUrls = request.urls
        if (!healthRefreshRequests.tryEmit(request) && pendingHealthUrls == request.urls) {
            pendingHealthUrls = null
        }
    }

    private fun normalizedHealthUrls(addons: List<InstalledAddon>): List<String> = addons
        .mapNotNull { AddonHealthStore.normalizeUrl(it.transportUrl) }
        .distinct()
        .sorted()

    private data class HealthRefreshRequest(
        val urls: List<String>,
        val force: Boolean,
        val retryWhenRateLimited: Boolean = false,
    )

    /// Flip an add-on on/off for the ACTIVE profile (the row's eye toggle, Apple
    /// `AddonsView.swift:424` -> `profiles.toggleAddon`). A local per-profile overlay, never an
    /// engine/account change; the repository excludes disabled add-ons from Home rows + source
    /// groups. The silent reload re-stamps [InstalledAddon.isDisabled] so the icon flips at once.
    fun toggleAddon(addon: InstalledAddon) = toggleAddonForOwner(addon, null)

    fun toggleAddon(addon: InstalledAddon, expectedRenderedOwner: ContinueWatchingOwner) =
        toggleAddonForOwner(addon, expectedRenderedOwner)

    private fun toggleAddonForOwner(addon: InstalledAddon, expectedRenderedOwner: ContinueWatchingOwner?) {
        if (_mutating.value) return
        val target = captureManagementTarget(addon, expectedRenderedOwner) ?: return
        _mutating.value = true
        viewModelScope.launch {
            try { repo.setAddonDisabled(target, !addon.isDisabled).fold(
                onSuccess = { receipt -> if (acceptReceipt(receipt)) load(showLoading = false) },
                onFailure = { if (repo.continueWatchingOwner() == target.owner) _actionMessage.value = (it.message ?: "Couldn't change visibility.") to true },
            ) } finally { _mutating.value = false }
        }
    }

    /// Persist a new add-on PRIORITY order from the reorder list's drop (Apple
    /// `AddonsView.swift:476 .onMove` -> `applyInAppAddonOrder`): each drop applies immediately, so
    /// leaving reorder mode needs no separate save step.
    fun applyOrder(transportUrls: List<String>) = applyOrderForOwner(transportUrls, null)

    fun applyOrder(transportUrls: List<String>, expectedRenderedOwner: ContinueWatchingOwner) =
        applyOrderForOwner(transportUrls, expectedRenderedOwner)

    private fun applyOrderForOwner(transportUrls: List<String>, expectedRenderedOwner: ContinueWatchingOwner?) {
        if (_mutating.value) return
        val target = captureManagementTarget(expectedRenderedOwner = expectedRenderedOwner) ?: return
        _mutating.value = true
        viewModelScope.launch {
            try { repo.applyAddonOrder(target, transportUrls).fold(
                onSuccess = { receipt -> if (acceptReceipt(receipt)) load(showLoading = false) },
                onFailure = { if (repo.continueWatchingOwner() == target.owner) _actionMessage.value = (it.message ?: "Couldn't change priority.") to true },
            ) } finally { _mutating.value = false }
        }
    }
}
