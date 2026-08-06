package com.vortx.android.ui.viewmodel

import androidx.compose.runtime.Composable
import androidx.compose.runtime.RememberObserver
import androidx.compose.runtime.remember
import androidx.lifecycle.ViewModelStore
import androidx.lifecycle.ViewModelStoreOwner

/**
 * One bounded ViewModel store for one committed route generation. Compose forgets the old owner only after
 * the replacement composition commits, then [onForgotten] clears every stale model. [onAbandoned] also clears
 * a newly created owner if its composition never commits, so neither side of a retried composition leaks work.
 */
internal class ReplacingViewModelStoreOwner : ViewModelStoreOwner, RememberObserver {
    private val store = ViewModelStore()

    override val viewModelStore: ViewModelStore
        get() = store

    override fun onRemembered() = Unit

    override fun onForgotten() = clear()

    override fun onAbandoned() = clear()

    fun clear() {
        store.clear()
    }
}

/** Keep one route store alive across Detail -> Player while bounding it to the current source generation. */
@Composable
internal fun rememberReplacingViewModelStoreOwner(generation: String): ViewModelStoreOwner {
    return remember(generation) { ReplacingViewModelStoreOwner() }
}
