package com.vortx.android.integrations

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import com.vortx.android.model.Episode
import com.vortx.android.model.MediaRef
import com.vortx.android.model.MediaType
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject

/// The single fan-out point for external progress sync (Trakt live scrobble, SIMKL watched-on-finish),
/// the Android analogue of the Apple `ScrobbleCoordinator` + `ExternalScrobbleProvider`s. Player call sites
/// call [start] / [pause] / [stop] with a [MediaRef] + progress percentage, and this fans out to every
/// connected + enabled provider without the player knowing any provider's wire shape.
///
/// FIRE-AND-FORGET by design: the public methods are non-suspend and launch on an internal scope that
/// OUTLIVES the composable that called them (so a scrobble STOP fired from the player's `onDispose` still
/// completes after the player leaves composition). Every network op is wrapped `runCatching` so an outage
/// or an auth error never blocks or crashes playback (the Apple "try?"-wrapped invariant).
///
/// DORMANCY: a provider whose credentials are absent ([TraktAuth.isConfigured] / [SIMKLAuth.isConfigured]
/// false) or that the user has not connected makes zero network calls, so an unconfigured build is inert.
///
/// PROVIDER CAPABILITIES (mirroring the Apple `ExternalScrobbleCapabilities`):
///   - Trakt: live start / pause / stop scrobble. A stop at >= [WATCHED_THRESHOLD] progress makes Trakt
///     record the watch in history server-side.
///   - SIMKL: NO live scrobble. It only records a definitive watch on [stop] when progress is high enough,
///     via `POST /sync/history`.
object ScrobbleService {

    private const val TAG = "ScrobbleService"

    /// Progress (0..100) at/above which a stop counts as a definitive watch (Trakt's own history rule, and
    /// the gate for the SIMKL history write). Matches the Apple 80% completion threshold.
    private const val WATCHED_THRESHOLD = 80.0

    // Per-provider scrobble toggles (plain prefs; these are preferences, not secrets). Default ON, matching
    // the Apple @AppStorage defaults for the scrobble switches.
    private const val TOGGLE_PREFS_FILE = "vortx_external_sync"
    const val KEY_TRAKT_SCROBBLE = "vortx.trakt.scrobble"
    const val KEY_SIMKL_SCROBBLE = "vortx.simkl.scrobble"

    /// Internal scope: a SupervisorJob so one provider's failure never cancels the others, on IO. Owned by
    /// the object (process-lifetime), which is exactly why a stop launched from a torn-down composable
    /// still runs to completion.
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    @Volatile private var togglePrefs: SharedPreferences? = null

    /// Idempotent init: wire the toggle prefs and both auth token stores. Safe to call from every entry
    /// point (the player scrobble hook, the Integrations screen).
    fun init(context: Context) {
        val app = context.applicationContext
        if (togglePrefs == null) {
            synchronized(this) {
                if (togglePrefs == null) {
                    togglePrefs = app.getSharedPreferences(TOGGLE_PREFS_FILE, Context.MODE_PRIVATE)
                }
            }
        }
        TraktAuth.init(app)
        SIMKLAuth.init(app)
    }

    // MARK: - Toggles

    /// Whether a provider's live/finish scrobble is enabled (configured AND the toggle on). Default ON.
    fun isTraktScrobbleEnabled(): Boolean =
        TraktAuth.isConfigured && (togglePrefs?.getBoolean(KEY_TRAKT_SCROBBLE, true) ?: true)

    fun isSimklScrobbleEnabled(): Boolean =
        SIMKLAuth.isConfigured && (togglePrefs?.getBoolean(KEY_SIMKL_SCROBBLE, true) ?: true)

    fun setTraktScrobbleEnabled(enabled: Boolean) {
        togglePrefs?.edit()?.putBoolean(KEY_TRAKT_SCROBBLE, enabled)?.apply()
    }

    fun setSimklScrobbleEnabled(enabled: Boolean) {
        togglePrefs?.edit()?.putBoolean(KEY_SIMKL_SCROBBLE, enabled)?.apply()
    }

    // MARK: - Live transitions (fire-and-forget)

    /// Playback started or resumed at [progress] (0..100). Trakt only.
    fun start(ref: MediaRef, progress: Double) = fanScrobble(ref, "start", progress)

    /// Playback paused at [progress]. Trakt only.
    fun pause(ref: MediaRef, progress: Double) = fanScrobble(ref, "pause", progress)

    /// Playback stopped at [progress]. Trakt stop (which records a watch server-side at >= threshold), plus
    /// a SIMKL history write when [progress] clears the watched threshold.
    fun stop(ref: MediaRef, progress: Double) {
        if (!ref.hasUsableId) return
        fanScrobble(ref, "stop", progress)
        if (progress >= WATCHED_THRESHOLD) recordSimklWatched(ref)
    }

    private fun fanScrobble(ref: MediaRef, action: String, progress: Double) {
        // Gate on connected + enabled so a configured-but-not-connected build makes zero calls (no
        // coroutine launched just to fail auth). validToken() below is still the authoritative refresh.
        if (!ref.hasUsableId || !TraktAuth.isSignedIn || !isTraktScrobbleEnabled()) return
        scope.launch {
            runCatching { scrobbleTrakt(ref, action, progress.coerceIn(0.0, 100.0)) }
                .onFailure { Log.d(TAG, "trakt scrobble/$action skipped: ${it.message}") }
        }
    }

