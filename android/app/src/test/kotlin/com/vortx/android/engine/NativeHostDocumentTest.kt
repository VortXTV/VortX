package com.vortx.android.engine

import com.vortx.android.backup.BinaryPlist
import com.vortx.android.backup.SettingsBackup
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.util.Base64
import java.util.Date

class NativeHostDocumentTest {
    private fun blob(domain: Map<String, Any>, edit: (JSONObject) -> Unit = {}): String {
        val bytes = requireNotNull(SettingsBackup.encode(domain, "tv.vortx", "VortX", Date(0)))
        val envelope = JSONObject(String(bytes, Charsets.UTF_8)); edit(envelope)
        return Base64.getEncoder().encodeToString(envelope.toString().toByteArray(Charsets.UTF_8))
    }
    private fun envelope(blob: String) = JSONObject(String(Base64.getDecoder().decode(blob), Charsets.UTF_8))
    private fun rawDomain(blob: String): Map<*, *> = BinaryPlist.decode(Base64.getDecoder().decode(envelope(blob).getString("payloadBase64"))) as Map<*, *>
    private fun paths(result: JSONObject): List<String> = result.getJSONArray("excludedCredentialPaths").let { rows ->
        (0 until rows.length()).map(rows::getString)
    }
    private fun failure(document: JSONObject, phrase: String) {
        val error = runCatching { NativeHostDocument.archive(document) }.exceptionOrNull()
        assertTrue("Expected '$phrase', got $error", error is IllegalArgumentException && error.message.orEmpty().contains(phrase))
    }

    @Test fun `known credential carriers omitted with escaped deterministic paths no source mutation`() {
        val source = JSONObject().put("apiKeys", JSONObject().put("realdebrid", "hidden-value"))
            .put("nativeProviderCredentials", JSONObject().put("fields", JSONObject().put("tmdb", "hidden-register")))
            .put("a/b~c", JSONObject().put("access_token", "hidden-nested").put("keep", "yes"))
            .put("nativeSync", JSONObject().put("schemaVersion", 1).put("key", "movie:authToken"))
            .put("activeProfile", "device-selection")
        val before = source.toString(); val result = NativeHostDocument.archive(source)
        assertEquals(before, source.toString())
        assertEquals(listOf("/apiKeys", "/a~1b~0c/access_token", "/nativeProviderCredentials"), paths(result))
        assertFalse(result.toString().contains("hidden-register"))
        assertFalse(result.toString().contains("hidden-value")); assertFalse(result.toString().contains("hidden-nested"))
        val document = result.getJSONObject("document")
        assertEquals("movie:authToken", document.getJSONObject("nativeSync").getString("key"))
        assertEquals("device-selection", document.getString("activeProfile"))
        assertEquals(result.toString(), NativeHostDocument.archive(source).toString())
    }

    @Test fun `configured URLs and literal library key values are never redacted`() {
        val url = "https://example.com/Token-AbC/manifest.json?apiKey=ConfiguredValue"
        val source = JSONObject().put("addons", JSONArray().put(JSONObject().put("transportUrl", url)))
            .put("library", JSONArray().put(JSONObject().put("key", "movie:password")))
            .put("vortx", JSONObject().put("deletedAddonsTs", JSONObject().put(url, JSONObject().put("removedAt", 123.5))))
        val result = NativeHostDocument.archive(source)
        assertEquals(url, result.getJSONObject("document").getJSONArray("addons").getJSONObject(0).getString("transportUrl"))
        assertEquals("movie:password", result.getJSONObject("document").getJSONArray("library").getJSONObject(0).getString("key"))
        assertEquals(123.5, result.getJSONObject("document").getJSONObject("vortx").getJSONObject("deletedAddonsTs").getJSONObject(url).getDouble("removedAt"), 0.0)
        assertTrue(paths(result).isEmpty())
    }

