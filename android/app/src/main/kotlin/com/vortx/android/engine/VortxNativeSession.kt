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
        rejectCredentials(state)
        return state
    }

    private fun rejectCredentials(value: Any?) {
        when (value) {
            is JSONObject -> value.keys().forEach { key ->
                require(key.lowercase() !in setOf("token", "accesstoken", "refreshtoken", "authkey", "password", "authorization", "bearer")) {
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
                 allowNewAccount: Boolean = false, isAccountCurrent: () -> Boolean = { true }): VortxNativeSession {
            check(isAccountCurrent()) { "Native account changed" }
            val stored = store.read(scope)
            val runtime = if (stored != null) {
                scope.validateSnapshot(stored)
                VortxNativeRuntime.hydrate(bindings, stored)
            } else {
                check(allowNewAccount) { "Native account has no checkpoint; explicit creation or migration required" }
                VortxNativeRuntime.create(bindings, scope.ownerProfileID, ownerName)
            }
            try {
                // Also acts as an additive capability gate. Old artifacts must fail explicitly.
                check(JSONObject(runtime.dispatch(JSONObject().put("type", "bind_sync_scope").put("scope", scope.accountID).toString())).getBoolean("ok")) {
                    "Native sync artifact required"
                }
                val snapshot = runtime.stateJson()
                scope.validateSnapshot(snapshot)
                store.commit(scope, snapshot)
                check(store.read(scope) == snapshot) { "Native checkpoint readback failed" }
                check(isAccountCurrent()) { "Native account changed" }
                return VortxNativeSession(scope, bindings, store, transport, runtime, isAccountCurrent)
            } catch (error: Throwable) { runtime.close(); throw error }
        }
    }

    @Synchronized fun read(): VortxNativeRead {
        check(!closed) { "Native session closed" }
        check(isAccountCurrent()) { "Native account changed" }
        val state = scope.validateSnapshot(runtime.stateJson())
        return VortxNativeRead(VortxNativeOwner(scope, state.getString("activeProfileId"), revision), state)
    }
    @Synchronized fun accepts(owner: VortxNativeOwner): Boolean = !closed && isAccountCurrent() && read().owner == owner
    @Synchronized fun <T> owned(owner: VortxNativeOwner, action: () -> T): T {
        check(accepts(owner)) { "Native owner changed" }; return action()
    }
    @Synchronized fun dispatch(actions: List<JSONObject>, owner: VortxNativeOwner = read().owner): List<String> = owned(owner) {
        val before = runtime.stateJson()
        val candidate = VortxNativeRuntime.hydrate(bindings, before)
        var installed = false
        try {
            val results = actions.map { action ->
                candidate.dispatch(action.toString()).also { check(JSONObject(it).getBoolean("ok")) { "Native action rejected" } }
            }
            val updated = candidate.stateJson()
            val state = scope.validateSnapshot(updated)
            store.commit(scope, updated)
            check(store.read(scope) == updated) { "Native checkpoint readback failed" }
            check(isAccountCurrent()) { "Native account changed" }
            val previous = runtime; runtime = candidate; installed = true; previous.close()
            // Any profile/registry mutation invalidates in-flight resources. Progress does not.
            if (state.getString("activeProfileId") != owner.profileID || actions.any {
                    it.getString("type") in setOf("merge_native_sync", "patch_profile", "delete_profile", "install_addon", "remove_addon", "reorder_addons")
                }) invalidate()
            changes.value += 1
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
