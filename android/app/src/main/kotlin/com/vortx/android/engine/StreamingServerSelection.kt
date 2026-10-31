package com.vortx.android.engine

import com.vortx.android.cast.CastEligibility
import com.vortx.android.model.Playable
import java.net.URI
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

/** Device-local user choice. Every successful edit replaces the grant, including an identical URL. */
class StreamingServerSelection internal constructor(
    initialBase: String?,
    private val persist: (String?) -> Boolean,
) {
    private var selected = normalizedBase(initialBase)?.let(::ChosenStreamingServer)

    @Synchronized internal fun capture(): ChosenStreamingServer? = selected
    @Synchronized fun currentBase(): String? = selected?.base

    @Synchronized fun save(raw: String): Boolean {
        val base = normalizedBase(raw) ?: return false
        if (!persist(base)) return false
        selected?.retire()
        selected = ChosenStreamingServer(base)
        return true
    }

    @Synchronized fun useEmbedded(): Boolean {
        if (!persist(null)) return false
        selected?.retire()
        selected = null
        return true
    }

    companion object {
        /** The selected endpoint is an origin plus an optional literal path, never credentials or a query. */
        fun normalizedBase(raw: String?): String? {
            var value = raw?.trim()?.takeIf { it.isNotEmpty() && it.length <= 2048 } ?: return null
            if (!value.contains("://")) value = "http://$value"
            value = value.trimEnd('/')
            val uri = runCatching { URI(value) }.getOrNull() ?: return null
            if (!CastEligibility.isRemoteHttpUrl(value) || uri.rawQuery != null || uri.rawFragment != null) return null
            val path = uri.rawPath.orEmpty()
            if (path.isNotEmpty() && !Regex("/[A-Za-z0-9._~/-]*").matches(path)) return null
            if (path.split('/').any { it == "." || it == ".." }) return null
            return value
        }
    }
}

/** Captured before resolution I/O; never manufactured by an add-on response or a remembered media URL. */
internal class ChosenStreamingServer internal constructor(internal val base: String) {
    private val active = AtomicBoolean(true)
    private val retirementLock = Any()
    private val retirementListeners = mutableSetOf<() -> Unit>()
    internal fun isCurrent(): Boolean = active.get()
    internal fun retire() {
        val callbacks = synchronized(retirementLock) {
            if (!active.getAndSet(false)) return
            retirementListeners.toList().also { retirementListeners.clear() }
        }
        callbacks.forEach { it() }
    }
    internal fun onRetire(action: () -> Unit): AutoCloseable {
        val registered = synchronized(retirementLock) {
            if (active.get()) { retirementListeners.add(action); true } else false
        }
        if (!registered) action()
        return AutoCloseable { synchronized(retirementLock) { retirementListeners.remove(action) } }
    }
    internal fun route(infoHash: String, fileIndex: Int, file: StreamingServerPreparedFile, ownerIsCurrent: () -> Boolean): StreamingServerRoute {
        require(Regex("[a-fA-F0-9]{40}").matches(infoHash) && fileIndex >= 0)
        check(isCurrent()) { "Streaming server choice changed" }
        return StreamingServerRoute.create(this, "$base/${infoHash.lowercase()}/$fileIndex", file.contentType, ownerIsCurrent)
    }
    override fun toString(): String = "ChosenStreamingServer(<device-local>)"
}

/** Ephemeral exact-resolution receipt. It is not serialized or restored from watch history. */
class StreamingServerRoute private constructor(
    private val selection: ChosenStreamingServer,
    private val resolvedUrl: String,
    internal val contentType: String?,
    private val ownerIsCurrent: () -> Boolean,
) {
    internal fun permits(url: String): Boolean = url == resolvedUrl && selection.isCurrent() && ownerIsCurrent()
    override fun toString(): String = "StreamingServerRoute(<owned route>)"
    internal companion object {
        fun create(selection: ChosenStreamingServer, url: String, contentType: String?, ownerIsCurrent: () -> Boolean): StreamingServerRoute =
            StreamingServerRoute(selection, url, contentType, ownerIsCurrent)
    }
}

/** Common producer used by the actual native resolver; tests inject only the HTTP preparation effect. */
internal suspend fun resolveSelectedStreamingServerTorrent(
    selection: ChosenStreamingServer,
    infoHash: String,
    fileIndex: Int,
    title: String,
    isCurrent: () -> Boolean,
    playbackIsCurrent: () -> Boolean,
    prepare: suspend (ChosenStreamingServer, String, Int) -> StreamingServerPreparedFile = StreamingServerTransport::prepare,
): Playable {
    fun requireCurrent() {
        if (!selection.isCurrent() || !isCurrent() || !playbackIsCurrent())
            throw CancellationException("Playback or streaming server choice changed")
    }
    currentCoroutineContext().ensureActive()
    requireCurrent()
    // Episode file selection remains the existing resolver's responsibility. Validate before the
    // HTTP effect; never guess a season-pack ordinal or grant a route from an add-on URL.
    require(Regex("[a-fA-F0-9]{40}").matches(infoHash) && fileIndex >= 0)
    val file = prepare(selection, infoHash.lowercase(), fileIndex)
    currentCoroutineContext().ensureActive()
    requireCurrent()
    val route = selection.route(infoHash, fileIndex, file, playbackIsCurrent)
    return Playable("${selection.base}/${infoHash.lowercase()}/$fileIndex", title,
        viaStreamingServer = true, isTorrent = true, streamingServerRoute = route)
}