    @Test fun `settings retain nonsecret device keys dates roster Data and unknown envelope metadata`() {
        val date = Date(1720000000123)
        val roster = "[{\"id\":\"profile\",\"name\":\"Viewer\",\"pin\":\"sha256:hash\"}]".toByteArray()
        val sourceBlob = blob(linkedMapOf("stremiox.profiles" to roster, "stremiox.serverURL" to "http://127.0.0.1:11470",
            "stremiox.profiles.active" to "profile", "unknown.date" to date, "unknown.number" to 42L,
            "kcfallback.account" to "must-remove", "unknown.future" to listOf(true, "hello"))) {
            it.put("futureHeader", JSONObject().put("version", 7)).put("createdAt", "2026-01-01T00:00:00.123456Z")
        }
        val result = NativeHostDocument.archive(JSONObject().put("settings", sourceBlob))
        val cleanBlob = result.getJSONObject("document").getString("settings")
        val domain = rawDomain(cleanBlob)
        assertEquals("http://127.0.0.1:11470", domain["stremiox.serverURL"])
        assertEquals("profile", domain["stremiox.profiles.active"]); assertEquals(date, domain["unknown.date"])
        assertEquals(42L, domain["unknown.number"]); assertEquals(listOf(true, "hello"), domain["unknown.future"])
        assertTrue(domain["stremiox.profiles"] is ByteArray)
        assertEquals("Viewer", JSONArray(String(domain["stremiox.profiles"] as ByteArray)).getJSONObject(0).getString("name"))
        assertFalse(domain.containsKey("kcfallback.account"))
        assertEquals(listOf("/settings/payloadBase64/kcfallback.account"), paths(result))
        assertEquals("2026-01-01T00:00:00.123456Z", envelope(cleanBlob).getString("createdAt"))
        assertEquals(7, envelope(cleanBlob).getJSONObject("futureHeader").getInt("version"))
        assertEquals(domain.size, envelope(cleanBlob).getInt("keyCount"))
    }

    @Test fun `nested JSON and plist Data remain Data while credentials are excluded`() {
        val innerJson = "{\"accessToken\":\"secret-json\",\"nested\":{\"key\":\"keep\"}}".toByteArray()
        val innerPlist = requireNotNull(BinaryPlist.encode(mapOf("password" to "secret-plist", "date" to Date(0), "safe" to listOf(1L, false))))
        val sourceBlob = blob(mapOf("jsonData" to innerJson, "plistData" to innerPlist,
            "jsonString" to "{\"refreshToken\":\"secret-string\",\"value\":12}"))
        val result = NativeHostDocument.archive(JSONObject().put("settings", sourceBlob))
        val clean = rawDomain(result.getJSONObject("document").getString("settings"))
        val json = JSONObject(String(clean["jsonData"] as ByteArray))
        assertFalse(json.has("accessToken")); assertEquals("keep", json.getJSONObject("nested").getString("key"))
        val plist = BinaryPlist.decode(clean["plistData"] as ByteArray) as Map<*, *>
        assertFalse(plist.containsKey("password")); assertEquals(Date(0), plist["date"])
        assertTrue(clean["jsonString"] is String); assertEquals(12, JSONObject(clean["jsonString"] as String).getInt("value"))
        assertEquals(listOf("/settings/payloadBase64/jsonData/accessToken", "/settings/payloadBase64/jsonString/refreshToken",
            "/settings/payloadBase64/plistData/password"), paths(result))
    }

    @Test fun `opaque corrupt and unsupported settings are explicit failures`() {
        failure(JSONObject().put("settings", "not base64!"), "base64")
        failure(JSONObject().put("settings", JSONObject()), "inspectable")
        failure(JSONObject().put("settings", blob(mapOf("opaque" to byteArrayOf(1, 2, 3)))), "Opaque settings data")
        failure(JSONObject().put("settings", blob(mapOf("invalidUtf8" to byteArrayOf(0xc3.toByte(), 0x28)))), "UTF-8")
        failure(JSONObject().put("settings", blob(mapOf("safe" to "yes")) { it.put("schema", 99) }), "Unsupported settings schema")
    }

    @Test fun `ambiguous secret-like unmatched field fails rather than guessing`() {
        for (key in listOf("serviceToken", "secretMaterial", "credentialHints", "providerAuthKey")) {
            failure(JSONObject().put(key, "sensitive-value-must-not-be-in-error"), "Ambiguous credential-like")
            failure(JSONObject().put("settings", blob(mapOf(key to "hidden"))), "Ambiguous credential-like")
        }
    }

