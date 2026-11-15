package com.vortx.android.diagnostics

import android.content.Context
import android.content.SharedPreferences
import android.os.Build
import com.vortx.android.BuildConfig
import com.vortx.android.profile.ProfileStore
import java.io.File
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.Callable
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Durable diagnostics, the Android counterpart of Apple's two channels (crashes come from [CrashReporter]):
 *  - `diagnostics.log` is ALWAYS ON for every user, about 512 KiB in the app cache (Apple `DiagnosticsLog`).
 *  - `vortx-diag.log` is OPT-IN through Settings > Diagnostic logging, on Apple's own key
 *    [PROBE_KEY], a rolling ~3 MiB file and the one a user exports (Apple `VXProbe`).
 *
 * Every line is formed by [DiagnosticRedaction.durableLine], and the export runs every line through the
 * current rules again, so bytes an older build wrote are still scrubbed on the way out. Writes happen on one
 * background thread: a caller (often the main thread or a player callback) never blocks on disk.
 */
object DiagnosticsLog {
    /** The Settings "Diagnostic logging" toggle, the same key Apple uses. */
    const val PROBE_KEY = "stremiox.probeLogging"
    /** The only directory the FileProvider may share from: staged, already-scrubbed export copies. */
    const val EXPORT_DIR = "diagnostics-export"

    private const val ALWAYS_ON_FILE = "diagnostics.log"
    private const val PROBE_FILE = "vortx-diag.log"
    private const val ALWAYS_ON_LIMIT = 512L * 1024
    private const val PROBE_MAX = 3L * 1024 * 1024
    private const val PROBE_KEEP = 2L * 1024 * 1024
    /** Always-on lines included in one export, so a dense breadcrumb cannot crowd out the probe log. */
    private const val DIAGNOSTICS_TAIL_LINES = 400

    private val writer = Executors.newSingleThreadExecutor { task ->
        Thread(task, "vortx-diagnostics").apply { isDaemon = true }
    }
    private val stamp = ThreadLocal.withInitial { SimpleDateFormat("yyyy-MM-dd HH:mm:ss.SSS", Locale.US) }

    @Volatile private var cacheDir: File? = null
    @Volatile private var prefs: SharedPreferences? = null

    /** Called once from Application.onCreate; logging before it is a silent no-op. */
    fun install(context: Context) {
        val app = context.applicationContext
        prefs = app.getSharedPreferences(ProfileStore.PREFS_FILE, Context.MODE_PRIVATE)
        cacheDir = app.cacheDir
        log("app", "launch version=${BuildConfig.VERSION_NAME} build=${BuildConfig.VERSION_CODE} " +
            "edition=${BuildConfig.FLAVOR} android=${Build.VERSION.SDK_INT} logging=${if (probeEnabled) "on" else "off"}")
    }

    /** Read live, so the Settings toggle takes effect without a relaunch. */
    val probeEnabled: Boolean get() = prefs?.getBoolean(PROBE_KEY, false) == true

    fun setProbeEnabled(enabled: Boolean) {
        prefs?.edit()?.putBoolean(PROBE_KEY, enabled)?.apply()
        log("diagnostics", "probe_logging=${if (enabled) "on" else "off"}")
    }

    /** One always-on line, mirrored into the exportable log while Diagnostic logging is on. Never blocks. */
    fun log(category: String, message: String) {
        val dir = cacheDir ?: return
        val line = line(category, message)
        val mirror = probeEnabled
        writer.execute {
            appendAlwaysOn(dir, line)
            if (mirror) appendProbe(dir, line)
        }
    }

    /** Verbose detail written only while Diagnostic logging is on; [message] is built only then. */
    fun probe(category: String, message: () -> String) {
        if (!probeEnabled) return
        val dir = cacheDir ?: return
        val line = line(category, message())
        writer.execute { appendProbe(dir, line) }
    }

    /** True when there is anything to export (either channel has content). */
    fun hasContent(): Boolean = snapshot().let { (probe, always) -> probe.isNotBlank() || always.isNotBlank() }

    /**
     * Flush queued writes and stage a fresh scrubbed file. Never write to a previously granted URI.
     */
    fun stageExport(context: Context): File = stageExport(context, exportBody())

    /** Before a profile opens, export only fixed account-recovery events and device/build details. */
    internal fun stageAccountRecoveryExport(context: Context): File =
        stageExport(context, accountRecoveryExportBody(header(), snapshot().second))

    private fun stageExport(context: Context, body: String): File {
        val dir = File(context.applicationContext.cacheDir, EXPORT_DIR).apply { mkdirs() }
        val cutoff = System.currentTimeMillis() - TimeUnit.DAYS.toMillis(1)
        dir.listFiles()?.filter { it.lastModified() < cutoff }?.forEach { it.delete() }
        return File.createTempFile("VortX-diagnostics-", ".txt", dir).apply { writeText(body) }
    }

