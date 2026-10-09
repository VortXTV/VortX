package com.vortx.android.ui.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.vortx.android.integrations.ExternalIntegrationOwner
import com.vortx.android.integrations.PersonalRatings
import com.vortx.android.integrations.RatingProvider
import com.vortx.android.integrations.RatingTitle
import com.vortx.android.integrations.SIMKLAuth
import com.vortx.android.integrations.ScrobbleService
import com.vortx.android.integrations.TraktAuth
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaDetail
import com.vortx.android.profile.ProfileStore
import com.vortx.android.ui.tv.TvFilterChip
import kotlinx.coroutines.launch

/** Shared touch/TV detail control. Title-level ratings never depend on the chosen episode or playback. */
@Composable
@OptIn(ExperimentalLayoutApi::class)
internal fun PersonalRatingActions(detail: MetaDetail, tv: Boolean, modifier: Modifier = Modifier) {
    if (detail.type != MediaType.MOVIE && detail.type != MediaType.SERIES) return
    val title = RatingTitle.fromId(detail.id, detail.type == MediaType.SERIES) ?: return
    val context = LocalContext.current
    remember(context) { ScrobbleService.init(context.applicationContext); Unit }
    val profile by ProfileStore.shared.activeProfile.collectAsStateWithLifecycle()
    val trakt by TraktAuth.sessionBoundary.collectAsStateWithLifecycle()
    val simkl by SIMKLAuth.sessionBoundary.collectAsStateWithLifecycle()
    val preferences by ScrobbleService.toggleChanges.collectAsStateWithLifecycle()
    val controller = PersonalRatings.controller
    LaunchedEffect(profile, trakt, simkl, preferences) { controller.reconcile() }
    FlowRow(modifier = modifier, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        for (provider in RatingProvider.entries) {
            val owner = remember(profile, trakt, simkl, preferences, provider) { controller.owner(provider) }
            if (owner != null) PersonalRatingAction(owner, title, tv)
        }
    }
}

@Composable
private fun PersonalRatingAction(owner: ExternalIntegrationOwner, title: RatingTitle, tv: Boolean) {
    val controller = PersonalRatings.controller
    val revision by controller.revision.collectAsStateWithLifecycle()
    val state = remember(owner, title, revision) { controller.state(owner, title) }
    val scope = rememberCoroutineScope()
    var picking by remember(owner, title) { mutableStateOf(false) }
    LaunchedEffect(owner) { controller.refresh(owner) }
    val label = state.value?.let { "${owner.provider.label} · $it/10" } ?: "Rate on ${owner.provider.label}"
    if (tv) {
        TvFilterChip(label = label, selected = state.value != null, enabled = !state.busy,
            onClick = { picking = true }, stateDescription = "Your rating on ${owner.provider.label}")
    } else {
        Chip(label = label, selected = state.value != null, enabled = !state.busy, leadingIcon = null,
            onClick = { picking = true }, stateDescription = "Your rating on ${owner.provider.label}")
    }
    if (picking) AlertDialog(
        onDismissRequest = { picking = false },
        title = { Text("Your ${owner.provider.label} rating") },
        text = {
            Column(Modifier.heightIn(max = 420.dp).verticalScroll(rememberScrollState())) {
                if (owner.provider == RatingProvider.SIMKL) Text(
                    "SIMKL can add a newly rated movie to seen history, or a show to Watching.")
                if (state.busy) Text("Saving…")
                state.message?.let { Text(it) }
                for (value in 10 downTo 1) TextButton(enabled = !state.busy, onClick = {
                    scope.launch { controller.set(owner, title, value) }
                }) { Text(if (state.value == value) "$value/10 · your rating" else "$value/10") }
                if (state.value != null) TextButton(enabled = !state.busy, onClick = {
                    scope.launch { controller.set(owner, title, null) }
                }) { Text("Remove rating") }
            }
        },
        confirmButton = { TextButton(onClick = { picking = false }) { Text("Done") } },
    )
}
