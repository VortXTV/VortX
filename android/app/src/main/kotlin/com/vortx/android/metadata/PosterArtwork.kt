package com.vortx.android.metadata

import android.content.Context
import android.net.Uri
import com.vortx.android.profile.ProfileStore
import java.net.URLEncoder
import java.util.Locale

/**
 * Poster / backdrop / logo artwork routing, the Kotlin port of Apple `app/SourcesShared/XRDBConfig.swift`,
 * `ERDBConfig.swift`, and the shared `PosterArtwork` router that lives alongside them. Every catalog and
 * detail poster/backdrop/logo URL is resolved through [PosterArtwork] so the active art provider is chosen
 * ONCE and the app never re-decides per call site.
 *
 * Precedence (identical to Apple): ERDB token/keyless render (when the user turned it on) wins, then the
 * VortX / XRDB baked-poster service (default ON), then the original add-on artwork. Every provider carries
 * the app's OWN art as `fb=` so the renderer fails soft to it on any miss (an id it cannot map, or a type
 * with no source art) rather than blanking the card.
 *
 * These values are NOT credentials (the XRDB admin key and the ERDB configurator secret live server-side),
 * so they persist in the SAME flat [android.content.SharedPreferences] keys the rest of the settings use
 * (`stremiox.xrdb.*` / `stremiox.erdb.*` / `stremiox.fanart.*`), byte-identical to the Apple `UserDefaults`
 * keys, and ride the existing cross-platform settings carriage. The ERDB `?fk=` fanart key is the only
 * value read from the secure store ([MetadataProviderKeys]); it never lands on device in plaintext beyond
 * that store and is passed as a query value exactly where Apple passes it (never in a path, never logged).
 */
object ArtworkPreferences {

    // Apple UserDefaults keys, byte-for-byte (XRDBConfig.swift / ERDBConfig.swift).
    const val XRDB_ENABLED_KEY = "stremiox.xrdb.enabled"
    const val XRDB_BASE_KEY = "stremiox.xrdb.baseURL"
    const val XRDB_ALIAS_KEY = "stremiox.xrdb.configAlias"
    const val ERDB_ENABLED_KEY = "stremiox.erdb.enabled"
    const val ERDB_TOKEN_KEY = "stremiox.erdb.token"
    const val ERDB_BASE_KEY = "stremiox.erdb.baseURL"
    const val ERDB_FANART_POSTERS_KEY = "stremiox.erdb.fanartPosters"
    const val FANART_ENABLED_KEY = "stremiox.fanart.enabled"

    @Volatile private var appContext: Context? = null

    /**
     * Wire the process application context once (from `VortXApplication.onCreate`), so the synchronous URL
     * builders can read the flat settings + the secure fanart key without threading a context to every call
     * site. Idempotent; a null context (never expected) leaves the defaults (XRDB on, ERDB/fanart off).
     */
    fun init(context: Context) {
        appContext = context.applicationContext
    }

    private fun prefs() = appContext
        ?.getSharedPreferences(ProfileStore.PREFS_FILE, Context.MODE_PRIVATE)

    fun bool(key: String, default: Boolean): Boolean = prefs()?.getBoolean(key, default) ?: default

    fun string(key: String): String = prefs()?.getString(key, "")?.trim().orEmpty()

    /** Persist a boolean setting on its flat key (the artwork toggles). No-op before [init]. */
    fun setBool(key: String, value: Boolean) {
        prefs()?.edit()?.putBoolean(key, value)?.apply()
    }

    /**
     * The user's fanart.tv key from the secure metadata store (Apple `ApiKeys.fanartKey`), or null when
     * unset. Read on demand (cheap encrypted read); used only for the ERDB `?fk=` fanart-poster query value
     * and by [FanartClient]. Never logged, never placed in a URL PATH.
     */
    fun fanartKey(): String? = appContext?.let { ctx ->
        MetadataProviderKeys(ctx).value(MetadataProviderKeys.Slot.FANART).trim().takeIf { it.isNotEmpty() }
    }

    /** The user's TMDB key from the secure metadata store (Apple `ApiKeys.tmdbKey`), or null when unset. */
    fun tmdbKey(): String? = appContext?.let { ctx ->
        MetadataProviderKeys(ctx).value(MetadataProviderKeys.Slot.TMDB).trim().takeIf { it.isNotEmpty() }
    }

    /** Percent-encode a query VALUE the way Apple's `.urlQueryAllowed` set does (spaces, reserved chars). */
    internal fun encodeQuery(value: String): String =
        runCatching { URLEncoder.encode(value, "UTF-8").replace("+", "%20") }.getOrDefault(value)
}

/**
 * XRDB (extendedratings.com / IbbyLabs) baked-poster IMAGE service, the Kotlin port of Apple `XRDB`. It
 * routes a poster/backdrop URL through `{base}/{type}/{id}?config={alias}&fb={original}`. Default base is
 * VortX's own keyless service (poster.vortx.tv), so ratings-on-posters ships on by default. Renderable only
 * for `tt…` / `tmdb:` ids; every other id scheme keeps its raw poster.
 */
