package com.vortx.android.ui.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.vortx.android.data.CatalogRepository
import com.vortx.android.model.InstalledAddon
import com.vortx.android.ui.UiState
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/// Add-on management (S04, DESIGN-SYSTEM.md §4 "Add-ons"): the installed list read live from
/// `ctx.profile.addons`, install-by-URL, and remove. Mirrors Apple `AddonsView`'s core loop (health
/// probing, QR pairing, drag-reorder, and the add-on catalog/store browser are NOT ported -- the engine
/// exposes no add-on-catalog model to browse against, see the S04 handoff report).
class AddonsViewModel(private val repo: CatalogRepository) : ViewModel() {
    private val _state = MutableStateFlow<UiState<List<InstalledAddon>>>(UiState.Loading)
    val state: StateFlow<UiState<List<InstalledAddon>>> = _state.asStateFlow()

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

    private var everLoaded = false

    /// Group-1 reactivity (see [CatalogRepository.ctxUpdates]): re-reads the installed list on every
    /// ctx change (an install/remove from this screen, but also a sign-in pulling in the account's own
    /// add-ons), not just this ViewModel's own [install]/[remove] actions -- so a sign-in that happens
    /// while this screen is open shows the account's add-ons live instead of needing a restart. The
    /// FIRST tick (fired immediately, see [CatalogRepository.ctxUpdates]) is the screen's normal
    /// entry-point load, replacing the old `init { load() }`.
    init {
        viewModelScope.launch {
            repo.ctxUpdates().collect { load(showLoading = !everLoaded) }
        }
    }

    fun load(showLoading: Boolean = true) {
        viewModelScope.launch {
            if (showLoading) _state.value = UiState.Loading
            repo.installedAddons().fold(
                onSuccess = { _state.value = UiState.Success(it) },
                onFailure = { _state.value = UiState.Error(it.message ?: "Couldn't load your add-ons.") },
            )
            everLoaded = true
        }
    }

    fun onUrlChange(value: String) {
        _urlInput.value = value
        _installMessage.value = null
    }

    fun install() {
        val url = _urlInput.value.trim()
        if (url.isEmpty() || _installing.value) return
        viewModelScope.launch {
            _installing.value = true
            repo.installAddon(url).fold(
                onSuccess = {
                    _installMessage.value = "Installed." to false
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
}
