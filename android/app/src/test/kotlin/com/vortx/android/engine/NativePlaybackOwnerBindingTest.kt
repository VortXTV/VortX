package com.vortx.android.engine

import com.vortx.android.player.PlaybackOwnerEpoch
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** Real JSON binding reader and epoch; no fake account authority, Android, JNI or Media3 proof. */
class NativePlaybackOwnerBindingTest {
    @Test fun progressWatchedLibrarySettingsAndAckChangesKeepOriginalPlaybackLifetime() {
        val before = state()
        val after = JSONObject(before.toString()).put("hostProfilePreferences", JSONObject().put("accent", "changed"))
        after.getJSONObject("nativeSync").put("progress", 160).put("watched", true).put("library", JSONObject())
            .put("ack", 42)
        val original = PlaybackOwnerEpoch.capture()!!
        if (nativePlaybackOwnerChanged(before, after)) PlaybackOwnerEpoch.invalidate()
        assertTrue(original.isActive)
        assertTrue(PlaybackOwnerEpoch.isCurrent(original))
    }

    @Test fun sameOwnerTypedReceiveAndUnrelatedRosterOrDormantSlotChangesAreNotRebindings() {
        val before = state()
        val after = JSONObject(before.toString())
        after.getJSONObject("roster").getJSONObject("profiles").put("other", profile("shared", "uid-other"))
        after.getJSONObject("nativeSync").getJSONObject("accountSlots").put("other", slot("own", "uid-other", 8, "remote-relink"))
        after.getJSONObject("nativeSync").getJSONObject("accountSlots").getJSONObject("main")
            .put("slots", JSONObject().put("dormant", JSONObject().put("displayName", "new source")))
        assertFalse(nativePlaybackOwnerChanged(before, after))
    }

    @Test fun activeProfileSwitchAndActiveBindingTransactionRetireBeforePublication() {
        val before = state()
        val after = JSONObject(before.toString())
        after.getJSONObject("roster").getJSONObject("profiles").put("other", profile("shared", "uid-main"))
        after.getJSONObject("nativeSync").getJSONObject("accountSlots").put("other", slot("shared", "uid-main", 0, null))
        after.put("activeProfileId", "other")
        assertTrue(nativePlaybackOwnerChanged(before, after))
        val original = PlaybackOwnerEpoch.capture()!!
        if (nativePlaybackOwnerChanged(before, after)) PlaybackOwnerEpoch.transition {
            assertFalse(original.isActive)
            assertNull(PlaybackOwnerEpoch.capture())
        }
        val sameUIDRelink = state(revision = 1, transaction = "same-uid-relink")
        assertTrue(nativePlaybackOwnerChanged(before, sameUIDRelink))
    }

    @Test fun exactBindingReceiptDetectsOwnAccountABAAndDoesNotReauthorizeOldToken() {
        val a = state(kind = "own", uid = "uid-a", revision = 1, transaction = "tx-a")
        val b = state(kind = "own", uid = "uid-b", revision = 2, transaction = "tx-b")
        val aAgain = state(kind = "own", uid = "uid-a", revision = 3, transaction = "tx-a-again")
        val original = PlaybackOwnerEpoch.capture()!!
        assertTrue(nativePlaybackOwnerChanged(a, b)); PlaybackOwnerEpoch.invalidate()
        assertTrue(nativePlaybackOwnerChanged(b, aAgain)); PlaybackOwnerEpoch.invalidate()
        assertTrue(nativePlaybackOwnerChanged(a, aAgain))
        assertFalse(original.isActive)
        assertFalse(PlaybackOwnerEpoch.isCurrent(original))
    }

    @Test fun legacyWithoutExplicitSlotUsesStrictProfileAccountAndPromotesEqualZeroBinding() {
        val before = state()
        before.getJSONObject("nativeSync").remove("accountSlots")
        assertFalse(nativePlaybackOwnerChanged(before, state()))
        assertTrue(nativePlaybackOwnerChanged(before, state(revision = 1, transaction = "first-selection")))
    }

    @Test fun malformedOrDeletedActiveBindingFailsBeforeAnOwnerPublication() {
        val before = state()
        val deleted = state().also { it.getJSONObject("roster").getJSONObject("profiles").getJSONObject("main").put("deleted", true) }
        val mismatch = state().also { it.getJSONObject("nativeSync").getJSONObject("accountSlots").getJSONObject("main")
            .getJSONObject("activeBinding").getJSONObject("account").put("value", "uid-wrong") }
        val malformed = state(revision = 0, transaction = "not-zero")
        for (after in listOf(deleted, mismatch, malformed)) {
            assertTrue(runCatching { nativePlaybackOwnerChanged(before, after) }.isFailure)
        }
    }

    private fun profile(kind: String, uid: String) = JSONObject().put("deleted", false)
        .put("account", JSONObject().put("kind", kind).put("value", uid))

    private fun slot(kind: String, uid: String, revision: Int, transaction: String?) = JSONObject()
        .put("activeBinding", JSONObject().put("account", JSONObject().put("kind", kind).put("value", uid))
            .put("revision", revision).put("transactionId", transaction ?: JSONObject.NULL))

    private fun state(kind: String = "shared", uid: String = "uid-main", revision: Int = 0, transaction: String? = null) =
        JSONObject().put("activeProfileId", "main")
            .put("roster", JSONObject().put("profiles", JSONObject().put("main", profile(kind, uid))))
            .put("nativeSync", JSONObject().put("accountSlots", JSONObject().put("main", slot(kind, uid, revision, transaction))))
}
