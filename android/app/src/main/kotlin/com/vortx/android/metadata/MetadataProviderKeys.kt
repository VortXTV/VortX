package com.vortx.android.metadata

import android.content.Context
import com.vortx.android.debrid.DebridKeys
import com.vortx.android.debrid.DebridOwnerToken
import com.vortx.android.integrations.SecureTokenStore
import com.vortx.android.security.PersistentCredentialAvailability
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * User-supplied metadata-provider credentials (SET-2), the Android port of the metadata slots in Apple
 * `app/SourcesShared/ApiKeys.swift`. Kept in ENCRYPTED storage (they are credentials, exactly like the skip
 * and debrid keys), using Apple's account strings `vortx.apikey.tmdb` / `vortx.apikey.mdblist` /
 * `vortx.apikey.fanart` as owner-qualified storage-key bases.
 *
 * ANDROID DIVERGENCE (documented, honest): unlike Apple, Android has no per-user "your key -> TMDB direct"
 * branch. Every metadata call on Android already runs through VortX's KEYLESS, edge-signed catalog proxy
 * (`catalogs.vortx.tv/3`, credential injected server-side; see `com.vortx.android.person.TMDBPersonClient`
 * / `com.vortx.android.home.CollectionsHubModel` / `com.vortx.android.trickplay.TmdbImdbResolver`). So a
 * value stored here is not consumed on this device today; it syncs to platforms that call these providers
 * directly and is ready for a future Android direct-provider path. The screen states this plainly rather
 * than implying the value is in use locally.
 *
 * Fail-soft: a blocked encrypted backend degrades to memory-for-this-process without ever crashing or
 * blanking the screen (see [SecureTokenStore] / [com.vortx.android.security.FailClosedCredentialStore]).
 */
class MetadataProviderKeys(context: Context) {

    private val store = SecureTokenStore(context.applicationContext, CREDENTIALS_FILE)
    private val debridKeys = DebridKeys(context.applicationContext)

    /** The three metadata slots, each carrying Apple's exact storage key + wire key + user-facing copy. */
    enum class Slot(val key: String, val syncKey: String, val displayName: String, val hint: String) {
        TMDB(
            "vortx.apikey.tmdb",
            "tmdb",
            "TMDB",
            "Recommendations, cast and artwork.",
        ),
        MDBLIST(
            "vortx.apikey.mdblist",
            "mdblist",
            "MDBList",
            "Ratings and imported lists.",
        ),
        FANART(
            "vortx.apikey.fanart",
            "fanart",
            "fanart.tv",
            "Logos and extra artwork.",
        ),
    }

    /** The stored value for [slot], or empty when unset. The value never leaves the secure store otherwise. */
    fun value(slot: Slot): String = synchronized(OWNER_LOCK) {
        val owner = currentOwner() ?: return@synchronized ""
        observeOwner(owner)
        if (!adoptLegacy(owner)) return@synchronized ""
        store.string(slot.storageKey(owner)) ?: ""
    }

    fun hasValue(slot: Slot): Boolean = value(slot).isNotEmpty()

    /**
     * Store (or, with a blank value, clear) [slot]. Returns whether the secure write was DURABLE: a false
     * means the encrypted backend is unavailable and the value is only in-process, which the caller surfaces
     * rather than reporting a durable save that did not happen.
     */
    fun set(slot: Slot, value: String): Boolean = synchronized(OWNER_LOCK) {
        val owner = currentOwner() ?: return@synchronized false
        observeOwner(owner)
        if (!adoptLegacy(owner) || !debridKeys.isCurrent(owner)) return@synchronized false
        val storageKey = slot.storageKey(owner)
        val previous = store.string(storageKey).orEmpty()
        val trimmed = value.trim()
        val persisted = store.set(storageKey, trimmed.ifEmpty { null })
        val current = store.string(storageKey).orEmpty()
        val verified = persisted && current == trimmed && debridKeys.isCurrent(owner)
        if (verified && previous != current) advanceRevision()
        verified
    }

    /**
     * WHY K-05: the same session-owner transition that guards debrid credentials must first move any legacy
     * global metadata slots into the departing owner's scope and tombstone the globals. A failed secure write
     * blocks the session mutation, so no later account can observe the prior account's credential.
     */
    internal fun runOwnerTransition(mutation: () -> Boolean): Boolean = synchronized(OWNER_LOCK) {
        val owner = currentOwner() ?: return@synchronized false
        if (!adoptLegacy(owner)) return@synchronized false
        mutation()
    }

    private fun currentOwner(): DebridOwnerToken? = debridKeys.ownerToken()

    private fun Slot.storageKey(owner: DebridOwnerToken): String = "$key.${owner.scope.storageSuffix}"

    private fun adoptLegacy(owner: DebridOwnerToken): Boolean {
        if (!debridKeys.isCurrent(owner)) return false
        val readKeys = buildList {
            Slot.entries.forEach { slot ->
                add(slot.key)
                add(slot.storageKey(owner))
            }
        }
        val snapshot = store.confirmedSnapshot(*readKeys.toTypedArray())
        if (snapshot.availability != PersistentCredentialAvailability.AVAILABLE) return false
        val mutations = linkedMapOf<String, String?>()
        Slot.entries.forEach { slot ->
            val legacy = snapshot.values[slot.key]?.takeIf(String::isNotEmpty)
            if (legacy != null && snapshot.values[slot.storageKey(owner)].isNullOrEmpty()) {
                mutations[slot.storageKey(owner)] = legacy
            }
            if (legacy != null) mutations[slot.key] = null
        }
        if (mutations.isEmpty()) return true
        if (!debridKeys.isCurrent(owner) || !store.set(mutations)) return false
        val readback = store.confirmedSnapshot(*mutations.keys.toTypedArray())
        return readback.availability == PersistentCredentialAvailability.AVAILABLE &&
            mutations.all { (key, expected) -> readback.values[key] == expected } &&
            debridKeys.isCurrent(owner)
    }

    private fun observeOwner(owner: DebridOwnerToken) {
        if (observedOwner == null) observedOwner = owner
        else if (observedOwner != owner) {
            observedOwner = owner
            advanceRevision()
        }
    }

    companion object {
        private const val CREDENTIALS_FILE = "vortx_metadata_credentials"
        private val OWNER_LOCK = Any()
        private val revisionCounter = AtomicLong(0L)
        private val _credentialRevision = MutableStateFlow(0L)
        private var observedOwner: DebridOwnerToken? = null

        /** Live key changes and owner switches repaint subscribers, matching [DebridKeys.credentialRevision]. */
        internal val credentialRevision: StateFlow<Long> = _credentialRevision.asStateFlow()

        private fun advanceRevision() {
            _credentialRevision.value = revisionCounter.incrementAndGet()
        }
    }
}