    internal fun accountRecoveryExportBody(header: String, alwaysOnContents: String): String = buildString {
        append("Account recovery diagnostics\n").append(header).append('\n')
        // Map known events back to constants. Never copy line arguments, message text or timestamps
        // from retained logs into this limited export, even when those logs were already scrubbed.
        val events = alwaysOnContents.lineSequence().mapNotNull { line ->
            val event = line.substringAfter(" [", "")
            when {
                event.startsWith("native-profiles] restore result=failed stage=legacy_preparation ") ->
                    "Legacy profile restore failed during preparation"
                event.startsWith("native-profiles] prepare result=ready ") ->
                    "Legacy profile restore preparation completed"
                event == "native-account] sync result=failed reason=backup_sign_in_required" ->
                    "The backup service requires a fresh sign-in"
                event == "native-account] sync result=failed reason=native_linkage_unavailable" ->
                    "The native account engine could not be loaded"
                event == "native-account] restore result=failed stage=checkpoint_open" ->
                    "The local account checkpoint could not be opened"
                event == "native-account] restore result=failed stage=backup_read" ->
                    "The encrypted account backup could not be read"
                event == "native-account] restore result=failed stage=account_apply" ->
                    "The encrypted account backup could not be applied"
                event == "native-account] restore result=failed stage=local_apply" ->
                    "Account data could not open on this device"
                event == "native-account] restore result=ready stage=account_apply" ->
                    "Account restore completed"
                event == "sync] upload result=accepted" -> "Backup upload accepted"
                event == "sync] upload result=failed" -> "Backup upload failed"
                event == "sync] realtime result=unavailable stage=start reason=setup_failed" ->
                    "Live sync setup failed"
                event == "sync] realtime result=degraded stage=connect reason=socket_start_failed" ->
                    "Live sync connection failed"
                else -> null
            }
        }.toList().takeLast(40)
        if (events.isEmpty()) append("No account recovery events were recorded.\n")
        else events.forEach { append(it).append('\n') }
    }

    /** The complete export: a device header, the probe log, then the distinct always-on tail, all re-scrubbed. */
    fun exportBody(): String {
        val (probe, always) = snapshot()
        return exportBody(header(), probe, always, CrashReporter.pendingCrashes.map { it.json })
    }

    internal fun exportBody(
        header: String,
        probeContents: String,
        alwaysOnContents: String,
        crashReports: List<String> = emptyList(),
    ): String {
        val probeLines = probeContents.lines().filter { it.isNotBlank() }
        val out = StringBuilder(header).append('\n')
        if (probeLines.isEmpty()) {
            out.append("(diagnostic log is empty; turn on Diagnostic logging, reproduce the issue, then export)\n")
        } else {
            probeLines.forEach { out.append(DiagnosticRedaction.scrub(it)).append('\n') }
        }
        val seen = probeLines.toHashSet()
        val tail = alwaysOnContents.lines().filter { it.isNotBlank() }.takeLast(DIAGNOSTICS_TAIL_LINES)
            .filterNot { it in seen }
        out.append("\n===== always-on application diagnostics =====\n")
        if (tail.isEmpty()) {
            out.append("(always-on diagnostics log is empty or duplicates the log above)\n")
        } else {
            out.append("--- diagnostics.log (last ${tail.size} distinct lines) ---\n")
            tail.forEach { out.append(DiagnosticRedaction.scrub(it)).append('\n') }
        }
        // Crashes captured by CrashReporter on earlier runs: already redacted there, scrubbed again here.
        if (crashReports.isNotEmpty()) {
            out.append("\n===== crash reports (${crashReports.size}) =====\n")
            crashReports.forEach { report ->
                crashLines(report).forEach { out.append(DiagnosticRedaction.scrub(it)).append('\n') }
            }
        }
        return out.toString()
    }

    /** One stored crash report as readable lines, so the per-line cap never cuts the stack short. */
    private fun crashLines(json: String): List<String> = runCatching {
        val report = JSONObject(json)
        buildList {
            val at = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US).format(Date(report.optLong("timestampMs")))
            add("crash at=$at thread=${report.optString("thread")} type=${report.optString("type")}")
            report.optString("message").takeIf { it.isNotBlank() }?.let { add("  message: $it") }
            report.optJSONArray("stack")?.let { stack -> for (i in 0 until stack.length()) add("  at ${stack.optString(i)}") }
            report.optJSONArray("breadcrumbs")?.let { crumbs -> for (i in 0 until crumbs.length()) add("  before: ${crumbs.optString(i)}") }
        }
    }.getOrElse { listOf("crash report (unreadable)") }

    private fun header(): String = buildString {
        append("VortX diagnostic log\n")
        append("App: ${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE}) ${BuildConfig.FLAVOR}")
        if (BuildConfig.DEBUG) append(" debug")
        append('\n')
        append("Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT}), ${Build.MANUFACTURER} ${Build.MODEL}\n")
        append("Diagnostic logging: ${if (probeEnabled) "on" else "off"}\n")
        append("Exported: ${stamp.get()!!.format(Date())}\n")
    }

    private fun line(category: String, message: String): String =
        DiagnosticRedaction.durableLine(stamp.get()!!.format(Date()), category, message)

    /** Probe and always-on contents after every queued write has landed. */
    private fun snapshot(): Pair<String, String> {
        val dir = cacheDir ?: return "" to ""
        return runCatching {
            writer.submit(Callable {
                File(dir, PROBE_FILE).readTextOrEmpty() to File(dir, ALWAYS_ON_FILE).readTextOrEmpty()
            }).get(5, TimeUnit.SECONDS)
        }.getOrDefault("" to "")
    }

    private fun File.readTextOrEmpty(): String = if (isFile) runCatching { readText() }.getOrDefault("") else ""

    private fun appendAlwaysOn(dir: File, line: String) {
        runCatching {
            val file = File(dir, ALWAYS_ON_FILE)
            // Dumb rotation, as on Apple: start over rather than juggling partial truncation.
            if (file.length() > ALWAYS_ON_LIMIT) file.writeText("")
            file.appendText(line)
        }
    }

    private fun appendProbe(dir: File, line: String) {
        runCatching {
            val file = File(dir, PROBE_FILE)
            if (file.length() > PROBE_MAX) {
                // Keep roughly the newest PROBE_KEEP bytes, starting at a whole line.
                val text = file.readText()
                val cut = text.length - PROBE_KEEP.toInt()
                val start = text.indexOf('\n', cut.coerceAtLeast(0)).let { if (it < 0) text.length else it + 1 }
                file.writeText(text.substring(start))
            }
            file.appendText(line)
        }
    }
}
