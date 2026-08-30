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
    private var refresh: Token? = null

    fun begin(profileId: String, targetId: String?): Token = synchronized(lock) {
        refresh = null
        next(profileId, targetId)
    }

    /**
     * Claims the one in-flight force-refresh slot. Repeated taps must not repeatedly unload the shared
     * engine model: the current refresh already asks every add-on again and owns its eventual publication.
     */
    fun beginRefresh(profileId: String, targetId: String?): Token? = synchronized(lock) {
        if (refresh != null) return null
        next(profileId, targetId).also { refresh = it }
    }

    /** Releases a completed refresh only if it still owns the slot. */
    fun finishRefresh(token: Token) = synchronized(lock) {
        if (refresh === token) refresh = null
    }

    private fun next(profileId: String, targetId: String?): Token {
        generation += 1L
        this.profileId = profileId
        return Token(generation, profileId, targetId).also { current = it }
    }

    fun invalidate(profileId: String): Long = synchronized(lock) {
        generation += 1L
        this.profileId = profileId
        current = null
        refresh = null
        generation
    }

    fun currentToken(): Token? = synchronized(lock) { current }

    fun accepts(token: Token, activeProfileId: String): Boolean = synchronized(lock) {
        current == token && profileId == activeProfileId && token.profileId == activeProfileId
    }
}
