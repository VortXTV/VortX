package com.vortx.android.trickplay

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Rect
import android.util.Log
import com.vortx.android.net.VortXEdgeAuth
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.UUID
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.sqrt

/**
 * Community trickplay: scrub-preview thumbnails SHARED across users, like Netflix / Plex storyboards.
 * Android port of `app/SourcesShared/CommunityTrickplay.swift`, matched to the SAME Cloudflare Worker
 * (`trickplay.vortx.tv`) an Apple- or web-signed client hits, so a content key computed here indexes the
 * same pool.
 *
 * Two halves, both 100% fail-soft (any miss / error / offline silently leaves the player on its existing
 * per-device local capture, so there is never a regression):
 *
 *   1. FETCH-FIRST ([fetch]): on opening a title, compute the content key and GET
 *      `trickplay.vortx.tv/tp/{key}`. On a hit, download the sprite-sheet + WEBVTT index and serve scrub
 *      previews by cropping the sprite sub-rect for the scrubbed time.
 *
 *   2. UPLOAD-AFTER-GENERATE ([buildAndUpload]): after the device finishes generating its own local
 *      trickplay set, pack the captured JPEG frames into one sprite-sheet, build a matching WEBVTT index,
 *      and POST it (first-writer-wins). Runs off the main thread.
 *
 * CONTENT KEY (computed identically by the Worker):
 *   sha1("{imdb}:{season|0}:{episode|0}:{durationBucket}"),  durationBucket = floor(duration/10)*10.
 * Quality is deliberately NOT in the key; the duration bucket keeps different cuts from colliding.
 *
 * WIRING (follow-up, flagged per the parity assignment): this ships the CLIENT (content key + coverage +
 * fetch + upload + the tmdb->imdb resolver via [TmdbImdbResolver]). Two seams are NOT wired here and land
 * with a later player pass:
 *   - the SCRUBBER-PREVIEW read: the player scrubber calling [fetch] and cropping [Sheet.crop] onto the
 *     seek-bar thumbnail;
 *   - the CAPTURE feed: the player's local trickplay capture pipeline emitting [CapturedFrame]s into
 *     [buildAndUpload]. Android has no frame-capture pipeline yet, so nothing calls [buildAndUpload] until
 *     that lands.
 * Also NOT wired: the user setting gate + the RemoteConfig fleet kill-switch (`features.communityTrickplay`)
 * Apple reads; Android has neither surface yet, so [isEnabled] is a constant `true` (feature-on default).
 *
 * Privacy: uploads ONLY the generated sprite + vtt + the content key/metadata (imdb / season / episode /
 * duration-bucket). NEVER an account token, user id, or any PII; none is referenced here.
 */
object CommunityTrickplay {

    private const val TAG = "trickplay"

    /**
     * The trickplay edge base. Baked default `https://trickplay.vortx.tv` == Apple's shipping value
     * (`RemoteConfigDefaults.endpointTrickplay`); Android has no remote-config dial yet. `trickplay.vortx.tv`
     * is a [VortXEdgeAuth] gated host, so [sign] stamps the `/tp/<key>` GET + POST.
     */
    private const val BASE_URL = "https://trickplay.vortx.tv"

    /**
     * Feature gate. Apple ANDs a user setting (default on) with a RemoteConfig fleet kill-switch; Android
     * has neither surface yet (flagged above), so this is a plain feature-on default. Wire the setting +
     * kill-switch here when they land, exactly as Apple's `isEnabled` does.
     */
    const val isEnabled: Boolean = true

    // MARK: - Worker-mirrored constants (kept in sync with vortx-trickplay decision.ts + RemoteConfig defaults)

    /** The Worker's serve floor (`MIN_SERVE_COVERAGE`): a POST below this is discarded, so never sent. */
    private const val MIN_SERVE_COVERAGE = 0.02

    /** Sheet builder frame bounds (Apple `RemoteConfigDefaults.trickplayMinFrames` / `trickplayMaxFrames`). */
    private const val MIN_FRAMES = 1
    private const val MAX_FRAMES = 600

