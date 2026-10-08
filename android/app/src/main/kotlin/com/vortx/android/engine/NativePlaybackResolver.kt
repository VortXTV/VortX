package com.vortx.android.engine

import android.content.Context
import com.vortx.android.debrid.DebridCoordinator
import com.vortx.android.debrid.DebridKeys
import com.vortx.android.debrid.DebridResolver
import com.vortx.android.model.Episode
import com.vortx.android.model.Playable
import com.vortx.android.model.StreamSource
import com.vortx.android.model.SubtitleRequestMetadata
import com.vortx.android.usenet.UsenetProviderStore
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

/** Platform resolution only. Credentials stay in their existing owner-scoped secure stores. */
internal fun interface NativePlaybackResolver {
    suspend fun resolve(source: StreamSource, episode: Episode?): Playable

    /** Captured repository owner/source admission, not a lookup of the currently selected profile. */
    suspend fun resolve(source: StreamSource, episode: Episode?, isCurrent: () -> Boolean): Playable {
        currentCoroutineContext().ensureActive()
        if (!isCurrent()) throw CancellationException("Playback owner changed")
        val result = resolve(source, episode)
        try {
            currentCoroutineContext().ensureActive()
            if (!isCurrent()) throw CancellationException("Playback owner changed")
            return result
        } catch (failure: Throwable) {
            result.playbackLease?.close()
            throw failure
        }
    }
}

internal fun nativeDirectPlayable(source: StreamSource): Playable? {
    if (source.isTorrent || source.isUsenet) return null
    val url = source.directPlaybackUrl(source.id.substringBefore('#')) ?: return null
    return Playable(url, source.title, headers = source.requestHeaders,
        externalSubtitles = source.externalSubtitles, externalSubtitleTracks = source.externalSubtitleTracks,
        communityJsTransport = source.communityJsTransport)
}

internal class AndroidNativePlaybackResolver(context: Context) : NativePlaybackResolver {
    private val context = context.applicationContext
    private val keys by lazy { DebridKeys(this.context) }
    private val resolver by lazy { DebridResolver(keys) }
    private val coordinator by lazy { DebridCoordinator(resolver = resolver, keys = keys, appContext = this.context,
        usenetProviderStore = UsenetProviderStore(this.context, keys::ownerToken, keys::mutateCurrentOwner)) }

    override suspend fun resolve(source: StreamSource, episode: Episode?): Playable {
        val direct = nativeDirectPlayable(source)
        val playable = when {
            direct != null -> direct
            source.isUsenet -> {
                val target = source.usenetResolveTarget(episode)
                val result = try {
                    coordinator.resolvePlaybackRef(DebridCoordinator.DebridCandidate(nzbUrl = target.nzbUrl,
                        usenetKnownHash = target.knownHash, fileMustInclude = target.fileMustInclude, fileIdx = target.fileIdx), target.episode)
                } catch (cancel: CancellationException) { throw cancel }
                catch (error: Exception) { throw usenetPlaybackFailure(error) }
                    ?: throw usenetPlaybackFailure(DebridResolver.DebridException.NoKey)
                Playable(result.url, source.title, playbackLease = result.progressiveSession)
            }
            source.isTorrent -> {
                val target = source.debridResolveTarget(source.id.substringBefore('#'), episode)
                require(Regex("[a-fA-F0-9]{40}").matches(target.infoHash)) { "Invalid torrent identity" }
                require(target.fileIdx == null || target.fileIdx >= 0) { "Invalid torrent file" }
                val url = resolver.resolve(infoHash = target.infoHash, episode = target.episode, fileIdx = target.fileIdx)
                if (url != null) Playable(url, source.title)
                else {
                    val base = if (VortxServer.streamingEnabled(context)) VortxServer.startIfNeeded(context) else null
                    checkNotNull(base) { "Native torrent server is unavailable; configure debrid or install a server-enabled artifact" }
                    Playable("$base/${target.infoHash.lowercase()}/${target.fileIdx ?: 0}", source.title, viaStreamingServer = true, isTorrent = true)
                }
            }
            else -> throw UnsupportedOperationException("This native source type cannot be resolved")
        }
        return playable.copy(isDolbyVision = StreamRanking.isDolbyVision(source), isAtmos = StreamRanking.isAtmos(source),
            subtitleMetadata = SubtitleRequestMetadata(source.filename, source.videoHash, source.videoSize))
    }
}
