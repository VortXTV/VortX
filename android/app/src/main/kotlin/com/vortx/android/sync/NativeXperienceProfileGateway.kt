package com.vortx.android.sync

import com.vortx.android.xperience.XperienceImportNamespace

/** Captured, profile-scoped saved-import persistence. No install, fetch, DTO setter or UI authority. */
internal interface NativeXperienceProfileGateway {
    interface Target {
        val accountId: String
        val profileId: String
    }
    interface Snapshot {
        val target: Target
        /** Original raw observations, including opaque future records and tombstones. Each call
         * detaches its bytes. A namespace reader may refuse unsupported records without rewriting them. */
        fun registers(): Map<String, ByteArray>
    }
    fun captureXperienceProfile(): Result<Snapshot>
    fun xperienceSnapshot(target: Target): Result<Snapshot>
    fun xperienceTargetIsCurrent(target: Target): Boolean
    fun publishXperienceIfCurrent(snapshot: Snapshot, publication: () -> Unit): Boolean
    fun retireXperienceTarget(target: Target)

    /** append uses Namespace.append; refresh/replace/rebind use Saved.replacement/Namespace.replace.
     * An Edit is an ownerless proposal. Only this original target may admit and persist it. */
    suspend fun writeXperience(target: Target, edit: XperienceImportNamespace.Edit): Result<Snapshot>
    /** Namespace has no pure delete API. Only a supported Saved baseline can request a tombstone. */
    suspend fun deleteXperience(target: Target, saved: XperienceImportNamespace.Saved): Result<Snapshot>
}
