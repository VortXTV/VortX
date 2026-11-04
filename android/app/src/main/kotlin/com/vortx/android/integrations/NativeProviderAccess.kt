package com.vortx.android.integrations

import com.vortx.android.security.AccountFileProviderWriters
import com.vortx.android.security.PersistentCredentialAvailability
import com.vortx.android.security.PersistentCredentialSnapshot
import com.vortx.android.engine.AccountFileLocalPresence
import com.vortx.android.engine.NativeProfileOverlayWitness
import com.vortx.android.sync.SessionOwnerSnapshot
import org.json.JSONObject
import java.util.UUID
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Admission must hold the authenticated account/epoch lock through the short secure transaction. */
internal interface NativeProviderAdmission {
    fun <T> withCurrent(expected: SessionOwnerSnapshot.Account? = null, action: (SessionOwnerSnapshot.Account) -> T): T?
    /** Ordinary provider reads may seed the vault, unlike existing-only Restore inspection. */
    fun <T> withOrdinaryCurrent(expected: SessionOwnerSnapshot.Account?, action: (SessionOwnerSnapshot.Account) -> T): T? =
        withCurrent(expected, action)

    /** Only the already-retained live owner may admit an existing-only retry vault read. */
    fun <T> withExistingRetryCurrent(
        expected: SessionOwnerSnapshot.Account,
        action: (SessionOwnerSnapshot.Account) -> T,
    ): T? = null
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

    /** Never load or seed a record. An exact startup shell with no state is inert; the manager
     * must still confirm the separate qualified legacy stores. */
    fun inspectRestorePresence(owner: SessionOwnerSnapshot.Account): AccountFileLocalPresence =
        secure.inspectExisting(key(owner)) { raw ->
            require(raw.length <= 4_096)
            val root = NativeProfileOverlayWitness.parseDocument(raw.toByteArray(Charsets.UTF_8))
            val actor = root.opt("actor") as? String
            val document = root.optJSONObject("document")
            root.keys().asSequence().toSet() == setOf("actor", "counter", "document", "pending", "auxiliary", "baseline") &&
                actor != null && runCatching { UUID.fromString(actor).toString() == actor }.getOrDefault(false) &&
                (root.opt("counter") as? Number)?.toString() == "0" &&
                document != null && document.keys().asSequence().toSet() == setOf("schemaVersion", "scope", "fields") &&
                (document.opt("schemaVersion") as? Number)?.toString() == "1" &&
                document.opt("scope") == scope(owner) && document.optJSONObject("fields")?.length() == 0 &&
                listOf("pending", "auxiliary", "baseline").all { root.optJSONObject(it)?.length() == 0 }
        }

    /** Borrow only a physically confirmed existing value from the already-open encrypted store. */
    fun existingRetryVault(owner: SessionOwnerSnapshot.Account): ProviderRetryCredentialProof.ExistingVault? {
        var value: String? = null
        var repeated = false
        val status = secure.inspectExisting(key(owner)) { raw ->
            repeated = value != null
            value = raw
            false
        }
        // Unconfirmed in-memory entries can report PRESENT without a confirmed-value callback.
        if (status != AccountFileLocalPresence.PRESENT || repeated) return null
        return value?.let { ProviderRetryCredentialProof.parseExisting(owner.id, it) }
    }

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
    private val outbound = mutableMapOf<ProviderCallTicket, OutboundCredential>()
    private val changes = MutableStateFlow(0L)
    val revision = changes.asStateFlow()
    private val changeLock = Any()

    fun bind(vault: NativeProviderVault, admission: NativeProviderAdmission, changed: (SessionOwnerSnapshot.Account) -> Unit) =
        AccountFileProviderWriters.withWriter(Unit) {
            synchronized(storeLock) {
                retireOutbound { true }
                binding = Binding(vault, admission, changed)
            }
            notifyChanged()
        }

