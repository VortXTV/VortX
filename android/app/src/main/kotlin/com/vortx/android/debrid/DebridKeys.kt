package com.vortx.android.debrid

import android.content.Context
import android.util.AtomicFile
import com.vortx.android.security.FailClosedCredentialStore
import com.vortx.android.security.PersistentCredentialAvailability
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import java.io.FileNotFoundException
import java.util.concurrent.atomic.AtomicLong
import java.util.zip.CRC32
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/// A debrid service VortX can hold an API key for. A debrid key turns cached torrents into instant
/// direct links, so cached torrents play straight from the user's own debrid account without a debrid
/// add-on. Mirrors the Apple `DebridService` (app/SourcesShared/DebridKeys.swift): the raw values are
/// the SAME on-disk identifiers so a future cross-platform key sync lines up field for field.
enum class DebridService(val id: String, val displayName: String) {
    REAL_DEBRID("realDebrid", "Real-Debrid"),
    ALL_DEBRID("allDebrid", "AllDebrid"),
    PREMIUMIZE("premiumize", "Premiumize"),
    TOR_BOX("torBox", "TorBox");

    /// The pre-account-scoping key used by existing Android builds. New code reads it only during the
    /// one-owner adoption and tombstones it before a different account can expose it to a rollback build.
    internal val legacyStorageKey: String get() = "vortx.debrid.$id"

    /// Owner-scoped storage key. Signed-out device data uses `local`; an account uses `account.<Account.id>`,
    /// so even a malformed account id equal to `local` cannot collide with the signed-out scope.
    internal fun storageKey(owner: DebridOwnerScope): String = "$legacyStorageKey.${owner.storageSuffix}"
}

internal sealed interface DebridOwnerScope {
    val storageSuffix: String
    val claimIdentity: String
    val uiIdentity: String

    data object SignedOutLocal : DebridOwnerScope {
        override val storageSuffix = DebridKeys.LOCAL_OWNER_IDENTITY
        override val claimIdentity = DebridKeys.LOCAL_OWNER_IDENTITY
        override val uiIdentity = DebridKeys.LOCAL_OWNER_IDENTITY
    }

    data class Account(val id: String) : DebridOwnerScope {
        override val storageSuffix = "account.$id"
        override val claimIdentity = "${DebridKeys.ACCOUNT_CLAIM_PREFIX}$id"
        override val uiIdentity = claimIdentity
    }
}

internal sealed interface DebridAccountOwnerState {
    data object UnknownOrUnavailable : DebridAccountOwnerState
    data class SignedOutLocal(val generation: Long) : DebridAccountOwnerState
    data class Account(val id: String, val generation: Long) : DebridAccountOwnerState
}

internal data class DebridOwnerToken(
    val scope: DebridOwnerScope,
    val generation: Long,
) {
    val identity: String get() = scope.uiIdentity
}

/** A key and its process-monotonic mutation revision, captured as one credential-state read. */
internal data class DebridCredentialSnapshot(
    val key: String,
    val revision: Long,
    val owner: DebridOwnerToken?,
)

/**
 * One process-wide binding from the restored VortX account to every debrid reader. An absent binding or an
 * unknown state means restore identity is not known yet. Only [DebridAccountOwnerState.SignedOutLocal]
 * permits the device-local scope.
 */
internal class DebridAccountOwnerBinding {
    @Volatile private var ownerSource: (() -> DebridAccountOwnerState)? = null

    fun bind(source: (() -> DebridAccountOwnerState)?) {
        ownerSource = source
    }

    fun currentOwner(): DebridOwnerToken? = when (val state = ownerSource?.invoke()) {
        null,
        DebridAccountOwnerState.UnknownOrUnavailable,
        -> null
        is DebridAccountOwnerState.SignedOutLocal ->
            DebridOwnerToken(DebridOwnerScope.SignedOutLocal, state.generation)
        is DebridAccountOwnerState.Account -> state.id.trim().takeIf(String::isNotEmpty)?.let {
            DebridOwnerToken(DebridOwnerScope.Account(it), state.generation)
        }
    }
}

internal enum class DebridStorageAvailability {
    AVAILABLE,
    UNAVAILABLE,
}

internal data class DebridStorageSnapshot(
    val availability: DebridStorageAvailability,
    val values: Map<String, String?>,
)

internal sealed interface LegacyOwnerReservation {
    data object Missing : LegacyOwnerReservation
    data object InvalidOrUnavailable : LegacyOwnerReservation
    data class Claimed(val owner: String) : LegacyOwnerReservation
}

internal object LegacyOwnerClaimCodec {
    fun encode(owner: String): ByteArray {
        val payload = owner.toByteArray(Charsets.UTF_8)
        require(payload.isNotEmpty() && payload.size <= DebridKeys.MAX_CLAIM_OWNER_BYTES)
        val content = ByteArrayOutputStream().also { bytes ->
            DataOutputStream(bytes).use { output ->
                output.write(DebridKeys.CLAIM_MAGIC)
                output.writeInt(DebridKeys.CLAIM_VERSION)
                output.writeInt(payload.size)
                output.write(payload)
            }
        }.toByteArray()
        val checksum = CRC32().apply { update(content) }.value
        return ByteArrayOutputStream().also { bytes ->
            bytes.write(content)
            DataOutputStream(bytes).use { it.writeLong(checksum) }
        }.toByteArray()
    }

