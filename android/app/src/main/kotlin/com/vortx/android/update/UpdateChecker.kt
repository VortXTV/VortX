package com.vortx.android.update

import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.core.content.FileProvider
import com.vortx.android.BuildConfig
import com.vortx.android.profile.ProfileStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Polls `vortx.tv/appcast.json` for a newer BUILD of the Android app and, once the user opts in, downloads
 * and VERIFIES the update end to end before anything reaches the package installer. Android is sideloaded
 * (no Play channel), so this manifest is how a user learns a new APK exists. The Android analogue of Apple's
 * `UpdateChecker.swift`, sharing its exact manifest URL, its per-platform manifest shape, and its two
 * UserDefaults keys.
 *
 * Trust chain (SEC-01 / SEC-07 remediation, enforced by [UpdatePolicy] and [ApkVerification]):
 *  1. The feed is fetched over HTTPS from a fixed URL; every redirect hop is validated against the host
 *     allow-list by hand ([HttpURLConnection.instanceFollowRedirects] is OFF, so no hop is ever implicit).
 *  2. The `android` feed entry must declare signed=true, a strictly newer build, an allow-listed HTTPS
 *     artifact URL, a positive byte size, the artifact SHA-256, and a signer fingerprint that normalizes to
 *     the pinned production certificate. Anything missing, mistyped, or hostile fails closed: no offer, no
 *     fallback URL, no browser hand-off.
 *  3. On "Get the update" the APK streams into the app-private cache with the declared size capped and
 *     hashed mid-stream; exact length AND digest must match the feed before the file is considered.
 *  4. Before installation the archive itself is opened: package/applicationId, build, marketing version,
 *     and the embedded signing certificate (exactly one signer, pinned SHA-256) must all match. Only then
 *     is the file handed over via FileProvider + ACTION_VIEW. An unverified installUrl is NEVER opened.
 *
 * Compares by BUILD ([BuildConfig.VERSION_CODE]), not the marketing version: betas share the marketing
 * version and differ only by build, so a version-only compare could never see a beta -> beta bump. Only a
 * NON-prerelease ("Latest") entry raises the notice, exactly like the Apple original.
 *
 * Signals, all StateFlows the Compose surfaces collect:
 *  - [available]: the PASSIVE banner state; cleared when up to date, skipped, or Later-ed for this session.
 *  - [prompt]: the ACTIVE once-per-launch popup; cleared by [later] (session) or [skipVersion] (durable).
 *  - [installPhase]: the secure download/verify pipeline state driving the dialog buttons.
 */
object UpdateChecker {

    /** Apple's exact keys, shared with every platform in the same prefs file. */
    const val LAST_CHECKED_KEY = "stremiox.update.lastChecked"
    const val DISMISSED_KEY = "stremiox.update.dismissedVersion"

    private const val TAG = "UpdateChecker"
    private const val MANIFEST_URL = "https://vortx.tv/appcast.json"
    private const val HOURLY_MS = 3_600_000L
    private const val TIMEOUT_MS = 12_000
    private const val APK_MIME = "application/vnd.android.package-archive"

    /** Status codes this client treats as a redirect; each hop is validated before it is followed. */
    private val REDIRECT_CODES = setOf(
        HttpURLConnection.HTTP_MOVED_PERM,
        HttpURLConnection.HTTP_MOVED_TEMP,
        303,
        307,
        308,
    )

    /** Private-cache subdirectory holding staged updates; never world-readable, never a shared location. */
    private const val STAGE_DIR = "update"

    private val FILE_PROVIDER_AUTHORITY = "${BuildConfig.APPLICATION_ID}.fileprovider"

    /** A build newer than the running one whose feed entry passed every trust gate, or null when current. */
    data class Release(
        val version: String,
        val build: Int,
        val name: String,
        val notes: String,
    ) {
        /** Stable key distinguishing betas that share [version]; the Later/Skip + once-per-launch memory. */
        val key: String get() = "$version.$build"
    }

    /** Progress of the secure download/verify pipeline started by [prepareInstall]. */
    sealed interface InstallPhase {
        /** Nothing running, nothing staged. */
        data object Idle : InstallPhase

        /** Streaming the artifact; received == total means the post-download gates are running. */
        data class Downloading(val received: Long, val total: Long) : InstallPhase

        /** Fully verified artifact staged in the private cache; [launchInstall] may hand it to the OS. */
        data class Ready(val releaseKey: String, val file: File) : InstallPhase

