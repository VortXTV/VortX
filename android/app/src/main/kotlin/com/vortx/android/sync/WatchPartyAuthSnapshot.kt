package com.vortx.android.sync

import com.vortx.android.player.PlaybackOwnerToken
import java.util.UUID

/**
 * Short-lived, in-memory authority for one party owner. Never persist, put in a URL, or log this value.
 * It deliberately contains neither the account data key nor add-on/provider credentials.
 */
internal class WatchPartyAuthSnapshot private constructor(
    val bearer: String,
    val accountId: String,
    val profileId: String,
    val authGeneration: Long,
    val sessionGeneration: Long,
    val ownerEpoch: Long,
    internal val ownerToken: PlaybackOwnerToken,
) {
    /** A retired account/profile lifetime cannot revive after an A-to-B-to-A transition. */
    internal fun sameAuthorityAs(other: WatchPartyAuthSnapshot): Boolean =
        ownerToken === other.ownerToken &&
            authGeneration == other.authGeneration &&
            sessionGeneration == other.sessionGeneration &&
            ownerEpoch == other.ownerEpoch &&
            accountId == other.accountId &&
            profileId == other.profileId &&
            bearer == other.bearer &&
            ownerToken.isActive && other.ownerToken.isActive

    override fun toString(): String = "WatchPartyAuthSnapshot(redacted)"

    internal companion object {
        /** Pure admission policy. Only the owning sync manager captures production session values. */
        fun capture(
            bearer: String,
            accountId: String,
            profileId: String,
            authGeneration: Long,
            sessionGeneration: Long,
            ownerEpoch: Long,
            ownerToken: PlaybackOwnerToken,
        ): WatchPartyAuthSnapshot? {
            val canonicalAccount = runCatching { UUID.fromString(accountId).toString() }.getOrNull()
            if (canonicalAccount != accountId || bearer.isBlank() || bearer.any(Char::isWhitespace) ||
                bearer.any { it.isISOControl() } || profileId.isBlank() || profileId.any { it.isISOControl() } ||
                authGeneration < 0L || sessionGeneration < 0L || ownerEpoch < 1L || !ownerToken.isActive
            ) return null
            return WatchPartyAuthSnapshot(
                bearer, accountId, profileId, authGeneration, sessionGeneration, ownerEpoch, ownerToken,
            )
        }
    }
}