    fun decode(bytes: ByteArray): LegacyOwnerReservation {
        if (
            bytes.size < DebridKeys.CLAIM_MIN_FILE_BYTES ||
            bytes.size > DebridKeys.MAX_CLAIM_FILE_BYTES
        ) {
            return LegacyOwnerReservation.InvalidOrUnavailable
        }
        return runCatching {
            DataInputStream(ByteArrayInputStream(bytes)).use { input ->
                val magic = ByteArray(DebridKeys.CLAIM_MAGIC.size)
                input.readFully(magic)
                if (!magic.contentEquals(DebridKeys.CLAIM_MAGIC)) {
                    return LegacyOwnerReservation.InvalidOrUnavailable
                }
                if (input.readInt() != DebridKeys.CLAIM_VERSION) {
                    return LegacyOwnerReservation.InvalidOrUnavailable
                }
                val length = input.readInt()
                if (length !in 1..DebridKeys.MAX_CLAIM_OWNER_BYTES) {
                    return LegacyOwnerReservation.InvalidOrUnavailable
                }
                val expectedSize = DebridKeys.CLAIM_HEADER_BYTES + length + Long.SIZE_BYTES
                if (bytes.size != expectedSize) {
                    return LegacyOwnerReservation.InvalidOrUnavailable
                }
                val ownerBytes = ByteArray(length)
                input.readFully(ownerBytes)
                val storedChecksum = input.readLong()
                val actualChecksum = CRC32().apply {
                    update(bytes, 0, bytes.size - Long.SIZE_BYTES)
                }.value
                if (storedChecksum != actualChecksum) {
                    return LegacyOwnerReservation.InvalidOrUnavailable
                }
                ownerBytes.toString(Charsets.UTF_8)
                    .takeIf(String::isNotBlank)
                    ?.let(LegacyOwnerReservation::Claimed)
                    ?: LegacyOwnerReservation.InvalidOrUnavailable
            }
        }.getOrElse { LegacyOwnerReservation.InvalidOrUnavailable }
    }
}

/**
 * Minimal persistence boundary for the account-scoping state machine. The Android adapter below delegates
 * to [FailClosedCredentialStore]; the interface keeps owner switching and migration executable in pure JVM
 * tests without constructing an Android [Context].
 */
internal interface DebridKeyValueStore {
    val adoptionDomain: Any get() = this
    fun snapshot(vararg keys: String): DebridStorageSnapshot
    fun write(values: Map<String, String?>): Boolean
    fun legacyOwnerReservation(): LegacyOwnerReservation
    fun claimLegacyOwner(owner: String): Boolean
    fun repairLegacyOwner(owner: String): Boolean = false
}

internal data class DebridKeyStatus(
    val hasValue: Boolean,
    val durablyConfigured: Boolean,
    val storageUnavailable: Boolean,
)

private class AndroidDebridKeyValueStore(context: Context) : DebridKeyValueStore {
    override val adoptionDomain: Any get() = AndroidDebridKeyValueStore::class

    private val store = FailClosedCredentialStore(
        context = context,
        encryptedFileName = DebridKeys.ENCRYPTED_FILE,
        legacyPlainFileName = DebridKeys.PLAIN_FALLBACK_FILE,
        tag = DebridKeys.TAG,
    )
    private val legacyClaimStore =
        AtomicFile(File(context.noBackupFilesDir, DebridKeys.LEGACY_CLAIM_FILE))

    override fun snapshot(vararg keys: String): DebridStorageSnapshot {
        val snapshot = store.confirmedSnapshot(*keys)
        return DebridStorageSnapshot(
            availability = if (
                snapshot.availability == PersistentCredentialAvailability.AVAILABLE
            ) {
                DebridStorageAvailability.AVAILABLE
            } else {
                DebridStorageAvailability.UNAVAILABLE
            },
            values = snapshot.values,
        )
    }

    override fun write(values: Map<String, String?>): Boolean =
        if (values.values.all { it == null }) {
            store.clear(*values.keys.toTypedArray())
        } else {
            store.set(values)
        }

