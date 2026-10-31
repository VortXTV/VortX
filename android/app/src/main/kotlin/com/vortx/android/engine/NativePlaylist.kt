package com.vortx.android.engine

import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import com.vortx.android.model.PreferredEpisode
import com.vortx.android.player.queue.PlaybackQueueEntry
import java.math.BigDecimal
import java.math.BigInteger
import java.util.ArrayDeque
import java.util.IdentityHashMap
import java.util.UUID
import org.json.JSONArray
import org.json.JSONObject

/** Android projection of the same profile-only `playlist.v1.<lowercase UUID>` wire register. */
internal object NativePlaylist {
    const val PREFIX = "playlist."
    const val V1_PREFIX = "playlist.v1."
    const val MAX_FIELD_BYTES = 512
    const val MAX_VALUE_BYTES = 512 * 1024
    private const val MAX_REGISTER_BYTES = MAX_VALUE_BYTES + 1024
    const val MAX_JSON_DEPTH = 64
    const val MAX_JSON_NODES = 65_536
    const val MAX_LIVE_PLAYLISTS = 32
    private val uuidPattern = Regex("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")

    internal data class Entry(
        val entryID: String,
        val contentID: String,
        val type: String,
        val title: String,
        val videoIDHint: String? = null,
        val episodeLabel: String? = null,
    )
    internal data class Document(val id: String, val name: String, val entries: List<Entry>)
    internal sealed interface Projection {
        data object Deleted : Projection
        data class Supported(val document: Document) : Projection
        data object Unsupported : Projection
    }

    fun field(id: UUID): String = V1_PREFIX + id.toString().lowercase()

    /** Host admission keeps unknown bounded playlist objects intact for older clients. */
    fun validateEnvelope(field: String, value: Any, global: Boolean) {
        require(field.startsWith(PREFIX))
        require(utf8LengthWithin(field, MAX_FIELD_BYTES, rejectControlAndFormat = true) != null) {
            "Invalid playlist field key"
        }
        require(!global) { "Playlists are profile-scoped" }
        if (field.startsWith(V1_PREFIX)) {
            val rawID = field.removePrefix(V1_PREFIX)
            require(canonicalUUID(rawID) != null) { "Invalid playlist field" }
        }
        if (value === JSONObject.NULL) return
        require(value is JSONObject) { "Playlist value must be object or null" }
        require(boundedJSONCost(value) != null) { "Playlist envelope is malformed or exceeds structural/cost limits" }
    }

    /** A queue entry is already catalog-only; map its stable metadata to the cross-platform wire DTO. */
    fun entryFromQueue(entry: PlaybackQueueEntry): Entry {
        val item = entry.item
        require(item.type == MediaType.MOVIE || item.type == MediaType.SERIES)
        val episode: PreferredEpisode? = item.preferredEpisode
        return Entry(
            entryID = canonicalUUID(entry.id) ?: error("Invalid queue entry ID"),
            contentID = item.id,
            type = item.type.id,
            title = item.name,
            videoIDHint = episode?.videoIdentity,
            episodeLabel = episode?.let { "S${it.season}E${it.episode}" },
        ).also(::validateEntry)
    }

