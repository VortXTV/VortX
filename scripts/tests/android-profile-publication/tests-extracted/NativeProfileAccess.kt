package com.vortx.android.engine
import com.vortx.android.profile.NativeProfileGateway
import com.vortx.android.profile.UserProfile
// Exact production constructor/read/prepare/publication methods; native command collaborators only are synthetic.
internal class NativeProfileAccess(
    private val publicationAdmission: ((VortxNativeSession, () -> Boolean) -> Boolean)? = null,
    private val capturePreparedPublication: ((VortxNativeSession) -> NativeProfileGateway.PreparedProjection)? = null,
    private val session: () -> VortxNativeSession,
) : NativeProfileGateway {
    override fun read(): NativeProfileGateway.Projection = projection(session().read())
    override fun prepareProjection(mountIdentity: Any, prepare: (NativeProfileGateway.Projection) -> Unit): NativeProfileGateway.PreparedProjection {
        val runtime = mountIdentity as? VortxNativeSession ?: error("Invalid native profile mount")
        check(session() === runtime) { "Native profile account changed" }
        // This entire synchronous transaction runs on IO. No ProfileStore fields or Main callback
        // occur here, and none of these monitors survive the return to the suspend caller.
        return runtime.withCurrentRead { read ->
            val admit = checkNotNull(publicationAdmission) { "Native profile publication admission unavailable" }
            var result: NativeProfileGateway.PreparedProjection? = null
            check(admit(runtime) {
                check(session() === runtime) { "Native profile account changed" }
                prepare(projection(read))
                // A qualified legacy write may have advanced the update stamp. Capture its acknowledged
                // successor, not the pre-migration projection or an independently sampled stamp.
                result = checkNotNull(capturePreparedPublication) { "Native profile metadata admission unavailable" }(runtime)
                true
            }) { "Native profile account changed" }
            checkNotNull(result)
        }
    }
    override fun <T> withProjection(expected: NativeProfileGateway.Projection, action: () -> T): T =
        withCurrentProjection { current ->
            check(current == expected) { "Native profile projection changed" }
            action()
        }
    override fun <T> withCurrentProjection(action: (NativeProfileGateway.Projection) -> T): T {
        val runtime = session()
        // One native read under the same Session -> account -> mounted publication admission.
        // Consumers must finish synchronously; no snapshot or lock is carried across an await.
        return runtime.withCurrentRead { current ->
            val admit = checkNotNull(publicationAdmission) { "Native profile publication admission unavailable" }
            var result: Result<T>? = null
            check(admit(runtime) {
                check(session() === runtime) { "Native profile projection changed" }
                result = runCatching { action(projection(current)) }
                true
            }) { "Native profile account changed" }
            checkNotNull(result).getOrThrow()
        }
    }

    var saveForTest: ((UserProfile) -> NativeProfileGateway.Projection)? = null
    override fun select(id: String): NativeProfileGateway.Projection = error("Not used")
    override fun save(profile: UserProfile, adding: Boolean): NativeProfileGateway.Projection = checkNotNull(saveForTest)(profile)
    override fun remove(id: String): NativeProfileGateway.Projection = error("Not used")
    companion object { fun projection(read: VortxNativeRead): NativeProfileGateway.Projection = read.projected }
}
