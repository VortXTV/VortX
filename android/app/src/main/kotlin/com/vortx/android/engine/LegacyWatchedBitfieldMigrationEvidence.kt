package com.vortx.android.engine

import java.net.URI
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.security.MessageDigest
import java.util.Base64
import java.util.UUID
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

/**
 * Captures the proof required to decode one legacy series bitmap into bare watched episode IDs.
 *
 * This is a preparation helper only: it neither changes a native import nor invents a clock.
 * Importers must continue to merge its IDs through their existing `w`/`ma`/`ua` reducer, where
 * explicit clocked marks and resets are authoritative.
 */
internal object LegacyWatchedBitfieldMigrationEvidence {
    private const val OWNER_PROFILE_ID = "00000000-0000-0000-0000-00000000A11C"
    class Failure(message: String) : IllegalArgumentException(message)

    data class Scope(val accountID: String, private val suppliedProfileID: String, val verifiedStreamingUID: String?, private val suppliedOwnerProfileID: String) {
        /** A validated full UUID normalized to the same canonical form used by source buckets. */
        val profileID: String
        val ownerProfileID: String
        init {
            require(accountID.isNotBlank()) { "Missing account scope" }
            require(FULL_UUID.matches(suppliedProfileID)) { "Invalid profile scope" }
            profileID = runCatching { UUID.fromString(suppliedProfileID).toString().uppercase() }
                .getOrElse { throw Failure("Invalid profile scope") }
            require(FULL_UUID.matches(suppliedOwnerProfileID)) { "Invalid owner profile scope" }
            ownerProfileID = UUID.fromString(suppliedOwnerProfileID).toString().uppercase()
            if (verifiedStreamingUID != null) require(verifiedStreamingUID.isNotBlank()) { "Invalid streaming identity" }
        }
    }

    sealed class SourceRowLocator {
        abstract val pointer: String
        data class AuthenticatedOwnerLibrary(val index: Int) : SourceRowLocator() { override val pointer = "/vortx/library/$index" }
        data class AuthenticatedLegacyRootLibrary(val index: Int) : SourceRowLocator() { override val pointer = "/library/$index" }
        data class AuthenticatedProfileLibrary(val index: Int) : SourceRowLocator() { override val pointer = "/vortx/byProfile/<captured-profile>/library/$index" }
        data class AuthenticatedOwnerHistory(val index: Int, val sourceProfileID: String) : SourceRowLocator() { override val pointer = "/vortx/byProfile/$sourceProfileID/ownerHistory/$index" }
        data class OwnAccountLibraryResponse(val index: Int) : SourceRowLocator() { override val pointer = "/libraryResponseBase64/result/$index" }
        data class OwnAccountProfileLibrary(val index: Int) : SourceRowLocator() { override val pointer = "/profileOverlayBase64/vortx/byProfile/<captured-profile>/library/$index" }
        data class OwnAccountOwnerHistory(val index: Int) : SourceRowLocator() { override val pointer = "/profileOverlayBase64/vortx/byProfile/<captured-profile>/ownerHistory/$index" }
    }

    /** Raw original manifest identity; the authenticated source must contain this exact descriptor. */
    class AuthorizedAddon(val transportURL: String, manifest: ByteArray) {
        private val manifestBytes = manifest.copyOf()
        init {
            val uri = runCatching { URI(transportURL) }.getOrNull()
            require(uri != null && uri.scheme?.lowercase() in setOf("http", "https") && !uri.host.isNullOrBlank() &&
                uri.userInfo == null && uri.fragment == null && manifestBytes.isNotEmpty() && manifestBytes.size <= StrictJson.MAX_BYTES) {
                "Invalid original add-on descriptor"
            }
            val parsed = strictObject(StrictJson.value(manifestBytes))
            require(parsed["id"] is StrictJson.Value.StringValue && parsed["name"] is StrictJson.Value.StringValue) { "Original add-on manifest is incomplete" }
        }
        val manifest: ByteArray get() = manifestBytes.copyOf()
        val manifestSHA256: String get() = sha256(manifestBytes)
        override fun equals(other: Any?): Boolean = other is AuthorizedAddon && transportURL == other.transportURL && manifestBytes.contentEquals(other.manifestBytes)
        override fun hashCode(): Int = 31 * transportURL.hashCode() + manifestBytes.contentHashCode()
    }

