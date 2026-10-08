package com.vortx.android.library

import java.math.BigDecimal
import java.math.MathContext
import java.math.RoundingMode
import java.nio.CharBuffer
import java.nio.charset.CodingErrorAction
import java.util.Base64
import java.util.Locale
import java.util.UUID
import java.security.MessageDigest
import org.json.JSONArray
import org.json.JSONObject

/** Apple-compatible schema-1 per-item values. Register clocks/merging remain the host's authority. */
internal object NativeWatchlistCodec {
    const val PREFIX = "watchlist."
    const val MAX_FIELD_LENGTH = 704
    const val MAX_ENTRIES = 1_000
    private const val MAX_NUMBER = 9_007_199_254_740_991L
    private val safeId = Regex("(?:tt|tmdb)[A-Za-z0-9:._-]*")
    private val types = setOf("movie", "series")
    private val entryKeys = setOf("id", "type", "name", "poster", "addedAt")

    data class Identity(val type: String, val id: String)

    fun field(id: String, type: String): String {
        require(type in types && id.isNotEmpty() && utf8(id).size <= 512 && safeId.matches(id)) {
            "This title cannot be added to Watchlist."
        }
        return "$PREFIX$type.${Base64.getUrlEncoder().withoutPadding().encodeToString(utf8(id))}"
    }

