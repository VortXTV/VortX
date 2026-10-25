package com.vortx.android.player

import org.junit.Assert.*
import org.junit.Test

class SubtitleSidecarIdentityTest {
    @Test fun sameUriRetainsOwnedIdForReselectionButNewSourceCannotAdoptIt() {
        var sequence = 0
        val identity = SubtitleSidecarIdentity { "opaque-${++sequence}" }
        val uri = "https://subs.example/private?token=not-in-id"
        val first = identity.idFor(uri)
        assertEquals(first, identity.idFor(uri))
        assertFalse(first.contains("private")); assertFalse(first.contains("token"))
        assertNull(identity.existingId("https://other.example/sub.srt"))
        identity.reset()
        assertNull(identity.existingId(uri)); assertNotEquals(first, identity.idFor(uri))
    }

    @Test fun exactOwnedFormatIdSelectsExistingSameUriAfterOffNotNewLastTrack() {
        val identity = SubtitleSidecarIdentity { "requested" }
        val requested = identity.idFor("file:///private/cache/requested.srt")
        val exact = OwnedSubtitleTrack(1, 0, requested)
        val unrelated = OwnedSubtitleTrack(2, 0, "vortx-sidecar:late-other-load-file")
        assertEquals(exact, uniqueOwnedSubtitleTrack(requested,
            listOf(OwnedSubtitleTrack(0, 0, "embedded-en"), exact, unrelated)))
        // Reordering/group growth changes current indices, not the original requested file identity.
        val moved = OwnedSubtitleTrack(3, 1, requested)
        assertEquals(moved, uniqueOwnedSubtitleTrack(requested, listOf(unrelated, moved)))
    }

    @Test fun missingAmbiguousForeignAndExcessiveCandidatesNeverPickFirstOrLast() {
        val id = "vortx-sidecar:requested"
        assertNull(uniqueOwnedSubtitleTrack(id, listOf(OwnedSubtitleTrack(0, 0, "embedded"))))
        assertNull(uniqueOwnedSubtitleTrack(id, listOf(OwnedSubtitleTrack(0, 0, id), OwnedSubtitleTrack(1, 0, id))))
        assertNull(uniqueOwnedSubtitleTrack("foreign", listOf(OwnedSubtitleTrack(0, 0, "foreign"))))
        assertNull(uniqueOwnedSubtitleTrack(id, listOf(OwnedSubtitleTrack(-1, 0, id))))
        assertNull(uniqueOwnedSubtitleTrack(id, List(4097) { OwnedSubtitleTrack(0, it, null) }))
    }
}