    /** Per-sheet tile budget (Apple `RemoteConfigDefaults.trickplayMaxTiles`), 3 MB-safe at 320x180/q0.7. */
    private const val MAX_TILES = 80

    /** Tile geometry + upload cap, identical to Apple's buildAndUpload literals. */
    private const val TILE_W = 320
    private const val TILE_H = 180
    private const val MAX_BYTES = 3 * 1024 * 1024

    /** floor(duration/10)*10, matching the Worker's durationBucket. */
    fun durationBucket(duration: Double): Int {
        if (!duration.isFinite() || duration <= 0.0) return 0
        return (floor(duration / 10.0) * 10.0).toInt()
    }

    /**
     * Coverage of a would-be upload, computed identically to the Worker's `computeCoverage`:
     * clamp[0,1]( frame_count / max(1, round(durationBucket / interval_s)) ). Guarded like the Worker
     * (0 on any non-positive input). Mirrors Apple `CommunityTrickplay.coverage`.
     */
    fun coverage(frameCount: Int, intervalS: Double, durationBucket: Int): Double {
        if (frameCount <= 0 || intervalS <= 0.0 || durationBucket <= 0) return 0.0
        val expected = maxOf(1, Math.round(durationBucket.toDouble() / intervalS).toInt())
        return minOf(1.0, maxOf(0.0, frameCount.toDouble() / expected.toDouble()))
    }

    /**
     * Whether the client should spend a POST on this capture. Returns false ONLY when we can positively
     * predict the Worker will reject it as below_coverage_threshold; an unknown duration/interval fails
     * OPEN (allow, let the Worker decide). Mirrors Apple `CommunityTrickplay.uploadCanStore`, including the
     * EXACT decimated-sheet prediction ([buildAndUpload]'s stride math) so a sheet the Worker would keep is
     * never skipped.
     */
    fun uploadCanStore(frameCount: Int, intervalS: Double, durationBucket: Int): Boolean {
        if (durationBucket <= 0 || intervalS <= 0.0 || frameCount <= 0) return true
        // Raw prediction: the sheet exactly as captured (no decimation).
        if (coverage(frameCount, intervalS, durationBucket) >= MIN_SERVE_COVERAGE) return true
        // Decimated prediction: mirror buildAndUpload's exact stride math reading the same maxTiles budget.
        val maxTiles = maxOf(1, MAX_TILES)
        if (frameCount <= maxTiles) return false
        val budget = minOf(frameCount, maxTiles)
        val stride = ceil(frameCount.toDouble() / budget.toDouble()).toInt()
        val decimatedCount = ceil(frameCount.toDouble() / stride.toDouble()).toInt()
        val decimatedInterval = intervalS * stride.toDouble()
        return coverage(decimatedCount, decimatedInterval, durationBucket) >= MIN_SERVE_COVERAGE
    }

    /**
     * sha1("{imdb}:{season|0}:{episode|0}:{durationBucket}") as lowercase hex. null when the imdb id is not
     * a real `tt…` id (ad-hoc paste-a-link plays have no shareable identity) or the duration bucket is 0.
     * Mirrors Apple `CommunityTrickplay.contentKey`.
     */
    fun contentKey(imdbId: String, season: Int?, episode: Int?, duration: Double): String? {
        if (!IMDB_ID_REGEX.matches(imdbId)) return null
        val bucket = durationBucket(duration)
        if (bucket <= 0) return null
        val raw = "$imdbId:${season ?: 0}:${episode ?: 0}:$bucket"
        val digest = MessageDigest.getInstance("SHA-1").digest(raw.toByteArray(Charsets.UTF_8))
        val sb = StringBuilder(digest.size * 2)
        for (b in digest) sb.append("%02x".format(b.toInt() and 0xFF))
        return sb.toString()
    }

    // MARK: - TMDB-keyed plays -> IMDb identity (delegated to the reusable resolver)

