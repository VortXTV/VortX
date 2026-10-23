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
    private val readCachedCandidates: suspend () -> List<ProfilePickerArtworkCandidate> = { emptyList() },
    private val loadCachedArtwork: suspend (String) -> Boolean = { false },
    private val writeCachedCandidates: suspend (List<ProfilePickerArtworkCandidate>) -> Unit = {},
) {
    private val _movie = MutableStateFlow<ProfilePickerArtworkCandidate?>(null)
    val movie: StateFlow<ProfilePickerArtworkCandidate?> = _movie.asStateFlow()

    private var didAttemptCache = false
    private var didAttemptCatalog = false
    private var candidates: List<ProfilePickerArtworkCandidate> = emptyList()
    private var currentIndex = -1
    private val readyURLs = mutableMapOf<String, String>()
    private val unavailableIDs = mutableSetOf<String>()

    /** Cached public art is published before any live catalog await; selection never waits for either. */
    suspend fun run(reducedMotion: Boolean) = coroutineScope {
        seedFromCache()
        ensureCandidates()
        if (_movie.value == null) showInitialCandidate()
        if (_movie.value == null || candidates.size < 2) return@coroutineScope

        var prewarm: Job? = launch { preload(candidates[nextIndex(currentIndex)]) }
        if (reducedMotion) {
            prewarm?.join()
            return@coroutineScope
        }
        while (currentCoroutineContext().isActive) {
            delay(rotationIntervalMillis)
            prewarm?.join()
            prewarm = null
            val next = nextReadyIndex(currentIndex) ?: break
            publishReady(next)
            prewarm = launch { preload(candidates[nextIndex(next)]) }
        }
    }

    internal fun unavailableCandidateIDs(): Set<String> = unavailableIDs.toSet()

    /** Cache probes never use HTTP and a missing/purged image is not a persistent candidate failure. */
    private suspend fun seedFromCache() {
        if (didAttemptCache || _movie.value != null) return
        val cached = try { readCachedCandidates().take(CANDIDATE_LIMIT) }
            catch (cancel: CancellationException) { throw cancel }
            catch (_: Exception) { emptyList() }
        currentCoroutineContext().ensureActive()
        candidates = cached
        for ((index, candidate) in cached.withIndex()) {
            for (url in candidate.artworkURLs) {
                val loaded = try { loadCachedArtwork(url) }
                    catch (cancel: CancellationException) { throw cancel }
                    catch (_: Exception) { false }
                currentCoroutineContext().ensureActive()
                if (loaded) {
                    didAttemptCache = true
                    readyURLs[candidate.id] = url
                    currentIndex = index
                    _movie.value = candidate.copy(artworkURLs = listOf(url))
                    return
                }
            }
        }
        didAttemptCache = true
    }

    private suspend fun ensureCandidates() {
        if (didAttemptCatalog) return
        val fetched = try { fetchCandidates().take(CANDIDATE_LIMIT) }
            catch (cancel: CancellationException) { throw cancel }
            catch (_: Exception) { emptyList() }
        currentCoroutineContext().ensureActive()
        didAttemptCatalog = true
        // A failed refresh must not remove already visible public artwork or its title.
        if (fetched.isEmpty()) return
        val visible = _movie.value
        candidates = if (visible == null) fetched else
            (listOf(visible) + fetched.filterNot { it.id == visible.id }).take(CANDIDATE_LIMIT)
        currentIndex = visible?.let { current -> candidates.indexOfFirst { it.id == current.id } } ?: -1
        if (visible != null) persistReady()
    }

    private suspend fun showInitialCandidate() {
        for (index in candidates.indices) {
            currentCoroutineContext().ensureActive()
            if (preload(candidates[index]) != null) {
                publishReady(index)
                return
            }
        }
    }

    private suspend fun nextReadyIndex(from: Int): Int? {
        if (from < 0 || candidates.isEmpty()) return null
        for (offset in 1 until candidates.size) {
            currentCoroutineContext().ensureActive()
            val index = (from + offset) % candidates.size
            if (preload(candidates[index]) != null) return index
        }
        return null
    }

    private fun nextIndex(index: Int): Int = (index + 1) % candidates.size

    private suspend fun publishReady(index: Int) {
        currentCoroutineContext().ensureActive()
        val candidate = candidates[index]
        val winner = checkNotNull(readyURLs[candidate.id])
        currentIndex = index
        // The consumer receives the actual successful URL, not the already-failed prefix list.
        _movie.value = candidate.copy(artworkURLs = listOf(winner))
        persistReady()
    }

    private suspend fun persistReady() {
        val visible = _movie.value ?: return
        val snapshot = (listOf(visible) + candidates.filterNot { it.id == visible.id }.map { candidate ->
            readyURLs[candidate.id]?.let { candidate.copy(artworkURLs = listOf(it)) } ?: candidate
        }).take(CANDIDATE_LIMIT)
        try { writeCachedCandidates(snapshot) }
        catch (cancel: CancellationException) { throw cancel }
        catch (_: Exception) { /* A public presentation cache cannot block profile selection. */ }
        currentCoroutineContext().ensureActive()
    }

    private suspend fun preload(candidate: ProfilePickerArtworkCandidate): ProfilePickerArtworkCandidate? {
        readyURLs[candidate.id]?.let { return candidate.copy(artworkURLs = listOf(it)) }
        if (candidate.id in unavailableIDs) return null
        for (url in candidate.artworkURLs) {
            currentCoroutineContext().ensureActive()
            val loaded = try { loadArtwork(url) }
                catch (cancel: CancellationException) { throw cancel }
                catch (_: Exception) { false }
            currentCoroutineContext().ensureActive()
            if (loaded) {
                readyURLs[candidate.id] = url
                return candidate.copy(artworkURLs = listOf(url))
            }
        }
        unavailableIDs += candidate.id
        return null
    }

    private companion object {
        const val ROTATION_INTERVAL_MILLIS = 5_000L
    }
}

