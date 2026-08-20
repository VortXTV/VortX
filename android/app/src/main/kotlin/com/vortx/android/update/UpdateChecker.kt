package com.vortx.android.update

import android.content.Context
import com.vortx.android.BuildConfig
import com.vortx.android.profile.ProfileStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Polls `vortx.tv/appcast.json` for a newer BUILD of the Android app and remembers it so the UI can offer an
 * update. Android is sideloaded (no Play channel), so this manifest is how a user learns a new APK exists.
 * The Android analogue of Apple's `UpdateChecker.swift`, sharing its exact manifest URL, its per-platform
 * manifest shape, and its two UserDefaults keys.
 *
 * Compares by BUILD ([BuildConfig.VERSION_CODE]), not the marketing version: betas share the marketing
 * version and differ only by build, so a version-only compare could never see a beta -> beta bump. Only a
 * NON-prerelease ("Latest") entry raises the launch popup, exactly like the Apple original.
 *
 * Two signals, both exposed as StateFlows the Compose surfaces collect:
 *  - [available]: the PASSIVE signal a newer stable build exists; the Settings/About "update available"
 *    banner reads it. Cleared when up to date or when the user dismissed this build.
 *  - [prompt]: the ACTIVE once-per-launch popup. Set for a newer build not yet surfaced THIS process, so the
 *    modal appears automatically at launch (and again only for a genuinely newer build); cleared by
 *    [dismissPrompt].
 */
object UpdateChecker {

    /** Apple's exact keys, shared with every platform in the same prefs file. */
    const val LAST_CHECKED_KEY = "stremiox.update.lastChecked"
    const val DISMISSED_KEY = "stremiox.update.dismissedVersion"

    private const val MANIFEST_URL = "https://vortx.tv/appcast.json"
    private const val RELEASES_URL = "https://github.com/VortXTV/VortX/releases/latest"
    private const val HOURLY_MS = 3_600_000L
    private const val TIMEOUT_MS = 12_000
    private const val MAX_MANIFEST_BYTES = 512 * 1024

    /** A build newer than the running one that the user has not dismissed, or null when up to date. */
    data class Release(
        val version: String,
        val build: Int,
        val name: String,
        val notes: String,
        val installUrl: String,
    ) {
        /** Stable key distinguishing betas that share [version]; the dismiss + once-per-launch memory. */
        val key: String get() = "$version.$build"
    }

    private val _available = MutableStateFlow<Release?>(null)
    val available: StateFlow<Release?> = _available.asStateFlow()

    private val _prompt = MutableStateFlow<Release?>(null)
    val prompt: StateFlow<Release?> = _prompt.asStateFlow()

    /**
     * Builds surfaced as the popup during THIS process. In-memory on purpose: it suppresses a second popup
     * for the same build this session but resets on relaunch, so the user is reminded once per launch until
     * they update. (The banner's dismissal, by contrast, IS persisted under [DISMISSED_KEY].)
     */
    private val promptedKeys = mutableSetOf<String>()

    private val monitoring = AtomicBoolean(false)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /**
     * Start polling. Idempotent: the first call kicks an immediate check then an hourly re-check for the
     * process's life; later calls only run one more immediate check (so a returning surface re-checks
     * promptly). Safe to call from every launcher's process start.
     */
    fun start(context: Context) {
        val appContext = context.applicationContext
        if (!monitoring.compareAndSet(false, true)) {
            scope.launch { check(appContext) }
            return
        }
        scope.launch {
            while (true) {
                check(appContext)
                delay(HOURLY_MS)
            }
        }
    }

    /**
     * The user dismissed the popup ("Later" or after "Get the update"). Persist the build key under the
     * banner's key so the passive banner stops nagging for the same build too, and clear both live signals.
     */
    fun dismissPrompt(context: Context) {
        _prompt.value?.let { release ->
            prefs(context).edit().putString(DISMISSED_KEY, release.key).apply()
        }
        _prompt.value = null
        _available.value = null
    }

    private suspend fun check(context: Context) {
        val manifest = fetchManifest() ?: return
        // Only a successful fetch stamps the clock, so a network blip does not silence notices.
        prefs(context).edit().putLong(LAST_CHECKED_KEY, System.currentTimeMillis()).apply()

        val entry = manifest.optJSONObject("android")
        if (entry == null) {
            clear()
            return
        }
        val build = entry.optInt("build", 0)
        if (build <= BuildConfig.VERSION_CODE) {
            clear()
            return
        }
        // Only nudge for a stable ("Latest") release; a prerelease entry stays silent (testers sideload
        // betas by hand), exactly like Apple.
        if (entry.optBoolean("prerelease", false)) {
            clear()
            return
        }

        val release = Release(
            version = entry.optStringOrNull("version") ?: "",
            build = build,
            name = entry.optStringOrNull("name") ?: (entry.optStringOrNull("version") ?: "Update"),
            notes = entry.optStringOrNull("notes") ?: "",
            installUrl = entry.optStringOrNull("apk")
                ?: entry.optStringOrNull("url")
                ?: entry.optStringOrNull("altstore")
                ?: RELEASES_URL,
        )

        val dismissed = prefs(context).getString(DISMISSED_KEY, null)
        if (release.key == dismissed) {
            // The user already dismissed this exact build: no banner, no popup, until a newer one ships.
            clear()
            return
        }
        _available.value = release
        // Raise the popup once per launch per build.
        if (promptedKeys.add(release.key)) {
            _prompt.value = release
        }
    }

    private fun clear() {
        _available.value = null
        _prompt.value = null
    }

    private suspend fun fetchManifest(): JSONObject? = withContext(Dispatchers.IO) {
        var connection: HttpURLConnection? = null
        try {
            connection = (URL(MANIFEST_URL).openConnection() as HttpURLConnection).apply {
                connectTimeout = TIMEOUT_MS
                readTimeout = TIMEOUT_MS
                instanceFollowRedirects = true
                requestMethod = "GET"
            }
            if (connection.responseCode != HttpURLConnection.HTTP_OK) return@withContext null
            val bytes = connection.inputStream.use { input -> readBounded(input) } ?: return@withContext null
            runCatching { JSONObject(bytes.toString(Charsets.UTF_8)) }.getOrNull()
        } catch (_: Exception) {
            null
        } finally {
            runCatching { connection?.disconnect() }
        }
    }

    /** Read at most [MAX_MANIFEST_BYTES]; null if the body overruns the cap (a bogus/huge response). */
    private fun readBounded(input: java.io.InputStream): ByteArray? {
        val out = java.io.ByteArrayOutputStream()
        val buffer = ByteArray(8 * 1024)
        var total = 0
        while (true) {
            val read = input.read(buffer)
            if (read < 0) break
            total += read
            if (total > MAX_MANIFEST_BYTES) return null
            out.write(buffer, 0, read)
        }
        return out.toByteArray()
    }

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(ProfileStore.PREFS_FILE, Context.MODE_PRIVATE)

    private fun JSONObject.optStringOrNull(key: String): String? {
        if (!has(key) || isNull(key)) return null
        return optString(key).ifBlank { null }
    }
}
