package com.vortx.android.ui.tv

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import com.vortx.android.player.PlayerPipBridge
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import com.vortx.android.VortXApplication
import com.vortx.android.deeplink.DeepLinkDeliveryState
import com.vortx.android.deeplink.VortXDeepLinkEvent
import com.vortx.android.home.continueWatchingOwnerIsKnown
import com.vortx.android.player.PlaybackOwnerEpoch
import com.vortx.android.player.PlaybackOwnerToken
import com.vortx.android.tv.TopShelfSettings
import com.vortx.android.tv.WatchNextPublication
import com.vortx.android.tv.WatchNextPublisher
import com.vortx.android.tv.watchNextPublication
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.conflate
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.onStart
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.UUID

/// Android TV (10-foot / D-pad) entry point. This is the activity the `LEANBACK_LAUNCHER` intent lands on
/// (see AndroidManifest.xml), kept DISTINCT from the phone [com.vortx.android.MainActivity] so the two
/// form factors can diverge in layout and focus model while sharing one process and one data path.
///
/// It shares everything below the presentation layer with the phone shell:
///   - the SAME process-wide [com.vortx.android.data.CatalogRepository] / [com.vortx.android.data.AuthRepository]
///     owned by [VortXApplication] (built once per process -- see that class's doc comment for why an
///     Activity-scoped engine instance is unsafe; a second Activity reading the same singleton is exactly
///     the intended path),
///   - the SAME [com.vortx.android.ui.viewmodel.HomeViewModel] / [com.vortx.android.ui.viewmodel.DetailViewModel]
///     (constructed via [com.vortx.android.ui.viewmodel.StremioXViewModelFactory] inside [TvApp]),
///   - the SAME [com.vortx.android.player.PlayerScreen] for playback.
///
/// The active profile (and its Kids content guard) is honored transparently: [VortXApplication.onCreate]
/// stands up `ProfileStore` before any Activity, and the reused ViewModels read the active profile the same
/// way the phone does (the source ranking's `isKids` gate lives inside [DetailViewModel], so it applies on
/// TV with no extra code). Splash + edge-to-edge mirror [com.vortx.android.MainActivity].
class TvActivity : ComponentActivity() {
    private var deepLinkEvent by mutableStateOf<VortXDeepLinkEvent?>(null)
    private var deepLinkSequence = 0L
    private var deepLinkDelivery = DeepLinkDeliveryState()

    override fun onCreate(savedInstanceState: Bundle?) {
        // Same cold-start splash contract as MainActivity: install before super.onCreate so the brand
        // gold mark on warm obsidian covers the gap before Compose's first frame (framework-owned on
        // API 31+, compat-drawn on 26-30). No custom exit animation here -- a TV has no touch-dismiss and
        // the default fade is fine at 10 feet.
        installSplashScreen()
        super.onCreate(savedInstanceState)
        val restoredDeliveryId = savedInstanceState?.getString(STATE_DEEP_LINK_DELIVERY_ID)
        deepLinkDelivery = DeepLinkDeliveryState(
            restoredConsumedDeliveryId = restoredDeliveryId,
        )
        routeDeepLink(intent, restoredDeliveryId = restoredDeliveryId)

        val app = application as VortXApplication
        setContent {
            TvApp(
                repo = app.catalogRepository,
                auth = app.authRepository,
                syncManager = app.syncManager,
                deepLinkEvent = deepLinkEvent,
            )
        }

        // Observe the local playback projection without competing for the visible Home catalog load.
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                val repo = app.catalogRepository
                TopShelfSettings.observeShowContinueWatching(applicationContext)
                    .flowOn(Dispatchers.IO)
                    .collectLatest { enabled ->
                        if (!enabled) {
                            app.clearWatchNextIfDisabled()
                            return@collectLatest
                        }
                        var published: Pair<PlaybackOwnerToken, WatchNextPublication>? = null
                        repo.ctxUpdates().onStart { emit(Unit) }.flowOn(Dispatchers.IO).conflate().collect {
                            val previous = published
                            published = withContext(Dispatchers.IO) {
                                val epoch = PlaybackOwnerEpoch.capture() ?: return@withContext null
                                val owner = repo.continueWatchingOwner()
                                if (!continueWatchingOwnerIsKnown(owner, owner.profileId)) return@withContext null
                                val candidate = watchNextPublication(owner, repo.continueWatchingSnapshot(owner))
                                    ?: return@withContext null
                                val projection = epoch to candidate
                                if (projection == previous) return@withContext previous
                                val success = WatchNextPublisher.publish(applicationContext, candidate.items) { write ->
                                    app.publishWatchNextIfCurrent(candidate.owner, epoch) { isActive && write() }
                                }
                                projection.takeIf { success }
                            }
                        }
                    }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        routeDeepLink(intent, forceNewDelivery = true)
    }

    /// TV shares the phone Activity's pre-S Home-press PiP bridge. The bridge is intentionally a no-op
    /// on API 31+ where params-based auto-enter owns the transition.
    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        PlayerPipBridge.onUserLeaveHint()
    }

    private fun routeDeepLink(
        intent: Intent?,
        restoredDeliveryId: String? = null,
        forceNewDelivery: Boolean = false,
    ) {
        val deliveryId = deliveryId(intent, restoredDeliveryId, forceNewDelivery)
        if (deepLinkDelivery.isConsumed(deliveryId)) {
            clearDeepLinkData(intent)
            return
        }
        val target = deepLinkDelivery.consume(deliveryId, intent?.dataString) ?: return
        clearDeepLinkData(intent)
        deepLinkEvent = VortXDeepLinkEvent(target, ++deepLinkSequence)
    }

    private fun deliveryId(source: Intent?, restoredDeliveryId: String?, forceNew: Boolean): String {
        val retained = source?.getStringExtra(EXTRA_DEEP_LINK_DELIVERY_ID)
        if (!forceNew && restoredDeliveryId != null && retained == restoredDeliveryId) {
            return retained
        }
        return UUID.randomUUID().toString().also { source?.putExtra(EXTRA_DEEP_LINK_DELIVERY_ID, it) }
    }

    private fun clearDeepLinkData(source: Intent?) {
        source ?: return
        source.data = null
        setIntent(source)
    }

    override fun onSaveInstanceState(outState: Bundle) {
        outState.putString(STATE_DEEP_LINK_DELIVERY_ID, deepLinkDelivery.consumedDeliveryId)
        super.onSaveInstanceState(outState)
    }

    private companion object {
        const val STATE_DEEP_LINK_DELIVERY_ID = "vortx.deepLinkDeliveryId"
        const val EXTRA_DEEP_LINK_DELIVERY_ID = "com.vortx.android.extra.DEEP_LINK_DELIVERY_ID"
    }
}