    data class MetadataRequest(val scope: Scope, val addon: AuthorizedAddon, val type: String, val metaID: String)
    class MetadataResponse(val request: MetadataRequest, raw: ByteArray) { val raw: ByteArray = raw.copyOf() }

    class Evidence(
        val scope: Scope,
        val rowLocator: SourceRowLocator,
        val metaID: String,
        val watchedBitfield: String,
        val addon: AuthorizedAddon,
        source: ByteArray,
        val sourceSHA256: String,
        metadata: ByteArray,
        val metadataSHA256: String,
        val inventory: List<LegacyWatchedBitfieldEpisode>,
        /** Bare source facts only; `ma` / `ua` precedence remains with the legacy reducer. */
        val watchedVideoIDs: List<String>,
    ) { private val sourceBytes = source.copyOf(); private val metadataBytes = metadata.copyOf(); val source get() = sourceBytes.copyOf(); val metadata get() = metadataBytes.copyOf() }

    suspend fun capture(scope: Scope, source: ByteArray, rowLocator: SourceRowLocator, addon: AuthorizedAddon,
                        isCurrent: () -> Boolean, fetch: suspend (MetadataRequest) -> MetadataResponse): Evidence {
        currentCoroutineContext().ensureActive()
        require(isCurrent()) { "Migration account admission revoked" }
        val sourceSnapshot = source.copyOf()
        val addonSnapshot = AuthorizedAddon(addon.transportURL, addon.manifest)
        val sourceTree = StrictJson.value(sourceSnapshot)
        val row = validatedSourceRow(sourceTree, scope, rowLocator)
        requireOriginalAddon(sourceTree, rowLocator, addonSnapshot)
        val request = MetadataRequest(scope, addonSnapshot, "series", row.metaID)
        val response = fetch(request)
        currentCoroutineContext().ensureActive()
        require(isCurrent()) { "Migration account admission revoked" }
        require(response.request == request) { "Metadata response belongs to another request" }
        return replay(scope, sourceSnapshot, rowLocator, addonSnapshot, response.raw, isCurrent)
    }

    /** Cold replay re-runs the same strict source/descriptor/inventory/bitmap validation without
     * trusting archived decoded IDs or performing a metadata request. */
    fun replay(scope: Scope, source: ByteArray, rowLocator: SourceRowLocator, addon: AuthorizedAddon,
               metadata: ByteArray, isCurrent: () -> Boolean): Evidence {
        require(isCurrent()) { "Migration account admission revoked" }
        val sourceSnapshot = source.copyOf()
        val addonSnapshot = AuthorizedAddon(addon.transportURL, addon.manifest)
        val sourceTree = StrictJson.value(sourceSnapshot)
        val row = validatedSourceRow(sourceTree, scope, rowLocator)
        requireOriginalAddon(sourceTree, rowLocator, addonSnapshot)
        val metadataSnapshot = metadata.copyOf()
        val inventory = inventory(metadataSnapshot, row.metaID)
        val watched = LegacyWatchedBitfieldDecoder.decode(row.watchedBitfield, inventory)
        require(isCurrent()) { "Migration account admission revoked" }
        return Evidence(scope, rowLocator, row.metaID, row.watchedBitfield, addonSnapshot, sourceSnapshot, sha256(sourceSnapshot),
            metadataSnapshot, sha256(metadataSnapshot), inventory, watched)
    }

    fun validateSource(scope: Scope, source: ByteArray, rowLocator: SourceRowLocator) {
        validatedSourceRow(StrictJson.value(source.copyOf()), scope, rowLocator)
    }

    /** A retry may select metadata only for the series proven by its archived source/locator. */
    fun sourceMetaID(scope: Scope, source: ByteArray, rowLocator: SourceRowLocator): String =
        validatedSourceRow(StrictJson.value(source.copyOf()), scope, rowLocator).metaID

    /** Preserve original manifest number lexemes while extracting source-authorized candidates.
     * A platform JSONObject reserialization can otherwise change the descriptor being attested. */
    fun originalAddons(source: ByteArray, rowLocator: SourceRowLocator): List<AuthorizedAddon> {
        val tree = StrictJson.value(source.copyOf())
        if (isOwn(rowLocator)) requireOwnEnvelope(tree)
        return descriptorValues(tree, rowLocator).map { value ->
            val row = strictObject(value)
            AuthorizedAddon(strictString(row["transportUrl"]), StrictJson.encode(row.getValue("manifest")))
        }
    }

