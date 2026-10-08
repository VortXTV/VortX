package com.vortx.android.engine

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import java.nio.channels.FileChannel
import java.security.KeyStore
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.atomic.AtomicLong
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.json.JSONArray
import org.json.JSONObject

/** Identity only. Account bearer/password/debrid credentials never enter this boundary. */
internal data class VortxAccountScope(val accountID: String, val ownerProfileID: String) {
    init { require(accountID.isNotBlank() && ownerProfileID.isNotBlank() && '\u0000' !in accountID && '\u0000' !in ownerProfileID) }
    val authenticatedData: ByteArray get() = "$accountID\u0000$ownerProfileID".toByteArray(Charsets.UTF_8)
    val digest: String get() = MessageDigest.getInstance("SHA-256").digest(authenticatedData).joinToString("") { "%02x".format(it) }

    fun validateSnapshot(snapshot: String, requireSync: Boolean = true): JSONObject {
        val state = JSONObject(snapshot)
        val profiles = state.getJSONObject("roster").getJSONObject("profiles")
        val owner = profiles.getJSONObject(ownerProfileID)
        require(owner.getBoolean("owner") && !owner.getBoolean("deleted")) { "Invalid native snapshot owner" }
        require(profiles.keys().asSequence().count { profiles.getJSONObject(it).getBoolean("owner") } == 1)
        profiles.keys().forEach { require(profiles.getJSONObject(it).getString("id") == it) }
        val active = state.getString("activeProfileId")
        require(!profiles.getJSONObject(active).getBoolean("deleted"))
        val libraries = state.getJSONObject("libraries")
        require(libraries.has(active) && libraries.has(ownerProfileID))
        val sync = state.optJSONObject("nativeSync")
        require(!requireSync || sync != null) { "Native sync artifact required" }
        if (sync != null) {
            require(sync.getInt("schemaVersion") == 1 && sync.getString("scope") == accountID &&
                sync.getString("ownerProfileId") == ownerProfileID) { "Native snapshot scope mismatch" }
            sync.getJSONObject("profiles"); sync.getJSONObject("addons"); sync.getJSONObject("libraries"); sync.getJSONObject("watches")
        }
        if (state.has("hostProfilePreferences")) {
            val host = state.getJSONObject("hostProfilePreferences")
            host.keys().forEach { key ->
                if (key == "modifiedSeconds") require(host.getDouble(key).let { it.isFinite() && it >= 0.0 })
                else host.getJSONObject(key)
            }
        }
        if (state.has("hostProfileSyncPending")) require(state.get("hostProfileSyncPending") is Boolean)
        if (state.has("legacyImportMaterial")) {
            val material = state.getJSONObject("legacyImportMaterial")
            require(material.getInt("schemaVersion") == 1)
            material.getJSONArray("roster"); material.getJSONArray("deletedProfileIds")
            material.getJSONObject("addons"); material.getJSONObject("libraries")
            material.getJSONObject("watches"); material.getJSONObject("identityLinks")
        }
        if (state.has("hostDocument")) {
            state.getJSONObject("hostDocument")
            val excluded = state.getJSONArray("excludedCredentialPaths")
            (0 until excluded.length()).forEach { require(excluded.get(it) is String) }
        } else require(!state.has("excludedCredentialPaths"))
        rejectCredentials(state)
        return state
    }

    internal fun rejectCredentials(value: Any?) {
        when (value) {
            is JSONObject -> value.keys().forEach { key ->
                val field = key.lowercase().replace("_", "").replace("-", "")
                val urlKey = runCatching { java.net.URI(key) }.getOrNull()
                val transportIdentity = urlKey?.scheme?.lowercase() in setOf("https", "http") && !urlKey?.host.isNullOrBlank()
                require(transportIdentity || (field !in setOf("token", "auth", "authkey", "datakey", "password", "authorization", "bearer", "apikey", "apikeys", "credentials") &&
                    !field.endsWith("token") && !field.endsWith("password") && !field.endsWith("secret"))) {
                    "Credentials are not native state"
                }
                rejectCredentials(value.get(key))
            }
            is JSONArray -> (0 until value.length()).forEach { rejectCredentials(value.get(it)) }
        }
    }
}

