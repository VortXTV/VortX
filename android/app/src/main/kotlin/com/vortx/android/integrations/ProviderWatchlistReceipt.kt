package com.vortx.android.integrations

import com.vortx.android.engine.NativeProfileOverlayWitness
import java.math.BigDecimal
import java.time.Instant
import org.json.JSONArray
import org.json.JSONObject

/** Evidence from one correlated provider POST. The caller supplies its original body and raw
 * response bytes, and separately retains request, owner, credential and attempt authority. */
internal object ProviderWatchlistReceipt {
    enum class Operation(val successStatus: Int) {
        TRAKT_ADD(201), TRAKT_REMOVE(200), SIMKL_ADD(201),
    }

    enum class Outcome {
        ADDED, ALREADY_PRESENT, REMOVED, STATUS_CONFIRMED, ITEM_REPORTED_NOT_FOUND, UNVERIFIED,
    }

    private const val MAX_REQUEST_BYTES = 4_096
    private const val MAX_RESPONSE_BYTES = 32_768
    private const val PLAN_TO_WATCH = "plantowatch"
    private val traktBuckets = setOf("movies", "shows", "seasons", "episodes")
    private val simklAddedBuckets = setOf("movies", "shows", "anime")
    private val simklMissingBuckets = setOf("movies", "shows", "episodes")
    private val imdbId = Regex("tt[0-9]{1,20}")
    private val decimalId = Regex("[1-9][0-9]{0,9}")
    private val externalNumericId = Regex("[1-9][0-9]{0,19}")
    private val simklPositiveFields = setOf("ids", "to", "type", "title", "year", "anime_type")
    private val simklAnimeTypes = setOf("tv", "special", "ova", "movie", "music video", "ona")
    private val simklNumericKeys = setOf("tmdb", "tvdb", "mal", "anidb", "anilist", "kitsu")
    private val simklSlugKeys = setOf("slug", "tvdbslug", "traktslug", "letterboxd", "mdlslug")
    private val utcTimestamp = Regex("[0-9]{4}-[0-9]{2}-[0-9]{2}T(?:[01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](\\.[0-9]{1,9})?Z")

    fun evaluate(
        operation: Operation,
        exactRequestBody: ByteArray,
        status: Int,
        rawResponseBody: ByteArray,
    ): Outcome {
        if (status != operation.successStatus ||
            exactRequestBody.size !in 1..MAX_REQUEST_BYTES || rawResponseBody.size !in 1..MAX_RESPONSE_BYTES
        ) return Outcome.UNVERIFIED

        return try {
            val request = parseSubmittedItem(operation, NativeProfileOverlayWitness.parseDocument(exactRequestBody))
            val response = NativeProfileOverlayWitness.parseDocument(rawResponseBody)
            when (operation) {
                Operation.TRAKT_ADD, Operation.TRAKT_REMOVE -> trakt(operation, request, response)
                Operation.SIMKL_ADD -> simkl(request, response)
            }
        } catch (_: Exception) {
            Outcome.UNVERIFIED
        }
    }

    private data class SubmittedItem(val bucket: String, val idKey: String, val id: String) {
        val type: String get() = if (bucket == "movies") "movie" else "show"

        fun matches(ids: JSONObject, allowStringTmdb: Boolean): Boolean =
            identityValue(idKey, ids.opt(idKey), allowStringTmdb) == id
    }

    private fun parseSubmittedItem(operation: Operation, body: JSONObject): SubmittedItem {
        val bucket = body.namesSet().single()
        require(bucket == "movies" || bucket == "shows")
        val rows = body.getJSONArray(bucket)
        require(rows.length() == 1)
        val item = rows.getJSONObject(0)
        if (operation == Operation.SIMKL_ADD) {
            require(item.namesSet() == setOf("ids", "to") && item.opt("to") == PLAN_TO_WATCH)
        } else {
            require(item.namesSet() == setOf("ids"))
        }
        val ids = item.getJSONObject("ids")
        // One identifier avoids certifying a conflicting alias merely because the server echoed it.
        val key = ids.namesSet().single()
        val id = requireNotNull(identityValue(key, ids.get(key), allowStringTmdb = false))
        return SubmittedItem(bucket, key, id)
    }

    private fun trakt(operation: Operation, request: SubmittedItem, response: JSONObject): Outcome {
        val primary = if (operation == Operation.TRAKT_ADD) "added" else "deleted"
        val hasExisting = operation == Operation.TRAKT_ADD
        val fields = if (hasExisting) setOf(primary, "existing", "not_found", "list")
            else setOf(primary, "not_found", "list")
        require(response.namesSet() == fields)
        validateTraktList(response.getJSONObject("list"))
        val changed = traktCount(response.getJSONObject(primary), request.bucket)
        val existing = if (hasExisting) traktCount(response.getJSONObject("existing"), request.bucket) else 0
        val missing = soleItem(response.getJSONObject("not_found"), request.bucket, traktBuckets, nullable = true)
        if (missing != null) {
            require(changed == 0 && existing == 0 && missing.namesSet() == setOf("ids"))
            val ids = missing.getJSONObject("ids")
            require(ids.namesSet() == setOf(request.idKey) && request.matches(ids, allowStringTmdb = false))
            return Outcome.ITEM_REPORTED_NOT_FOUND
        }
        return when {
            changed == 1 && existing == 0 -> if (hasExisting) Outcome.ADDED else Outcome.REMOVED
            changed == 0 && existing == 1 -> Outcome.ALREADY_PRESENT
            else -> Outcome.UNVERIFIED
        }
    }

