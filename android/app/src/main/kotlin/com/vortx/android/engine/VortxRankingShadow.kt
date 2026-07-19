package com.vortx.android.engine

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import com.vortx.android.model.StreamGroup
import com.vortx.android.model.StreamSource
import com.vortx.android.sources.SourcePrefsSnapshot
import com.vortx.android.sources.SourcePreferencesStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject

/// The vortx-core SHADOW ranking lane (engine cutover Phase 7 slice 1, the Android analogue of the
/// Apple VortxBridge shadow): behind a DEFAULT-OFF flag, every source rank ALSO runs through the
/// own-engine kernel (`{"kind":"streams"}` resolve over [VortxCore]) and the two orders are
/// compared and LOGGED. It changes NOTHING the app shows:
///
///   * flag OFF (the default): [enabled] is false and the call site's guard is a single volatile
///     read; no library load, no JNI call, no allocation. The app is byte-identical in behavior.
///   * flag ON: the compare runs FIRE-AND-FORGET on its own scope, off the rank path; the ranked
///     list the UI renders is still [StreamRanking]'s, always. The only output is a logcat line.
///
/// What is compared: the SAME filtered stream universe [StreamRanking] ranks (user filters applied,
/// YouTube trailers excluded), as one flat list. The Kotlin order is the app's own scorer
/// ([StreamRanking.score] descending, stable); the engine order is the kernel's `ranked[].raw_index`
/// under its DEFAULT ranking profile with the cached-availability vector supplied from
/// [StreamRanking.isCachedSource]. The two rankers own different preference models (the Kotlin side
/// folds the full user-preference layer; the shadow engine handle carries the frozen default video
/// profile), so a non-zero diff under customized preferences is EXPECTED signal, not a bug: the
/// readout measures where the kernels agree, feeding the parity work before any cutover.
object VortxRankingShadow {

    private const val TAG = "VortxShadowRank"

    /// The flag key, in the app's flat `vortx.*` settings namespace (the same `vortx_settings` file
    /// every other streaming preference lives in). Default OFF. The Android equivalent of Apple's
    /// `vortxShadowRanking` toggle.
    const val FLAG_KEY = "vortx.engine.shadowRanking"

    /// Bound the JSON we build per compare so a 1200+ stream title cannot make the shadow lane
    /// allocate megabytes; the head of the ranked order is where agreement matters most anyway.
    private const val MAX_STREAMS = 512

    /// The flag, mirrored into a volatile so the call-site guard costs one field read. Private set:
    /// flips only via [configure]'s SharedPreferences read + change listener.
    @Volatile
    var enabled: Boolean = false
        private set

    /// STRONG reference to the prefs listener: SharedPreferences holds listeners weakly, so a local
    /// would be collected and the flag would silently stop tracking Settings edits.
    private var prefsListener: SharedPreferences.OnSharedPreferenceChangeListener? = null

    /// The shadow lane's own scope: compares never block the rank path even when the flag is ON.
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    /// The lazy shadow engine handle (0 = not created / unavailable). Process-lifetime, like the
    /// main engine's native singletons; never freed (the OS reclaims it with the process).
    private var handle: Long = 0
    private var handleTried = false

    /// One-shot warn guards so a broken lane logs once, not once per rank.
    @Volatile private var warnedUnavailable = false

    /// Read the flag and start tracking edits. Idempotent; call once with any context (the
    /// application context is taken). Reading is the ONLY thing this does: it never loads the
    /// native library (that happens lazily on the first enabled compare).
    @Synchronized
    fun configure(context: Context) {
        if (prefsListener != null) return
        val prefs = context.applicationContext
            .getSharedPreferences(SourcePreferencesStore.PREFS_FILE, Context.MODE_PRIVATE)
        enabled = prefs.getBoolean(FLAG_KEY, false)
        val listener = SharedPreferences.OnSharedPreferenceChangeListener { p, key ->
            if (key == FLAG_KEY) enabled = p.getBoolean(FLAG_KEY, false)
        }
        prefs.registerOnSharedPreferenceChangeListener(listener)
        prefsListener = listener
    }

    /// Fire-and-forget shadow compare over the SAME inputs [StreamRanking.rankedGroups] just
    /// ranked: the pre-rank [groups] and the frozen [prefs] snapshot. Call site guards on
    /// [enabled]; this re-checks defensively and never throws into the caller.
    fun compareAsync(groups: List<StreamGroup>, prefs: SourcePrefsSnapshot) {
        if (!enabled) return
        scope.launch {
            runCatching { compareAndLog(groups, prefs) }
                .onFailure { Log.w(TAG, "shadow compare failed (app ranking unaffected)", it) }
        }
    }