/** Public Family-catalog presentation only. Never stores profiles, accounts, history or add-on URLs. */
internal object ProfilePickerPublicArtworkCacheCodec {
    const val MAX_BYTES = 32 * 1024
    private const val SCHEMA = 1
    private const val SOURCE = "cinemeta-family-public-v1"
    private const val MAX_AGE_MS = 7L * 24 * 60 * 60 * 1000
    private val imageHosts = setOf("images.metahub.space", "image.tmdb.org", "m.media-amazon.com")

    private fun valid(candidate: ProfilePickerArtworkCandidate): ProfilePickerArtworkCandidate? {
        if (!Regex("tt[0-9]{5,12}").matches(candidate.id)) return null
        val name = candidate.name.trim()
        if (name.isEmpty() || name.length > 200 || name.any { it.code < 32 || it.code == 127 }) return null
        val urls = candidate.artworkURLs.distinct().filter(::isPublicArtworkURL).take(2)
        return if (urls.isEmpty()) null else candidate.copy(name = name, artworkURLs = urls)
    }

    private fun isPublicArtworkURL(url: String): Boolean {
        if (url.length !in 1..1024) return false
        val uri = try { java.net.URI(url) } catch (_: Exception) { return false }
        return uri.scheme.equals("https", ignoreCase = true) &&
            uri.host?.lowercase(java.util.Locale.ROOT) in imageHosts &&
            uri.rawUserInfo == null && uri.rawQuery == null && uri.rawFragment == null &&
            (uri.port == -1 || uri.port == 443)
    }

    fun encode(candidates: List<ProfilePickerArtworkCandidate>, nowMillis: Long): String? {
        if (nowMillis <= 0L) return null
        val selected = candidates.mapNotNull(::valid).distinctBy { it.id }.take(CANDIDATE_LIMIT)
        if (selected.isEmpty()) return null
        val rows = org.json.JSONArray()
        selected.forEach { row -> rows.put(JSONObject().put("id", row.id).put("name", row.name)
            .put("urls", org.json.JSONArray(row.artworkURLs))) }
        val text = JSONObject().put("schema", SCHEMA).put("source", SOURCE)
            .put("savedAt", nowMillis).put("movies", rows).toString()
        return text.takeIf { it.toByteArray(Charsets.UTF_8).size <= MAX_BYTES }
    }

    fun decode(text: String, nowMillis: Long): List<ProfilePickerArtworkCandidate> = try {
        if (text.toByteArray(Charsets.UTF_8).size > MAX_BYTES || nowMillis <= 0L) emptyList() else {
            val root = JSONObject(text)
            require(root.keys().asSequence().toSet() == setOf("schema", "source", "savedAt", "movies"))
            require(root.opt("schema") == SCHEMA && root.opt("source") == SOURCE)
            val savedNumber = root.opt("savedAt") as? Number ?: error("Invalid public artwork cache clock")
            val savedAt = java.math.BigDecimal(savedNumber.toString()).longValueExact()
            require(savedAt in 1..nowMillis && nowMillis - savedAt <= MAX_AGE_MS)
            val rows = root.getJSONArray("movies")
            require(rows.length() in 1..CANDIDATE_LIMIT)
            val output = ArrayList<ProfilePickerArtworkCandidate>(rows.length())
            val ids = HashSet<String>()
            for (index in 0 until rows.length()) {
                val row = rows.getJSONObject(index)
                require(row.keys().asSequence().toSet() == setOf("id", "name", "urls"))
                val id = row.opt("id") as? String ?: error("Invalid public artwork id")
                val name = row.opt("name") as? String ?: error("Invalid public artwork name")
                val urls = row.getJSONArray("urls")
                require(urls.length() in 1..2)
                val original = ProfilePickerArtworkCandidate(id, name, (0 until urls.length()).map {
                    urls.get(it) as? String ?: error("Invalid public artwork URL")
                })
                val accepted = valid(original) ?: error("Invalid public artwork record")
                require(accepted == original && ids.add(id))
                output += accepted
            }
            output
        }
    } catch (_: Exception) { emptyList() }
}

