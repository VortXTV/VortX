package com.vortx.android.profile

import org.junit.Assert.assertEquals
import org.junit.Test

class PlaylistScopeTransitionTest {
    private fun witness(
        selectedID: String? = "MAIN",
        profileID: String? = "MAIN",
        accountSlot: String = "primary",
        usesEngineHistory: Boolean = true,
        accountID: String? = "account-a",
        accountGeneration: Long? = 4L,
        credentialEpoch: Long? = 9L,
    ) = PlaylistScopeEvidence(selectedID, profileID, accountSlot, usesEngineHistory,
        accountID, accountGeneration, credentialEpoch)

    @Test fun sameBindingAccountAndCredentialTreatMetadataOrSettingsRefreshAsProjection() {
        assertEquals(PlaylistScopeTransition.PROJECTION_REFRESH,
            playlistScopeTransition(witness(), witness()))
    }

    @Test fun selectedProfileOrHistoryBindingChangeRetiresPlaylistAuthority() {
        assertEquals(PlaylistScopeTransition.AUTHORITY_BOUNDARY,
            playlistScopeTransition(witness(), witness(selectedID = "CHILD", profileID = "CHILD", accountSlot = "primary.CHILD", usesEngineHistory = false)))
    }

    @Test fun accountGenerationAndCredentialEpochChangesRetireEvenWhenProfileIsSame() {
        assertEquals(PlaylistScopeTransition.AUTHORITY_BOUNDARY,
            playlistScopeTransition(witness(), witness(accountGeneration = 5L)))
        assertEquals(PlaylistScopeTransition.AUTHORITY_BOUNDARY,
            playlistScopeTransition(witness(), witness(credentialEpoch = 10L)))
    }

    @Test fun absentBindingOrNativeAccountEvidenceFailsClosedButKnownNoTraktEpochIsStable() {
        assertEquals(PlaylistScopeTransition.AUTHORITY_BOUNDARY,
            playlistScopeTransition(witness(selectedID = null, profileID = null), witness(selectedID = null, profileID = null)))
        assertEquals(PlaylistScopeTransition.AUTHORITY_BOUNDARY,
            playlistScopeTransition(witness(accountID = null, accountGeneration = null), witness(accountID = null, accountGeneration = null)))
        assertEquals(PlaylistScopeTransition.AUTHORITY_BOUNDARY,
            playlistScopeTransition(witness(accountID = "", accountGeneration = 4L), witness(accountID = "", accountGeneration = 4L)))
        assertEquals(PlaylistScopeTransition.PROJECTION_REFRESH,
            playlistScopeTransition(witness(credentialEpoch = null), witness(credentialEpoch = null)))
    }

    @Test fun accountClearAndReturnAreTwoAuthorityBoundaries() {
        val original = witness()
        val cleared = witness(accountID = null, accountGeneration = null)
        assertEquals(PlaylistScopeTransition.AUTHORITY_BOUNDARY,
            playlistScopeTransition(original, cleared))
        assertEquals(PlaylistScopeTransition.AUTHORITY_BOUNDARY,
            playlistScopeTransition(cleared, original))
    }
}
