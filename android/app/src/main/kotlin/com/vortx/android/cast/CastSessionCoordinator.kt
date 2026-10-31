package com.vortx.android.cast

/** In-memory media proof. The owner is an opaque mounted selection, never an account or source URL. */
data class CastConfirmedProgress(val owner: String, val positionMs: Long, val durationMs: Long)
internal data class CastTimelineUpdate(val point: CastConfirmedProgress?, val remoteActive: Boolean, val resumePositionMs: Long?)

/** The real adapter delegates session ordering, receiver-status admission and retirement to this class. */
internal class CastSessionCoordinator(
    private val validProgress: (Long, Long) -> Boolean = { _, duration -> duration > 0L },
    private val timeline: (CastTimelineUpdate) -> Unit,
) {
    data class Binding(val session: Any, val client: Any, val route: String, val epoch: Long) {
        fun same(other: Binding?): Boolean = other != null && session === other.session && client === other.client && epoch == other.epoch
    }
    data class Stop(val binding: Binding, val loadId: String)
    class LoadTicket internal constructor(val owner: String, val binding: Binding)
    data class Status(val receipt: String?, val positionMs: Long, val durationMs: Long,
        val playing: Boolean, val paused: Boolean, val buffering: Boolean)
    private data class Grant(val owner: String, val route: String, val deadline: Long, var session: Any? = null)
    private data class Resume(val deadline: Long, var ready: Boolean = false, var proof: Status? = null)
    private data class Load(val owner: String, val id: String, var binding: Binding,
        var deadline: Long?, var confirmed: Boolean = false, var point: CastConfirmedProgress? = null,
        var playing: Boolean = false, var paused: Boolean = false, var buffering: Boolean = true,
        var resume: Resume? = null, var seekTarget: Long? = null, var seekDeadline: Long? = null)
    private var owner: String? = null
    private var grant: Grant? = null
    private var ticket: LoadTicket? = null
    private var load: Load? = null
    private var nextEpoch = 0L
    private var leaving = false
    private var retiredPoint: CastConfirmedProgress? = null
    private var resumePoint: CastConfirmedProgress? = null
    var binding: Binding? = null
        private set
    val currentOwner: String? get() = load?.owner
    val loadId: String? get() = load?.id
    val isOwned: Boolean get() = load?.confirmed == true
    val canControl: Boolean get() = !leaving && isOwned && load?.resume == null
    val isPlaying: Boolean get() = canControl && load?.playing == true && load?.seekTarget == null
    val isPaused: Boolean get() = load?.paused == true
    val isBuffering: Boolean get() = load?.let { it.buffering || it.resume != null || it.seekTarget != null } == true
    val point: CastConfirmedProgress? get() = load?.point

    fun select(next: String?): Stop? {
        if (owner == next) return null
        val stop = retire(stopReceiver = true)
        owner = next
        leaving = false
        grant = null
        ticket = null
        return stop
    }
    fun observe(session: Any, client: Any, route: String) {
        if (binding?.let { it.session === session && it.client === client } == true) return
        if (load != null) retire(stopReceiver = false)
        binding = Binding(session, client, route, ++nextEpoch)
    }
    fun chooseRoute(requestOwner: String, route: String, now: Long): Boolean {
        if (leaving || owner != requestOwner || route.isBlank()) return false
        retire(stopReceiver = false)
        ticket = null
        grant = Grant(requestOwner, route, now + LOAD_TIMEOUT_MS)
        return true
    }
    fun starting(session: Any, route: String, now: Long) {
        val pending = grant ?: return
        if (pending.owner != owner || pending.route != route || now > pending.deadline) return
        if (pending.session == null) pending.session = session
    }
    fun started(session: Any, client: Any, route: String, now: Long, currentSession: Any?): LoadTicket? {
        if (session !== currentSession) return null
        val pending = grant
        val requested = !leaving && pending != null && pending.owner == owner && pending.route == route &&
            pending.session === session && now <= pending.deadline
        // Late outgoing/foreign callbacks may not retarget a different explicitly chosen successor.
        if (!requested && pending != null) return null
        observe(session, client, route)
        if (!requested) return null
        grant = null
        return LoadTicket(requireNotNull(owner), requireNotNull(binding)).also { ticket = it }
    }
    fun begin(request: LoadTicket, id: String, now: Long): Boolean {
        if (leaving || ticket !== request || owner != request.owner || !request.binding.same(binding) || id.isBlank()) return false
        ticket = null
        load = Load(request.owner, id, request.binding, now + LOAD_TIMEOUT_MS)
        return true
    }
    fun ended(session: Any) {
        if (load?.binding?.session === session) retire(stopReceiver = false)
        if (binding?.session === session) binding = null
        if (grant?.session === session) grant = null
        if (ticket?.binding?.session === session) ticket = null
    }
    fun suspended(session: Any, client: Any, now: Long) {
        val active = load ?: return
        if (!active.confirmed || active.binding.session !== session || active.binding.client !== client) return
        startResume(active, now)
        // A real suspension retires readiness and any status from before this callback.
        active.resume?.ready = false
        active.resume?.proof = null
    }
    private fun startResume(active: Load, now: Long) {
        if (active.resume != null) return // Repeated SDK callbacks never extend the first suspension's bound.
        active.resume = Resume(now + RECONNECT_TIMEOUT_MS)
        active.playing = false
        active.binding = active.binding.copy(epoch = ++nextEpoch)
        binding = active.binding
        timeline(CastTimelineUpdate(active.point, remoteActive = true, resumePositionMs = null))
    }
    fun resuming(session: Any, client: Any, route: String, now: Long) {
        starting(session, route, now)
        val active = load ?: return
        if (!active.confirmed || route != active.binding.route) return
        startResume(active, now)
        if (now >= requireNotNull(active.resume).deadline) { retire(false); return }
        // willResume grants no readiness, including for a repeated or replacement pair.
        // resumed calls this same preparation, then grants readiness for its actual callback.
        active.resume?.ready = false
        if (active.binding.session !== session || active.binding.client !== client) {
            active.binding = Binding(session, client, route, ++nextEpoch)
            binding = active.binding
            active.resume?.proof = null
        }
    }
    fun resumed(session: Any, client: Any, route: String, now: Long, currentSession: Any?): LoadTicket? {
        if (session !== currentSession) return null
        val pending = grant
        if (pending != null) {
            starting(session, route, now)
            return started(session, client, route, now, currentSession)
        }
        if (load?.binding?.route?.let { it != route } == true) {
            retire(stopReceiver = false)
            observe(session, client, route)
            return null
        }
        resuming(session, client, route, now)
        val active = load ?: return null
        val attempt = active.resume ?: return null
        if (active.binding.session !== session || active.binding.client !== client) return null
        attempt.ready = true
        attempt.proof?.let { applyStatus(active, it) }
        return null
    }
    /** Only RemoteMediaClient.onStatusUpdated calls this. Cached reads and progress/timer ticks cannot. */
    fun freshStatus(source: Binding, status: Status, now: Long) {
        val active = load ?: return
        if (leaving || !source.same(active.binding) || !source.same(binding)) return
        if (active.resume?.let { now >= it.deadline } == true) { retire(false); return }
        if (status.receipt != active.id || !(status.playing || status.paused || status.buffering)) {
            // LOAD is asynchronous. Old-media/idle updates before the first UUID echo are not a
            // rejection of this request; keep its bounded pending state without granting authority.
            if (active.confirmed) retire(stopReceiver = false)
            return
        }
        val attempt = active.resume
        if (attempt != null && !attempt.ready) { attempt.proof = status; return }
        applyStatus(active, status)
    }
    private fun applyStatus(active: Load, status: Status) {
        if (status.receipt != active.id) return
        active.resume = null
        active.confirmed = true
        active.playing = status.playing
        active.paused = status.paused
        active.buffering = status.buffering
        if (status.playing || status.paused) active.deadline = null
        val target = active.seekTarget
        if (!status.buffering && status.positionMs in 0L..MAX_POSITION_MS && status.durationMs in 1L..MAX_POSITION_MS &&
            validProgress(status.positionMs, status.durationMs) && (target == null || kotlin.math.abs(status.positionMs - target) <= SEEK_TOLERANCE_MS)) {
            active.point = CastConfirmedProgress(active.owner, status.positionMs, status.durationMs)
            active.seekTarget = null
            active.seekDeadline = null
        }
        // Always forward the last CONFIRMED point. A pause/exit between periodic ticks must save it;
        // neither an approximate clock nor an unconfirmed seek target can promote watched state.
        timeline(CastTimelineUpdate(active.point, remoteActive = true, resumePositionMs = null))
    }
    fun seek(target: Long, now: Long): Long? {
        val active = load ?: return null
        if (!canControl || target !in 0L..MAX_POSITION_MS) return null
        val duration = active.point?.durationMs ?: 0L
        val accepted = if (duration > 0L) target.coerceAtMost(duration) else target
        active.seekTarget = accepted
        active.seekDeadline = now + RECONNECT_TIMEOUT_MS
        return accepted
    }
    fun tick(admitted: Boolean, now: Long): Stop? {
        if (leaving) return null
        if (!admitted) {
            grant = null; ticket = null
            return retire(stopReceiver = true)
        }
        if (grant?.let { now > it.deadline } == true) grant = null
        val active = load ?: return null
        if (active.resume?.let { now >= it.deadline } == true) return retire(stopReceiver = false)
        if (active.deadline?.let { now >= it } == true || active.seekDeadline?.let { now >= it } == true)
            return retire(stopReceiver = true)
        return null
    }
    fun retire(stopReceiver: Boolean): Stop? {
        val active = load ?: return null
        val stop = if (stopReceiver) Stop(active.binding, active.id) else null
        active.point?.let { retiredPoint = it; resumePoint = it }
        load = null
        timeline(CastTimelineUpdate(active.point, remoteActive = false, resumePositionMs = active.point?.positionMs))
        return stop
    }
    /** The real host exit hook validates the original owner before choosing continuation or revocation. */
    fun prepareExit(requestOwner: String, admitted: Boolean): Stop? {
        if (owner != requestOwner) return null
        if (admitted) { leavePlayer(requestOwner); return null }
        // A 100 ms owner cleanup may beat the 1 s Cast clock. It must revoke synchronously and must
        // never enter the continuation exemption that ignores later denied-admission ticks.
        grant = null; ticket = null
        return retire(stopReceiver = true)
    }
    /** Runs synchronously before the player invalidates its own exit/writeback gate. */
    fun leavePlayer(requestOwner: String) {
        if (owner != requestOwner) return
        leaving = true
        grant = null; ticket = null
        retire(stopReceiver = false)
    }
    fun detach() { leaving = true; grant = null; ticket = null; retire(false); binding = null }
    fun confirmed(requestOwner: String): CastConfirmedProgress? =
        (load?.point ?: retiredPoint)?.takeIf { it.owner == requestOwner }
    fun takeResume(requestOwner: String): CastConfirmedProgress? = resumePoint?.takeIf { it.owner == requestOwner }?.also { resumePoint = null }

    companion object {
        const val LOAD_TIMEOUT_MS = 60_000L
        const val RECONNECT_TIMEOUT_MS = 15_000L
        const val MAX_POSITION_MS = 7L * 24L * 60L * 60L * 1000L
        const val SEEK_TOLERANCE_MS = 2_000L
    }
}
