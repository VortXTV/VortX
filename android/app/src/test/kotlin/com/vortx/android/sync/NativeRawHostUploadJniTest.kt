package com.vortx.android.sync

import kotlinx.coroutines.runBlocking
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Additional separately selected, authored UNRUN real-JNI/public-body controls. Reuses the
 * actual manager/AES transport/Session/encrypted-store fixture with synthetic server/provider
 * bytes. No live network/account, compiler, device or resource proof. Old87/40/JNI32 and the
 * domain18/JNI3 methods/assertions remain distinct and unchanged. */
class NativeRawHostUploadJniTest {
    private fun verify(mode: String) = runBlocking {
        assumeTrue("Exact reviewed host JNI required; skips are not proof", System.getenv("VORTX_JNI_SYNC") == "1" &&
            !System.getenv("VORTX_JNI_LIBRARY").isNullOrBlank())
        val source = NativeAccountSyncTest()
        source.mainDispatcher()
        try { source.verifyRawHostUploadCase(mode) } finally { source.resetDispatcher() }
    }

    @Test fun pendingRawArraysUploadWithUnknownNativeRootProviderAndSettingConservation() = verify("warm")
    @Test fun coldReopenNeedsNoOldEditReceiptToUploadPendingRawArrays() = verify("cold")
    @Test fun conflictRebuildUsesFreshGetWinnerAndIgnoresRejectionEcho() = verify("retry")
    @Test fun equalEventContradictionOnFreshGetNeverBuildsSecondPut() = verify("equalConflict")
    @Test fun frozenPutSurvivesLaterProfileAndImportEditButAcknowledgesOnlySentRaw() = verify("lateEdit")
    @Test fun mountAuthCancellationOrFileDriftNeverAcknowledgeOldPut() {
        for (mode in listOf("retire", "auth", "cancel", "ackFileDrift")) verify(mode)
    }
    @Test fun exportIsSingleUseReadPairedCheckpointBoundAndIgnoresDtoMutation() = verify("capture")
    @Test fun completePendingProviderAndUnstampedSettingsBudgetRefuseBeforePut() {
        for (mode in listOf("providerBudget", "settingBudget")) verify(mode)
    }
    @Test fun malformedDirtyOrRemoteApplicationCannotBecomeEmptyOrPhantomPendingInput() {
        for (mode in listOf("malformedDirty", "negativeStamp", "remoteWindow")) verify(mode)
    }
    @Test fun lateQueuedGlobalEditIsNotAppliedClearedOrRebasedByOlderReceipt() {
        for (mode in listOf("lateSettings", "clearGuard")) verify(mode)
    }
    @Test fun scalarCurrencyAvoidsSessionUnderOperationsAndReceiptScopeTakesSessionFirst() = runBlocking {
        assumeTrue("Exact reviewed host JNI required; skips are not proof", System.getenv("VORTX_JNI_SYNC") == "1" &&
            !System.getenv("VORTX_JNI_LIBRARY").isNullOrBlank())
        val source = NativeAccountSyncTest()
        source.mainDispatcher()
        try { source.verifyUploadCurrencyLockOrder() } finally { source.resetDispatcher() }
    }
    @Test fun originalAuthCapturePredatesGetAndRemainsOriginalAcrossRetry() {
        for (mode in listOf("originGet", "originRetry", "originGlobal")) verify(mode)
    }
}