/** A replace-only bounded app-cache file. Old good data survives a failed write or refresh. */
private class ProfilePickerPublicArtworkCache(private val file: java.io.File) {
    suspend fun read(): List<ProfilePickerArtworkCandidate> = withContext(Dispatchers.IO) {
        try {
            if (!file.isFile || file.length() > ProfilePickerPublicArtworkCacheCodec.MAX_BYTES) return@withContext emptyList()
            val bytes = file.inputStream().use { input ->
                val output = ByteArrayOutputStream()
                val buffer = ByteArray(4096)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    if (output.size() + count > ProfilePickerPublicArtworkCacheCodec.MAX_BYTES) return@withContext emptyList()
                    output.write(buffer, 0, count)
                }
                output.toByteArray()
            }
            currentCoroutineContext().ensureActive()
            ProfilePickerPublicArtworkCacheCodec.decode(bytes.toString(Charsets.UTF_8), System.currentTimeMillis())
        } catch (cancel: CancellationException) { throw cancel }
        catch (_: Exception) { emptyList() }
    }

    suspend fun write(candidates: List<ProfilePickerArtworkCandidate>): Unit = withContext(Dispatchers.IO) {
        val text = ProfilePickerPublicArtworkCacheCodec.encode(candidates, System.currentTimeMillis())
            ?: return@withContext
        var temporary: java.io.File? = null
        try {
            val parent = checkNotNull(file.parentFile)
            if (!parent.isDirectory && !parent.mkdirs()) return@withContext
            temporary = java.io.File.createTempFile("profile-picker-art-", ".pending", parent)
            temporary.writeText(text, Charsets.UTF_8)
            currentCoroutineContext().ensureActive()
            try {
                java.nio.file.Files.move(temporary.toPath(), file.toPath(),
                    java.nio.file.StandardCopyOption.REPLACE_EXISTING, java.nio.file.StandardCopyOption.ATOMIC_MOVE)
            } catch (_: java.nio.file.AtomicMoveNotSupportedException) {
                java.nio.file.Files.move(temporary.toPath(), file.toPath(), java.nio.file.StandardCopyOption.REPLACE_EXISTING)
            }
        } catch (cancel: CancellationException) { throw cancel }
        catch (_: Exception) { /* Public artwork cache is optional; retain the prior file. */ }
        finally { temporary?.delete() }
        Unit
    }
}

/** Local-data probe only. A later URL presentation can still miss memory/disk cache after eviction. */
private suspend fun loadCachedPickerArtwork(context: Context, imageLoader: ImageLoader, url: String): Boolean =
    withContext(Dispatchers.IO) {
        try {
            val snapshot = imageLoader.diskCache?.openSnapshot(url) ?: return@withContext false
            snapshot.use {
                val request = ImageRequest.Builder(context)
                    .data(it.data.toFile())
                    .memoryCacheKey(url)
                    .size(PICKER_ARTWORK_DECODE_PX, PICKER_ARTWORK_DECODE_PX)
                    .scale(coil3.size.Scale.FIT)
                    .precision(coil3.size.Precision.INEXACT)
                    .build()
                val loaded = imageLoader.execute(request) is SuccessResult
                currentCoroutineContext().ensureActive()
                loaded
            }
        } catch (cancel: CancellationException) { throw cancel }
        catch (_: Exception) { false }
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
    val publicCache = remember(context) {
        ProfilePickerPublicArtworkCache(java.io.File(context.cacheDir, "profile-picker-public-art-v1.json"))
    }
    val controller = remember(context, imageLoader, publicCache) {
        ProfilePickerArtworkController(
            fetchCandidates = ::fetchPublicFamilyMovies,
            loadArtwork = { url -> loadPickerArtwork(context, imageLoader, url) },
            readCachedCandidates = publicCache::read,
            loadCachedArtwork = { url -> loadCachedPickerArtwork(context, imageLoader, url) },
            writeCachedCandidates = publicCache::write,
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
                    maxDecodePx = PICKER_ARTWORK_DECODE_PX,
                    decodeScale = coil3.size.Scale.FIT,
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
                .size(PICKER_ARTWORK_DECODE_PX, PICKER_ARTWORK_DECODE_PX)
                .scale(coil3.size.Scale.FIT)
                .precision(coil3.size.Precision.INEXACT)
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

private const val PICKER_ARTWORK_DECODE_PX = 1920
private const val ARTWORK_FADE_MILLIS = 800
private const val CATALOG_TIMEOUT_MILLIS = 12_000
private const val CATALOG_MAX_BYTES = 512 * 1024
private const val CANDIDATE_LIMIT = 12