    /** Delegates to [TmdbImdbResolver.resolveImdbId]; kept here so callers have one trickplay entry point. */
    suspend fun resolveImdbId(context: Context, rawId: String, seriesHint: Boolean): String? =
        TmdbImdbResolver.resolveImdbId(context, rawId, seriesHint)

    /** Delegates to [TmdbImdbResolver.cachedImdbId]. */
    fun cachedImdbId(rawId: String): String? = TmdbImdbResolver.cachedImdbId(rawId)

    // MARK: - Fetch-first (L1 community layer)

    /**
     * A community sprite-sheet ready to crop. [bitmap] is the decoded sheet; [tileW]/[tileH] are the
     * per-tile size; [intervalS] the seconds between tiles. Mirrors Apple `CommunityTrickplay.Sheet`.
     */
    data class Sheet(
        val bitmap: Bitmap,
        val tileW: Int,
        val tileH: Int,
        val intervalS: Double,
        val frameCount: Int,
        val cols: Int,
    ) {
        /** The cropped tile nearest [time] (seconds), drawn from the sheet sub-rect. null if out of range. */
        fun crop(time: Double): Bitmap? {
            if (frameCount <= 0 || cols <= 0 || intervalS <= 0.0) return null
            val idx = maxOf(0, minOf(frameCount - 1, floor(time / intervalS).toInt()))
            val col = idx % cols
            val row = idx / cols
            val x = col * tileW
            val y = row * tileH
            if (x + tileW > bitmap.width || y + tileH > bitmap.height) return null
            return runCatching { Bitmap.createBitmap(bitmap, x, y, tileW, tileH) }.getOrNull()
        }
    }

    /**
     * GET the community set for [key] and, on a hit, download + decode the sprite. Returns null on any miss
     * / error (404, offline, decode failure) so the caller falls back to local generation. Never throws.
     * Mirrors Apple `CommunityTrickplay.fetch`.
     */
    suspend fun fetch(key: String): Sheet? = withContext(Dispatchers.IO) {
        var metaConn: HttpURLConnection? = null
        var spriteConn: HttpURLConnection? = null
        try {
            // 1) Signed metadata GET off the gated trickplay host.
            metaConn = (URL("$BASE_URL/tp/$key").openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                connectTimeout = 8_000
                readTimeout = 8_000
                useCaches = false
                setRequestProperty("accept", "application/json")
            }
            VortXEdgeAuth.sign(metaConn)
            if (metaConn.responseCode != 200) return@withContext null
            val text = metaConn.inputStream.bufferedReader(Charsets.UTF_8).use { it.readText() }
            val meta = runCatching { JSONObject(text) }.getOrNull() ?: return@withContext null

            val spriteUrl = meta.optString("sprite", "")
            val tileW = meta.optInt("tile_w", 0)
            val tileH = meta.optInt("tile_h", 0)
            val intervalS = meta.optDouble("interval_s", 0.0)
            val frameCount = meta.optInt("frame_count", 0)
            val cols = meta.optInt("cols", 0)
            if (frameCount <= 0 || cols <= 0 || tileW <= 0 || tileH <= 0 || intervalS <= 0.0 || spriteUrl.isEmpty()) {
                return@withContext null
            }

            // 2) The sprite is on the R2 public asset host, NOT a gated *.vortx.tv service host, so it stays
            // UNSIGNED (that route is exempt), matching Apple.
            spriteConn = (URL(spriteUrl).openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                connectTimeout = 12_000
                readTimeout = 12_000
                useCaches = false
            }
            if (spriteConn.responseCode != 200) return@withContext null
            val bytes = spriteConn.inputStream.use { it.readBytes() }
            val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: return@withContext null

            Sheet(bitmap = bitmap, tileW = tileW, tileH = tileH, intervalS = intervalS, frameCount = frameCount, cols = cols)
        } catch (_: IOException) {
            null
        } finally {
            metaConn?.disconnect()
            spriteConn?.disconnect()
        }
    }

