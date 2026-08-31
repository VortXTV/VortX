package com.vortx.android.ui.viewmodel

import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaDetail
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DetailMutationFenceTest {
    @Test
    fun `recovered detail uses canonical id rather than route id`() {
        val routeId = "tmdb:123"
        val recoveredCanonicalId = "tt456"
        val fence = DetailMutationFence()

        val lease = fence.begin(
            MetaDetail(id = recoveredCanonicalId, type = MediaType.MOVIE, name = "Recovered"),
            profileId = "profile-a",
        )

        assertEquals("The repository mutation target must be the displayed recovered meta", recoveredCanonicalId, lease.id)
        assertFalse(routeId == lease.id)
    }

    @Test
    fun `profile rebuild suppresses a suspended old mutation completion`() {
        val fence = DetailMutationFence()
        val oldDetail = MetaDetail(id = "tt456", type = MediaType.SERIES, name = "Old profile")
        val oldProfileLease = fence.begin(oldDetail, profileId = "profile-a")

        fence.invalidate()

        assertFalse("The old profile may not publish after its repository call returns", fence.canPublish(oldProfileLease, "profile-b", oldDetail))
        val freshLease = fence.begin(oldDetail, profileId = "profile-b")
        assertTrue("A fresh profile action receives a new valid lease", fence.canPublish(freshLease, "profile-b", oldDetail))
    }

    @Test
    fun `retry also invalidates a pending canonical target`() {
        val fence = DetailMutationFence()
        val recoveredLease = fence.begin(
            MetaDetail(id = "tt456", type = MediaType.MOVIE, name = "Recovered"),
            profileId = "profile-a",
        )

        fence.invalidate()
        val routeLease = fence.begin(
            MetaDetail(id = "tmdb:123", type = MediaType.MOVIE, name = "Route"),
            profileId = "profile-a",
        )

        assertFalse(fence.accepts(recoveredLease))
        assertTrue(
            fence.canPublish(
                routeLease,
                "profile-a",
                MetaDetail(id = "tmdb:123", type = MediaType.MOVIE, name = "Route"),
            ),
        )
        assertEquals("tmdb:123", routeLease.id)
    }

    @Test
    fun `same id with a different type cannot publish`() {
        val fence = DetailMutationFence()
        val lease = fence.begin(
            MetaDetail(id = "shared", type = MediaType.MOVIE, name = "Movie"),
            profileId = "profile-a",
        )

        assertFalse(
            fence.canPublish(
                lease,
                "profile-a",
                MetaDetail(id = "shared", type = MediaType.SERIES, name = "Series"),
            ),
        )
    }
}