    private fun validatedSourceRow(root: StrictJson.Value, scope: Scope, locator: SourceRowLocator): SourceRow {
        val index = when (locator) {
            is SourceRowLocator.AuthenticatedOwnerLibrary -> locator.index
            is SourceRowLocator.AuthenticatedLegacyRootLibrary -> locator.index
            is SourceRowLocator.AuthenticatedProfileLibrary -> locator.index
            is SourceRowLocator.AuthenticatedOwnerHistory -> locator.index
            is SourceRowLocator.OwnAccountLibraryResponse -> locator.index
            is SourceRowLocator.OwnAccountProfileLibrary -> locator.index
            is SourceRowLocator.OwnAccountOwnerHistory -> locator.index
        }
        require(index in 0 until 10_000) { "Source row index exceeds migration limit" }
        if (isOwn(locator)) {
            require(scope.verifiedStreamingUID != null && scope.profileID != scope.ownerProfileID) { "Own source requires an independent verified streaming identity" }
            requireOwnEnvelope(root)
            requireScopedOwnOverlay(root, scope)
        } else require(scope.verifiedStreamingUID == null) { "Shared source cannot claim an independent streaming identity" }
        return sourceRow(root, scope, locator).also { row ->
            require(row.type == "series" && row.metaID.isNotBlank() && row.watchedBitfield.isNotEmpty()) { "Source row is not a watched series" }
        }
    }

    private data class SourceRow(val metaID: String, val type: String, val watchedBitfield: String)

    private fun sourceRow(root: StrictJson.Value, scope: Scope, locator: SourceRowLocator): SourceRow = when (locator) {
        is SourceRowLocator.AuthenticatedOwnerLibrary -> {
            require(locator.index >= 0 && scope.profileID == scope.ownerProfileID) { "Owner source requires owner scope" }
            val vortx = strictObject(strictObject(root).getValue("vortx"))
            val rows = strictArray(vortx.getValue("library"))
            sharedRow(rows, locator.index)
        }
        is SourceRowLocator.AuthenticatedLegacyRootLibrary -> {
            require(locator.index >= 0 && scope.profileID == scope.ownerProfileID) { "Owner source requires owner scope" }
            sharedRow(strictArray(strictObject(root).getValue("library")), locator.index)
        }
        is SourceRowLocator.AuthenticatedProfileLibrary -> {
            require(locator.index >= 0) { "Invalid source row index" }
            val vortx = strictObject(strictObject(root).getValue("vortx"))
            val profiles = strictObject(vortx.getValue("byProfile"))
            require(profiles.keys.count { it.equals(scope.profileID, true) } == 1) { "Ambiguous profile source carrier" }
            val bucket = strictObject(profiles.getValue(scope.profileID))
            sharedRow(strictArray(bucket.getValue("library")), locator.index)
        }
        is SourceRowLocator.OwnAccountLibraryResponse -> {
            require(locator.index >= 0 && scope.verifiedStreamingUID != null) { "Own source requires verified streaming identity" }
            val envelope = strictObject(StrictJson.value(strictEnvelopeBytes(strictObject(root), "libraryResponseBase64")))
            val row = strictArray(envelope.getValue("result")).getOrNull(locator.index) ?: throw Failure("Source row is absent")
            val fields = strictObject(row); val state = strictObject(fields.getValue("state"))
            SourceRow(strictString(fields["_id"]), strictString(fields["type"]), strictString(state["watched"]))
        }
        is SourceRowLocator.AuthenticatedOwnerHistory -> {
            require(locator.index >= 0 && scope.profileID == scope.ownerProfileID && FULL_UUID.matches(locator.sourceProfileID) &&
                locator.sourceProfileID.uppercase() in setOf(scope.ownerProfileID, OWNER_PROFILE_ID)) { "Owner history requires exact owner carrier" }
            val profiles = strictObject(strictObject(strictObject(root).getValue("vortx")).getValue("byProfile"))
            require(profiles.keys.count { it.equals(locator.sourceProfileID, true) } == 1) { "Ambiguous owner history carrier" }
            val bucket = strictObject(profiles.getValue(locator.sourceProfileID))
            sharedRow(strictArray(bucket.getValue("ownerHistory")), locator.index)
        }
        is SourceRowLocator.OwnAccountProfileLibrary -> ownOverlayRow(root, scope, locator.index, "library")
        is SourceRowLocator.OwnAccountOwnerHistory -> ownOverlayRow(root, scope, locator.index, "ownerHistory")
    }

