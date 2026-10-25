package com.vortx.android.ui.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.vortx.android.player.queue.PlaybackQueueEntry
import com.vortx.android.player.queue.PlaybackQueueState
import com.vortx.android.player.queue.PlaybackQueuePresentation
import com.vortx.android.data.CatalogRepository
import com.vortx.android.data.ContinueWatchingOwner
import com.vortx.android.model.Catalog
import com.vortx.android.profile.UserProfile
import com.vortx.android.ui.theme.VortXTheme
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlin.coroutines.coroutineContext

private data class QueuePresentationSnapshot(
    val source: PlaybackQueueState,
    val owner: ContinueWatchingOwner,
    val profile: UserProfile,
    val policyEpoch: Long,
    val visible: PlaybackQueueState,
)

/** Up to 100 metadata rows, admitted off the UI dispatcher and published only to their exact snapshot. */
@Composable
internal fun rememberPlaybackQueuePresentation(
    source: PlaybackQueueState?,
    repo: CatalogRepository,
    owner: ContinueWatchingOwner?,
    profile: UserProfile?,
    policyEpoch: Long,
): PlaybackQueueState? {
    var published by remember(repo) { mutableStateOf<QueuePresentationSnapshot?>(null) }
    LaunchedEffect(repo, source, owner, profile, policyEpoch) {
        if (source == null || owner == null || profile == null || source.owner != owner || profile.id != owner.profileId) {
            published = null
            return@LaunchedEffect
        }
        val visible = withContext(Dispatchers.Default) {
            PlaybackQueuePresentation.project(source, owner, repo::continueWatchingOwner) { items, expected ->
                repo.admitClientHomeRows(listOf(Catalog("playback-queue", "Playback queue", items)), expected)
                    .map { rows -> rows.flatMap { it.items } }
            }
        }
        coroutineContext.ensureActive()
        published = QueuePresentationSnapshot(source, owner, profile, policyEpoch, visible)
    }
    // A changed policy/roster/queue invalidates the old visible value synchronously, before the new
    // coroutine is scheduled. Recomposition cannot flash an earlier profile's title while admission runs.
    return published?.takeIf {
        it.source === source && it.owner == owner && it.profile == profile && it.policyEpoch == policyEpoch
    }?.visible
}

/** Uses the existing shared Chip language; no private player-control layout or extra overlay height. */
@Composable
internal fun PlaybackQueueActions(
    count: Int,
    enabled: Boolean,
    onAdd: () -> Unit,
    onPlayNext: () -> Unit,
    onShow: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(modifier = modifier, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Chip("Add to queue", false, onAdd, enabled = enabled && count < 100)
            Chip("Play next", false, onPlayNext, enabled = enabled && count < 100)
        }
        Chip("Queue ($count)", false, onShow)
    }
}

/** Bounded upcoming list. Android Dialog owns touch/Back/D-pad modality; item identity is the queue UUID. */
@Composable
internal fun PlaybackQueueSheet(
    state: PlaybackQueueState,
    onDismiss: () -> Unit,
    onPlay: (PlaybackQueueEntry) -> Unit,
    onMove: (String, Int) -> Unit,
    onRemove: (String) -> Unit,
    onRetry: (() -> Unit)? = null,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Playback queue (${state.entries.size})") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                state.error?.let { Text(it, color = VortXTheme.colors.textSecondary) }
                if (!state.ready && state.error == null) Text("Loading saved queue…")
                if (state.ready && state.entries.isEmpty()) {
                    Text("Add movies or episodes from their details. They’ll play in order when the current title ends.")
                }
                if (!state.ready && state.error != null && onRetry != null) {
                    TextButton(onClick = onRetry) { Text("Retry saved queue") }
                }
                LazyColumn(
                    modifier = Modifier.fillMaxWidth().heightIn(max = 420.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    itemsIndexed(state.entries, key = { _, entry -> entry.id }) { index, entry ->
                        Column(modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
                            Text("${index + 1}. ${entry.item.name}", fontWeight = FontWeight.SemiBold)
                            entry.item.preferredEpisode?.let { hint ->
                                Text("Season ${hint.season} · Episode ${hint.episode}", color = VortXTheme.colors.textSecondary)
                            }
                            Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                                TextButton(enabled = state.ready, onClick = { onPlay(entry) }) { Text("Play") }
                                TextButton(
                                    enabled = state.ready,
                                    modifier = Modifier.semantics { contentDescription = "Remove ${entry.item.name} from queue" },
                                    onClick = { onRemove(entry.id) },
                                ) { Text("Remove") }
                            }
                            // Two short rows fit a narrow phone dialog without clipping its actions.
                            Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                                TextButton(
                                    enabled = state.ready && index > 0,
                                    modifier = Modifier.semantics { contentDescription = "Move ${entry.item.name} up" },
                                    onClick = { onMove(entry.id, -1) },
                                ) { Text("↑") }
                                TextButton(
                                    enabled = state.ready && index < state.entries.lastIndex,
                                    modifier = Modifier.semantics { contentDescription = "Move ${entry.item.name} down" },
                                    onClick = { onMove(entry.id, 1) },
                                ) { Text("↓") }
                            }
                        }
                    }
                }
                Text("Choose Play to start an item, or move titles to change what plays next.", color = VortXTheme.colors.textSecondary)
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Done") } },
    )
}
