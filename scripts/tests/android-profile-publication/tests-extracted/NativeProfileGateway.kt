package com.vortx.android.profile

/** Synchronous durable command boundary used by the existing profile UI only in native mode. */
internal interface NativeProfileGateway {
    data class Projection(val profiles: List<UserProfile>, val activeID: String)
    /** Worker-captured metadata only. Publication must not read Session or secure storage. */
    class PreparedProjection(val projection: Projection, val requiresRecovery: Boolean = false, private val admission: (() -> Unit) -> Boolean) {
        fun publishIfCurrent(action: () -> Unit): Boolean = admission(action)
    }
    /** Explicit mount identity prevents an asynchronous bootstrap from adopting a replacement account. */
    fun prepareProjection(mountIdentity: Any, prepare: (Projection) -> Unit): PreparedProjection =
        error("Background native profile publication is unavailable")
    fun read(): Projection
    /** Consume one current snapshot while this gateway's existing publication fence remains held. */
    fun <T> withCurrentProjection(action: (Projection) -> T): T {
        val current = read()
        return withProjection(current) { action(current) }
    }
    /** Publish only while the same native projection and account still own this mutation. */
    fun <T> withProjection(expected: Projection, action: () -> T): T = synchronized(this) {
        check(read() == expected) { "Native profile projection changed" }
        action()
    }
    fun select(id: String): Projection
    fun save(profile: UserProfile, adding: Boolean): Projection
    fun remove(id: String): Projection
}