    private fun ownOverlayRow(root: StrictJson.Value, scope: Scope, index: Int, key: String): SourceRow {
        require(index >= 0) { "Invalid source row index" }
        val overlay = strictObject(StrictJson.value(strictEnvelopeBytes(strictObject(root), "profileOverlayBase64")))
        val profiles = strictObject(strictObject(overlay.getValue("vortx")).getValue("byProfile"))
        require(profiles.keys == setOf(scope.profileID)) { "Foreign own-account profile overlay" }
        val bucket = strictObject(profiles.getValue(scope.profileID))
        return sharedRow(strictArray(bucket.getValue(key)), index)
    }

    private fun requireScopedOwnOverlay(root: StrictJson.Value, scope: Scope) {
        val overlay = strictObject(StrictJson.value(strictEnvelopeBytes(strictObject(root), "profileOverlayBase64")))
        overlay["vortx"]?.let { vortx -> strictObject(vortx)["byProfile"]?.let { profiles ->
            require(strictObject(profiles).keys.all { it == scope.profileID }) { "Foreign own-account profile overlay" }
        } }
        overlay["webProgress"]?.let { web -> strictObject(web)["removed"]?.let { removed ->
            strictObject(removed)["byProfile"]?.let { profiles ->
                require(strictObject(profiles).keys.all { it == scope.profileID }) { "Foreign own-account removals" }
            }
        } }
    }

    private fun isOwn(locator: SourceRowLocator): Boolean = locator is SourceRowLocator.OwnAccountLibraryResponse ||
        locator is SourceRowLocator.OwnAccountProfileLibrary || locator is SourceRowLocator.OwnAccountOwnerHistory

    private fun requireOwnEnvelope(source: StrictJson.Value) {
        val parsed = strictObject(source)
        val expected = setOf("schemaVersion", "libraryResponseBase64", "addonsResponseBase64", "profileOverlayBase64")
        require(parsed.keys == expected && ((parsed["schemaVersion"] as? StrictJson.Value.Number)?.raw in setOf("1", "2"))) { "Malformed own-account source envelope" }
        strictEnvelopeBytes(parsed, "libraryResponseBase64"); strictEnvelopeBytes(parsed, "addonsResponseBase64"); strictEnvelopeBytes(parsed, "profileOverlayBase64")
    }

    private fun sharedRow(rows: List<StrictJson.Value>, index: Int): SourceRow {
        val row = strictObject(rows.getOrNull(index) ?: throw Failure("Source row is absent"))
        return SourceRow(strictString(row["id"]), strictString(row["type"]), strictString(row["watched"]))
    }

    private fun requireOriginalAddon(root: StrictJson.Value, locator: SourceRowLocator, expected: AuthorizedAddon) {
        val descriptors = descriptorValues(root, locator)
        val expectedManifest = StrictJson.value(expected.manifest)
        val matches = descriptors.count { raw ->
            val descriptor = strictObject(raw)
            strictString(descriptor["transportUrl"]) == expected.transportURL && descriptor["manifest"] == expectedManifest
        }
        require(matches == 1) { "Original add-on descriptor is absent or ambiguous" }
    }

    private fun descriptorValues(root: StrictJson.Value, locator: SourceRowLocator): List<StrictJson.Value> {
        val rootObject = strictObject(root)
        return if (isOwn(locator)) {
            val result = strictObject(StrictJson.value(strictEnvelopeBytes(rootObject, "addonsResponseBase64")))
            strictArray(strictObject(result.getValue("result")).getValue("addons"))
        } else {
            // A present `vortx` member remains structural evidence. The pre-vortx root format
            // legitimately carries both library and registry at the root, however.
            val vortxDescriptors = rootObject["vortx"]?.let { optionalStrictArray(strictObject(it)["addons"]) } ?: emptyList()
            vortxDescriptors + optionalStrictArray(rootObject["addons"])
        }
    }

