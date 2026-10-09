package com.vortx.android.sync

import java.math.BigDecimal
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class BackupRevisionPolicyTest {
    @Test fun `accept exact numeric safe integers without lexical integer restriction`() {
        for (value in listOf(0, 1L, 1.0, BigDecimal("1.00"), BigDecimal("1e3"), BackupRevisionPolicy.MAX_VERSION)) {
            assertEquals(BigDecimal(value.toString()).longValueExact(), BackupRevisionPolicy.parse(value))
        }
    }

    @Test fun `reject coercions fractions nonfinite and unsafe revisions`() {
        for (value in listOf(null, JSONObject.NULL, "1", true, -1, 0.5, Double.NaN, Double.POSITIVE_INFINITY,
            BigDecimal("9007199254740991.1"), BigDecimal("9007199254740992"), Long.MAX_VALUE)) {
            assertNull("Invalid revision $value", BackupRevisionPolicy.parse(value))
        }
    }

    @Test fun `successor comes only from base with seed and overflow explicit`() {
        assertEquals(0L, BackupRevisionPolicy.next(null))
        assertEquals(1L, BackupRevisionPolicy.next(0L))
        assertEquals(42L, BackupRevisionPolicy.next(41L))
        assertEquals(BackupRevisionPolicy.MAX_VERSION, BackupRevisionPolicy.next(BackupRevisionPolicy.MAX_VERSION - 1))
        for (base in listOf(-1L, BackupRevisionPolicy.MAX_VERSION, Long.MAX_VALUE)) assertNull(BackupRevisionPolicy.next(base))
    }

    @Test fun `backup response preserves original decimal before platform number rounding`() {
        val body = requireNotNull(BackupRevisionPolicy.decodeResponse("""{"version":9007199254740991.1,"document":"ciphertext"}"""))
        assertEquals(BigDecimal("9007199254740991.1"), body.get("version"))
        assertNull(BackupRevisionPolicy.parse(body.get("version")))
        assertEquals(1L, BackupRevisionPolicy.parse(requireNotNull(BackupRevisionPolicy.decodeResponse("""{"version":1.0}""")).get("version")))
    }

    @Test fun `ambiguous malformed and nonobject response is never empty backup`() {
        for (text in listOf("", "null", "[]", "{} trailing", "{", """{"version":1,"version":2}""")) {
            assertNull(text, BackupRevisionPolicy.decodeResponse(text))
        }
    }

    @Test fun `epoch shaped historical base still advances by exactly one`() {
        assertEquals(1_791_497_691_540L, BackupRevisionPolicy.next(1_791_497_691_539L))
        assertEquals(42L, BackupRevisionPolicy.next(41L))
    }
}