    // MARK: - Upload-after-generate (sprite-sheet build + POST)

    /** One captured local frame: its JPEG bytes and the playback time (seconds) it was grabbed at. */
    data class CapturedFrame(val time: Double, val jpeg: ByteArray)

    /**
     * The outcome of an upload attempt, so the caller can log honestly instead of collapsing everything
     * that is not stored into "failed". Mirrors Apple `CommunityTrickplay.UploadOutcome`.
     */
    sealed interface UploadOutcome {
        data object Stored : UploadOutcome
        data class Rejected(val reason: String) : UploadOutcome
        data object Failed : UploadOutcome
    }

    /** The picked, decimated, encoded sheet buildAndUpload will POST. */
    private data class PickedSheet(val jpeg: ByteArray, val count: Int, val cols: Int, val interval: Double)

    /**
     * Build a sprite-sheet + WEBVTT index from the device's captured frames and POST it (first-writer-wins).
     * Runs off the main thread. Returns [UploadOutcome.Stored] only if the server stored a NEW set,
     * [UploadOutcome.Rejected] for a 200 the Worker declined, and [UploadOutcome.Failed] for a transport /
     * non-200 error or a local build failure that never POSTed. Never throws. Mirrors Apple
     * `CommunityTrickplay.buildAndUpload`.
     */
    suspend fun buildAndUpload(
        key: String,
        imdbId: String,
        season: Int?,
        episode: Int?,
        durationBucket: Int,
        srcHeight: Int,
        intervalS: Double,
        frames: List<CapturedFrame>,
    ): UploadOutcome = withContext(Dispatchers.Default) {
        if (!isEnabled) return@withContext UploadOutcome.Failed
        val sorted = frames.sortedBy { it.time }

        // The sheet builder needs >= 2 tiles; clamp the effective lower bound to 2 so a 1-frame set is
        // rejected up front instead of failing later at the floor with a misleading log.
        val minFrames = maxOf(2, MIN_FRAMES)
        if (sorted.size < minFrames || sorted.size > MAX_FRAMES) {
            Log.d(TAG, "buildAndUpload skipped: sorted=${sorted.size} below buildable floor $minFrames (need >=2 tiles)")
            return@withContext UploadOutcome.Failed
        }

        // Bound one sheet to a 3 MB-safe tile budget. DECIMATE evenly across the whole capture (never
        // truncate to the opening) so the sheet still spans the entire duration, just at a coarser scrub
        // interval. Start at the configured budget and, on a 3 MB overflow OR a compose/encode failure,
        // HALVE the budget and rebuild the WHOLE geometry together. Floor is 2 tiles.
        val maxTiles = maxOf(1, MAX_TILES)
        var budget = minOf(sorted.size, maxTiles)
        var picked: PickedSheet? = null
        while (budget >= 2) {
            val stride = if (sorted.size > budget) ceil(sorted.size.toDouble() / budget.toDouble()).toInt() else 1
            val effective = if (stride > 1) sorted.filterIndexed { i, _ -> i % stride == 0 } else sorted
            val effectiveInterval = intervalS * stride.toDouble()
            val cols = maxOf(1, ceil(sqrt(effective.size.toDouble())).toInt())
            val rows = ceil(effective.size.toDouble() / cols.toDouble()).toInt()

            val composed = renderSheetBitmap(effective, TILE_W, TILE_H, cols, rows)
            if (composed == null) {
                Log.d(TAG, "buildAndUpload compose FAILED tiles=${effective.size} cols=$cols rows=$rows budget=$budget -> re-decimate")
                if (budget == 2) break
                budget = maxOf(2, budget / 2)
                continue
            }
            var fit: ByteArray? = null
            for (q in intArrayOf(70, 50, 40)) {
                val d = encodeJpeg(composed, q)
                if (d != null && d.size <= MAX_BYTES) { fit = d; break }
            }
            composed.recycle()
            if (fit != null) {
                picked = PickedSheet(fit, effective.size, cols, effectiveInterval)
                break
            }
            Log.d(TAG, "buildAndUpload over 3MB at q40 tiles=${effective.size} cols=$cols rows=$rows budget=$budget -> re-decimate")
            if (budget == 2) break
            budget = maxOf(2, budget / 2)
        }
        val sheet = picked ?: run {
            Log.d(TAG, "buildAndUpload could not build a >=2-tile sheet under 3MB (sorted=${sorted.size}) -> dropped")
            return@withContext UploadOutcome.Failed
        }

        val vtt = buildVtt(sheet.count, sheet.cols, TILE_W, TILE_H, sheet.interval)
        val meta = JSONObject()
            .put("imdb", imdbId)
            .put("season", season ?: 0)
            .put("episode", episode ?: 0)
            .put("durationBucket", durationBucket)
            .put("frame_count", sheet.count)
            .put("tile_w", TILE_W)
            .put("tile_h", TILE_H)
            .put("interval_s", sheet.interval)
            .put("cols", sheet.cols)
            .put("src_height", srcHeight)
        post(key, sheet.jpeg, vtt, meta)
    }

