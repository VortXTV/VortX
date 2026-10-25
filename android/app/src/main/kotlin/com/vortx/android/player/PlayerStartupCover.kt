package com.vortx.android.player

import android.os.SystemClock
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.vortx.android.R
import com.vortx.android.metadata.PosterArtwork
import com.vortx.android.model.PlaybackContext
import com.vortx.android.model.Playable
import com.vortx.android.profile.ContinueWatchingOwnerGate
import com.vortx.android.sources.CanonicalContentIdentity
import com.vortx.android.ui.components.FallbackArtwork
import com.vortx.android.ui.theme.VortXTheme
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
import kotlinx.coroutines.withTimeoutOrNull
import java.util.Locale

private const val STARTUP_LOGO_TIMEOUT_MS = 2_500L
private const val STARTUP_WINDOW_POLL_MS = 250L

/** The only metadata the startup layer may display or use to resolve a clearlogo. */
internal data class PlayerStartupCanonicalMetadata(
    val id: String?,
    val type: String,
    val title: String?,
)

/**
 * Immutable presentation state. The poster remains the current
 * playable's already-bound now-playing poster; it is never inferred from a source URL or ambient detail.
 */
internal data class PlayerStartupArtwork(
    val posterUrl: String?,
    val title: String,
    val logoUrl: String?,
)

/** Pre-engine construction has no artwork request; the same window deadline survives engine publication. */
@Composable
internal fun playerStartupPlaceholder(playable: Playable): PlayerStartupArtwork {
    val canonical = remember(playable.playbackContext, playable.mediaRef) { playerStartupCanonicalMetadata(playable) }
    return PlayerStartupArtwork(playable.posterUrl, canonical?.title ?: stringResource(R.string.player_startup_title), null)
}

/** One per-attempt load latch; keeping it behind the session/owner remember key prevents refetch on re-enable. */
private class StartupArtworkLoadState {
    var attempted by mutableStateOf(false)
    var logoUrl by mutableStateOf<String?>(null)
}

/**
 * Derive one canonical identity from the immutable playback context, or from the immutable media reference.
 * Never use source URL/title fields, ambient detail state, or source-facing metadata here.
 */
internal fun playerStartupCanonicalMetadata(playable: Playable): PlayerStartupCanonicalMetadata? {
    val context = playable.playbackContext
    val contextType = context?.type?.let(::canonicalStartupType)
    val contextTitle = context?.title?.trim()?.takeIf(String::isNotEmpty)?.take(256)
    val mediaRefId = playable.mediaRef?.let(::canonicalStartupMediaId)
    if (contextType != null) {
        // Prefer the already-split MediaRef fields. A local PlaybackContext contentId can be opaque/private;
        // only the existing strict parser may admit it, and the raw value is never sent to public art.
        return PlayerStartupCanonicalMetadata(
            id = mediaRefId ?: context?.let(::canonicalStartupContextId),
            type = contextType,
            title = contextTitle,
        )
    }

    val mediaRef = playable.mediaRef ?: return null
    return PlayerStartupCanonicalMetadata(
        id = mediaRefId,
        type = if (mediaRef.isSeries) "series" else "movie",
        title = mediaRef.title?.trim()?.takeIf(String::isNotEmpty)?.take(256),
    )
}

private fun canonicalStartupType(raw: String): String? = when (raw.trim().lowercase(Locale.ROOT)) {
    "movie" -> "movie"
    "series" -> "series"
    else -> null
}

private fun canonicalStartupImdb(raw: String): String? =
    CanonicalContentIdentity.imdb(raw.trim())?.substringBefore(':')

private fun canonicalStartupContextId(context: PlaybackContext): String? =
    context.contentId.let(::canonicalStartupImdb)
        ?: context.toMediaRef()?.let(::canonicalStartupMediaId)

private fun canonicalStartupMediaId(mediaRef: com.vortx.android.model.MediaRef): String? =
    mediaRef.imdb?.let(::canonicalStartupImdb)
        ?: mediaRef.tmdb?.takeIf { it > 0 }?.let { "tmdb:$it" }

/**
 * Resolve the current title's clearlogo once after engine construction for this active startup attempt.
 * The pre-engine branch uses only its supplied poster/title, so publishing the engine cannot restart a
 * request or extend the shared deadline. [enabled] includes error/exit/PiP/owner/deadline admission.
 */
