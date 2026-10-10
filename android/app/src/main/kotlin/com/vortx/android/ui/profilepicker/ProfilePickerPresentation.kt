package com.vortx.android.ui.profilepicker

import android.content.Context
import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.FiniteAnimationSpec
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.collectAsState
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import coil3.ImageLoader
import coil3.SingletonImageLoader
import coil3.request.ImageRequest
import coil3.request.SuccessResult
import com.vortx.android.ui.theme.VortXMotion
import com.vortx.android.ui.theme.VortXTheme
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.coroutineScope
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder

/**
 * The bounded, public artwork record used before a profile is selected. It intentionally contains no
 * profile, account, history, add-on, or playback state: the launch picker must not reveal the previous
 * viewer's private data while it is still asking who is watching.
 */
data class ProfilePickerArtworkCandidate(
    val id: String,
    val name: String,
    val artworkURLs: List<String>,
) {
    val cacheKey: String get() = "$id|${artworkURLs.joinToString("|")}"
}

/** Viewport policy shared by phone, tablet, and TV picker compositions. */
data class ProfilePickerLayoutPolicy(
    val widthDp: Float,
    val largeText: Boolean,
    val isPhone: Boolean = false,
    val isTv: Boolean = false,
) {
    val isWide: Boolean get() = widthDp >= WIDE_BREAKPOINT_DP
    val horizontalInsetDp: Float get() = if (isWide) WIDE_INSET_DP else COMPACT_INSET_DP
    val spacingDp: Float get() = if (isWide) WIDE_SPACING_DP else COMPACT_SPACING_DP

    /** Number of columns that fit without phantom empty tracks. */
    val columns: Int
        get() = when {
            isTv -> {
                val available = maxOf(0f, widthDp - horizontalInsetDp * 2f)
                val fit = ((available + spacingDp) / (TV_TILE_WIDTH_DP + spacingDp)).toInt()
                maxOf(1, minOf(if (largeText) 4 else 6, fit))
            }
            largeText -> if (isWide) 4 else 2
            widthDp < 350f -> 2
            widthDp < 700f -> 3
            widthDp < 1000f -> 4
            else -> 6
        }

    /** Avatar face side in dp; TV retains its 120dp 10-foot face while the card remains 200dp wide. */
    val avatarSideDp: Float
        get() {
            if (isTv) return TV_AVATAR_DP
            val available = minOf(widthDp, MAX_GRID_WIDTH_DP) - horizontalInsetDp * 2f - 16f -
                spacingDp * (columns - 1)
            return maxOf(if (isWide) MIN_WIDE_AVATAR_DP else MIN_COMPACT_AVATAR_DP,
                minOf(if (isWide) MAX_WIDE_AVATAR_DP else MAX_COMPACT_AVATAR_DP, available / columns))
        }

    /** Width of a focusable TV tile. Phone/tablet tiles stay square around their avatar face. */
    val tileWidthDp: Float get() = if (isTv) TV_TILE_WIDTH_DP else avatarSideDp

    /**
     * Populated rows only. In particular, a final row with two items in a six-column layout has two
     * actual children and is centered as two children; it is never padded with empty tracks.
     */
    fun rows(itemCount: Int): List<IntRange> {
        if (itemCount <= 0) return emptyList()
        return (0 until itemCount step columns).map { start ->
            start until minOf(start + columns, itemCount)
        }
    }

    companion object {
        private const val WIDE_BREAKPOINT_DP = 700f
        private const val MAX_GRID_WIDTH_DP = 1100f
        private const val COMPACT_INSET_DP = 24f
        private const val WIDE_INSET_DP = 48f
        private const val COMPACT_SPACING_DP = 18f
        private const val WIDE_SPACING_DP = 28f
        private const val MIN_COMPACT_AVATAR_DP = 44f
        private const val MIN_WIDE_AVATAR_DP = 64f
        private const val MAX_COMPACT_AVATAR_DP = 110f
        private const val MAX_WIDE_AVATAR_DP = 160f
        private const val TV_TILE_WIDTH_DP = 200f
        private const val TV_AVATAR_DP = 120f
    }
}

/**
 * Owns the one bounded picker catalog and its one rotation clock. The production UI supplies public
 * Cinemeta fetching and Coil loading; tests can inject both, so cancellation, negative caching, and the
 * selected/next prewarm contract stay executable without a device or network.
 */
