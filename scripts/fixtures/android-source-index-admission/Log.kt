package android.util

/** JVM-only benign host collaborator; Android SDK Log methods are not executable locally. */
object Log {
    @JvmStatic fun d(tag: String, message: String): Int = 0
    @JvmStatic fun w(tag: String, message: String): Int = 0
}
