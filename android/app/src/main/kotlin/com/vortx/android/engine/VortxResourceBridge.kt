package com.vortx.android.engine

import kotlinx.coroutines.suspendCancellableCoroutine
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

internal data class VortxResourceRequest(
    val resource: Resource,
    val type: String,
    val id: String,
    val extra: List<Pair<String, String>> = emptyList(),
) {
    enum class Resource(val wire: String, val contentKey: String) {
        CATALOG("catalog", "metas"), META("meta", "meta"), STREAM("stream", "streams"),
        SUBTITLES("subtitles", "subtitles"), ADDON_CATALOG("addon_catalog", "addons"), MANIFEST("manifest", ""),
    }
    fun json(): JSONObject = JSONObject().put("resource", resource.wire).put("type", type).put("id", id)
        .put("extra", JSONArray().also { array -> extra.forEach { array.put(JSONArray().put(it.first).put(it.second)) } })

    fun matches(value: JSONObject): Boolean {
        if (value.opt("resource") != resource.wire || value.opt("type") != type || value.opt("id") != id) return false
        val pairs = value.optJSONArray("extra") ?: return false
        if (pairs.length() != extra.size) return false
        return extra.indices.all { index ->
            val pair = pairs.optJSONArray(index)
            pair != null && pair.length() == 2 && pair.opt(0) == extra[index].first && pair.opt(1) == extra[index].second
        }
    }
}

/** Manifest bytes are retained only for this in-memory request, including configured transport URLs. */
internal data class VortxResourceAddon(val id: String, val transportUrl: String, val manifestJson: String? = null) {
    fun json(): JSONObject = JSONObject().put("id", id).put("transportUrl", transportUrl).also {
        if (manifestJson != null) it.put("manifest", JSONObject(manifestJson))
    }
}

internal data class VortxResourceGroup(val addonId: String, val status: String, val contentJson: String?, val errorCode: String?) {
    /** Exact protocol objects; includes every source/subtitle option and unknown provider extension. */
    fun items(resource: VortxResourceRequest.Resource): List<JSONObject> {
        if (status != "ready") return emptyList()
        val content = JSONObject(requireNotNull(contentJson) { "Ready resource has no content" })
        if (resource == VortxResourceRequest.Resource.MANIFEST) return listOf(content)
        if (resource == VortxResourceRequest.Resource.META) {
            require(content.has("meta")) { "Metadata payload missing" }
            return if (content.isNull("meta")) emptyList() else listOf(content.getJSONObject("meta"))
        }
        val array = content.getJSONArray(resource.contentKey)
        return (0 until array.length()).map(array::getJSONObject)
    }
}

internal data class VortxResourceSnapshot(
    val ownerId: String, val requestId: String, val generation: Long,
    val request: VortxResourceRequest, val groups: List<VortxResourceGroup>,
    val sourceUrls: Map<String, String>,
)

internal interface VortxResourceCancellation : AutoCloseable { fun cancel() }
internal interface VortxResourceTransport {
    fun makeCancellation(): VortxResourceCancellation
    fun load(requestJson: String, cancellation: VortxResourceCancellation): String
}

/** One consumer per bridge. Owner invalidation, cancellation and new loads all revoke publication.
 * No preferences or credential storage. Late native completions cannot overwrite a newer selection.
 */