class ProfilePickerArtworkController(
    private val fetchCandidates: suspend () -> List<ProfilePickerArtworkCandidate>,
    private val loadArtwork: suspend (String) -> Boolean,
    private val rotationIntervalMillis: Long = ROTATION_INTERVAL_MILLIS,
) {
    private val _movie = MutableStateFlow<ProfilePickerArtworkCandidate?>(null)
    val movie: StateFlow<ProfilePickerArtworkCandidate?> = _movie.asStateFlow()

    private var didAttemptCatalog = false
    private var candidates: List<ProfilePickerArtworkCandidate> = emptyList()
    private var currentIndex = -1
    private val readyIDs = mutableSetOf<String>()
    private val unavailableIDs = mutableSetOf<String>()

    /** Run until the picker leaves composition. The caller's cancellation is deliberately allowed through. */
    suspend fun run(reducedMotion: Boolean) = coroutineScope {
        ensureCandidates()
        if (_movie.value == null) showInitialCandidate()
        if (_movie.value == null) return@coroutineScope
        if (candidates.size < 2) return@coroutineScope

        // Keep the selected candidate and the next candidate warm. A single child owns this prewarm; there
        // is no second rotation clock and no unbounded queue of catalog/artwork requests.
        var prewarm: Job? = launch { preload(candidates[nextIndex(currentIndex)]) }
        if (reducedMotion) {
            prewarm.join()
            return@coroutineScope
        }

        while (currentCoroutineContext().isActive) {
            delay(rotationIntervalMillis)
            prewarm?.join()
            prewarm = null
            val next = nextReadyIndex(currentIndex) ?: break
            currentIndex = next
            _movie.value = candidates[next]
            prewarm = launch { preload(candidates[nextIndex(next)]) }
        }
    }

    /** Test-visible evidence that cancellation never turns a candidate into a persistent art failure. */
    internal fun unavailableCandidateIDs(): Set<String> = unavailableIDs.toSet()

    private suspend fun ensureCandidates() {
        if (didAttemptCatalog) return
        // Mark the attempt only after a successful, non-cancelled fetch. If the picker disappears while
        // JSON is in flight, the next visible session may retry instead of inheriting a false failure.
        val fetched = try {
            fetchCandidates()
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Throwable) {
            // A public catalog outage is non-blocking for profile selection. Keep the controller in an
            // empty, completed state instead of taking the launch picker down with an engine/network error.
            emptyList()
        }
        currentCoroutineContext().ensureActive()
        didAttemptCatalog = true
        candidates = fetched.take(CANDIDATE_LIMIT)
    }

    private suspend fun showInitialCandidate() {
        for (index in candidates.indices) {
            currentCoroutineContext().ensureActive()
            if (preload(candidates[index])) {
                currentIndex = index
                _movie.value = candidates[index]
                return
            }
        }
    }

    private suspend fun nextReadyIndex(from: Int): Int? {
        if (from < 0 || candidates.isEmpty()) return null
        for (offset in 1 until candidates.size) {
            currentCoroutineContext().ensureActive()
            val index = (from + offset) % candidates.size
            if (preload(candidates[index])) return index
        }
        return null
    }

    private fun nextIndex(index: Int): Int = (index + 1) % candidates.size

    private suspend fun preload(candidate: ProfilePickerArtworkCandidate): Boolean {
        if (candidate.id in readyIDs) return true
        if (candidate.id in unavailableIDs) return false
        for (url in candidate.artworkURLs) {
            currentCoroutineContext().ensureActive()
            val loaded = try {
                loadArtwork(url)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Throwable) {
                false
            }
            currentCoroutineContext().ensureActive()
            if (loaded) {
                readyIDs += candidate.id
                return true
            }
        }
        // Only a fully attempted, non-cancelled candidate is negatively cached. CancellationException
        // from the loader reaches the caller above and never reaches this line.
        unavailableIDs += candidate.id
        return false
    }

    private companion object {
        const val ROTATION_INTERVAL_MILLIS = 5_000L
    }
}

/** Read the Android equivalent of Apple's scenePhase so backgrounded pickers stop catalog/artwork work. */
@Composable
internal fun rememberProfilePickerLifecycleActive(): Boolean {
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    var active by remember(lifecycle) {
        mutableStateOf(lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED))
    }
    DisposableEffect(lifecycle) {
        val observer = LifecycleEventObserver { _, _ ->
            active = lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)
        }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer) }
    }
    return active
}

/** Shared owner wiring: one controller and one bounded catalog per picker composition. */
@Composable
internal fun rememberProfilePickerMovie(
    visible: Boolean,
    reducedMotion: Boolean,
): ProfilePickerArtworkCandidate? {
    val context = LocalContext.current.applicationContext
    val imageLoader = remember(context) { SingletonImageLoader.get(context) }
    val controller = remember(context, imageLoader) {
        ProfilePickerArtworkController(
            fetchCandidates = ::fetchPublicFamilyMovies,
            loadArtwork = { url -> loadPickerArtwork(context, imageLoader, url) },
        )
    }
    val movie by controller.movie.collectAsState()
    LaunchedEffect(controller, visible, reducedMotion) {
        if (visible) controller.run(reducedMotion)
    }
    return movie
}

