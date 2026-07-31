package com.vortx.android.mediaserver

import com.vortx.android.integrations.CredentialStoreAccess
import com.vortx.android.security.PersistentCredentialAvailability
import java.util.UUID
import org.json.JSONObject

internal enum class MediaServerAddDisposition(val wire: String) {
    ROLLBACK("rollback"),
    COMMITTED("committed");

    companion object {
        fun fromWire(wire: String): MediaServerAddDisposition? = entries.firstOrNull { it.wire == wire }
    }
}

internal data class MediaServerAddJournal(
    val serverId: UUID,
    val disposition: MediaServerAddDisposition,
)

internal data class MediaServerMetadataSnapshot(
    val records: List<MediaServerRecord>,
    val pendingRemovals: Set<UUID>,
    val pendingAdds: List<MediaServerAddJournal>,
)

internal sealed interface MediaServerMetadataRead {
    data class Available(val snapshot: MediaServerMetadataSnapshot) : MediaServerMetadataRead
    data object Unavailable : MediaServerMetadataRead
}

/**
 * Keeps the last process-confirmed metadata image authoritative. Android SharedPreferences mutates its
 * process cache before disk I/O, even when commit returns false. A rejected publish therefore poisons later
 * writes and rereads in this process while retaining the prior confirmed image; only a fresh process may load
 * the disk again.
 */
internal class ConfirmedMediaServerMetadata(
    private val readPersisted: () -> MediaServerMetadataRead,
    private val writePersisted: (MediaServerMetadataSnapshot) -> Boolean,
) {
    private val lock = Any()
    private var confirmed: MediaServerMetadataRead? = null
    private var poisoned = false

    fun read(): MediaServerMetadataRead = synchronized(lock) {
        confirmed ?: runCatching(readPersisted)
            .getOrDefault(MediaServerMetadataRead.Unavailable)
            .also { confirmed = it }
    }

    fun publish(next: MediaServerMetadataSnapshot): Boolean = synchronized(lock) {
        val current = confirmed ?: runCatching(readPersisted)
            .getOrDefault(MediaServerMetadataRead.Unavailable)
            .also { confirmed = it }
        if (poisoned || current !is MediaServerMetadataRead.Available) return@synchronized false
        val committed = runCatching { writePersisted(next) }.getOrDefault(false)
        if (committed) {
            confirmed = MediaServerMetadataRead.Available(next)
        } else {
            poisoned = true
        }
        committed
    }
}

internal sealed interface MediaServerAddCredentialPreparation {
    data class Ready(val values: Map<String, String?>) : MediaServerAddCredentialPreparation
    data object Unavailable : MediaServerAddCredentialPreparation
    data object RecoveryPending : MediaServerAddCredentialPreparation
}

/**
 * Builds one encrypted-store mutation that both retains the prior per-server token and installs its
 * replacement. The caller must durably publish a ROLLBACK journal before committing [Ready.values].
 */
internal fun prepareMediaServerAddCredentials(
    store: CredentialStoreAccess,
    tokenKey: String,
    backupKey: String,
    token: String,
    plexAccountTokenKey: String,
    plexAccountToken: String?,
): MediaServerAddCredentialPreparation {
    val snapshotKeys = buildList {
        add(tokenKey)
        add(backupKey)
        if (!plexAccountToken.isNullOrEmpty()) add(plexAccountTokenKey)
    }
    val previous = store.confirmedSnapshot(*snapshotKeys.toTypedArray())
    if (previous.availability == PersistentCredentialAvailability.UNAVAILABLE) {
        return MediaServerAddCredentialPreparation.Unavailable
    }
    if (previous.values[backupKey] != null) {
        return MediaServerAddCredentialPreparation.RecoveryPending
    }

    val previousPlexAccountToken = previous.values[plexAccountTokenKey]
    val values = linkedMapOf<String, String?>(
        backupKey to encodePriorMediaServerToken(
            value = previous.values[tokenKey],
            priorPlexAccountToken = previousPlexAccountToken,
            plexAccountTokenOwned = if (plexAccountToken.isNullOrEmpty()) {
                null
            } else {
                previousPlexAccountToken == null
            },
        ),
        tokenKey to token,
    )
    if (!plexAccountToken.isNullOrEmpty() && previousPlexAccountToken == null) {
        values[plexAccountTokenKey] = plexAccountToken
    }
    return MediaServerAddCredentialPreparation.Ready(values)
}

