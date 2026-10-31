package com.vortx.android.integrations

import com.vortx.android.security.PersistentCredentialAvailability
import com.vortx.android.security.PersistentCredentialSnapshot
import com.vortx.android.sync.SessionOwnerSnapshot
import org.json.JSONObject
import java.util.UUID
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Admission must hold the authenticated account/epoch lock through the short secure transaction. */
internal interface NativeProviderAdmission {
    fun <T> withCurrent(expected: SessionOwnerSnapshot.Account? = null, action: (SessionOwnerSnapshot.Account) -> T): T?
}

/** One encrypted record is both the credential backing and its sync intent; there is no second-store gap. */
internal class NativeProviderVault(private val secure: CredentialStoreAccess, private val qualifiedLegacy: ((SessionOwnerSnapshot.Account) -> JSONObject)? = null) {
    private var observedOwner: SessionOwnerSnapshot.Account? = null
    private var observedEvents: JSONObject? = null
    private var revision = 0L
    private var writeGeneration = 0L

    /** Full sensitive record observation, not the selected-provider event revision. No toString. */
    class Observation internal constructor(internal val owner: SessionOwnerSnapshot.Account,
        internal val generation: Long, internal val sealed: String?, internal val legacy: String?)

    fun observe(owner: SessionOwnerSnapshot.Account): Observation {
        val snapshot = secure.confirmedSnapshot(key(owner))
        check(snapshot.availability == PersistentCredentialAvailability.AVAILABLE) { "Provider secure storage unavailable" }
        val sealed = snapshot.values[key(owner)]
        // Unlike load, observing an absent vault must never initialize/commit it.
        val legacy = if (sealed == null) qualifiedLegacy?.invoke(owner)?.toString() else null
        return Observation(owner, writeGeneration, sealed, legacy)
    }
    fun requireCurrent(observation: Observation) {
        val current = observe(observation.owner)
        check(current.generation == observation.generation && current.sealed == observation.sealed &&
            current.legacy == observation.legacy) { "Pending provider family changed" }
    }
    fun prospective(observation: Observation, document: JSONObject): JSONObject {
        val candidate = NativeProviderCredentials(scope(observation.owner), observation.sealed)
        observation.legacy?.let { candidate.merge(JSONObject(it)) }
        candidate.merge(document)
        return candidate.mirror(document)
    }

    fun load(owner: SessionOwnerSnapshot.Account): NativeProviderCredentials {
        val snapshot = secure.confirmedSnapshot(key(owner))
        check(snapshot.availability == PersistentCredentialAvailability.AVAILABLE) { "Provider secure storage unavailable" }
        val sealed = snapshot.values[key(owner)]
        return NativeProviderCredentials(scope(owner), sealed).also { candidate ->
            if (sealed == null) {
                qualifiedLegacy?.invoke(owner)?.let(candidate::merge)
                commit(owner, candidate) // Stable installation/account actor, even before first edit.
            }
        }
    }
    fun commit(owner: SessionOwnerSnapshot.Account, candidate: NativeProviderCredentials) {
        require(candidate.scope == scope(owner))
        val encoded = candidate.encoded()
        check(writeGeneration < Long.MAX_VALUE) { "Provider revision exhausted" }
        writeGeneration += 1 // Includes same-byte writes and uncertain writes; rejects full-record ABA.
        check(secure.set(key(owner), encoded)) { "Provider secure commit unavailable" }
        val readback = secure.confirmedSnapshot(key(owner))
        check(readback.availability == PersistentCredentialAvailability.AVAILABLE && readback.values[key(owner)] == encoded) {
            "Provider secure readback unavailable"
        }
    }
    fun revision(owner: SessionOwnerSnapshot.Account, value: NativeProviderCredentials): Long {
        val events = value.events(NativeProviderCredentials.KEYS)
        if (owner != observedOwner || !NativeProviderCredentials.same(events, observedEvents)) {
            revision = revisions.incrementAndGet(); observedOwner = owner; observedEvents = events
        }
        return revision
    }
    companion object {
        private val revisions = java.util.concurrent.atomic.AtomicLong(0L)
        fun scope(owner: SessionOwnerSnapshot.Account) = "account.${UUID.fromString(owner.id).toString()}"
        private fun key(owner: SessionOwnerSnapshot.Account) = "native.providers.${scope(owner)}"
    }
}

/** Process binding is replaced only by the account manager. No signed-out or unscoped adoption. */
internal object NativeProviderAccess {
    private class Binding(val vault: NativeProviderVault, val admission: NativeProviderAdmission, val changed: (SessionOwnerSnapshot.Account) -> Unit)
    @Volatile private var binding: Binding? = null
    private val storeLock = Any()
    private val changes = MutableStateFlow(0L)
    val revision = changes.asStateFlow()
    private val changeLock = Any()

    fun bind(vault: NativeProviderVault, admission: NativeProviderAdmission, changed: (SessionOwnerSnapshot.Account) -> Unit) {
        synchronized(storeLock) { binding = Binding(vault, admission, changed) }
        notifyChanged()
    }
    fun unbindForTest() { synchronized(storeLock) { binding = null }; notifyChanged() }
    fun accountChanged() { notifyChanged() }
    private fun notifyChanged() = synchronized(changeLock) { changes.value += 1 }

    data class Guard internal constructor(val owner: SessionOwnerSnapshot.Account, val keys: Set<String>, val events: JSONObject, internal val bindingIdentity: Any)
    data class Read(val values: Map<String, String?>, val revision: Long, val owner: SessionOwnerSnapshot.Account)

