package com.vortx.android.engine

import com.vortx.android.profile.NativeProfileGateway
import com.vortx.android.profile.UserProfile
import org.json.JSONArray
import org.json.JSONObject

internal class NativeProfileAccess(private val session: () -> VortxNativeSession) : NativeProfileGateway {
    internal class EditTarget internal constructor(internal val runtime: VortxNativeSession, internal val owner: VortxNativeOwner,
        internal val profileID: String, internal val original: UserProfile?, internal val binding: NativeAccountBinding?)
    fun captureEdit(profile: UserProfile, adding: Boolean): EditTarget = captureTarget(profile, adding, requireActive = true)
    fun captureSelection(profile: UserProfile): EditTarget = captureTarget(profile, adding = false, requireActive = false)
    private fun captureTarget(profile: UserProfile, adding: Boolean, requireActive: Boolean): EditTarget = com.vortx.android.profile.ContinueWatchingOwnerGate.serialized {
        val runtime = session(); val read = runtime.read()
        check(!requireActive || adding || read.owner.profileID == profile.id) { "Open this profile through its PIN gate before editing" }
        val original = projection(read).profiles.singleOrNull { it.id == profile.id }
        check(if (adding) original == null else original == profile) { "Profile editor source changed" }
        EditTarget(runtime, read.owner, profile.id, original, original?.let { NativeAccountBinding.read(read.state, it.id) })
    }
    /** Preserve ProfileStore's existing lock order; nested store callbacks reenter these same locks. */
    fun <T> withEditTarget(target: EditTarget, action: () -> T): T = com.vortx.android.profile.ContinueWatchingOwnerGate.serialized {
        target.runtime.owned(target.owner) {
            check(session() === target.runtime) { "Profile account changed" }
            val read = target.runtime.read()
            check(projection(read).profiles.singleOrNull { it.id == target.profileID } == target.original) { "Profile editor source changed" }
            target.binding?.let { check(it.matches(NativeAccountBinding.read(read.state, target.profileID))) { "Profile binding changed" } }
            action()
        }
    }
    override fun read(): NativeProfileGateway.Projection = projection(session().read())
    override fun select(id: String): NativeProfileGateway.Projection {
        val runtime = session(); val read = runtime.read()
        // The existing UI verifies the exact projected salted PIN before calling ProfileStore.select.
        runtime.dispatch(listOf(JSONObject().put("type", "switch_profile").put("id", id)), read.owner)
        return projection(runtime.read())
    }
    override fun save(profile: UserProfile, adding: Boolean): NativeProfileGateway.Projection {
        val runtime = session(); val read = runtime.read()
        val previous = projection(read).profiles.find { it.id == profile.id }
        check(adding == (previous == null)) { "Native profile changed" }
        check(profile.isOwner == (profile.id == read.owner.scope.ownerProfileID)) { "Native owner identity cannot change" }
        check(!profile.isOwner || !profile.usesOwnAccount) { "Native owner cannot be rebound" }
        val actions = mutableListOf<JSONObject>()
        if (adding) actions += JSONObject().put("type", "add_profile").put("id", profile.id).put("name", profile.name)
        if (!profile.isOwner && (profile.usesOwnAccount != (previous?.usesOwnAccount ?: false))) {
            val expected = if (adding) NativeAccountBinding.parse(JSONObject().put("account", JSONObject().put("kind", "local_only"))
                .put("revision", 0).put("transactionId", JSONObject.NULL)) else NativeAccountBinding.read(read.state, profile.id)
            actions += NativeStreamingAccountLink.action(read.owner.scope, profile.id, expected, java.util.UUID.randomUUID().toString(),
                JSONObject().put("kind", if (profile.usesOwnAccount) "pending_own" else "shared"))
        }
        val edits = JSONArray()
        fun edit(field: String, value: Any?) { edits.put(JSONObject().put("field", field).put("value", value ?: JSONObject.NULL)) }
        if (previous?.name != profile.name) edit("name", profile.name)
        if (previous?.pin != profile.pin) {
            require(profile.pin == null || Regex("sha256:[a-fA-F0-9]{64}").matches(profile.pin)) { "Profile PIN must be salted before storage" }
            edit("pin", profile.pin)
        }
        if (previous?.isKids != profile.isKids) edit("kids", profile.isKids)
        if (previous?.familyEdit != profile.familyEdit) edit("familyEdit", profile.familyEdit)
        if (previous?.accentID != profile.accentID) edit("accent", profile.accentID)
        if (previous?.oled != profile.oled) edit("oled", profile.oled)
        if (previous?.textScale != profile.textScale) edit("textScale", (profile.textScale * 1000).toInt())
        if (previous?.disabledAddons != profile.disabledAddons) edit("disabledAddons", JSONArray(profile.disabledAddons.orEmpty()))
        if (edits.length() > 0) actions += JSONObject().put("type", "patch_profile").put("id", profile.id).put("edits", edits)
        val host = read.state.getJSONObject("hostProfilePreferences")
        val raw = NativeHostProfiles.updated(host.optJSONObject(profile.id), profile)
        if (adding && !raw.has("addonPreferences")) raw.put("addonPreferences", JSONObject())
        if (previous?.disabledAddons != profile.disabledAddons && raw.has("addonPreferences")) {
            raw.getJSONObject("addonPreferences").put("disabledAddonURLsOverride", JSONArray(profile.disabledAddons.orEmpty()))
        }
        host.put(profile.id, raw).put("modifiedSeconds", maxOf(System.currentTimeMillis() / 1000.0, host.optDouble("modifiedSeconds", 0.0) + 0.001))
        runtime.dispatch(actions, read.owner, host)
        return projection(runtime.read())
    }
    override fun remove(id: String): NativeProfileGateway.Projection {
        val runtime = session(); val read = runtime.read()
        check(id != read.owner.scope.ownerProfileID) { "Native owner cannot be removed" }
        val host = read.state.getJSONObject("hostProfilePreferences").also { it.remove(id) }
        host.put("modifiedSeconds", maxOf(System.currentTimeMillis() / 1000.0, host.optDouble("modifiedSeconds", 0.0) + 0.001))
        runtime.dispatch(listOf(JSONObject().put("type", "delete_profile").put("id", id)), read.owner, host)
        return projection(runtime.read())
    }

