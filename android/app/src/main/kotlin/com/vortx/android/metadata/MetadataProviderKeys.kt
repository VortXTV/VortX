package com.vortx.android.metadata

import android.content.Context
import com.vortx.android.integrations.SecureTokenStore
import com.vortx.android.security.PersistentCredentialAvailability
import org.json.JSONObject
import java.util.UUID

/**
 * User-supplied metadata-provider credentials (SET-2), the Android port of the metadata slots in Apple
 * `app/SourcesShared/ApiKeys.swift`. Kept in ENCRYPTED storage (they are credentials, exactly like the skip
 * and debrid keys), under Apple's EXACT account strings `vortx.apikey.tmdb` / `vortx.apikey.mdblist` /
 * `vortx.apikey.fanart` so the values ride the same cross-device carriage as the Apple apps.
 *
 * ANDROID DIVERGENCE (documented, honest): unlike Apple, Android has no per-user "your key -> TMDB direct"
 * branch. Every metadata call on Android already runs through VortX's KEYLESS, edge-signed catalog proxy
 * (`catalogs.vortx.tv/3`, credential injected server-side; see `com.vortx.android.person.TMDBPersonClient`
 * / `com.vortx.android.home.CollectionsHubModel` / `com.vortx.android.trickplay.TmdbImdbResolver`). So a
 * value stored here is NOT consumed on this device today; it is persisted on the exact key so it SYNCS to
 * platforms that call these providers directly, and is ready for a future Android direct-provider path. The
 * screen states this plainly rather than implying the value is in use locally.
 *
 * Fail-soft: a blocked encrypted backend degrades to memory-for-this-process without ever crashing or
 * blanking the screen (see [SecureTokenStore] / [com.vortx.android.security.FailClosedCredentialStore]).
 */
class MetadataProviderKeys(context: Context) {

    private val appContext = context.applicationContext
    private val store = SecureTokenStore(appContext, CREDENTIALS_FILE)
    private val ownerPrefs = appContext.getSharedPreferences(OWNER_FILE, Context.MODE_PRIVATE)
    private val deviceId = ownerPrefs.getString(KEY_DEVICE_ID, null)
        ?.takeIf { runCatching { UUID.fromString(it) }.isSuccess }
        ?: UUID.randomUUID().toString().also {
            check(ownerPrefs.edit().putString(KEY_DEVICE_ID, it).commit()) { "metadata device id persistence failed" }
        }

    data class Revision(val clock: Long, val device: String, val tombstone: Boolean)
    data class Snapshot(val values: Map<Slot, String?>, val revisions: Map<Slot, Revision>)

    /** The three metadata slots, each carrying Apple's exact storage key + user-facing copy. */
    enum class Slot(val key: String, val displayName: String, val hint: String) {
        TMDB(
            "vortx.apikey.tmdb",
            "TMDB",
            "Recommendations, cast and artwork.",
        ),
        MDBLIST(
            "vortx.apikey.mdblist",
            "MDBList",
            "Ratings and imported lists.",
        ),
        FANART(
            "vortx.apikey.fanart",
            "fanart.tv",
            "Logos and extra artwork.",
        ),
    }

    /**
     * Bind the secure namespace to a VortX account. Empty/malformed ids deliberately resolve to the
     * isolated signed-out namespace rather than aliasing an account. This is synchronous so a caller
     * cannot read an old owner's slot in the interval before an async reload completes.
     */
    fun bindOwner(accountId: String?): Boolean {
        val owner = normalizedOwner(accountId)
        // The namespace selector itself is durable state. Never expose a new owner in memory when the
        // pointer failed to commit: a later process could otherwise recover a different owner than this one.
        if (!ownerPrefs.edit().putString(KEY_OWNER, owner).commit()) return false
        return migrateLegacyIfSafe(owner)
    }