    fun unbindForTest() = AccountFileProviderWriters.withWriter(Unit) {
        synchronized(storeLock) {
            retireOutbound { true }
            binding = null
        }
        notifyChanged()
    }

    fun accountChanged() { notifyChanged() }
    private fun notifyChanged() = synchronized(changeLock) { changes.value += 1 }

    class RetryIdentity internal constructor(val vaultActor: String, val createdAt: String?)

    class Guard internal constructor(
        val owner: SessionOwnerSnapshot.Account,
        val keys: Set<String>,
        private val events: JSONObject,
        internal val bindingIdentity: Any,
        private val retry: RetryIdentity? = null,
    ) {
        val isExistingOnlyRetry: Boolean get() = retry != null

        internal fun matches(candidate: NativeProviderCredentials, confirmedActor: String? = null): Boolean {
            val original = retry
                ?: return NativeProviderCredentials.same(events, candidate.events(keys))
            if ((confirmedActor ?: ProviderRetryCredentialProof.vaultActor(candidate)) != original.vaultActor ||
                (keys == NativeProviderCredentials.GROUPS[0] && candidate.auxiliary("traktCreated") != original.createdAt)
            ) return false
            val fields = candidate.document().getJSONObject("fields")
            return keys.all { key -> NativeProviderCredentials.same(events.optJSONObject(key), fields.optJSONObject(key)) }
        }
    }

    class RetryCredential internal constructor(
        val guard: Guard,
        val accessToken: String,
        val expiresAtSeconds: Long,
        val createdAtSeconds: Long?,
        private var proof: ByteArray?,
    ) : AutoCloseable {
        @Synchronized fun copyProof(): ByteArray? = proof?.copyOf()
        @Synchronized fun isOpen(): Boolean = proof != null
        @Synchronized override fun close() {
            proof?.fill(0)
            proof = null
        }
    }

    data class Read(val values: Map<String, String?>, val revision: Long, val owner: SessionOwnerSnapshot.Account)

    private class OutboundCredential(val guard: Guard, val createdAt: String?) {
        fun matches(candidate: NativeProviderCredentials, confirmedActor: String?): Boolean =
            guard.matches(candidate, confirmedActor) &&
                (guard.keys != NativeProviderCredentials.GROUPS[0] || candidate.auxiliary("traktCreated") == createdAt)
    }

    fun attachOutbound(guard: Guard, ticket: ProviderCallTicket): Boolean =
        accessForGuard(guard) { selected, value, actor ->
            val observed = OutboundCredential(guard, value.auxiliary("traktCreated"))
            if (selected !== guard.bindingIdentity || !observed.matches(value, actor) || ticket in outbound) false
            else { outbound[ticket] = observed; true }
        } == true

    fun claimOutbound(guard: Guard, ticket: ProviderCallTicket, claim: () -> Boolean): Boolean =
        accessForGuard(guard) { selected, value, actor ->
            val original = outbound[ticket]
            original != null && original.guard === guard && selected === guard.bindingIdentity &&
                original.matches(value, actor) && claim()
        } == true

    fun detachOutbound(ticket: ProviderCallTicket) {
        synchronized(storeLock) { outbound.remove(ticket) }
    }

    private fun retireOutbound(retired: (OutboundCredential) -> Boolean) {
        val entries = outbound.iterator()
        while (entries.hasNext()) {
            val (ticket, observed) = entries.next()
            if (retired(observed)) {
                entries.remove()
                ticket.retire()
            }
        }
    }

    private fun commit(selected: Binding, owner: SessionOwnerSnapshot.Account, candidate: NativeProviderCredentials) {
        retireOutbound { it.guard.bindingIdentity === selected && it.guard.owner == owner && !it.matches(candidate, null) }
        try {
            selected.vault.commit(owner, candidate)
        } catch (failure: Exception) {
            // A failed durable acknowledgement cannot prove that the old credential is still live.
            retireOutbound { it.guard.bindingIdentity === selected && it.guard.owner == owner }
            throw failure
        }
    }