object XRDB {
    const val DEFAULT_BASE = "https://poster.vortx.tv"

    /** On by default (Apple `enabled`): VortX hosts its own baked-poster service, so ratings work keyless. */
    val enabled: Boolean get() = ArtworkPreferences.bool(ArtworkPreferences.XRDB_ENABLED_KEY, true)

    /** enabled AND a usable base (Apple `isEnabled`); a non-empty non-http base disables it (null base). */
    val isEnabled: Boolean get() = enabled && normalizedBase() != null

    /**
     * The poster-service image URL for a title, or [fallback] when disabled / the id is not renderable.
     * [type] is "poster" / "backdrop" / "thumbnail" / "logo". Mirrors Apple `XRDB.imageURL`.
     */
    fun imageURL(type: String = "poster", id: String, fallback: String?): String? {
        if (!enabled) return fallback
        val base = normalizedBase() ?: return fallback
        val rid = renderableID(id) ?: return fallback
        var url = "$base/$type/$rid"
        val alias = ArtworkPreferences.string(ArtworkPreferences.XRDB_ALIAS_KEY)
        if (alias.isNotEmpty()) url += "?config=${ArtworkPreferences.encodeQuery(alias)}"
        if (!fallback.isNullOrEmpty()) {
            url += (if (url.contains("?")) "&" else "?") + "fb=${ArtworkPreferences.encodeQuery(fallback)}"
        }
        return url
    }

    /** True when the service can bake a rating onto this id (mirror of the [renderableID] gate). */
    fun canRender(id: String): Boolean = renderableID(id) != null

    /** `tt…` renders directly, `tmdb:` drops its prefix; every other scheme is not renderable. */
    private fun renderableID(id: String): String? = when {
        id.startsWith("tt") -> id
        id.startsWith("tmdb:") -> id.removePrefix("tmdb:")
        else -> null
    }

    /** Trimmed http(s) base, trailing slashes removed; defaults to poster.vortx.tv. null = invalid custom. */
    private fun normalizedBase(): String? {
        var s = ArtworkPreferences.string(ArtworkPreferences.XRDB_BASE_KEY)
        if (s.isEmpty()) return DEFAULT_BASE
        if (!(s.startsWith("http://") || s.startsWith("https://"))) return null
        while (s.endsWith("/")) s = s.dropLast(1)
        return s.ifEmpty { DEFAULT_BASE }
    }
}

/**
 * ERDB (Easy Ratings Database, easyratingsdb.com) baked posters/backdrops/LOGOS, the Kotlin port of Apple
 * `ERDB`. Token-based but the hosted erdb.vortx.tv is KEYLESS, so a tokenless request still returns
 * VortX-styled, rating-baked art. Opt-in (default OFF) because turning it on replaces EVERY poster,
 * backdrop and logo with a baked render; when on it takes precedence over the XRDB poster service.
 */
object ERDB {
    const val DEFAULT_BASE = "https://erdb.vortx.tv"

    val token: String get() = ArtworkPreferences.string(ArtworkPreferences.ERDB_TOKEN_KEY)

    /** Off by default (Apple `isActive`): turning it on replaces every poster/backdrop/logo with a bake. */
    val isActive: Boolean get() = ArtworkPreferences.bool(ArtworkPreferences.ERDB_ENABLED_KEY, false)

    /** Request fanart.tv posters (`?art=fanart`); posters only. Apple `fanartPosters`. */
    val fanartPosters: Boolean get() = ArtworkPreferences.bool(ArtworkPreferences.ERDB_FANART_POSTERS_KEY, false)

    /**
     * The renderer URL for a title, or [fallback] when inactive / the id is not renderable. [type] is
     * "poster" / "backdrop" / "logo" / "thumbnail". The id keeps its scheme (ERDB accepts the colons in the
     * path). Mirrors Apple `ERDB.imageURL`, including the `fb=` fail-soft contract.
     */
    fun imageURL(type: String, id: String, fallback: String?): String? {
        if (!isActive) return fallback
        val rid = renderableID(id) ?: return fallback
        val tk = token
        val tokenSeg = if (tk.isEmpty()) "" else "$tk/"
        var u = "${normalizedBase()}/$tokenSeg$type/$rid.jpg"
        if (type == "poster" && fanartPosters) {
            u += "?art=fanart"
            ArtworkPreferences.fanartKey()?.let { fk ->
                u += "&fk=${ArtworkPreferences.encodeQuery(fk)}"
            }
        }
        if (!fallback.isNullOrEmpty()) {
            u += (if (u.contains("?")) "&" else "?") + "fb=${ArtworkPreferences.encodeQuery(fallback)}"
        }
        return u
    }

    /** True when ERDB can bake a rating onto this id (mirror of the [renderableID] gate). */
    fun canRender(id: String): Boolean = renderableID(id) != null

    /** ERDB resolves IMDb, TMDB, TVDB and the anime id schemes; anything else keeps its original art. */
    private fun renderableID(id: String): String? {
        if (id.startsWith("tt")) return id
        for (scheme in RENDERABLE_SCHEMES) if (id.startsWith(scheme)) return id
        return null
    }

