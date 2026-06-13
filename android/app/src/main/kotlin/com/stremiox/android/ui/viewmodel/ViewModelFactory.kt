package com.stremiox.android.ui.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import com.stremiox.android.data.CatalogRepository
import com.stremiox.android.model.MediaType

/// Constructor injection without a DI framework (KISS): a factory that hands the single
/// [CatalogRepository] seam to each ViewModel. When Hilt/Koin is introduced for the engine, this is
/// the one place that changes. [detailArgs] are supplied per detail page.
class StremioXViewModelFactory(
    private val repo: CatalogRepository,
    private val detailArgs: DetailArgs? = null,
) : ViewModelProvider.Factory {

    data class DetailArgs(val type: MediaType, val id: String)

    @Suppress("UNCHECKED_CAST")
    override fun <T : ViewModel> create(modelClass: Class<T>): T = when {
        modelClass.isAssignableFrom(HomeViewModel::class.java) -> HomeViewModel(repo) as T
        modelClass.isAssignableFrom(DiscoverViewModel::class.java) -> DiscoverViewModel(repo) as T
        modelClass.isAssignableFrom(LibraryViewModel::class.java) -> LibraryViewModel(repo) as T
        modelClass.isAssignableFrom(SearchViewModel::class.java) -> SearchViewModel(repo) as T
        modelClass.isAssignableFrom(DetailViewModel::class.java) -> {
            val args = requireNotNull(detailArgs) { "DetailViewModel requires DetailArgs" }
            DetailViewModel(repo, args.type, args.id) as T
        }
        else -> throw IllegalArgumentException("Unknown ViewModel: ${modelClass.name}")
    }
}