    /**
     * Compose the frames into one sheet bitmap (each frame scaled-to-fill into its tile cell), top-to-bottom
     * so index order matches the vtt. Returns null on any decode/alloc failure. Android's Canvas origin is
     * top-left, so tiles lay out directly (no y-flip, unlike Apple's bottom-left CGContext). Mirrors Apple
     * `renderSheetImage`.
     */
    private fun renderSheetBitmap(frames: List<CapturedFrame>, tileW: Int, tileH: Int, cols: Int, rows: Int): Bitmap? {
        val sheetW = cols * tileW
        val sheetH = rows * tileH
        if (sheetW <= 0 || sheetH <= 0) return null
        val sheet = runCatching { Bitmap.createBitmap(sheetW, sheetH, Bitmap.Config.ARGB_8888) }.getOrNull() ?: return null
        val canvas = Canvas(sheet)
        canvas.drawColor(Color.BLACK)
        val paint = Paint().apply { isFilterBitmap = true; isAntiAlias = true }
        frames.forEachIndexed { i, frame ->
            val src = BitmapFactory.decodeByteArray(frame.jpeg, 0, frame.jpeg.size) ?: return@forEachIndexed
            val col = i % cols
            val row = i / cols
            val left = col * tileW
            val top = row * tileH
            canvas.drawBitmap(src, null, Rect(left, top, left + tileW, top + tileH), paint)
            src.recycle()
        }
        return sheet
    }

    /** JPEG-encode [bitmap] at [quality] (0..100). null on encode failure. */
    private fun encodeJpeg(bitmap: Bitmap, quality: Int): ByteArray? {
        val out = ByteArrayOutputStream()
        return if (bitmap.compress(Bitmap.CompressFormat.JPEG, quality, out)) out.toByteArray() else null
    }

    /**
     * WEBVTT mapping each tile window [t, t+interval) to `sprite#xywh=x,y,w,h` (Jellyfin/Plex web
     * convention; the app crops the sub-rect itself). Row-major, cols per row. Mirrors Apple `buildVTT`.
     */
    private fun buildVtt(frameCount: Int, cols: Int, tileW: Int, tileH: Int, intervalS: Double): String {
        val lines = ArrayList<String>(frameCount * 3 + 2)
        lines.add("WEBVTT")
        lines.add("")
        for (i in 0 until frameCount) {
            val start = i * intervalS
            val end = (i + 1) * intervalS
            val col = i % cols
            val row = i / cols
            val x = col * tileW
            val y = row * tileH
            lines.add("${vttTime(start)} --> ${vttTime(end)}")
            lines.add("sprite#xywh=$x,$y,$tileW,$tileH")
            lines.add("")
        }
        return lines.joinToString("\n")
    }