    // ---- The compare (shadow scope; one at a time per the handle discipline) ----

    @Synchronized
    private fun compareAndLog(groups: List<StreamGroup>, prefs: SourcePrefsSnapshot) {
        if (!VortxCore.isAvailable()) {
            warnOnce("libvortx_ffi.so not packaged; shadow lane idle")
            return
        }
        // The same stream universe the Kotlin ranker ordered: user filters applied, trailers out.
        val input = StreamRanking.applyUserFilters(groups, prefs)
            .flatMap { it.streams }
            .filter { !it.isYouTubeTrailer }
            .take(MAX_STREAMS)
        if (input.size < 2) return // nothing to disagree about

        // Kotlin's order over that universe: the app's own scorer, descending, stable on ties
        // (identical scores to what rankedGroups/best used; score() is memoized so this is cheap).
        val kotlinOrder = input.indices.sortedWith(
            compareByDescending<Int> { StreamRanking.score(input[it], prefs) }.thenBy { it },
        )

        val engineHandle = ensureHandle() ?: run {
            warnOnce("vortx-core init_runtime returned 0; shadow lane idle")
            return
        }
        val request = JSONObject()
            .put("kind", "streams")
            .put("streams", JSONArray().also { arr -> input.forEach { arr.put(engineStreamJson(it)) } })
            .put("cached", JSONArray().also { arr -> input.forEach { arr.put(StreamRanking.isCachedSource(it)) } })

        val responseJson = VortxCore.nativeResolveJson(engineHandle, request.toString())
            ?: run { warnOnce("vortx-core resolve returned null (native panic guard)"); return }
        val response = JSONObject(responseJson)
        if (response.optString("kind") != "streams") {
            Log.w(TAG, "unexpected resolve response kind=${response.optString("kind")} error=${response.optString("error")}")
            return
        }
        val ranked = response.getJSONArray("ranked")
        val engineOrder = ArrayList<Int>(ranked.length())
        for (i in 0 until ranked.length()) engineOrder.add(ranked.getJSONObject(i).getInt("raw_index"))

        // Agreement readout: positional diff over the two permutations of the same input, plus the
        // signals that matter most for a cutover (top pick, top 5).
        val n = minOf(kotlinOrder.size, engineOrder.size)
        var diff = 0
        for (i in 0 until n) if (kotlinOrder[i] != engineOrder[i]) diff++
        val top1 = n > 0 && kotlinOrder[0] == engineOrder[0]
        val top5 = kotlinOrder.take(5).toSet() == engineOrder.take(5).toSet()
        Log.i(
            TAG,
            "shadow rank n=$n agree=${n - diff}/$n diff=$diff top1Agree=$top1 top5SetAgree=$top5 " +
                "kotlinTop=${input.getOrNull(kotlinOrder.firstOrNull() ?: -1)?.title?.take(60)} " +
                "engineTop=${input.getOrNull(engineOrder.firstOrNull() ?: -1)?.title?.take(60)}",
        )
    }

    /// Create the shadow engine once (0 stays 0 after a failed try; [warnOnce] reported it).
    private fun ensureHandle(): Long? {
        if (handle != 0L) return handle
        if (handleTried) return null
        handleTried = true
        handle = VortxCore.nativeInitRuntime("""{"ownerId":"shadow","ownerName":"Shadow"}""")
        return if (handle != 0L) handle else null
    }

    /// One engine-wire stream document for [s], on the protocol's camelCase keys. The free-text
    /// fields are folded the way [StreamRanking]'s own qualityText assembles them (title +
    /// description + quality + filename), so the compare measures RANKING logic, not which field an
    /// add-on happened to put its release tags in.
    private fun engineStreamJson(s: StreamSource): JSONObject {
        val o = JSONObject()
        s.url?.let { o.put("url", it) }
        s.ytId?.let { o.put("ytId", it) }
        s.infoHash?.let { o.put("infoHash", it) }
        s.fileIdx?.let { o.put("fileIdx", it) }
        s.externalUrl?.let { o.put("externalUrl", it) }
        o.put("title", s.title)
        listOfNotNull(s.description, s.quality, s.filename)
            .joinToString(" ")
            .takeIf { it.isNotBlank() }
            ?.let { o.put("description", it) }
        return o
    }

    private fun warnOnce(message: String) {
        if (warnedUnavailable) return
        warnedUnavailable = true
        Log.w(TAG, message)
    }
}