    fun projection(field: String, value: Any): Projection {
        if (!field.startsWith(V1_PREFIX)) return Projection.Unsupported
        val registerID = canonicalUUID(field.removePrefix(V1_PREFIX)) ?: return Projection.Unsupported
        if (value === JSONObject.NULL) return Projection.Deleted
        val root = value as? JSONObject ?: return Projection.Unsupported
        if (boundedJSONCost(root) == null) return Projection.Unsupported
        val schema = root.opt("schema")
        if (schema !is Int && schema !is Long) return Projection.Unsupported
        if (schema.toLong() != 1L) return Projection.Unsupported
        if (root.keys().asSequence().toSet() != setOf("schema", "id", "name", "entries")) return Projection.Unsupported
        val id = root.optString("id", "")
        if (id != registerID) return Projection.Unsupported
        val name = root.opt("name") as? String ?: return Projection.Unsupported
        if (!validName(name)) return Projection.Unsupported
        val array = root.opt("entries") as? JSONArray ?: return Projection.Unsupported
        if (array.length() > 100) return Projection.Unsupported
        val seen = mutableSetOf<String>()
        val entries = ArrayList<Entry>(array.length())
        for (index in 0 until array.length()) {
            val row = array.opt(index) as? JSONObject ?: return Projection.Unsupported
            val keys = row.keys().asSequence().toSet()
            val required = setOf("entryID", "contentID", "type", "title")
            val allowed = required + setOf("videoIDHint", "episodeLabel")
            if (!keys.containsAll(required) || !allowed.containsAll(keys)) return Projection.Unsupported
            val entryID = row.opt("entryID") as? String ?: return Projection.Unsupported
            val contentID = row.opt("contentID") as? String ?: return Projection.Unsupported
            val type = row.opt("type") as? String ?: return Projection.Unsupported
            val title = row.opt("title") as? String ?: return Projection.Unsupported
            val hint = if (row.has("videoIDHint")) row.opt("videoIDHint") as? String ?: return Projection.Unsupported else null
            val label = if (row.has("episodeLabel")) row.opt("episodeLabel") as? String ?: return Projection.Unsupported else null
            val entry = Entry(entryID, contentID, type, title, hint, label)
            if (!seen.add(entryID) || !runCatching { validateEntry(entry) }.isSuccess) return Projection.Unsupported
            entries += entry
        }
        return Projection.Supported(Document(registerID, name, entries))
    }

    /** Pure observed-register admission. The facade still owns captured profile, raw CAS, and budget checks. */
    fun validateMutation(field: String, expectedRegister: JSONObject?, value: Any, profileFields: JSONObject) {
        require(field.startsWith(V1_PREFIX)) { "Invalid playlist field" }
        val id = canonicalUUID(field.removePrefix(V1_PREFIX)) ?: error("Invalid playlist field")
        val present = profileFields.has(field)
        val current = profileFields.optJSONObject(field)
        if (present) require(boundedRegisterValue(current ?: error("Invalid original register")) != null) {
            "Original playlist register is malformed or unbounded"
        }
        if (expectedRegister != null) require(boundedRegisterValue(expectedRegister) != null) {
            "Expected playlist register is malformed or unbounded"
        }
        require(if (present) current != null && expectedRegister != null && NativeHostPreferences.equal(current, expectedRegister)
                else expectedRegister == null) { "Stale playlist register" }
        if (!present) {
            require(value !== JSONObject.NULL) { "Cannot create from a tombstone" }
            val created = projection(field, value) as? Projection.Supported ?: error("Invalid playlist document")
            require(created.document.id == id)
            val live = profileFields.keys().asSequence().filter { it.startsWith(PREFIX) }
                .count { raw ->
                    val register = profileFields.optJSONObject(raw)
                    register?.opt("value") != JSONObject.NULL
                }
            require(live < MAX_LIVE_PLAYLISTS) { "Playlist creation limit reached" }
            return
        }
        val originalRegister = current ?: error("Invalid original register")
        val originalValue = originalRegister.opt("value") ?: error("Invalid original register")
        val original = projection(field, originalValue) as? Projection.Supported
            ?: error("Original playlist is unsupported or deleted")
        require(original.document.id == id)
        if (value === JSONObject.NULL) return
        val updated = projection(field, value) as? Projection.Supported ?: error("Invalid playlist document")
        require(updated.document.id == id)
    }

