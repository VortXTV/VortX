package com.vortx.android.deeplink

import android.content.Intent
import android.os.Bundle
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import java.util.UUID

/** Main-thread Intent/Bundle boundary shared by the phone and TV launchers. */
internal class ActivityDeepLinkDelivery {
    private var state = DeepLinkDeliveryState()
    var pendingEvent by mutableStateOf<VortXDeepLinkEvent?>(null)
        private set

    fun restore(saved: Bundle?) {
        state = DeepLinkDeliveryState(
            restoredConsumedDeliveryId = saved?.getString(STATE_DELIVERY_ID),
            restoredPendingType = saved?.getString(STATE_TITLE_TYPE),
            restoredPendingId = saved?.getString(STATE_TITLE_ID),
            restoredPendingSequence = saved?.getLong(STATE_TITLE_SEQUENCE) ?: 0L,
            restoredLaunchFingerprint = saved?.getString(STATE_LAUNCH_FINGERPRINT),
            restoredLatestFingerprint = saved?.getString(STATE_LATEST_FINGERPRINT),
        )
        pendingEvent = state.pendingEvent
    }

    fun route(source: Intent?, forceNewDelivery: Boolean = false) {
        source ?: return
        val retained = if (forceNewDelivery) null else source.getStringExtra(EXTRA_DELIVERY_ID)
        val deliveryId = UUID.randomUUID().toString()
        when (val admission = state.route(deliveryId, source.dataString,
            coldLaunch = !forceNewDelivery, retainedDeliveryId = retained)) {
            is DeepLinkDeliveryState.IntentAdmission.Accepted -> {
                source.putExtra(EXTRA_DELIVERY_ID, deliveryId)
                source.data = null
                pendingEvent = admission.event
            }
            DeepLinkDeliveryState.IntentAdmission.Replay -> source.data = null
            DeepLinkDeliveryState.IntentAdmission.Invalid -> Unit
        }
    }

    fun acknowledge(event: VortXDeepLinkEvent) {
        if (state.acknowledge(event)) pendingEvent = null
    }

    fun save(outState: Bundle) {
        outState.putString(STATE_DELIVERY_ID, state.consumedDeliveryId)
        outState.putString(STATE_LAUNCH_FINGERPRINT, state.launchFingerprint)
        outState.putString(STATE_LATEST_FINGERPRINT, state.latestFingerprint)
        val pending = state.pendingEvent ?: return
        // No URL, profile, account or resume state is saved.
        outState.putString(STATE_TITLE_TYPE, pending.target.type.id)
        outState.putString(STATE_TITLE_ID, pending.target.id)
        outState.putLong(STATE_TITLE_SEQUENCE, pending.sequence)
    }

    private companion object {
        const val STATE_DELIVERY_ID = "vortx.deepLinkDeliveryId"
        const val STATE_LAUNCH_FINGERPRINT = "vortx.deepLinkLaunchFingerprint"
        const val STATE_LATEST_FINGERPRINT = "vortx.deepLinkLatestFingerprint"
        const val STATE_TITLE_TYPE = "vortx.deepLinkPendingType"
        const val STATE_TITLE_ID = "vortx.deepLinkPendingId"
        const val STATE_TITLE_SEQUENCE = "vortx.deepLinkPendingSequence"
        const val EXTRA_DELIVERY_ID = "com.vortx.android.extra.DEEP_LINK_DELIVERY_ID"
    }
}
