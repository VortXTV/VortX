package com.vortx.android.profile

internal class ExtractedProfileStore(
    private var nativeGateway: NativeProfileGateway?,
    private val onApply: (NativeProfileGateway.Projection, Boolean) -> Unit,
) {
    // Exact actual ProfileStore boundary; the full preference/migration reducer is outside this unit.
    private fun applyNativeProjection(value: NativeProfileGateway.Projection, forceSettings: Boolean = false) = ContinueWatchingOwnerGate.serialized {
        checkNotNull(nativeGateway).withProjection(value) { applyNativeProjectionLocked(value, forceSettings) }
    }

    private fun applyNativeProjectionLocked(value: NativeProfileGateway.Projection, forceSettings: Boolean) = onApply(value, forceSettings)
    fun publish(value: NativeProfileGateway.Projection, forceSettings: Boolean = false) = applyNativeProjection(value, forceSettings)
}