    @Test fun `JSON arrays and nested structures scrub all known vocabulary`() {
        val names = listOf("auth", "authKey", "password", "apiKey", "apiKeys", "authorization", "bearer", "dataKey",
            "token", "accessToken", "refreshToken", "authToken", "clientSecret", "credentials")
        val array = JSONArray(names.map { JSONObject().put(it, "hidden").put("safe", true) })
        val result = NativeHostDocument.archive(JSONObject().put("rows", array))
        assertEquals(names.size, paths(result).size)
        assertFalse(result.getJSONObject("document").toString().contains("hidden"))
        assertEquals(names.size, result.getJSONObject("document").getJSONArray("rows").length())
    }

    @Test fun `empty Data and null unknown fields are preserved safely`() {
        val result = NativeHostDocument.archive(JSONObject().put("future", JSONObject.NULL).put("settings", blob(mapOf("empty" to byteArrayOf()))))
        assertTrue(result.getJSONObject("document").isNull("future"))
        assertArrayEquals(byteArrayOf(), rawDomain(result.getJSONObject("document").getString("settings"))["empty"] as ByteArray)
    }

    @Test fun `JSON inside JSON strings is inspected recursively in settings Data and root document`() {
        val nested = JSONObject().put("accessToken", "nested-secret").put("safe", "yes").toString()
        val wrapped = JSONObject().put("nested", nested).toString()
        val source = JSONObject().put("futureStructuredString", wrapped)
            .put("settings", blob(mapOf("jsonData" to wrapped.toByteArray(Charsets.UTF_8))))
        val result = NativeHostDocument.archive(source)
        val clean = result.getJSONObject("document")
        assertEquals("yes", JSONObject(JSONObject(clean.getString("futureStructuredString")).getString("nested")).getString("safe"))
        assertFalse(clean.getString("futureStructuredString").contains("nested-secret"))
        val data = rawDomain(clean.getString("settings"))["jsonData"] as ByteArray
        val child = JSONObject(JSONObject(String(data, Charsets.UTF_8)).getString("nested"))
        assertFalse(child.has("accessToken")); assertEquals("yes", child.getString("safe"))
        assertEquals(listOf("/futureStructuredString/nested/accessToken", "/settings/payloadBase64/jsonData/nested/accessToken"), paths(result))
        failure(JSONObject().put("futureStructuredString", "{uninspectable"), "structured settings data")
    }

    @Test fun `noncredential structured strings Data and whole settings preserve exact original bytes`() {
        val structured = " { \"z\" : 1, \"a\" : [ true, false ] } "
        val data = structured.toByteArray(Charsets.UTF_8)
        val sourceBlob = blob(mapOf("futureData" to data, "futureString" to structured))
        val result = NativeHostDocument.archive(JSONObject().put("future", structured).put("settings", sourceBlob))
        assertEquals(structured, result.getJSONObject("document").getString("future"))
        assertEquals(sourceBlob, result.getJSONObject("document").getString("settings"))
        assertTrue(paths(result).isEmpty())

        // A different credential field forces settings re-encoding; unrelated Data/String must still
        // retain their exact bytes and spacing, not merely an equivalent parsed object.
        val redacted = NativeHostDocument.archive(JSONObject().put("settings", blob(mapOf("futureData" to data,
            "futureString" to structured, "kcfallback.account" to "hidden"))))
        val domain = rawDomain(redacted.getJSONObject("document").getString("settings"))
        assertArrayEquals(data, domain["futureData"] as ByteArray); assertEquals(structured, domain["futureString"])
    }