    /** Opaque app-sensitive lifetime. It exports no credential-bearing fields or generated toString. */
    class Prospective internal constructor(private val selected: Any,
        private var observation: NativeProviderVault.Observation?) : AutoCloseable {
        fun <T> withCurrent(document: JSONObject, action: (JSONObject) -> T): T {
            val original = checkNotNull(observation) { "Provider observation retired" }
            val binding = selected as Binding
            return checkNotNull(binding.admission.withCurrent(original.owner) {
                synchronized(storeLock) {
                    check(NativeProviderAccess.binding === binding) { "Provider binding changed" }
                    binding.vault.requireCurrent(original)
                    action(binding.vault.prospective(original, document))
                }
            }) { "Provider account changed" }
        }
        override fun close() { observation = null }
    }
    fun captureProspective(owner: SessionOwnerSnapshot.Account): Prospective? {
        val selected = binding ?: return null
        return selected.admission.withCurrent(owner) {
            synchronized(storeLock) {
                check(binding === selected) { "Provider binding changed" }
                Prospective(selected, selected.vault.observe(owner))
            }
        }
    }

    private fun <T> access(expected: SessionOwnerSnapshot.Account? = null, action: (Binding, SessionOwnerSnapshot.Account, NativeProviderCredentials) -> T): T? {
        val selected = binding ?: return null
        return selected.admission.withCurrent(expected) { owner -> synchronized(storeLock) {
            check(binding === selected) { "Provider binding changed" }
            action(selected, owner, selected.vault.load(owner))
        } }
    }
    fun read(keys: Set<String>): Read? = runCatching { access { selected, owner, value ->
        Read(keys.associateWith(value::value), selected.vault.revision(owner, value), owner)
    } }.getOrNull()

    fun edit(values: Map<String, String?>, auxiliary: Map<String, String?> = emptyMap()): Boolean {
        val success = runCatching { access { binding, owner, candidate ->
            candidate.edit(values, auxiliary)
            binding.vault.commit(owner, candidate)
            // Admission is still held: a switch cannot redirect this exact account's dirty event.
            binding.changed(owner)
            true
        } == true }.getOrDefault(false)
        if (success) notifyChanged()
        return success
    }
    fun merge(owner: SessionOwnerSnapshot.Account, document: JSONObject): JSONObject? {
        val result = access(owner) { selected, captured, candidate ->
            candidate.merge(document)
            selected.vault.commit(captured, candidate)
            candidate.mirror(document)
        }
        if (result != null) notifyChanged()
        return result
    }
    fun acknowledge(owner: SessionOwnerSnapshot.Account, sent: JSONObject): Boolean = access(owner) { selected, captured, candidate ->
        candidate.acknowledge(sent); selected.vault.commit(captured, candidate); true
    } == true
    fun hasPending(owner: SessionOwnerSnapshot.Account): Boolean? = access(owner) { _, _, value -> value.hasPending() }

    fun <T> capture(keys: Set<String>, read: () -> T): Pair<Guard, T>? = access { selected, owner, value ->
        Guard(owner, keys, value.events(keys), selected) to read()
    }
    fun current(guard: Guard): Boolean = guarded(guard) { true } == true
    /** Read-only reuse after a serialized peer rotation; never authorizes a credential mutation. */
    fun <T> readCurrentOwner(guard: Guard, read: () -> T): T? = access(guard.owner) { selected, _, _ ->
        if (selected !== guard.bindingIdentity) null else read()
    }
    fun <T> guarded(guard: Guard, action: () -> T): T? = access(guard.owner) { selected, _, value ->
        if (selected !== guard.bindingIdentity || !NativeProviderCredentials.same(guard.events, value.events(guard.keys))) null
        else action()
    }
    fun authorize(key: String, expectedValue: String, expectedRevision: Long, issue: () -> Unit): Boolean =
        runCatching { access { selected, owner, value ->
            if (expectedValue.isEmpty() || value.value(key) != expectedValue || selected.vault.revision(owner, value) != expectedRevision) false
            else { issue(); true }
        } == true }.getOrDefault(false)

    /** OAuth persistence uses one complete tuple write; createdAt is non-synced secure local metadata. */
    fun oauthStore(provider: String): CredentialStoreAccess = object : CredentialStoreAccess {
        private val mapping = when (provider) {
            "trakt" -> mapOf("vortx.trakt.accessToken" to "traktAccess", "vortx.trakt.refreshToken" to "traktRefresh", "vortx.trakt.expiresAt" to "traktExpiry")
            "simkl" -> mapOf("vortx.simkl.accessToken" to "simklAccess", "vortx.simkl.expiresAt" to "simklExpiry")
            else -> error("Unsupported native provider")
        }
        override fun string(key: String): String? = confirmedString(key)
        override fun confirmedSnapshot(vararg keys: String): PersistentCredentialSnapshot = runCatching {
            access { _, _, candidate -> PersistentCredentialSnapshot(PersistentCredentialAvailability.AVAILABLE,
                keys.associateWith { key -> if (key == "vortx.trakt.createdAt" && provider == "trakt") candidate.auxiliary("traktCreated") else candidate.value(mapping[key] ?: error("Unsupported native provider key")) }) }
        }.getOrNull() ?: PersistentCredentialSnapshot(PersistentCredentialAvailability.UNAVAILABLE, emptyMap())
        override fun set(key: String, value: String?): Boolean = set(mapOf(key to value))
        override fun set(values: Map<String, String?>): Boolean {
            if (!values.keys.all { it in mapping || (provider == "trakt" && it == "vortx.trakt.createdAt") }) return false
            if (!values.keys.containsAll(mapping.keys)) return false
            return edit(mapping.map { (key, wire) -> wire to values[key] }.toMap(),
                if (values.containsKey("vortx.trakt.createdAt")) mapOf("traktCreated" to values["vortx.trakt.createdAt"]) else emptyMap())
        }
        override fun clear(vararg keys: String): Boolean = set(keys.associateWith { null })
    }
}