    /** Opaque app-sensitive lifetime. It exports no credential-bearing fields or generated toString. */
    class Prospective internal constructor(private val selected: Any,
        private var observation: NativeProviderVault.Observation?) : AutoCloseable {
        fun <T> withCurrent(document: JSONObject, action: (JSONObject) -> T): T {
            val original = checkNotNull(observation) { "Provider observation retired" }
            val binding = selected as Binding
            return checkNotNull(AccountFileProviderWriters.withWriter<T?>(null) {
                binding.admission.withOrdinaryCurrent(original.owner) {
                    synchronized(storeLock) {
                        check(NativeProviderAccess.binding === binding) { "Provider binding changed" }
                        binding.vault.requireCurrent(original)
                        action(binding.vault.prospective(original, document))
                    }
                }
            }) { "Provider account changed" }
        }
        override fun close() { observation = null }
    }
    fun captureProspective(owner: SessionOwnerSnapshot.Account): Prospective? =
        AccountFileProviderWriters.withWriter<Prospective?>(null) {
            val selected = binding ?: return@withWriter null
            selected.admission.withOrdinaryCurrent(owner) {
                synchronized(storeLock) {
                    check(binding === selected) { "Provider binding changed" }
                    Prospective(selected, selected.vault.observe(owner))
                }
            }
        }

    /** Existing-only inspection may run under the Restore reservation. The ordinary load
     * seeds a missing vault and therefore cannot be used as an absence witness. */
    fun inspectRestoreVaultPresence(owner: SessionOwnerSnapshot.Account,
                                   expectedVault: NativeProviderVault): AccountFileLocalPresence {
        val selected = binding ?: return AccountFileLocalPresence.UNAVAILABLE
        if (selected.vault !== expectedVault) return AccountFileLocalPresence.UNAVAILABLE
        return selected.admission.withCurrent(owner) {
            synchronized(storeLock) {
                if (binding !== selected) AccountFileLocalPresence.UNAVAILABLE
                else selected.vault.inspectRestorePresence(owner)
            }
        } ?: AccountFileLocalPresence.UNAVAILABLE
    }

    private fun <T> access(expected: SessionOwnerSnapshot.Account? = null,
                           action: (Binding, SessionOwnerSnapshot.Account, NativeProviderCredentials) -> T): T? =
        AccountFileProviderWriters.withWriter<T?>(null) {
            val selected = binding ?: return@withWriter null
            selected.admission.withOrdinaryCurrent(expected) { owner -> synchronized(storeLock) {
                check(binding === selected) { "Provider binding changed" }
                action(selected, owner, selected.vault.load(owner))
            } }
        }

    private fun <T> accessExistingForRetry(
        expected: SessionOwnerSnapshot.Account,
        expectedBinding: Any? = null,
        action: (Binding, ProviderRetryCredentialProof.ExistingVault) -> T?,
    ): T? = AccountFileProviderWriters.withWriter<T?>(null) {
        val selected = binding ?: return@withWriter null
        if (expectedBinding != null && selected !== expectedBinding) return@withWriter null
        selected.admission.withExistingRetryCurrent(expected) { owner ->
            synchronized(storeLock) {
                if (binding !== selected || owner != expected) null
                else selected.vault.existingRetryVault(owner)?.let { action(selected, it) }
            }
        }
    }

    private fun <T> accessForGuard(
        guard: Guard,
        action: (Binding, NativeProviderCredentials, String?) -> T,
    ): T? = if (guard.isExistingOnlyRetry) {
        accessExistingForRetry(guard.owner, guard.bindingIdentity) { selected, vault ->
            action(selected, vault.credentials, vault.actor)
        }
    } else access(guard.owner) { selected, _, value -> action(selected, value, null) }

