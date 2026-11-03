package com.vortx.android.sync

import com.vortx.android.backup.AccountFilePlist
import com.vortx.android.engine.DetachedAccountFileKernel
import com.vortx.android.engine.NativeOwnerHistoryAccount
import com.vortx.android.engine.NativeProfileOverlayWitness
import com.vortx.android.engine.OHJson
import com.vortx.android.engine.VortxAccountScope
import com.vortx.android.engine.VortxRuntimeBindings
import java.math.BigDecimal
import java.net.URI
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.util.Base64
import java.util.Locale
import java.util.concurrent.CancellationException

private typealias HostFields = Map<String, Any?>

/** Validation only. The caller authenticates and retains the exact candidate bytes and original fence. */
internal object AccountFileHostAdmission {
    enum class Reason { MALFORMED, UNSUPPORTED_NATIVE, UNSUPPORTED_SOURCE, INVALID_HOST, LIMIT }
    class Failure(val reason: Reason) : IllegalArgumentException("Selected account file: " + reason.name)

    private const val MAX_DEPTH = 64
    private const val MAX_NODES = 100_000
    private const val MAX_DECODED_BYTES = 16L * 1024 * 1024
    // OHJson copies raw child slices. Charge each parse and each nested slice inspection.
    private const val MAX_SCANNED_BYTES = 128L * 1024 * 1024
    private val forbiddenSources = setOf(
        "ownerHistory", "nativeOwnerHistorySources", "nativeProviderCredentials", "authenticatedSourceArchive",
        "verifiedStreamingUid", "sourceDocumentBase64", "ownAccountOverlayPending", "ownAccountOverlayQuarantine",
        "nativeLegacyMembershipPending", "nativeWatchedMigrationEvidence", "nativeWatchedMigrationPending",
        "nativeWatchedMigrationSources",
    )
    private val emptySources = setOf("ownAccountSources", "ownAccountSourceHistory")
    private val knownCredentials = setOf(
        "auth", "authkey", "password", "apikey", "apikeys", "authorization", "bearer", "datakey", "token",
        "accesstoken", "refreshtoken", "authtoken", "clientsecret", "credentials", "nativeprovidercredentials",
    )
    private val credentialSuffixes = listOf("token", "password", "authkey", "apikey")
    private val digestKeys = setOf(
        "valueHash", "fingerprint", "sourceDocumentSha256", "metadataResponseSha256", "profileOverlaySha256",
        "typedCarrierFingerprint",
    )
    private val hex32 = Regex("[0-9a-f]{32}")
    private val hex64 = Regex("[0-9a-f]{64}")
    private val uuid = Regex("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
    private val rowIndex = Regex("[0-9]+")
    private val tagGraphemes = Regex("\\X{1,64}")
    private val digestProfileSlot = Regex("[0-9A-F-]{36}")
    private val safeClock = BigDecimal("9007199254740990")
    private val signedIntLow = BigDecimal.valueOf(Long.MIN_VALUE)
    private val signedIntHigh = BigDecimal.valueOf(Long.MAX_VALUE)
    private val structuredPrefixes = listOf("{", "[", "bplist", "<?xml", "<!DOCTYPE", "<plist")
    private const val TAG_SEPARATOR = ":-.,!?)"
    private const val TAG_SYNTAX = "[]{}\"'\\:=;<`"
    private const val SERIES_PREFIX = "stremiox.seriesSourceSticky."

    fun requireCandidate(
        plaintext: ByteArray,
        scope: VortxAccountScope,
        bindings: VortxRuntimeBindings,
        checkCurrent: () -> Unit,
    ) {
        checkCurrent()
        if (plaintext.size > AccountFileLegacyAdmission.MAX_PLAINTEXT_BYTES) throw Failure(Reason.LIMIT)
        val original = plaintext.copyOf()
        try {
            val root = checked(Reason.MALFORMED) {
                requireJsonWorkBound(original)
                val parsed = OHJson.Obj(original)
                NativeProfileOverlayWitness.parseAccountDocument(original)
                parsed
            }
            val native = checked(Reason.MALFORMED) { root.raw("nativeSync") }
            val state = checked(Reason.UNSUPPORTED_NATIVE) {
                DetachedAccountFileKernel.fileRestoreState(scope, native, bindings, checkCurrent)
            }
            checked(Reason.UNSUPPORTED_SOURCE) {
                Inspector(checkCurrent).requireSharedSources(native, scope.ownerProfileID)
                Inspector(checkCurrent).requireSharedSources(state, scope.ownerProfileID)
            }
            checked(Reason.INVALID_HOST) {
                Inspector(checkCurrent).requireHost(root)
                NativeOwnerHistoryAccount(original).validateBudget(writeV2 = true)
            }
            checkCurrent()
        } finally {
            original.fill(0)
        }
    }

    private inline fun <T> checked(reason: Reason, run: () -> T): T = try {
        run()
    } catch (failure: Failure) {
        throw failure
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (_: Exception) {
        // Library messages can include keys, URLs, raw JSON or credentials.
        throw Failure(reason)
    }

    private enum class Role {
        ORDINARY, HOST, LEGACY, SETTINGS, ROSTER_DATA, ROSTER, ROSTER_ITEM, NAME, AVATAR, LIBRARY_ROWS,
        LIBRARY_ROW, ADDON_ROWS, ADDON_ROW, ADDON_MANIFEST, ADDON_DISPLAY, SERIES_DATA, SERIES_CHOICES,
        SERIES_CHOICE, NATIVE, REGISTERS, REGISTER, NATIVE_PROFILE, NATIVE_IMPORT, BASELINE, NATIVE_ROSTER,
    }

    private data class Context(val role: Role = Role.ORDINARY, val owner: String? = null)
    private data class JsonNumber(val text: String)

    private class Inspector(private val checkCurrent: () -> Unit) {
        private var nodes = 0
        private var decodedBytes = 0L
        private var scannedBytes = 0L

        /** Shape probes and traversal share one interpretation of each slice. */
        private inner class Raw(initial: ByteArray) {
            private var bytes: ByteArray? = initial
            private var parsed: Any? = null

            fun value(): Any? {
                val input = bytes ?: return parsed
                scan(input.size)
                parsed = when (head(input)) {
                    '{' -> fields(OHJson.Obj(input))
                    '[' -> OHJson.array(input).map { Raw(it) }
                    '"' -> OHJson.text(input)
                    't' -> true
                    'f' -> false
                    'n' -> null
                    else -> JsonNumber(OHJson.utf8(input))
                }
                // All Raw scalars came from a complete strict JSON parse.
                bytes = null
                return parsed
            }
        }

        private fun visit(depth: Int) {
            if (depth > MAX_DEPTH || ++nodes > MAX_NODES) throw Failure(Reason.LIMIT)
            if (nodes % 128 == 1) checkCurrent()
        }

        private fun scan(size: Int) {
            scannedBytes += size
            if (scannedBytes > MAX_SCANNED_BYTES) throw Failure(Reason.LIMIT)
            checkCurrent()
        }

        private fun decoded(size: Int) {
            decodedBytes += size
            if (decodedBytes > MAX_DECODED_BYTES) throw Failure(Reason.LIMIT)
            checkCurrent()
        }

        private fun fields(obj: OHJson.Obj): HostFields = obj.keys.associateWith { Raw(obj.raw(it)) }
        private fun unwrap(value: Any?): Any? = if (value is Raw) value.value() else value

        @Suppress("UNCHECKED_CAST")
        private fun objectValue(value: Any?): HostFields? = unwrap(value) as? HostFields
        private fun list(value: Any?): List<*>? = unwrap(value) as? List<*>
        private fun text(value: Any?): String? = unwrap(value) as? String
        private fun bool(value: Any?): Boolean? = unwrap(value) as? Boolean

        private fun number(value: Any?): BigDecimal? {
            val spelling = when (val plain = unwrap(value)) {
                is JsonNumber -> plain.text
                is Number -> plain.toString()
                else -> return null
            }
            // Large unknown lexemes are kept raw. Only typed identity predicates need arithmetic.
            return spelling.takeIf { it.length <= 128 }?.toBigDecimalOrNull()
        }

        private fun integer(value: Any?): BigDecimal? =
            number(value)?.takeIf { it.stripTrailingZeros().scale() <= 0 }

        private fun schema(value: Any?, max: Int): Boolean =
            integer(value)?.let { it >= BigDecimal.ONE && it <= BigDecimal.valueOf(max.toLong()) } == true

        fun requireSharedSources(bytes: ByteArray, owner: String) {
            requireJsonWorkBound(bytes)
            shared(Raw(bytes), owner, null, 0)
        }

        private fun shared(input: Any?, owner: String, profileID: String?, depth: Int) {
            visit(depth)
            when (val value = unwrap(input)) {
                is Map<*, *> -> {
                    val row = requireNotNull(objectValue(value))
                    require(row.keys.none { it in forbiddenSources })
                    require(emptySources.all { key -> key !in row || objectValue(row[key])?.isEmpty() == true })
                    val binding = objectValue(row["account"])
                    if (binding != null && "kind" in binding) {
                        val kind = text(binding["kind"])
                        val ownerRow = profileID == owner || (text(row["id"]) == owner && bool(row["owner"]) == true)
                        val supported = when (kind) {
                            "shared" -> "value" !in binding || text(binding["value"]) == owner
                            "local_only" -> ownerRow && "value" !in binding
                            else -> false
                        }
                        require(supported)
                    } else {
                        val kind = text(row["account"])
                        require(kind != "own" && kind != "pending_own" && (kind != "local_only" || profileID == owner))
                    }
                    for ((key, child) in row) {
                        val inherited = if (uuid.matches(key) && key == key.uppercase(Locale.ROOT)) key else profileID
                        shared(child, owner, inherited, depth + 1)
                    }
                }
                is List<*> -> value.forEach { shared(it, owner, profileID, depth + 1) }
            }
        }

        fun requireHost(root: OHJson.Obj) {
            val row = fields(root)
            inspect(row, Context(Role.HOST), emptyList(), 0)
            if ("apiKeys" !in row) return
            val keys = requireNotNull(objectValue(row["apiKeys"]))
            for ((key, value) in keys) {
                require(if (key == "metadata") objectValue(value)?.values?.all { text(it) != null } == true
                    else text(value) != null)
            }
        }

        private fun inspect(input: Any?, context: Context, path: List<String>, depth: Int) {
            visit(depth)
            when (val value = unwrap(input)) {
                is Map<*, *> -> inspectObject(requireNotNull(objectValue(value)), context, path, depth)
                is List<*> -> value.forEachIndexed { index, child ->
                    inspect(child, itemContext(child, context), path + index.toString(), depth + 1)
                }
                is ByteArray -> inspectData(value, context, path, depth)
                is String -> inspectText(value, context, path, depth)
                is JsonNumber, is Number, is Boolean, is AccountFilePlist.PlistDate, null -> Unit
                else -> throw Failure(Reason.INVALID_HOST)
            }
        }

        private fun inspectObject(row: HostFields, context: Context, path: List<String>, depth: Int) {
            val descriptor = isDescriptor(row)
            val event = isWebsiteEvent(row)
            val envelope = text(row["format"]) == "vortx-backup"
            if (envelope) {
                require(schema(row["schema"], 1))
                val payload = requireNotNull(base64(requireNotNull(text(row["payloadBase64"]))))
                decoded(payload.size)
                inspect(AccountFilePlist.decode(payload), Context(Role.SETTINGS), path + "payloadBase64", depth + 1)
            }
            for ((key, child) in row) {
                if (envelope && key == "payloadBase64" || event && key == "eventId") continue
                if (!configuredUrl(key)) {
                    val lower = key.lowercase(Locale.ROOT)
                    val name = lower.replace("_", "").replace("-", "")
                    if (name in knownCredentials || lower.startsWith("kcfallback.")) continue
                    require(!name.contains("secret") && !name.contains("credential") &&
                        credentialSuffixes.none { name.endsWith(it) })
                }
                val settings = if (key == "settings") text(child) else null
                if (settings != null) {
                    val bytes = requireNotNull(base64(settings))
                    decoded(bytes.size)
                    val nested = requireNotNull(objectValue(parseJson(utf8View(bytes), allowQuoted = false)))
                    require(text(nested["format"]) == "vortx-backup")
                    inspect(nested, Context(), path + key, depth + 1)
                } else {
                    inspect(child, fieldContext(row, key, context, descriptor), path + key, depth + 1)
                }
            }
        }

        private fun fieldContext(row: HostFields, key: String, context: Context, descriptor: Boolean): Context {
            val child = row[key]
            val role = when (context.role) {
                Role.HOST -> when {
                    key == "nativeSync" -> objectValue(child)?.let { nativeOwner(it) }?.let { return Context(Role.NATIVE, it) }
                    key == "vortx" && objectValue(child) != null -> Role.LEGACY
                    else -> null
                }
                Role.LEGACY -> Role.ROSTER.takeIf { key == "roster" && list(child) != null }
                Role.SETTINGS -> when {
                    child is ByteArray && key == "stremiox.profiles" -> Role.ROSTER_DATA
                    child is ByteArray && key.startsWith(SERIES_PREFIX) &&
                        key.removePrefix(SERIES_PREFIX).let { it == "default" || uuid.matches(it) } -> Role.SERIES_DATA
                    else -> null
                }
                Role.SERIES_CHOICES -> Role.SERIES_CHOICE.takeIf {
                    clean(key) && objectValue(child)?.let { isSeriesChoice(it) } == true
                }
                Role.SERIES_CHOICE -> Role.ADDON_DISPLAY.takeIf { key == "addon" && text(child) != null }
                Role.ROSTER_ITEM -> when (key) {
                    "name" -> Role.NAME
                    "avatar" -> Role.AVATAR
                    else -> null
                }
                Role.LIBRARY_ROW -> Role.ADDON_DISPLAY.takeIf { key == "name" }
                Role.ADDON_ROW -> Role.ADDON_DISPLAY.takeIf { key == "name" }
                Role.NATIVE -> when {
                    key == "profiles" && objectValue(child) != null -> Role.REGISTERS
                    key == "legacyImport" && objectValue(child)?.let {
                        schema(it["schemaVersion"], 2) && text(it["fingerprint"])?.let(hex64::matches) == true
                    } == true -> Role.NATIVE_IMPORT
                    else -> null
                }
                Role.REGISTERS -> Role.REGISTER.takeIf {
                    registerProfile(child, key, requireNotNull(context.owner)) != null
                }
                Role.REGISTER -> Role.NATIVE_PROFILE.takeIf { key == "profile" && objectValue(child) != null }
                Role.NATIVE_PROFILE -> Role.NAME.takeIf { key == "name" }
                Role.NATIVE_IMPORT -> Role.BASELINE.takeIf {
                    key == "baseline" && objectValue(child)?.let { baselineOwner(it) } == context.owner
                }
                Role.BASELINE -> Role.NATIVE_ROSTER.takeIf { key == "roster" && list(child) != null }
                else -> null
            }
            if (role != null) return Context(role, context.owner)
            if (context.role == Role.HOST || context.role == Role.LEGACY) {
                if (key == "library" && list(child) != null) return Context(Role.LIBRARY_ROWS)
                if (key == "addons" && list(child) != null) return Context(Role.ADDON_ROWS)
            }
            if (descriptor && key == "manifest") return Context(Role.ADDON_MANIFEST)
            if (descriptor && key == "name" || context.role == Role.ADDON_MANIFEST && (key == "name" || key == "description")) {
                if (text(child) != null) return Context(Role.ADDON_DISPLAY)
            }
            return Context()
        }

        private fun itemContext(value: Any?, context: Context): Context {
            val row = objectValue(value) ?: return Context()
            return Context(when (context.role) {
                Role.ROSTER -> if (text(row["id"])?.let(uuid::matches) == true &&
                    text(row["name"]) != null && text(row["avatar"]) != null) Role.ROSTER_ITEM else Role.ORDINARY
                Role.LIBRARY_ROWS -> if (clean(text(row["id"])) && text(row["type"]) != null &&
                    text(row["name"]) != null) Role.LIBRARY_ROW else Role.ORDINARY
                Role.ADDON_ROWS -> if ("manifest" !in row && text(row["name"]) != null &&
                    configuredUrl(text(row["transportUrl"]))) Role.ADDON_ROW else Role.ORDINARY
                Role.NATIVE_ROSTER -> if (isNativeProfile(row, requireNotNull(context.owner))) Role.NATIVE_PROFILE else Role.ORDINARY
                else -> Role.ORDINARY
            })
        }

        private fun nativeOwner(row: HostFields): String? {
            if (!schema(row["schemaVersion"], 5) || !clean(text(row["scope"]))) return null
            val owner = text(row["ownerProfileId"]) ?: return null
            val profiles = objectValue(row["profiles"]) ?: return null
            return owner.takeIf { registerProfile(profiles[owner], owner, owner) != null }
        }

        private fun registerProfile(value: Any?, key: String, owner: String): HostFields? {
            if (!uuid.matches(key)) return null
            val register = objectValue(value) ?: return null
            if (objectValue(register["fieldClocks"]) == null) return null
            val profile = objectValue(register["profile"]) ?: return null
            return profile.takeIf { text(it["id"]) == key && isNativeProfile(it, owner) }
        }

        private fun baselineOwner(row: HostFields): String? {
            if (!schema(row["schemaVersion"], 2) || list(row["deletedProfileIds"])?.all { text(it) != null } != true ||
                listOf("addons", "libraries", "watches", "identityLinks").any { objectValue(row[it]) == null }) return null
            val roster = list(row["roster"]) ?: return null
            val primary = roster.filter { bool(objectValue(it)?.get("owner")) == true }.singleOrNull() ?: return null
            val owner = text(objectValue(primary)?.get("id")) ?: return null
            return owner.takeIf { roster.all { entry -> objectValue(entry)?.let { isNativeProfile(it, owner) } == true } }
        }

        private fun isNativeProfile(row: HostFields, owner: String): Boolean {
            val id = text(row["id"]) ?: return false
            if (!uuid.matches(id) || text(row["name"]) == null) return false
            val primary = bool(row["owner"]) ?: return false
            if (primary != (id == owner)) return false
            val account = objectValue(row["account"]) ?: return false
            val kind = text(account["kind"])
            if (!when (kind) {
                "local_only", "pending_own" -> "value" !in account
                "shared" -> !primary && text(account["value"]) == owner
                "own" -> text(account["value"])?.let { it.isNotEmpty() && it.codePoints().noneMatch(::control) } == true
                else -> false
            }) return false
            val parental = objectValue(row["parental"]) ?: return false
            return bool(parental["kids"]) != null && bool(parental["familyEdit"]) != null &&
                objectValue(row["settings"]) != null && text(row["addons"]) in setOf("own", "share_primary") &&
                (unwrap(row["pin"]) == null || text(row["pin"]) != null) &&
                ("deleted" !in row || bool(row["deleted"]) != null) &&
                listOf("rev", "updatedAt").all { key -> key !in row ||
                    integer(row[key])?.let { it.signum() >= 0 && it.toDouble().isFinite() } == true }
        }

        private fun isSeriesChoice(row: HostFields): Boolean =
            text(row["addon"]) != null && number(row["ts"])?.toDouble()?.isFinite() == true &&
                listOf("bingeGroup", "audioLanguage").all { unwrap(row[it]) == null || text(row[it]) != null } &&
                (unwrap(row["resolution"]) == null || integer(row["resolution"])?.let { it in signedIntLow..signedIntHigh } == true)

        private fun isDescriptor(row: HostFields): Boolean {
            if (!configuredUrl(text(row["transportUrl"]))) return false
            val manifest = objectValue(row["manifest"]) ?: return false
            return listOf("id", "name", "version").all { text(manifest[it])?.isNotEmpty() == true }
        }

        private fun isWebsiteEvent(row: HostFields): Boolean {
            if (text(row["eventId"])?.let(hex32::matches) != true) return false
            val counterText = text(row["counter"]) ?: return false
            val counter = counterText.toULongOrNull() ?: return false
            if (counter == ULong.MAX_VALUE || counter.toString() != counterText) return false
            fun clock(key: String, integral: Boolean = true): Boolean =
                (if (integral) integer(row[key]) else number(row[key]))?.let { it.signum() >= 0 && it <= safeClock } == true
            if (integer(row["version"])?.compareTo(BigDecimal.valueOf(3)) == 0 &&
                row.keys == setOf("version", "counter", "eventId", "state", "wallTime", "legacyRemovedSeen", "legacyAddedSeen")) {
                return text(row["state"]) in setOf("present", "removed") &&
                    listOf("wallTime", "legacyRemovedSeen", "legacyAddedSeen").all { clock(it, integral = false) }
            }
            if (!schema(row["schemaVersion"], 1)) return false
            val digest = text(row["fingerprint"])?.let(hex64::matches) == true
            if (row.keys == setOf("schemaVersion", "counter", "eventId", "fingerprint", "observedClock")) {
                return digest && clock("observedClock")
            }
            if (listOf("scope", "ownerProfileId", "profileId").any { text(row[it])?.isNotEmpty() != true }) return false
            val binding = objectValue(row["expectedBinding"]) ?: return false
            if (binding.keys != setOf("account", "revision", "transactionId") || objectValue(binding["account"]) == null ||
                number(binding["revision"]) == null || unwrap(binding["transactionId"])?.let { it !is String } == true) return false
            val base = setOf("schemaVersion", "counter", "eventId", "scope", "ownerProfileId", "profileId", "expectedBinding")
            if (row.keys == base + "fingerprint") return digest
            val required = base + setOf("wallTime", "observed", "mutations")
            return row.keys.containsAll(required) && (required + "order").containsAll(row.keys) && clock("wallTime") &&
                objectValue(row["observed"]) != null && list(row["mutations"])?.all { objectValue(it) != null } == true &&
                ("order" !in row || list(row["order"])?.all { text(it) != null } == true)
        }

        private fun inspectData(bytes: ByteArray, context: Context, path: List<String>, depth: Int) {
            decoded(bytes.size)
            val json = parseJson(utf8View(bytes), allowQuoted = false)
            if (json != null) {
                val next = when {
                    context.role == Role.ROSTER_DATA && json is List<*> -> Context(Role.ROSTER)
                    context.role == Role.SERIES_DATA && json is Map<*, *> -> Context(Role.SERIES_CHOICES)
                    else -> Context()
                }
                inspect(json, next, path, depth + 1)
            } else {
                inspect(AccountFilePlist.decodeValue(bytes), Context(), path, depth + 1)
            }
        }

        private fun inspectText(value: String, context: Context, path: List<String>, depth: Int) {
            if (hex64.matches(value) && isDigestPath(path)) return
            val json = parseJson(value.removePrefix("\uFEFF"), allowQuoted = true)
            if (json != null) {
                decoded(value.toByteArray(Charsets.UTF_8).size)
                inspect(json, Context(), path, depth + 1)
                return
            }
            val bytes = base64(value)
            if (bytes != null) {
                decoded(bytes.size)
                val nested = utf8View(bytes)
                // Binary plists and malformed recognized carriers can contain invalid UTF-8.
                // Replacement text only recognizes a prefix; it can never admit a value.
                val sniff = nested ?: utf8View(bytes, replaceMalformed = true)
                val encoded = parseJson(nested, allowQuoted = true)
                if (encoded != null || sniff?.let(::plistPrefix) == true) {
                    inspect(encoded ?: AccountFilePlist.decodeValue(bytes), Context(), path, depth + 1)
                    return
                }
                require(sniff?.let(::structured) != true && nested?.let(::looksLikeOpenStep) != true)
            }
            if (!structured(value)) return
            val display = context.role == Role.NAME || context.role == Role.ADDON_DISPLAY
            val title = value.trim(::space)
            require((context.role == Role.NAME || context.role == Role.AVATAR) && (value == "[" || value == "{") ||
                display && (hasTag(title, literal = true) || hasTag(title, literal = false)))
        }

        private fun hasTag(text: String, literal: Boolean): Boolean {
            var position = 0
            var tags = 0
            while (position < text.length && text[position] in "[{") {
                val close = if (text[position] == '[') ']' else '}'
                val end = text.indexOf(close, position + 1)
                if (end < 0) return false
                val inside = text.substring(position + 1, end)
                if (inside.isBlank()) return false
                if (literal) {
                    if (inside.codePointCount(0, inside.length) > 64 || !inside.codePoints().allMatch(::literalTagScalar)) return false
                } else if (!tagGraphemes.matches(inside) || inside.codePoints().anyMatch {
                        control(it) || it <= 127 && it.toChar() in TAG_SYNTAX
                    }) return false
                if (parseJson(text.substring(position, end + 1), allowQuoted = false) != null) return false
                tags++
                position = end + 1
                if (position == text.length) break
                val separator = text[position]
                if (!space(separator) && (literal || separator !in TAG_SEPARATOR)) return false
                if (literal) break
                while (position < text.length && space(text[position])) position++
            }
            if (tags == 0) return false
            val suffix = text.substring(position).dropWhile { padding(it) || it in TAG_SEPARATOR }
            if (structured(suffix) || suffix.startsWith('"')) return false
            val bytes = base64(suffix) ?: return true
            decoded(bytes.size)
            val sniff = utf8View(bytes, replaceMalformed = true) ?: return false
            return !structured(sniff) && !significant(sniff).startsWith('"') && !looksLikeOpenStep(sniff)
        }

        private fun parseJson(text: String?, allowQuoted: Boolean): Any? {
            val input = text ?: return null
            val leading = input.firstOrNull { it !in " \t\r\n" }
            if (leading != '{' && leading != '[' && (!allowQuoted || leading != '"')) return null
            val bytes = input.toByteArray(Charsets.UTF_8)
            scan(bytes.size)
            requireJsonWorkBound(bytes)
            return try {
                when (leading) {
                    '{' -> fields(OHJson.Obj(bytes))
                    '[' -> OHJson.array(bytes).map { Raw(it) }
                    else -> OHJson.text(bytes)
                }
            } catch (_: IllegalArgumentException) {
                null
            } catch (_: IllegalStateException) {
                null
            }
        }
    }

    private fun head(bytes: ByteArray): Char? =
        bytes.firstOrNull { it != 0x20.toByte() && it != 0x09.toByte() && it != 0x0a.toByte() && it != 0x0d.toByte() }?.toInt()?.toChar()

    private fun space(char: Char): Boolean = char.isWhitespace() || Character.isSpaceChar(char)
    private fun padding(char: Char): Boolean = space(char) || char == '\uFEFF'
    private fun significant(text: String): String = text.trim(::padding)
    private fun structured(text: String): Boolean {
        val view = significant(text)
        return structuredPrefixes.any { view.startsWith(it) }
    }

    private fun plistPrefix(text: String): Boolean {
        val view = significant(text)
        return structuredPrefixes.drop(2).any { view.startsWith(it) }
    }

    // Refuse a recognizable unsupported OpenStep carrier before treating it as opaque.
    private fun looksLikeOpenStep(text: String): Boolean {
        val view = significant(text)
        if (view.startsWith('(') || view.startsWith('<') ||
            view.startsWith("/*") || view.startsWith("//")) return true

        // A key followed by '=' starts an assignment. A shortcut can precede another entry.
        // Continue past shortcuts so ordinary text such as "Scene; final chapter" remains opaque.
        var start = skipOpenStepTrivia(view, 0)
        var sawShortcut = false
        while (start < view.length) {
            // Old-style parsing can return preceding entries when the next key cannot be read.
            val end = openStepKeyEnd(view, start) ?: return sawShortcut
            val separator = skipOpenStepTrivia(view, end)
            when (view.getOrNull(separator)) {
                '=' -> return true
                ';' -> {
                    sawShortcut = true
                    start = skipOpenStepTrivia(view, separator + 1)
                }
                else -> return false
            }
        }
        return sawShortcut
    }

    private fun openStepKeyEnd(text: String, start: Int): Int? {
        var end = start
        val quote = text[start]
        if (quote == '"' || quote == '\'') {
            end++
            while (end < text.length && text[end] != quote) {
                end += if (text[end] == '\\') 2 else 1
            }
            return if (end < text.length) end + 1 else null
        }
        while (end < text.length && openStepBareKeyCharacter(text[end])) end++
        return if (end > start) end else null
    }

    private fun openStepBareKeyCharacter(char: Char): Boolean =
        char in 'a'..'z' || char in 'A'..'Z' || char in '0'..'9' || char in "_\$/:.-"

    private fun skipOpenStepTrivia(text: String, from: Int): Int {
        var next = from
        while (next < text.length) {
            when {
                text[next] in " \t\r\n\u000b\u000c\u2028\u2029" -> next++
                text.startsWith("//", next) -> {
                    next += 2
                    while (next < text.length && text[next] !in "\r\n\u2028\u2029") next++
                }
                text.startsWith("/*", next) -> {
                    val end = text.indexOf("*/", next + 2)
                    if (end < 0) return text.length
                    next = end + 2
                }
                else -> return next
            }
        }
        return next
    }

    /** Refuse extreme collection shapes before OHJson allocates their child slices. */
    private fun requireJsonWorkBound(bytes: ByteArray) {
        var depth = 0
        var structure = 0
        var quoted = false
        var escaped = false
        for (byte in bytes) {
            val c = byte.toInt().toChar()
            if (quoted) {
                if (escaped) escaped = false
                else if (c == '\\') escaped = true
                else if (c == '"') quoted = false
            } else when (c) {
                '"' -> quoted = true
                '{', '[' -> {
                    if (++depth > MAX_DEPTH + 1) throw Failure(Reason.LIMIT)
                    structure++
                }
                '}', ']' -> depth--
                ',', ':' -> structure++
            }
            if (structure > MAX_NODES * 2) throw Failure(Reason.LIMIT)
        }
    }
    private fun clean(text: String?): Boolean = text != null && text.isNotBlank() && text.codePoints().noneMatch(::control)

    private fun control(point: Int): Boolean = when (Character.getType(point)) {
        Character.CONTROL.toInt(), Character.FORMAT.toInt() -> true
        else -> false
    }

    private fun literalTagScalar(point: Int): Boolean =
        Character.isLetterOrDigit(point) || when (Character.getType(point)) {
            Character.NON_SPACING_MARK.toInt(), Character.ENCLOSING_MARK.toInt(), Character.COMBINING_SPACING_MARK.toInt(),
            Character.LETTER_NUMBER.toInt(), Character.OTHER_NUMBER.toInt() -> true
            else -> point <= 127 && point.toChar() in " ._-+&"
        }

    private fun base64(text: String): ByteArray? {
        // Foundation's default Base64 decoder expects complete 4-character blocks.
        if (text.isEmpty() || text.length % 4 != 0) return null
        return try { Base64.getDecoder().decode(text) } catch (_: IllegalArgumentException) { null }
    }

    private fun configuredUrl(text: String?): Boolean {
        if (text == null || !(text.startsWith("http://", ignoreCase = true) ||
                text.startsWith("https://", ignoreCase = true))) return false
        return try {
            val uri = URI(text.replace(" ", "%20"))
            val authority = uri.rawAuthority?.substringAfterLast('@') ?: return false
            if (authority.startsWith('[')) uri.host?.isNotEmpty() == true
            else authority.substringBefore(':').isNotEmpty()
        } catch (_: java.net.URISyntaxException) {
            false
        }
    }

    private fun isDigestPath(path: List<String>): Boolean {
        val key = path.lastOrNull() ?: return false
        if (key in digestKeys) return true
        if (path.size >= 3 && key == "rootDocumentSha256" &&
            path[path.size - 3] == "ownAccountOverlayQuarantine" && hex64.matches(path[path.size - 2])) return true
        if (path.takeLast(4).take(3) == listOf("nativeSync", "legacyImport", "acceptedFingerprints") && rowIndex.matches(key)) return true
        if (!hex64.matches(key)) return false
        val tail = path.takeLast(5)
        if (tail.size == 5 && tail.take(3) == listOf("nativeSync", "legacyImport", "ownAccountSourceHistory") &&
            digestProfileSlot.matches(tail[3])) return true
        val slot = path.takeLast(7)
        return slot.size == 7 && slot[0] == "nativeSync" && slot[1] == "accountSlots" &&
            slot[3] == "slots" && slot[5] == "sourceHistory"
    }

    /** Strict interpretation view for nested carriers. The candidate bytes are never rewritten. */
    private fun utf8View(bytes: ByteArray, replaceMalformed: Boolean = false): String? {
        fun at(index: Int): Int = bytes.getOrNull(index)?.toInt()?.and(0xff) ?: -1
        fun starts(vararg prefix: Int): Boolean = prefix.indices.all { at(it) == prefix[it] }
        val (encoding, skip) = when {
            starts(0, 0, 0xfe, 0xff) -> "UTF-32BE" to 4
            starts(0xff, 0xfe, 0, 0) -> "UTF-32LE" to 4
            starts(0xef, 0xbb, 0xbf) -> "UTF-8" to 3
            starts(0xfe, 0xff) -> "UTF-16BE" to 2
            starts(0xff, 0xfe) -> "UTF-16LE" to 2
            bytes.size >= 4 && starts(0, 0, 0) -> "UTF-32BE" to 0
            bytes.size >= 4 && at(1) == 0 && at(2) == 0 && at(3) == 0 -> "UTF-32LE" to 0
            bytes.size >= 2 && at(0) == 0 -> "UTF-16BE" to 0
            bytes.size >= 2 && at(1) == 0 -> "UTF-16LE" to 0
            else -> "UTF-8" to 0
        }
        return try {
            val action = if (replaceMalformed) CodingErrorAction.REPLACE else CodingErrorAction.REPORT
            charset(encoding).newDecoder().onMalformedInput(action).onUnmappableCharacter(action)
                .decode(ByteBuffer.wrap(bytes, skip, bytes.size - skip)).toString()
        } catch (_: java.nio.charset.CharacterCodingException) {
            null
        }
    }
}
