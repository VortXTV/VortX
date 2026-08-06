package com.vortx.android.ui.viewmodel

import com.vortx.android.sync.VortXSyncManager
import org.junit.Assert.assertEquals
import org.junit.Test

class VortXQrJoinerReducerTest {
    @Test
    fun approvalUrlCarriesUppercaseCodeAndDeviceKey() {
        assertEquals(
            "https://vortx.tv/approve?c=ABCD1234&k=public-key_1",
            vortxApprovalUrl(" abcd1234 ", "public-key_1"),
        )
    }

    @Test
    fun recurringTransportTroubleIsSurfacedAndRelayRecoveryClearsIt() {
        val reducer = QrJoinerReducer()
        repeat(3) {
            assertEquals(
                QrJoinerAction.KeepWaiting(false),
                reducer.onResult(VortXSyncManager.QrJoinResult.TransportError, 1_000),
            )
        }
        assertEquals(
            QrJoinerAction.KeepWaiting(true),
            reducer.onResult(VortXSyncManager.QrJoinResult.TransportError, 1_000),
        )
        assertEquals(
            QrJoinerAction.KeepWaiting(false),
            reducer.onResult(VortXSyncManager.QrJoinResult.Pending, 1_000),
        )
    }

    @Test
    fun expiredOrStaleCodesRemintAndApprovalCompletes() {
        val reducer = QrJoinerReducer()
        assertEquals(
            QrJoinerAction.Remint,
            reducer.onResult(VortXSyncManager.QrJoinResult.Expired, 1_000),
        )
        assertEquals(
            QrJoinerAction.Remint,
            reducer.onResult(VortXSyncManager.QrJoinResult.Pending, 240_000),
        )
        assertEquals(
            QrJoinerAction.SignedIn("owner@example.com"),
            reducer.onResult(VortXSyncManager.QrJoinResult.SignedIn("owner@example.com"), 1_000),
        )
    }
}
