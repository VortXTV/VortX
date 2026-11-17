package com.vortx.android.sync

import com.vortx.android.engine.OHJson
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeWebsiteRosterDenialReceiptTest {
    private val accountId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private val anotherAccount = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    private val key = ByteArray(32) { it.toByte() }
    private val anotherKey = ByteArray(32) { (it + 1).toByte() }
    private val original = raw("""{"catalog":"fixture"}""")
    private val projected = raw("""{"catalog":"fixture","roster":"fixture"}""")

    @Test fun `canonical receipt matches independent framing vector after reload`() {
        val encoded = receipt().encode()
        assertEquals("v1:42:43:" +
            "bf0e19e9027538da82aef7a559ab667dceb27e854a16b887479fcfe8a6dfcab2:" +
            "f02364899fc98a33bd36e2f261eadddd2e4a25fd06ef010573c22fd0b1c1831a:" +
            "c63f63715d4041d5f20f5f307dd58e595c8d25c49ff790b10b4d1df575df9d83", encoded)
        val reopened = NativeWebsiteRosterDenialReceipt.decode(encoded, accountId, key.copyOf())
        assertEquals(encoded, reopened.encode())
        assertEquals(42L, reopened.originalRevision)
        assertEquals(43L, reopened.targetRevision)
        assertTrue(reopened.matchesAttempt(accountId, key, 42, original.copyOf(), 43, projected.copyOf()))
        assertTrue(reopened.matchesProjectedBytes(accountId, key, 43, projected.copyOf()))
        assertFalse(encoded.contains("fixture"))
        assertFalse(encoded.contains(accountId))
        assertFalse(encoded.contains("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"))
    }

    @Test fun `restored first evidence refuses changed raw or head revision`() {
        val saved = NativeWebsiteRosterDenialReceipt.decode(receipt().encode(), accountId, key)
        val differentlySpelledOriginal = raw("""{"catalog":"f\u0069xture"}""")
        val differentlySpelledProjection = raw("""{ "catalog":"fixture","roster":"fixture"}""")
        assertFalse(saved.matchesAttempt(accountId, key, 41, original, 42, projected))
        assertFalse(saved.matchesAttempt(accountId, key, 43, original, 44, projected))
        assertFalse(saved.matchesAttempt(accountId, key, 42, original, 44, projected))
        assertFalse(saved.matchesAttempt(accountId, key, 42, differentlySpelledOriginal, 43, projected))
        assertFalse(saved.matchesAttempt(accountId, key, 42, original, 43, differentlySpelledProjection))
        assertFalse(saved.matchesProjectedBytes(accountId, key, 44, projected))
        assertFalse(saved.matchesProjectedBytes(accountId, key, 43, differentlySpelledProjection))
        assertFalse(saved.matchesProjectedBytes(accountId, key, 43, original))
        assertTrue(saved.matchesAttempt(accountId, key, 42, original, 43, projected))
    }

    @Test fun `account key and document roles cannot substitute`() {
        val saved = receipt()
        assertThrows(IllegalArgumentException::class.java) {
            NativeWebsiteRosterDenialReceipt.decode(saved.encode(), anotherAccount, key)
        }
        assertThrows(IllegalArgumentException::class.java) {
            NativeWebsiteRosterDenialReceipt.decode(saved.encode(), accountId, anotherKey)
        }
        assertFalse(saved.matchesAttempt(anotherAccount, key, 42, original, 43, projected))
        assertFalse(saved.matchesAttempt(accountId, anotherKey, 42, original, 43, projected))
        assertFalse(saved.matchesAttempt(accountId, key, 42, projected, 43, original))
        assertFalse(saved.matchesProjectedBytes(anotherAccount, key, 43, projected))
        assertFalse(saved.matchesProjectedBytes(accountId, anotherKey, 43, projected))
        val originalTag = saved.encode().split(':')[3]
        val candidateAtSameRevision = receipt(41, 42, projected, original).encode().split(':')[4]
        assertFalse(originalTag == candidateAtSameRevision)
    }

    @Test fun `strict encoding rejects tampering and noncanonical records`() {
        val saved = receipt().encode()
        val fields = saved.split(':')
        fun replacing(index: Int, value: String) = fields.toMutableList().apply { this[index] = value }.joinToString(":")
        val anotherProjection = receipt(after = raw("{}")).encode().split(':')[4]
        fun changedTag(tag: String) = (if (tag[0] == '0') "1" else "0") + tag.drop(1)
        val malformed = listOf(
            "", "v1", "$saved:", "$saved\n", " $saved", "a".repeat(300),
            replacing(0, "v2"), replacing(1, "042"), replacing(1, "+42"), replacing(1, "-42"),
            replacing(1, "4.2e1"), replacing(2, "44"), replacing(1, "9007199254740992"),
            replacing(3, fields[3].uppercase()), replacing(3, changedTag(fields[3])),
            replacing(4, anotherProjection), replacing(5, changedTag(fields[5])),
            saved.replaceFirst("v1:42:43:", "v1:43:44:"),
            saved.replace(":${fields[3]}:${fields[4]}:", ":${fields[4]}:${fields[3]}:"),
        )
        for (encoded in malformed) {
            assertThrows(IllegalArgumentException::class.java) {
                NativeWebsiteRosterDenialReceipt.decode(encoded, accountId, key)
            }
        }
    }

    @Test fun `only nonempty bounded raw and exact successor revisions may be recorded`() {
        assertEquals(1L, receipt(0, 1).targetRevision)
        val maximum = BackupRevisionPolicy.MAX_VERSION
        val maximumRecord = receipt(maximum - 1, maximum).encode()
        assertEquals(maximum, NativeWebsiteRosterDenialReceipt.decode(maximumRecord, accountId, key).targetRevision)
        assertThrows(IllegalArgumentException::class.java) { receipt(-1, 0) }
        assertThrows(IllegalArgumentException::class.java) { receipt(0, 0) }
        assertThrows(IllegalArgumentException::class.java) { receipt(maximum, maximum + 1) }
        assertThrows(IllegalArgumentException::class.java) { receipt(before = byteArrayOf()) }
        assertThrows(IllegalArgumentException::class.java) { receipt(after = byteArrayOf()) }
        val oversized = ByteArray(OHJson.MAX + 1)
        assertThrows(IllegalArgumentException::class.java) { receipt(before = oversized) }
        assertThrows(IllegalArgumentException::class.java) { receipt(after = oversized) }
        assertThrows(IllegalArgumentException::class.java) {
            NativeWebsiteRosterDenialReceipt.decode(receipt().encode(), accountId, ByteArray(31))
        }
        assertThrows(IllegalArgumentException::class.java) {
            NativeWebsiteRosterDenialReceipt.decode(receipt().encode(), accountId.uppercase(), key)
        }
    }

    private fun receipt(base: Long = 42, target: Long = 43, before: ByteArray = original, after: ByteArray = projected) =
        NativeWebsiteRosterDenialReceipt.create(accountId, key, base, before, target, after)

    private fun raw(value: String) = value.toByteArray(Charsets.UTF_8)
}