    companion object {
        fun projection(read: VortxNativeRead): NativeProfileGateway.Projection {
            val native = read.state.getJSONObject("roster").getJSONObject("profiles")
            val host = read.state.optJSONObject("hostProfilePreferences") ?: JSONObject()
            val profiles = native.keys().asSequence().map { native.getJSONObject(it) }.filterNot { it.getBoolean("deleted") }.map { value ->
                val id = value.getString("id"); val settings = value.getJSONObject("settings"); val parental = value.getJSONObject("parental")
                val previous = host.optJSONObject(id)?.let(UserProfile::decodeProfile) ?: UserProfile(id = id, name = value.getString("name"), avatar = "person.fill")
                previous.copy(id = id, name = value.getString("name"), isOwner = value.getBoolean("owner"),
                    usesOwnAccount = value.getJSONObject("account").getString("kind") in setOf("own", "pending_own"),
                    pin = value.optString("pin").takeUnless { it.isEmpty() || it == "null" },
                    isKids = parental.getBoolean("kids"), familyEdit = parental.getBoolean("familyEdit"),
                    accentID = settings.optString("accent", previous.accentID), oled = settings.getBoolean("oled"),
                    textScale = settings.getInt("textScale") / 1000.0,
                    disabledAddons = NativeAddonPreferences.disabled(read.copy(owner = read.owner.copy(profileID = id))).toList())
            }.toList().sortedWith(compareByDescending<UserProfile> { it.isOwner }.thenBy { it.id })
            return NativeProfileGateway.Projection(profiles, read.owner.profileID)
        }
    }
}
