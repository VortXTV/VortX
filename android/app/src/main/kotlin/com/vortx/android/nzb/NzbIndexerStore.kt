package com.vortx.android.nzb

import android.content.Context
import com.vortx.android.debrid.DebridOwnerToken
import com.vortx.android.security.FailClosedCredentialStore
import com.vortx.android.security.PersistentCredentialAvailability
import org.json.JSONArray
import org.json.JSONObject

/**
 * Owner/profile-scoped, encrypted-only Newznab configuration. This is deliberately a single secure record
 * so endpoint metadata and its API keys have identical lifetime. Corrupt or unavailable records are read
 * fail-closed and mutations refuse to overwrite them.
 */
internal class NzbIndexerStore(
    context: Context,
    private val currentOwner: () -> DebridOwnerToken?,
    private val currentProfileId: () -> String?,
    private val mutateCurrentOwner: (DebridOwnerToken, () -> Boolean) -> Boolean,
) {
    data class Scope(val owner: DebridOwnerToken, val profileId: String) {
        /** Durable encrypted-record namespace; owner generation belongs only to the in-flight fence. */
        val storageIdentity: String get() = "${owner.scope.storageSuffix}.$profileId"
    }

    data class Document(val revision: Long, val indexers: List<NzbIndexerConfig>)
    sealed interface Read {
        data class Ready(val document: Document) : Read
        data object Missing : Read
        data object Unavailable : Read
        data object Corrupt : Read
        data object Stale : Read
    }

    private val secure = FailClosedCredentialStore(
        context = context.applicationContext,
        encryptedFileName = ENCRYPTED_FILE,
        legacyPlainFileName = LEGACY_PLAIN_FILE,
        tag = TAG,
    )

    fun captureScope(): Scope? = currentOwner()?.let { owner ->
        currentProfileId()?.trim()?.takeIf(String::isNotEmpty)?.let { Scope(owner, it) }
    }

    fun isCurrent(scope: Scope): Boolean = nzbStoreScopeIsCurrent(scope, currentOwner(), currentProfileId())

    fun read(): Read = captureScope()?.let(::read) ?: Read.Stale

    fun read(scope: Scope): Read {
        if (!isCurrent(scope)) return Read.Stale
        val snapshot = secure.confirmedSnapshot(storageKey(scope))
        if (snapshot.availability != PersistentCredentialAvailability.AVAILABLE) return Read.Unavailable
        val raw = snapshot.values[storageKey(scope)] ?: return Read.Missing
        val parsed = decode(raw) ?: return Read.Corrupt
        return if (isCurrent(scope)) Read.Ready(parsed) else Read.Stale
    }

    /** Blank [apiKey] retains a key only for an existing configuration; a new one needs a real key. */
    fun save(config: NzbIndexerConfig, apiKey: String): Boolean = captureScope()?.let { save(config, apiKey, it) } ?: false

    fun save(config: NzbIndexerConfig, apiKey: String, scope: Scope): Boolean =
        save(config, apiKey, scope, expectedRevision = null, requireExpectedRevision = false)

    /**
     * Applies an editor action only to the exact owner/profile/document that produced its visible state.
     * This prevents a cached Compose editor from retargeting a different profile after a switch.
     */
    fun saveFromRead(config: NzbIndexerConfig, apiKey: String, scope: Scope, expectedRevision: Long?): Boolean =
        save(config, apiKey, scope, expectedRevision, requireExpectedRevision = true)

    private fun save(
        config: NzbIndexerConfig,
        apiKey: String,
        scope: Scope,
        expectedRevision: Long?,
        requireExpectedRevision: Boolean,
    ): Boolean {
        if (!isCurrent(scope) || !config.isValidMetadata()) return false
        val existing = read(scope)
        if (requireExpectedRevision && !nzbReadMatchesRevision(existing, expectedRevision)) return false
        val document = when (existing) {
            is Read.Ready -> existing.document
            Read.Missing -> Document(revision = 0, indexers = emptyList())
            else -> return false
        }
        val key = apiKey.trim()
        val old = document.indexers.firstOrNull { it.id == config.id }
        if (old == null && key.isEmpty()) return false
        if (key.isNotEmpty() && (key.toByteArray().size > MAX_KEY_BYTES || key.any(Char::isISOControl))) return false
        if (old == null && document.indexers.size >= MAX_INDEXERS) return false
        val normalized = config.copy(name = config.name.trim(), endpoint = NzbIndexerEndpointPolicy.validate(config.endpoint).getOrThrow().toString())
        val next = document.indexers.toMutableList().also { list ->
            val index = list.indexOfFirst { it.id == normalized.id }
            if (index >= 0) list[index] = normalized else list += normalized
        }
        val previousKeys = if (existing is Read.Missing) emptyMap() else decodeKeys(storageKey(scope)) ?: return false
        val keys = previousKeys.toMutableMap()
        if (key.isNotEmpty()) keys[normalized.id] = key
        if (keys[normalized.id].isNullOrBlank()) return false
        val encoded = encode(Document(document.revision + 1, next), keys) ?: return false
        return mutateCurrentOwner(scope.owner) {
            isCurrent(scope) &&
                (!requireExpectedRevision || nzbReadMatchesRevision(read(scope), expectedRevision)) &&
                secure.set(storageKey(scope), encoded)
        }
    }

    fun remove(id: String): Boolean = captureScope()?.let { remove(id, it) } ?: false

    fun remove(id: String, scope: Scope): Boolean = remove(id, scope, expectedRevision = null, requireExpectedRevision = false)

    /** See [saveFromRead]; deletes must be fenced by the same visible document revision. */
    fun removeFromRead(id: String, scope: Scope, expectedRevision: Long?): Boolean =
        remove(id, scope, expectedRevision, requireExpectedRevision = true)

    private fun remove(id: String, scope: Scope, expectedRevision: Long?, requireExpectedRevision: Boolean): Boolean {
        val existing = read(scope)
        if (requireExpectedRevision && !nzbReadMatchesRevision(existing, expectedRevision)) return false
        val document = (existing as? Read.Ready)?.document ?: return false
        if (!document.indexers.any { it.id == id }) return true
        val keys = decodeKeys(storageKey(scope)) ?: return false
        val next = document.indexers.filterNot { it.id == id }
        val encoded = encode(Document(document.revision + 1, next), keys - id) ?: return false
        return mutateCurrentOwner(scope.owner) {
            isCurrent(scope) &&
                (!requireExpectedRevision || nzbReadMatchesRevision(read(scope), expectedRevision)) &&
                secure.set(storageKey(scope), encoded)
        }
    }

    /** Exposes a captured key only to the request adapter, never to UI callers. */
    internal fun keyFor(id: String, scope: Scope): String? {
        val ready = read(scope) as? Read.Ready ?: return null
        if (ready.document.indexers.none { it.id == id }) return null
        return decodeKeys(storageKey(scope))?.get(id)?.takeIf { it.isNotBlank() && isCurrent(scope) }
    }

    private fun storageKey(scope: Scope): String = "$PREFIX${scope.storageIdentity}"

    private fun decodeKeys(key: String): Map<String, String>? {
        val snapshot = secure.confirmedSnapshot(key)
        if (snapshot.availability != PersistentCredentialAvailability.AVAILABLE) return null
        val raw = snapshot.values[key] ?: return emptyMap()
        return decodeRaw(raw)?.second
    }

    private fun decode(raw: String): Document? = decodeRaw(raw)?.first
    private fun decodeRaw(raw: String): Pair<Document, Map<String, String>>? = runCatching {
        if (raw.toByteArray().size > MAX_DOCUMENT_BYTES) return null
        val root = JSONObject(raw)
        if (root.optInt("version", -1) != VERSION) return null
        val revision = root.optLong("revision", -1)
        if (revision !in 1..Long.MAX_VALUE - 1) return null
        val keysObject = root.optJSONObject("keys") ?: return null
        val configs = root.optJSONArray("indexers") ?: return null
        if (configs.length() > MAX_INDEXERS) return null
        val indexers = buildList {
            repeat(configs.length()) { index ->
                val item = configs.optJSONObject(index) ?: return null
                val config = NzbIndexerConfig(
                    id = item.optString("id"), name = item.optString("name"),
                    endpoint = item.optString("endpoint"), enabled = item.optBoolean("enabled", true),
                )
                if (!config.isValidMetadata()) return null
                add(config)
            }
        }
        if (indexers.map(NzbIndexerConfig::id).toSet().size != indexers.size) return null
        val keys = indexers.associate { config ->
            val value = keysObject.optString(config.id)
            if (value.isBlank() || value.toByteArray().size > MAX_KEY_BYTES || value.any(Char::isISOControl)) return null
            config.id to value
        }
        Document(revision, indexers) to keys
    }.getOrNull()

    private fun encode(document: Document, keys: Map<String, String>): String? = runCatching {
        require(document.revision > 0 && document.indexers.size <= MAX_INDEXERS)
        val indexers = JSONArray()
        document.indexers.forEach { config ->
            require(config.isValidMetadata())
            require(!keys[config.id].isNullOrBlank())
            indexers.put(JSONObject().put("id", config.id).put("name", config.name).put("endpoint", config.endpoint).put("enabled", config.enabled))
        }
        val keyObject = JSONObject()
        document.indexers.forEach { config -> keyObject.put(config.id, keys.getValue(config.id)) }
        JSONObject().put("version", VERSION).put("revision", document.revision).put("indexers", indexers).put("keys", keyObject).toString()
    }.getOrNull()

    private companion object {
        const val TAG = "NzbIndexerStore"
        const val ENCRYPTED_FILE = "vortx_nzb_indexers"
        const val LEGACY_PLAIN_FILE = "vortx_nzb_indexers_plain"
        const val PREFIX = "vortx.nzb.indexer."
        const val VERSION = 1
        const val MAX_INDEXERS = 8
        const val MAX_KEY_BYTES = 4_096
        const val MAX_DOCUMENT_BYTES = 128 * 1024
    }
}

/** Testable owner/profile fence shared by secure reads, mutations, and late search admission. */
internal fun nzbStoreScopeIsCurrent(
    captured: NzbIndexerStore.Scope,
    currentOwner: DebridOwnerToken?,
    currentProfileId: String?,
): Boolean = currentOwner == captured.owner && currentProfileId?.trim() == captured.profileId

/** A missing record is revision zero for the purpose of an editor's first save. */
internal fun nzbReadMatchesRevision(read: NzbIndexerStore.Read, expectedRevision: Long?): Boolean = when (read) {
    is NzbIndexerStore.Read.Ready -> read.document.revision == expectedRevision
    NzbIndexerStore.Read.Missing -> expectedRevision == null
    else -> false
}
