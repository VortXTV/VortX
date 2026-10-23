package com.vortx.android.ui.network

import androidx.compose.runtime.Composable
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import com.vortx.android.model.Playable
import com.vortx.android.network.NetworkShare
import com.vortx.android.network.NetworkShareEntry
import com.vortx.android.network.NetworkShareException
import com.vortx.android.network.NetworkShareStore
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

/**
 * The folder browser behind Library > Network shares on phone and TV: a stack of opened folders, the current
 * folder's contents, and the Playable for a video (carrying the share's login only for files inside it).
 */
@Stable
class NetworkShareBrowserState internal constructor(val store: NetworkShareStore, private val scope: CoroutineScope) {
    data class Level(val share: NetworkShare, val folder: String?, val title: String)

    var stack by mutableStateOf<List<Level>>(emptyList())
        private set
    var entries by mutableStateOf<List<NetworkShareEntry>?>(null)
        private set
    var error by mutableStateOf<String?>(null)
        private set
    /** Why the last video could not start (for example, the share redirected it elsewhere). */
    var playError by mutableStateOf<String?>(null)
        private set
    private var job: Job? = null

    val current: Level? get() = stack.lastOrNull()

    fun open(share: NetworkShare) = push(Level(share, null, share.name))

    fun enter(entry: NetworkShareEntry) {
        val level = current ?: return
        push(Level(level.share, entry.url, entry.name))
    }

    /** Up one folder; false at the share list, so the caller leaves the screen. */
    fun back(): Boolean {
        if (stack.isEmpty()) return false
        stack = stack.dropLast(1)
        reload()
        return true
    }

    fun reload() {
        job?.cancel()
        entries = null
        error = null
        playError = null
        val level = current ?: return
        job = scope.launch {
            try {
                entries = store.list(level.share, level.folder)
            } catch (cancel: CancellationException) {
                throw cancel
            } catch (failure: NetworkShareException) {
                error = failure.reason.message
            } catch (_: Exception) {
                error = NetworkShareException.Reason.UNREACHABLE.message
            }
        }
    }

    /**
     * Resolves [entry]'s final address first (redirects only within the share), then hands the player a Playable
     * with the login attached only for that address. A refusal shows in [playError] instead.
     */
    fun play(entry: NetworkShareEntry, onPlay: (Playable) -> Unit) {
        val level = current ?: return
        playError = null
        scope.launch {
            try {
                val (url, headers) = store.playbackTarget(level.share, entry.url)
                onPlay(Playable(url = url, title = entry.name, headers = headers))
            } catch (cancel: CancellationException) {
                throw cancel
            } catch (failure: NetworkShareException) {
                playError = failure.reason.message
            } catch (_: Exception) {
                playError = NetworkShareException.Reason.UNREACHABLE.message
            }
        }
    }

    private fun push(level: Level) {
        stack = stack + level
        reload()
    }
}

@Composable
fun rememberNetworkShareBrowser(): NetworkShareBrowserState {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    return remember { NetworkShareBrowserState(NetworkShareStore.shared(context), scope) }
}

/** Adds a share and reports the viewer-facing failure, or null on success. */
suspend fun NetworkShareStore.addReportingError(name: String, address: String, username: String, password: String): String? =
    try {
        add(name, address, username, password)
        null
    } catch (cancel: CancellationException) {
        throw cancel
    } catch (failure: NetworkShareException) {
        failure.reason.message
    } catch (_: Exception) {
        NetworkShareException.Reason.UNREACHABLE.message
    }

fun NetworkShareEntry.sizeLabel(): String? = size?.let { bytes ->
    val units = listOf("B", "KB", "MB", "GB", "TB")
    var value = bytes.toDouble()
    var unit = 0
    while (value >= 1000 && unit < units.lastIndex) { value /= 1000; unit++ }
    if (unit == 0) "$bytes B" else String.format(java.util.Locale.ROOT, "%.1f %s", value, units[unit])
}
