package com.vortx.android.engine

import org.json.JSONObject

/**
 * Actual active native identity, not a resource revision or a whole presentation DTO. Full binding
 * equality includes its revision and transaction ID: same-UID relinks and A -> B -> A still revoke.
 * The existing strict binding reader validates the active profile/account projection on both sides.
 */
internal fun nativePlaybackOwnerChanged(before: JSONObject, after: JSONObject): Boolean {
    val previousID = before.getString("activeProfileId")
    val nextID = after.getString("activeProfileId")
    val previous = NativeAccountBinding.read(before, previousID)
    val next = NativeAccountBinding.read(after, nextID)
    return previousID != nextID || !previous.matches(next)
}