        /**
         * The pipeline stopped without producing an installable file. [retryable] marks transport trouble
         * (a Retry makes sense); a non-retryable failure is an integrity refusal and Retry will refuse again.
         */
        data class Failed(val reason: String, val retryable: Boolean) : InstallPhase
    }

    /**
     * In-session suppression memory: builds surfaced as the popup THIS process ("Later"-ed or shown) and the
     * session-scoped Later set. All access is locked because startup checks, manual checks, and UI actions
     * can overlap (SEC-08). Nothing here persists: relaunch forgets Later, which is the point of SEC-07.
     */
    internal class SurfaceMemory {
        private val lock = Any()
        private val promptedKeys = mutableSetOf<String>()
        private val laterKeys = mutableSetOf<String>()

        /** Whether the banner/dialog for this build may appear during this process. */
        fun shouldSurface(key: String): Boolean = synchronized(lock) { key !in laterKeys }

        /**
         * Claim the once-per-launch popup for this build; true only the FIRST time, and never after the user
         * Later-ed the build this session.
         */
        fun claimPopup(key: String): Boolean = synchronized(lock) {
            if (key in laterKeys) return@synchronized false
            promptedKeys.add(key)
        }

        /** Session-only dismissal of this build: survives until process death, never written to disk. */
        fun later(key: String) {
            synchronized(lock) { laterKeys.add(key) }
        }
    }

    private val _available = MutableStateFlow<Release?>(null)
    val available: StateFlow<Release?> = _available.asStateFlow()

    private val _prompt = MutableStateFlow<Release?>(null)
    val prompt: StateFlow<Release?> = _prompt.asStateFlow()

    private val _installPhase = MutableStateFlow<InstallPhase>(InstallPhase.Idle)
    val installPhase: StateFlow<InstallPhase> = _installPhase.asStateFlow()

    private val surface = SurfaceMemory()

    /** Feed spec behind [available]/[prompt]; the only source of download parameters for the pipeline. */
    private val offeredSpecLock = Any()
    private var offeredSpec: UpdatePolicy.VerifiedRelease? = null

    private val monitoring = AtomicBoolean(false)

    // SEC-08: every overlapping entry point serializes. checkMutex keeps polls/manual checks from racing
    // each other; installMutex keeps exactly one download alive; SurfaceMemory's own lock guards its sets.
    private val checkMutex = Mutex()
    private val installMutex = Mutex()
    @Volatile private var installJob: Job? = null

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
     * SEC-07 "Later": suppress this build for THE REST OF THIS PROCESS ONLY. Nothing is persisted, so the
     * reminder returns on the next launch until the user updates or explicitly skips the version.
     */
    fun later() {
        _prompt.value?.let { surface.later(it.key) }
        clearSignals()
    }

    /**
     * SEC-07 "Skip This Version": durable suppression of exactly this build key under [DISMISSED_KEY], the
     * explicit opt-out. A NEWER build always resurfaces; this one stays silent until then.
     */
    fun skipVersion(context: Context) {
        _prompt.value?.let { release ->
            prefs(context).edit().putString(DISMISSED_KEY, release.key).apply()
        }
        clearSignals()
    }

    /**
     * Begin the secure download/verify pipeline for the currently offered release. Single-flight: calls made
     * while a preparation is already running simply return; the [installPhase] flow reports progress. Never
     * opens any URL directly and never touches the installer: that is [launchInstall]'s job, after every
     * gate passed.
     */
    fun prepareInstall(context: Context) {
        val appContext = context.applicationContext
        if (installJob?.isActive == true) return
        installJob = scope.launch {
            installMutex.withLock {
                val spec = synchronized(offeredSpecLock) { offeredSpec } ?: return@withLock
                val current = _installPhase.value
                if (current is InstallPhase.Ready && current.releaseKey == spec.key) return@withLock
                runCatching { performPrepare(appContext, spec) }
                    .onFailure { error ->
                        Log.w(TAG, "update pipeline crashed: ${error.javaClass.simpleName}")
                        _installPhase.value = InstallPhase.Failed(
                            "The update could not be downloaded. Check your connection and try again.",
                            retryable = true,
                        )
                        deleteStaged(appContext)
                    }
            }
        }
    }