/** Full-bleed artwork and the black fades that keep picker copy readable on any movie still. */
@Composable
internal fun ProfilePickerCinematicBackdrop(
    movie: ProfilePickerArtworkCandidate?,
    reducedMotion: Boolean,
    modifier: Modifier = Modifier,
) {
    val fade: FiniteAnimationSpec<Float> = if (reducedMotion) snap()
    else tween(durationMillis = ARTWORK_FADE_MILLIS, easing = VortXMotion.easing)
    Box(modifier.fillMaxSize().background(Color.Black)) {
        Crossfade(targetState = movie, animationSpec = fade, label = "profilePickerArtwork") { current ->
            if (current == null) {
                Box(Modifier.fillMaxSize().background(VortXTheme.colors.canvas))
            } else {
                com.vortx.android.ui.components.FallbackArtwork(
                    urls = current.artworkURLs,
                    contentDescription = null,
                    modifier = Modifier.fillMaxSize(),
                    placeholder = { Box(Modifier.fillMaxSize().background(VortXTheme.colors.canvas)) },
                )
            }
        }
        Box(
            Modifier.fillMaxSize().background(
                Brush.horizontalGradient(
                    0f to Color.Black.copy(alpha = 0.38f),
                    0.55f to Color.Transparent,
                ),
            ),
        )
        Box(
            Modifier.fillMaxSize().background(
                Brush.verticalGradient(
                    0f to Color.Black.copy(alpha = 0.16f),
                    0.38f to Color.Transparent,
                    0.70f to Color.Black.copy(alpha = 0.72f),
                    1f to Color.Black.copy(alpha = 0.96f),
                ),
            ),
        )
    }
}

private suspend fun fetchPublicFamilyMovies(): List<ProfilePickerArtworkCandidate> = withContext(Dispatchers.IO) {
    var connection: HttpURLConnection? = null
    try {
        val genre = URLEncoder.encode("Family", "UTF-8").replace("+", "%20")
        connection = (URL("https://v3-cinemeta.strem.io/catalog/movie/top/genre=$genre.json").openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            connectTimeout = CATALOG_TIMEOUT_MILLIS
            readTimeout = CATALOG_TIMEOUT_MILLIS
            useCaches = true
            setRequestProperty("accept", "application/json")
        }
        if (connection.responseCode != HttpURLConnection.HTTP_OK) return@withContext emptyList()
        val text = connection.inputStream.use(::readBoundedUtf8) ?: return@withContext emptyList()
        val metas = runCatching { JSONObject(text).optJSONArray("metas") }.getOrNull() ?: return@withContext emptyList()
        val seen = mutableSetOf<String>()
        buildList {
            for (index in 0 until metas.length()) {
                val row = metas.optJSONObject(index) ?: continue
                if (!row.optString("type").equals("movie", ignoreCase = true)) continue
                val id = row.optString("id").takeIf { it.startsWith("tt") } ?: continue
                val name = row.optString("name").trim().takeIf(String::isNotEmpty) ?: continue
                val poster = row.optString("poster").trim().takeIf(::isHttpsUrl) ?: continue
                if (!seen.add(id)) continue
                val background = row.optString("background").trim().takeIf(::isHttpsUrl)
                    ?: "https://images.metahub.space/background/big/$id/img"
                add(ProfilePickerArtworkCandidate(id, name, listOf(background, poster).distinct()))
            }
        }.shuffled().take(CANDIDATE_LIMIT)
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (_: IOException) {
        emptyList()
    } catch (_: RuntimeException) {
        emptyList()
    } finally {
        connection?.disconnect()
    }
}

private suspend fun loadPickerArtwork(context: Context, imageLoader: ImageLoader, url: String): Boolean =
    withContext(Dispatchers.IO) {
        try {
            val request = ImageRequest.Builder(context)
                .data(url)
                .size(1920, 1920)
                .build()
            imageLoader.execute(request) is SuccessResult
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Throwable) {
            false
        }
    }

private fun isHttpsUrl(value: String): Boolean =
    runCatching { URL(value).protocol.equals("https", ignoreCase = true) && URL(value).host.isNotBlank() }
        .getOrDefault(false)

private fun readBoundedUtf8(input: InputStream): String? {
    val output = ByteArrayOutputStream()
    val buffer = ByteArray(8 * 1024)
    var total = 0
    while (true) {
        val count = input.read(buffer)
        if (count <= 0) break
        total += count
        if (total > CATALOG_MAX_BYTES) return null
        output.write(buffer, 0, count)
    }
    return output.toString(Charsets.UTF_8.name())
}

private const val ARTWORK_FADE_MILLIS = 800
private const val CATALOG_TIMEOUT_MILLIS = 12_000
private const val CATALOG_MAX_BYTES = 512 * 1024
private const val CANDIDATE_LIMIT = 12