    fun encodedValue(document: Document): JSONObject {
        require(canonicalUUID(document.id) != null && validName(document.name))
        require(document.entries.size <= 100 && document.entries.map { it.entryID }.toSet().size == document.entries.size)
        val rows = JSONArray()
        document.entries.forEach { entry ->
            validateEntry(entry)
            val row = JSONObject().put("entryID", entry.entryID).put("contentID", entry.contentID)
                .put("type", entry.type).put("title", entry.title)
            entry.videoIDHint?.let { row.put("videoIDHint", it) }
            entry.episodeLabel?.let { row.put("episodeLabel", it) }
            rows.put(row)
        }
        return JSONObject().put("schema", 1).put("id", document.id).put("name", document.name).put("entries", rows)
            .also { require(boundedJSONCost(it) != null) { "Playlist value exceeds structural/cost limits" } }
    }

    private fun validateEntry(entry: Entry) {
        require(canonicalUUID(entry.entryID) != null)
        require(validText(entry.contentID, 1024) && entry.type in setOf("movie", "series"))
        require(validText(entry.title, 512))
        require(entry.videoIDHint == null || validText(entry.videoIDHint, 1024))
        require(entry.episodeLabel == null || validText(entry.episodeLabel, 512))
        require(entry.type == "series" || entry.videoIDHint == null || entry.videoIDHint == entry.contentID)
    }

    private fun validName(value: String): Boolean = utf8LengthWithin(value, 160, rejectControlAndFormat = true) != null &&
        value.isNotEmpty() && value == value.trim()

    private fun validText(value: String, maxBytes: Int): Boolean = utf8LengthWithin(value, maxBytes, rejectControlAndFormat = true) != null &&
        value.isNotBlank()

    /** Returns scalar UTF-8 length without allocating an encoder buffer. */
    private fun utf8LengthWithin(value: String, maximumBytes: Int, rejectControlAndFormat: Boolean): Int? {
        if (value.length > maximumBytes) return null
        var bytes = 0
        var index = 0
        while (index < value.length) {
            val current = value[index]
            val scalar = when {
                Character.isHighSurrogate(current) -> {
                    if (index + 1 >= value.length || !Character.isLowSurrogate(value[index + 1])) return null
                    Character.toCodePoint(current, value[index + 1]).also { index += 2 }
                }
                Character.isLowSurrogate(current) -> return null
                else -> current.code.also { index++ }
            }
            val category = Character.getType(scalar)
            if (rejectControlAndFormat && (category == Character.CONTROL.toInt() || category == Character.FORMAT.toInt())) return null
            val width = when {
                scalar <= 0x7F -> 1
                scalar <= 0x7FF -> 2
                scalar <= 0xFFFF -> 3
                else -> 4
            }
            if (width > maximumBytes - bytes) return null
            bytes += width
        }
        return bytes
    }

    /** Check the full observed register before NativeHostPreferences.equal performs raw CAS. */
    internal fun canonicalReceiptRegister(raw: JSONObject): ByteArray? {
        if (boundedRegisterValue(raw) == null) return null
        val bytes = NativeWebsiteProfileEdits.canonical(raw).toByteArray(Charsets.UTF_8)
        return bytes.takeIf { it.size <= 513 * 1024 }
    }

    private fun boundedRegisterValue(raw: JSONObject): Any? {
        if (boundedJSONCost(raw, MAX_REGISTER_BYTES) == null || raw.keys().asSequence().toSet() != setOf("clock", "actor", "value")) return null
        val clock = raw.opt("clock") as? Number ?: return null
        val validClock = runCatching { BigDecimal(clock.toString()).longValueExact() }
            .getOrNull()?.let { it in 0..NativeHostPreferences.MAX_CLOCK } == true
        if (!validClock || canonicalUUID(raw.opt("actor") as? String ?: "") == null) return null
        val value = raw.opt("value") ?: return null
        if (value === JSONObject.NULL) return value
        if (value !is JSONObject || boundedJSONCost(value) == null) return null
        return value
    }

    private data class JSONWork(val value: Any, val depth: Int, val exitContainer: Boolean = false)

