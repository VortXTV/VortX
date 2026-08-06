package com.vortx.android.sources

/**
 * Monotonic owner/target fence for the detail source pipeline. A token remains valid only until the next load or
 * profile switch. The generation, not just profile/episode equality, rejects A -> B -> A and target round trips.
 */
internal class SourceRequestFence(initialProfileId: String) {
    class Token internal constructor(
        val generation: Long,
        val profileId: String,
        val targetId: String?,
    )

    private val lock = Any()
    private var generation = 0L
    private var profileId = initialProfileId
    private var current: Token? = null

    fun begin(profileId: String, targetId: String?): Token = synchronized(lock) {
        generation += 1L
        this.profileId = profileId
        Token(generation, profileId, targetId).also { current = it }
    }

    fun invalidate(profileId: String): Long = synchronized(lock) {
        generation += 1L
        this.profileId = profileId
        current = null
        generation
    }

    fun currentToken(): Token? = synchronized(lock) { current }

    fun accepts(token: Token, activeProfileId: String): Boolean = synchronized(lock) {
        current == token && profileId == activeProfileId && token.profileId == activeProfileId
    }
}
