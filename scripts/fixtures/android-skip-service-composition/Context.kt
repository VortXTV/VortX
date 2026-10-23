package android.content

import java.io.File

/** Synthetic JVM surface only. File construction performs no filesystem access. */
class Context {
    val applicationContext: Context get() = this
    val cacheDir: File get() = File("/synthetic-skip-cache-no-io")
}
