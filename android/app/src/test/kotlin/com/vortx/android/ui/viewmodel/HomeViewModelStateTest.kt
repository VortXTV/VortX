package com.vortx.android.ui.viewmodel

import com.vortx.android.data.HomeUpdate
import com.vortx.android.home.TraktContinueWatchingReceipt
import com.vortx.android.model.Catalog
import com.vortx.android.ui.UiState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class HomeViewModelStateTest {
    @Test
    fun `delayed account A Trakt result awaiting other rails is rejected under account B`() {
        val accountA = TraktContinueWatchingReceipt(sessionEpoch = 41L, toggleRevision = 7L)

        assertEquals(
            false,
            isTraktContinueWatchingReceiptCurrent(
                receipt = accountA,
                currentSessionEpoch = 42L,
                currentToggleRevision = 7L,
                currentlyEnabled = true,
            ),
        )
        assertEquals(
            false,
            isTraktContinueWatchingReceiptCurrent(
                receipt = accountA,
                currentSessionEpoch = 41L,
                currentToggleRevision = 8L,
                currentlyEnabled = true,
            ),
        )
        assertEquals(
            false,
            isTraktContinueWatchingReceiptCurrent(
                receipt = accountA,
                currentSessionEpoch = 41L,
                currentToggleRevision = 7L,
                currentlyEnabled = false,
            ),
        )
    }

    @Test
    fun `initial empty heartbeat stays loading`() {
        assertNull(HomeUpdateReducer().reduce(HomeUpdate(rows = emptyList())))
    }

    @Test
    fun `privacy-transition empty snapshot authoritatively clears prior account rows`() {
        val reducer = HomeUpdateReducer()
        assertEquals(
            UiState.Success(emptyList<Catalog>()),
            reducer.reduce(
                HomeUpdate(
                    rows = emptyList(),
                    generation = 2,
                    sequence = 1,
                    profileId = "profile-b",
                    authoritative = true,
                ),
            ),
        )
    }

    @Test
    fun `old rows and an ordered empty heartbeat cannot undo the latest clear`() {
        val reducer = HomeUpdateReducer()
        val oldRows = listOf(Catalog(id = "old", title = "Old account", items = emptyList()))

        assertEquals(
            UiState.Success(oldRows),
            reducer.reduce(HomeUpdate(oldRows, generation = 1, sequence = 1, profileId = "profile-a")),
        )
        assertEquals(
            UiState.Success(emptyList<Catalog>()),
            reducer.reduce(
                HomeUpdate(
                    rows = emptyList(),
                    generation = 2,
                    sequence = 2,
                    profileId = "profile-b",
                    authoritative = true,
                ),
            ),
        )
        assertNull(
            reducer.reduce(HomeUpdate(oldRows, generation = 1, sequence = 3, profileId = "profile-a")),
        )
        assertNull(
            reducer.reduce(HomeUpdate(emptyList(), generation = 2, sequence = 3, profileId = "profile-b")),
        )
    }
}
