package com.vortx.android.engine

import java.io.ByteArrayOutputStream
import java.util.Base64
import java.util.zip.DataFormatException
import java.util.zip.Inflater

/** Exact episode identity/order supplied by one authenticated legacy metadata response. */
internal data class LegacyWatchedBitfieldEpisode(
    val id: String,
    val season: Int,
    val episode: Int,
    val releasedMs: Long?,
)

/**
 * Strict decoder for Stremio's legacy `{anchor}:{anchorLength}:{base64-zlib}` watched bitmap.
 * It returns only proven watched video IDs. Callers own source clocks and explicit unwatch events.
 */
internal object LegacyWatchedBitfieldDecoder {
    private const val MAXIMUM_INVENTORY = 10_000
    private const val MAXIMUM_COMPRESSED_BYTES = 64 * 1024
    private const val MAXIMUM_ENCODED_BYTES = 87_384 // Base64 ceiling for MAXIMUM_COMPRESSED_BYTES.
    private const val MAXIMUM_DECOMPRESSED_BYTES = 16 * 1024
    private const val MAXIMUM_ANCHOR_CHARACTERS = 4 * 1024
    private const val MAXIMUM_SERIALIZED_CHARACTERS = MAXIMUM_ANCHOR_CHARACTERS + MAXIMUM_ENCODED_BYTES + 32

    /** IDs retain their exact source spelling and legacy inventory order. */
    fun decode(serialized: String, inventory: List<LegacyWatchedBitfieldEpisode>): List<String> {
        validate(inventory)
        val field = parse(serialized)
        val bytes = inflate(field.payload)
        require(field.anchorLength <= bytes.size * 8) { "Anchor length exceeds bitmap" }
        val anchors = inventory.indices.filter { inventory[it].id == field.anchor }
        require(anchors.size == 1) { "Anchor is absent or ambiguous" }
        val anchorIndex = anchors.single()
        require(bit(bytes, field.anchorLength - 1)) { "Anchor does not identify a watched bit" }

        val offset = field.anchorLength.toLong() - anchorIndex.toLong() - 1L
        val watched = mutableListOf<String>()
        for (sourceIndex in 0 until bytes.size * 8) {
            if (!bit(bytes, sourceIndex)) continue
            require(sourceIndex < field.anchorLength) { "Bitmap has a watched bit after its anchor" }
            val inventoryIndex = sourceIndex.toLong() - offset
            require(inventoryIndex in 0 until inventory.size.toLong()) {
                "Bitmap would drop a watched video outside the supplied inventory"
            }
            watched += inventory[inventoryIndex.toInt()].id
        }
        return watched
    }

    private fun validate(inventory: List<LegacyWatchedBitfieldEpisode>) {
        require(inventory.isNotEmpty() && inventory.size <= MAXIMUM_INVENTORY) { "Invalid inventory size" }
        val ids = mutableSetOf<String>()
        val coordinates = mutableSetOf<Coordinate>()
        inventory.forEach { entry ->
            require(entry.id.isNotEmpty() && entry.season >= 0 && entry.episode >= 0) { "Invalid episode inventory" }
            require(ids.add(entry.id)) { "Duplicate video identifier" }
            require(coordinates.add(Coordinate(entry.season, entry.episode, entry.releasedMs))) { "Ambiguous episode coordinates" }
        }
        val sorted = inventory.sortedWith(::compareEpisodes)
        require(sorted == inventory) { "Inventory is not in exact legacy episode order" }
    }

    private fun parse(serialized: String): Field {
        require(serialized.length <= MAXIMUM_SERIALIZED_CHARACTERS) { "Watched bitmap frame exceeds limit" }
        val payloadSeparator = serialized.lastIndexOf(':')
        require(payloadSeparator > 0) { "Bitmap has no payload" }
        val lengthSeparator = serialized.lastIndexOf(':', payloadSeparator - 1)
        require(lengthSeparator > 0) { "Bitmap has no anchor length" }
        val anchor = serialized.substring(0, lengthSeparator)
        val lengthString = serialized.substring(lengthSeparator + 1, payloadSeparator)
        val payloadString = serialized.substring(payloadSeparator + 1)
        require(anchor.isNotEmpty() && anchor.length <= MAXIMUM_ANCHOR_CHARACTERS && anchor.toByteArray(Charsets.UTF_8).size <= MAXIMUM_ANCHOR_CHARACTERS && payloadString.isNotEmpty() &&
            payloadString.length <= MAXIMUM_ENCODED_BYTES && lengthString.all { it in '0'..'9' }) { "Malformed watched bitmap" }
        val anchorLength = lengthString.toIntOrNull()?.takeIf { it in 1..MAXIMUM_DECOMPRESSED_BYTES * 8 }
            ?: throw IllegalArgumentException("Malformed watched bitmap")
        val payload = try { Base64.getDecoder().decode(payloadString) } catch (_: IllegalArgumentException) { throw IllegalArgumentException("Malformed base64 bitmap") }
        require(payload.size <= MAXIMUM_COMPRESSED_BYTES && Base64.getEncoder().encodeToString(payload) == payloadString) { "Malformed base64 bitmap" }
        return Field(anchor, anchorLength, payload)
    }

    private fun inflate(compressed: ByteArray): ByteArray {
        val inflater = Inflater()
        try {
            inflater.setInput(compressed)
            val output = ByteArrayOutputStream()
            val chunk = ByteArray(1024)
            while (!inflater.finished()) {
                val count = try { inflater.inflate(chunk) } catch (_: DataFormatException) { throw IllegalArgumentException("Truncated or malformed zlib bitmap") }
                if (count == 0) throw IllegalArgumentException("Truncated zlib bitmap")
                require(output.size() + count <= MAXIMUM_DECOMPRESSED_BYTES) { "Bitmap exceeds decompressed limit" }
                output.write(chunk, 0, count)
            }
            require(inflater.remaining == 0) { "Bitmap has trailing compressed data" }
            return output.toByteArray()
        } finally { inflater.end() }
    }

    private fun bit(bytes: ByteArray, index: Int): Boolean = ((bytes[index / 8].toInt() ushr (index % 8)) and 1) != 0
    private fun compareEpisodes(left: LegacyWatchedBitfieldEpisode, right: LegacyWatchedBitfieldEpisode): Int {
        val season = left.season.compareTo(right.season)
        if (season != 0) return season
        val episode = left.episode.compareTo(right.episode)
        if (episode != 0) return episode
        return when {
            left.releasedMs == null && right.releasedMs != null -> -1
            left.releasedMs != null && right.releasedMs == null -> 1
            left.releasedMs == null -> 0
            else -> left.releasedMs!!.compareTo(right.releasedMs!!)
        }
    }
    private data class Coordinate(val season: Int, val episode: Int, val releasedMs: Long?)
    private data class Field(val anchor: String, val anchorLength: Int, val payload: ByteArray)
}