    private val RENDERABLE_SCHEMES =
        listOf("tmdb:", "tvdb:", "kitsu:", "anilist:", "mal:", "anidb:", "realimdb:")

    private fun normalizedBase(): String {
        var s = ArtworkPreferences.string(ArtworkPreferences.ERDB_BASE_KEY)
        if (s.isEmpty() || !(s.startsWith("http://") || s.startsWith("https://"))) return DEFAULT_BASE
        while (s.endsWith("/")) s = s.dropLast(1)
        return s.ifEmpty { DEFAULT_BASE }
    }
}

/**
 * fanart.tv as a DIRECT art provider, INDEPENDENT of ERDB (Apple `Fanart`). Off by default. When on, the
 * async art sites prefer fanart.tv's community clearlogo / poster / background (resolved via [FanartClient]
 * using the user's fanart.tv key) over the add-on art WITHOUT enabling ERDB's rating-baked renders.
 * Resolution is async (network) so it never blocks the synchronous [PosterArtwork] URL builders.
 */
object Fanart {
    val isEnabled: Boolean get() = ArtworkPreferences.bool(ArtworkPreferences.FANART_ENABLED_KEY, false)

    suspend fun logo(id: String, type: String): String? =
        if (!isEnabled) null else FanartClient.art(id, type).logo

    suspend fun poster(id: String, type: String): String? =
        if (!isEnabled) null else FanartClient.art(id, type).poster

    suspend fun background(id: String, type: String): String? =
        if (!isEnabled) null else FanartClient.art(id, type).background
}

/**
 * The single place every poster / backdrop / logo URL is resolved, the Kotlin port of Apple `PosterArtwork`.
 * Precedence: ERDB (when active) wins, then the VortX / XRDB poster service, then the original add-on art.
 */
object PosterArtwork {

    /** The raw, id-derivable art CDN hosts our baking service re-renders from (Apple `wrappableArtHosts`). */
    private val WRAPPABLE_ART_HOSTS = listOf("metahub.space", "tmdb.org")

    /**
     * PROVIDER-LEVEL: true when a baking provider is switched on, so a global caller must not draw its OWN
     * rating badge. Prefer [bakesRatings] with an id at a per-poster badge site. Apple `bakesRatings`.
     */
    val bakesRatings: Boolean get() = ERDB.isActive || XRDB.isEnabled

    /**
     * Whether the active provider will ACTUALLY bake a rating onto THIS id's poster (mirrors [poster]'s
     * precedence). A non-renderable id yields false so the caller draws its OWN badge instead of suppressing
     * it for a bake that never arrives. Apple `bakesRatings(forID:)`.
     */
    fun bakesRatings(forId: String?): Boolean {
        if (forId == null) return bakesRatings
        if (ERDB.isActive) return ERDB.canRender(forId)
        if (XRDB.isEnabled) return XRDB.canRender(forId)
        return false
    }

    /**
     * Poster image URL for a title id. Respects an add-on's OWN poster art (a non-wrappable host may already
     * carry baked ratings): only art we effectively source ourselves (metahub / TMDB CDN, or a blank
     * poster) is wrapped. ERDB token wins, then VortX / XRDB, then the original. Apple `poster`.
     */
    fun poster(id: String, fallback: String?): String? {
        if (!fallback.isNullOrEmpty() && !isWrappableRawArt(fallback)) return fallback
        return if (ERDB.isActive) ERDB.imageURL("poster", id, fallback) else XRDB.imageURL("poster", id, fallback)
    }

    /** Backdrop image URL. ERDB when active (it bakes ratings/quality on backdrops too), else the original. */
    fun backdrop(id: String, fallback: String?): String? =
        if (ERDB.isActive) ERDB.imageURL("backdrop", id, fallback) else fallback

    /** Title clearart LOGO URL. ERDB serves a rating-baked logo by id when active; else the caller's logo. */
    fun logo(id: String?, fallback: String?): String? {
        if (ERDB.isActive && id != null) {
            ERDB.imageURL("logo", id, null)?.let { return it }
        }
        return fallback
    }

    /**
     * Async logo resolution shared by every hero/detail logo slot: fanart.tv clearlogo first (when the
     * fanart toggle is on), else the synchronous ERDB-aware add-on/metahub logo. Apple `resolvedLogo`.
     */
    suspend fun resolvedLogo(id: String?, type: String, fallback: String?): String? {
        if (id == null) return fallback
        Fanart.logo(id, type)?.let { return it }
        return logo(id, fallback)
    }

    /** Whether [url] is one of the raw, id-derivable art forms our service can safely re-render from. */
    fun isWrappableRawArt(url: String?): Boolean {
        if (url.isNullOrEmpty()) return true
        val host = runCatching { Uri.parse(url).host }.getOrNull()?.lowercase(Locale.ROOT) ?: return false
        return WRAPPABLE_ART_HOSTS.any { host == it || host.endsWith(".$it") }
    }
}