internal interface VortxCheckpointStore {
    /** Null means absent only; decrypt/key/I/O/malformed failures must throw. */
    fun read(scope: VortxAccountScope): String?
    /** Full atomic replacement, durable flush and authenticated readback before returning. */
    fun commit(scope: VortxAccountScope, snapshot: String)
}

/** Same sealed format as Apple: nonce(12) + AES-GCM ciphertext + tag(16), account+NUL+owner AAD. */
internal class VortxEncryptedCheckpointStore(
    private val directory: File,
    private val key: (VortxAccountScope) -> SecretKey,
) : VortxCheckpointStore {
    private fun file(scope: VortxAccountScope) = File(directory, "native-state-v1-${scope.digest}.sealed")
    private fun open(scope: VortxAccountScope, bytes: ByteArray): String {
        require(bytes.size in 28..MAX_BYTES) { "Invalid native checkpoint" }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(scope), GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
        cipher.updateAAD(scope.authenticatedData)
        val plain = cipher.doFinal(bytes, 12, bytes.size - 12)
        val text = Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(plain)).toString()
        scope.validateSnapshot(text)
        return text
    }
    @Synchronized override fun read(scope: VortxAccountScope): String? {
        val target = file(scope)
        // exists() hides access failures; only the explicit no-such-file exception means absent.
        return try {
            require(Files.size(target.toPath()) <= MAX_BYTES)
            open(scope, Files.readAllBytes(target.toPath()))
        } catch (_: java.nio.file.NoSuchFileException) { null }
    }
    @Synchronized override fun commit(scope: VortxAccountScope, snapshot: String) {
        scope.validateSnapshot(snapshot)
        val plain = snapshot.toByteArray(Charsets.UTF_8)
        require(plain.size <= MAX_BYTES - 28)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key(scope))
        require(cipher.iv.size == 12)
        cipher.updateAAD(scope.authenticatedData)
        val sealed = cipher.iv + cipher.doFinal(plain)
        Files.createDirectories(directory.toPath())
        val pending = Files.createTempFile(directory.toPath(), "native-checkpoint-", ".pending")
        try {
            FileOutputStream(pending.toFile()).use { it.write(sealed); it.fd.sync() }
            Files.move(pending, file(scope).toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
            FileChannel.open(directory.toPath(), StandardOpenOption.READ).use { it.force(true) }
            check(read(scope) == snapshot) { "Native checkpoint readback failed" }
        } finally { Files.deleteIfExists(pending) }
    }
    companion object { private const val MAX_BYTES = 33_554_432 }
}

/** Android Keystore holds a non-exportable AES-256 key; there is no plaintext fallback. */
internal object VortxAndroidCheckpointKey {
    @Synchronized fun get(scope: VortxAccountScope): SecretKey {
        val alias = "vortx.native.state.v1.${scope.digest}"
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if (store.containsAlias(alias)) return requireNotNull(store.getKey(alias, null) as? SecretKey)
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256).setRandomizedEncryptionRequired(true).build())
            generateKey()
        }
    }
}

internal data class VortxNativeOwner(val scope: VortxAccountScope, val profileID: String, val revision: Long)
internal data class VortxNativeRead(val owner: VortxNativeOwner, val state: JSONObject)

