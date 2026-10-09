package com.vortx.android.profile

/** Synchronous durable command boundary used by the existing profile UI only in native mode. */
internal interface NativeProfileGateway {
    data class Projection(val profiles: List<UserProfile>, val activeID: String)
    fun read(): Projection
    fun select(id: String): Projection
    fun save(profile: UserProfile, adding: Boolean): Projection
    fun remove(id: String): Projection
}
