package com.vortx.android.engine

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.fail
import org.junit.Test
import java.nio.charset.Charset
import java.nio.file.Files
import javax.crypto.spec.SecretKeySpec

/** Exercises the actual extracted AES-GCM store and preflight against JVM temporary files. */
class RepairWatchedCheckpointTest {
    @Test fun `sealed preflight survives store reconstruction and exact raw bytes win CAS`() {
        val directory = Files.createTempDirectory("repair-android-watched-checkpoint-").toFile()
        val scope = VortxAccountScope("account.fixture", "00000000-0000-0000-0000-00000000A11C")
        val key = SecretKeySpec(ByteArray(32) { (it * 7).toByte() }, "AES")
        val first = preflight(scope)
        val writer = VortxEncryptedCheckpointStore(directory) { key }
        writer.commitPreflight(first, null)

        val sealed = directory.listFiles()?.singleOrNull { it.name.endsWith(".sealed") }
        assertNotNull(sealed)
        assertFalse(sealed!!.readBytes().toString(Charset.forName("ISO-8859-1")).contains(first.raw))
        val reopened = VortxEncryptedCheckpointStore(directory) { key }.readPreflight(scope.accountID)
        assertNotNull(reopened)
        assertEquals(first.raw, reopened!!.raw)
        expectFailure { NativeMigrationPreflight.parse(VortxAccountScope("other", scope.ownerProfileID), first.raw) }

        val second = preflight(scope)
        expectFailure { writer.commitPreflight(second, null) }
        writer.commitPreflight(second, first)
        assertEquals(second.raw, VortxEncryptedCheckpointStore(directory) { key }.readPreflight(scope.accountID)!!.raw)
    }

    private fun preflight(scope: VortxAccountScope) = NativeMigrationPreflight.create(
        scope,
        NativeHostDocument.archive(JSONObject().put("safeFixture", "retained")),
        emptyList(),
    )

    private fun expectFailure(block: () -> Unit) {
        try { block(); fail("Expected exact preflight scope or CAS rejection") }
        catch (_: IllegalArgumentException) { }
    }
}
