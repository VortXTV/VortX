package com.vortx.android.ui.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.vortx.android.data.CatalogRepository
import com.vortx.android.data.AddonManagementSnapshot
import com.vortx.android.engine.AddonHealth
import com.vortx.android.engine.AddonHealthStore
import com.vortx.android.model.InstalledAddon
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
    private var managementSnapshot: AddonManagementSnapshot? = null
    private var managementGeneration = 0L
    private var visibilityOperation: Any? = null
    private val _loadingManagement = MutableStateFlow(true)
    val loadingManagement: StateFlow<Boolean> = _loadingManagement.asStateFlow()
    private val _changingVisibility = MutableStateFlow<String?>(null)
    val changingVisibility: StateFlow<String?> = _changingVisibility.asStateFlow()
    private val _visibilityMessages = MutableStateFlow<Map<String, String>>(emptyMap())
    val visibilityMessages: StateFlow<Map<String, String>> = _visibilityMessages.asStateFlow()

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
        val generation = ++managementGeneration
        // Retire the old row authority synchronously. A queued callback or old finally cannot clear a
        // successor's busy flag, report an error against its same-URL row, or target its selected profile.
        managementSnapshot = null
        visibilityOperation = null
        _changingVisibility.value = null
        _visibilityMessages.value = emptyMap()
        _loadingManagement.value = true
        viewModelScope.launch {
            if (showLoading) _state.value = UiState.Loading
            repo.addonManagementSnapshot().fold(
                onSuccess = { snapshot ->
                    val published = snapshot.publishIfCurrent {
                        if (generation == managementGeneration) {
                            managementSnapshot = snapshot
                            _state.value = UiState.Success(snapshot.addons)
                            _loadingManagement.value = false
                            probeHealth(snapshot.addons)
                        }
                    }
                    if (!published && generation == managementGeneration) {
                        // The account/profile changed while IO returned. Its ctx tick will load the
                        // successor; keep the stale rows non-interactive until that load arrives.
                        _state.value = UiState.Loading
                    }
                },
                onFailure = {
                    if (generation == managementGeneration) {
                        _state.value = UiState.Error("Couldn't load your add-ons. Try again.")
                        _loadingManagement.value = false
                    }
                },
            )
            if (generation == managementGeneration) everLoaded = true
        }
    }

    fun onUrlChange(value: String) {
        _urlInput.value = value
        _installMessage.value = null
    }

    /// The raw URL awaiting an Update-if-installed confirm, or null when no dialog is showing (SRC-8, Apple
    /// `AddonsView.showUpdateConfirm`). The screen renders a confirm dialog whenever this is non-null.
    private val _pendingUpdate = MutableStateFlow<String?>(null)
    val pendingUpdate: StateFlow<String?> = _pendingUpdate.asStateFlow()

    fun install() {
        val url = _urlInput.value.trim()
        if (url.isEmpty() || _installing.value) return
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
        if (normalized != null && installed.any { it.transportUrl == normalized }) {
            _pendingUpdate.value = url
            return
        }
        runInstall(url, replacingExisting = false)
    }

    /// Confirm the Update-if-installed dialog: re-install the pending URL and report "Updated." on success.
    fun confirmUpdate() {
        val url = _pendingUpdate.value ?: return
        _pendingUpdate.value = null
        runInstall(url, replacingExisting = true)
    }

    /// Dismiss the Update-if-installed dialog, leaving the add-on and the typed URL untouched.
    fun cancelUpdate() {
        _pendingUpdate.value = null
    }

    private fun runInstall(url: String, replacingExisting: Boolean) {
        if (_installing.value) return
        viewModelScope.launch {
            _installing.value = true
            repo.installAddon(url).fold(
                onSuccess = {
                    _installMessage.value = (if (replacingExisting) "Updated." else "Installed.") to false
                    _urlInput.value = ""
                    load()
                },
                onFailure = { _installMessage.value = (it.message ?: "Couldn't install that add-on.") to true },
            )
            _installing.value = false
        }
    }

    fun remove(addon: InstalledAddon) {
        viewModelScope.launch {
            repo.removeAddon(addon)
            load()
        }
    }

    /// The Change-URL sheet's live outcome, or null while it is idle. `first` = user-facing text,
    /// `second` = true when the swap FAILED (the sheet stays open so the user can correct the URL);
    /// a success clears it and the sheet dismisses. Mirrors Apple `EditAddonURLView.message`.
    private val _changeUrlMessage = MutableStateFlow<Pair<String, Boolean>?>(null)
    val changeUrlMessage: StateFlow<Pair<String, Boolean>?> = _changeUrlMessage.asStateFlow()

    private val _changingUrl = MutableStateFlow(false)
    val changingUrl: StateFlow<Boolean> = _changingUrl.asStateFlow()

    /// Signals the Change-URL sheet to dismiss after a successful swap. The screen collects this and
    /// closes its sheet; a plain incrementing token avoids a stale re-dismiss on recomposition.
    private val _changeUrlDone = MutableStateFlow(0)
    val changeUrlDone: StateFlow<Int> = _changeUrlDone.asStateFlow()

    fun onChangeUrlOpen() {
        _changeUrlMessage.value = null
    }

    /// Swap an installed add-on's manifest URL (Apple `EditAddonURLView.update`): install the new URL
    /// first, then drop the old without tombstoning. On success the sheet dismisses; on failure it stays
    /// open with the error so the user can fix the URL.
    fun changeAddonUrl(addon: InstalledAddon, newUrl: String) {
        val trimmed = newUrl.trim()
        if (trimmed.isEmpty() || _changingUrl.value) return
        _changingUrl.value = true
        _changeUrlMessage.value = null
        viewModelScope.launch {
            try {
                repo.changeAddonUrl(addon, trimmed).fold(
                    onSuccess = {
                        _changeUrlDone.value += 1
                        load()
                    },
                    onFailure = { _changeUrlMessage.value = (it.message ?: "Couldn't update that add-on.") to true },
                )
            } finally {
                _changingUrl.value = false
            }
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

    /// Change the profile that produced this row, retaining its original Session/revision through
    /// queued IO and acknowledgment. Disabled add-ons remain in management and installed state;
    /// only the profile's active catalog/source registry excludes them.
    fun toggleAddon(addon: InstalledAddon) {
        if (_loadingManagement.value || visibilityOperation != null) return
        val snapshot = managementSnapshot ?: return
        val generation = managementGeneration
        val operation = Any()
        var reserved = false
        snapshot.publishIfCurrent {
            if (snapshot === managementSnapshot && snapshot.addons.singleOrNull { it.transportUrl == addon.transportUrl } == addon) {
                visibilityOperation = operation
                _changingVisibility.value = addon.transportUrl
                _visibilityMessages.value = _visibilityMessages.value - addon.transportUrl
                reserved = true
            }
        }
        if (!reserved) { load(showLoading = false); return }
        viewModelScope.launch {
            fun isOriginalOperation() = visibilityOperation === operation && managementGeneration == generation && managementSnapshot === snapshot
            try {
                repo.setAddonVisibility(snapshot, addon, !addon.isDisabled).fold(
                    onSuccess = { acknowledged ->
                        if (isOriginalOperation()) {
                            val published = acknowledged.publishIfCurrent {
                                if (isOriginalOperation()) {
                                    managementSnapshot = acknowledged
                                    _state.value = UiState.Success(acknowledged.addons)
                                    probeHealth(acknowledged.addons)
                                }
                            }
                            if (!published && isOriginalOperation()) load(showLoading = false)
                        }
                    },
                    onFailure = {
                        val published = snapshot.publishIfCurrent {
                            if (isOriginalOperation()) {
                                _visibilityMessages.value = _visibilityMessages.value +
                                    (addon.transportUrl to "Couldn't change this add-on's visibility. Try again.")
                            }
                        }
                        if (!published && isOriginalOperation()) load(showLoading = false)
                    },
                )
            } finally {
                if (visibilityOperation === operation) {
                    visibilityOperation = null
                    _changingVisibility.value = null
                }
            }
        }
    }

    /// Persist a new add-on PRIORITY order from the reorder list's drop (Apple
    /// `AddonsView.swift:476 .onMove` -> `applyInAppAddonOrder`): each drop applies immediately, so
    /// leaving reorder mode needs no separate save step.
    fun applyOrder(transportUrls: List<String>) {
        viewModelScope.launch {
            repo.applyAddonOrder(transportUrls)
            load(showLoading = false)
        }
    }
}