    private fun validateTraktList(list: JSONObject) {
        require(list.namesSet() == setOf("updated_at", "item_count"))
        val timestamp = list.get("updated_at") as? String ?: error("Invalid provider list timestamp")
        require(utcTimestamp.matches(timestamp))
        Instant.parse(timestamp)
        val itemCount = list.get("item_count") as? BigDecimal ?: error("Invalid provider list count")
        require(itemCount.longValueExact() >= 0)
    }

    private fun traktCount(counts: JSONObject, submittedBucket: String): Int {
        require(counts.namesSet() == traktBuckets)
        var matched = 0
        for (bucket in traktBuckets) {
            val value = counts.get(bucket) as? BigDecimal ?: error("Invalid provider count")
            when {
                value.signum() == 0 -> Unit
                bucket == submittedBucket && value.compareTo(BigDecimal.ONE) == 0 -> matched = 1
                else -> error("Provider count exceeds request")
            }
        }
        return matched
    }

    private fun simkl(request: SubmittedItem, response: JSONObject): Outcome {
        require(response.namesSet() == setOf("added", "not_found"))
        val added = soleItem(response.getJSONObject("added"), request.bucket, simklAddedBuckets)
        val missing = soleItem(response.getJSONObject("not_found"), request.bucket, simklMissingBuckets)
        require(added == null || missing == null)
        if (added != null) {
            require(added.namesSet().all { it in simklPositiveFields })
            require(added.opt("to") == PLAN_TO_WATCH && added.opt("type") == request.type)
            validateSimklMetadata(added, request.bucket)
            val ids = added.getJSONObject("ids")
            validateSimklIds(ids, request.bucket)
            require(request.matches(ids, allowStringTmdb = true))
            return Outcome.STATUS_CONFIRMED
        }
        if (missing == null) return Outcome.UNVERIFIED
        require(missing.namesSet() == setOf("ids", "to") || missing.namesSet() == setOf("ids", "to", "type"))
        require(missing.opt("to") == PLAN_TO_WATCH && (!missing.has("type") || missing.opt("type") == request.type))
        val ids = missing.getJSONObject("ids")
        require(ids.namesSet() == setOf(request.idKey) && request.matches(ids, allowStringTmdb = false))
        return Outcome.ITEM_REPORTED_NOT_FOUND
    }

    private fun validateSimklMetadata(item: JSONObject, bucket: String) {
        if (item.has("title")) require(validMetadataText(item.get("title"), 512))
        if (item.has("year")) {
            val year = item.get("year") as? BigDecimal ?: error("Invalid provider year")
            require(year.intValueExact() in 1..9_999)
        }
        if (item.has("anime_type")) {
            val animeType = item.get("anime_type")
            require(animeType === JSONObject.NULL || bucket == "shows" && animeType is String && animeType in simklAnimeTypes)
        }
    }

    private fun validateSimklIds(ids: JSONObject, bucket: String) {
        require(bucket == "movies" || !ids.has("letterboxd"))
        var canonical: Long? = null
        for (key in ids.namesSet()) {
            val value = ids.get(key)
            when (key) {
                "simkl", "simkl_id" -> {
                    val number = value as? BigDecimal ?: error("Invalid canonical Simkl ID")
                    val parsed = number.longValueExact()
                    require(parsed > 0 && (canonical == null || canonical == parsed))
                    canonical = parsed
                }
                "imdb" -> require(value is String && imdbId.matches(value))
                in simklNumericKeys -> require(value is String && externalNumericId.matches(value))
                in simklSlugKeys -> require(validMetadataText(value, 256) && value is String && value.none(Char::isWhitespace))
                else -> error("Unknown provider ID")
            }
        }
    }

    private fun validMetadataText(value: Any?, maxLength: Int): Boolean =
        value is String && value.length <= maxLength && value.isNotBlank() && value.none(Char::isISOControl)

    /** Reports can omit optional buckets. Any present entry must be the sole submitted title. */
    private fun soleItem(
        report: JSONObject,
        submittedBucket: String,
        knownBuckets: Set<String>,
        nullable: Boolean = false,
    ): JSONObject? {
        var item: JSONObject? = null
        for (bucket in report.namesSet()) {
            require(bucket in knownBuckets)
            val value = report.get(bucket)
            if (nullable && value === JSONObject.NULL) continue
            val rows = value as? JSONArray ?: error("Invalid provider report")
            if (rows.length() == 0) continue
            require(bucket == submittedBucket && rows.length() == 1)
            item = rows.getJSONObject(0)
        }
        return item
    }

    private fun identityValue(key: String, raw: Any?, allowStringTmdb: Boolean): String? = when (key) {
        "imdb" -> (raw as? String)?.takeIf(imdbId::matches)
        "tmdb" -> when (raw) {
            is BigDecimal -> try {
                raw.intValueExact().takeIf { it > 0 }?.toString()
            } catch (_: ArithmeticException) { null }
            is String -> raw.takeIf { allowStringTmdb && decimalId.matches(it) && it.toIntOrNull() != null }
            else -> null
        }
        else -> null
    }

    private fun JSONObject.namesSet(): Set<String> = keys().asSequence().toSet()
}
