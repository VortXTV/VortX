package com.vortx.android.ui.components

import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.vortx.android.account.AccountSyncGate
import com.vortx.android.integrations.ScrobbleService
import com.vortx.android.integrations.TraktAuth
import com.vortx.android.integrations.TraktManualCheckInPolicy
import com.vortx.android.model.Episode
import com.vortx.android.model.MetaDetail
import com.vortx.android.profile.ProfileStore
import com.vortx.android.ui.tv.TvFilterChip
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import org.json.JSONObject

/** Optional manual check-in for watching somewhere VortX cannot observe. This never writes watch history. */
@Composable
internal fun TraktManualCheckInAction(
    detail: MetaDetail,
    primaryEpisode: Episode?,
    resolving: Boolean,
    tv: Boolean,
    modifier: Modifier = Modifier,
) {
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    remember(context) { ScrobbleService.init(context.applicationContext); Unit }
    val profile by ProfileStore.shared.activeProfile.collectAsStateWithLifecycle()
    val profileId = profile?.id ?: ProfileStore.shared.activeProfileId
    val sessionBoundary by TraktAuth.sessionBoundary.collectAsStateWithLifecycle()
    val epoch = TraktAuth.currentSessionEpoch
    val target = TraktManualCheckInPolicy.target(detail, primaryEpisode)
    val owner = target?.let { TraktManualCheckInPolicy.Owner(epoch ?: -1L, profileId, detail.id, it) }
    val currentOwner by rememberUpdatedState(owner)
    val offered = TraktManualCheckInPolicy.canOffer(
        configured = TraktAuth.isConfigured,
        optedIn = ScrobbleService.isToggleOn(ScrobbleService.KEY_TRAKT_CHECKIN, false),
        ownerProfile = AccountSyncGate.activeProfileSyncsAccount(),
        connected = TraktAuth.isSignedIn && epoch != null,
        target = target,
    )
    var state by remember(owner, sessionBoundary) { mutableStateOf(TraktManualCheckInPolicy.RequestState.IDLE) }
    var message by remember(owner, sessionBoundary) { mutableStateOf<String?>(null) }
    if (!offered || owner == null) return

    val pending = state == TraktManualCheckInPolicy.RequestState.IN_FLIGHT || resolving
    val label = when (state) {
        TraktManualCheckInPolicy.RequestState.SUCCESS -> "Checked in"
        TraktManualCheckInPolicy.RequestState.CONFLICT -> "Check-in conflict"
        TraktManualCheckInPolicy.RequestState.FAILURE -> "Check-in failed"
        else -> "I'm watching this"
    }
    val submit: (Boolean) -> Unit = { replaceActive ->
        if (currentOwner == owner && AccountSyncGate.activeProfileSyncsAccount() && !resolving) {
            val next = TraktManualCheckInPolicy.begin(state, owner)
            if (next != null) {
                state = next
                message = null
                val requestOwner = owner
                scope.launch {
                    val (method, body) = payload(requestOwner.target)
                    val response = try {
                        if (replaceActive) {
                            val cleared = TraktAuth.sessionBoundRequest(
                                "DELETE", "/checkin", requestOwner.accountEpoch,
                            )
                            if ((cleared?.isSuccess == true || cleared?.status == 404) && currentOwner == requestOwner &&
                                AccountSyncGate.activeProfileSyncsAccount()) {
                                TraktAuth.sessionBoundRequest(method, "/checkin", requestOwner.accountEpoch, body)
                            } else cleared
                        } else {
                            TraktAuth.sessionBoundRequest(method, "/checkin", requestOwner.accountEpoch, body)
                        }
                    } catch (cancelled: CancellationException) {
                        throw cancelled
                    } catch (_: Exception) {
                        null
                    } finally {
                        TraktManualCheckInPolicy.finish(requestOwner)
                    }
                    val result = when {
                        currentOwner != requestOwner -> null
                        response == null -> TraktManualCheckInPolicy.RequestState.FAILURE
                        response.status in 200..299 -> TraktManualCheckInPolicy.RequestState.SUCCESS
                        response.status == 409 -> TraktManualCheckInPolicy.RequestState.CONFLICT
                        else -> TraktManualCheckInPolicy.RequestState.FAILURE
                    }
                    if (result != null && currentOwner == requestOwner) {
                        state = TraktManualCheckInPolicy.completion(currentOwner!!, requestOwner, result)
                            ?: TraktManualCheckInPolicy.RequestState.IDLE
                        message = when (result) {
                            TraktManualCheckInPolicy.RequestState.SUCCESS -> "Trakt accepted the check-in."
                            TraktManualCheckInPolicy.RequestState.CONFLICT -> "Trakt already has another active check-in. Nothing was replaced."
                            else -> response?.let { "Trakt could not check in (HTTP ${it.status})." }
                                ?: "Trakt session changed or could not be refreshed. Reconnect or try again."
                        }
                    }
                }
            }
        }
    }
    val action: () -> Unit = { submit(false) }
    if (tv) {
        TvFilterChip(label = if (pending) "Checking in…" else label, selected = state == TraktManualCheckInPolicy.RequestState.SUCCESS,
            onClick = action, modifier = modifier, enabled = !pending,
            stateDescription = "Check in to Trakt for ${detail.name}")
    } else {
        Chip(label = if (pending) "Checking in…" else label,
            selected = state == TraktManualCheckInPolicy.RequestState.SUCCESS,
            enabled = !pending,
            leadingIcon = null,
            onClick = action,
            modifier = modifier,
            stateDescription = "Check in to Trakt for ${detail.name}")
    }
    message?.let { text ->
        AlertDialog(
            onDismissRequest = { message = null },
            title = { Text(when (state) {
                TraktManualCheckInPolicy.RequestState.CONFLICT -> "Already watching something"
                TraktManualCheckInPolicy.RequestState.FAILURE -> "Could not check in"
                else -> "Trakt check-in"
            }) },
            text = { Text(text) },
            confirmButton = {
                if (state == TraktManualCheckInPolicy.RequestState.CONFLICT) {
                    TextButton(onClick = { message = null; submit(true) }) { Text("Check in here") }
                } else {
                    TextButton(onClick = { message = null }) { Text("OK") }
                }
            },
            dismissButton = if (state == TraktManualCheckInPolicy.RequestState.CONFLICT) {
                { TextButton(onClick = { message = null }) { Text("Keep it") } }
            } else null,
        )
    }
}

private fun payload(target: TraktManualCheckInPolicy.Target): Pair<String, String> = when (target) {
    is TraktManualCheckInPolicy.Target.Movie -> "POST" to JSONObject().put(
        "movie", JSONObject().put("ids", ids(target.id)),
    ).toString()
    is TraktManualCheckInPolicy.Target.EpisodeTarget -> "POST" to JSONObject()
        .put("show", JSONObject().put("ids", ids(target.id)))
        .put("episode", JSONObject().put("season", target.season).put("number", target.episode))
        .toString()
}

private fun ids(id: String): JSONObject = JSONObject().apply {
    if (id.startsWith("tt")) put("imdb", id) else put("tmdb", id.removePrefix("tmdb:").toLong())
}
