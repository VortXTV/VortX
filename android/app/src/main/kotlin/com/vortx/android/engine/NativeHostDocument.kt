package com.vortx.android.engine

import com.vortx.android.backup.BinaryPlist
import com.vortx.android.backup.SettingsBackup
import org.json.JSONArray
import org.json.JSONObject
import org.json.JSONTokener
import java.net.URI
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.util.Base64
import java.util.Date

/**
 * Credential-filtered, complete host-side archive; never a kernel input or a replacement cloud doc.
 * Unknown noncredential fields and device-local selectors are retained. The caller encrypts this
 * result, independently of the kernel snapshot, and keeps the original authenticated cloud carrier.
 */
internal object NativeHostDocument {
    fun archive(document: JSONObject): JSONObject = Sanitizer().archive(document)

    private class Sanitizer {
        private val excluded = sortedSetOf<String>()
        private var nodes = 0

        fun archive(document: JSONObject): JSONObject = JSONObject()
            .put("document", json(document, "", 0, root = true))
            .put("excludedCredentialPaths", JSONArray(excluded.toList()))

        private fun budget(depth: Int) {
            requireArchive(depth <= 64 && ++nodes <= 100_000, "Host document exceeds inspection limits")
        }

        private fun excluded(key: String, path: String): Boolean {
            // Add-on intent maps use the configured URL itself as a dictionary key. Case-sensitive
            // configuration segments are identities, not credential field names; inspect values only.
            val urlKey = runCatching { URI(key) }.getOrNull()
            if (urlKey?.scheme?.lowercase() in setOf("http", "https") && !urlKey?.host.isNullOrBlank()) return false
            val normalized = key.lowercase().filter(Char::isLetterOrDigit)
            if (key.lowercase().startsWith("kcfallback.") || normalized in credentialKeys) {
                excluded += path
                return true
            }
            requireArchive(!normalized.contains("secret") && !normalized.contains("credential") &&
                suspiciousSuffixes.none(normalized::endsWith), "Ambiguous credential-like field requires reconciliation")
            return false
        }

        private fun json(value: Any?, path: String, depth: Int, root: Boolean = false): Any {
            budget(depth)
            return when (value) {
                null, JSONObject.NULL -> JSONObject.NULL
                is JSONObject -> JSONObject().also { result ->
                    for (key in value.keys().asSequence().toList().sorted()) {
                        val childPath = pointer(path, key)
                        if (excluded(key, childPath)) continue
                        val child = value.get(key)
                        result.put(key, if (root && key == "settings" && child != JSONObject.NULL)
                            settings(child, childPath, depth + 1) else json(child, childPath, depth + 1))
                    }
                }
                is JSONArray -> JSONArray().also { result ->
                    for (index in 0 until value.length()) result.put(json(value.get(index), pointer(path, index.toString()), depth + 1))
                }
                is String -> structuredString(value, path, depth)
                is Boolean -> value
                is Number -> value.also { requireArchive(it.toDouble().isFinite(), "Nonfinite host document number") }
                else -> reject("Unsupported host document value")
            }
        }

        private fun settings(value: Any, path: String, depth: Int): String {
            budget(depth)
            val priorExclusions = excluded.size
            val encoded = value as? String ?: reject("Settings carrier is not an inspectable backup")
            val envelopeBytes = decodeBase64(encoded)
            val envelope = parseJson(strictUtf8(envelopeBytes)) as? JSONObject
                ?: reject("Settings envelope is not an object")
            requireArchive(envelope.opt("schema") is Number && envelope.getDouble("schema") == 1.0,
                "Unsupported settings schema")
            // This validates the shipping envelope. Its RETURN VALUE is deliberately not used:
            // decodeDomain filters device-local NONsecret settings, which this archive must preserve.
            requireArchive(SettingsBackup.decodeDomain(envelopeBytes) != null, "Settings backup cannot be inspected losslessly")
            val payload = envelope.opt("payloadBase64") as? String ?: reject("Missing settings payload")
            val rawDomain = BinaryPlist.decode(decodeBase64(payload)) as? Map<*, *>
                ?: reject("Settings payload is not a representable property-list dictionary")
            val domain = plist(rawDomain, pointer(path, "payloadBase64"), depth + 1) as Map<*, *>
            val stringDomain = linkedMapOf<String, Any>()
            for ((key, child) in domain) stringDomain[key as? String ?: reject("Nonstring settings key")] = child ?: reject("Null settings value")
            val generated = SettingsBackup.encode(stringDomain, envelope.getString("bundleID"), envelope.getString("app"), Date(0))
                ?: reject("Sanitized settings cannot be represented losslessly")
            val generatedEnvelope = parseJson(strictUtf8(generated)) as JSONObject
            // Preserve every original noncredential envelope header, including unknown headers and the
            // exact createdAt spelling. Only the redacted payload and its truthful keyCount change.
            val cleanEnvelope = json(envelope, path, depth + 1) as JSONObject
            cleanEnvelope.put("payloadBase64", generatedEnvelope.getString("payloadBase64"))
            cleanEnvelope.put("keyCount", stringDomain.size)
            if (excluded.size == priorExclusions) return encoded
            return Base64.getEncoder().encodeToString(cleanEnvelope.toString().toByteArray(Charsets.UTF_8))
        }

