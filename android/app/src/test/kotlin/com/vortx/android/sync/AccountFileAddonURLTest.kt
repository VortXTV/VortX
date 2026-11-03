package com.vortx.android.sync

import com.vortx.android.engine.OHJson
import com.vortx.android.engine.VortxAccountScope
import java.io.File
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Pure production projection, synthetic URL sources. No request/client/network is used.
 * The actual-Apple oracle gate is explicitly opt-in; a skip is UNVERIFIED, never parity proof. */
class AccountFileAddonURLTest {
    private fun resource(name: String) = requireNotNull(javaClass.classLoader?.getResourceAsStream(name)).use { it.readBytes() }
    private fun source(url: String): Pair<String, ByteArray> {
        val fixture = OHJson.Obj(resource("account-file-profile-material.json"))
        val root = OHJson.Obj(OHJson.Obj(OHJson.array(fixture.raw("cases")).first()).raw("source"))
        val vortx = root.obj("vortx"); val child = fixture.text("child")
        val roster = OHJson.array(vortx.raw("roster")).map { raw ->
            val row = OHJson.Obj(raw)
            if (row.text("id") == child) row.set("addonPreferences", OHJson.Obj()
                .set("disabledAddonURLsOverride", OHJson.array(listOf(OHJson.quote(url)))).encoded())
            row.encoded()
        }
        return fixture.text("owner") to root.set("vortx", vortx.set("roster", OHJson.array(roster)).encoded()).encoded()
    }
    private fun attempt(url: String): Result<String> {
        val (owner, bytes) = source(url); val before = bytes.copyOf()
        val admitted = AccountFileLegacyAdmission.admitLegacy(bytes, owner)
        val result = runCatching {
            admitted.prepareMaterial(VortxAccountScope("account.file-url-parity", owner))
        }
        // These assertions are outside the captured operation: a preservation assertion must
        // never be misclassified as an expected preference refusal in a negative vector.
        assertArrayEquals(before, bytes); assertArrayEquals(before, admitted.originalPlaintext())
        // Result.map deliberately does NOT catch structural extraction failures. A successful
        // projection that strips the selected URL or emits malformed material is a fixture
        // failure, never an expected Apple refusal. Do not replace this with mapCatching.
        return result.map { material ->
            val child = OHJson.array(OHJson.Obj(material).raw("roster")).map { OHJson.Obj(it) }
                .single { OHJson.utf8(it.raw("owner")) == "false" }
            OHJson.text(OHJson.array(child.obj("settings").raw("disabledAddons")).single())
        }
    }
    private fun projected(url: String): String = attempt(url).getOrThrow()

    @Test fun decodedHostAndUntouchedConfigurationFixTheReportedIdentityMismatch() {
        assertEquals("https://example.com/Case?Cfg=AbC%2F", projected("https://%65XAMPLE.com/Case?Cfg=AbC%2F"))
        assertEquals("https://xn--bcher-kva.example/Case", projected("https://BÜCHER.example/Case"))
        assertEquals("https://xn--bcher-kva.example/Case", projected("https://B%C3%9CCHER.example/Case"))
        assertEquals("https://xn--bcher-kva.example/Case", projected("https://XN--BCHER-KVA.example/Case"))
        assertEquals("https://%65xample.com/Case?Cfg=%252F", projected("https://%2565XAMPLE.com/Case?Cfg=%252F"))
        assertEquals("https://xn--b%63her%64-9db.example/Case?Cfg=AbC%2F",
            projected("https://b%C3%BC%2563her%2564.example/Case?Cfg=AbC%2F"))
        assertEquals("https://xn--b%64her-n2a.n%63ame.example/Case?Cfg=%252F+AbC",
            projected("https://b%C3%BC%2564her.n%2563ame.example/Case?Cfg=%252F+AbC"))
        assertEquals("https://example.com:443/Case", projected("HTTPS://EXAMPLE.com:443/Case"))
        assertEquals("https://example.com/", projected("https://EXAMPLE.com/"))
        assertEquals("https://example.com", projected("https://EXAMPLE.com"))
        assertEquals("https://[2001:db8::1]/Case", projected("https://[2001:DB8::1]/Case"))
        val composed = projected("https://EXAMPLE.com/café?Cfg=résumé")
        val decomposed = projected("https://EXAMPLE.com/cafe\u0301?Cfg=re\u0301sume\u0301")
        assertEquals("https://example.com/caf%C3%A9?Cfg=r%C3%A9sum%C3%A9", composed)
        assertEquals("https://example.com/cafe%CC%81?Cfg=re%CC%81sume%CC%81", decomposed)
        assertNotEquals("Configured path/query Unicode spelling must not be NFC-normalized", composed, decomposed)
        assertEquals("https://example.com/%252F/%2f?Cfg=%252F+AbC", projected("https://EXAMPLE.com/%252F/%2f?Cfg=%252F+AbC"))
        for (input in listOf("https://name:password@example.com/Case", "https://@example.com/Case",
            "https://example.com/Case#", "file://example.com/Case")) {
            assertTrue(attempt(input).isFailure)
        }
    }

    @Test fun allSharedUrlVectorsMatchAnActualHashedAppleProjectionReceipt() {
        assumeTrue("Root must generate and pin the actual Apple oracle; skipped means UNVERIFIED",
            System.getenv("VORTX_PROFILE_URL_ORACLE_GATE") == "1")
        val file = File(requireNotNull(System.getenv("VORTX_PROFILE_URL_ORACLE")))
        val expectedSHA = requireNotNull(System.getenv("VORTX_PROFILE_URL_ORACLE_SHA256"))
        require(file.isAbsolute && file.isFile && Regex("[0-9a-f]{64}").matches(expectedSHA))
        val oracleBytes = file.readBytes(); assertEquals(expectedSHA, OHJson.sha(oracleBytes))
        val oracle = OHJson.Obj(oracleBytes); val vectorBytes = resource("account-file-addon-url-vectors.json")
        assertEquals(1L, OHJson.integer(oracle.raw("format")))
        assertEquals(OHJson.sha(vectorBytes), oracle.text("vectorsSHA256"))
        val cases = OHJson.array(OHJson.Obj(vectorBytes).raw("cases")).map { OHJson.Obj(it) }
        val results = OHJson.array(oracle.raw("results")).map { OHJson.Obj(it) }
        assertEquals(cases.map { it.text("name") }, results.map { it.text("name") })
        assertEquals(cases.size, cases.map { it.text("name") }.toSet().size)
        for ((case, expected) in cases.zip(results)) {
            val name = case.text("name"); val result = attempt(case.text("url"))
            when (OHJson.utf8(expected.raw("rejected"))) {
                "true" -> { assertNull(expected["normalized"]); assertTrue("Apple refuses $name", result.isFailure) }
                "false" -> assertEquals("Actual Apple parity $name", expected.text("normalized"), result.getOrThrow())
                else -> error("Malformed synthetic oracle outcome")
            }
        }
    }
}
