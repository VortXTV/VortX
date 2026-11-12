package com.vortx.android.tv

import com.vortx.android.data.ContinueWatchingOwner
import com.vortx.android.data.ContinueWatchingSnapshot
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Test

class WatchNextPublicationTest {
    private val owner = ContinueWatchingOwner("profile-a", "slot-a", "account-a", true, 8)

    @Test fun unavailableOwnerDoesNotClearExistingLauncherRows() {
        val unavailable = ContinueWatchingOwner("native-unavailable", "native-unavailable", "native-unavailable", true, 0)
        assertNull(watchNextPublication(unavailable, Result.success(ContinueWatchingSnapshot(unavailable, emptyList()))))
        assertNull(watchNextPublication(owner, Result.failure(IllegalStateException("snapshot unavailable"))))
    }

    @Test fun onlyAConfirmedEmptySnapshotCanClearRows() {
        val otherProfile = owner.copy(profileId = "profile-b")
        val stale = owner.copy(revision = 7)
        assertNull(watchNextPublication(owner, Result.success(ContinueWatchingSnapshot(otherProfile, emptyList()))))
        assertNull(watchNextPublication(owner, Result.success(ContinueWatchingSnapshot(stale, emptyList()))))
        assertEquals(WatchNextPublication(owner, emptyList()),
            watchNextPublication(owner, Result.success(ContinueWatchingSnapshot(owner, emptyList()))))
    }

    @Test fun retainsOwnerIdentityAndOnlyInProgressRows() {
        val item = MetaItem("movie-a", MediaType.MOVIE, "Movie", resumeSeconds = 42.0, progress = 0.2f)
        val snapshot = ContinueWatchingSnapshot(owner, listOf(item, item.copy(id = "finished", watched = true)))
        val publication = watchNextPublication(owner, Result.success(snapshot))
        assertEquals(WatchNextPublication(owner,
            listOf(WatchNextPublisher.Item(item.type, item.id, item.name, null, 42.0, 0.2f))), publication)
        val newer = owner.copy(revision = 9)
        assertNotEquals(publication, watchNextPublication(newer, Result.success(snapshot.copy(owner = newer))))
    }
}
