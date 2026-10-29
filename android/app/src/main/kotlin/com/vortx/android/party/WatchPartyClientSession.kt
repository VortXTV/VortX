package com.vortx.android.party

import android.os.Looper
import android.os.SystemClock
import com.vortx.android.sync.VortXSyncManager
import com.vortx.android.sync.WatchPartyAuthSnapshot
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
import java.util.UUID

internal interface WatchPartyAuthAuthority {
    fun capture(): WatchPartyAuthSnapshot?
    fun isCurrent(snapshot: WatchPartyAuthSnapshot): Boolean
}
internal class ManagerWatchPartyAuthAuthority(private val manager: VortXSyncManager) : WatchPartyAuthAuthority {
    override fun capture() = manager.captureWatchPartyAuth()
    override fun isCurrent(snapshot: WatchPartyAuthSnapshot) = manager.isCurrentWatchPartyAuth(snapshot)
}

/**
 * One ephemeral room per mounted player. Every state mutation is Main-serialized; auth, owner, socket,
 * and operation identity are rechecked after suspension. A failed transport requires an explicit fresh
 * join: a socket reconnect never inherits sequence, key application authority, or an old pending permit.
 */
internal class WatchPartyClientSession(
    private val authAuthority: WatchPartyAuthAuthority,
    private val currentOwner: () -> WatchPartyOwnerStamp?,
    /** Must synchronously consume under the real player-owner monitor, then mutate without suspending. */
    private val apply: (WatchPartyWire.Control, WatchPartyApplyPermit, WatchPartyClientPolicy) -> Boolean,
    private val now: () -> Long = SystemClock::elapsedRealtime,
    private val transport: WatchPartyServiceTransport = WatchPartyTransport(),
    private val assertMainThread: () -> Unit = {
        check(Looper.myLooper() == Looper.getMainLooper()) { "Party state requires the main thread" }
    },
    private val currentLeaderControl: () -> WatchPartyWire.Control? = { null },
) {
    constructor(sync: VortXSyncManager, currentOwner: () -> WatchPartyOwnerStamp?,
        apply: (WatchPartyWire.Control, WatchPartyApplyPermit, WatchPartyClientPolicy) -> Boolean,
        currentLeaderControl: () -> WatchPartyWire.Control?) : this(
            ManagerWatchPartyAuthAuthority(sync), currentOwner, apply, currentLeaderControl = currentLeaderControl)

    data class UiState(val phase: Phase = Phase.IDLE, val members: Int = 0, val leader: Boolean = false, val canShare: Boolean = false) {
        enum class Phase { IDLE, CONNECTING, CONNECTED, CLOSED, FAILED }
    }
    private data class Member(val room: String, val id: String, val capability: String, val leader: Boolean) {
        fun body() = JSONObject().put("memberId", id).put("capability", capability)
        override fun toString() = "PartyMembership(redacted)"
    }
    private data class Challenge(val nonce: String, val startedAt: Long, val bootstrap: Boolean, val completion: CompletableDeferred<WatchPartyProof>)
    private data class Reservation(val id: String, val room: String, val term: Long, val sequence: Long)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val outgoing = Mutex()
    private val mutableState = MutableStateFlow(UiState())
    val state = mutableState.asStateFlow()
    private var operation = UUID.randomUUID()
    private var work: Job? = null
    private var reader: Job? = null
    private var watchdog: Job? = null
    private var socket: WatchPartySocket? = null
    private var auth: WatchPartyAuthSnapshot? = null
    private var owner: WatchPartyOwnerStamp? = null
    private var member: Member? = null
    private var key: ByteArray? = null
    private var invitation: WatchPartyInvite? = null
    private var inviteDeadline = 0L
    private var policy: WatchPartyClientPolicy? = null
    private var challenge: Challenge? = null
    private var reservation: CompletableDeferred<Reservation>? = null
    private var renewal: CompletableDeferred<Long>? = null
    private var renewalAfterSequence = 0L
    private var refresh = WatchPartyRefreshLedger()
    private var retiredNonces = WatchPartyRetiredNonces()
    private var connectedSeen = false
    private var memberCount = 0
    private var pendingControl: WatchPartyWire.Control? = null
    private var controlDrain: Job? = null
    private var lastReadySequence = 0L
    private var lastReservationSupersessionSequence = 0L
    private var coveredReadySequence = 0L
    private data class Publication(val grant: Reservation, val ciphertext: String,
        val completion: CompletableDeferred<Boolean>, var supersededByMetadata: Boolean = false)
    private var publication: Publication? = null

    fun create() = start(null)
    fun join(invite: WatchPartyInvite) = start(invite)
    private fun start(invite: WatchPartyInvite?) {
        main()
        invalidate(UiState.Phase.IDLE)
        val auth = authAuthority.capture()
        val owner = currentOwner()
        if (auth == null || owner == null || owner.accountId != auth.accountId || owner.profileId != auth.profileId || owner.ownerEpoch != auth.ownerEpoch) {
            invite?.erase(); mutableState.value = UiState(UiState.Phase.FAILED); return
        }
        this.auth = auth; this.owner = owner
        val op = operation
        mutableState.value = UiState(UiState.Phase.CONNECTING)
        // Covers setup HTTP as well as a live socket. Cancellation cancels actual OkHttp calls.
        watchdog = scope.launch {
            while (isActive && operation == op) {
                delay(250)
                if (!owned(op)) { invalidateIfCurrent(op, UiState.Phase.CLOSED); break }
                if (invitation != null && now() >= inviteDeadline) {
                    invitation?.erase(); invitation = null
                    mutableState.value = mutableState.value.copy(canShare = false)
                }
                val p = policy
                if (p != null && (!p.observe(now()) || (p.anchored && !p.live(now())))) {
                    invalidateIfCurrent(op, UiState.Phase.CLOSED); break
                }
            }
        }
        work = scope.launch {
            try {
                val roomKey = invite?.copyKey() ?: WatchPartyWire.roomKey()
                key = roomKey
                val creationStarted = now()
                val receipt = if (invite == null) post("", JSONObject(), op)
                    else post("/${invite.roomId}/join", JSONObject().put("inviteCode", invite.inviteCode), op)
                ensure(op)
                val roomId = receipt.opaqueString("roomId")
                require(invite == null || roomId == invite.roomId)
                val leader = invite == null
                val memberId = receipt.opaqueString(if (leader) "leaderId" else "id")
                if (!leader) require(receipt.strictString("role") == "member" && receipt.strictLong("incarnation") == 1L)
                val member = Member(roomId, memberId, receipt.opaqueString("capability"), leader)
                this@WatchPartyClientSession.member = member
                if (leader) {
                    check(creationStarted <= Long.MAX_VALUE - 120_000)
                    inviteDeadline = creationStarted + 120_000
                    invitation = WatchPartyInvite.make(roomId, receipt.opaqueString("inviteCode"), roomKey)
                }
                invite?.erase()
                val snapshot = receipt.getJSONObject("snapshot")
                val p = WatchPartyClientPolicy(owner, UUID.randomUUID().toString(), snapshot.opaqueString("roomGeneration"),
                    snapshot.strictLong("leaderTerm"), snapshot.strictLong("serverSequence"), now())
                require(snapshot.strictLong("leaseRemainingMs") in 1000..30_000)
                policy = p
                memberCount = snapshot.strictLong("memberCount").also { require(it in 1..64) }.toInt()
                val ticket = post("/$roomId/ticket", member.body(), op).opaqueString("ticket")
                ensure(op)
                val connected = transport.open(roomId, ticket)
                socket = connected
                withTimeout(8_000) { connected.ready.await() }
                ensure(op, connected)
                reader = scope.launch { readFrames(op, connected) }
                // Establish a nonce-bound sequence only after this actual socket is open.
                prove(op, connected, bootstrap = true)
                ensure(op, connected)
                if (refresh.needsRefresh) refreshAndProve(op, connected)
                mutableState.value = UiState(UiState.Phase.CONNECTED, memberCount, leader, leader && now() < inviteDeadline)
                if (leader && lastReadySequence > coveredReadySequence) beginControlDrain(op, connected)
                while (isActive) {
                    delay(WatchPartyClientPolicy.refreshDelay(now(), p.deadline))
                    outgoing.withLock {
                        ensure(op, connected)
                        require(p.live(now()))
                        if (leader) {
                            check(renewal == null)
                            renewalAfterSequence = p.sequence
                            val wait = CompletableDeferred<Long>(); renewal = wait
                            connected.send(JSONObject().put("kind", "renew"))
                            withTimeout(5_000) { wait.await() }
                            ensure(op, connected)
                        }
                        refreshAndProve(op, connected)
                    }
                }
            } catch (failure: CancellationException) {
                invite?.erase()
                if (operation == op) invalidateIfCurrent(op, UiState.Phase.CLOSED)
                throw failure
            } catch (_: Exception) {
                invite?.erase(); invalidateIfCurrent(op, UiState.Phase.FAILED)
            }
        }
    }
    private suspend fun refreshAndProve(op: UUID, connected: WatchPartySocket) {
        do {
            val obligation = refresh.beginRefresh()
            val member = member ?: error("Party ended")
            post("/${member.room}/renew", member.body(), op)
            ensure(op, connected)
            refresh.completeRefresh(obligation)
            // Do not adopt the HTTP snapshot as sequence/lease authority. Only a nonce proof from
            // this actual ordered socket can extend the local deadline, anchored to request start.
            prove(op, connected, bootstrap = false)
            ensure(op, connected)
            // A lease event during member-renew/proof creates a new obligation, never cleared by
            // an older completion. Repeat before normal cadence, including for guests.
        } while (refresh.needsRefresh)
    }
    private suspend fun prove(op: UUID, connected: WatchPartySocket, bootstrap: Boolean) {
        ensure(op, connected)
        check(challenge == null)
        val started = now(); val nonce = WatchPartyWire.randomToken()
        val pending = Challenge(nonce, started, bootstrap, CompletableDeferred()); challenge = pending
        connected.send(JSONObject().put("kind", "lease.challenge").put("nonce", nonce))
        withTimeout(5_000) { pending.completion.await() }
        ensure(op, connected)
    }
    private suspend fun readFrames(op: UUID, connected: WatchPartySocket) {
        try {
            for (text in connected.frames) {
                ensure(op, connected)
                val value = JSONObject(text)
                val kind = value.opt("kind") as? String
                when (kind) {
                    "connected" -> {
                        require(!connectedSeen)
                        require(value.strictString("role") == if (member?.leader == true) "leader" else "member")
                        val p = policy ?: error("Party ended")
                        require(p.connectedBaseline(value.opaqueString("roomGeneration"), value.strictLong("leaderTerm"),
                            value.strictLong("serverSequence"), now()))
                        connectedSeen = true
                    }
                    "lease.proof" -> {
                        require(connectedSeen)
                        val nonce = value.opaqueString("nonce")
                        val waiting = challenge
                        if (waiting == null || waiting.nonce != nonce) {
                            require(retiredNonces.contains(nonce))
                            continue // only a bounded, explicitly retired duplicate can be ignored
                        }
                        require(!waiting.completion.isCompleted)
                        val proof = WatchPartyProof(nonce, value.opaqueString("roomGeneration"),
                            value.strictLong("leaderTerm"), value.strictLong("serverSequence"), value.strictLong("leaseRemainingMs"))
                        val p = policy ?: error("Party ended")
                        require(p.acceptProof(proof, nonce, waiting.startedAt, now(), waiting.bootstrap))
                        retire(nonce); challenge = null
                        waiting.completion.complete(proof)
                    }
                    "reservation" -> {
                        val waiting = reservation ?: error("Unsolicited reservation")
                        require(!waiting.isCompleted)
                        waiting.complete(Reservation(value.opaqueString("reservationId"), value.opaqueString("roomGeneration"),
                            value.strictLong("leaderTerm"), value.strictLong("serverSequence")))
                    }
                    "error" -> {
                        val waiting = publication
                        val p = policy
                        require(value.strictString("code") == "stale-reservation" && waiting != null &&
                            waiting.supersededByMetadata && p != null && p.sequence >= waiting.grant.sequence &&
                            lastReservationSupersessionSequence >= waiting.grant.sequence)
                        publication = null
                        waiting.completion.complete(false)
                    }
                    null -> acceptEvent(value, op, connected)
                    else -> error("Unsupported party message")
                }
            }
            invalidateIfCurrent(op, UiState.Phase.CLOSED)
        } catch (failure: CancellationException) {
            invalidateIfCurrent(op, UiState.Phase.CLOSED)
            throw failure
        } catch (_: Exception) { invalidateIfCurrent(op, UiState.Phase.FAILED) }
    }
    private fun acceptEvent(value: JSONObject, op: UUID, connected: WatchPartySocket) {
        ensure(op, connected)
        val p = policy ?: error("Party ended")
        require(connectedSeen)
        val type = value.strictString("type")
        require(type in setOf("sealed", "member-joined", "member-ready", "member-left", "lease-renewed", "room-closed"))
        val room = value.opaqueString("roomGeneration"); val term = value.strictLong("leaderTerm")
        val sequence = value.strictLong("serverSequence")
        val count = value.strictLong("memberCount"); require(count in 1..64 || type == "room-closed")
        memberCount = count.toInt()
        if (!p.anchored) {
            require(p.bootstrapEvent(room, term, sequence, now()))
            require(type != "room-closed")
            if (type == "lease-renewed") refresh.leaseObserved(sequence)
            if (type == "member-ready") lastReadySequence = maxOf(lastReadySequence, sequence)
            if (type == "member-ready" || type == "member-joined" || type == "lease-renewed") lastReservationSupersessionSequence = maxOf(lastReservationSupersessionSequence, sequence)
            return // Never apply pre-proof controls or accept an event as lease authority.
        }
        require(p.admitEvent(room, term, sequence, now()))
        mutableState.value = mutableState.value.copy(members = count.toInt())
        when (type) {
            "room-closed" -> invalidateIfCurrent(op, UiState.Phase.CLOSED)
            "lease-renewed" -> {
                lastReservationSupersessionSequence = maxOf(lastReservationSupersessionSequence, sequence)
                publication?.takeIf { it.grant.sequence <= sequence }?.supersededByMetadata = true
                refresh.leaseObserved(sequence)
                renewal?.let { waiting ->
                    require(sequence > renewalAfterSequence && !waiting.isCompleted)
                    renewal = null; waiting.complete(sequence)
                }
            }
            "member-joined" -> {
                lastReservationSupersessionSequence = maxOf(lastReservationSupersessionSequence, sequence)
                publication?.takeIf { it.grant.sequence <= sequence }?.supersededByMetadata = true
            }
            "member-ready" -> {
                lastReservationSupersessionSequence = maxOf(lastReservationSupersessionSequence, sequence)
                lastReadySequence = maxOf(lastReadySequence, sequence)
                publication?.takeIf { it.grant.sequence <= sequence }?.supersededByMetadata = true
                if (member?.leader == true) {
                    // Current playback is sampled only after this ordered ready event. Coalesce ready
                    // bursts; every fresh successful snapshot covers all ready events seen before it.
                    pendingControl = null
                    beginControlDrain(op, connected)
                }
            }
            "sealed" -> {
                val roomKey = key ?: error("Party ended")
                val control = WatchPartyWire.open(value.strictString("ciphertext"), roomKey, room, term, sequence)
                require(control.mediaId == owner?.titleToken)
                // A leader has already performed its own local command. Receiving its sealed echo
                // advances the sequence but cannot seek again or fight playback intent.
                if (member?.leader == true) {
                    publication?.let { waiting ->
                        require(!waiting.supersededByMetadata && waiting.grant.sequence == sequence && waiting.ciphertext == value.strictString("ciphertext"))
                        publication = null
                        waiting.completion.complete(true)
                    }
                } else {
                    val permit = p.permit(control, now()) ?: error("Expired party control")
                    ensure(op, connected)
                    require(apply(control, permit, p))
                }
            }
        }
    }
    /** User updates coalesce into one bounded slot; remote commands never echo through this seam. */
    fun publish(action: String, positionMs: Long) {
        main()
        val op = operation; val connected = socket ?: return
        val current = owner ?: return
        if (member?.leader != true || mutableState.value.phase != UiState.Phase.CONNECTED) return
        if (!owned(op)) { invalidateIfCurrent(op, UiState.Phase.CLOSED); return }
        require(action in setOf("play", "pause", "seek"))
        pendingControl = WatchPartyWire.Control(action, current.titleToken, positionMs.coerceIn(0, 86_400_000))
        beginControlDrain(op, connected)
    }
    private fun beginControlDrain(op: UUID, connected: WatchPartySocket) {
        if (controlDrain?.isActive == true || member?.leader != true) return
        controlDrain = scope.launch {
            try {
                while (pendingControl != null || lastReadySequence > coveredReadySequence) {
                    outgoing.withLock {
                        ensure(op, connected)
                        val readyObligation = lastReadySequence
                        val needsReady = readyObligation > coveredReadySequence
                        val control = if (needsReady) currentLeaderControl().also { pendingControl = null }
                            else pendingControl.also { pendingControl = null }
                        require(control != null && control.mediaId == owner?.titleToken)
                        val applied = publishOnce(control, op, connected, readyObligation)
                        if (applied) coveredReadySequence = maxOf(coveredReadySequence, readyObligation)
                        else pendingControl = currentLeaderControl()
                        // A stale grant or sent publish superseded by ordered readiness retries from a
                        // fresh reservation/current snapshot. It never reuses ciphertext or sequence.
                    }
                }
            } catch (failure: CancellationException) {
                invalidateIfCurrent(op, UiState.Phase.CLOSED)
                throw failure
            } catch (_: Exception) { invalidateIfCurrent(op, UiState.Phase.FAILED) }
            finally { if (operation == op) controlDrain = null }
        }
    }
    private suspend fun publishOnce(control: WatchPartyWire.Control, op: UUID,
        connected: WatchPartySocket, sampledReadySequence: Long): Boolean {
        ensure(op, connected)
        val p = policy ?: error("Party ended"); require(p.live(now()))
        check(reservation == null && publication == null)
        val wait = CompletableDeferred<Reservation>(); reservation = wait
        connected.send(JSONObject().put("kind", "reserve"))
        val grant = withTimeout(5_000) { wait.await() }
        ensure(op, connected)
        reservation = null
        require(p.live(now()) && grant.room == p.room && grant.term == p.term)
        if (grant.sequence <= p.sequence && lastReservationSupersessionSequence >= grant.sequence) return false
        require(p.sequence < MAX_SAFE_INTEGER && grant.sequence == p.sequence + 1)
        val refreshed = if (lastReadySequence > sampledReadySequence) currentLeaderControl() else control
        require(refreshed != null && refreshed.mediaId == owner?.titleToken)
        val ciphertext = WatchPartyWire.seal(refreshed, key ?: error("Party ended"), grant.room, grant.term, grant.sequence)
        ensure(op, connected)
        val pending = Publication(grant, ciphertext, CompletableDeferred()); publication = pending
        connected.send(JSONObject().put("kind", "publish").put("reservationId", grant.id)
            .put("roomGeneration", grant.room).put("leaderTerm", grant.term).put("serverSequence", grant.sequence).put("ciphertext", ciphertext))
        val applied = withTimeout(5_000) { pending.completion.await() }
        ensure(op, connected)
        return applied
    }
    fun shareLink(): String? {
        main()
        return if (owned(operation) && now() < inviteDeadline && mutableState.value.canShare && policy?.live(now()) == true) invitation?.link() else null
    }
    fun leave() {
        main()
        val oldMember = member; val oldAuth = auth
        if (owned(operation)) runCatching { socket?.send(JSONObject().put("kind", "leave")) }
        invalidate(UiState.Phase.CLOSED)
        // Explicit authenticated leave is best effort; never keep credentials in a URL or stored retry.
        if (oldMember != null && oldAuth != null && authAuthority.isCurrent(oldAuth)) scope.launch {
            try {
                if (authAuthority.isCurrent(oldAuth)) transport.post("/${oldMember.room}/leave", oldAuth.bearer, oldMember.body())
            } catch (_: Exception) { /* room also has a bounded lease; no background retry */ }
        }
    }
    fun ownerChanged() { main(); invalidate(UiState.Phase.CLOSED) }
    fun close() { main(); invalidate(UiState.Phase.CLOSED); scope.cancel() }
    private suspend fun post(path: String, body: JSONObject, op: UUID): JSONObject {
        ensure(op)
        val original = auth ?: error("Signed out")
        val result = transport.post(path, original.bearer, body)
        ensure(op)
        return result
    }
    private fun owned(op: UUID): Boolean {
        val original = auth ?: return false
        return op == operation && (socket == null || socket?.isActive() == true) && authAuthority.isCurrent(original) && currentOwner() == owner && owner != null
    }
    private fun ensure(op: UUID, expectedSocket: WatchPartySocket? = null) {
        main(); check(owned(op) && (expectedSocket == null || socket === expectedSocket && expectedSocket.isOpen())) { "Party owner changed" }
        val p = policy
        if (p != null) check(p.observe(now())) { "Party clock changed" }
    }
    private fun retire(nonce: String) { retiredNonces.retire(nonce) }
    private fun invalidateIfCurrent(op: UUID, phase: UiState.Phase) { if (operation == op) invalidate(phase) }
    private fun invalidate(phase: UiState.Phase) {
        main(); operation = UUID.randomUUID()
        work?.cancel(); work = null; reader?.cancel(); reader = null; watchdog?.cancel(); watchdog = null
        socket?.close(); socket = null
        challenge?.completion?.cancel(); challenge = null
        reservation?.cancel(); reservation = null; renewal?.cancel(); renewal = null
        publication?.completion?.cancel(); publication = null; controlDrain?.cancel(); controlDrain = null
        pendingControl = null; lastReadySequence = 0; coveredReadySequence = 0; lastReservationSupersessionSequence = 0
        policy?.cancel(); policy = null
        key?.fill(0); key = null; invitation?.erase(); invitation = null; inviteDeadline = 0
        auth = null; owner = null; member = null
        refresh = WatchPartyRefreshLedger(); retiredNonces = WatchPartyRetiredNonces(); connectedSeen = false; memberCount = 0
        mutableState.value = UiState(phase)
    }
    private fun main() { assertMainThread() }
}