    @Test fun `base64 JSON and plist strings outside settings scrub known credentials recursively`() {
        fun encoded(text: String) = Base64.getEncoder().encodeToString(text.toByteArray(Charsets.UTF_8))
        val json = encoded(JSONObject().put("authKey", "hidden-json").put("safe", true).toString())
        val plist = Base64.getEncoder().encodeToString(requireNotNull(BinaryPlist.encode(mapOf("password" to "hidden-plist", "when" to Date(0), "count" to 8L))))
        val array = encoded(JSONArray().put(JSONObject().put("refreshToken", "hidden-array").put("key", "movie:tt123")).toString())
        val result = NativeHostDocument.archive(JSONObject().put("futureJson", json).put("futurePlist", plist).put("futureArray", array))
        val clean = result.getJSONObject("document")
        assertTrue(envelope(clean.getString("futureJson")).getBoolean("safe")); assertFalse(envelope(clean.getString("futureJson")).has("authKey"))
        val decodedPlist = BinaryPlist.decode(Base64.getDecoder().decode(clean.getString("futurePlist"))) as Map<*, *>
        assertFalse(decodedPlist.containsKey("password")); assertEquals(Date(0), decodedPlist["when"]); assertEquals(8L, decodedPlist["count"])
        val decodedArray = JSONArray(String(Base64.getDecoder().decode(clean.getString("futureArray")), Charsets.UTF_8))
        assertFalse(decodedArray.getJSONObject(0).has("refreshToken")); assertEquals("movie:tt123", decodedArray.getJSONObject(0).getString("key"))
        assertEquals(listOf("/futureArray/0/refreshToken", "/futureJson/authKey", "/futurePlist/password"), paths(result))
    }

    @Test fun `nested backup envelopes inspect plist payloads and preserve unknown headers in every carrier`() {
        val backup = blob(mapOf("kcfallback.account" to "hidden", "stremiox.serverURL" to "http://127.0.0.1:11470", "future" to 9L)) {
            it.put("futureHeader", JSONObject().put("stable", "yes"))
        }
        val source = JSONObject().put("objectCarrier", envelope(backup)).put("textCarrier", envelope(backup).toString())
            .put("base64Carrier", backup)
        val result = NativeHostDocument.archive(source).getJSONObject("document")
        val carriers = listOf(result.getJSONObject("objectCarrier"), JSONObject(result.getString("textCarrier")), envelope(result.getString("base64Carrier")))
        for (carrier in carriers) {
            val domain = BinaryPlist.decode(Base64.getDecoder().decode(carrier.getString("payloadBase64"))) as Map<*, *>
            assertFalse(domain.containsKey("kcfallback.account")); assertEquals(9L, domain["future"])
            assertEquals("http://127.0.0.1:11470", domain["stremiox.serverURL"])
            assertEquals("yes", carrier.getJSONObject("futureHeader").getString("stable")); assertEquals(2, carrier.getInt("keyCount"))
        }
        val archived = NativeHostDocument.archive(source)
        assertEquals(listOf("/base64Carrier/payloadBase64/kcfallback.account", "/objectCarrier/payloadBase64/kcfallback.account",
            "/textCarrier/payloadBase64/kcfallback.account"), paths(archived))
    }

    @Test fun `base64 structures recurse inside settings strings Data and encoded JSON string wrappers`() {
        fun encoded(text: String) = Base64.getEncoder().encodeToString(text.toByteArray(Charsets.UTF_8))
        val nested = JSONObject().put("accessToken", "hidden").put("value", "keep").toString()
        val encodedJsonString = encoded(JSONObject.quote(nested))
        val doubleEncoded = encoded(encoded(nested))
        val source = JSONObject().put("quoted", encodedJsonString).put("double", doubleEncoded)
            .put("settings", blob(mapOf("futureString" to encoded(nested), "futureData" to encoded(nested).toByteArray(Charsets.UTF_8))))
        val result = NativeHostDocument.archive(source)
        val clean = result.getJSONObject("document")
        val decodedQuoted = org.json.JSONTokener(String(Base64.getDecoder().decode(clean.getString("quoted")), Charsets.UTF_8)).nextValue() as String
        assertEquals("keep", JSONObject(decodedQuoted).getString("value")); assertFalse(JSONObject(decodedQuoted).has("accessToken"))
        val decodedDouble = JSONObject(String(Base64.getDecoder().decode(Base64.getDecoder().decode(clean.getString("double"))), Charsets.UTF_8))
        assertEquals("keep", decodedDouble.getString("value")); assertFalse(decodedDouble.has("accessToken"))
        val domain = rawDomain(clean.getString("settings"))
        assertFalse(envelope(domain["futureString"] as String).has("accessToken"))
        assertFalse(envelope(String(domain["futureData"] as ByteArray, Charsets.UTF_8)).has("accessToken"))
        assertEquals(listOf("/double/accessToken", "/quoted/accessToken", "/settings/payloadBase64/futureData/accessToken",
            "/settings/payloadBase64/futureString/accessToken"), paths(result))
    }