/**
 * Resolves one durable add journal. ROLLBACK restores every credential retained by this add, including clearing
 * a Plex account token this add owned because the slot was previously absent. COMMITTED only discards the
 * backup. A missing backup means the atomic credential mutation never committed, or its resolution already did.
 */
internal fun resolveMediaServerAddCredentials(
    store: CredentialStoreAccess,
    tokenKey: String,
    backupKey: String,
    plexAccountTokenKey: String,
    disposition: MediaServerAddDisposition,
): Boolean {
    val snapshot = store.confirmedSnapshot(backupKey)
    if (snapshot.availability == PersistentCredentialAvailability.UNAVAILABLE) return false
    val encodedPrior = snapshot.values[backupKey] ?: return true
    return when (disposition) {
        MediaServerAddDisposition.ROLLBACK -> {
            val prior = decodePriorMediaServerToken(encodedPrior) ?: return false
            val values = linkedMapOf<String, String?>(
                tokenKey to prior.serverToken.value,
                backupKey to null,
            )
            prior.plexAccountToken?.let { plex ->
                values[plexAccountTokenKey] = if (plex.owned) null else plex.value
            }
            store.set(values)
        }
        MediaServerAddDisposition.COMMITTED -> store.clear(backupKey)
    }
}

internal fun resumeMediaServerAddJournals(
    journals: List<MediaServerAddJournal>,
    resolveCredentials: (MediaServerAddJournal) -> Boolean,
    publishRemaining: (List<MediaServerAddJournal>) -> Boolean,
): List<MediaServerAddJournal> {
    var remaining = journals
    for (journal in journals) {
        if (!resolveCredentials(journal)) continue
        val next = remaining.filter { it.serverId != journal.serverId }
        if (!publishRemaining(next)) break
        remaining = next
    }
    return remaining
}

enum class MediaServerAddResult {
    CONNECTED,
    NOT_CONNECTED,
    RECOVERY_PENDING,
}

private data class PriorMediaServerToken(val value: String?)

private data class PriorPlexAccountToken(
    val value: String?,
    val owned: Boolean,
)

private data class PriorMediaServerCredentials(
    val serverToken: PriorMediaServerToken,
    val plexAccountToken: PriorPlexAccountToken?,
)

private fun encodePriorMediaServerToken(
    value: String?,
    priorPlexAccountToken: String?,
    plexAccountTokenOwned: Boolean?,
): String =
    JSONObject()
        .put("present", value != null)
        .apply { if (value != null) put("value", value) }
        .apply {
            if (plexAccountTokenOwned != null) {
                put(
                    "plexAccountToken",
                    JSONObject()
                        .put("present", priorPlexAccountToken != null)
                        .put("owned", plexAccountTokenOwned)
                        .apply {
                            if (priorPlexAccountToken != null) {
                                put("value", priorPlexAccountToken)
                            }
                        },
                )
            }
        }
        .toString()

private fun decodePriorMediaServerToken(json: String): PriorMediaServerCredentials? {
    val obj = runCatching { JSONObject(json) }.getOrNull() ?: return null
    if (!obj.has("present")) return null
    val serverToken = if (obj.optBoolean("present", false)) {
        obj.optString("value").takeIf { it.isNotEmpty() }?.let(::PriorMediaServerToken)
            ?: return null
    } else {
        PriorMediaServerToken(null)
    }
    if (!obj.has("plexAccountToken")) {
        return PriorMediaServerCredentials(serverToken, null)
    }
    val plex = obj.optJSONObject("plexAccountToken") ?: return null
    if (!plex.has("present") || !plex.has("owned")) return null
    val present = plex.optBoolean("present", false)
    val owned = plex.optBoolean("owned", false)
    val priorPlexAccountToken = when {
        present && !owned ->
            plex.optString("value").takeIf { it.isNotEmpty() }
                ?.let { PriorPlexAccountToken(value = it, owned = false) }
                ?: return null
        !present && owned -> PriorPlexAccountToken(value = null, owned = true)
        else -> return null
    }
    return PriorMediaServerCredentials(serverToken, priorPlexAccountToken)
}
