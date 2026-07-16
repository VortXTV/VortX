package com.vortx.android.ui.viewmodel

import android.content.Context
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import com.vortx.android.data.AuthRepository
import com.vortx.android.data.CatalogRepository
import com.vortx.android.data.PreviewAuthRepository
import com.vortx.android.model.MediaType
import com.vortx.android.search.SearchHistoryStore

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
) : ViewModelProvider.Factory {

    data class DetailArgs(val type: MediaType, val id: String)

    @Suppress("UNCHECKED_CAST")
    override fun <T : ViewModel> create(modelClass: Class<T>): T = when {
        modelClass.isAssignableFrom(HomeViewModel::class.java) -> HomeViewModel(repo) as T
        modelClass.isAssignableFrom(DiscoverViewModel::class.java) -> DiscoverViewModel(repo) as T
        modelClass.isAssignableFrom(LibraryViewModel::class.java) -> LibraryViewModel(repo) as T
        modelClass.isAssignableFrom(SearchViewModel::class.java) -> {
            val context = requireNotNull(appContext) { "SearchViewModel requires an app Context (for SearchHistoryStore)" }
            SearchViewModel(repo, SearchHistoryStore(context)) as T
        }
        modelClass.isAssignableFrom(AddonsViewModel::class.java) -> AddonsViewModel(repo) as T
        modelClass.isAssignableFrom(AccountViewModel::class.java) -> AccountViewModel(auth) as T
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
