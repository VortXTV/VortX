package com.vortx.android.diagnostics

import android.content.Context
import android.os.Process
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.ArrayDeque
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.system.exitProcess

/** Audit 12.5: bounded, privacy-redacted local crash capture. No network work belongs here. */
object CrashReporter {
    data class PendingCrash(val json: String)

    private const val MAX_FILES = 5
    private const val MAX_BREADCRUMBS = 20
    private const val WRITE_TIMEOUT_MS = 200L
    private val installed = AtomicBoolean(false)
    private val breadcrumbs = ArrayDeque<String>(MAX_BREADCRUMBS)
    @Volatile var pendingCrashes: List<PendingCrash> = emptyList()
        private set

    fun install(context: Context) {
        runCatching {
            if (!installed.compareAndSet(false, true)) return@runCatching
            val appContext = context.applicationContext
            val previous = Thread.getDefaultUncaughtExceptionHandler()
            Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
                runCatching { writeBounded(appContext, thread, throwable) }
                try {
                    previous?.uncaughtException(thread, throwable) ?: terminate()
                } catch (_: Throwable) {
                    terminate()
                }
            }
            Thread({ runCatching { loadPending(appContext) } }, "vortx-crash-loader")
                .apply { isDaemon = true; start() }
        }
    }

    fun addBreadcrumb(tag: String, message: String) {
        runCatching {
            val line = "${redact(tag).take(32)}: ${redact(message).take(160)}"
            synchronized(breadcrumbs) {
                if (breadcrumbs.size == MAX_BREADCRUMBS) breadcrumbs.removeFirst()
                breadcrumbs.addLast(line)
            }
        }
    }

    private fun loadPending(context: Context) {
        val files = crashFiles(context)
        pendingCrashes = files.take(MAX_FILES)
            .mapNotNull { runCatching { PendingCrash(it.readText().take(16_384)) }.getOrNull() }
        files.drop(MAX_FILES).forEach { runCatching { it.delete() } }
        // Future diagnostics upload seam: consume pendingCrashes explicitly, never upload from this reporter.
    }

    private fun writeBounded(context: Context, thread: Thread, throwable: Throwable) {
        val task = FutureTask {
            runCatching {
                val dir = File(context.filesDir, "crash").apply { mkdirs() }
                crashFiles(context).drop(MAX_FILES - 1).forEach { it.delete() }
                if (crashFiles(context).size >= MAX_FILES) return@runCatching
                val crumbs = synchronized(breadcrumbs) { breadcrumbs.toList() }
                val json = JSONObject()
                    .put("timestampMs", System.currentTimeMillis())
                    .put("thread", redact(thread.name).take(64))
                    .put("type", throwable.javaClass.name.take(160))
                    .put("message", redact(throwable.message.orEmpty()).take(500))
                    .put("stack", JSONArray(throwable.stackTrace.take(32).map { redact(it.toString()).take(300) }))
                    .put("breadcrumbs", JSONArray(crumbs))
                File(dir, "crash-${System.currentTimeMillis()}-${thread.id}.json").writeText(json.toString())
                crashFiles(context).drop(MAX_FILES).forEach { it.delete() }
            }
        }
        Thread(task, "vortx-crash-writer").apply { isDaemon = true; start() }
        runCatching { task.get(WRITE_TIMEOUT_MS, TimeUnit.MILLISECONDS) }
        if (!task.isDone) task.cancel(true)
    }

    private fun terminate(): Nothing {
        Process.killProcess(Process.myPid())
        exitProcess(10)
    }

    private fun crashFiles(context: Context): List<File> =
        File(context.filesDir, "crash").listFiles { file -> file.isFile && file.extension == "json" }
            ?.sortedByDescending { it.lastModified() }.orEmpty()

    private fun redact(value: String): String = value.take(2_000)
        .replace(Regex("(?i)(https?://[^?\\s]+)\\?[^\\s]+"), "\$1?[redacted]")
        .replace(
            Regex("(?i)([\"']?(token|secret|password|auth|key)[\"']?\\s*[:=]\\s*)[\"']?[^\"',;\\s}]+[\"']?"),
            "\$1[redacted]",
        )
        .replace(Regex("(?i)\\bbearer\\s+[A-Za-z0-9._~+/=-]+"), "Bearer [redacted]")
}
