package com.vortx.android.engine

import com.vortx.android.profile.NativeProfileGateway
import com.vortx.android.profile.UserProfile

// Constructor, read, and withProjection are copied verbatim from the actual changed source.
internal class NativeProfileAccess(
    private val publicationAdmission: ((VortxNativeSession, () -> Boolean) -> Boolean)? = null,
    private val session: () -> VortxNativeSession,
) : NativeProfileGateway {
    override fun read(): NativeProfileGateway.Projection = projection(session().read())
    override fun <T> withProjection(expected: NativeProfileGateway.Projection, action: () -> T): T {
        val runtime = session()
        // Session must precede provider/account admission; nested native reads then reenter this monitor.
        return runtime.withCurrentRead { current ->
            val admit = checkNotNull(publicationAdmission) { "Native profile publication admission unavailable" }
            var result: Result<T>? = null
            check(admit(runtime) {
                check(session() === runtime && projection(current) == expected) { "Native profile projection changed" }
                result = runCatching(action)
                true
            }) { "Native profile account changed" }
            checkNotNull(result).getOrThrow()
        }
    }

    // Collaborator stubs: field translation and native mutations are outside this boundary unit.
    override fun select(id: String): NativeProfileGateway.Projection = error("Not used by boundary unit")
    override fun save(profile: UserProfile, adding: Boolean): NativeProfileGateway.Projection = error("Not used by boundary unit")
    override fun remove(id: String): NativeProfileGateway.Projection = error("Not used by boundary unit")
    companion object {
        fun projection(read: VortxNativeRead): NativeProfileGateway.Projection = read.projected
    }
}
