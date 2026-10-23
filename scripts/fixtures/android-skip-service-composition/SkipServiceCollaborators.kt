package com.vortx.android.skip

import android.content.Context
import java.io.File
import org.json.JSONObject

// Synthetic collaborator boundary only. No network, filesystem, credentials, TTL, or Android services.
data class StoredSpan(val kind: String, val startMs: Int?, val endMs: Int?)

class SkipTimestampStore(val file: File) {
    data class Entry(val fetchedAt: Long, val spans: List<StoredSpan>, val introEstimateMs: Int? = null) {
        companion object { fun miss() = Entry(System.currentTimeMillis(), emptyList()) }
    }
    private val rows = linkedMapOf<String, Entry>()
    val reads = mutableListOf<String>()
    val writes = mutableListOf<Pair<String, Entry>>()
    suspend fun entry(key: String): Entry? { reads += key; return rows[key] }
    suspend fun store(entry: Entry, key: String) { writes += key to entry; rows[key] = entry }
    suspend fun invalidate(key: String) { rows.remove(key) }
    fun seed(key: String, entry: Entry) { rows[key] = entry }
    fun snapshot(): Map<String, Entry> = rows.toMap()
    fun reset() { rows.clear(); reads.clear(); writes.clear() }
}

// Same conserved helper semantics as actual SkipTimestampStore.kt; persistence is deliberately omitted.
internal fun JSONObject.optIntOrNull(key: String): Int? {
    if (!has(key) || isNull(key)) return null
    return optInt(key)
}

internal object SkipHttp {
    data class Result(val status: Int, val body: String)
    data class Request(val method: String, val url: String, val headers: Map<String, String>)
    val requests = mutableListOf<Request>()
    private val replies = linkedMapOf<String, Result>()
    fun reply(prefix: String, status: Int, body: String = "") { replies[prefix] = Result(status, body) }
    fun reset() { requests.clear(); replies.clear() }
    suspend fun request(method: String, urlString: String, headers: Map<String, String> = emptyMap()): Result {
        requests += Request(method, urlString, headers.toMap())
        replies.entries.firstOrNull { urlString.startsWith(it.key) }?.let { return it.value }
        // The two always-selected IMDb legs may fail softly when a test isolates another provider.
        if (urlString.startsWith("https://skip.vortx.tv/skip?") ||
            urlString.startsWith("https://api.skipdb.tv/api/segments?")) return Result(503, "")
        throw AssertionError("Unexpected synthetic HTTP request: $urlString")
    }
}

object SkipConfig {
    var provider: String = "theintrodb"
    var communityKey: String? = null
    var customKey: String? = null
    fun init(context: Context) {}
    fun skipDBKey(): String? = communityKey
    fun customSkipKey(): String? = customKey
    fun reset() { provider = "theintrodb"; communityKey = null; customKey = null }
}

object CustomSkipProvider {
    var base: String? = null
    var hostname: String? = null
    fun baseURL(): String? = base
    fun host(): String? = hostname
    fun reset() { base = null; hostname = null }
}

object AniSkipService {
    data class Call(val id: String, val episode: Int?, val duration: Double)
    val calls = mutableListOf<Call>()
    var result: List<SegmentCandidate> = emptyList()
    fun supports(metaId: String): Boolean = metaId.startsWith("mal:")
    suspend fun candidates(metaId: String, episode: Int?, durationSeconds: Double): List<SegmentCandidate> {
        calls += Call(metaId, episode, durationSeconds)
        return result
    }
    fun reset() { calls.clear(); result = emptyList() }
}
