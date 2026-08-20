package com.vortx.android.ui.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.vortx.android.data.CatalogRepository
import com.vortx.android.data.CommunityAddonStore
import com.vortx.android.engine.AddonHealthStore
import com.vortx.android.model.StoreAddon
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

/// Discover add-ons (S04 "Add-on management", Apple `AddonStoreView`): a browsable, searchable store over
/// the official community collection, each entry carrying a LIVE health badge (through the same
/// [AddonHealthStore] the installed list uses) and a one-tap Install that goes through the engine, so the
/// new add-on syncs to the account and the official apps exactly like a pasted manifest URL. Already-
/// installed add-ons show as Installed.
@OptIn(FlowPreview::class)
class AddonStoreViewModel(
    private val repo: CatalogRepository,
    private val store: CommunityAddonStore = CommunityAddonStore(),
    private val healthStore: AddonHealthStore = AddonHealthStore(),
) : ViewModel() {
    sealed interface StoreState {
        data object Loading : StoreState
        data class Content(val addons: List<StoreAddon>) : StoreState
        /// Fetched nothing usable (network/parse failure) -- the screen offers a Try-again.
        data object Failed : StoreState
    }

    private val _state = MutableStateFlow<StoreState>(StoreState.Loading)
    val state: StateFlow<StoreState> = _state.asStateFlow()

    private val _query = MutableStateFlow("")
    val query: StateFlow<String> = _query.asStateFlow()

    /// Normalized transport URLs of the account's installed add-ons, refreshed live from ctx changes so a
    /// row flips to Installed the instant its install confirms.
    private val _installed = MutableStateFlow<Set<String>>(emptySet())
    val installed: StateFlow<Set<String>> = _installed.asStateFlow()

    /// Transport URLs whose install is in flight (the row shows "Installing…").
    private val _installing = MutableStateFlow<Set<String>>(emptySet())
    val installing: StateFlow<Set<String>> = _installing.asStateFlow()

    val health = healthStore.status

    /// The catalog filtered by the current query (name / summary / type substring, case-insensitive),
    /// mirroring Apple `AddonStoreView.filtered`.
    val filtered: StateFlow<List<StoreAddon>> =
        combine(state, query) { s, q -> filter(s, q) }
            .stateIn(viewModelScope, SharingStarted.Eagerly, emptyList())

    init {
        load()
        viewModelScope.launch {
            repo.ctxUpdates().collect { refreshInstalled() }
        }
        // Probe the visible (filtered) rows as the query settles. The health store rate-limits non-forced
        // bulk refreshes, so this cannot burst; the probe set is capped so a 200-entry catalog never floods.
        viewModelScope.launch {
            filtered.debounce(PROBE_DEBOUNCE_MILLIS).collect { rows ->
                val urls = rows.take(PROBE_WINDOW).map { it.transportUrl }
                if (urls.isNotEmpty()) healthStore.refresh(urls)
            }
        }
    }

    fun load() {
        _state.value = StoreState.Loading
        viewModelScope.launch {
            val fetched = store.fetch()
            _state.value = if (fetched.isEmpty()) StoreState.Failed else StoreState.Content(fetched)
        }
    }

    fun onQueryChange(value: String) {
        _query.value = value
    }

    /// Install a store add-on through the engine (Apple `AddonStoreView.installStore`). The installed set
    /// re-reads from ctx after the engine confirms, flipping this row to Installed.
    fun install(addon: StoreAddon) {
        if (addon.transportUrl in _installing.value) return
        _installing.value = _installing.value + addon.transportUrl
        viewModelScope.launch {
            repo.installAddon(addon.transportUrl)
            refreshInstalled()
            _installing.value = _installing.value - addon.transportUrl
        }
    }

    /// Whether [addon] is already installed, matched on the engine's normalized transport URL (the store
    /// often lists an un-suffixed URL). Mirrors Apple `AddonStoreView.normalizedManifestURL` compare.
    fun isInstalled(addon: StoreAddon): Boolean =
        normalize(addon.transportUrl) in _installed.value

    private fun normalize(raw: String): String =
        repo.normalizedAddonUrl(raw) ?: run {
            val trimmed = raw.trim()
            if (trimmed.lowercase().endsWith("manifest.json")) trimmed else trimmed.trimEnd('/') + "/manifest.json"
        }

    private suspend fun refreshInstalled() {
        val addons = repo.installedAddons().getOrNull().orEmpty()
        _installed.value = addons.map { normalize(it.transportUrl) }.toSet()
    }

    private fun filter(state: StoreState, query: String): List<StoreAddon> {
        val all = (state as? StoreState.Content)?.addons ?: return emptyList()
        val q = query.trim().lowercase()
        if (q.isEmpty()) return all
        return all.filter { addon ->
            addon.name.lowercase().contains(q) ||
                addon.summary.lowercase().contains(q) ||
                addon.types.any { it.lowercase().contains(q) }
        }
    }

    private companion object {
        const val PROBE_WINDOW = 60
        const val PROBE_DEBOUNCE_MILLIS = 250L
    }
}
