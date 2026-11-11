package com.vortx.android.sync

import com.vortx.android.engine.OHJson
import java.nio.ByteBuffer
import java.security.MessageDigest
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/** Local denial evidence for the first detached website roster attempt. Callers must supply a
 * fresh authenticated GET and hold the original lease. A receipt cannot authorize a PUT,
 * authenticate a readback, acknowledge a write, or advance the applied revision. */
internal class NativeWebsiteRosterDenialReceipt private constructor(
    val originalRevision: Long,
    val targetRevision: Long,
    private val originalTag: ByteArray,
    private val projectedTag: ByteArray,
    private val encoded: String,
) {
    fun encode(): String = encoded

    /** Only the exact first base and exact first projection can match after a restart. */
    fun matchesAttempt(
        accountId: String,
        dataKey: ByteArray,
        originalRevision: Long,
        original: ByteArray,
        targetRevision: Long,
        projected: ByteArray,
    ): Boolean {
        if (originalRevision != this.originalRevision || targetRevision != this.targetRevision ||
            !validContext(accountId, dataKey) || !bounded(original) || !bounded(projected)) return false
        return withReceiptMac(dataKey) { mac ->
            val originalMatches = MessageDigest.isEqual(
                originalTag, mac.documentTag(accountId, ORIGINAL, originalRevision, original),
            )
            val projectedMatches = MessageDigest.isEqual(
                projectedTag, mac.documentTag(accountId, PROJECTED, targetRevision, projected),
            )
            originalMatches && projectedMatches
        }
    }

    /** Byte comparison only. Any received bytes still need the caller's own authenticated GET. */
    fun matchesProjectedBytes(accountId: String, dataKey: ByteArray, revision: Long, raw: ByteArray): Boolean {
        if (revision != targetRevision || !validContext(accountId, dataKey) || !bounded(raw)) return false
        return withReceiptMac(dataKey) { mac ->
            MessageDigest.isEqual(projectedTag, mac.documentTag(accountId, PROJECTED, revision, raw))
        }
    }

    companion object {
        private const val DOMAIN = "vortx-android-website-roster-denial-receipt-v1"
        private const val FORMAT = "v1"
        private const val HMAC = "HmacSHA256"
        private const val ORIGINAL: Byte = 1
        private const val PROJECTED: Byte = 2
        private const val RECORD: Byte = 3
        private const val TAG_BYTES = 32
        private const val TAG_CHARS = 2 * TAG_BYTES
        private const val HEX = "0123456789abcdef"
        private const val MIN_RECORD_CHARS = 2 + 5 + 2 + 3 * TAG_CHARS
        private const val MAX_RECORD_CHARS = 2 + 5 + 2 * 16 + 3 * TAG_CHARS
        private const val INVALID = "Invalid website roster denial receipt"
        private val ACCOUNT = Regex("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
        private val DOMAIN_BYTES = DOMAIN.toByteArray(Charsets.US_ASCII)
        private val KEY_PURPOSE = "$DOMAIN/key".toByteArray(Charsets.US_ASCII)

        /** Caller must persist the first encoded value before CAS and refuse uncertain storage. */
        fun create(
            accountId: String,
            dataKey: ByteArray,
            originalRevision: Long,
            original: ByteArray,
            targetRevision: Long,
            projected: ByteArray,
        ): NativeWebsiteRosterDenialReceipt {
            require(validContext(accountId, dataKey) && bounded(original) && bounded(projected) &&
                BackupRevisionPolicy.next(originalRevision) == targetRevision) { INVALID }
            return withReceiptMac(dataKey) { mac ->
                val originalTag = mac.documentTag(accountId, ORIGINAL, originalRevision, original)
                val projectedTag = mac.documentTag(accountId, PROJECTED, targetRevision, projected)
                val seal = mac.recordTag(accountId, originalRevision, targetRevision, originalTag, projectedTag)
                val encoded = listOf(
                    FORMAT, originalRevision.toString(), targetRevision.toString(),
                    originalTag.hex(), projectedTag.hex(), seal.hex(),
                ).joinToString(":")
                NativeWebsiteRosterDenialReceipt(originalRevision, targetRevision, originalTag, projectedTag, encoded)
            }
        }

        /** An existing malformed or unauthentic value throws. Only storage can establish absence. */
        fun decode(encoded: String, accountId: String, dataKey: ByteArray): NativeWebsiteRosterDenialReceipt {
            require(validContext(accountId, dataKey) && encoded.length in MIN_RECORD_CHARS..MAX_RECORD_CHARS) { INVALID }
            val fields = encoded.split(':', limit = 7)
            require(fields.size == 6 && fields[0] == FORMAT) { INVALID }
            val originalRevision = parseRevision(fields[1])
            val targetRevision = parseRevision(fields[2])
            require(BackupRevisionPolicy.next(originalRevision) == targetRevision) { INVALID }
            val originalTag = parseTag(fields[3])
            val projectedTag = parseTag(fields[4])
            val savedSeal = parseTag(fields[5])
            val expectedSeal = withReceiptMac(dataKey) {
                it.recordTag(accountId, originalRevision, targetRevision, originalTag, projectedTag)
            }
            require(MessageDigest.isEqual(savedSeal, expectedSeal)) { INVALID }
            return NativeWebsiteRosterDenialReceipt(originalRevision, targetRevision, originalTag, projectedTag, encoded)
        }

        private fun validContext(accountId: String, dataKey: ByteArray): Boolean =
            dataKey.size == 32 && accountId.length == 36 && ACCOUNT.matches(accountId)

        private fun bounded(raw: ByteArray): Boolean = raw.size in 1..OHJson.MAX

        private fun parseRevision(value: String): Long =
            requireNotNull(value.toLongOrNull()?.takeIf { it.toString() == value }) { INVALID }

        private fun parseTag(value: String): ByteArray {
            require(value.length == TAG_CHARS) { INVALID }
            return ByteArray(TAG_BYTES) { index ->
                val high = HEX.indexOf(value[2 * index])
                val low = HEX.indexOf(value[2 * index + 1])
                require(high >= 0 && low >= 0) { INVALID }
                ((high shl 4) or low).toByte()
            }
        }

        private fun ByteArray.hex(): String = buildString(TAG_CHARS) {
            for (byte in this@hex) {
                val unsigned = byte.toInt() and 255
                append(HEX[unsigned ushr 4])
                append(HEX[unsigned and 15])
            }
        }

        private inline fun <T> withReceiptMac(dataKey: ByteArray, block: (Mac) -> T): T {
            val mac = Mac.getInstance(HMAC)
            mac.init(SecretKeySpec(dataKey, HMAC))
            val receiptKey = mac.doFinal(KEY_PURPOSE)
            try {
                mac.init(SecretKeySpec(receiptKey, HMAC))
                return block(mac)
            } finally {
                receiptKey.fill(0)
            }
        }

        private fun Mac.prefix(accountId: String, purpose: Byte) {
            update(DOMAIN_BYTES)
            update(purpose)
            update(accountId.toByteArray(Charsets.US_ASCII)) // validated fixed-width canonical UUID
        }

        private fun Mac.documentTag(accountId: String, purpose: Byte, revision: Long, raw: ByteArray): ByteArray {
            prefix(accountId, purpose)
            update(ByteBuffer.allocate(12).putLong(revision).putInt(raw.size).array())
            return doFinal(raw)
        }

        private fun Mac.recordTag(
            accountId: String,
            originalRevision: Long,
            targetRevision: Long,
            originalTag: ByteArray,
            projectedTag: ByteArray,
        ): ByteArray {
            prefix(accountId, RECORD)
            update(ByteBuffer.allocate(16).putLong(originalRevision).putLong(targetRevision).array())
            update(originalTag)
            return doFinal(projectedTag)
        }
    }
}