/** One immutable account. Every mutation is clone/apply/commit/readback/swap under one monitor. */
internal class VortxNativeSession private constructor(
    val scope: VortxAccountScope,
    private val bindings: VortxRuntimeBindings,
    private val store: VortxCheckpointStore,
    private val transport: VortxResourceTransport,
    private var runtime: VortxNativeRuntime,
    private val isAccountCurrent: () -> Boolean,
    private var hostProfilePreferences: JSONObject,
    private var hostProfileSyncPending: Boolean,
    private var legacyImportMaterial: JSONObject?,
    private var hostDocumentArchive: JSONObject?,
    private val onMutation: () -> Unit,
) : AutoCloseable {
    private data class Slot(val ticket: UUID, val owner: VortxNativeOwner, val bridge: VortxResourceBridge,
                            var completed: List<Pair<String, Long>>? = null)
    private val slots = mutableMapOf<String, Slot>()
    private var revision = nextRevision.incrementAndGet()
    private var closed = false
    private val changes = MutableStateFlow(0L)
    val updates: StateFlow<Long> get() = changes

    companion object {
        private val nextRevision = AtomicLong()
        fun open(scope: VortxAccountScope, ownerName: String, bindings: VortxRuntimeBindings,
                 store: VortxCheckpointStore, transport: VortxResourceTransport,
                 allowNewAccount: Boolean = false, bootstrapActions: List<JSONObject> = emptyList(),
                 initialHostProfiles: JSONObject = JSONObject(), initialHostArchive: JSONObject? = null,
                 onMutation: () -> Unit = {}, isAccountCurrent: () -> Boolean = { true }): VortxNativeSession {
            check(isAccountCurrent()) { "Native account changed" }
            scope.rejectCredentials(initialHostProfiles)
            scope.rejectCredentials(initialHostArchive)
            bootstrapActions.forEach(scope::rejectCredentials)
            val stored = store.read(scope)
            val runtime = if (stored != null) {
                val retained = scope.validateSnapshot(stored)
                // Earlier experimental checkpoints may contain encoded credentials in adjacent
                // carriers. Inspect BEFORE hydrate; rejection leaves the original encrypted file
                // untouched. Newer stored prefs must not bypass sanitized incoming preferences.
                for (field in listOf("hostProfilePreferences", "legacyImportMaterial", "hostDocument")) {
                    retained.optJSONObject(field)?.let(NativeHostDocument::requireCredentialFree)
                }
                val core = JSONObject(stored).also {
                    it.remove("hostProfilePreferences"); it.remove("legacyImportMaterial")
                    it.remove("hostProfileSyncPending")
                    it.remove("hostDocument"); it.remove("excludedCredentialPaths")
                }
                VortxNativeRuntime.hydrate(bindings, core.toString())
            } else {
                check(allowNewAccount || bootstrapActions.isNotEmpty()) { "Native account has no checkpoint; explicit creation or migration required" }
                VortxNativeRuntime.create(bindings, scope.ownerProfileID, ownerName)
            }
            try {
                // Also acts as an additive capability gate. Old artifacts must fail explicitly.
                check(JSONObject(runtime.dispatch(JSONObject().put("type", "bind_sync_scope").put("scope", scope.accountID).toString())).getBoolean("ok")) {
                    "Native sync artifact required"
                }
                for (action in bootstrapActions) {
                    check(JSONObject(runtime.dispatch(action.toString())).getBoolean("ok")) { "Native account bootstrap rejected" }
                }
                val old = stored?.let(::JSONObject)
                val storedProfiles = old?.optJSONObject("hostProfilePreferences")
                val hostProfiles = if (storedProfiles == null || initialHostProfiles.optDouble("modifiedSeconds", 0.0) > storedProfiles.optDouble("modifiedSeconds", 0.0))
                    initialHostProfiles else storedProfiles
                val hostPending = old?.optBoolean("hostProfileSyncPending", false) == true ||
                    (old != null && !old.has("hostProfileSyncPending") && storedProfiles != null && hostProfiles === storedProfiles &&
                        initialHostProfiles.length() > 0 && NativeHostProfiles.hasUnexportedChanges(initialHostProfiles, storedProfiles))
                // Preserve exact typed source clocks beside the receipt, never the credential-bearing cloud document.
                val legacyMaterial = old?.optJSONObject("legacyImportMaterial")
                    ?: bootstrapActions.firstOrNull { it.getString("type") == "import_legacy_sync" }?.getJSONObject("material")
                val archive = initialHostArchive ?: old?.optJSONObject("hostDocument")?.let {
                    JSONObject().put("document", it).put("excludedCredentialPaths", old.getJSONArray("excludedCredentialPaths"))
                }
                val snapshot = JSONObject(runtime.stateJson()).put("hostProfilePreferences", hostProfiles).put("hostProfileSyncPending", hostPending).put("legacyImportMaterial", legacyMaterial)
                    .put("hostDocument", archive?.getJSONObject("document")).put("excludedCredentialPaths", archive?.getJSONArray("excludedCredentialPaths")).toString()
                scope.validateSnapshot(snapshot)
                store.commit(scope, snapshot)
                check(store.read(scope) == snapshot) { "Native checkpoint readback failed" }
                check(isAccountCurrent()) { "Native account changed" }
                return VortxNativeSession(scope, bindings, store, transport, runtime, isAccountCurrent, JSONObject(hostProfiles.toString()), hostPending,
                    legacyMaterial?.let { JSONObject(it.toString()) }, archive?.let { JSONObject(it.toString()) }, onMutation)
            } catch (error: Throwable) { runtime.close(); throw error }
        }
    }

    @Synchronized fun read(): VortxNativeRead {
        check(!closed) { "Native session closed" }
        check(isAccountCurrent()) { "Native account changed" }
        val state = scope.validateSnapshot(JSONObject(runtime.stateJson()).put("hostProfilePreferences", hostProfilePreferences)
            .put("hostProfileSyncPending", hostProfileSyncPending)
            .put("legacyImportMaterial", legacyImportMaterial).put("hostDocument", hostDocumentArchive?.getJSONObject("document"))
            .put("excludedCredentialPaths", hostDocumentArchive?.getJSONArray("excludedCredentialPaths")).toString())
        return VortxNativeRead(VortxNativeOwner(scope, state.getString("activeProfileId"), revision), state)
    }
    @Synchronized fun accepts(owner: VortxNativeOwner): Boolean = !closed && isAccountCurrent() && read().owner == owner
    @Synchronized fun resolve(request: JSONObject, owner: VortxNativeOwner = read().owner): JSONObject = owned(owner) {
        JSONObject(runtime.resolve(request.toString())).also { check(it.getString("kind") != "error") { "Native query rejected" } }
    }
    @Synchronized fun <T> owned(owner: VortxNativeOwner, action: () -> T): T {
        check(accepts(owner)) { "Native owner changed" }; return action()
    }
    @Synchronized fun dispatch(actions: List<JSONObject>, owner: VortxNativeOwner = read().owner,
                              hostProfiles: JSONObject? = null, notifyMutation: Boolean = true,
                              hostArchive: JSONObject? = null): List<String> = owned(owner) {
        actions.forEach(scope::rejectCredentials)
        scope.rejectCredentials(hostProfiles)
        scope.rejectCredentials(hostArchive)
        val before = runtime.stateJson()
        val candidate = VortxNativeRuntime.hydrate(bindings, before)
        var installed = false
        try {
            val results = actions.map { action ->
                candidate.dispatch(action.toString()).also { check(JSONObject(it).getBoolean("ok")) { "Native action rejected" } }
            }
            val preferences = hostProfiles ?: hostProfilePreferences
            val pendingPreferences = hostProfileSyncPending ||
                (notifyMutation && hostProfiles != null && NativeHostProfiles.hasUnexportedChanges(hostProfilePreferences, hostProfiles))
            val retained = legacyImportMaterial ?: actions.firstOrNull { it.getString("type") == "import_legacy_sync" }?.getJSONObject("material")
            val archive = hostArchive ?: hostDocumentArchive
            val updated = JSONObject(candidate.stateJson()).put("hostProfilePreferences", preferences).put("hostProfileSyncPending", pendingPreferences).put("legacyImportMaterial", retained)
                .put("hostDocument", archive?.getJSONObject("document")).put("excludedCredentialPaths", archive?.getJSONArray("excludedCredentialPaths")).toString()
            val state = scope.validateSnapshot(updated)
            store.commit(scope, updated)
            check(store.read(scope) == updated) { "Native checkpoint readback failed" }
            check(isAccountCurrent()) { "Native account changed" }
            val prior = JSONObject(before)
            val profileOrRegistryChanged = prior.getJSONObject("roster").toString() != state.getJSONObject("roster").toString() ||
                prior.getJSONObject("nativeSync").getJSONObject("addons").toString() != state.getJSONObject("nativeSync").getJSONObject("addons").toString()
            val hostChanged = preferences.toString() != hostProfilePreferences.toString()
            val previous = runtime; runtime = candidate; installed = true; previous.close()
            hostProfilePreferences = JSONObject(preferences.toString())
            hostProfileSyncPending = pendingPreferences
            legacyImportMaterial = retained?.let { JSONObject(it.toString()) }
            hostDocumentArchive = archive?.let { JSONObject(it.toString()) }
            // Any profile/registry mutation invalidates in-flight resources. Progress does not.
            if (hostChanged || profileOrRegistryChanged || state.getString("activeProfileId") != owner.profileID || actions.any {
                    it.getString("type") in setOf("patch_profile", "delete_profile", "install_addon", "remove_addon", "reorder_addons")
                }) invalidate()
            changes.value += 1
            if (notifyMutation) onMutation()
            results
        } finally { if (!installed) candidate.close() }
    }
    @Synchronized private fun invalidate() {
        revision = nextRevision.incrementAndGet()
        slots.values.forEach { it.bridge.close() }; slots.clear()
    }
    @Synchronized override fun close() {
        if (closed) return
        closed = true; invalidate(); runtime.close(); (transport as? AutoCloseable)?.close()
        changes.value += 1
    }
    @Synchronized private fun begin(name: String, owner: VortxNativeOwner): Slot = owned(owner) {
        slots.remove(name)?.bridge?.close()
        Slot(UUID.randomUUID(), owner, VortxResourceBridge(transport)).also { slots[name] = it }
    }
    @Synchronized private fun current(name: String, slot: Slot): Boolean = accepts(slot.owner) && slots[name] === slot

    /** Parsing may occur off-lock; publication must still belong to the exact latest consumer load. */
    @Synchronized fun <T> publish(name: String, owner: VortxNativeOwner, pages: List<VortxResourceSnapshot>, action: () -> T): T = owned(owner) {
        check(slots[name]?.completed == pages.map { it.requestId to it.generation }) { "Native request superseded" }
        action()
    }

    /** A new request replaces only its own consumer slot. Close/profile/account changes fence all slots. */
    suspend fun load(name: String, owner: VortxNativeOwner,
                     requests: List<Pair<VortxResourceRequest, List<VortxResourceAddon>>>): List<VortxResourceSnapshot> {
        val slot = begin(name, owner)
        try {
            val result = requests.map { (request, addons) ->
                check(current(name, slot)) { "Native request superseded" }
                slot.bridge.load("${scope.digest}:${owner.profileID}:${owner.revision}", request, addons).also {
                    check(current(name, slot) && slot.bridge.accepts(it)) { "Native request superseded" }
                }
            }
            check(current(name, slot)) { "Native request superseded" }
            synchronized(this) {
                check(current(name, slot)) { "Native request superseded" }
                slot.completed = result.map { it.requestId to it.generation }
            }
            return result
        } finally { slot.bridge.close() }
    }
}
