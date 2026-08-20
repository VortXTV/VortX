package com.vortx.android.ui.viewmodel

import android.content.Context
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import com.vortx.android.data.AuthRepository
import com.vortx.android.data.CatalogRepository
import com.vortx.android.data.CatalogPreferencesStore
import com.vortx.android.data.PreviewAuthRepository
import com.vortx.android.home.HomeRailPreferences
import com.vortx.android.home.HomeRailSurface
import com.vortx.android.model.MediaType
import com.vortx.android.library.WatchlistStore
import com.vortx.android.home.SimklRailsModel
import com.vortx.android.home.TraktRailsModel
import com.vortx.android.home.ImportedCatalogs
import com.vortx.android.home.CollectionsHubModel
import com.vortx.android.home.CollectionsHubProviderPolicy
import com.vortx.android.integrations.ScrobbleService
import com.vortx.android.iptv.LiveViewModel
import com.vortx.android.search.SearchHistoryStore
import com.vortx.android.sync.VortXSyncManager

/// Constructor injection without a DI framework (KISS): a factory that hands the shared
/// [CatalogRepository]/[AuthRepository] seams to each ViewModel. When Hilt/Koin is introduced for the
/// engine, this is the one place that changes. [detailArgs] are supplied per detail page. [auth]
/// defaults to the offline preview so every existing call site (none of which touch account state)
/// keeps compiling unchanged; only the account screen passes a real one. [appContext] is required by
/// [SearchViewModel] (its [SearchHistoryStore] is plain-`SharedPreferences`-backed) and by
/// [DetailViewModel] (debrid keys + the source-list assembly's preference / pin stores); every other
/// ViewModel ignores it, so existing non-detail / non-search call sites are unaffected.
class StremioXViewModelFactory(
    private val repo: CatalogRepository,
    private val auth: AuthRepository = PreviewAuthRepository(),
    private val detailArgs: DetailArgs? = null,
    private val appContext: Context? = null,
    private val syncManager: VortXSyncManager? = null,
    private val homeSurface: HomeRailSurface = HomeRailSurface.PHONE,
) : ViewModelProvider.Factory {

    data class DetailArgs(val type: MediaType, val id: String)

    @Suppress("UNCHECKED_CAST")
    override fun <T : ViewModel> create(modelClass: Class<T>): T = when {
        modelClass.isAssignableFrom(HomeViewModel::class.java) -> HomeViewModel(
            repo = repo,
            railPreferences = appContext?.let(HomeRailPreferences::shared),
            railSurface = homeSurface,
            watchlistStore = appContext?.let(WatchlistStore::shared),
            traktRails = TraktRailsModel(),
            simklRails = SimklRailsModel(appContext?.also(ScrobbleService::init)),
            importedCatalogs = appContext?.let(ImportedCatalogs::shared),
            collectionsHub = appContext?.let { context ->
                CollectionsHubModel(
                    context = context,
                    tmdbCatalogSupported = {
                        repo.installedAddons().getOrNull()
                            ?.let(CollectionsHubProviderPolicy::supportsTmdbCatalogItems)
                            ?: false
                    },
                )
            },
        ) as T
        modelClass.isAssignableFrom(DiscoverViewModel::class.java) -> DiscoverViewModel(
            repo,
            appContext?.let(CatalogPreferencesStore::shared) ?: CatalogPreferencesStore.inMemory(),
        ) as T
        modelClass.isAssignableFrom(LibraryViewModel::class.java) -> LibraryViewModel(repo) as T
        modelClass.isAssignableFrom(LiveViewModel::class.java) -> LiveViewModel(repo) as T
        modelClass.isAssignableFrom(SearchViewModel::class.java) -> {
            val context = requireNotNull(appContext) { "SearchViewModel requires an app Context (for SearchHistoryStore)" }
            SearchViewModel(repo, SearchHistoryStore(context)) as T
        }
        modelClass.isAssignableFrom(AddonsViewModel::class.java) -> AddonsViewModel(repo) as T
        modelClass.isAssignableFrom(AddonStoreViewModel::class.java) -> AddonStoreViewModel(repo) as T
        modelClass.isAssignableFrom(AddonPairingViewModel::class.java) -> AddonPairingViewModel(repo) as T
        modelClass.isAssignableFrom(AccountViewModel::class.java) -> AccountViewModel(auth) as T
        modelClass.isAssignableFrom(VortXAccountViewModel::class.java) -> {
            // The app-process VortXSyncManager (VortXApplication.syncManager): the E2E VortX account +
            // cross-device sync engine. Only the VortX account screen asks for this ViewModel, and its
            // entry row is hidden when the manager could not be stood up, so this requireNotNull can
            // only trip on a wiring bug, not in normal use.
            val manager = requireNotNull(syncManager) { "VortXAccountViewModel requires the app VortXSyncManager" }
            VortXAccountViewModel(manager) as T
        }
        modelClass.isAssignableFrom(DetailViewModel::class.java) -> {
            val args = requireNotNull(detailArgs) { "DetailViewModel requires DetailArgs" }
            val context = requireNotNull(appContext) {
                "DetailViewModel requires an app Context (debrid keys + source-list assembly)"
            }
            DetailViewModel(repo, args.type, args.id, context) as T
        }
        else -> throw IllegalArgumentException("Unknown ViewModel: ${modelClass.name}")
    }
}