    override fun legacyOwnerReservation(): LegacyOwnerReservation {
        val bytes = try {
            // Always enter AtomicFile.openRead. On older Android releases it restores a valid backup before
            // opening the base file; checking baseFile first would misclassify that recoverable state as absent.
            legacyClaimStore.openRead().use { input ->
                val out = ByteArrayOutputStream()
                val buffer = ByteArray(1024)
                var total = 0
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    total += count
                    if (total > DebridKeys.MAX_CLAIM_FILE_BYTES) {
                        return LegacyOwnerReservation.InvalidOrUnavailable
                    }
                    out.write(buffer, 0, count)
                }
                out.toByteArray()
            }
        } catch (_: FileNotFoundException) {
            return LegacyOwnerReservation.Missing
        } catch (_: Exception) {
            return LegacyOwnerReservation.InvalidOrUnavailable
        }
        return LegacyOwnerClaimCodec.decode(bytes)
    }

    override fun claimLegacyOwner(owner: String): Boolean {
        when (val existing = legacyOwnerReservation()) {
            is LegacyOwnerReservation.Claimed -> return existing.owner == owner
            LegacyOwnerReservation.InvalidOrUnavailable -> return false
            LegacyOwnerReservation.Missing -> Unit
        }
        return writeLegacyOwner(owner)
    }

    override fun repairLegacyOwner(owner: String): Boolean {
        when (val existing = legacyOwnerReservation()) {
            is LegacyOwnerReservation.Claimed -> return existing.owner == owner
            LegacyOwnerReservation.InvalidOrUnavailable,
            LegacyOwnerReservation.Missing,
            -> Unit
        }
        return writeLegacyOwner(owner)
    }

    private fun writeLegacyOwner(owner: String): Boolean {
        val output = runCatching { legacyClaimStore.startWrite() }.getOrNull() ?: return false
        var finished = false
        return try {
            output.write(LegacyOwnerClaimCodec.encode(owner))
            legacyClaimStore.finishWrite(output)
            finished = true
            legacyOwnerReservation() == LegacyOwnerReservation.Claimed(owner)
        } catch (_: Exception) {
            if (!finished) runCatching { legacyClaimStore.failWrite(output) }
            false
        }
    }

}

