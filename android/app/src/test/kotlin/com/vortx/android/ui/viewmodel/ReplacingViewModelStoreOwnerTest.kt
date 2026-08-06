package com.vortx.android.ui.viewmodel

import androidx.lifecycle.ViewModel
import org.junit.Assert.assertTrue
import org.junit.Test

class ReplacingViewModelStoreOwnerTest {
    @Test
    fun `forgotten committed owner clears its model store`() {
        val owner = ReplacingViewModelStoreOwner()
        val current = TrackingViewModel()
        owner.viewModelStore.put("detail", current)

        owner.onForgotten()

        assertTrue(current.cleared)
        assertTrue(owner.viewModelStore.keys().isEmpty())
    }

    @Test
    fun `abandoned replacement owner clears work created before commit`() {
        val owner = ReplacingViewModelStoreOwner()
        val abandoned = TrackingViewModel()
        owner.viewModelStore.put("detail", abandoned)

        owner.onAbandoned()

        assertTrue(abandoned.cleared)
        assertTrue(owner.viewModelStore.keys().isEmpty())
    }

    private class TrackingViewModel : ViewModel() {
        var cleared = false
            private set

        override fun onCleared() {
            cleared = true
        }
    }
}
