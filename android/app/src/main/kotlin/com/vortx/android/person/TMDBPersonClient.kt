package com.vortx.android.person

import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import com.vortx.android.net.VortXEdgeAuth
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.text.DateFormat
import java.text.SimpleDateFormat
import java.util.Locale

/// The Android port of the person / cast-credits slice of `app/SourcesShared/TMDBClient.swift`, kept to
/// exactly the calls the cast row + Person page need (full cast, person bio, person filmography, and the
/// tmdb -> tt resolve for opening a filmography title).
///
/// Every request goes through VortX's KEYLESS catalog edge (`catalogs.vortx.tv/3`), a cached, app-gated
/// TMDB proxy that injects OUR TMDB key server-side, so users with no key still get cast + person data.
/// This mirrors the keyless branch of the Apple `TMDBClient.get()` choke point; Android has no per-user
/// TMDB key surface, so it is edge-only (no "user key -> TMDB direct" branch). Each request is SIGNED via
/// [VortXEdgeAuth] so the gate can attribute the call to a real VortX build (the same HMAC contract the
/// rest of the app's gated hosts use).
///
/// FAIL-SOFT by contract, exactly like the Swift original: every call returns null / [] on a non-`tt`
/// id, a non-positive person id, no match, no data, a non-200, or any transport error -- a flaky edge
/// never breaks the detail page (the plain-name cast fallback stays) or the Person page.
object TMDBPersonClient {

    /// The keyless catalog edge base, path-compatible with TMDB's `/3` namespace (a request to
    /// `/person/{id}` hits `catalogs.vortx.tv/3/person/{id}`). This is the baked default Apple's
    /// `RemoteConfig.catalogsEndpoint` also ships; Android has no remote-config dial yet, so the shipping
    /// value is used directly. `catalogs.vortx.tv` is one of [VortXEdgeAuth]'s gated hosts, so [sign]
    /// stamps every request here.
    private const val EDGE_BASE = "https://catalogs.vortx.tv/3"

    private const val TIMEOUT_MS = 20_000
    private const val IMAGE_BASE = "https://image.tmdb.org/t/p"

    /// Full cast with character names + headshots for the detail page's cast rail, resolved from an IMDb
    /// id. Series use `aggregate_credits` so recurring roles across seasons resolve; movies use
    /// `/credits`. Ported from `TMDBClient.credits(imdbID:type:)` (the cast half; the Apple overview
    /// fallback is not needed on Android, whose synopsis comes from the engine meta). [] on anything but
    /// a genuine cast list, so the detail screen falls back to the engine's plain-name cast.
    suspend fun credits(imdbId: String, type: MediaType): List<CastMember> {
        if (!imdbId.startsWith("tt")) return emptyList()
        val media = mediaPath(type)
        val found = getJson("/find/$imdbId?external_source=imdb_id") ?: return emptyList()
        val resultsKey = if (media == "tv") "tv_results" else "movie_results"
        val first = found.optJSONArray(resultsKey)?.optJSONObject(0) ?: return emptyList()
        val tmdbId = first.optInt("id", 0).takeIf { it > 0 } ?: return emptyList()
        val path = if (media == "tv") "/tv/$tmdbId/aggregate_credits" else "/movie/$tmdbId/credits"
        val payload = getJson(path) ?: return emptyList()
        val cast = payload.optJSONArray("cast") ?: return emptyList()
        val out = ArrayList<CastMember>(cast.length())
        for (i in 0 until cast.length()) {
            val entry = cast.optJSONObject(i) ?: continue
            val name = entry.optStringOrNull("name") ?: continue
            // Movies carry `character`; TV aggregate credits carry `roles: [{ character }]`.
            val character = entry.optStringOrNull("character")
                ?: entry.optJSONArray("roles")?.optJSONObject(0)?.optStringOrNull("character")
            val profile = entry.optStringOrNull("profile_path")?.let { "$IMAGE_BASE/w185$it" }
            out += CastMember(
                id = entry.optInt("id", 0),
                name = name,
                character = character,
                profileUrl = profile,
            )
        }
        return out
    }

    /// Full person record via `/person/{id}` for the Person page header, ported from
    /// `TMDBClient.person(id:)`. [id] is the TMDB person id a [CastMember] carries. null on a
    /// non-positive id (a name-only fallback tile has no person), no match, or any error.
    suspend fun person(id: Int): PersonDetail? {
        if (id <= 0) return null
        val obj = getJson("/person/$id") ?: return null
        val name = obj.optStringOrNull("name") ?: return null
        return PersonDetail(
            name = name,
            biography = obj.optStringOrNull("biography"),
            birthday = prettyDate(obj.optStringOrNull("birthday")),
            placeOfBirth = obj.optStringOrNull("place_of_birth"),
            profileUrl = obj.optStringOrNull("profile_path")?.let { "$IMAGE_BASE/w342$it" },
            knownForDepartment = obj.optStringOrNull("known_for_department"),
        )
    }