    private fun recordSimklWatched(ref: MediaRef) {
        if (!SIMKLAuth.isSignedIn || !isSimklScrobbleEnabled()) return
        scope.launch {
            runCatching { simklAddToHistory(ref) }
                .onFailure { Log.d(TAG, "simkl history skipped: ${it.message}") }
        }
    }

    // MARK: - Trakt wire

    private suspend fun scrobbleTrakt(ref: MediaRef, action: String, progress: Double) {
        val token = TraktAuth.validToken() // throws NotSignedIn when not connected -> caught by runCatching
        val payload = JSONObject().put("progress", progress)
        if (ref.isSeries) {
            payload.put("show", JSONObject().put("ids", traktIds(ref)))
            val season = ref.season
            val number = ref.episode
            if (season != null && number != null) {
                payload.put("episode", JSONObject().put("season", season).put("number", number))
            } else {
                return // an episode scrobble needs S/E; without it Trakt cannot anchor the play
            }
        } else {
            payload.put("movie", JSONObject().put("ids", traktIds(ref)))
        }
        val response = IntegrationsHttp.request(
            method = "POST",
            urlString = "${TraktAuth.API_BASE}/scrobble/$action",
            headers = mapOf(
                "Content-Type" to "application/json",
                "trakt-api-version" to "2",
                "trakt-api-key" to traktClientId(),
                "Authorization" to "Bearer $token",
            ),
            body = payload.toString(),
        )
        Log.d(TAG, "trakt scrobble/$action -> HTTP ${response.status}")
    }

    private fun traktIds(ref: MediaRef): JSONObject = JSONObject().apply {
        ref.imdb?.takeIf { it.isNotEmpty() }?.let { put("imdb", it) }
        ref.tmdb?.let { put("tmdb", it) }
    }

    /// The Trakt client id, re-read from BuildConfig (Trakt's own header). Kept private to this file so the
    /// key stays out of the wider surface.
    private fun traktClientId(): String = com.vortx.android.BuildConfig.TRAKT_CLIENT_ID.trim()

    // MARK: - SIMKL wire

    private suspend fun simklAddToHistory(ref: MediaRef) {
        val token = SIMKLAuth.validToken() // throws NotSignedIn when not connected -> caught by runCatching
        val body = JSONObject()
        val ids = JSONObject().apply {
            ref.imdb?.takeIf { it.isNotEmpty() }?.let { put("imdb", it) }
            ref.tmdb?.let { put("tmdb", it) }
        }
        if (ref.isSeries) {
            val show = JSONObject().put("ids", ids)
            val season = ref.season
            val number = ref.episode
            if (season != null && number != null) {
                show.put(
                    "seasons",
                    JSONArray().put(
                        JSONObject().put("number", season).put(
                            "episodes",
                            JSONArray().put(JSONObject().put("number", number)),
                        ),
                    ),
                )
            }
            body.put("shows", JSONArray().put(show))
        } else {
            body.put("movies", JSONArray().put(JSONObject().put("ids", ids)))
        }
        val response = IntegrationsHttp.request(
            method = "POST",
            urlString = "${SIMKLAuth.API_BASE}/sync/history?${SIMKLAuth.requiredQuery()}",
            headers = SIMKLAuth.authHeaders(token),
            body = body.toString(),
        )
        Log.d(TAG, "simkl sync/history -> HTTP ${response.status}")
    }
}

/// Build the provider-agnostic [MediaRef] for a play, resolving the engine `libraryId`-style identity ONCE
/// (the Apple `ScrobbleCoordinator` does the same): the IMDb `tt…` id where the Stremio id carries one,
/// else a numeric TMDB id. Returns null when neither is present (a magnet / kitsu-only id), so the player
/// simply does not scrobble.
///
///   - [metaId] is the engine meta id: `tt1234567` (movie or show) or `tmdb:12345`.
///   - [episode] is the chosen series episode ([Episode.season] / [Episode.episode]); null for a movie.
fun buildMediaRef(
    type: MediaType,
    metaId: String,
    episode: Episode?,
    title: String?,
    year: Int?,
): MediaRef? {
    val imdb = parseImdbId(metaId)
    val tmdb = parseTmdbId(metaId)
    if (imdb == null && tmdb == null) return null
    val isSeries = type == MediaType.SERIES
    return MediaRef(
        isSeries = isSeries,
        imdb = imdb,
        tmdb = tmdb,
        season = episode?.season?.takeIf { isSeries && it > 0 },
        episode = episode?.episode?.takeIf { isSeries && it > 0 },
        title = title,
        year = year,
    )
}

/// The IMDb `tt…` id from a Stremio meta/video id (`tt1234567`, or `tt1234567:1:2` for an episode: the
/// portion before the first colon is the show id). Null when the id is not IMDb-shaped.
private fun parseImdbId(metaId: String): String? {
    val head = metaId.substringBefore(':')
    return head.takeIf { it.startsWith("tt") && it.length > 2 && it.drop(2).all(Char::isDigit) }
}

/// The numeric TMDB id from a `tmdb:12345` (or `tmdb:12345:1:2`) Stremio id. Null when not TMDB-shaped.
private fun parseTmdbId(metaId: String): Int? {
    if (!metaId.startsWith("tmdb:")) return null
    return metaId.removePrefix("tmdb:").substringBefore(':').toIntOrNull()
}