    private fun inventory(raw: ByteArray, requestedID: String): List<LegacyWatchedBitfieldEpisode> {
        val meta = strictObject(strictObject(StrictJson.value(raw)).getValue("meta"))
        require(strictString(meta["id"]) == requestedID && strictString(meta["type"]) == "series") { "Metadata identity mismatch" }
        val videos = strictArray(meta["videos"])
        require(videos.size in 1..10_000) { "Metadata has no complete episode inventory" }
        return videos.map { rawVideo ->
            val video = strictObject(rawVideo)
            LegacyWatchedBitfieldEpisode(strictString(video["id"]), strictInt(video["season"]), strictInt(video["episode"]), strictReleased(video["released"]))
        }.sortedWith(::compareEpisodes)
    }

    private fun compareEpisodes(left: LegacyWatchedBitfieldEpisode, right: LegacyWatchedBitfieldEpisode): Int {
        val season = left.season.compareTo(right.season); if (season != 0) return season
        val episode = left.episode.compareTo(right.episode); if (episode != 0) return episode
        return when { left.releasedMs == null && right.releasedMs != null -> -1; left.releasedMs != null && right.releasedMs == null -> 1; left.releasedMs == null -> 0; else -> left.releasedMs!!.compareTo(right.releasedMs!!) }
    }

    private fun strictObject(value: StrictJson.Value?): Map<String, StrictJson.Value> = (value as? StrictJson.Value.Object)?.values ?: throw Failure("Malformed JSON object")
    private fun strictArray(value: StrictJson.Value?): List<StrictJson.Value> = (value as? StrictJson.Value.Array)?.values ?: throw Failure("Malformed JSON array")
    private fun optionalStrictArray(value: StrictJson.Value?): List<StrictJson.Value> = if (value == null) emptyList() else strictArray(value)
    private fun strictString(value: StrictJson.Value?): String = (value as? StrictJson.Value.StringValue)?.value?.takeIf(String::isNotEmpty) ?: throw Failure("Missing string")
    private fun strictInt(value: StrictJson.Value?): Int {
        val raw = (value as? StrictJson.Value.Number)?.raw ?: throw Failure("Malformed episode coordinate")
        require(Regex("^(0|[1-9][0-9]{0,9})$").matches(raw)) { "Malformed episode coordinate" }
        val result = raw.toLongOrNull() ?: throw Failure("Malformed episode coordinate")
        require(result <= Int.MAX_VALUE) { "Malformed episode coordinate" }
        return result.toInt()
    }
    private fun strictReleased(value: StrictJson.Value?): Long? {
        if (value == null || value is StrictJson.Value.Null) return null
        return released((value as? StrictJson.Value.StringValue)?.value ?: throw Failure("Malformed episode release value"))
    }

    private fun released(value: String): Long {
        val bytes = value.toByteArray(Charsets.US_ASCII)
        require(bytes.size >= 20 && bytes[4] == '-'.code.toByte() && bytes[7] == '-'.code.toByte() && bytes[10] == 'T'.code.toByte() && bytes[13] == ':'.code.toByte() && bytes[16] == ':'.code.toByte()) { "Malformed episode release value" }
        fun digits(start: Int, count: Int): Long {
            require(start + count <= bytes.size && (start until start + count).all { bytes[it] in '0'.code.toByte()..'9'.code.toByte() }) { "Malformed episode release value" }
            return (start until start + count).fold(0L) { result, index -> result * 10 + (bytes[index] - '0'.code.toByte()).toLong() }
        }
        val year = digits(0, 4); val month = digits(5, 2); val day = digits(8, 2); val hour = digits(11, 2); val minute = digits(14, 2); val second = digits(17, 2)
        require(year >= 1 && month in 1..12 && day in 1..daysInMonth(year, month) && hour < 24 && minute < 60 && second < 60) { "Malformed episode release value" }
        var cursor = 19; var milliseconds = 0L
        if (cursor < bytes.size && bytes[cursor] == '.'.code.toByte()) {
            cursor += 1; val start = cursor; while (cursor < bytes.size && bytes[cursor] in '0'.code.toByte()..'9'.code.toByte()) cursor += 1
            val count = cursor - start; require(count in 1..3) { "Episode release has non-millisecond precision" }
            milliseconds = digits(start, count) * if (count == 1) 100 else if (count == 2) 10 else 1
        }
        val offsetMinutes = if (cursor + 1 == bytes.size && bytes[cursor] == 'Z'.code.toByte()) 0L else {
            require(cursor + 6 == bytes.size && (bytes[cursor] == '+'.code.toByte() || bytes[cursor] == '-'.code.toByte()) && bytes[cursor + 3] == ':'.code.toByte()) { "Malformed episode release value" }
            val hours = digits(cursor + 1, 2); val minutes = digits(cursor + 4, 2); require(hours <= 23 && minutes < 60) { "Malformed episode release value" }
            if (bytes[cursor] == '+'.code.toByte()) hours * 60 + minutes else -(hours * 60 + minutes)
        }
        return Math.addExact(Math.addExact(daysSinceEpoch(year, month, day) * 86_400_000L + hour * 3_600_000L + minute * 60_000L + second * 1_000L, milliseconds), -offsetMinutes * 60_000L)
    }
    private fun daysInMonth(year: Long, month: Long): Long = when (month) { 2L -> if (year % 4L == 0L && (year % 100L != 0L || year % 400L == 0L)) 29 else 28; 4L, 6L, 9L, 11L -> 30; else -> 31 }
    private fun daysSinceEpoch(year: Long, month: Long, day: Long): Long { val adjustedYear = year - if (month <= 2L) 1 else 0; val era = adjustedYear / 400; val yearOfEra = adjustedYear - era * 400; val dayOfYear = (153 * (month + if (month > 2L) -3 else 9) + 2) / 5 + day - 1; return era * 146_097 + yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear - 719_468 }