    /// A person's filmography via `/person/{id}/combined_credits`, mapped onto the same [MetaItem] cards
    /// the hub rails use (id = "tmdb:<id>", type from `media_type`, poster from `poster_path`). Ported
    /// from `TMDBClient.personCredits(id:)`: deduped by id, entries with no poster or title dropped,
    /// sorted most-popular first then newest. [] on a non-positive id or any error.
    suspend fun personCredits(id: Int): List<MetaItem> {
        if (id <= 0) return emptyList()
        val obj = getJson("/person/$id/combined_credits") ?: return emptyList()
        val cast = obj.optJSONArray("cast") ?: return emptyList()
        val seen = HashSet<String>()
        data class Ranked(val item: MetaItem, val popularity: Double, val date: String)
        val ranked = ArrayList<Ranked>(cast.length())
        for (i in 0 until cast.length()) {
            val entry = cast.optJSONObject(i) ?: continue
            val tid = entry.optInt("id", 0).takeIf { it > 0 } ?: continue
            val media = entry.optStringOrNull("media_type") ?: "movie"
            if (media != "movie" && media != "tv") continue
            val name = (entry.optStringOrNull("title") ?: entry.optStringOrNull("name")) ?: continue
            val posterPath = entry.optStringOrNull("poster_path") ?: continue
            val cid = "tmdb:$tid"
            if (!seen.add(cid)) continue
            val date = entry.optStringOrNull("release_date") ?: entry.optStringOrNull("first_air_date") ?: ""
            ranked += Ranked(
                item = MetaItem(
                    id = cid,
                    type = if (media == "tv") MediaType.SERIES else MediaType.MOVIE,
                    name = name,
                    poster = "$IMAGE_BASE/w342$posterPath",
                    year = date.take(4).takeIf { it.length == 4 },
                ),
                popularity = entry.optDouble("popularity", 0.0),
                date = date,
            )
        }
        return ranked
            .sortedWith(compareByDescending<Ranked> { it.popularity }.thenByDescending { it.date })
            .map { it.item }
    }

    /// Resolve a filmography card's catalog id to an IMDb `tt` id before opening its detail, ported from
    /// `TMDBClient.imdbID(forCatalogID:type:)`. A `tt` id passes straight through; a `tmdb:<n>` id is
    /// resolved via `/external_ids` (the hub type guess can be wrong, so try the guessed media then the
    /// other -- external_ids is authoritative). Cinemeta meta + stream add-ons key on the `tt` id, so
    /// resolving BEFORE opening is what gives the pushed detail its hero, ratings, and sources. null on
    /// any failure -> the caller falls back to opening the unresolved id (a sparser but non-crashing page).
    suspend fun imdbId(forCatalogId: String, type: MediaType): String? {
        if (forCatalogId.startsWith("tt")) return forCatalogId
        val tmdbNumber = when {
            forCatalogId.startsWith("tmdb:") -> forCatalogId.removePrefix("tmdb:").toIntOrNull()
            else -> forCatalogId.toIntOrNull()
        } ?: return null
        val primary = mediaPath(type)
        val secondary = if (primary == "tv") "movie" else "tv"
        for (media in listOf(primary, secondary)) {
            val ext = getJson("/$media/$tmdbNumber/external_ids") ?: continue
            val imdb = ext.optStringOrNull("imdb_id")
            if (imdb != null && imdb.startsWith("tt")) return imdb
        }
        return null
    }

    private fun mediaPath(type: MediaType): String = if (type == MediaType.SERIES) "tv" else "movie"

    /// GET [path] off the keyless edge and decode a JSON object. Signs the request via [VortXEdgeAuth]
    /// (stamped after the method + URL are set, before the connection opens, per the signer's contract).
    /// Runs on [Dispatchers.IO]; a non-200 or any transport error resolves to null so every caller stays
    /// fail-soft. [path] is a leading-slash TMDB path (`/person/123`), appended to the `/3` edge base.
    private suspend fun getJson(path: String): JSONObject? = withContext(Dispatchers.IO) {
        var connection: HttpURLConnection? = null
        try {
            val url = URL(EDGE_BASE + path)
            connection = (url.openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                connectTimeout = TIMEOUT_MS
                readTimeout = TIMEOUT_MS
                useCaches = false
            }
            // Stamp X-VX-* for the gated catalogs host (no-op for any other host), right before send.
            VortXEdgeAuth.sign(connection)
            if (connection.responseCode != 200) return@withContext null
            val text = connection.inputStream.bufferedReader(Charsets.UTF_8).use { it.readText() }
            runCatching { JSONObject(text) }.getOrNull()
        } catch (_: IOException) {
            null
        } finally {
            connection?.disconnect()
        }
    }

    /// ISO `yyyy-MM-dd` -> a medium localized date ("Mar 1, 1970"), mirroring the Apple `prettyDate`.
    /// null for a null/blank/unparseable value, so the header's born line simply omits it.
    private fun prettyDate(iso: String?): String? {
        if (iso.isNullOrBlank()) return null
        val parser = SimpleDateFormat("yyyy-MM-dd", Locale.US)
        val date = runCatching { parser.parse(iso.take(10)) }.getOrNull() ?: return null
        return DateFormat.getDateInstance(DateFormat.MEDIUM, Locale.getDefault()).format(date)
    }

    /// Like `optString` but null (not "") for a missing or JSON-null value, matching the codebase's
    /// existing `optStringOrNull` helpers (EngineState / DebridResolver) so optional fields stay absent.
    private fun JSONObject.optStringOrNull(key: String): String? {
        if (!has(key) || isNull(key)) return null
        return optString(key).ifBlank { null }
    }
}
