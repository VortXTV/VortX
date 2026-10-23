package android.util

/** Synthetic no-op collaborator; no Android logging runtime is included. */
object Log {
    @JvmStatic fun i(tag: String, message: String): Int = 0
}