@Composable
internal fun rememberPlayerStartupArtwork(
    playable: Playable,
    sessionKey: Any,
    ownerRevision: Long,
    enabled: Boolean,
): PlayerStartupArtwork {
    val canonical = remember(playable.playbackContext, playable.mediaRef) {
        playerStartupCanonicalMetadata(playable)
    }
    val titleFallback = stringResource(R.string.player_startup_title)
    val loadState = remember(sessionKey, ownerRevision) { StartupArtworkLoadState() }
    val latestEnabled by rememberUpdatedState(enabled)

    LaunchedEffect(sessionKey, ownerRevision, enabled) {
        if (!enabled) {
            // Error/exit/PiP admission is terminal for this attempt; a later re-enable with the same
            // session key must not rearm the resolver after the parent has retired its startup window.
            loadState.attempted = true
            return@LaunchedEffect
        }
        if (loadState.attempted) return@LaunchedEffect

        // Mark the attempt before suspension: a timeout, failure, or cancellation cannot cause a later
        // engine-only re-enable to start another resolver for this same logical startup mount.
        loadState.attempted = true
        if (!latestEnabled || !ContinueWatchingOwnerGate.serialized { it == ownerRevision }) return@LaunchedEffect
        val metadata = canonical ?: return@LaunchedEffect
        val publicId = metadata.id ?: return@LaunchedEffect
        val resolved = try {
            currentCoroutineContext().ensureActive()
            withTimeoutOrNull(STARTUP_LOGO_TIMEOUT_MS) {
                currentCoroutineContext().ensureActive()
                PosterArtwork.resolvedLogo(publicId, metadata.type, null)
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            null
        }?.trim()?.takeIf(String::isNotEmpty)

        currentCoroutineContext().ensureActive()
        if (resolved == null || !latestEnabled) return@LaunchedEffect

        // A resolver completion may race an owner/profile transition. Publish only while the exact owner
        // revision that mounted this attempt is still current; the keyed state is never handed to a successor.
        ContinueWatchingOwnerGate.serialized { currentRevision ->
            if (currentRevision == ownerRevision && latestEnabled) loadState.logoUrl = resolved
        }
    }

    return PlayerStartupArtwork(
        posterUrl = playable.posterUrl,
        title = canonical?.title ?: titleFallback,
        logoUrl = loadState.logoUrl,
    )
}

/**
 * Static, noninteractive artwork under the parent's gestures/chrome. Both images use the finite keyed
 * fallback helper, with bounded poster/logo decodes and no global loader change or crossfade animation.
 */
@Composable
internal fun PlayerStartupCover(
    artwork: PlayerStartupArtwork,
    modifier: Modifier = Modifier,
) {
    Box(modifier = modifier.fillMaxSize().background(Color.Black)) {
        FallbackArtwork(
            urls = listOf(artwork.posterUrl),
            contentDescription = null,
            modifier = Modifier.fillMaxSize(),
            maxDecodePx = 1_280,
            contentScale = ContentScale.Crop,
            crossfade = false,
            placeholder = { Box(Modifier.fillMaxSize().background(Color.Black)) },
        )
        Box(
            Modifier.fillMaxSize().background(
                Brush.verticalGradient(
                    0f to Color.Black.copy(alpha = 0.28f),
                    0.55f to Color.Black.copy(alpha = 0.48f),
                    1f to Color.Black.copy(alpha = 0.86f),
                ),
            ),
        )
        Column(
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .fillMaxWidth()
                .padding(horizontal = 24.dp, vertical = 52.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            artwork.logoUrl?.let { logo ->
                Box(
                    modifier = Modifier
                        .widthIn(max = 360.dp)
                        .fillMaxWidth()
                        .height(110.dp),
                ) {
                    FallbackArtwork(
                        urls = listOf(logo),
                        contentDescription = null,
                        modifier = Modifier.fillMaxSize(),
                        maxDecodePx = 720,
                        decodeScale = coil3.size.Scale.FIT,
                        contentScale = ContentScale.Fit,
                        crossfade = false,
                    )
                }
            }
            // Text is the sole accessible title. The poster and logo are decorative by design.
            Text(
                text = artwork.title,
                color = Color.White,
                style = VortXTheme.type.screenTitle,
                textAlign = TextAlign.Center,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

/**
 * Observe the parent's pure startup deadline. It polls only while the same keyed window remains pending;
 * evidence, owner loss, error/exit/PiP admission, or the 12-second deadline permanently retires it.
 */
@Composable
internal fun rememberStartupCoverWindow(
    window: StartupCoverWindow,
    ownerRevision: Long,
    evidence: PlaybackStartupEvidence,
    allowed: Boolean = true,
): Boolean {
    val ownerCurrent = ContinueWatchingOwnerGate.serialized { currentRevision ->
        currentRevision == ownerRevision
    }
    val eligibleNow = allowed && evidence == PlaybackStartupEvidence.AWAITING && ownerCurrent
    val immediatelyPending = window.pending(
        nowMs = SystemClock.elapsedRealtime(),
        evidence = evidence,
        ownerCurrent = ownerCurrent,
        allowed = allowed,
    )
    var pending by remember(window, ownerRevision) { mutableStateOf(immediatelyPending) }

    LaunchedEffect(window, ownerRevision, evidence, allowed) {
        if (!eligibleNow || !immediatelyPending) {
            pending = false
            return@LaunchedEffect
        }
        while (currentCoroutineContext().isActive && pending) {
            val currentOwner = ContinueWatchingOwnerGate.serialized { currentRevision ->
                currentRevision == ownerRevision
            }
            currentCoroutineContext().ensureActive()
            val stillPending = window.pending(
                nowMs = SystemClock.elapsedRealtime(),
                evidence = evidence,
                ownerCurrent = currentOwner,
                allowed = allowed,
            )
            pending = stillPending
            if (!stillPending) break
            delay(STARTUP_WINDOW_POLL_MS)
        }
    }

    // `immediatelyPending` invokes the pure window during composition so an evidence/error/owner change
    // hides the layer in that same frame; `pending` keeps a retired window from rearming on later changes.
    return eligibleNow && immediatelyPending && pending
}