    /**
     * Shared conservative JSON-cost admission. It is iterative, depth/node bounded, cycle safe, and
     * runs before JSONObject/JSONEncoder serialization. String cost covers raw and escaped JSON text;
     * every admitted number reserves the same 64-byte allowance on both platforms.
     */
    private fun boundedJSONCost(root: JSONObject, maximumBytes: Int = MAX_VALUE_BYTES): Int? {
        val pending = ArrayDeque<JSONWork>()
        val activeContainers = IdentityHashMap<Any, Boolean>()
        pending.addLast(JSONWork(root, 0))
        var nodes = 1
        var cost = 0

        fun add(amount: Int): Boolean {
            if (amount < 0 || amount > maximumBytes - cost) return false
            cost += amount
            return true
        }
        fun addString(text: String): Boolean {
            if (!add(2)) return false
            var index = 0
            while (index < text.length) {
                val current = text[index]
                val scalar = when {
                    Character.isHighSurrogate(current) -> {
                        if (index + 1 >= text.length || !Character.isLowSurrogate(text[index + 1])) return false
                        Character.toCodePoint(current, text[index + 1]).also { index += 2 }
                    }
                    Character.isLowSurrogate(current) -> return false
                    else -> current.code.also { index++ }
                }
                val escaped = when {
                    scalar == 0x22 || scalar == 0x2F || scalar == 0x5C -> 2
                    scalar <= 0x1F || scalar in 0x7F..0x9F -> 6
                    scalar <= 0x7F -> 1
                    scalar <= 0xFFFF -> 6
                    else -> 12
                }
                if (!add(escaped)) return false
            }
            return true
        }
        fun numberAllowed(number: Number): Boolean = when (number) {
            is Byte, is Short, is Int, is Long -> true
            is Float -> number.isFinite()
            is Double -> number.isFinite()
            is BigInteger -> number.bitLength() <= 100
            is BigDecimal -> number.precision() <= 30 && number.scale() in -32..32
            else -> false
        }

        while (pending.isNotEmpty()) {
            val work = pending.removeLast()
            if (work.exitContainer) {
                activeContainers.remove(work.value)
                continue
            }
            when (val value = work.value) {
                JSONObject.NULL -> if (!add(4)) return null
                is String -> if (!addString(value)) return null
                is Boolean -> if (!add(if (value) 4 else 5)) return null
                is Number -> if (!numberAllowed(value) || !add(64)) return null
                is JSONObject -> {
                    if (activeContainers.containsKey(value)) return null
                    val count = value.length()
                    if (count > (MAX_JSON_NODES - nodes) / 2 || (count > 0 && work.depth >= MAX_JSON_DEPTH)) return null
                    if (!add(2)) return null
                    nodes += count * 2 // count both property keys and values
                    activeContainers[value] = true
                    pending.addLast(JSONWork(value, work.depth, exitContainer = true))
                    val keys = value.keys().asSequence().toList()
                    for ((index, key) in keys.withIndex()) {
                        if ((index > 0 && !add(1)) || !addString(key) || !add(1)) return null // comma, key, colon
                        pending.addLast(JSONWork(value.get(key), work.depth + 1))
                    }
                }
                is JSONArray -> {
                    if (activeContainers.containsKey(value)) return null
                    val count = value.length()
                    if (count > MAX_JSON_NODES - nodes || (count > 0 && work.depth >= MAX_JSON_DEPTH)) return null
                    if (!add(2)) return null
                    nodes += count
                    activeContainers[value] = true
                    pending.addLast(JSONWork(value, work.depth, exitContainer = true))
                    for (index in 0 until count) {
                        if (index > 0 && !add(1)) return null
                        pending.addLast(JSONWork(value.get(index), work.depth + 1))
                    }
                }
                else -> return null
            }
        }
        return cost
    }

    private fun canonicalUUID(raw: String): String? = runCatching {
        if (!uuidPattern.matches(raw)) return null
        UUID.fromString(raw).toString().lowercase().takeIf { it == raw }
    }.getOrNull()
}