    fun identity(field: String): Identity {
        require(field.length <= MAX_FIELD_LENGTH)
        val parts = field.split('.')
        require(parts.size == 3 && parts[0] == "watchlist") { "Invalid Watchlist identity" }
        val bytes = Base64.getUrlDecoder().decode(parts[2])
        val id = Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT).decode(java.nio.ByteBuffer.wrap(bytes)).toString()
        require(field(id, parts[1]) == field) { "Noncanonical Watchlist identity" }
        return Identity(parts[1], id)
    }

    /** Validate tombstones as well as live entries; a malformed key cannot bypass the wire contract. */
    fun validate(field: String, value: Any) {
        val identity = identity(field)
        if (value == JSONObject.NULL) return
        require(value is JSONObject) { "Invalid Watchlist value" }
        val entry = entry(value)
        require(entry.id == identity.id && entry.type == identity.type) { "Mismatched Watchlist value" }
    }

    fun value(entry: WatchlistEntry): JSONObject = JSONObject().apply {
        put("id", entry.id)
        put("type", entry.type)
        entry.name?.let { put("name", it) }
        entry.poster?.let { put("poster", it) }
        put("addedAt", entry.addedAt)
    }.also { validate(field(entry.id, entry.type), it) }

    fun change(entry: WatchlistEntry, watchlisted: Boolean): JSONObject = JSONObject().put(
        field(entry.id, entry.type), if (watchlisted) value(entry) else JSONObject.NULL,
    )

    /** No cap trim: converged independent additions must remain visible, including more than 1,000. */
    fun entries(registers: JSONObject): List<WatchlistEntry> = buildList {
        for (field in registers.keys().asSequence().filter { it.startsWith(PREFIX) }) {
            val register = registers.getJSONObject(field)
            require(register.keys().asSequence().toSet() == setOf("clock", "actor", "value"))
            val rawClock = register.get("clock")
            require(rawClock is Number && BigDecimal(rawClock.toString()).longValueExact() in 0..MAX_NUMBER)
            val actor = register.getString("actor")
            require(UUID.fromString(actor).toString() == actor) { "Invalid Watchlist actor" }
            val value = register.get("value")
            validate(field, value)
            if (value != JSONObject.NULL) add(entry(value as JSONObject))
        }
    }.sortedWith(compareByDescending<WatchlistEntry> { it.addedAt }.thenBy { it.type }.thenBy { it.id })

    /** Only the authenticated cloud-import owner may call this; local arrays are not native proof. */
    fun legacyEntries(array: JSONArray): List<WatchlistEntry> {
        require(array.length() <= MAX_ENTRIES) { "Legacy Watchlist exceeds the import limit" }
        val values = (0 until array.length()).map { entry(array.getJSONObject(it)) }
        require(values.map { field(it.id, it.type) }.distinct().size == values.size) { "Duplicate Watchlist identity" }
        return values
    }

    fun requireAdditionCapacity(entries: List<WatchlistEntry>, id: String, type: String) {
        if (entries.none { it.id == id && it.type == type }) check(entries.size < MAX_ENTRIES) {
            "This watchlist has 1,000 titles. Remove a title before adding another; no existing titles were deleted."
        }
    }

    /**
     * Clock-zero authenticated seed event, not a native edit. Content-addressed actors avoid equal
     * clock/actor equivocation when two authenticated legacy snapshots have different metadata.
     * The same normalized value() must also be the seeded register value. No UUID bit rewriting.
     */
    fun baselineActor(profileId: String, entry: WatchlistEntry): String {
        val canonical = baselineCanonicalJSON(profileId, entry)
        val hex = MessageDigest.getInstance("SHA-256").digest(utf8(canonical)).joinToString("") {
            (it.toInt() and 255).toString(16).padStart(2, '0')
        }.take(32)
        return "${hex.take(8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}"
    }

    internal fun baselineCanonicalJSON(profileId: String, entry: WatchlistEntry): String {
        require(UUID.fromString(profileId).toString().uppercase(Locale.ROOT) == profileId) { "Noncanonical Watchlist profile" }
        val normalized = value(entry)
        val encoded = normalized.keys().asSequence().sorted().joinToString(",", "{", "}") { key ->
            jsQuote(key) + ":" + when (val item = normalized.get(key)) {
                is String -> jsQuote(item)
                is Number -> canonicalSeconds(item.toDouble())
                else -> error("Invalid normalized Watchlist entry")
            }
        }
        return "{\"domain\":\"vortx-watchlist-baseline-v1\",\"field\":${jsQuote(field(entry.id, entry.type))},\"profileId\":${jsQuote(profileId)},\"value\":$encoded}"
    }

    /** JS shortest-roundtrip binary64, including subnormals; never platform JSONObject quoting. */
    internal fun canonicalSeconds(number: Double): String {
        require(number.isFinite() && number >= 0 && number <= MAX_NUMBER.toDouble())
        if (number == 0.0) return "0"
        val exact = BigDecimal(number)
        val shortest = (1..17).firstNotNullOf { precision ->
            listOf(RoundingMode.FLOOR, RoundingMode.CEILING).map { exact.round(MathContext(precision, it)).stripTrailingZeros() }
                .distinct().filter { it.toDouble() == number }
                .minWithOrNull(compareBy<BigDecimal> { it.subtract(exact).abs() }.thenBy { it.unscaledValue().testBit(0) })
        }
        if (number >= 1e-6) return shortest.toPlainString()
        val digits = shortest.unscaledValue().toString()
        val coefficient = if (digits.length == 1) digits else "${digits.first()}.${digits.drop(1)}"
        return "${coefficient}e${shortest.precision() - shortest.scale() - 1}"
    }

    private fun jsQuote(text: String): String {
        utf8(text) // Reject malformed surrogate strings before hashing or emitting a seed.
        return buildString {
            append('"')
            for (char in text) when (char) {
                '"' -> append("\\\"")
                '\\' -> append("\\\\")
                '\b' -> append("\\b")
                '\u000C' -> append("\\f")
                '\n' -> append("\\n")
                '\r' -> append("\\r")
                '\t' -> append("\\t")
                else -> if (char.code < 32) append("\\u${char.code.toString(16).padStart(4, '0')}") else append(char)
            }
            append('"')
        }
    }

    private fun entry(value: JSONObject): WatchlistEntry {
        val keys = value.keys().asSequence().toSet()
        require(keys.all { it in entryKeys } && keys.containsAll(setOf("id", "type", "addedAt")))
        val id = value.get("id").also { require(it is String) } as String
        val type = value.get("type").also { require(it is String) } as String
        field(id, type)
        val rawAddedAt = value.get("addedAt")
        require(rawAddedAt is Number)
        val addedAt = rawAddedAt.toDouble()
        require(addedAt.isFinite() && addedAt >= 0 && addedAt <= MAX_NUMBER.toDouble())
        fun optionalString(key: String, limit: Int): String? {
            if (!value.has(key) || value.isNull(key)) return null
            return (value.get(key).also { require(it is String) } as String).also { require(utf8(it).size <= limit) }
        }
        return WatchlistEntry(id, type, optionalString("name", 4_096), optionalString("poster", 8_192), addedAt)
    }

    private fun utf8(value: String): ByteArray {
        val encoded = Charsets.UTF_8.newEncoder().onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT).encode(CharBuffer.wrap(value))
        return ByteArray(encoded.remaining()).also { encoded.get(it) }
    }
}
