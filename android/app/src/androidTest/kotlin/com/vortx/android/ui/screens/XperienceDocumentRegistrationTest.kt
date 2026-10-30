package com.vortx.android.ui.screens

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.activity.result.ActivityResultRegistry
import androidx.activity.result.contract.ActivityResultContract
import androidx.core.app.ActivityOptionsCompat
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/** SOURCE ONLY / UNRUN. Real registry + production registration body. Claim/cancel collaborators are
 * scripted; these schedules do not prove the ViewModel's original-ticket/native admission or an actual
 * Activity recreation. The separately pinned caller controls and real device checks remain required. */
@RunWith(AndroidJUnit4::class)
class XperienceDocumentRegistrationTest {
    private class Registry(private val failLaunch: Boolean = false) : ActivityResultRegistry() {
        val launches = mutableListOf<Int>()
        override fun <I, O> onLaunch(requestCode: Int, contract: ActivityResultContract<I, O>, input: I,
            options: ActivityOptionsCompat?) {
            launches += requestCode
            if (failLaunch) throw ActivityNotFoundException("Synthetic missing document handler")
        }
        fun saved(): Bundle = Bundle().also { onSaveInstanceState(it) }
    }
    private val originalUri = Uri.parse("content://synthetic-xperience/original")

    @Test fun pendingOriginalResultRegistersBeforeClaimAndDoesNotCancelDeliveredRead() {
        val old = Registry()
        var cancelled = 0
        val first = XperienceDocumentRegistration(old, "original-key", { true }, {}, { cancelled++ })
        first.launchIfUnclaimed()
        val requestCode = old.launches.single()
        val state = old.saved()
        first.dispose(changingConfigurations = true)
        assertEquals(0, cancelled)
        val recreated = Registry().also { it.onRestoreInstanceState(state) }
        assertTrue(recreated.dispatchResult(requestCode, Activity.RESULT_OK, Intent().setData(originalUri)))
        val order = mutableListOf<String>()
        val receiver = XperienceDocumentRegistration(recreated, "original-key",
            { order += "claim-original"; false },
            { result -> assertEquals(originalUri, result); order += "result-original" }, { cancelled++ })
        receiver.launchIfUnclaimed()
        assertEquals(listOf("result-original", "claim-original"), order)
        assertEquals(emptyList<Int>(), recreated.launches)
        receiver.dispose(changingConfigurations = false)
        assertEquals(0, cancelled) // Actual receiver skips cancelling the handed-off read.
    }

    @Test fun configurationReregistrationReceivesLateOriginalResultWithoutSecondLaunch() {
        val old = Registry()
        val results = mutableListOf<Uri?>()
        var cancelled = 0
        val first = XperienceDocumentRegistration(old, "same-original-key", { true }, { results += it }, { cancelled++ })
        first.launchIfUnclaimed()
        val requestCode = old.launches.single()
        val state = old.saved()
        first.dispose(changingConfigurations = true)
        val recreated = Registry().also { it.onRestoreInstanceState(state) }
        val receiver = XperienceDocumentRegistration(recreated, "same-original-key", { false }, { results += it }, { cancelled++ })
        receiver.launchIfUnclaimed()
        assertEquals(emptyList<Int>(), recreated.launches)
        assertTrue(recreated.dispatchResult(requestCode, Activity.RESULT_OK, Intent().setData(originalUri)))
        assertEquals(listOf(originalUri), results)
        receiver.dispose(changingConfigurations = false)
        assertEquals(0, cancelled)
    }

    @Test fun explicitOldDismissalCannotDeliverLateOrNullResultToSuccessorKey() {
        val registry = Registry()
        val cancelled = mutableListOf<String>()
        val delivered = mutableListOf<Pair<String, Uri?>>()
        val old = XperienceDocumentRegistration(registry, "key-a", { true }, { delivered += "a" to it }, { cancelled += "a" })
        old.launchIfUnclaimed()
        val oldCode = registry.launches.single()
        old.dispose(changingConfigurations = false)
        old.dispose(changingConfigurations = false)
        assertEquals(listOf("a"), cancelled)
        val successor = XperienceDocumentRegistration(registry, "key-b", { true }, { delivered += "b" to it }, { cancelled += "b" })
        successor.launchIfUnclaimed()
        val newCode = registry.launches.last()
        registry.dispatchResult(oldCode, Activity.RESULT_CANCELED, null)
        assertEquals(emptyList<Pair<String, Uri?>>(), delivered)
        assertTrue(registry.dispatchResult(newCode, Activity.RESULT_CANCELED, null))
        assertEquals(listOf("b" to null), delivered)
        successor.dispose(changingConfigurations = false)
        // Null result was handed to the original callback; controller cancellation belongs there.
        assertEquals(listOf("a"), cancelled)
    }

    @Test fun configurationSkipDoesNotSuppressExplicitCloseOfReplacementReceiver() {
        val old = Registry()
        var cancelled = 0
        val first = XperienceDocumentRegistration(old, "original-key", { true }, {}, { cancelled++ })
        first.launchIfUnclaimed()
        val state = old.saved()
        first.dispose(changingConfigurations = true)
        val recreated = Registry().also { it.onRestoreInstanceState(state) }
        val receiver = XperienceDocumentRegistration(recreated, "original-key", { false }, {}, { cancelled++ })
        receiver.launchIfUnclaimed()
        receiver.dispose(changingConfigurations = false)
        first.dispose(changingConfigurations = false)
        assertEquals(1, cancelled)
        assertEquals(emptyList<Int>(), recreated.launches)
    }

    @Test fun absentOsHandlerCancelsOnlyOriginalRegistrationOnce() {
        val registry = Registry(failLaunch = true)
        val cancelled = mutableListOf<String>()
        val receiver = XperienceDocumentRegistration(registry, "failed-original", { true },
            { error("Failed launch cannot deliver a result") }, { cancelled += "original" })
        receiver.launchIfUnclaimed()
        receiver.dispose(changingConfigurations = false)
        assertEquals(1, registry.launches.size)
        assertEquals(listOf("original"), cancelled)
    }

    @Test fun restoredRegistryStateAloneDoesNotRegisterOrLaunchOldAuthority() {
        val old = Registry()
        val first = XperienceDocumentRegistration(old, "dead-process-key", { true }, {}, {})
        first.launchIfUnclaimed()
        val oldCode = old.launches.single()
        val platformState = old.saved()
        first.dispose(changingConfigurations = true)
        // A fresh process has no retained State.fileTicket, so the UI creates no old presenter.
        val fresh = Registry().also { it.onRestoreInstanceState(platformState) }
        fresh.dispatchResult(oldCode, Activity.RESULT_OK, Intent().setData(originalUri))
        assertEquals(emptyList<Int>(), fresh.launches)
        val newResults = mutableListOf<Uri?>()
        val newAction = XperienceDocumentRegistration(fresh, "explicit-new-key", { true }, { newResults += it }, {})
        newAction.launchIfUnclaimed()
        assertEquals(emptyList<Uri?>(), newResults)
        newAction.dispose(changingConfigurations = false)
    }
}
