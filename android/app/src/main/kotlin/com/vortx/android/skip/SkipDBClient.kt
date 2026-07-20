package com.vortx.android.skip

import android.util.Log
import kotlinx.coroutines.async
import kotlinx.coroutines.supervisorScope
import org.json.JSONObject

/// Submission client for skip segments, the Kotlin port of `app/SourcesShared/SkipDBClient.swift`. A submit
/// fires up to THREE legs concurrently:
///  - skip.vortx.tv (our self-hosted, keyless worker): ALWAYS, no API key required. This is the
///    authoritative leg; overall success means our worker accepted the segment. VortX edge-signed.
///  - api.skipdb.tv (the community database we mirror reads from): best-effort, ONLY when the user has
///    configured a skipdb.tv API key. A missing key or a community-side failure never blocks success.
///  - the user's optional custom SkipDB-compatible provider: best-effort, ONLY when configured. A
///    THIRD-PARTY host, so it is NOT VortX edge-signed.
/// Reads are handled by [SkipTimestampService].
object SkipDBClient {

    private const val TAG = "skipsubmit"

    /// Thrown only when the authoritative skip.vortx.tv leg fails. Carries a user-facing message.
    class SkipDBException(val code: Int, val serverMessage: String?) : Exception(
        when (code) {
            429 -> serverMessage ?: "Too many submissions, try again in a bit."
            400 -> serverMessage ?: "That segment was rejected (check the times)."
            else -> serverMessage ?: "Skip submission failed ($code)."
        },
    )

    /// Shared body shape for both legs. `season`/`episode` are omitted (or sent as 0) for a film; both
    /// endpoints treat either as "no episode". `segmentType` is intro|recap|outro|preview (credits map to
    /// "outro" upstream of here). Mirrors Apple `SkipDBClient.SubmitRequest`.
    data class SubmitRequest(
        val imdbId: String,
        val season: Int?,
        val episode: Int?,
        val segmentType: String,
        val startMs: Int,
        val endMs: Int,
        val durationMs: Int?,
    ) {
        fun toJson(): String {
            val o = JSONObject()
            o.put("imdb_id", imdbId)
            o.put("season", season ?: JSONObject.NULL)
            o.put("episode", episode ?: JSONObject.NULL)
            o.put("segment_type", segmentType)
            o.put("start_ms", startMs)
            o.put("end_ms", endMs)
            o.put("duration_ms", durationMs ?: JSONObject.NULL)
            return o.toString()
        }
    }

    /// Submit to all databases. Throws [SkipDBException] only when the authoritative skip.vortx.tv leg
    /// fails; the community + custom legs are best-effort and their outcome is logged but never surfaced.
    /// Mirrors Apple `SkipDBClient.submit`.
    ///
    /// Uses [supervisorScope], NOT [kotlinx.coroutines.coroutineScope]: the authoritative vortx leg can
    /// throw, and under a plain coroutineScope that failure would cancel the sibling community/custom
    /// children mid-flight, so the best-effort legs would NOT always run to completion, exactly when the
    /// primary fails. A SupervisorJob keeps the children independent, so the community/custom legs still
    /// finish while the vortx failure is surfaced via its own `await()`, matching Apple's async-let, where
    /// the best-effort legs are awaited independently and always complete.
    suspend fun submit(req: SubmitRequest) = supervisorScope {
        // Run all legs concurrently. The community + custom legs are gated on their own config.
        val vortx = async { submitToVortX(req) }
        val community = async { submitToCommunity(req) }
        val custom = async { submitToCustom(req) }
        // The best-effort legs never throw; await them so their tasks complete and log (a vortx failure
        // cannot cancel them under supervisorScope).
        community.await()
        custom.await()
        // Authoritative leg: propagate its failure to the caller.
        vortx.await()
    }

    /// Our keyless worker. No Authorization header; VortX edge-signed by [SkipHttp].
    private suspend fun submitToVortX(req: SubmitRequest) {
        val res = SkipHttp.request(
            method = "POST",
            urlString = "https://skip.vortx.tv/skip/contribute",
            body = req.toJson(),
            timeoutMs = SkipHttp.SUBMIT_TIMEOUT_MS,
        )
        if (res.status == 0) throw SkipDBException(res.status, null)
        if (res.status !in 200..299) {
            // Errors come back as {"ok": false, "error": "..."}; surface the message ONLY when `error` is a
            // genuine JSON string (Apple's `JSONValue.stringValue` returns nil for a bool/number, falling
            // back to the generic per-code message), so a non-string `error` value does not leak here.
            val msg = runCatching {
                val o = JSONObject(res.body)
                if (o.has("error") && o.get("error") is String) o.getString("error").ifBlank { null } else null
            }.getOrNull()
            throw SkipDBException(res.status, msg)
        }
    }

    /// The community skipdb.tv leg. Best-effort: no key means no submission and no error; any failure is
    /// logged, not thrown. We give back to the database we read from when the user opts in with a key.
    private suspend fun submitToCommunity(req: SubmitRequest) {
        val key = SkipConfig.skipDBKey() ?: return // no key: silently skip, our worker has it
        val res = SkipHttp.request(
            method = "POST",
            urlString = "https://api.skipdb.tv/api/segments",
            headers = mapOf("Authorization" to "Bearer $key"),
            body = req.toJson(),
            timeoutMs = SkipHttp.SUBMIT_TIMEOUT_MS,
        )
        if (!res.isSuccess) Log.i(TAG, "skipdb.tv submit returned ${res.status} (best-effort, ignored)")
    }

    /// The user's optional custom SkipDB-compatible leg. Best-effort, exactly like the community leg. NOT
    /// VortX edge-signed: third-party host.
    private suspend fun submitToCustom(req: SubmitRequest) {
        val base = CustomSkipProvider.baseURL() ?: return // no/invalid URL: silently skip
        val headers = SkipConfig.customSkipKey()?.let { mapOf("Authorization" to "Bearer $it") } ?: emptyMap()
        val res = SkipHttp.request(
            method = "POST",
            urlString = "$base/api/segments",
            headers = headers,
            body = req.toJson(),
            timeoutMs = SkipHttp.SUBMIT_TIMEOUT_MS,
        )
        if (!res.isSuccess) Log.i(TAG, "custom skip provider submit returned ${res.status} (best-effort, ignored)")
    }

    /// Remove the cached VortX skip entry for an episode so the next fetch picks up the submission. Mirrors
    /// Apple `SkipDBClient.invalidateCache`.
    suspend fun invalidateCache(imdbId: String, season: Int?, episode: Int?, durationSeconds: Double) {
        val key = SkipTimestampService.vortxCacheKey(imdbId, season, episode, durationSeconds)
        SkipTimestampService.storeOrNull()?.invalidate(key)
    }
}
