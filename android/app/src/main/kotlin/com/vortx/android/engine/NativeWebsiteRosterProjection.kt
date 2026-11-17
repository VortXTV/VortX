package com.vortx.android.engine

import com.vortx.android.backup.SettingsBackup
import com.vortx.android.profile.UserProfile
import com.vortx.android.sync.VortXSyncDoc
import org.json.JSONObject

/** Pure source classification and a detached outgoing roster projection. Neither the input nor
 * the result is authenticated authority: the manager must retain the real GET/capture separately,
 * prove current local absence, enforce the encrypted wire budget, and CAS/read back before apply.
 * No storage, clock, key, native runtime, revision, source receipt or upload ACK is created here. */
internal object NativeWebsiteRosterProjection {
    // Match the website-only ownership exclusions in Apple eb09485e3. Presence, even null or an
    // invalid type, is evidence against this exception; it is never treated as an absent carrier.
    private val appCarriers = setOf("settings", "nativeSync", "nativeAccountBootstrap", "nativeHostPreferences",
        "nativeOwnerHistorySources", "nativeProviderCredentials", "profileEdits", "profileEditEvents",
        "profileEditResults", "webAddonEdits", "websiteAddonEditPending") + nativeMigrationSidecars
    private val profileCarriers = setOf("roster", "rosterModified", "profiles", "byProfile", "deletedProfiles",
        "activeProfile", "ownerWatched", "library", "deletedLibrary", "deletedLibraryTs", "updatedAt",
        "addons", "addonsOwnedAt", "mediaServers", "iptv")

    /** Returns a caller-owned candidate, or null for an ineligible source. Invalid JSON, duplicate
     * keys, invalid Unicode, excessive nesting and the OHJson byte bound throw before projection.
     * The ordinary receive parser/snapshot limits and full roster resolver also must accept the
     * projected bytes before return. The caller must not mutate [original] during this synchronous
     * call. Input bytes are unchanged.
     * Unedited values keep their exact JSON tokens; enclosing object order/whitespace may change.
     * This is not complete channel-content validation: ordinary native admission still validates
     * the real readback. A malformed unrelated channel is preserved, not dropped or defaulted. */
    fun project(original: ByteArray): ByteArray? {
        val account = OHJson.Obj(original)
        if (account.keys.any { it in appCarriers }) return null
        val vortx = if ("vortx" in account.keys) objectValue(account["vortx"]) ?: return null else OHJson.Obj()
        if (vortx.keys.any { it in profileCarriers }) return null
        val progress = if ("webProgress" in account.keys) objectValue(account["webProgress"]) ?: return null else null
        val removed = if (progress != null && "removed" in progress.keys)
            objectValue(progress["removed"]) ?: return null else null
        if (!hasNoProfileProgress(progress) || !hasNoProfileProgress(removed)) return null

        val hasWebsiteChannel = isArray(account["addons"]) || isObject(account["apiKeys"])
            || isArray(account["addonOrder"]) || isObject(account["removedAddons"])
            || isArray(account["webAddonRemovals"]) || isArray(vortx["deletedAddons"])
            || isObject(vortx["deletedAddonsTs"]) || isArray(progress?.get("owner"))
            || isArray(removed?.get("owner"))
        if (!hasWebsiteChannel) return null

        // Encode only the NEW local row with the actual Android full-profile codec. Its explicit
        // empty add-on-preference object matches the existing detached empty-account producer.
        // The account itself never passes through JSONObject or a tolerant profile decoder.
        val owner = UserProfile(id = UserProfile.OWNER_ID, name = "Main", avatar = "🍿", isOwner = true)
        val row = owner.encode().put("addonPreferences", JSONObject()).toString().toByteArray(Charsets.UTF_8)
        // Stable key ordering also makes this local row independent of JSONObject iteration order.
        val roster = OHJson.array(listOf(OHJson.canonical(row)))
        vortx.set("roster", roster).set("rosterModified", OHJson.literal("0"))
        return account.set("vortx", vortx.encoded()).encoded().also {
            require(it.size <= OHJson.MAX) { "Website roster projection exceeds JSON budget" }
            requireOrdinaryRoster(it, owner)
        }
    }

    /** Same pure ingress/snapshot/roster-resolution chain as applyRawDocumentInternal followed by
     * applyDocumentLocked. Account ingress alone has a larger budget than the later snapshot path.
     * The parsed/snapshotted view is validation only; never send its normalized serialization.
     * Credential/source archive, material and native-kernel admission are still separately owed. */
    private fun requireOrdinaryRoster(projected: ByteArray, expectedOwner: UserProfile) {
        val incoming = NativeProfileOverlayWitness.parseAccountDocument(projected)
        val snapshot = nativeWatchedDocumentSnapshot(incoming)
        try {
            val document = NativeProfileOverlayWitness.parseDocument(snapshot)
            val parsed = VortXSyncDoc.parse(document)
            require(parsed.rosterIsLossless) { "Projected full roster required" }
            val resolved = SettingsBackup.resolveRosterForPull(document.opt("settings"),
                parsed.roster.takeIf { parsed.rosterIsLossless }, parsed.rosterModifiedSeconds, parsed.rosterIsLossless)
            val roster = requireNotNull(resolved.roster) { "Projected roster unresolved" }
            require(roster.size == 1 && roster.single() == expectedOwner &&
                roster.single().isOwner && roster.single().id == UserProfile.OWNER_ID && resolved.modifiedSeconds == 0.0) {
                "Projected owner changed during ordinary roster resolution"
            }
        } finally { snapshot.fill(0) }
    }

    private fun isArray(value: ByteArray?) = value?.firstOrNull() == '['.code.toByte()
    private fun isObject(value: ByteArray?) = value?.firstOrNull() == '{'.code.toByte()
    // OHJson.Obj already parsed every value and removed only its surrounding whitespace.
    private fun objectValue(value: ByteArray?): OHJson.Obj? =
        if (isObject(value)) OHJson.Obj(requireNotNull(value)) else null
    private fun hasNoProfileProgress(progress: OHJson.Obj?): Boolean {
        if (progress == null || "byProfile" !in progress.keys) return true
        return objectValue(progress["byProfile"])?.keys?.isEmpty() == true
    }
}