internal class VortxResourceBridge(
    private val transport: VortxResourceTransport,
    private val workers: ExecutorService = Executors.newFixedThreadPool(4),
) : AutoCloseable {
    private data class Lease(val owner: String, val id: String, val generation: Long)
    private var sequence = 0L
    private var current: Lease? = null
    private var token: VortxResourceCancellation? = null
    private var closed = false

    @Synchronized fun invalidate() {
        current = null
        token?.cancel()
        token = null
    }

    @Synchronized override fun close() {
        closed = true
        invalidate()
        workers.shutdown() // queued tasks finish and free their own handles; never free under a load
    }

    @Synchronized fun accepts(snapshot: VortxResourceSnapshot): Boolean =
        !closed && current == Lease(snapshot.ownerId, snapshot.requestId, snapshot.generation)

    @Synchronized private fun begin(owner: String, cancellation: VortxResourceCancellation): Lease {
        check(!closed && sequence < Long.MAX_VALUE) { "Resource bridge closed" }
        token?.cancel()
        val lease = Lease(owner, UUID.randomUUID().toString(), ++sequence)
        current = lease
        token = cancellation
        return lease
    }

    @Synchronized private fun cancel(lease: Lease, cancellation: VortxResourceCancellation) {
        if (current == lease) { current = null; token = null }
        cancellation.cancel()
    }

    suspend fun load(ownerId: String, request: VortxResourceRequest, addons: List<VortxResourceAddon>,
                     budgetMs: Long = 5000, maxResponseBytes: Long = 8_388_608): VortxResourceSnapshot {
        require(ownerId.isNotEmpty() && addons.all { it.id.isNotEmpty() } && addons.map { it.id }.toSet().size == addons.size)
        require(budgetMs in 1..60_000 && maxResponseBytes in 1..33_554_432)
        // Serialize caller-owned collections before starting work, so later UI mutation cannot change
        // which request the result claims to answer. The returned request is immutable below too.
        val capturedRequest = request.copy(extra = request.extra.toList())
        val capturedAddons = addons.toList()
        val addonJSON = JSONArray().also { array -> capturedAddons.forEach { array.put(it.json()) } }
        val cancellation = transport.makeCancellation()
        val lease = try { begin(ownerId, cancellation) } catch (error: Throwable) { cancellation.close(); throw error }
        val wire = JSONObject().put("requestId", lease.id).put("generation", lease.generation)
            .put("request", capturedRequest.json()).put("addons", addonJSON)
            .put("budgetMs", budgetMs).put("maxResponseBytes", maxResponseBytes).toString()
        return suspendCancellableCoroutine { continuation ->
            continuation.invokeOnCancellation { cancel(lease, cancellation) }
            try {
                workers.execute {
                    try {
                        val result = JSONObject(transport.load(wire, cancellation))
                        require(result.getString("kind") == "resource_result" && result.getString("requestId") == lease.id)
                        require(result.get("generation") is Number && result.get("generation").toString() == lease.generation.toString())
                        require(capturedRequest.matches(result.getJSONObject("request"))) { "Mismatched resource request" }
                        check(!result.getBoolean("cancelled")) { "Resource request cancelled" }
                        val array = result.getJSONArray("groups")
                        val groups = (0 until array.length()).map { index ->
                            val group = array.getJSONObject(index)
                            val status = group.getString("status")
                            require(status in setOf("ready", "error", "timeout", "cancelled"))
                            VortxResourceGroup(group.getString("addonId"), status, group.optJSONObject("content")?.toString(),
                                group.optJSONObject("error")?.getString("code"))
                        }
                        require(groups.map { it.addonId }.toSet().size == groups.size)
                        require(groups.all { group -> capturedAddons.any { it.id == group.addonId } })
                        groups.forEach { group ->
                            val items = group.items(capturedRequest.resource)
                            if (group.status == "ready") require(requireNotNull(group.contentJson).toByteArray(Charsets.UTF_8).size <= maxResponseBytes) {
                                "Resource response exceeded body limit"
                            }
                            if (capturedRequest.resource == VortxResourceRequest.Resource.META) require(items.all {
                                it.getString("id") == capturedRequest.id && it.getString("type") == capturedRequest.type
                            }) { "Metadata response identity mismatch" }
                        }
                        val snapshot = VortxResourceSnapshot(ownerId, lease.id, lease.generation, capturedRequest, groups,
                            capturedAddons.associate { it.id to it.transportUrl })
                        check(accepts(snapshot)) { "Resource request superseded" }
                        continuation.resume(snapshot)
                    } catch (error: Throwable) { continuation.resumeWithException(error) }
                    finally { cancellation.close() }
                }
            } catch (error: Throwable) {
                cancel(lease, cancellation)
                cancellation.close()
                continuation.resumeWithException(error)
            }
        }
    }
}

/** Host free is deferred until every in-flight blocking JNI call returns. */
internal class VortxJniResourceTransport : VortxResourceTransport, AutoCloseable {
    private var host = run {
        check(VortxCore.isAvailable()) { "Native engine unavailable" }
        check(VortxCore.nativeResourceHostAbiVersion() == 1) { "Native resource ABI mismatch" }
        VortxCore.nativeResourceHostNew().also { check(it != 0L) { "Native resource host unavailable" } }
    }
    private var users = 0
    private var closed = false

    @Synchronized override fun close() { closed = true; freeIfIdle() }
    @Synchronized private fun acquire(): Long { check(!closed); users++; return host }
    @Synchronized private fun release() { users--; freeIfIdle() }
    private fun freeIfIdle() {
        if (closed && users == 0 && host != 0L) { val old = host; host = 0; VortxCore.nativeResourceHostFree(old) }
    }
    override fun makeCancellation(): VortxResourceCancellation = Token()
    override fun load(requestJson: String, cancellation: VortxResourceCancellation): String {
        val pointer = acquire()
        try {
            val token = cancellation as Token
            return checkNotNull(VortxCore.nativeResourceHostLoadJson(pointer, requestJson, token.handle))
        } finally { release() }
    }
    private class Token : VortxResourceCancellation {
        var handle = VortxCore.nativeCancelNew().also { check(it != 0L) }
            private set
        @Synchronized override fun cancel() { if (handle != 0L) VortxCore.nativeCancelCancel(handle) }
        @Synchronized override fun close() {
            val old = handle; handle = 0
            if (old != 0L) VortxCore.nativeCancelFree(old)
        }
    }
}
