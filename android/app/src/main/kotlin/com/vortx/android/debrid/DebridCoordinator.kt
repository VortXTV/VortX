package com.vortx.android.debrid

import android.content.Context
import android.util.Log
import com.vortx.android.engine.StreamRanking
import com.vortx.android.model.StreamSource
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch
import kotlinx.coroutines.supervisorScope
import kotlinx.coroutines.withTimeoutOrNull

/// Drives cache-check + playback resolution across the user's configured debrid providers. This is the
/// Kotlin port of the Apple `DebridCoordinator` (app/SourcesShared/DebridResolver.swift): the per-provider
/// resolve/cache-check legs live in [DebridResolver] (which dispatches by service); this layer adds the
/// cross-provider orchestration the parity map flagged as missing:
///
///  - cache-check FAN-OUT: query every configured provider CONCURRENTLY, then merge deterministically so
///    the ranker/assembly can prefer account-confirmed-cached sources ([cacheCheck]).
///  - MULTI-CANDIDATE FAILOVER: race the top cached candidates and return the first that mints a real link,
///    so a dead/false-cached pick never blocks a genuinely-cached one ([resolveFirstPlayable]).
///  - CWResume / reresolve: refresh an expired debrid link for a Continue-Watching resume within a 20-min
///    fresh window, re-resolving the SAME source rather than re-running source selection ([resumePlaybackURL]).
///  - usenet: the TorBox usenet resolve + cache-check path ([resolveUsenet] / [usenetCacheCheck]).
///
/// CONCURRENCY MODEL (this is the part that gets reviewed): every fan-out uses structured concurrency under a
/// [supervisorScope], so a failing leg NEVER cancels its siblings; every leg additionally catches its own
/// failure and yields a soft null/empty; and all provider IO runs on [Dispatchers.IO]. A provider error only
/// ever HIDES that provider (no confirmations / no link), it never crashes the caller. The whole layer is
/// fail-soft by construction, matching the Apple actor's async semantics.
///
/// STATELESS: unlike the Apple actor (which caches per-service resolver actors + hops to the main actor for a
/// key snapshot), this holds a single [DebridResolver] that dispatches by service and reads [DebridKeys]
/// synchronously (EncryptedSharedPreferences reads are cheap and thread-safe), so no warm/reload dance and no
/// actor isolation are needed. Callers (the source-list assembly wave, the CW resume path) construct one and
/// invoke its suspend methods from any dispatcher.
class DebridCoordinator(
    private val resolver: DebridResolver,
    private val keys: DebridKeys,
) {
    /// Convenience: build the resolver + key store from the app context (the assembly/play layer already
    /// owns a [DebridResolver]; prefer sharing that via the primary constructor when possible).
    constructor(context: Context) : this(
        DebridKeys(context.applicationContext).let { k -> DebridResolver(k) to k },
    )

    private constructor(pair: Pair<DebridResolver, DebridKeys>) : this(pair.first, pair.second)

    // ------------------------------------------------------------------------------------------------
    // Value types
    // ------------------------------------------------------------------------------------------------

    /// The provenance of a natively-resolved debrid link: enough to regenerate a FRESH link straight from the
    /// provider (skipping the add step) when the minted URL has expired. Carried from the resolve site to the
    /// play-record so a Continue-Watching resume can [reresolve] the SAME source. [torrentId]/[fileId] are the
    /// provider ids that avoid a re-add; [infoHash]/[fileIdx] let a provider re-add from scratch if the id is
    /// gone. A usenet ref carries an empty [infoHash] (no reresolve id: the url alone plays). Mirrors the
    /// Apple `DebridPlaybackRef`.
    data class DebridPlaybackRef(
        val url: String,
        val service: DebridService,
        val infoHash: String,
        val torrentId: Int?,
        val fileId: Int?,
        val fileIdx: Int?,
    )

    /// A resolvable source the failover race operates on. The source-list assembly wave maps each ranked
    /// `CoreStream` into one of these (it owns `CoreStream`/ranking; this layer stays decoupled from them).
    /// A raw torrent carries [infoHash] (+ optional [magnet]/[trackers]); a usenet stream carries [nzbUrl]
    /// (+ optional [usenetKnownHash]/[fileMustInclude]); [hasDirectUrl] marks a stream that already has a
    /// direct/debrid link (skipped: nothing to resolve). Mirrors the `CoreStream` fields the Apple
    /// `resolveFirstPlayable` reads.
    ///
    /// [source] is the [StreamSource] this candidate was mapped from, carried ONLY so the label-authoritative
    /// gate in [resolveFirstPlayable] can rank a race winner's resolution via [StreamRanking.resolutionRank]
    /// (the Android analogue of Apple's `CoreStream` candidates carrying their own resolution). Null when the
    /// caller has no source to attach (the gate then treats the candidate as always acceptable).
    data class DebridCandidate(
        val infoHash: String? = null,
        val magnet: String? = null,
        val trackers: List<String> = emptyList(),
        val nzbUrl: String? = null,
        val usenetKnownHash: String? = null,
        val fileMustInclude: String? = null,
        val fileIdx: Int? = null,
        val hasDirectUrl: Boolean = false,
        val source: StreamSource? = null,
    )

    /// A cache-check hit: which provider has the hash cached, plus the cached file list. Mirrors the Apple
    /// `cacheCheck` return `(service, files)`.
    data class CacheHit(val service: DebridService, val files: List<DebridResolver.DebridFile>)

    /// The winning ([ref]) of a failover race PAIRED with the [candidate] it resolved from, so the caller can
    /// wire the engine / headers off the exact winning source. Mirrors the Apple `(ref, stream)`.
    data class PlayableWinner(val ref: DebridPlaybackRef, val candidate: DebridCandidate)

    /// The outcome of a Continue-Watching resume resolve: the [url] to hand the player, and whether it is
    /// AUTHORITATIVE ([refreshed] = a freshly minted link, OR a stored link still inside the fresh window) or
    /// a possibly-stale fallback ([refreshed] = false, so the caller keeps its stale-link failover priming).
    /// Mirrors the Apple `CWResume.resolvedURL` `(url, refreshed)`.
    data class ResumeResolution(val url: String, val refreshed: Boolean)

    // ------------------------------------------------------------------------------------------------
    // Gates
    // ------------------------------------------------------------------------------------------------

    /// True when any debrid provider is configured (a torrent resolve is possible). With no key every torrent
    /// path returns immediately with no network, byte-identical to pre-feature behaviour.
    val hasAnyResolver: Boolean get() = keys.hasAnyKey()

    /// True when a usenet resolve is possible (a TorBox key is configured; usenet is TorBox-only). With no
    /// TorBox key every usenet path is inert.
    val hasUsenetResolver: Boolean get() = keys.isConfigured(DebridService.TOR_BOX)

    private fun pickService(service: DebridService?): DebridService? =
        service?.takeIf(keys::isConfigured) ?: keys.configuredServices().firstOrNull()

    // ------------------------------------------------------------------------------------------------
    // Cache-check (concurrent fan-out)
    // ------------------------------------------------------------------------------------------------

    /// Which provider has each of [hashes] cached (the first configured provider that reports it), with the
    /// files. Queries every configured provider CONCURRENTLY, then merges in a deterministic
    /// [DebridService.entries] priority order so the chosen provider for a hash is stable.
    ///
    /// Fail-soft: each per-provider probe already never throws (see [DebridResolver.checkCache]); the leg is
    /// additionally wrapped so even an unexpected throw hides only that provider and never cancels its
    /// siblings ([supervisorScope]). Real-Debrid contributes nothing (it removed its instant cache-check).
    /// Empty with no key. Mirrors the Apple `DebridCoordinator.cacheCheck` `withTaskGroup` + priority merge.
    suspend fun cacheCheck(hashes: List<String>): Map<String, CacheHit> {
        val services = keys.configuredServices()
        if (services.isEmpty() || hashes.isEmpty()) return emptyMap()

        val maps: Map<DebridService, Map<String, List<DebridResolver.DebridFile>>> = supervisorScope {
            val deferreds = services.map { service ->
                service to async(Dispatchers.IO) {
                    try {
                        resolver.checkCache(service, hashes)
                    } catch (cancel: CancellationException) {
                        throw cancel
                    } catch (error: Exception) {
                        emptyMap<String, List<DebridResolver.DebridFile>>()
                    }
                }
            }
            // await() is a suspend call, so collect in a plain loop (the supervisorScope block IS a suspend
            // context); a non-inline mapValues/associate lambda would not compile here.
            val collected = LinkedHashMap<DebridService, Map<String, List<DebridResolver.DebridFile>>>()
            for ((service, deferred) in deferreds) collected[service] = deferred.await()
            collected
        }

        val out = LinkedHashMap<String, CacheHit>()
        for (service in DebridService.entries) {
            val map = maps[service] ?: continue
            for ((hash, files) in map) {
                if (files.isNotEmpty() && !out.containsKey(hash)) out[hash] = CacheHit(service, files)
            }
        }
        return out
    }

    /// Which of [nzbMd5s] the user's TorBox usenet account has cached (drives the usenet cache badge). The
    /// keys are the lowercased md5 identifiers, matching [DebridResolver.usenetIdentifier]. Empty with no
    /// TorBox key. Mirrors the Apple `usenetCacheCheck`.
    suspend fun usenetCacheCheck(nzbMd5s: List<String>): Set<String> {
        if (!hasUsenetResolver || nzbMd5s.isEmpty()) return emptySet()
        val map = resolver.usenetCheckCache(nzbMd5s)
        return map.filterValues { it.isNotEmpty() }.keys
    }

    // ------------------------------------------------------------------------------------------------
    // Single-source resolve (throwing surface for the assembly/play layer)
    // ------------------------------------------------------------------------------------------------

    /// Resolve a torrent through the given (or first configured) provider, surfacing the provider ids for a
    /// later [reresolve]. Throws [DebridResolver.DebridException.NoKey] when nothing is configured, and any
    /// other [DebridResolver.DebridException] on a resolve failure. Mirrors the Apple `resolveWithIds`.
    suspend fun resolveWithIds(
        service: DebridService? = null,
        infoHash: String,
        magnet: String? = null,
        fileIdx: Int? = null,
        episode: DebridResolver.Episode? = null,
        trackers: List<String> = emptyList(),
    ): Pair<DebridResolver.ResolvedLink, DebridService> {
        val chosen = pickService(service) ?: throw DebridResolver.DebridException.NoKey
        val link = resolver.resolveWithIds(chosen, infoHash, magnet, fileIdx, episode, trackers)
        return link to chosen
    }

    /// Regenerate a fresh direct link for a previously-resolved file through the SAME provider, skipping the
    /// add step where the provider supports it. Used by [resumePlaybackURL]. Mirrors the Apple `reresolve`.
    suspend fun reresolve(
        service: DebridService,
        infoHash: String,
        torrentId: Int?,
        fileId: Int?,
        fileIdx: Int?,
    ): String {
        if (!keys.isConfigured(service)) throw DebridResolver.DebridException.NoKey
        return resolver.reresolveLink(service, infoHash, torrentId, fileId, fileIdx)
    }

    /// Resolve a usenet stream (nzb link) to a direct HTTPS URL via the TorBox usenet backend. Throws
    /// [DebridResolver.DebridException.NoKey] when no TorBox key is configured. Mirrors the Apple
    /// `resolveUsenet`.
    suspend fun resolveUsenet(
        nzbUrl: String,
        knownHash: String? = null,
        fileMustInclude: String? = null,
        fileIdx: Int? = null,
        episode: DebridResolver.Episode? = null,
    ): String {
        if (!hasUsenetResolver) throw DebridResolver.DebridException.NoKey
        return resolver.resolveUsenet(nzbUrl, knownHash, fileMustInclude, fileIdx, episode)
    }

    // ------------------------------------------------------------------------------------------------
    // Bounded, fail-soft single-candidate resolve
    // ------------------------------------------------------------------------------------------------

    /// The single bridge from a raw torrent / usenet [candidate] to a debrid DIRECT link for playback,
    /// returning the full [DebridPlaybackRef] (url + provider + reresolve ids) so the play-record can persist
    /// enough to later refresh an expired link. FAIL-SOFT by construction: every non-success (no key, not a
    /// resolvable candidate, any provider error, a throw, or the [RESOLVE_TIMEOUT_MS] budget) returns null so
    /// the caller falls back to today's path.
    ///
    /// NO-KEY / CACHE GATE: with no resolver this returns null immediately (no network). When [confirmedCachedHashes]
    /// (or [confirmedUsenetURLs]) is non-null, a not-confirmed pick returns null with ZERO network so the
    /// caller falls straight through to the embedded path; a null set keeps the pre-gate behaviour. Mirrors
    /// the Apple `resolvedPlaybackRef`.
    suspend fun resolvePlaybackRef(
        candidate: DebridCandidate,
        episode: DebridResolver.Episode? = null,
        confirmedCachedHashes: Set<String>? = null,
        confirmedUsenetURLs: Set<String>? = null,
    ): DebridPlaybackRef? {
        // USENET first: a stream with an .nzb link (and no direct url) resolves through the TorBox usenet
        // backend, gated on a TorBox key. NOT a torrent: the minted URL is a plain direct stream (no infoHash).
        if (!candidate.hasDirectUrl && !candidate.nzbUrl.isNullOrBlank()) {
            if (!hasUsenetResolver) return null
            if (confirmedUsenetURLs != null && candidate.nzbUrl !in confirmedUsenetURLs) return null
            return withTimeoutOrNull(RESOLVE_TIMEOUT_MS) {
                try {
                    val url = resolver.resolveUsenet(
                        candidate.nzbUrl, candidate.usenetKnownHash, candidate.fileMustInclude, candidate.fileIdx, episode,
                    )
                    DebridPlaybackRef(url, DebridService.TOR_BOX, infoHash = "", torrentId = null, fileId = null, fileIdx = candidate.fileIdx)
                } catch (cancel: CancellationException) {
                    throw cancel
                } catch (error: Exception) {
                    null
                }
            }
        }

        // Raw torrent only: a candidate WITH a direct url is already playable; one with neither url nor
        // infoHash isn't ours to resolve. Branch out before any provider work.
        if (candidate.hasDirectUrl) return null
        val hash = candidate.infoHash?.trim()?.lowercase()?.takeIf { it.isNotEmpty() } ?: return null
        if (!hasAnyResolver) return null
        if (confirmedCachedHashes != null && hash !in confirmedCachedHashes) return null
        val service = pickService(null) ?: return null
        val magnet = candidate.magnet?.takeIf { it.isNotBlank() } ?: resolver.magnet(hash, candidate.trackers)

        return withTimeoutOrNull(RESOLVE_TIMEOUT_MS) {
            try {
                val link = resolver.resolveWithIds(service, hash, magnet, candidate.fileIdx, episode, candidate.trackers)
                DebridPlaybackRef(link.url, service, hash, link.torrentId, link.fileId, candidate.fileIdx)
            } catch (cancel: CancellationException) {
                throw cancel
            } catch (error: Exception) {
                null
            }
        }
    }

    // ------------------------------------------------------------------------------------------------
    // Multi-candidate failover (parallel cached-source race)
    // ------------------------------------------------------------------------------------------------

    /// PARALLEL cached-source race: resolve up to [max] account-confirmed-cached [candidates] CONCURRENTLY (in
    /// the caller's rank order) and return the FIRST that mints a real link, cancelling the losers. This is the
    /// multi-candidate failover: the best source is tried, but a dead / false-cached / evicted pick simply
    /// yields null and a sibling wins instead of the user tapping dead rows one by one.
    ///
    /// A candidate is raced when it is a raw torrent whose lowercased infoHash is in [cachedHashes], OR a
    /// usenet stream whose nzb link is in [cachedUsenetURLs] (the same account-confirmed sets the source list
    /// badges); a candidate already carrying a direct url is skipped. Nothing not confirmed cached is raced,
    /// so we never kick off an uncached add-then-download.
    ///
    /// CONCURRENCY: each leg runs on [Dispatchers.IO] under a [supervisorScope], so a leg that FAILS (returns
    /// null, or even throws) NEVER cancels its siblings; each leg additionally catches its own failure and
    /// yields null. Results arrive on an unbounded [Channel] and are drained in COMPLETION order; the first
    /// non-null winner wins and the remaining in-flight legs are cancelled (their poll loops honor
    /// cancellation and stop promptly). FAIL-SOFT: returns null when nothing is confirmed-cached to race or
    /// every leg fails, so the caller falls back to today's single-resolve / local-engine path (byte-identical
    /// with no key: this returns before any await). Mirrors the Apple `resolveFirstPlayable`.
    ///
    /// LABEL-AUTHORITATIVE GATE ([labeledBest]): the "Watch Now" button label is composed from the labeled
    /// best source, so the played source must not be a LOWER resolution than that promise. We can only hold
    /// the promise when the labeled best is itself guaranteed to resolve, i.e. it is confirmed-cached (a raw
    /// torrent whose hash is in [cachedHashes], a usenet nzb in [cachedUsenetURLs], or a url-bearing
    /// direct/debrid row). In that case we REFUSE any race winner whose resolution ([StreamRanking.resolutionRank]
    /// of the candidate's [DebridCandidate.source]) is below the label, and return null so the caller
    /// single-resolves the labeled best instead. When the labeled best is NOT confirmed-cached (a false add-on
    /// cached tag that would time out serially), the gate is inert and the completion-order race stays exactly
    /// as before so the user still reaches a real cached source fast. With no [labeledBest] (or a candidate
    /// carrying no [DebridCandidate.source]) the gate accepts anything. Mirrors the Apple
    /// `resolveFirstPlayable` gate (app/SourcesShared/DebridResolver.swift ~1360-1419).
    suspend fun resolveFirstPlayable(
        candidates: List<DebridCandidate>,
        episode: DebridResolver.Episode? = null,
        cachedHashes: Set<String>,
        cachedUsenetURLs: Set<String> = emptySet(),
        max: Int = 4,
        labeledBest: StreamSource? = null,
    ): PlayableWinner? {
        // No-key / nothing-to-race guarantee: return before any provider contact so the caller's fallback runs.
        if (!hasAnyResolver && !hasUsenetResolver) return null
        if (cachedHashes.isEmpty() && cachedUsenetURLs.isEmpty()) return null

        // Keep only the confirmed-cached, resolvable candidates, in the caller's rank order.
        val cached = candidates.filter { c ->
            if (c.hasDirectUrl) return@filter false
            val h = c.infoHash?.trim()?.lowercase()
            if (!h.isNullOrEmpty() && h in cachedHashes) return@filter true
            val nzb = c.nzbUrl
            if (!nzb.isNullOrEmpty() && nzb in cachedUsenetURLs) return@filter true
            false
        }
        if (cached.isEmpty()) return null

        // Bound concurrency to [1, 4] so a group never hammers the provider; losers are cancelled on the first win.
        val cap = max.coerceIn(1, 4)
        val racing = cached.take(cap)

        // LABEL-AUTHORITATIVE GATE. The label's resolution rank, and whether the label is a source we can
        // actually deliver (confirmed-cached) so a lower-quality substitute would break the promise. A winner
        // is acceptable unless the label is a confirmed-cached HIGHER resolution than it. Equal-or-higher
        // winners always pass, so a same-tier faster leg still wins the race.
        val bestRank: Int? = labeledBest?.let { StreamRanking.resolutionRank(it) }
        val bestConfirmedCached: Boolean = labeledBest?.let { best ->
            if (best.url != null) return@let true // direct / debrid link resolves without an add-then-download
            val h = best.infoHash?.trim()?.lowercase()
            if (!h.isNullOrEmpty() && h in cachedHashes) return@let true
            val nzb = best.nzbUrl
            if (!nzb.isNullOrEmpty() && nzb in cachedUsenetURLs) return@let true
            false
        } ?: false
        fun acceptable(candidate: DebridCandidate): Boolean {
            if (!bestConfirmedCached || bestRank == null) return true
            val src = candidate.source ?: return true // no source to rank: never refuse
            return StreamRanking.resolutionRank(src) >= bestRank
        }

        // A single confirmed-cached candidate is just the existing single resolve (no group overhead). Still
        // honour the gate: a lone winner below a confirmed-cached label is refused so the caller resolves the
        // labeled best instead.
        if (racing.size == 1) {
            if (!acceptable(racing[0])) return null
            val ref = resolvePlaybackRef(racing[0], episode, cachedHashes, cachedUsenetURLs) ?: return null
            return PlayableWinner(ref, racing[0])
        }

        return supervisorScope {
            // Unbounded so a leg's send never suspends and a losing leg is never blocked; results are drained
            // in completion order below.
            val results = Channel<PlayableWinner?>(Channel.UNLIMITED)
            val legs = racing.map { candidate ->
                launch(Dispatchers.IO) {
                    var result: PlayableWinner? = null
                    try {
                        result = resolvePlaybackRef(candidate, episode, cachedHashes, cachedUsenetURLs)
                            ?.let { PlayableWinner(it, candidate) }
                    } catch (cancel: CancellationException) {
                        throw cancel   // real cancellation: propagate (the finally still emits its sentinel)
                    } catch (error: Exception) {
                        // provider failure already collapses to null inside resolvePlaybackRef; belt-and-suspenders
                    } finally {
                        // EXACTLY ONE emit per leg on EVERY exit path (success, Exception, a bare Error, or
                        // cancellation), so the fixed-count drain below can never block on a leg that died
                        // without reporting. trySend is non-suspending and safe during cancellation.
                        results.trySend(result)
                    }
                }
            }

            // First leg to produce a real ref that PASSES the label-authoritative gate wins; a leg that
            // fails/fast-fails sends null, and a leg that resolves but is a lower resolution than a
            // confirmed-cached label is skipped (never a silent lower-quality substitute). We keep draining
            // until an acceptable ref appears or every leg has reported. When every resolved leg is below a
            // confirmed-cached label the winner stays null and the caller single-resolves the labeled best.
            var winner: PlayableWinner? = null
            for (i in racing.indices) {
                val result = results.receive()
                if (result != null && acceptable(result.candidate)) {
                    winner = result
                    break
                }
            }
            // Cancel the remaining in-flight legs (idempotent on already-completed ones). The supervisorScope
            // then awaits their prompt, cancellation-honoring exit before returning.
            legs.forEach { it.cancel() }
            winner
        }
    }

    // ------------------------------------------------------------------------------------------------
    // Continue-Watching exact-source resume (CWResume)
    // ------------------------------------------------------------------------------------------------

    /// Resolve the EXACT stored source of a Continue-Watching item to a playable URL, mirroring the Apple
    /// `CWResume.resolvedURL`. Owner requirement: resume plays THAT source (the one the user chose), not a
    /// re-run of source selection across all add-ons.
    ///
    ///  - No debrid provenance ([ref] null or its [DebridPlaybackRef.infoHash] empty, i.e. a plain-direct /
    ///    torrent / usenet entry with no reresolve id): return [storedUrl] unchanged, `refreshed = false`.
    ///  - INSTANT RESUME: a debrid link minted within [FRESH_LINK_WINDOW_MS] is almost certainly still valid,
    ///    so hand [storedUrl] straight back with `refreshed = true` (no reresolve round-trip). This keeps the
    ///    "quick pause then resume" case instant.
    ///  - Older than the window (or no mint timestamp): mint a FRESH link for the SAME file through the SAME
    ///    provider via [reresolve] (on TorBox a single requestdl off the stored ids; others re-add from the
    ///    infoHash) and return it with `refreshed = true`.
    ///  - Same source genuinely unavailable (evicted / no key / reresolve throws): fall back to [storedUrl]
    ///    with `refreshed = false`, letting the caller's own player failover take over only now.
    ///
    /// [linkSavedAtMillis] is the epoch-millis the stored link was minted (null when unknown). Never throws
    /// (except on real cancellation).
    suspend fun resumePlaybackURL(
        ref: DebridPlaybackRef?,
        storedUrl: String?,
        linkSavedAtMillis: Long?,
    ): ResumeResolution {
        // No debrid provenance: the stored link is all we have. (Usenet refs carry an empty infoHash, so they
        // also take this path: usenet has no reresolve id, exactly as on Apple.)
        if (ref == null || ref.infoHash.isEmpty()) {
            return ResumeResolution(storedUrl.orEmpty(), refreshed = false)
        }
        // INSTANT RESUME: still inside the fresh window -> replay the stored link directly (fresh-window check
        // is independent of whether the key is still configured, matching Apple's ordering).
        if (!storedUrl.isNullOrEmpty() && linkSavedAtMillis != null) {
            val age = System.currentTimeMillis() - linkSavedAtMillis
            if (age in 0 until FRESH_LINK_WINDOW_MS) return ResumeResolution(storedUrl, refreshed = true)
        }
        // Key removed since the entry was recorded: skip the doomed reresolve and fall back to the stored link
        // (Apple's reresolve throws .noKey here, caught to the same fallback).
        if (!keys.isConfigured(ref.service)) {
            return ResumeResolution(storedUrl.orEmpty(), refreshed = false)
        }
        // Older than the window (or no mint timestamp): mint a FRESH link for the SAME file, SAME provider.
        val fresh = try {
            reresolve(ref.service, ref.infoHash, ref.torrentId, ref.fileId, ref.fileIdx)
        } catch (cancel: CancellationException) {
            throw cancel
        } catch (error: Exception) {
            Log.d(TAG, "CW resume reresolve failed for ${ref.service.displayName}: ${error.message}")
            null
        }
        if (fresh != null) return ResumeResolution(fresh, refreshed = true)
        // Same source genuinely unavailable: fall back to the possibly-stale stored link.
        return ResumeResolution(storedUrl.orEmpty(), refreshed = false)
    }

    private companion object {
        const val TAG = "DebridCoordinator"

        /// Streaming-settle ceiling for one in-line resolve. A confirmed-cached source resolves in ~1 round
        /// trip, so 5s covers it while bounding a stall (flaky provider, hung network) so the play action
        /// never hangs. On timeout the resolve is cancelled and the caller falls soft. Mirrors the Apple
        /// `DebridCoordinator.resolveTimeout` (5s).
        const val RESOLVE_TIMEOUT_MS = 5_000L

        /// How recently a stored debrid link must have been minted for a resume to replay it instantly without
        /// a reresolve round-trip. Debrid direct links live for hours; a conservative 20 minutes keeps the
        /// "quick pause then resume" case instant while anything older takes the reliable reresolve path.
        /// Mirrors the Apple `CWResume.freshLinkWindow` (20 * 60 s).
        const val FRESH_LINK_WINDOW_MS = 20L * 60L * 1_000L
    }
}
