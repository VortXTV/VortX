package com.vortx.android.sync

import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class VortXQrJoinFlowTest {
    @Test
    fun pollDispositionSeparatesExpiryRetryApprovalAndPending() {
        assertEquals(
            VortXSyncManager.QrPollDisposition.EXPIRED,
            VortXSyncManager.qrPollDisposition(404, false),
        )
        assertEquals(
            VortXSyncManager.QrPollDisposition.EXPIRED,
            VortXSyncManager.qrPollDisposition(410, false),
        )
        listOf(0, 429, 500, 503).forEach { status ->
            assertEquals(
                VortXSyncManager.QrPollDisposition.RETRIABLE_ERROR,
                VortXSyncManager.qrPollDisposition(status, false),
            )
        }
        assertEquals(
            VortXSyncManager.QrPollDisposition.READY,
            VortXSyncManager.qrPollDisposition(200, true),
        )
        assertEquals(
            VortXSyncManager.QrPollDisposition.PENDING,
            VortXSyncManager.qrPollDisposition(200, false),
        )
    }

    @Test
    fun approvedEnvelopeMustAuthenticateBeforeItCanBecomeADataKey() {
        val joiner = VortXPairingCrypto.newEphemeral()
        val dataKey = ByteArray(32) { it.toByte() }
        val (claim, wrapped) = requireNotNull(
            VortXPairingCrypto.wrapDataKey(dataKey, joiner.publicKeyBase64URL),
        )
        val envelope = JSONObject()
            .put("claim", claim)
            .put("wrapped", wrapped)
            .toString()

        assertArrayEquals(
            dataKey,
            VortXSyncManager.unwrapQrPayload(envelope, joiner.privateKey),
        )
        assertNull(VortXSyncManager.unwrapQrPayload("{}", joiner.privateKey))
        assertNull(VortXSyncManager.unwrapQrPayload(envelope, VortXPairingCrypto.newEphemeral().privateKey))
    }
}