    @Test fun `opaque ordinary strings URLs and unchanged base64 retain exact original bytes`() {
        val safeJson = " { \"future\" : [1, 2, 3] } "
        val encoded = Base64.getEncoder().withoutPadding().encodeToString(safeJson.toByteArray(Charsets.UTF_8))
        val opaque = Base64.getEncoder().encodeToString(byteArrayOf(0xff.toByte(), 1, 2, 3))
        val url = "https://example.com/Config%2FAbC/manifest.json?opaque=$encoded"
        val source = JSONObject().put("safe", " \n$encoded\n ").put("opaque", opaque).put("text", "Ordinary viewing preference")
            .put("url", url).put("futureBackup", blob(mapOf("safe" to safeJson)))
        val result = NativeHostDocument.archive(source)
        for (key in source.keys()) assertEquals(source.getString(key), result.getJSONObject("document").getString(key))
        assertTrue(paths(result).isEmpty())
        val direct = envelope(source.getString("futureBackup"))
        val archivedDirect = NativeHostDocument.archive(JSONObject().put("direct", direct)).getJSONObject("document").getJSONObject("direct")
        assertEquals(direct.getString("payloadBase64"), archivedDirect.getString("payloadBase64"))
    }

    @Test fun `malformed recognizable base64 JSON plist and nested backups fail closed`() {
        fun encoded(text: String) = Base64.getEncoder().encodeToString(text.toByteArray(Charsets.UTF_8))
        failure(JSONObject().put("future", encoded("{uninspectable")), "structured settings data")
        failure(JSONObject().put("future", encoded("{\"safe\":true}") + "!"), "Malformed recognizable base64")
        failure(JSONObject().put("future", "ey!"), "Malformed recognizable base64")
        failure(JSONObject().put("future", encoded("bplist00malformed")), "property-list data cannot be inspected")
        failure(JSONObject().put("future", blob(mapOf("safe" to true)) { it.put("schema", 999) }), "Unsupported settings schema")
        failure(JSONObject().put("future", envelope(blob(mapOf("safe" to true))).put("payloadBase64", "invalid!")), "cannot be inspected losslessly")
        failure(JSONObject().put("future", encoded("[\"unterminated")), "structured settings data")
    }

    @Test fun `recursive encoded and object carriers retain bounded inspection`() {
        var nested = JSONObject().put("safe", "yes")
        repeat(70) { nested = JSONObject().put("nested", nested) }
        val encoded = Base64.getEncoder().encodeToString(nested.toString().toByteArray(Charsets.UTF_8))
        failure(JSONObject().put("future", encoded), "inspection limits")
    }

    @Test fun `direct and double quoted JSON strings inspect recursively and retain string layers`() {
        val payload = "{\"authKey\":\"quoted-secret\",\"safe\":true}"
        val quoted = JSONObject.quote(payload)
        val result = NativeHostDocument.archive(JSONObject().put("single", quoted).put("double", JSONObject.quote(quoted)))
        val clean = result.getJSONObject("document")
        fun unquote(value: String) = org.json.JSONTokener(value).nextValue() as String
        assertTrue(JSONObject(unquote(clean.getString("single"))).getBoolean("safe"))
        assertFalse(JSONObject(unquote(clean.getString("single"))).has("authKey"))
        assertFalse(JSONObject(unquote(unquote(clean.getString("double")))).has("authKey"))
        assertEquals(listOf("/double/authKey", "/single/authKey"), paths(result))
        failure(JSONObject().put("future", "\"unterminated"), "structured settings data")
    }
}
