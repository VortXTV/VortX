package com.vortx.android.ui.foryou

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.vortx.android.VortXApplication
import com.vortx.android.foryou.ForYouRowsModel
import com.vortx.android.foryou.ForYouState
import com.vortx.android.foryou.ForYouStore
import com.vortx.android.foryou.SmartCollection
import com.vortx.android.model.MetaItem

/** The Library screen's view of smart collections: the store state, each collection's titles (cached
 * by rules, so renaming or pinning never refetches) and the library's watched titles. */
class SmartCollectionsScreenState(
    val store: ForYouState,
    val titles: Map<String, List<MetaItem>>,
    val loading: Set<String>,
    val watched: Set<String>,
) {
    fun visible(collection: SmartCollection): List<MetaItem> {
        val raw = titles[ForYouRowsModel.rawKey(collection)].orEmpty()
        return if (collection.rules.hideWatched) raw.filterNot { it.id in watched } else raw
    }
}

@Composable
fun rememberSmartCollectionsState(): SmartCollectionsScreenState {
    val context = LocalContext.current
    val store by ForYouStore.shared(context).state.collectAsStateWithLifecycle()
    val titles = remember { mutableStateMapOf<String, List<MetaItem>>() }
    var loading by remember { mutableStateOf(emptySet<String>()) }
    var watched by remember { mutableStateOf(emptySet<String>()) }
    LaunchedEffect(Unit) {
        val repository = (context.applicationContext as? VortXApplication)?.catalogRepository ?: return@LaunchedEffect
        watched = repository.library().getOrNull()?.items.orEmpty().filter { it.watched }.mapTo(hashSetOf()) { it.id }
    }
    LaunchedEffect(store.collections) {
        val missing = store.collections.filter { ForYouRowsModel.rawKey(it) !in titles }
        loading = missing.mapTo(hashSetOf()) { it.id }
        for (collection in missing) {
            titles[ForYouRowsModel.rawKey(collection)] = ForYouRowsModel.titles(collection.rules)
            loading = loading - collection.id
        }
    }
    return SmartCollectionsScreenState(store, titles, loading, watched)
}