    /** The stored value for [slot], or empty when unset. The value never leaves the secure store otherwise. */
    fun value(slot: Slot): String = store.string(scopedKey(currentOwner(), slot)) ?: ""

    fun hasValue(slot: Slot): Boolean = value(slot).isNotEmpty()

    /**
     * Store (or, with a blank value, clear) [slot]. Returns whether the secure write was DURABLE: a false
     * means the encrypted backend is unavailable and the value is only in-process, which the caller surfaces
     * rather than reporting a durable save that did not happen.
     */
    fun set(slot: Slot, value: String): Boolean {
        val trimmed = value.trim()
        val owner = currentOwner()
        if (!store.set(scopedKey(owner, slot), trimmed.ifEmpty { null })) return false
        val prior = revisionFor(owner, slot)
        val clock = maxOf(System.currentTimeMillis(), (prior?.clock ?: 0L) + 1L)
        return writeRevision(owner, slot, Revision(clock, deviceId, trimmed.isEmpty()))
    }

    /** Immutable account-scoped read for a sync lease. It never consults the mutable UI owner pointer. */
    fun valuesForOwner(accountId: String): Map<Slot, String?>? {
        val owner = accountId.takeIf(::isValidOwner) ?: return null
        val slots = Slot.entries
        val snapshot = store.confirmedSnapshot(*slots.map { scopedKey(owner, it) }.toTypedArray())
        if (snapshot.availability != PersistentCredentialAvailability.AVAILABLE) return null
        return slots.associateWith { slot -> snapshot.values[scopedKey(owner, slot)]?.takeIf(String::isNotEmpty) }
    }

    fun snapshotForOwner(accountId: String): Snapshot? {
        val values = valuesForOwner(accountId) ?: return null
        val owner = accountId.takeIf(::isValidOwner) ?: return null
        return Snapshot(values, Slot.entries.mapNotNull { slot -> revisionFor(owner, slot)?.let { slot to it } }.toMap())
    }

    fun encodeRevisions(existing: JSONObject?, revisions: Map<Slot, Revision>): JSONObject =
        JSONObject(existing?.toString() ?: "{}").also { out ->
            for ((slot, revision) in revisions) {
                val entry = out.optJSONObject(slot.wireName)?.let { JSONObject(it.toString()) } ?: JSONObject()
                entry.put("clock", revision.clock).put("device", revision.device).put("tombstone", revision.tombstone)
                out.put(slot.wireName, entry)
            }
        }

    fun decodeRevisions(raw: JSONObject?): Map<Slot, Revision> = buildMap {
        raw ?: return@buildMap
        for (slot in Slot.entries) {
            val entry = raw.optJSONObject(slot.wireName) ?: continue
            val clock = entry.optLong("clock", -1L)
            val device = entry.optString("device", "")
            if (clock >= 0L && runCatching { UUID.fromString(device) }.isSuccess) {
                put(slot, Revision(clock, device, entry.optBoolean("tombstone", false)))
            }
        }
    }

    /**
     * Write every incoming slot in one encrypted-store transaction under the immutable account id. The
     * caller supplies the lease predicate immediately before and after the durable commit; an account switch
     * can make the operation fail, but can never redirect account A material into account B's slots.
     */
    fun applyForOwner(
        accountId: String,
        values: Map<Slot, String?>,
        leaseIsCurrent: () -> Boolean,
    ): Boolean {
        val owner = accountId.takeIf(::isValidOwner) ?: return false
        if (!leaseIsCurrent()) return false
        val writes = values.mapKeys { (slot, _) -> scopedKey(owner, slot) }
            .mapValues { (_, value) -> value?.trim()?.takeIf(String::isNotEmpty) }
        if (writes.isEmpty()) return leaseIsCurrent()
        return store.set(writes) && leaseIsCurrent()
    }

