package com.vortx.android.sync

import com.vortx.android.engine.OHJson
import java.io.InputStream
import org.junit.Assert.*
import org.junit.Test

/** Pure framing/parser and bounded-read tests; ciphertext is synthetic and is never decrypted. */
class AccountBackupFileTest {
    private val sealed = OHJson.b64(ByteArray(28) { 17 })
    private val cipher = "v2.$sealed"
    private fun response(version: String = "42", document: String = "\"$cipher\"") =
        """{"document":$document,"version":$version,"future":{"integer":9007199254740991.1}}""".toByteArray()
    private fun failure(reason: AccountBackupFile.Reason, action: () -> Unit) {
        try { action(); fail("Expected account-file refusal") }
        catch (error: AccountBackupFile.Failure) { assertEquals(reason, error.reason) }
    }

    @Test fun fullEncryptedFileHasExactWebsiteFieldsAndUntouchedCiphertext() {
        for (version in listOf("0", "42", "9007199254740991")) {
            val file = AccountBackupFile.encodeServerResponse(response(version), "Original user", 1234)
            val root = OHJson.Obj(file)
            assertEquals(setOf("vortxBackup", "username", "exportedAt", "document", "version"), root.keys)
            assertArrayEquals(OHJson.literal("1"), root.raw("vortxBackup"))
            assertEquals("Original user", root.text("username")); assertEquals(1234L, OHJson.integer(root.raw("exportedAt")))
            assertEquals(cipher, root.text("document")); assertEquals(version.toLong(), OHJson.integer(root.raw("version")))
            assertFalse(root.keys.any { it in setOf("token", "dataKey", "settings", "nativeSync") })
        }
        val escaped = "\"v2.\\u0045${sealed.drop(1)}\"" // E is the actual first base64 character for byte 17.
        val file = AccountBackupFile.encodeServerResponse(response(document = escaped), "name", 0)
        assertArrayEquals(escaped.toByteArray(), OHJson.Obj(file).raw("document"))
        assertEquals(cipher, AccountBackupFile.inspect(file).document)
    }

    @Test fun strictRawIngressRejectsDuplicateEscapedKeysAndNonLexicalRevisions() {
        for (version in listOf("-1", "-0", "1.0", "1e0", "\"1\"", "true", "null", "9007199254740991.1", "9007199254740992", "01")) {
            failure(AccountBackupFile.Reason.DAMAGED) { AccountBackupFile.encodeServerResponse(response(version), "name", 0) }
        }
        for (raw in listOf(
            """{"document":"$cipher","version":1,"version":2}""",
            """{"document":"$cipher","version":1,"\u0076ersion":2}""",
            """{"document":"$cipher","version":1,"future":{"x":1,"x":2}}""",
            """{"document":"$cipher","version":1,"é":1,"e\u0301":2}""",
            """{"document":7,"version":1}""", "null", "[]", "{} trailing",
        )) failure(AccountBackupFile.Reason.DAMAGED) { AccountBackupFile.encodeServerResponse(raw.toByteArray(), "name", 0) }
        failure(AccountBackupFile.Reason.DAMAGED) { AccountBackupFile.encodeServerResponse(byteArrayOf(0xc3.toByte(), 0x28), "name", 0) }
    }

    @Test fun framingRejectsUnsupportedEncryptionAndInvalidCanonicalBase64() {
        failure(AccountBackupFile.Reason.UNSUPPORTED_FORMAT) { AccountBackupFile.encodeServerResponse(response(document = "\"v3.$sealed\""), "name", 0) }
        for (document in listOf("", "v2.", "v2.AAAA", "v2.$sealed\n", sealed.dropLast(1))) {
            failure(AccountBackupFile.Reason.DAMAGED) { AccountBackupFile.encodeServerResponse(response(document = String(OHJson.quote(document))), "name", 0) }
        }
        assertEquals(sealed, AccountBackupFile.inspect(AccountBackupFile.encodeServerResponse(response(document = "\"$sealed\""), "name", 0)).document)
    }

    @Test fun inspectingAFileRetainsEveryUnknownByteAndKnownFieldsRemainStrict() {
        val file = """{ "vortxBackup":1,"document":"$cipher","version":42,"username":"name","exportedAt":1,"future":{"n":9007199254740991.1,"space":" x "} }""".toByteArray()
        val inspected = AccountBackupFile.inspect(file)
        assertArrayEquals(file, inspected.originalBytes())
        inspected.originalBytes().fill(0)
        assertArrayEquals(file, inspected.originalBytes())
        failure(AccountBackupFile.Reason.UNSUPPORTED_FORMAT) { AccountBackupFile.inspect(String(file).replace("vortxBackup\":1", "vortxBackup\":1.0").toByteArray()) }
        failure(AccountBackupFile.Reason.DAMAGED) { AccountBackupFile.inspect(String(file).replace("\"username\":\"name\"", "\"username\":7").toByteArray()) }
        failure(AccountBackupFile.Reason.DAMAGED) { AccountBackupFile.inspect(String(file).replace("\"exportedAt\":1", "\"exportedAt\":1e0").toByteArray()) }
    }

    @Test fun fileTenMiBAndResponseEightMiBLimitsAreDifferentAndReadStopsAtFirstExcessByte() {
        val small = response()
        val exact = small + ByteArray(AccountBackupFile.MAXIMUM_RESPONSE_BYTES - small.size) { 32 }
        assertArrayEquals(exact, AccountBackupFile.readBoundedResponse(exact.inputStream()))
        AccountBackupFile.encodeServerResponse(exact, "name", 0)
        var consumed = 0
        val endless = object : InputStream() {
            override fun read(): Int { consumed++; return 32 }
            override fun read(b: ByteArray, off: Int, len: Int): Int { java.util.Arrays.fill(b, off, off + len, 32.toByte()); consumed += len; return len }
        }
        failure(AccountBackupFile.Reason.TOO_LARGE) { AccountBackupFile.readBoundedResponse(endless) }
        assertEquals(AccountBackupFile.MAXIMUM_RESPONSE_BYTES + 1, consumed)
        failure(AccountBackupFile.Reason.TOO_LARGE) { AccountBackupFile.encodeServerResponse(exact + byteArrayOf(32), "name", 0) }
        val file = AccountBackupFile.encodeServerResponse(small, "name", 0)
        val fileAtCap = file + ByteArray(AccountBackupFile.MAXIMUM_FILE_BYTES - file.size) { 32 }
        assertArrayEquals(fileAtCap, AccountBackupFile.inspect(fileAtCap).originalBytes())
        failure(AccountBackupFile.Reason.TOO_LARGE) { AccountBackupFile.inspect(fileAtCap + byteArrayOf(32)) }
    }
}
