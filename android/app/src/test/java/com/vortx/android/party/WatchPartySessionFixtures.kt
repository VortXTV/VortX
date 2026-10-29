package com.vortx.android.party

import com.vortx.android.player.PlaybackOwnerToken
import com.vortx.android.sync.WatchPartyAuthSnapshot
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.ReceiveChannel
import org.json.JSONObject

/** Disposable fixtures drive the real session; no network, real account or player exists here. */
internal class SessionAuth : WatchPartyAuthAuthority {
    private var token = PlaybackOwnerToken()
    var profile = "profile-a"
    var generation = 1L
    private val account = "12345678-1234-1234-1234-123456789abc"
    override fun capture(): WatchPartyAuthSnapshot? = WatchPartyAuthSnapshot.capture(
        "synthetic-bearer", account, profile, generation, generation, generation, token,
    )
    override fun isCurrent(snapshot: WatchPartyAuthSnapshot): Boolean =
        capture()?.let(snapshot::sameAuthorityAs) == true
    fun rotate(newProfile: String) { token.retire(); token = PlaybackOwnerToken(); profile = newProfile; generation++ }
    fun owner(): WatchPartyOwnerStamp = WatchPartyOwnerStamp(
        "local-owner-$generation", 1, 1, "T".repeat(43), account, profile, generation,
    )
}

internal class SessionSocket : WatchPartySocket {
    private val readyValue = CompletableDeferred<Unit>()
    override val ready: Deferred<Unit> = readyValue
    private val incoming = Channel<String>(Channel.UNLIMITED)
    override val frames: ReceiveChannel<String> = incoming
    val sent = mutableListOf<JSONObject>()
    var closed = false
    fun open() { readyValue.complete(Unit) }
    fun frame(value: JSONObject) { check(incoming.trySend(value.toString()).isSuccess) }
    fun tryFrame(value: JSONObject) = incoming.trySend(value.toString()).isSuccess
    override fun send(value: JSONObject) { check(!closed); sent += JSONObject(value.toString()) }
    override fun close() { closed = true; incoming.cancel() }
    override fun isActive() = !closed
    override fun isOpen() = !closed && readyValue.isCompleted
}

internal class SessionTransport : WatchPartyServiceTransport {
    data class Request(val path: String, val body: JSONObject, val result: CompletableDeferred<JSONObject>)
    val requests = mutableListOf<Request>()
    val sockets = mutableListOf<SessionSocket>()
    override suspend fun post(path: String, bearer: String, body: JSONObject): JSONObject {
        check(bearer == "synthetic-bearer")
        val result = CompletableDeferred<JSONObject>()
        requests += Request(path, JSONObject(body.toString()), result)
        return result.await()
    }
    override fun open(roomId: String, ticket: String): WatchPartySocket = SessionSocket().also { sockets += it }
}

internal object SessionValues {
    val roomId = "R".repeat(24)
    val generation = "G".repeat(24)
    val member = "M".repeat(24)
    val capability = "C".repeat(24)
    val ticket = "T".repeat(24)
    val invite = "I".repeat(24)
    val key = ByteArray(32) { (it + 1).toByte() }
    fun snapshot(sequence: Long = 0) = JSONObject().put("roomGeneration", generation).put("leaderTerm", 1)
        .put("serverSequence", sequence).put("leaseRemainingMs", 30_000).put("memberCount", 1)
    fun created() = JSONObject().put("roomId", roomId).put("leaderId", member).put("capability", capability)
        .put("inviteCode", invite).put("snapshot", snapshot())
    fun joined() = JSONObject().put("roomId", roomId).put("id", member).put("role", "member")
        .put("incarnation", 1).put("capability", capability).put("snapshot", snapshot())
    fun ticket() = JSONObject().put("ticket", ticket)
    fun connected(leader: Boolean, sequence: Long = 0) = JSONObject().put("kind", "connected")
        .put("role", if (leader) "leader" else "member").put("roomGeneration", generation)
        .put("leaderTerm", 1).put("serverSequence", sequence)
    fun proof(nonce: String, sequence: Long) = JSONObject().put("kind", "lease.proof").put("nonce", nonce)
        .put("roomGeneration", generation).put("leaderTerm", 1).put("serverSequence", sequence).put("leaseRemainingMs", 20_000)
    fun event(type: String, sequence: Long, ciphertext: String? = null) = JSONObject().put("type", type)
        .put("roomGeneration", generation).put("leaderTerm", 1).put("serverSequence", sequence)
        .put("memberCount", 2).also { if (ciphertext != null) it.put("ciphertext", ciphertext) }
}