    /**
     * Hand a FULLY VERIFIED staged APK to the system installer via FileProvider + ACTION_VIEW. Returns
     * false (and installs nothing) unless the pipeline reached [InstallPhase.Ready], which by construction
     * means size, digest, package identity, version identity, and the pinned signer all matched.
     */
    fun launchInstall(context: Context): Boolean {
        val appContext = context.applicationContext
        val phase = _installPhase.value
        if (phase !is InstallPhase.Ready) return false
        val file = phase.file
        if (!file.isFile) {
            _installPhase.value = InstallPhase.Idle
            return false
        }
        val uri = runCatching {
            FileProvider.getUriForFile(appContext, FILE_PROVIDER_AUTHORITY, file)
        }.getOrNull() ?: return false
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, APK_MIME)
            .addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_ACTIVITY_NEW_TASK,
            )
        return runCatching { appContext.startActivity(intent) }
            .onFailure { Log.w(TAG, "installer hand-off failed: ${it.javaClass.simpleName}") }
            .isSuccess
            .also { handedOff -> if (handedOff) _installPhase.value = InstallPhase.Idle }
    }

    // ------------------------------------------------------------------
    // Feed check
    // ------------------------------------------------------------------

    private suspend fun check(context: Context) {
        checkMutex.withLock {
            val manifestText = fetchManifest() ?: return@withLock
            // Only a successful fetch stamps the clock, so a network blip does not silence notices.
            prefs(context).edit().putLong(LAST_CHECKED_KEY, System.currentTimeMillis()).apply()

            when (val decision = UpdatePolicy.evaluateFeed(
                manifestText = manifestText,
                currentBuild = BuildConfig.VERSION_CODE,
                currentFlavor = BuildConfig.FLAVOR,
                expectedApplicationId = BuildConfig.APPLICATION_ID,
            )) {
                is UpdatePolicy.UpdateDecision.None -> clearSignals()
                is UpdatePolicy.UpdateDecision.Malformed -> {
                    // Fail closed: log the refusal, offer nothing, never fall back to any other URL.
                    Log.w(TAG, "appcast rejected: ${decision.reason}")
                    clearSignals()
                }
                is UpdatePolicy.UpdateDecision.Offer -> offer(context, decision.release)
            }
        }
    }

    private fun offer(context: Context, spec: UpdatePolicy.VerifiedRelease) {
        val dismissed = prefs(context).getString(DISMISSED_KEY, null)
        if (spec.key == dismissed || !surface.shouldSurface(spec.key)) {
            // Skipped durably, or Later-ed earlier this process: no banner, no popup, until something changes.
            clearSignals()
            return
        }
        synchronized(offeredSpecLock) { offeredSpec = spec }
        val release = spec.toRelease()
        _available.value = release
        // Raise the popup once per launch per build.
        if (surface.claimPopup(spec.key)) {
            _prompt.value = release
        }
        // A staged artifact from an older offer is no longer the thing we verified metadata for.
        val phase = _installPhase.value
        if (phase is InstallPhase.Ready && phase.releaseKey != spec.key) {
            _installPhase.value = InstallPhase.Idle
        }
    }

    private fun clearSignals() {
        synchronized(offeredSpecLock) { offeredSpec = null }
        _available.value = null
        _prompt.value = null
    }

    private fun UpdatePolicy.VerifiedRelease.toRelease() = Release(
        version = version,
        build = build,
        name = name.ifBlank { "Update" },
        notes = notes,
    )

    // ------------------------------------------------------------------
    // Secure fetch (manifest + artifact share the same hop-by-hop policy)
    // ------------------------------------------------------------------

    private suspend fun fetchManifest(): String? = withContext(Dispatchers.IO) {
        try {
            openWithValidatedRedirects(URL(MANIFEST_URL)) { connection ->
                if (connection.responseCode != HttpURLConnection.HTTP_OK) return@openWithValidatedRedirects null
                val raw = connection.inputStream.use { input ->
                    readBounded(input, UpdatePolicy.MAX_MANIFEST_BYTES)
                }
                raw?.toString(Charsets.UTF_8)
            }
        } catch (_: Exception) {
            null
        }
    }

    /**
     * Open [initial] following redirects MANUALLY: automatic following is disabled, and each Location is
     * revalidated through [UpdatePolicy.resolveRedirect] (HTTPS + allow-list + no userinfo), up to
     * [UpdatePolicy.MAX_REDIRECT_HOPS]. The block receives the FINAL validated connection and its return
     * value becomes ours; any refused hop yields null instead of the response.
     */
    private fun <T> openWithValidatedRedirects(initial: URL, block: (HttpURLConnection) -> T?): T? {
        var url = initial
        var hops = 0
        while (true) {
            var connection: HttpURLConnection? = null
            try {
                connection = (url.openConnection() as HttpURLConnection).apply {
                    connectTimeout = TIMEOUT_MS
                    readTimeout = TIMEOUT_MS
                    instanceFollowRedirects = false
                    requestMethod = "GET"
                }
                val code = connection.responseCode
                if (code in REDIRECT_CODES) {
                    hops += 1
                    if (hops > UpdatePolicy.MAX_REDIRECT_HOPS) return null
                    val location = connection.getHeaderField("Location") ?: return null
                    val next = UpdatePolicy.resolveRedirect(url, location) ?: return null
                    url = next
                    continue
                }
                return block(connection)
            } catch (_: IOException) {
                return null
            } finally {
                runCatching { connection?.disconnect() }
            }
        }
    }

    // ------------------------------------------------------------------
    // Secure download + verify pipeline
    // ------------------------------------------------------------------

    /** Read at most [maxBytes]; null if the body overruns the cap (a bogus/huge response). */
    private fun readBounded(input: InputStream, maxBytes: Int): ByteArray? {
        val out = java.io.ByteArrayOutputStream()
        val buffer = ByteArray(8 * 1024)
        var total = 0
        while (true) {
            val read = input.read(buffer)
            if (read < 0) break
            total += read
            if (total > maxBytes) return null
            out.write(buffer, 0, read)
        }
        return out.toByteArray()
    }

    private suspend fun performPrepare(context: Context, spec: UpdatePolicy.VerifiedRelease) {
        withContext(Dispatchers.IO) {
            deleteStaged(context)
            val stageDir = File(context.cacheDir, STAGE_DIR)
            if (!stageDir.isDirectory && !stageDir.mkdirs()) {
                _installPhase.value = InstallPhase.Failed(
                    "Could not create a private staging area for the update.", retryable = true,
                )
                return@withContext
            }
            val partFile = File(stageDir, "update.apk.part")

            _installPhase.value = InstallPhase.Downloading(received = 0, total = spec.sizeBytes)
            val digest: String? = try {
                FileOutputStream(partFile).use { output ->
                    openWithValidatedRedirects(URL(spec.artifactUrl)) { connection ->
                        val announcedLength = connection.contentLengthLong
                        if (announcedLength >= 0 && announcedLength != spec.sizeBytes) return@openWithValidatedRedirects null
                        if (connection.responseCode != HttpURLConnection.HTTP_OK) return@openWithValidatedRedirects null
                        connection.inputStream.use { input ->
                            ApkVerification.copyExactWithDigest(input, output, spec.sizeBytes)
                        }
                    }
                }
            } catch (_: Exception) {
                null
            }

            if (digest == null || partFile.length() != spec.sizeBytes ||
                !UpdatePolicy.digestEquals(digest, spec.sha256)
            ) {
                val wrongContent = digest != null &&
                    partFile.length() == spec.sizeBytes &&
                    !UpdatePolicy.digestEquals(digest, spec.sha256)
                partFile.delete()
                _installPhase.value = if (wrongContent) {
                    // Right size, wrong bytes: a lying or tampered artifact, not a flaky network.
                    InstallPhase.Failed(
                        "The downloaded update did not match the published checksum. Installation blocked.",
                        retryable = false,
                    )
                } else {
                    InstallPhase.Failed(
                        "The update download did not complete. Check your connection and try again.",
                        retryable = true,
                    )
                }
                return@withContext
            }

            when (val verdict = ApkVerification.verify(
                apk = partFile,
                release = spec,
                expectedPackage = BuildConfig.APPLICATION_ID,
                inspector = ApkVerification.PackageManagerInspector(context),
            )) {
                is ApkVerification.Verdict.Rejected -> {
                    partFile.delete()
                    _installPhase.value = InstallPhase.Failed(verdict.reason, retryable = false)
                }
                is ApkVerification.Verdict.Accepted -> {
                    // Only now does a verified byte stream earn its final name.
                    val finalFile = File(stageDir, "VortX-${spec.version}-${spec.build}.apk")
                    val promoted = if (partFile.renameTo(finalFile)) finalFile else null
                    if (promoted == null) {
                        partFile.delete()
                        _installPhase.value = InstallPhase.Failed(
                            "The verified update could not be staged. Free up space and retry.",
                            retryable = true,
                        )
                    } else {
                        _installPhase.value = InstallPhase.Ready(spec.key, promoted)
                    }
                }
            }
        }
    }

    private fun deleteStaged(context: Context) {
        runCatching {
            File(context.cacheDir, STAGE_DIR).listFiles()?.forEach { it.delete() }
        }
    }

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(ProfileStore.PREFS_FILE, Context.MODE_PRIVATE)
}
