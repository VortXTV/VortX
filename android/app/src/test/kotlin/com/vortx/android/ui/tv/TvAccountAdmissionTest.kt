package com.vortx.android.ui.tv

import com.vortx.android.model.AuthState
import com.vortx.android.sync.VortXSyncManager
import org.junit.Assert.*
import org.junit.Test

class TvAccountAdmissionTest {
    @Test fun `native VortX-only account admits TV discovery and search`() {
        val native = VortXSyncManager.SessionUiState.SignedIn(VortXSyncManager.Account("fixture", "test@example.invalid", "Test", false))
        assertTrue(tvBrowseSignedIn(AuthState.SignedOut, native))
        assertTrue(tvBrowseSignedIn(AuthState.SignedIn(null, "streaming"), null))
    }
    @Test fun `signed out and unavailable secure sessions never admit a guest`() {
        for (session in listOf(null, VortXSyncManager.SessionUiState.SignedOut, VortXSyncManager.SessionUiState.UnknownOrUnavailable)) {
            assertFalse(tvBrowseSignedIn(AuthState.SignedOut, session))
        }
    }
    @Test fun `profiles and backup routes return to settings without exiting the shell`() {
        assertEquals(TvSettingsRoute.ROOT, TvSettingsRoute.PROFILES.back())
        assertEquals(TvSettingsRoute.ROOT, TvSettingsRoute.BACKUP.back())
        assertEquals(TvSettingsRoute.ADDONS, TvSettingsRoute.ADDON_STORE.back())
    }
}