        private fun plist(value: Any, path: String, depth: Int): Any {
            budget(depth)
            return when (value) {
                is Map<*, *> -> linkedMapOf<String, Any>().also { result ->
                    val entries = value.entries.map { (key, child) ->
                        (key as? String ?: reject("Nonstring property-list key")) to (child ?: reject("Null property-list value"))
                    }.sortedBy { it.first }
                    for ((key, child) in entries) {
                        val childPath = pointer(path, key)
                        if (!excluded(key, childPath)) result[key] = plist(child, childPath, depth + 1)
                    }
                }
                is List<*> -> value.mapIndexed { index, child ->
                    plist(child ?: reject("Null property-list array item"), pointer(path, index.toString()), depth + 1)
                }
                is ByteArray -> inspectData(value, path, depth + 1)
                is Date -> Date(value.time)
                is String -> structuredString(value, path, depth)
                is Boolean, is Long, is Int, is Short, is Byte -> value
                is Double -> value.also { requireArchive(it.isFinite(), "Nonfinite property-list number") }
                is Float -> value.also { requireArchive(it.isFinite(), "Nonfinite property-list number") }
                else -> reject("Unsupported property-list value")
            }
        }

        private fun structuredString(value: String, path: String, depth: Int): String {
            // Both settings and unknown document fields may carry nested JSON as STRING, including
            // strings inside JSON Data. Recurse while preserving the carrier, not just the first level.
            val trimmed = value.trimStart()
            if (!trimmed.startsWith('{') && !trimmed.startsWith('[')) return value
            val priorExclusions = excluded.size
            val clean = json(parseJson(value), path, depth + 1).toString()
            return if (excluded.size == priorExclusions) value else clean
        }

        private fun inspectData(bytes: ByteArray, path: String, depth: Int): ByteArray {
            budget(depth)
            val priorExclusions = excluded.size
            if (bytes.isEmpty()) return bytes.copyOf()
            if (bytes.size >= 8 && bytes.copyOfRange(0, 8).contentEquals("bplist00".toByteArray(Charsets.US_ASCII))) {
                val decoded = BinaryPlist.decode(bytes) ?: reject("Nested property-list data cannot be inspected")
                val clean = BinaryPlist.encode(plist(decoded, path, depth + 1)) ?: reject("Nested property-list data cannot be preserved")
                return if (excluded.size == priorExclusions) bytes.copyOf() else clean
            }
            val decoded = parseJson(strictUtf8(bytes))
            requireArchive(decoded is JSONObject || decoded is JSONArray, "Opaque settings data requires reconciliation")
            val clean = json(decoded, path, depth + 1).toString().toByteArray(Charsets.UTF_8)
            return if (excluded.size == priorExclusions) bytes.copyOf() else clean
        }
    }

    private val credentialKeys = setOf("auth", "authkey", "password", "apikey", "apikeys", "authorization", "bearer", "datakey",
        "token", "accesstoken", "refreshtoken", "authtoken", "clientsecret", "credentials")
    private val suspiciousSuffixes = listOf("token", "password", "authkey", "apikey")

    private fun pointer(path: String, key: String): String = path + "/" + key.replace("~", "~0").replace("/", "~1")
    private fun decodeBase64(value: String): ByteArray = runCatching { Base64.getDecoder().decode(value) }
        .getOrElse { reject("Invalid base64 settings carrier") }
    private fun strictUtf8(bytes: ByteArray): String = runCatching {
        Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT)
            .decode(ByteBuffer.wrap(bytes)).toString()
    }.getOrElse { reject("Opaque or invalid UTF-8 settings data") }
    private fun parseJson(value: String): Any = try {
        val reader = JSONTokener(value)
        val parsed = reader.nextValue()
        requireArchive(reader.nextClean() == '\u0000', "Trailing settings data cannot be inspected")
        parsed
    } catch (_: Exception) { reject("Opaque or malformed structured settings data") }
    private fun requireArchive(condition: Boolean, message: String) { if (!condition) reject(message) }
    private fun reject(message: String): Nothing = throw IllegalArgumentException("Native host archive reconciliation required: $message")
}