    /** Caller holds its provider credential admission before entering the owner and vault locks. */
    fun captureRetryCredential(
        expected: SessionOwnerSnapshot.Account,
        persistedOwnerEpoch: Long,
        dataKey: ByteArray,
        provider: ProviderRetryCredentialProof.Provider,
    ): RetryCredential? = try {
        accessExistingForRetry(expected) { selected, vault ->
            val fields = vault.credentials.document().getJSONObject("fields")
            val events = JSONObject()
            for (key in provider.keys) events.put(key, fields.optJSONObject(key) ?: return@accessExistingForRetry null)
            val token = (events.getJSONObject(provider.accessKey).opt("value") as? String)
                ?.takeUnless(String::isBlank) ?: return@accessExistingForRetry null
            val expiry = (events.getJSONObject(provider.expiryKey).opt("value") as? String)?.toLongOrNull()
                ?: return@accessExistingForRetry null
            val created = if (provider == ProviderRetryCredentialProof.Provider.TRAKT) {
                val refresh = events.getJSONObject("traktRefresh").opt("value") as? String
                if (refresh.isNullOrBlank() || expiry <= 0L) return@accessExistingForRetry null
                vault.credentials.auxiliary("traktCreated")
            } else null
            val guard = Guard(expected, provider.keys.toSet(), events, selected, RetryIdentity(vault.actor, created))
            val proof = ProviderRetryCredentialProof.derive(expected.id, persistedOwnerEpoch, dataKey, provider, vault)
                ?: return@accessExistingForRetry null
            RetryCredential(guard, token, expiry, created?.toLongOrNull(), proof)
        }
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (_: Exception) {
        null
    }

    fun read(keys: Set<String>): Read? = runCatching { access { selected, owner, value ->
        Read(keys.associateWith(value::value), selected.vault.revision(owner, value), owner)
    } }.getOrNull()

    fun edit(values: Map<String, String?>, auxiliary: Map<String, String?> = emptyMap()): Boolean {
        val success = runCatching { access { binding, owner, candidate ->
            candidate.edit(values, auxiliary)
            commit(binding, owner, candidate)
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
            commit(selected, captured, candidate)
            candidate.mirror(document)
        }
        if (result != null) notifyChanged()
        return result
    }
    fun acknowledge(owner: SessionOwnerSnapshot.Account, sent: JSONObject): Boolean = access(owner) { selected, captured, candidate ->
        candidate.acknowledge(sent); commit(selected, captured, candidate); true
    } == true
    fun hasPending(owner: SessionOwnerSnapshot.Account): Boolean? = access(owner) { _, _, value -> value.hasPending() }

    fun <T> capture(keys: Set<String>, read: () -> T): Pair<Guard, T>? = access { selected, owner, value ->
        Guard(owner, keys, value.events(keys), selected) to read()
    }
    /** Existing exact-owner admission, with no unscoped retry when the original is gone. */
    fun <T> captureForOwner(expected: SessionOwnerSnapshot.Account, keys: Set<String>, read: () -> T): Pair<Guard, T>? =
        access(expected) { selected, owner, value ->
            Guard(owner, keys, value.events(keys), selected) to read()
        }

    fun current(guard: Guard): Boolean = accessForGuard(guard) { selected, value, actor ->
        selected === guard.bindingIdentity && guard.matches(value, actor)
    } == true

    /** Read-only reuse after a serialized peer rotation; never authorizes a credential mutation. */
    fun <T> readCurrentOwner(guard: Guard, read: () -> T): T? {
        if (guard.isExistingOnlyRetry) return null
        return access(guard.owner) { selected, _, _ -> if (selected !== guard.bindingIdentity) null else read() }
    }

    fun <T> guarded(guard: Guard, action: () -> T): T? {
        if (guard.isExistingOnlyRetry) return null
        return access(guard.owner) { selected, _, value ->
            if (selected !== guard.bindingIdentity || !guard.matches(value)) null else action()
        }
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