    fun applyForOwner(
        accountId: String,
        values: Map<Slot, String?>,
        revisions: Map<Slot, Revision>,
        leaseIsCurrent: () -> Boolean,
    ): Boolean {
        val local = snapshotForOwner(accountId) ?: return false
        val winners = revisions.filter { (slot, remote) ->
            val current = local.revisions[slot]
            current == null || compare(remote, current) > 0
        }
        if (winners.isEmpty()) return true
        val selected = winners.mapValues { (slot, revision) -> if (revision.tombstone) null else values[slot] }
        if (selected.any { (_, value) -> value.isNullOrBlank() } && winners.any { !it.value.tombstone }) return false
        if (!applyForOwner(accountId, selected, leaseIsCurrent)) return false
        val owner = accountId.takeIf(::isValidOwner) ?: return false
        return winners.all { (slot, revision) -> writeRevision(owner, slot, revision) } && leaseIsCurrent()
    }

    internal fun currentOwnerForTests(): String = currentOwner()

    private fun currentOwner(): String =
        normalizedOwner(ownerPrefs.getString(KEY_OWNER, SIGNED_OUT_OWNER))

    /**
     * Old builds used one unqualified slot. Claim it once only after a verified account bind, and only
     * if the account's scoped slot is still absent. A signed-out process never adopts it, so a launch
     * before session restoration cannot move a real account credential into the local namespace.
     */
    private fun migrateLegacyIfSafe(owner: String): Boolean {
        if (owner == SIGNED_OUT_OWNER) return true
        val writes = linkedMapOf<String, String?>()
        for (slot in Slot.entries) {
            val scoped = scopedKey(owner, slot)
            val legacy = store.string(slot.key)?.takeIf(String::isNotBlank)
            // Claim every old key in the same durable transaction. If a scoped destination is already
            // populated, retain it and still erase the unqualified source so no second account can claim it.
            if (store.string(scoped) == null && legacy != null) writes[scoped] = legacy
            if (legacy != null) writes[slot.key] = null
        }
        return writes.isEmpty() || store.set(writes)
    }

    private fun normalizedOwner(raw: String?): String {
        val id = raw?.trim()?.lowercase().orEmpty()
        return if (id.matches(OWNER_ID)) id else SIGNED_OUT_OWNER
    }

    private fun isValidOwner(raw: String): Boolean = raw.matches(OWNER_ID)

    private fun scopedKey(owner: String, slot: Slot): String = "vortx.apikey.$owner.${slot.key.removePrefix("vortx.apikey.")}"

    private val Slot.wireName: String get() = key.removePrefix("vortx.apikey.")
    private fun revisionKey(owner: String, slot: Slot) = "revision.$owner.${slot.wireName}"
    private fun revisionFor(owner: String, slot: Slot): Revision? = runCatching {
        val entry = JSONObject(ownerPrefs.getString(revisionKey(owner, slot), null) ?: return null)
        val clock = entry.getLong("clock")
        val device = entry.getString("device")
        if (clock < 0 || runCatching { UUID.fromString(device) }.isFailure) null
        else Revision(clock, device, entry.getBoolean("tombstone"))
    }.getOrNull()
    private fun writeRevision(owner: String, slot: Slot, revision: Revision): Boolean =
        ownerPrefs.edit().putString(revisionKey(owner, slot), JSONObject().put("clock", revision.clock)
            .put("device", revision.device).put("tombstone", revision.tombstone).toString()).commit()
    private fun compare(left: Revision, right: Revision): Int =
        if (left.clock != right.clock) left.clock.compareTo(right.clock) else left.device.compareTo(right.device)

    companion object {
        const val CREDENTIALS_FILE = "vortx_metadata_credentials"
        const val OWNER_FILE = "vortx_metadata_credential_owner"
        private const val KEY_OWNER = "owner"
        private const val KEY_DEVICE_ID = "deviceId"
        private const val SIGNED_OUT_OWNER = "signed-out"
        private val OWNER_ID = Regex("[a-z0-9][a-z0-9._-]{2,127}")
    }
}