    private fun vttTime(seconds: Double): String {
        val total = seconds.toInt()
        val ms = ((seconds - total) * 1000).toInt()
        val h = total / 3600
        val m = (total % 3600) / 60
        val s = total % 60
        return "%02d:%02d:%02d.%03d".format(h, m, s, ms)
    }

    /**
     * POST the multipart body. [UploadOutcome.Stored] only on `{ ok:true, stored:true }`; a 200 the Worker
     * declined is [UploadOutcome.Rejected] (its `reason`); a transport error, a non-200, or a body we
     * cannot build is [UploadOutcome.Failed]. Signed for the gated host. Never throws. Mirrors Apple `post`.
     */
    private suspend fun post(key: String, sprite: ByteArray, vtt: String, meta: JSONObject): UploadOutcome =
        withContext(Dispatchers.IO) {
            val boundary = "vortx-tp-${UUID.randomUUID()}"
            val body = runCatching { multipartBody(boundary, sprite, vtt, meta.toString()) }.getOrNull()
                ?: return@withContext UploadOutcome.Failed

            var connection: HttpURLConnection? = null
            try {
                connection = (URL("$BASE_URL/tp/$key").openConnection() as HttpURLConnection).apply {
                    requestMethod = "POST"
                    connectTimeout = 20_000
                    readTimeout = 20_000
                    useCaches = false
                    doOutput = true
                    setRequestProperty("content-type", "multipart/form-data; boundary=$boundary")
                }
                VortXEdgeAuth.sign(connection)
                connection.outputStream.use { it.write(body) }

                val code = connection.responseCode
                val stream = if (code in 200..399) connection.inputStream else connection.errorStream
                val text = stream?.bufferedReader(Charsets.UTF_8)?.use { it.readText() }.orEmpty()
                val obj = runCatching { JSONObject(text) }.getOrNull()
                val ok = obj?.optBoolean("ok", false) == true
                val stored = obj?.optBoolean("stored", false) == true
                Log.d(TAG, "POST /tp/$key httpStatus=$code ok=$ok stored=$stored body=${text.take(200)}")
                when {
                    code != 200 -> UploadOutcome.Failed
                    stored -> UploadOutcome.Stored
                    else -> UploadOutcome.Rejected(obj?.optStringOrNull("reason") ?: "declined")
                }
            } catch (e: IOException) {
                Log.d(TAG, "POST /tp/$key httpStatus=err ok=false stored=false body=${e.toString().take(200)}")
                UploadOutcome.Failed
            } finally {
                connection?.disconnect()
            }
        }

    /** Assemble the multipart body: sprite file (image/jpeg) + vtt file (text/vtt) + a `meta` JSON field. */
    private fun multipartBody(boundary: String, sprite: ByteArray, vtt: String, metaJson: String): ByteArray {
        val out = ByteArrayOutputStream()
        fun write(s: String) = out.write(s.toByteArray(Charsets.UTF_8))
        // sprite file
        write("--$boundary\r\n")
        write("Content-Disposition: form-data; name=\"sprite\"; filename=\"sprite.jpg\"\r\n")
        write("Content-Type: image/jpeg\r\n\r\n")
        out.write(sprite)
        write("\r\n")
        // vtt file
        write("--$boundary\r\n")
        write("Content-Disposition: form-data; name=\"vtt\"; filename=\"index.vtt\"\r\n")
        write("Content-Type: text/vtt\r\n\r\n")
        write(vtt)
        write("\r\n")
        // meta field
        write("--$boundary\r\n")
        write("Content-Disposition: form-data; name=\"meta\"\r\n\r\n")
        write(metaJson)
        write("\r\n")
        write("--$boundary--\r\n")
        return out.toByteArray()
    }

    private fun JSONObject.optStringOrNull(key: String): String? {
        if (!has(key) || isNull(key)) return null
        return optString(key).ifBlank { null }
    }

    /** Real `tt…` id (Apple `^tt\d{6,}$`), the shareable-identity guard for [contentKey]. */
    private val IMDB_ID_REGEX = Regex("^tt\\d{6,}$")
}
