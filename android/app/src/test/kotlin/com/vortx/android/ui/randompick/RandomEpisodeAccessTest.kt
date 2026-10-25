package com.vortx.android.ui.randompick

import com.vortx.android.data.ContinueWatchingOwner
import com.vortx.android.profile.UserProfile
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Test

class RandomEpisodeAccessTest {
    private val owner = ContinueWatchingOwner("profile-a", "slot-a", "account-a", true, 3)
    private val profile = UserProfile(id = "profile-a", name = "Viewer", avatar = "ember", pin = "pin-v1")
    private val access = requireNotNull(capture())

    @Test fun actualProfilePickerAndSourceBindingAreRequired() {
        assertEquals(RandomEpisodeAccess(owner, profile, "tt123"), access)
        assertNull(capture(currentProfile = null))
        assertNull(capture(needsPicker = true))
        assertNull(capture(routeAdmitted = false))
        assertNull(capture(metaId = ""))
        assertNull(capture(sourceProfileId = "different"))
        assertNull(capture(currentOwner = owner.copy(profileId = "different")))
    }

    @Test fun fullOwnerProfileAndRecoveredMetaChangesCannotReuseAnOldWitness() {
        assertNotEquals(access, capture(currentOwner = owner.copy(accountSlot = "other")))
        assertNotEquals(access, capture(currentOwner = owner.copy(principal = "other")))
        assertNotEquals(access, capture(currentOwner = owner.copy(usesEngineHistory = false)))
        assertNotEquals(access, capture(currentOwner = owner.copy(revision = 4)))
        assertNotEquals(access, capture(currentProfile = profile.copy(isKids = true)))
        assertNotEquals(access, capture(currentProfile = profile.copy(pin = "pin-v2")))
        assertNotEquals(access, capture(currentProfile = profile.copy(name = "Edited")))
        assertNotEquals(access, capture(metaId = "tt456"))
    }

    private fun capture(
        currentOwner: ContinueWatchingOwner = owner,
        currentProfile: UserProfile? = profile,
        needsPicker: Boolean = false,
        metaId: String = "tt123",
        sourceProfileId: String = "profile-a",
        routeAdmitted: Boolean = true,
    ) = RandomEpisodeAccess.capture(currentOwner, currentProfile, needsPicker, metaId, sourceProfileId, routeAdmitted)
}