    private fun strictEnvelopeBytes(root: Map<String, StrictJson.Value>, key: String): ByteArray {
        val encoded = strictString(root[key])
        val bytes = runCatching { Base64.getDecoder().decode(encoded) }.getOrElse { throw Failure("Malformed own-account source envelope") }
        require(Base64.getEncoder().encodeToString(bytes) == encoded) { "Malformed own-account source envelope" }
        StrictJson.validate(bytes)
        return bytes
    }
    private fun sha256(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    private val FULL_UUID = Regex("^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$")

    /** Strict bounded raw ingress before org.json projection; rejects duplicate keys and malformed JSON. */
    private object StrictJson {
        const val MAX_BYTES = 2 * 1024 * 1024
        val credentialNames = setOf("auth", "authkey", "password", "apikey", "apikeys", "authorization", "bearer", "datakey", "token", "accesstoken", "refreshtoken", "authtoken", "clientsecret", "credentials")
        sealed class Value {
            data class Object(val values: Map<String, Value>) : Value()
            data class Array(val values: List<Value>) : Value()
            data class StringValue(val value: String) : Value()
            data class Number(val raw: String) : Value()
            data class Bool(val value: Boolean) : Value()
            object Null : Value()
        }
        fun encode(value: Value): ByteArray {
            fun quote(text: String): String = buildString {
                append('"')
                text.forEach { ch -> when (ch) {
                    '"' -> append("\\\""); '\\' -> append("\\\\")
                    '\b' -> append("\\b"); '\u000C' -> append("\\f"); '\n' -> append("\\n"); '\r' -> append("\\r"); '\t' -> append("\\t")
                    else -> if (ch.code < 32) append("\\u%04x".format(ch.code)) else append(ch)
                } }
                append('"')
            }
            fun render(node: Value): String = when (node) {
                is Value.Object -> node.values.entries.joinToString(",", "{", "}") { quote(it.key) + ":" + render(it.value) }
                is Value.Array -> node.values.joinToString(",", "[", "]", transform = ::render)
                is Value.StringValue -> quote(node.value)
                is Value.Number -> node.raw
                is Value.Bool -> node.value.toString()
                Value.Null -> "null"
            }
            return render(value).toByteArray(Charsets.UTF_8)
        }
        fun validate(bytes: ByteArray) { value(bytes) }
        fun value(bytes: ByteArray): Value {
            require(bytes.isNotEmpty() && bytes.size <= MAX_BYTES) { "JSON source is not bounded UTF-8" }
            val text = runCatching { Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString() }
                .getOrElse { throw Failure("JSON source is not bounded UTF-8") }
            val parser = Parser(text); val result = parser.value(0); parser.whitespace()
            require(parser.atEnd()) { "Trailing JSON data" }
            require(parser.credentialKeys.isEmpty()) { "Raw source is credential-bearing" }
            return result
        }
        private class Parser(private val text: String) {
            var index = 0
            val credentialKeys = mutableSetOf<String>()
            fun atEnd() = index == text.length
            fun whitespace() { while (index < text.length && text[index] in charArrayOf(' ', '\t', '\n', '\r')) index += 1 }
            fun value(depth: Int): Value {
                require(depth <= 64) { "JSON exceeds nesting limit" }; whitespace(); require(index < text.length) { "Truncated JSON" }
                return when (text[index]) {
                    '{' -> obj(depth + 1); '[' -> array(depth + 1); '"' -> Value.StringValue(string())
                    't' -> { literal("true"); Value.Bool(true) }; 'f' -> { literal("false"); Value.Bool(false) }; 'n' -> { literal("null"); Value.Null }
                    '-' -> Value.Number(number()); in '0'..'9' -> Value.Number(number()); else -> throw Failure("Malformed JSON token")
                }
            }
            fun obj(depth: Int): Value {
                index += 1; whitespace(); val keys = mutableSetOf<String>(); val values = linkedMapOf<String, Value>()
                if (take('}')) return Value.Object(values)
                while (true) {
                    whitespace(); require(index < text.length && text[index] == '"') { "Object key is missing" }
                    val key = string(); require(keys.add(key)) { "Duplicate JSON key" }
                    val normalized = key.lowercase().filter(Char::isLetterOrDigit)
                    if (normalized in StrictJson.credentialNames || normalized.contains("secret") || normalized.contains("credential")) credentialKeys += normalized
                    whitespace(); require(take(':')) { "Object colon is missing" }; values[key] = value(depth); whitespace()
                    if (take('}')) return Value.Object(values)
                    require(take(',')) { "Object separator is missing" }
                }
            }
            fun array(depth: Int): Value {
                index += 1; whitespace(); val values = mutableListOf<Value>(); if (take(']')) return Value.Array(values)
                while (true) { values += value(depth); whitespace(); if (take(']')) return Value.Array(values); require(take(',')) { "Array separator is missing" } }
            }
            fun string(): String {
                require(take('"')) { "String is missing" }; val out = StringBuilder()
                while (index < text.length) {
                    val ch = text[index++]; if (ch == '"') return out.toString(); require(ch.code >= 32) { "Control byte in JSON string" }
                    if (ch != '\\') { out.append(ch); continue }
                    require(index < text.length) { "Truncated JSON escape" }
                    when (val escaped = text[index++]) {
                        '"', '\\', '/' -> out.append(escaped); 'b' -> out.append('\b'); 'f' -> out.append('\u000C'); 'n' -> out.append('\n'); 'r' -> out.append('\r'); 't' -> out.append('\t')
                        'u' -> { val first = hex16(); if (first in 0xD800..0xDBFF) { require(take('\\') && take('u')) { "Unpaired JSON surrogate" }; val second = hex16(); require(second in 0xDC00..0xDFFF) { "Unpaired JSON surrogate" }; out.appendCodePoint(0x10000 + (first - 0xD800) * 0x400 + second - 0xDC00) } else { require(first !in 0xDC00..0xDFFF) { "Unpaired JSON surrogate" }; out.append(first.toChar()) } }
                        else -> throw Failure("Invalid JSON escape")
                    }
                }
                throw Failure("Unterminated JSON string")
            }
            fun number(): String {
                val start = index; take('-'); require(index < text.length) { "Malformed JSON number" }
                if (take('0')) require(index == text.length || text[index] !in '0'..'9') { "Leading zero JSON number" } else { require(digit()) { "Malformed JSON number" }; while (digit()) {} }
                if (take('.')) { require(digit()) { "Malformed JSON number" }; while (digit()) {} }
                if (take('e') || take('E')) { take('+') || take('-'); require(digit()) { "Malformed JSON number" }; while (digit()) {} }
                require(index - start <= 64) { "Lossy JSON number" }; return text.substring(start, index)
            }
            fun literal(value: String) { value.forEach { require(take(it)) { "Malformed JSON literal" } } }
            fun hex16(): Int { require(index + 4 <= text.length) { "Truncated JSON escape" }; var value = 0; repeat(4) { val digit = text[index++].digitToIntOrNull(16) ?: throw Failure("Invalid JSON hex"); value = value * 16 + digit }; return value }
            fun digit(): Boolean { if (index >= text.length || text[index] !in '0'..'9') return false; index += 1; return true }
            fun take(expected: Char): Boolean { if (index >= text.length || text[index] != expected) return false; index += 1; return true }
        }
    }
}