/// The user's debrid API keys, stored AES-encrypted at rest via [EncryptedSharedPreferences]. This is
/// the Android analogue of the Apple `DebridKeys` (which is Keychain-backed): debrid keys are
/// credentials, so they never sit in plain SharedPreferences.
///
/// If Keystore cannot open, reads and writes fail closed. They are never written to plain
/// SharedPreferences or published from process memory as if they were durable.
///
/// The process account binding is resolved on every operation. Every long-lived instance used by UI,
/// resolver, coordinator, and view models therefore switches owners together.
class DebridKeys private constructor(
    private val store: DebridKeyValueStore,
    private val activeOwner: () -> DebridOwnerToken?,
) {
    internal constructor(
        store: DebridKeyValueStore,
        ownerBinding: DebridAccountOwnerBinding,
    ) : this(store, ownerBinding::currentOwner)

    /** Production-binding constructor used by JVM contracts without an Android Context. */
    internal constructor(store: DebridKeyValueStore) : this(store, PROCESS_OWNER_BINDING::currentOwner)

    constructor(context: Context) : this(
        store = AndroidDebridKeyValueStore(context.applicationContext),
        activeOwner = PROCESS_OWNER_BINDING::currentOwner,
    )

    /// The stored key for [service], or an empty string when none is set.
    @Synchronized
    fun key(service: DebridService): String {
        val owner = currentOwner() ?: return ""
        adoptLegacyForFirstOwner(owner)
        return key(service, owner)
    }

    /// True when [service] has a non-empty key configured.
    fun isConfigured(service: DebridService): Boolean = key(service).isNotEmpty()

    /**
     * Capture a credential and its revision under the same process lock used by successful mutations. A
     * caller can therefore bind caches and network evidence to [DebridCredentialSnapshot.revision] without
     * ever pairing a new key with an old revision.
     */
    internal fun credentialSnapshot(service: DebridService): DebridCredentialSnapshot =
        synchronized(CREDENTIAL_STATE_LOCK) {
            val owner = currentOwner()
            observeOwnerLocked(owner)
            if (owner == null) {
                DebridCredentialSnapshot("", credentialRevisionCounter.get(), null)
            } else {
                adoptLegacyForFirstOwner(owner)
                val value = key(service, owner)
                val stableOwner = currentOwner()
                if (stableOwner != owner) {
                    observeOwnerLocked(stableOwner)
                    DebridCredentialSnapshot("", credentialRevisionCounter.get(), stableOwner)
                } else {
                    DebridCredentialSnapshot(value, credentialRevisionCounter.get(), owner)
                }
            }
        }

    /** Current revision after observing any account-owner transition. */
    internal fun currentCredentialRevision(): Long = synchronized(CREDENTIAL_STATE_LOCK) {
        observeOwnerLocked(currentOwner())
        credentialRevisionCounter.get()
    }

    /// True only when the current account has a non-empty key whose latest mutation reached encrypted
    /// storage. Settings uses this instead of treating a process-memory fallback as a saved credential.
    @Synchronized
    fun isDurablyConfigured(service: DebridService): Boolean {
        return status(service).durablyConfigured
    }

    /// Current account-scoped state for Settings. A rejected mutation is not published through the confirmed
    /// read view and reports storage unavailable until a later secure read or commit succeeds.
    @Synchronized
    internal fun status(service: DebridService): DebridKeyStatus {
        val owner = currentOwner()
            ?: return DebridKeyStatus(
                hasValue = false,
                durablyConfigured = false,
                storageUnavailable = true,
            )
        adoptLegacyForFirstOwner(owner)
        val storageKey = service.storageKey(owner.scope)
        val hasValue = key(service, owner).isNotEmpty()
        val storageUnavailable = isStorageUnavailable(storageKey)
        return DebridKeyStatus(
            hasValue = hasValue,
            durablyConfigured = hasValue && !storageUnavailable,
            storageUnavailable = storageUnavailable,
        )
    }

    /// Persist (or clear, on a blank value) a service's key. The Boolean is true only when the encrypted
    /// commit succeeded. A false result never publishes the unconfirmed value through [key], so UI callers
    /// must use this result rather than claiming that a mutation was saved. The instance monitor stays outside
    /// the process migration lock, matching every other two-lock path, and neither lock spans suspension.
    @Synchronized
    fun setKey(service: DebridService, value: String): Boolean {
        return synchronized(CREDENTIAL_STATE_LOCK) credentialState@{
            val owner = currentOwner() ?: return@credentialState false
            observeOwnerLocked(owner)
            adoptLegacyForFirstOwner(owner)
            if (!isCurrent(owner)) return@credentialState false
            val previous = key(service, owner)
            val trimmed = value.trim()
            val storageKey = service.storageKey(owner.scope)
            val success = synchronized(LEGACY_ADOPTION_LOCK) credentialMutation@{
                val legacyMutation = legacyMutationModeLocked(owner)
                if (legacyMutation == LegacyMutationMode.BLOCKED) return@credentialMutation false
                if (!isCurrent(owner)) return@credentialMutation false
                val values = linkedMapOf<String, String?>(
                    storageKey to trimmed.takeIf(String::isNotEmpty),
                )
                if (legacyMutation == LegacyMutationMode.MIRROR) {
                    values[service.legacyStorageKey] = trimmed.takeIf(String::isNotEmpty)
                }
                val persisted = store.write(values)
                val readback = store.snapshot(*values.keys.toTypedArray())
                val verified =
                    persisted &&
                        readback.availability == DebridStorageAvailability.AVAILABLE &&
                        values.all { (key, expected) -> readback.values[key] == expected }
                val ownerStillCurrent = isCurrent(owner)
                if (!ownerStillCurrent && legacyMutation == LegacyMutationMode.MIRROR) {
                    val tombstoned = tombstoneLegacyRollbackSlots()
                    if (!tombstoned) {
                        currentOwner()?.let { replacement ->
                            failLegacyCopies(
                                store.adoptionDomain,
                                replacement,
                                ownerStorageKeys(replacement),
                            )
                        } ?: markStorageFailure(storageKey)
                    }
                }
                if (verified) {
                    clearStorageFailure(storageKey)
                    clearPendingLegacyCopyFailure(owner, storageKey)
                } else {
                    markStorageFailure(storageKey)
                }
                verified && ownerStillCurrent
            }
            val finalOwner = currentOwner()
            observeOwnerLocked(finalOwner)
            if (finalOwner == owner) {
                val current = key(service, owner)
                if (previous != current) advanceCredentialRevisionLocked()
            }
            success
        }
    }

    /// Services with a key set, in preference order (Real-Debrid first, the most common), mirroring the
    /// Apple `configuredServices`.
    @Synchronized
    fun configuredServices(): List<DebridService> {
        val owner = currentOwner() ?: return emptyList()
        return configuredServices(owner)
    }

    /// True when any debrid key is configured; the resolver's zero-cost gate (no key -> torrents keep
    /// today's behavior).
    fun hasAnyKey(): Boolean = configuredServices().isNotEmpty()

    /// The first configured service + key, for the single-debrid resolve path the resolver uses.
    @Synchronized
    fun primary(): Pair<DebridService, String>? {
        val owner = currentOwner() ?: return null
        adoptLegacyForFirstOwner(owner)
        return DebridService.entries.firstNotNullOfOrNull { service ->
            key(service, owner).takeIf(String::isNotEmpty)?.let { service to it }
        }
    }

    internal fun ownerIdentity(): String =
        ownerToken()?.identity ?: UNKNOWN_OWNER_IDENTITY

    internal fun ownerToken(): DebridOwnerToken? = synchronized(CREDENTIAL_STATE_LOCK) {
        currentOwner().also { owner ->
            observeOwnerLocked(owner)
            owner?.let(::adoptLegacyForFirstOwner)
        }
    }

    internal fun isCurrent(owner: DebridOwnerToken): Boolean = currentOwner() == owner

    internal fun isCurrent(ownerIdentity: String, ownerGeneration: Long): Boolean =
        currentOwner()?.let {
            it.identity == ownerIdentity && it.generation == ownerGeneration
        } == true

    internal fun isConfigured(
        service: DebridService,
        owner: DebridOwnerToken,
    ): Boolean = key(service, owner).isNotEmpty()

    internal fun configuredServices(owner: DebridOwnerToken): List<DebridService> {
        if (!isCurrent(owner)) return emptyList()
        adoptLegacyForFirstOwner(owner)
        val services = DebridService.entries.filter { keyFromStorage(it, owner).isNotEmpty() }
        return services.takeIf { isCurrent(owner) }.orEmpty()
    }

    internal fun key(service: DebridService, owner: DebridOwnerToken): String {
        if (!isCurrent(owner)) return ""
        adoptLegacyForFirstOwner(owner)
        val value = keyFromStorage(service, owner)
        return value.takeIf { isCurrent(owner) }.orEmpty()
    }

    private fun currentOwner(): DebridOwnerToken? = activeOwner()

    private fun keyFromStorage(service: DebridService, owner: DebridOwnerToken): String {
        val storageKey = service.storageKey(owner.scope)
        synchronized(LEGACY_ADOPTION_LOCK) {
            val failed = FAILED_LEGACY_ADOPTIONS[store.adoptionDomain]
            if (
                failed?.ownerClaim == owner.scope.claimIdentity &&
                storageKey in failed.pendingStorageKeys
            ) {
                return ""
            }
        }
        val snapshot = store.snapshot(storageKey)
        if (snapshot.availability != DebridStorageAvailability.AVAILABLE) {
            synchronized(LEGACY_ADOPTION_LOCK) { markStorageFailure(storageKey) }
            return ""
        }
        synchronized(LEGACY_ADOPTION_LOCK) { clearStorageFailure(storageKey) }
        return snapshot.values[storageKey].orEmpty().takeIf { isCurrent(owner) }.orEmpty()
    }

    /**
     * Claim the legacy global slots for exactly one account. The owner is reserved in encrypted storage
     * first, then confirmed in atomic device-local, non-backed-up storage before missing legacy values are
     * copied into owner-scoped encrypted slots. A different active owner preserves the claimant's scoped copy
     * and tombstones the global slots before an older build can read the wrong account's credential.
     *
     * The process-wide lock matters because the app intentionally has several long-lived DebridKeys readers.
     * Without it, two instances could both observe a missing marker and adopt the same legacy key for A and B.
     */
    private fun adoptLegacyForFirstOwner(owner: DebridOwnerToken) {
        synchronized(LEGACY_ADOPTION_LOCK) {
            if (!isCurrent(owner)) return
            val domain = store.adoptionDomain
            val priorFailure = FAILED_LEGACY_ADOPTIONS[domain]

            val reservation = store.legacyOwnerReservation()
            val durableClaim = (reservation as? LegacyOwnerReservation.Claimed)?.owner
            val readKeys = buildList {
                add(LEGACY_OWNER_KEY)
                DebridService.entries.forEach { service ->
                    add(service.legacyStorageKey)
                    add(service.storageKey(owner.scope))
                }
            }
            val snapshot = store.snapshot(*readKeys.toTypedArray())
            if (snapshot.availability != DebridStorageAvailability.AVAILABLE) {
                DebridService.entries
                    .map { it.storageKey(owner.scope) }
                    .forEach(::markStorageFailure)
                return
            }
            val encryptedClaim = snapshot.values[LEGACY_OWNER_KEY]
            if (
                durableClaim != null &&
                encryptedClaim != null &&
                durableClaim != encryptedClaim
            ) {
                failLegacyCopies(domain, owner, ownerStorageKeys(owner))
                return
            }
            // A failed first adoption still establishes which owner was attempting the migration inside this
            // process. A later account must preserve that owner's copy and tombstone the rollback-global slots,
            // not return early and leave those credentials readable under the new account.
            val claimedOwner = durableClaim ?: encryptedClaim ?: priorFailure?.ownerClaim
            if (claimedOwner != null && claimedOwner != owner.scope.claimIdentity) {
                tombstoneLegacyForOtherOwner(domain, owner, claimedOwner)
                return
            }

            val legacyValues = DebridService.entries.mapNotNull { service ->
                snapshot.values[service.legacyStorageKey]
                    ?.takeIf(String::isNotEmpty)
                    ?.let { service to it }
            }
            val pendingBeforeRetry = priorFailure
                ?.takeIf { it.ownerClaim == owner.scope.claimIdentity }
                ?.pendingStorageKeys
                .orEmpty()
            val copies = linkedMapOf<String, String>()
            legacyValues.forEach { (service, legacyValue) ->
                val scopedKey = service.storageKey(owner.scope)
                if (
                    scopedKey in pendingBeforeRetry ||
                    snapshot.values[scopedKey].isNullOrEmpty()
                ) {
                    copies[scopedKey] = legacyValue
                }
            }

            // Reserve the owner in encrypted storage FIRST. AtomicFile on API 26 can fail its first write
            // without leaving a valid base file; this independent durable reservation survives that restart
            // boundary, blocks account B, and lets only account A retry the claim-file write.
            if (
                legacyValues.isNotEmpty() &&
                encryptedClaim == null &&
                reservation == LegacyOwnerReservation.Missing
            ) {
                if (!isCurrent(owner)) return
                val reserved = store.write(mapOf(LEGACY_OWNER_KEY to owner.scope.claimIdentity))
                val reservedReadback = store.snapshot(LEGACY_OWNER_KEY)
                if (
                    !reserved ||
                    reservedReadback.availability != DebridStorageAvailability.AVAILABLE ||
                    reservedReadback.values[LEGACY_OWNER_KEY] != owner.scope.claimIdentity
                ) {
                    failLegacyCopies(domain, owner, ownerStorageKeys(owner))
                    return
                }
            }

            if (legacyValues.isNotEmpty() || encryptedClaim == owner.scope.claimIdentity) {
                if (!isCurrent(owner)) return
                val claimPersisted = when (reservation) {
                    is LegacyOwnerReservation.Claimed ->
                        reservation.owner == owner.scope.claimIdentity
                    LegacyOwnerReservation.Missing ->
                        store.claimLegacyOwner(owner.scope.claimIdentity)
                    LegacyOwnerReservation.InvalidOrUnavailable ->
                        encryptedClaim == owner.scope.claimIdentity &&
                            store.repairLegacyOwner(owner.scope.claimIdentity)
                }
                if (
                    !claimPersisted ||
                    store.legacyOwnerReservation() !=
                    LegacyOwnerReservation.Claimed(owner.scope.claimIdentity)
                ) {
                    failLegacyCopies(domain, owner, ownerStorageKeys(owner))
                    return
                }
            }

            if (legacyValues.isEmpty()) {
                priorFailure?.pendingStorageKeys.orEmpty().forEach(::clearStorageFailure)
                FAILED_LEGACY_ADOPTIONS.remove(domain)
                return
            }

            if (!isCurrent(owner)) return
            val persisted = copies.isEmpty() || store.write(copies)
            val readback = store.snapshot(*copies.keys.toTypedArray())
            val readbackMatches =
                persisted &&
                readback.availability == DebridStorageAvailability.AVAILABLE &&
                copies.all { (storageKey, value) -> readback.values[storageKey] == value }
            if (!readbackMatches) {
                failLegacyCopies(domain, owner, copies.keys)
                return
            }

            copies.keys.forEach(::clearStorageFailure)
            FAILED_LEGACY_ADOPTIONS.remove(domain)
        }
    }

    private fun tombstoneLegacyForOtherOwner(
        domain: Any,
        currentOwner: DebridOwnerToken,
        claimedOwner: String,
    ) {
        val claimedScope = claimedOwner.toOwnerScope()
        val readKeys = buildList {
            DebridService.entries.forEach { service ->
                add(service.legacyStorageKey)
                claimedScope?.let { add(service.storageKey(it)) }
            }
        }
        val snapshot = store.snapshot(*readKeys.toTypedArray())
        if (snapshot.availability != DebridStorageAvailability.AVAILABLE) {
            failLegacyCopies(domain, currentOwner, ownerStorageKeys(currentOwner))
            return
        }
        val mutations = linkedMapOf<String, String?>()
        val preserved = linkedMapOf<String, String>()
        DebridService.entries.forEach { service ->
            val legacyValue = snapshot.values[service.legacyStorageKey]
                ?.takeIf(String::isNotEmpty)
                ?: return@forEach
            claimedScope?.let { scope ->
                val scopedKey = service.storageKey(scope)
                if (snapshot.values[scopedKey].isNullOrEmpty()) {
                    mutations[scopedKey] = legacyValue
                    preserved[scopedKey] = legacyValue
                }
            }
            mutations[service.legacyStorageKey] = null
        }
        if (mutations.isEmpty()) {
            ownerStorageKeys(currentOwner).forEach(::clearStorageFailure)
            FAILED_LEGACY_ADOPTIONS.remove(domain)
            return
        }
        if (!isCurrent(currentOwner)) return
        val persisted = store.write(mutations)
        val verifyKeys = mutations.keys.toTypedArray()
        val readback = store.snapshot(*verifyKeys)
        val verified =
            persisted &&
                readback.availability == DebridStorageAvailability.AVAILABLE &&
                DebridService.entries.all { readback.values[it.legacyStorageKey].isNullOrEmpty() } &&
                preserved.all { (key, value) -> readback.values[key] == value }
        if (!verified) {
            failLegacyCopies(domain, currentOwner, ownerStorageKeys(currentOwner))
            return
        }
        ownerStorageKeys(currentOwner).forEach(::clearStorageFailure)
        FAILED_LEGACY_ADOPTIONS.remove(domain)
    }

    private fun ownerStorageKeys(owner: DebridOwnerToken): List<String> =
        DebridService.entries.map { it.storageKey(owner.scope) }

    private fun String.toOwnerScope(): DebridOwnerScope? = when {
        this == LOCAL_OWNER_IDENTITY -> DebridOwnerScope.SignedOutLocal
        startsWith(ACCOUNT_CLAIM_PREFIX) ->
            removePrefix(ACCOUNT_CLAIM_PREFIX)
                .takeIf(String::isNotBlank)
                ?.let(DebridOwnerScope::Account)
        else -> null
    }

    /** Caller holds [LEGACY_ADOPTION_LOCK] through the resulting mutation and readback verification. */
    private fun legacyMutationModeLocked(owner: DebridOwnerToken): LegacyMutationMode {
        val failure = FAILED_LEGACY_ADOPTIONS[store.adoptionDomain]
        if (failure?.ownerClaim == owner.scope.claimIdentity) {
            return LegacyMutationMode.BLOCKED
        }
        val snapshot = store.snapshot(LEGACY_OWNER_KEY)
        if (snapshot.availability != DebridStorageAvailability.AVAILABLE) {
            return LegacyMutationMode.BLOCKED
        }
        val encryptedClaim = snapshot.values[LEGACY_OWNER_KEY]
        return when (val reservation = store.legacyOwnerReservation()) {
            is LegacyOwnerReservation.Claimed -> when {
                reservation.owner == owner.scope.claimIdentity &&
                    (encryptedClaim == null || encryptedClaim == reservation.owner) ->
                    LegacyMutationMode.MIRROR
                encryptedClaim == owner.scope.claimIdentity ->
                    LegacyMutationMode.BLOCKED
                else -> LegacyMutationMode.SCOPED_ONLY
            }
            LegacyOwnerReservation.Missing,
            LegacyOwnerReservation.InvalidOrUnavailable,
            -> if (encryptedClaim == owner.scope.claimIdentity) {
                LegacyMutationMode.BLOCKED
            } else {
                LegacyMutationMode.SCOPED_ONLY
            }
        }
    }

    /**
     * A mirrored write that observed an owner transition must remove every rollback-global credential before
     * releasing the process migration lock. The claimant's scoped copies were established by adoption first.
     */
    private fun tombstoneLegacyRollbackSlots(): Boolean {
        val tombstones = linkedMapOf<String, String?>().apply {
            DebridService.entries.forEach { put(it.legacyStorageKey, null) }
        }
        val persisted = store.write(tombstones)
        val readback = store.snapshot(*tombstones.keys.toTypedArray())
        return persisted &&
            readback.availability == DebridStorageAvailability.AVAILABLE &&
            tombstones.keys.all { readback.values[it].isNullOrEmpty() }
    }

    /**
     * Preserve every populated rollback slot in its durable claimant scope before clearing the globals. Adoption
     * handles missing claims and prior-owner transitions; this independent readback makes data preservation a
     * prerequisite for session-owner publication even when an earlier adoption attempt failed partway through.
     */
    private fun prepareLegacyRollbackSlotsForOwnerTransition(owner: DebridOwnerToken): Boolean {
        adoptLegacyForFirstOwner(owner)
        if (!isCurrent(owner)) return false
        val reservation = store.legacyOwnerReservation()
        val claimedOwner = (reservation as? LegacyOwnerReservation.Claimed)?.owner
        val claimedScope = claimedOwner?.toOwnerScope()
        val readKeys = buildList {
            add(LEGACY_OWNER_KEY)
            DebridService.entries.forEach { service ->
                add(service.legacyStorageKey)
                claimedScope?.let { add(service.storageKey(it)) }
            }
        }
        val snapshot = store.snapshot(*readKeys.toTypedArray())
        if (snapshot.availability != DebridStorageAvailability.AVAILABLE) return false
        val legacyValues = DebridService.entries.mapNotNull { service ->
            snapshot.values[service.legacyStorageKey]
                ?.takeIf(String::isNotEmpty)
                ?.let { service to it }
        }
        if (legacyValues.isEmpty()) return true
        if (claimedOwner == null || claimedScope == null) return false
        val encryptedClaim = snapshot.values[LEGACY_OWNER_KEY]
        if (encryptedClaim != null && encryptedClaim != claimedOwner) return false
        return legacyValues.all { (service, value) ->
            snapshot.values[service.storageKey(claimedScope)] == value
        }
    }

    /**
     * Remove every pre-scoping rollback credential before a persistent session mutation can expose a different owner.
     * The callback is synchronous by type and runs only after the tombstones verify, under the same process lock as
     * [setKey]. A failed tombstone never invokes it; a failed callback may leave rollback compatibility removed, while
     * the caller's durable session state remains unchanged.
     */
    internal fun runOwnerTransition(mutation: () -> Boolean): Boolean =
        synchronized(LEGACY_ADOPTION_LOCK) {
            val owner = currentOwner() ?: return@synchronized false
            if (!prepareLegacyRollbackSlotsForOwnerTransition(owner)) return@synchronized false
            if (!tombstoneLegacyRollbackSlots()) return@synchronized false
            mutation()
        }

    private fun isStorageUnavailable(storageKey: String): Boolean =
        synchronized(LEGACY_ADOPTION_LOCK) {
            storageKey in FAILED_STORAGE_KEYS[store.adoptionDomain].orEmpty()
        }

    private fun markStorageFailure(storageKey: String) {
        FAILED_STORAGE_KEYS.getOrPut(store.adoptionDomain, ::mutableSetOf).add(storageKey)
    }

    private fun clearStorageFailure(storageKey: String) {
        val failures = FAILED_STORAGE_KEYS[store.adoptionDomain] ?: return
        failures.remove(storageKey)
        if (failures.isEmpty()) FAILED_STORAGE_KEYS.remove(store.adoptionDomain)
    }

    private fun failLegacyCopies(
        domain: Any,
        owner: DebridOwnerToken,
        storageKeys: Collection<String>,
    ) {
        val pending = storageKeys.toSet()
        FAILED_LEGACY_ADOPTIONS[domain] =
            FailedLegacyAdoption(owner.scope.claimIdentity, pending)
        pending.forEach(::markStorageFailure)
    }

    private fun clearPendingLegacyCopyFailure(
        owner: DebridOwnerToken,
        storageKey: String,
    ) {
        val domain = store.adoptionDomain
        val failure = FAILED_LEGACY_ADOPTIONS[domain] ?: return
        if (
            failure.ownerClaim != owner.scope.claimIdentity ||
            storageKey !in failure.pendingStorageKeys
        ) {
            return
        }
        val remaining = failure.pendingStorageKeys - storageKey
        if (remaining.isEmpty()) {
            FAILED_LEGACY_ADOPTIONS.remove(domain)
        } else {
            FAILED_LEGACY_ADOPTIONS[domain] = failure.copy(pendingStorageKeys = remaining)
        }
    }

    internal companion object {
        const val TAG = "DebridKeys"
        const val ENCRYPTED_FILE = "vortx_debrid_keys"
        const val PLAIN_FALLBACK_FILE = "vortx_debrid_keys_plain"
        const val LOCAL_OWNER_IDENTITY = "local"
        const val ACCOUNT_CLAIM_PREFIX = "account:"
        const val UNKNOWN_OWNER_IDENTITY = "unbound"
        const val LEGACY_CLAIM_FILE = "vortx_debrid_legacy_claim"
        internal val CLAIM_MAGIC = byteArrayOf(0x56, 0x58, 0x44, 0x42, 0x52, 0x49, 0x44, 0x31)
        internal const val CLAIM_VERSION = 1
        internal const val MAX_CLAIM_OWNER_BYTES = 1024
        internal const val CLAIM_HEADER_BYTES = 8 + Int.SIZE_BYTES + Int.SIZE_BYTES
        internal const val CLAIM_MIN_FILE_BYTES = CLAIM_HEADER_BYTES + 1 + Long.SIZE_BYTES
        internal const val MAX_CLAIM_FILE_BYTES =
            CLAIM_HEADER_BYTES + MAX_CLAIM_OWNER_BYTES + Long.SIZE_BYTES
        internal const val LEGACY_OWNER_KEY = "vortx.debrid.legacyOwner"
        private val LEGACY_ADOPTION_LOCK = Any()
        private val CREDENTIAL_STATE_LOCK = Any()
        private val PROCESS_OWNER_BINDING = DebridAccountOwnerBinding()
        private val FAILED_LEGACY_ADOPTIONS = mutableMapOf<Any, FailedLegacyAdoption>()
        private val FAILED_STORAGE_KEYS = mutableMapOf<Any, MutableSet<String>>()
        private val credentialRevisionCounter = AtomicLong(0L)
        private val _credentialRevision = MutableStateFlow(0L)
        private var observedCredentialOwner: DebridOwnerToken? = null
        private var didObserveCredentialOwner = false

        /** Successful key mutations and observed owner transitions publish one process-wide revision. */
        internal val credentialRevision: StateFlow<Long> = _credentialRevision.asStateFlow()

        private fun advanceCredentialRevisionLocked() {
            val next = credentialRevisionCounter.incrementAndGet()
            _credentialRevision.value = next
        }

        private fun observeOwnerLocked(owner: DebridOwnerToken?) {
            if (!didObserveCredentialOwner) {
                didObserveCredentialOwner = true
                observedCredentialOwner = owner
            } else if (observedCredentialOwner != owner) {
                observedCredentialOwner = owner
                advanceCredentialRevisionLocked()
            }
        }

        internal fun bindAccountOwnerSource(source: (() -> DebridAccountOwnerState)?) {
            synchronized(CREDENTIAL_STATE_LOCK) {
                PROCESS_OWNER_BINDING.bind(source)
                observeOwnerLocked(PROCESS_OWNER_BINDING.currentOwner())
            }
        }
    }
}

private data class FailedLegacyAdoption(
    val ownerClaim: String,
    val pendingStorageKeys: Set<String>,
)

private enum class LegacyMutationMode {
    SCOPED_ONLY,
    MIRROR,
    BLOCKED,
}
