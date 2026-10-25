package com.vortx.android.player

/** Opaque original engine/source/manual-choice receipt. Contains no URL, account or credential. */
class PlayerSubtitleSelection internal constructor(
    internal val owner: Any,
    internal val source: Any,
    internal val sourceContext: Any?,
)

/**
 * Identity receipts reject source/manual ABA without numeric revision overflow. No IO or callbacks.
 * This small lock only protects receipt state; isCurrent returning true is NOT final-mount admission.
 * Hosts must serialize revocation and final check+native action on their existing owner boundary:
 * actual Media3 application looper, or actual MPV subtitleGenerationGate for local command/property.
 */
internal class SubtitleSelectionAuthority {
    private val lock = Any()
    private val owner = Any()
    private var current: PlayerSubtitleSelection? = null
    private var retired = false

    fun beginSource(context: Any? = null): PlayerSubtitleSelection? = synchronized(lock) {
        if (retired) null else PlayerSubtitleSelection(owner, Any(), context).also { current = it }
    }

    fun beginChoice(): PlayerSubtitleSelection? = synchronized(lock) {
        val source = current?.source ?: return@synchronized null
        if (retired) null else PlayerSubtitleSelection(owner, source, current?.sourceContext).also { current = it }
    }

    fun capture(): PlayerSubtitleSelection? = synchronized(lock) { current }
    fun isCurrent(request: PlayerSubtitleSelection): Boolean = synchronized(lock) {
        !retired && request.owner === owner && current === request
    }
    fun retire() = synchronized(lock) { retired = true; current = null }
}
