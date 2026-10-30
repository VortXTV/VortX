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

    fun validateSnapshot(snapshot: String, requireSync: Boolean = true): JSONObject =
        validateLocalPresentation(snapshot, requireSync, ownerHistory = false)

    /** Presentation only, after the typed coordinator has replayed the original raw sources. */
    internal fun validateOwnerHistoryPresentation(snapshot: String): JSONObject =
        validateLocalPresentation(snapshot, requireSync = true, ownerHistory = true)

    private fun validateLocalPresentation(snapshot: String, requireSync: Boolean, ownerHistory: Boolean): JSONObject {
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
            val schema = sync.getInt("schemaVersion")
            val admittedSchema = schema in 1..5 && !sync.has("ownerHistory") || ownerHistory && schema == 6
            require(admittedSchema && sync.getString("scope") == accountID &&
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
        state.optJSONObject("nativeHostPreferenceState")?.let { NativeHostPreferences.local(this, it) }
        if (state.has("websiteProfileEditPending") || state.has("websiteProfileEditCertificates")) {
            NativeWebsiteProfileEdits.validateRetained(this,
                state.optJSONObject("websiteProfileEditPending") ?: throw IllegalArgumentException("Website pending carrier missing"),
                state.optJSONObject("websiteProfileEditCertificates") ?: throw IllegalArgumentException("Website certificate carrier missing"))
        }
        if (state.has("websiteAddonEditPending")) NativeWebsiteAddonEdits.validatePending(this, state.getJSONObject("websiteAddonEditPending"))
        if (state.has("nativeHostPreferenceState")) state.getJSONObject("nativeHostPreferenceState")
        if (state.has("legacyImportMaterial")) {
            val material = state.getJSONObject("legacyImportMaterial")
            require(material.getInt("schemaVersion") in 1..2)
            material.getJSONArray("roster"); material.getJSONArray("deletedProfileIds")
            material.getJSONObject("addons"); material.getJSONObject("libraries")
            material.getJSONObject("watches"); material.getJSONObject("identityLinks")
        }
        state.optJSONObject("legacyWebsiteBootstrap")?.let { bootstrap ->
            require(bootstrap.keys().asSequence().toSet() == setOf("aggregate", "legacyImportFingerprint") &&
                bootstrap.get("aggregate") != JSONObject.NULL && bootstrap.getString("legacyImportFingerprint").matches(Regex("[0-9a-f]{64}")))
            NativeHostDocument.requireCredentialFree(bootstrap)
        }
        if (state.has("hostDocument")) {
            NativeWatchedMigrationStorage.read(state.getJSONObject("hostDocument")).requireScope(this)
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

/** Original authenticated encrypted-file observation. No raw bytes are exposed for logging or
 * reconstruction, and copying its plaintext cannot manufacture a compare/replace capability. */
internal class NativeCheckpointRead internal constructor(
    val plaintext: String?,
    private val issuer: Any,
    private val scope: VortxAccountScope,
    private val generation: Long,
    sealed: ByteArray?,
) {
    private val ciphertext = sealed?.copyOf()
    internal fun matches(store: Any, expectedScope: VortxAccountScope, currentGeneration: Long,
                         currentCiphertext: ByteArray?): Boolean {
        if (issuer !== store || scope != expectedScope || generation != currentGeneration) return false
        return if (ciphertext == null) currentCiphertext == null
        else currentCiphertext != null && MessageDigest.isEqual(ciphertext, currentCiphertext)
    }
}

internal interface VortxCheckpointStore {
    /** Null means absent only; decrypt/key/I/O/malformed failures must throw. */
    fun read(scope: VortxAccountScope): String?
    /** Authenticated raw envelope for explicit generic-or-typed routing, never absence-on-error. */
    fun readRetained(scope: VortxAccountScope): String? = read(scope)
    val supportsCheckpointAuthority: Boolean get() = false
    /** Full atomic replacement, durable flush and authenticated readback before returning. */
    fun commit(scope: VortxAccountScope, snapshot: String)
    /** Complete-account routes require an original encrypted-file CAS; old stores cannot pretend support. */
    fun captureCheckpoint(scope: VortxAccountScope): NativeCheckpointRead =
        error("Authenticated checkpoint compare/replace unavailable")
    fun requireCurrentCheckpoint(scope: VortxAccountScope, expected: NativeCheckpointRead) {
        error("Authenticated checkpoint compare/replace unavailable")
    }
    fun compareAndCommitCheckpoint(scope: VortxAccountScope, expected: NativeCheckpointRead,
                                   snapshot: String): NativeCheckpointRead =
        error("Authenticated checkpoint compare/replace unavailable")
    /** Account-authenticated local recovery. Null means no locator, never a failed decrypt. */
    fun discover(accountID: String): VortxAccountScope? = null
    /** Publish the exact immutable owner only after its checkpoint has committed. */
    fun remember(scope: VortxAccountScope) {}
    /** Reject ambiguous older unindexed checkpoints before creating any blank account. */
    fun verifyFreshAccount(scope: VortxAccountScope) {}
    fun verifyOwnerHistoryAbsence(scope: VortxAccountScope, original: NativeCheckpointRead,
                                 preservedPreflight: NativeMigrationPreflight?) {
        require(preservedPreflight == null) { "Retained migration requires authenticated preservation" }
        requireCurrentCheckpoint(scope, original)
        require(original.plaintext == null)
        verifyFreshAccount(scope)
    }
    /** Setup-only evidence; a missing runtime is never replaced with an empty one. */
    fun readPreflight(accountID: String): NativeMigrationPreflight? = null
    fun commitPreflight(next: NativeMigrationPreflight, expected: NativeMigrationPreflight?) {
        error("Encrypted native migration preflight storage unavailable")
    }
}

/** Same sealed format as Apple: nonce(12) + AES-GCM ciphertext + tag(16), account+NUL+owner AAD. */
internal class VortxEncryptedCheckpointStore(
    private val directory: File,
    private val key: (VortxAccountScope) -> SecretKey,
) : VortxCheckpointStore {
    override val supportsCheckpointAuthority: Boolean get() = true
    private val readIssuer = Any()
    private val checkpointGenerations = mutableMapOf<String, Long>()
    private fun checkpointGeneration(scope: VortxAccountScope) = checkpointGenerations[scope.digest] ?: 0L
    private fun retireCheckpointRead(scope: VortxAccountScope) {
        val previous = checkpointGeneration(scope)
        check(previous < Long.MAX_VALUE) { "Checkpoint generation exhausted" }
        checkpointGenerations[scope.digest] = previous + 1
    }
    private fun file(scope: VortxAccountScope) = File(directory, "native-state-v1-${scope.digest}.sealed")
    private fun readSealed(scope: VortxAccountScope): ByteArray? = try {
        val target = file(scope)
        require(Files.size(target.toPath()) <= MAX_BYTES) { "Invalid native checkpoint size" }
        java.io.FileInputStream(target).use { input ->
            val output = java.io.ByteArrayOutputStream()
            val buffer = ByteArray(8192)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                require(output.size().toLong() + count <= MAX_BYTES) { "Invalid native checkpoint size" }
                output.write(buffer, 0, count)
            }
            output.toByteArray()
        }
    } catch (_: java.nio.file.NoSuchFileException) { null }
    private fun open(scope: VortxAccountScope, bytes: ByteArray): String {
        require(bytes.size in 28..MAX_BYTES) { "Invalid native checkpoint" }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(scope), GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
        cipher.updateAAD(scope.authenticatedData)
        val plain = cipher.doFinal(bytes, 12, bytes.size - 12)
        val text = Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(plain)).toString()
        return text
    }
    private fun seal(scope: VortxAccountScope, snapshot: String): ByteArray {
        val plain = snapshot.toByteArray(Charsets.UTF_8)
        require(plain.size <= MAX_BYTES - 28)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key(scope))
        require(cipher.iv.size == 12)
        cipher.updateAAD(scope.authenticatedData)
        return cipher.iv + cipher.doFinal(plain)
    }
    private fun preflightScope(accountID: String) = VortxAccountScope(accountDigest(accountID), "native-migration-preflight-v1")
    private fun preflightFile(accountID: String) = File(directory, "native-preflight-v1-${accountDigest(accountID)}.sealed")
    @Synchronized override fun readPreflight(accountID: String): NativeMigrationPreflight? {
        val target = preflightFile(accountID)
        val outer = try {
            require(Files.size(target.toPath()) <= MAX_BYTES)
            JSONObject(open(preflightScope(accountID), Files.readAllBytes(target.toPath())))
        } catch (_: java.nio.file.NoSuchFileException) { return null }
        require(outer.keys().asSequence().toSet() == setOf("schemaVersion", "accountID", "ownerProfileID", "sealedPayload") &&
            outer.getInt("schemaVersion") == 1 && outer.getString("accountID") == accountID)
        val scope = VortxAccountScope(accountID, outer.getString("ownerProfileID"))
        val encoded = outer.getString("sealedPayload")
        val sealed = java.util.Base64.getDecoder().decode(encoded)
        require(java.util.Base64.getEncoder().encodeToString(sealed) == encoded)
        return NativeMigrationPreflight.parse(scope, open(scope, sealed))
    }
    @Synchronized override fun commitPreflight(next: NativeMigrationPreflight, expected: NativeMigrationPreflight?) {
        val prior = readPreflight(next.scope.accountID)
        require(prior?.raw == expected?.raw && (prior == null || prior.scope == next.scope)) { "Native migration setup changed" }
        NativeMigrationPreflight.parse(next.scope, next.raw)
        val outer = JSONObject().put("schemaVersion", 1).put("accountID", next.scope.accountID)
            .put("ownerProfileID", next.scope.ownerProfileID)
            .put("sealedPayload", java.util.Base64.getEncoder().encodeToString(seal(next.scope, next.raw)))
        replace(preflightScope(next.scope.accountID), preflightFile(next.scope.accountID), outer.toString())
        check(readPreflight(next.scope.accountID)?.raw == next.raw) { "Native migration preflight readback failed" }
    }
    @Synchronized override fun read(scope: VortxAccountScope): String? {
        val target = file(scope)
        // exists() hides access failures; only the explicit no-such-file exception means absent.
        return try {
            require(Files.size(target.toPath()) <= MAX_BYTES)
            open(scope, Files.readAllBytes(target.toPath())).also(scope::validateSnapshot)
        } catch (_: java.nio.file.NoSuchFileException) { null }
    }
    @Synchronized override fun readRetained(scope: VortxAccountScope): String? = captureCheckpoint(scope).plaintext
    @Synchronized override fun commit(scope: VortxAccountScope, snapshot: String) {
        scope.validateSnapshot(snapshot)
        // A failed rename/readback is uncertain too; no older captured read may retry over it.
        retireCheckpointRead(scope)
        replace(scope, file(scope), snapshot)
        check(read(scope) == snapshot) { "Native checkpoint readback failed" }
    }
    @Synchronized override fun captureCheckpoint(scope: VortxAccountScope): NativeCheckpointRead {
        val sealed = readSealed(scope)
        return NativeCheckpointRead(sealed?.let { open(scope, it) }, readIssuer, scope,
            checkpointGeneration(scope), sealed)
    }
    @Synchronized override fun requireCurrentCheckpoint(scope: VortxAccountScope, expected: NativeCheckpointRead) {
        check(expected.matches(readIssuer, scope, checkpointGeneration(scope), readSealed(scope))) { "Native checkpoint changed" }
    }
    @Synchronized override fun compareAndCommitCheckpoint(scope: VortxAccountScope, expected: NativeCheckpointRead,
                                                         snapshot: String): NativeCheckpointRead {
        val current = readSealed(scope)
        check(expected.matches(readIssuer, scope, checkpointGeneration(scope), current)) { "Native checkpoint changed" }
        // Validation/replay/whole-account budgeting is owned by the same Session admission;
        // this storage layer does not turn an interpretation-only JSONObject into its raw source.
        require(snapshot.toByteArray(Charsets.UTF_8).size <= MAX_BYTES - 28)
        retireCheckpointRead(scope)
        replace(scope, file(scope), snapshot, replaceExisting = current != null)
        val accepted = captureCheckpoint(scope)
        check(accepted.plaintext == snapshot) { "Native checkpoint readback failed" }
        return accepted
    }
    // The locator has a separate key/AAD domain. Neither owner identity nor roster is stored in
    // plaintext. A crash between state and locator publication leaves recoverable state, not an
    // apparently empty account. Older checkpoints gain a locator on their next authenticated pull.
    private fun accountDigest(accountID: String) = MessageDigest.getInstance("SHA-256").digest(accountID.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }
    private fun locatorScope(accountID: String) = VortxAccountScope(accountDigest(accountID), "native-account-locator-v1")
    private fun locatorFile(accountID: String) = File(directory, "native-account-v1-${accountDigest(accountID)}.sealed")
    private fun readLocator(target: File): VortxAccountScope {
        val digest = target.name.removePrefix("native-account-v1-").removeSuffix(".sealed")
        require(Regex("[0-9a-f]{64}").matches(digest))
        require(Files.size(target.toPath()) <= MAX_BYTES)
        val descriptor = JSONObject(open(VortxAccountScope(digest, "native-account-locator-v1"), Files.readAllBytes(target.toPath())))
        require(descriptor.getInt("schemaVersion") == 1 && accountDigest(descriptor.getString("accountID")) == digest)
        return VortxAccountScope(descriptor.getString("accountID"), descriptor.getString("ownerProfileID"))
    }
    @Synchronized override fun discover(accountID: String): VortxAccountScope? {
        val target = locatorFile(accountID)
        val scope = try { readLocator(target) } catch (_: java.nio.file.NoSuchFileException) { return null }
        require(scope.accountID == accountID)
        validateStoredCheckpoint(scope, checkNotNull(captureCheckpoint(scope).plaintext) { "Native account locator has no checkpoint" })
        return scope
    }
    @Synchronized override fun verifyFreshAccount(scope: VortxAccountScope) {
        require(readPreflight(scope.accountID) == null) { "Authenticated native migration is still pending" }
        verifyNoUnindexedCheckpoint(scope)
    }
    @Synchronized override fun verifyOwnerHistoryAbsence(scope: VortxAccountScope, original: NativeCheckpointRead,
                                                       preservedPreflight: NativeMigrationPreflight?) {
        requireCurrentCheckpoint(scope, original)
        require(original.plaintext == null)
        val retained = readPreflight(scope.accountID)
        require(retained?.raw == preservedPreflight?.raw && (retained == null || retained.scope == scope)) {
            "Original migration setup changed"
        }
        verifyNoUnindexedCheckpoint(scope)
    }
    private fun verifyNoUnindexedCheckpoint(scope: VortxAccountScope) {
        discover(scope.accountID)?.let { require(it == scope); return }
        val files = try { Files.list(directory.toPath()).use { paths -> paths.iterator().asSequence().map { it.toFile() }.toList() } }
            catch (_: java.nio.file.NoSuchFileException) { return }
        val located = files.filter { it.name.startsWith("native-account-v1-") && it.name.endsWith(".sealed") }
            .map(::readLocator).map { file(it).name }.toSet()
        require(files.none { it.name.startsWith("native-state-v1-") && it.name.endsWith(".sealed") && it.name !in located }) {
            "An older unindexed native checkpoint requires authenticated recovery before account creation"
        }
    }
    @Synchronized override fun remember(scope: VortxAccountScope) {
        val old = discover(scope.accountID)
        require(old == null || old == scope) { "Native account owner changed" }
        validateStoredCheckpoint(scope, checkNotNull(captureCheckpoint(scope).plaintext) { "Cannot publish an absent native checkpoint" })
        if (old == scope) return
        val descriptor = JSONObject().put("schemaVersion", 1).put("accountID", scope.accountID)
            .put("ownerProfileID", scope.ownerProfileID).toString()
        replace(locatorScope(scope.accountID), locatorFile(scope.accountID), descriptor)
        check(discover(scope.accountID) == scope) { "Native account locator readback failed" }
    }
    private fun validateStoredCheckpoint(scope: VortxAccountScope, snapshot: String) {
        if (JSONObject(snapshot).optString("kind") == "vortx.owner-history.checkpoint/1") {
            // Routing is not acceptance: the typed decoder verifies exact keys, integers,
            // scope and canonical base64. Full source replay happens before Session publication.
            NativeOwnerHistoryCoordinator.decodeEnvelope(snapshot.toByteArray(Charsets.UTF_8), scope)
        } else scope.validateSnapshot(snapshot)
    }
    private fun replace(scope: VortxAccountScope, target: File, snapshot: String, replaceExisting: Boolean = true) {
        val sealed = seal(scope, snapshot)
        Files.createDirectories(directory.toPath())
        val pending = Files.createTempFile(directory.toPath(), "native-checkpoint-", ".pending")
        try {
            FileOutputStream(pending.toFile()).use { it.write(sealed); it.fd.sync() }
            if (replaceExisting) {
                Files.move(pending, target.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
            } else {
                // Same-filesystem hard-link is create-only. A raced first checkpoint is never replaced.
                Files.createLink(target.toPath(), pending)
            }
            FileChannel.open(directory.toPath(), StandardOpenOption.READ).use { it.force(true) }
            check(open(scope, Files.readAllBytes(target.toPath())) == snapshot) { "Native sealed readback failed" }
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
    private var nativeHostPreferenceState: JSONObject,
    private var legacyImportMaterial: JSONObject?,
    private var hostDocumentArchive: JSONObject?,
    private var legacyWebsiteBootstrap: JSONObject?,
    private var websiteProfileEditPending: JSONObject,
    private var websiteProfileEditCertificates: JSONObject,
    private var websiteAddonEditPending: JSONObject,
    private val onMutation: () -> Unit,
    private val beforeOwnerChange: () -> Unit,
    /** A committed playback-progress report: the account upload may wait for playback to go quiet. */
    private val onProgressMutation: () -> Unit = onMutation,
    private var ownerHistory: NativeOwnerHistorySessionAdapter? = null,
    private val ownerHistoryAuthority: NativeOwnerHistoryAuthority? = null,
    initialRawHostState: ByteArray,
) : AutoCloseable {
    /** Captured before decode from the authenticated local checkpoint, or freshly minted when
     * there was no local host state. This is persistence material, not a new write capability. */
    private var rawNativeHostPreferenceState = NativeRawHostPreferences.captureLocal(scope, initialRawHostState)
    /** Cheap read-only observation validity, never account/native/load authority or cached health. */
    internal class XperienceObservation private constructor() : AutoCloseable {
        private val live = java.util.concurrent.atomic.AtomicBoolean(true)
        fun isCurrent(): Boolean = live.get()
        override fun close() { live.set(false) }
        companion object { internal fun issued() = XperienceObservation() }
    }
    private class XperienceObservedProfile(val fields: Map<String, ByteArray>) {
        val tokens = ArrayList<java.lang.ref.WeakReference<XperienceObservation>>()
        fun prune() { tokens.removeAll { it.get()?.isCurrent() != true } }
        fun close() { tokens.forEach { it.get()?.close() }; fields.values.forEach { it.fill(0) }; tokens.clear() }
    }
    private val xperienceObservations = linkedMapOf<String, XperienceObservedProfile>()
    @Synchronized internal fun captureXperienceObservation(owner: VortxNativeOwner): XperienceObservation = owned(owner) {
        check(!requiresRecovery())
        pruneXperienceObservations()
        val profile = NativeHostPreferences.canonicalProfileID(owner.profileID)
        val observed = xperienceObservations.getOrPut(profile) {
            XperienceObservedProfile(NativeXperienceWrite.fields(rawNativeHostPreferenceState, profile))
        }
        XperienceObservation.issued().also { observed.tokens += java.lang.ref.WeakReference(it) }
    }
    private fun pruneXperienceObservations() {
        val iterator = xperienceObservations.iterator()
        while (iterator.hasNext()) {
            val (_, group) = iterator.next(); group.prune()
            if (group.tokens.isEmpty()) { group.close(); iterator.remove() }
        }
    }
    private fun retireXperienceObservations() {
        xperienceObservations.values.forEach { it.close() }; xperienceObservations.clear()
    }
    /** Both typed receive and ordinary checkpoint installation use this exact raw path.
     * One retained raw family per actively observed profile; weak tokens never retain callers.
     * Compare only active profiles and preserve tokens on byte-equal family/progress updates. */
    private fun replaceRawHostPreferenceState(next: ByteArray) {
        pruneXperienceObservations()
        if (!rawNativeHostPreferenceState.contentEquals(next)) {
            val iterator = xperienceObservations.iterator()
            while (iterator.hasNext()) {
                val (profile, group) = iterator.next()
                val fields = NativeXperienceWrite.fields(next, profile)
                try {
                    if (group.fields.keys != fields.keys || group.fields.any { (key, raw) -> !raw.contentEquals(fields[key]) }) {
                        group.close(); iterator.remove() // Revoke before replacing raw state; ABA cannot resurrect.
                    }
                } finally { fields.values.forEach { it.fill(0) } }
            }
        }
        rawNativeHostPreferenceState.fill(0); rawNativeHostPreferenceState = next
    }
    private var rawHostMergeActive = false
    private var rawHostMerge: ByteArray? = null
    private data class Slot(val ticket: UUID, val owner: VortxNativeOwner,
                            val bridges: MutableList<VortxResourceBridge> = mutableListOf(),
                            var completed: List<Pair<String, Long>>? = null) {
        fun close() = bridges.forEach { it.close() }
    }
    private val slots = mutableMapOf<String, Slot>()
    /** The kernel's reason the latest offered legacy delta was held; null once one is accepted. */
    @Volatile var heldLegacyReconciliation: String? = null
        private set
    private var revision = nextRevision.incrementAndGet()
    private var closed = false
    private var retirementComplete = false
    private var checkpointUncertain = false
    private var unconfirmedHistoryRetirement = false
    private var acknowledgedCheckpoint: NativeCheckpointRead? = null
    private val changes = MutableStateFlow(0L)
    val updates: StateFlow<Long> get() = changes
    private val playlistRevisions = MutableStateFlow(0L)
    // Read-only receipt identity: profile changes, including an ABA, advance this epoch.
    // Same-profile peer merges may invalidate mutation/resource revisions without replacing it.
    private var playlistReceiptProfileEpoch = 0L
    /** Narrow invalidation for exact-target admission/revision loss and playlist projection changes. */
    internal val playlistUpdates: StateFlow<Long> get() = playlistRevisions
    /** Emit only after the changed projection or unavailable admission is already observable. */
    private fun signalPlaylistInvalidation() { playlistRevisions.value += 1 }
    private fun enterCheckpointUncertainty() {
        if (checkpointUncertain) return
        checkpointUncertain = true
        retireXperienceObservations()
        signalPlaylistInvalidation()
    }

    /** Mint read-only receipt identity in the SAME complete-account capture as its mutation target.
     * No separate generic flag or raw-GET observation can later upgrade an existing receipt to a
     * write permit. The coordinator still admits its original account/mount before publishing it. */
    @Synchronized internal fun <T> withPlaylistReceiptCapture(
        genericReadAvailable: Boolean = false,
        action: (VortxNativeRead, Long) -> T,
    ): T {
        requireCompleteAccountExportRoute(genericReadAvailable)
        return action(read(), playlistReceiptProfileEpoch)
    }

    /** A frozen upload may receive a same-profile GET/merge after receipt capture. That retires
     * mutation revision and raw-read identity, but not this read-only receipt scope. Never consult
     * the old GET or prospective-write permit here, and never mint a replacement owner. */
    @Synchronized internal fun <T> withPlaylistReceiptEpoch(owner: VortxNativeOwner, epoch: Long, action: () -> T): T {
        check(!closed && !requiresRecovery() && isAccountCurrent()) { "Playlist receipt session unavailable" }
        check(owner.scope == scope && epoch == playlistReceiptProfileEpoch) { "Playlist receipt owner changed" }
        return action()
    }

    private fun validatePresentation(snapshot: String): JSONObject = if (runtime.isTyped)
        scope.validateOwnerHistoryPresentation(snapshot) else scope.validateSnapshot(snapshot)

    companion object {
        private val nextRevision = AtomicLong()
        fun open(scope: VortxAccountScope, ownerName: String, bindings: VortxRuntimeBindings,
                 store: VortxCheckpointStore, transport: VortxResourceTransport,
                 allowNewAccount: Boolean = false, bootstrapActions: List<JSONObject> = emptyList(),
                 initialHostProfiles: JSONObject = JSONObject(), initialHostArchive: JSONObject? = null,
                 initialHostPreferences: JSONObject? = null,
                 initialLegacyWatchlists: Map<String, List<com.vortx.android.library.WatchlistEntry>> = emptyMap(),
                 verifyCandidate: ((VortxNativeRuntime) -> Unit)? = null,
                 onMutation: () -> Unit = {}, beforeOwnerChange: () -> Unit = {},
                 onProgressMutation: () -> Unit = onMutation,
                 ownerHistoryBindings: NativeOwnerHistoryBindings = NativeOwnerHistoryJniBindings,
                 ownerHistoryAuthority: NativeOwnerHistoryAuthority? = null,
                 initialRawHostPreferences: ByteArray? = null,
                 isAccountCurrent: () -> Boolean = { true }): VortxNativeSession {
            check(isAccountCurrent()) { "Native account changed" }
            scope.rejectCredentials(initialHostProfiles)
            scope.rejectCredentials(initialHostArchive)
            bootstrapActions.forEach(scope::rejectCredentials)
            val stored = store.readRetained(scope)
            // Capture the encrypted plaintext slice BEFORE JSONObject/hydration normalization.
            val storedRawHost = stored?.takeUnless(NativeOwnerHistorySessionAdapter::isEnvelope)?.let {
                OHJson.Obj(it.toByteArray(Charsets.UTF_8))["nativeHostPreferenceState"]
            }
            NativeRawHostPreferences.requireIncomingObservation(scope, initialHostPreferences, initialRawHostPreferences)
            if (stored != null && NativeOwnerHistorySessionAdapter.isEnvelope(stored)) {
                require(bootstrapActions.isEmpty()) { "Typed peer changes require the raw account route" }
                val original = store.captureCheckpoint(scope)
                check(original.plaintext == stored) { "Native checkpoint changed during open" }
                return openOwnerHistory(scope, NativeOwnerHistoryCoordinator.decodeEnvelope(stored.toByteArray(Charsets.UTF_8), scope),
                    original, bindings, ownerHistoryBindings, store, transport, requireNotNull(ownerHistoryAuthority),
                    onMutation, beforeOwnerChange, onProgressMutation, isAccountCurrent)
            }
            val runtime = if (stored != null) {
                val retained = scope.validateSnapshot(stored)
                // Earlier experimental checkpoints may contain encoded credentials in adjacent
                // carriers. Inspect BEFORE hydrate; rejection leaves the original encrypted file
                // untouched. Newer stored prefs must not bypass sanitized incoming preferences.
                for (field in listOf("hostProfilePreferences", "legacyImportMaterial", "hostDocument", "nativeHostPreferenceState", "legacyWebsiteBootstrap", "websiteProfileEditPending", "websiteAddonEditPending")) {
                    retained.optJSONObject(field)?.let(NativeHostDocument::requireCredentialFree)
                }
                val core = JSONObject(stored).also {
                    it.remove("hostProfilePreferences"); it.remove("legacyImportMaterial")
                    it.remove("hostProfileSyncPending")
                    it.remove("nativeHostPreferenceState")
                    it.remove("hostDocument"); it.remove("excludedCredentialPaths")
                    it.remove("legacyWebsiteBootstrap")
                    it.remove("websiteProfileEditPending"); it.remove("websiteProfileEditCertificates")
                    it.remove("websiteAddonEditPending")
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
                var heldBootstrap: JSONObject? = null
                var heldBootstrapReason: String? = null
                for (action in bootstrapActions) {
                    val result = runtime.dispatch(action.toString())
                    if (JSONObject(result).optBoolean("ok")) continue
                    check(NativeLegacyReconciliationPolicy.holdable(action) && heldBootstrap == null) { "Native account bootstrap rejected" }
                    heldBootstrap = action; heldBootstrapReason = NativeLegacyReconciliationPolicy.rejectionCode(result)
                }
                val old = stored?.let(::JSONObject)
                val storedProfiles = old?.optJSONObject("hostProfilePreferences")
                var hostProfiles = if (storedProfiles == null || initialHostProfiles.optDouble("modifiedSeconds", 0.0) > storedProfiles.optDouble("modifiedSeconds", 0.0))
                    initialHostProfiles else storedProfiles
                var hostPending = old?.optBoolean("hostProfileSyncPending", false) == true ||
                    (old != null && !old.has("hostProfileSyncPending") && storedProfiles != null && hostProfiles === storedProfiles &&
                        initialHostProfiles.length() > 0 && NativeHostProfiles.hasUnexportedChanges(initialHostProfiles, storedProfiles))
                var hostState = NativeHostPreferences.local(scope, old?.optJSONObject("nativeHostPreferenceState"))
                // Upgrade existing encrypted local-only intent against the authenticated immutable
                // baseline. Do not infer a baseline from an offline/global preference store.
                if (hostPending && initialHostProfiles.length() > 0) {
                    hostState = NativeHostPreferences.recordProfiles(scope, hostState, initialHostProfiles, hostProfiles)
                    hostPending = false
                }
                hostState = NativeHostPreferences.merge(scope, hostState, initialHostPreferences)
                val liveRoster = JSONObject(runtime.stateJson()).getJSONObject("roster").getJSONObject("profiles")
                hostState = NativeHostPreferences.seedWatchlists(scope, hostState, initialLegacyWatchlists.filterKeys {
                    liveRoster.optJSONObject(it)?.optBoolean("deleted") == false
                })
                val rawHostState = NativeRawHostPreferences.reconcile(scope, storedRawHost, hostState,
                    initialHostPreferences, initialRawHostPreferences)
                hostProfiles = NativeHostPreferences.projectProfiles(hostState, hostProfiles,
                    JSONObject(runtime.stateJson()).getJSONObject("roster").getJSONObject("profiles"))
                NativeHostPreferences.validateProjectedProfiles(hostProfiles)
                // Preserve exact typed source clocks beside the receipt, never the credential-bearing cloud document.
                // A held material was rejected: never adopt it as the retained baseline.
                val legacyMaterial = old?.optJSONObject("legacyImportMaterial")
                    ?: bootstrapActions.firstOrNull { it !== heldBootstrap && it.getString("type") in setOf("import_legacy_sync", "reconcile_legacy_sync") }?.getJSONObject("material")
                val archive = initialHostArchive ?: old?.optJSONObject("hostDocument")?.let {
                    JSONObject().put("document", it).put("excludedCredentialPaths", old.getJSONArray("excludedCredentialPaths"))
                }
                // A blank local checkpoint is not proof of an original aggregate when this open
                // adopts a peer's native baseline. Only this account's first import action binds
                // the sealed aggregate to its original legacy-import fingerprint.
                val importedLocally = bootstrapActions.any { it.optString("type") == "import_legacy_sync" }
                val legacyBootstrap = old?.optJSONObject("legacyWebsiteBootstrap") ?: if (stored == null && importedLocally) initialHostArchive
                    ?.getJSONObject("document")?.opt("profileEdits")?.takeIf { it != JSONObject.NULL && (it !is JSONObject || it.length() > 0) }
                    ?.let { raw -> JSONObject().put("aggregate", raw).put("legacyImportFingerprint", JSONObject(runtime.stateJson()).getJSONObject("nativeSync")
                        .getJSONObject("legacyImport").getString("fingerprint")) } else null
                legacyBootstrap?.let { NativeHostDocument.requireCredentialFree(it) }
                val pendingWebsiteEdits = old?.optJSONObject("websiteProfileEditPending") ?: JSONObject().put("events", JSONArray())
                val websiteCertificates = old?.optJSONObject("websiteProfileEditCertificates") ?: JSONObject()
                NativeWebsiteProfileEdits.validateRetained(scope, pendingWebsiteEdits, websiteCertificates)
                val pendingAddonEdits = old?.optJSONObject("websiteAddonEditPending") ?: NativeWebsiteAddonEdits.emptyPending()
                NativeWebsiteAddonEdits.validatePending(scope, pendingAddonEdits)
                val snapshotProjection = JSONObject(runtime.stateJson()).put("hostProfilePreferences", hostProfiles).put("hostProfileSyncPending", hostPending).put("legacyImportMaterial", legacyMaterial)
                    .put("nativeHostPreferenceState", hostState)
                    .put("hostDocument", archive?.getJSONObject("document")).put("excludedCredentialPaths", archive?.getJSONArray("excludedCredentialPaths"))
                    .put("legacyWebsiteBootstrap", legacyBootstrap)
                    .put("websiteProfileEditPending", pendingWebsiteEdits).put("websiteProfileEditCertificates", websiteCertificates)
                    .put("websiteAddonEditPending", pendingAddonEdits).toString()
                val snapshot = NativeRawHostPreferences.snapshot(snapshotProjection, rawHostState)
                scope.validateSnapshot(snapshot)
                verifyCandidate?.invoke(runtime)
                store.commit(scope, snapshot)
                check(store.read(scope) == snapshot) { "Native checkpoint readback failed" }
                check(isAccountCurrent()) { "Native account changed" }
                return VortxNativeSession(scope, bindings, store, transport, runtime, isAccountCurrent, JSONObject(hostProfiles.toString()), hostPending, hostState,
                    legacyMaterial?.let { JSONObject(it.toString()) }, archive?.let { JSONObject(it.toString()) },
                    legacyBootstrap?.let { JSONObject(it.toString()) },
                    JSONObject(pendingWebsiteEdits.toString()), JSONObject(websiteCertificates.toString()), NativeWebsiteAddonEdits.detached(pendingAddonEdits), onMutation, beforeOwnerChange,
                    onProgressMutation = onProgressMutation, ownerHistoryAuthority = ownerHistoryAuthority,
                    initialRawHostState = rawHostState)
                    .also {
                        it.heldLegacyReconciliation = heldBootstrapReason
                        if (store.supportsCheckpointAuthority) {
                            it.acknowledgedCheckpoint = store.captureCheckpoint(scope).also { read ->
                                check(read.plaintext == snapshot) { "Native checkpoint changed after admission" }
                            }
                        }
                    }
            } catch (error: Throwable) { runtime.close(); throw error }
        }
        internal fun openOwnerHistory(scope: VortxAccountScope, checkpoint: NativeOwnerHistoryCoordinator.Checkpoint,
            original: NativeCheckpointRead, bindings: VortxRuntimeBindings, historyBindings: NativeOwnerHistoryBindings,
            store: VortxCheckpointStore, transport: VortxResourceTransport, authority: NativeOwnerHistoryAuthority,
            onMutation: () -> Unit, beforeOwnerChange: () -> Unit, onProgressMutation: () -> Unit,
            isAccountCurrent: () -> Boolean,
            openingAuthority: NativeOwnerHistoryAuthority = authority): VortxNativeSession {
            val adapter = NativeOwnerHistorySessionAdapter.open(scope, checkpoint, original, historyBindings, store, authority, openingAuthority)
            try {
                val state = NativeProfileOverlayWitness.parseAccountDocument(adapter.presentation())
                val raw = OHJson.Obj(checkpoint.snapshot)
                // Explicit adjacent host projections only; raw unknown/source roots never enter
                // JSONObject and remain in the accepted checkpoint unchanged.
                listOf("hostDocument", "excludedCredentialPaths", "legacyImportMaterial", "legacyWebsiteBootstrap").forEach { key ->
                    raw[key]?.let { value ->
                        val boxed = NativeProfileOverlayWitness.parseAccountDocument(OHJson.Obj().set("value", value).encoded())
                        state.put(key, boxed.get("value"))
                    }
                }
                val host = NativeHostPreferences.local(scope, JSONObject(OHJson.utf8(checkpoint.hostPreferences)))
                val profiles = NativeHostPreferences.projectProfiles(host, state.optJSONObject("hostProfilePreferences") ?: JSONObject(),
                    state.getJSONObject("roster").getJSONObject("profiles"))
                val archive = state.optJSONObject("hostDocument")?.let {
                    JSONObject().put("document", it).put("excludedCredentialPaths", state.getJSONArray("excludedCredentialPaths"))
                }
                val session = VortxNativeSession(scope, bindings, store, transport, adapter.view(), isAccountCurrent,
                    profiles, state.optBoolean("hostProfileSyncPending"), host, state.optJSONObject("legacyImportMaterial"),
                    archive, state.optJSONObject("legacyWebsiteBootstrap"),
                    state.optJSONObject("websiteProfileEditPending") ?: JSONObject().put("events", JSONArray()),
                    state.optJSONObject("websiteProfileEditCertificates") ?: JSONObject(),
                    state.optJSONObject("websiteAddonEditPending") ?: NativeWebsiteAddonEdits.emptyPending(),
                    onMutation, beforeOwnerChange, onProgressMutation, adapter, authority,
                    initialRawHostState = checkpoint.hostPreferences)
                session.read() // Real typed-source validation preceded this presentation admission.
                return session
            } catch (failure: Throwable) { adapter.close(); throw failure }
        }
        /** Restore the ORIGINAL generic file for a same-monitor warm transfer, without rewriting
         * it first. Unknown raw fields stay in the original encrypted read for the typed union. */
        internal fun openForOwnerHistoryTransfer(scope: VortxAccountScope, original: NativeCheckpointRead,
            bindings: VortxRuntimeBindings, store: VortxCheckpointStore, transport: VortxResourceTransport,
            onMutation: () -> Unit, beforeOwnerChange: () -> Unit, onProgressMutation: () -> Unit,
            isAccountCurrent: () -> Boolean, authority: NativeOwnerHistoryAuthority): VortxNativeSession {
            store.requireCurrentCheckpoint(scope, original)
            val raw = checkNotNull(original.plaintext)
            val state = scope.validateSnapshot(raw)
            val core = JSONObject(raw).also { value ->
                listOf("hostProfilePreferences", "hostProfileSyncPending", "nativeHostPreferenceState", "legacyImportMaterial",
                    "hostDocument", "excludedCredentialPaths", "legacyWebsiteBootstrap", "websiteProfileEditPending",
                    "websiteProfileEditCertificates", "websiteAddonEditPending").forEach(value::remove)
            }
            val runtime = VortxNativeRuntime.hydrate(bindings, core.toString())
            try {
                store.requireCurrentCheckpoint(scope, original)
                val host = NativeHostPreferences.local(scope, state.optJSONObject("nativeHostPreferenceState"))
                // Absence mints a new local actor; a present original slice is always retained.
                val rawHost = OHJson.Obj(raw.toByteArray(Charsets.UTF_8))["nativeHostPreferenceState"]
                    ?: host.toString().toByteArray(Charsets.UTF_8)
                val archive = state.optJSONObject("hostDocument")?.let {
                    JSONObject().put("document", it).put("excludedCredentialPaths", state.getJSONArray("excludedCredentialPaths"))
                }
                return VortxNativeSession(scope, bindings, store, transport, runtime, isAccountCurrent,
                    state.optJSONObject("hostProfilePreferences") ?: JSONObject(), state.optBoolean("hostProfileSyncPending"),
                    host, state.optJSONObject("legacyImportMaterial"),
                    archive, state.optJSONObject("legacyWebsiteBootstrap"),
                    state.optJSONObject("websiteProfileEditPending") ?: JSONObject().put("events", JSONArray()),
                    state.optJSONObject("websiteProfileEditCertificates") ?: JSONObject(),
                    state.optJSONObject("websiteAddonEditPending") ?: NativeWebsiteAddonEdits.emptyPending(),
                    onMutation, beforeOwnerChange, onProgressMutation, ownerHistoryAuthority = authority,
                    initialRawHostState = rawHost)
                    .also { it.acknowledgedCheckpoint = original }
            } catch (failure: Throwable) { runtime.close(); throw failure }
        }
    }

    @Synchronized fun read(): VortxNativeRead {
        check(!closed) { "Native session closed" }
        check(isAccountCurrent()) { "Native account changed" }
        val state = validatePresentation(JSONObject(runtime.stateJson()).put("hostProfilePreferences", hostProfilePreferences)
            .put("hostProfileSyncPending", hostProfileSyncPending)
            .put("nativeHostPreferenceState", nativeHostPreferenceState)
            .put("legacyImportMaterial", legacyImportMaterial).put("hostDocument", hostDocumentArchive?.getJSONObject("document"))
            .put("excludedCredentialPaths", hostDocumentArchive?.getJSONArray("excludedCredentialPaths"))
            .put("legacyWebsiteBootstrap", legacyWebsiteBootstrap)
            .put("websiteProfileEditPending", websiteProfileEditPending)
            .put("websiteProfileEditCertificates", websiteProfileEditCertificates)
            .put("websiteAddonEditPending", websiteAddonEditPending).toString())
        return VortxNativeRead(VortxNativeOwner(scope, state.getString("activeProfileId"), revision), state)
    }
    @Synchronized fun requiresRecovery(): Boolean = checkpointUncertain || ownerHistory?.requiresRecovery() == true
    @Synchronized fun hasOwnerHistory(): Boolean = ownerHistory != null
    @Synchronized fun rawAccount(): ByteArray? = ownerHistory?.cloudAccount()
    /** Detached readonly raw observation. Never accepts an owner or grants mutation authority. */
    @Synchronized internal fun rawHostPreferences(): ByteArray {
        check(!closed && !requiresRecovery() && isAccountCurrent())
        return NativeRawHostPreferences.document(rawNativeHostPreferenceState)
    }

    /** The coordinator provides the authenticated source slice under its EXISTING account,
     * Session and mount admission. This synchronous scope carries provenance only; dispatch still
     * performs all original authority/fork/checkpoint checks. No source is recaptured on resume. */
    @Synchronized internal fun <T> withRawHostMerge(raw: ByteArray?, action: () -> T): T {
        check(!rawHostMergeActive) { "Nested raw host observation" }
        rawHostMergeActive = true; rawHostMerge = raw?.copyOf()
        return try { action() } finally {
            rawHostMerge?.fill(0); rawHostMerge = null; rawHostMergeActive = false
        }
    }
    @Synchronized fun accepts(owner: VortxNativeOwner): Boolean = !closed && !requiresRecovery() && isAccountCurrent() && read().owner == owner

    private fun requireCompleteAccountExportRoute(genericReadAvailable: Boolean = false) {
        check(!closed && !requiresRecovery() && isAccountCurrent() &&
            (runtime.isTyped || (genericReadAvailable && store.supportsCheckpointAuthority && acknowledgedCheckpoint != null))) {
            "Complete account export budget unavailable"
        }
    }
    @Synchronized internal fun captureGenericPlaylistCheckpoint(owner: VortxNativeOwner): NativeCheckpointRead? = owned(owner) {
        if (runtime.isTyped) null else checkNotNull(acknowledgedCheckpoint).also {
            check(store.supportsCheckpointAuthority)
            store.requireCurrentCheckpoint(scope, it)
        }
    }

    /** Logical projection only, never raw persistence provenance or a catalog/fetch permit. Capture
     * the original profile/registry/binding and inherited addon preferences before suspension. */
    internal fun xperienceContext(read: VortxNativeRead): String {
        val host = read.state.getJSONObject("hostProfilePreferences")
        val preferences = JSONObject()
        setOf(read.owner.profileID, scope.ownerProfileID).forEach { id ->
            preferences.put(id, host.optJSONObject(id)?.optJSONObject("addonPreferences") ?: JSONObject.NULL)
        }
        return JSONObject().put("roster", read.state.getJSONObject("roster"))
            .put("addons", read.state.getJSONObject("nativeSync").getJSONObject("addons"))
            .put("bindings", bindingSelections(read.state)).put("preferences", preferences).toString()
    }
    @Synchronized internal fun xperienceFields(owner: VortxNativeOwner): Map<String, ByteArray> = owned(owner) {
        NativeXperienceWrite.fields(rawNativeHostPreferenceState, owner.profileID)
    }

    /** Retains actual original runtime/checkpoint identity, not a decoded account surrogate. */
    internal class XperienceOperation private constructor(
        internal val session: VortxNativeSession,
        internal val owner: VortxNativeOwner,
        internal val runtime: VortxNativeRuntime,
        internal val checkpoint: NativeCheckpointRead?,
        internal val typedCheckpoint: NativeOwnerHistoryCoordinator.Checkpoint?,
        internal val context: String,
        internal val change: NativeXperienceWrite.Change,
        raw: ByteArray,
    ) : AutoCloseable {
        private var raw: ByteArray? = raw.copyOf()
        internal fun matches(value: ByteArray) = raw?.contentEquals(value) == true
        override fun close() { raw?.fill(0); raw = null }
        companion object {
            internal fun capture(session: VortxNativeSession, owner: VortxNativeOwner, runtime: VortxNativeRuntime,
                checkpoint: NativeCheckpointRead?, typed: NativeOwnerHistoryCoordinator.Checkpoint?,
                context: String, change: NativeXperienceWrite.Change, raw: ByteArray) =
                XperienceOperation(session, owner, runtime, checkpoint, typed, context, change, raw)
        }
    }
    @Synchronized internal fun captureXperienceOperation(owner: VortxNativeOwner, context: String,
        change: NativeXperienceWrite.Change, genericReadAvailable: Boolean): XperienceOperation =
        withCompleteAccountExportOwner(owner, genericReadAvailable) { read ->
            check(xperienceContext(read) == context) { "Original Xperience context changed" }
            NativeXperienceWrite.requireClocks(rawNativeHostPreferenceState)
            change.admit(NativeXperienceWrite.register(rawNativeHostPreferenceState, owner.profileID, change.field))
            val checkpoint = captureGenericPlaylistCheckpoint(owner)
            val typed = ownerHistory?.checkpoint()
            check((typed != null) == runtime.isTyped) { "Original typed checkpoint unavailable" }
            XperienceOperation.capture(this, owner, runtime, checkpoint, typed, context, change, rawNativeHostPreferenceState)
        }
    private fun requireXperienceOperation(operation: XperienceOperation) {
        check(operation.session === this && operation.runtime === runtime && accepts(operation.owner) &&
            operation.matches(rawNativeHostPreferenceState) &&
            xperienceContext(read()) == operation.context) { "Original Xperience operation changed" }
        if (operation.typedCheckpoint != null) check(ownerHistory?.checkpoint() === operation.typedCheckpoint) {
            "Original typed Xperience checkpoint changed"
        } else {
            check(operation.checkpoint != null && acknowledgedCheckpoint === operation.checkpoint)
            store.requireCurrentCheckpoint(scope, operation.checkpoint)
        }
        operation.change.admit(NativeXperienceWrite.register(rawNativeHostPreferenceState,
            operation.owner.profileID, operation.change.field))
    }
    /** An actual coordinator checkpoint read rechecks original authority and encrypted-file
     * identity. A pre-persistence typed preview refusal may keep the unchanged parent usable;
     * accepted/started uncertainty, a changed file or revoked authority cannot pass this proof. */
    private fun typedCheckpointStillCurrent(expected: NativeOwnerHistoryCoordinator.Checkpoint?): Boolean =
        expected != null && ownerHistory?.requiresRecovery() == false &&
            runCatching { ownerHistory?.checkpoint() === expected }.getOrDefault(false)

    private val xperiencePreviewIssuer = Any()
    /** Opaque full-host provenance, NOT account authority. A caller-created instance lacks the
     * Session's private issuer. The genuine instance expires with its synchronous preview scope. */
    internal class XperienceHostPreview internal constructor(
        private val issuer: Any,
        internal val operation: XperienceOperation,
        host: ByteArray,
    ) : AutoCloseable {
        private val thread = Thread.currentThread()
        private var host: ByteArray? = host.copyOf()
        internal fun issuedBy(value: Any) = issuer === value
        internal fun <T> copyFor(action: (ByteArray) -> T): T {
            check(Thread.currentThread() === thread) { "Xperience preview crossed threads" }
            val copy = checkNotNull(host) { "Xperience preview expired" }.copyOf()
            return try { action(copy) } finally { copy.fill(0) }
        }
        fun <T> withRawHost(scope: VortxAccountScope, action: (ByteArray) -> T): T =
            operation.session.withXperiencePreview(this, scope, action)
        override fun close() { host?.fill(0); host = null }
    }
    @Synchronized private fun <T> withXperiencePreview(preview: XperienceHostPreview,
        expectedScope: VortxAccountScope, action: (ByteArray) -> T): T {
        check(preview.issuedBy(xperiencePreviewIssuer) && expectedScope == scope) { "Unattested Xperience host preview" }
        requireXperienceOperation(preview.operation)
        return preview.copyFor { host ->
            NativeHostPreferences.validate(scope, JSONObject(OHJson.utf8(host)))
            NativeXperienceWrite.maximumClock(host)
            val local = OHJson.Obj().set("document", host).encoded()
            preview.operation.change.requireReplacement(checkNotNull(NativeXperienceWrite.register(local,
                preview.operation.owner.profileID, preview.operation.change.field)))
            action(host)
        }
    }

    @Synchronized internal fun dispatchXperience(
        operation: XperienceOperation,
        prospectiveGlobalChanges: JSONObject,
        genericAdmission: (ByteArray, XperienceHostPreview, () -> Unit) -> Unit,
        typedAdmission: (ByteArray, ByteArray, () -> Unit) -> Unit,
        beforeCommit: () -> Unit,
    ): ByteArray {
        requireXperienceOperation(operation)
        val replacement = NativeXperienceWrite.replace(scope, operation.owner.profileID,
            rawNativeHostPreferenceState, operation.change)
        dispatchInternal(emptyList(), operation.owner, null, true, null, null, null, null, null, null,
            beforeCommit, null, emptyMap(), false, true, null, operation.checkpoint,
            prospectiveGlobalChanges, operation, replacement, typedAdmission, genericAdmission)
        val accepted = NativeXperienceWrite.register(rawNativeHostPreferenceState, operation.owner.profileID,
            operation.change.field)
        if (accepted == null || !accepted.contentEquals(replacement.register())) {
            enterCheckpointUncertainty()
            error("Xperience raw register readback failed")
        }
        return accepted
    }

    private val rawHostExportIssuer = Any()
    /** Fresh post-GET checkpoint provenance. It is unrelated to any old in-memory edit object.
     * The coordinator supplies the retained authenticated source under its original admission;
     * arbitrary raw host data cannot construct the Session's private issuer. */
    internal class RawHostExport internal constructor(
        private val issuer: Any,
        internal val session: VortxNativeSession,
        internal val owner: VortxNativeOwner,
        internal val runtime: VortxNativeRuntime,
        internal val checkpoint: NativeCheckpointRead,
        internal val context: String,
        internal val sourceCurrent: () -> Boolean,
        local: ByteArray, source: ByteArray, projection: ByteArray, native: ByteArray,
    ) : AutoCloseable {
        private val thread = Thread.currentThread()
        private var active = true; private var consumed = false
        private val local = local.copyOf(); private val source = source.copyOf()
        private val projection = projection.copyOf(); private val native = native.copyOf()
        internal fun issuedBy(value: Any) = issuer === value
        internal fun matchesLocal(value: ByteArray) = local.contentEquals(value)
        fun composeHost(scope: VortxAccountScope, source: ByteArray, projection: ByteArray,
            action: (ByteArray, ByteArray) -> ByteArray): ByteArray = session.withRawHostExportCurrent(this, scope) {
            check(active && !consumed && Thread.currentThread() === thread) { "Raw host export expired, repeated or changed thread" }
            check(this.source.contentEquals(source) && this.projection.contentEquals(projection)) { "Original raw host export source changed" }
            consumed = true
            val host = NativeRawHostPreferences.document(local); val native = native.copyOf()
            try {
                val result = action(native, host)
                try { session.requireRawHostExport(this); result }
                catch (failure: Throwable) { result.fill(0); throw failure }
            } finally { host.fill(0); native.fill(0) }
        }
        internal fun requireActive() { check(active && Thread.currentThread() === thread) { "Raw host export expired or changed thread" } }
        override fun close() { active = false; local.fill(0); source.fill(0); projection.fill(0); native.fill(0) }
    }
    @Synchronized internal fun <T> withRawHostExport(owner: VortxNativeOwner, source: ByteArray,
        projection: ByteArray, sourceCurrent: () -> Boolean, action: (RawHostExport) -> T): T =
        withCompleteAccountExportOwner(owner, true) { read ->
            check(!runtime.isTyped && sourceCurrent()) { "Generic raw host export unavailable" }
            NativeXperienceWrite.requireClocks(rawNativeHostPreferenceState)
            val checkpoint = checkNotNull(captureGenericPlaylistCheckpoint(owner))
            val native = read.state.getJSONObject("nativeSync").toString().toByteArray(Charsets.UTF_8)
            val snapshot = RawHostExport(rawHostExportIssuer, this, owner, runtime, checkpoint,
                xperienceContext(read), sourceCurrent, rawNativeHostPreferenceState, source, projection, native)
            native.fill(0)
            try { action(snapshot) } finally { snapshot.close() }
        }
    private fun requireRawHostExport(snapshot: RawHostExport) {
        snapshot.requireActive()
        check(snapshot.issuedBy(rawHostExportIssuer) && snapshot.session === this && snapshot.runtime === runtime &&
            accepts(snapshot.owner) && snapshot.matchesLocal(rawNativeHostPreferenceState) &&
            acknowledgedCheckpoint === snapshot.checkpoint && xperienceContext(read()) == snapshot.context &&
            snapshot.sourceCurrent()) { "Original raw host export changed" }
        store.requireCurrentCheckpoint(scope, snapshot.checkpoint)
    }
    @Synchronized private fun <T> withRawHostExportCurrent(snapshot: RawHostExport,
        expectedScope: VortxAccountScope, action: () -> T): T {
        check(scope == expectedScope) { "Raw host export scope changed" }
        requireRawHostExport(snapshot)
        return action()
    }

    /** The PUT candidate may outlive a newer local checkpoint. Only its exact sent raw carrier
     * can clear pending; newer events remain pending. This acknowledgement uses today's original
     * file CAS while the caller holds the ORIGINAL upload account/mount/accepted receipt fence. */
    @Synchronized internal fun acknowledgeRawHostDocument(sent: ByteArray, isCurrent: () -> Boolean): Boolean {
        check(isCurrent() && !requiresRecovery()) { "Raw host acknowledgement retired" }
        val current = NativeRawHostPreferences.document(rawNativeHostPreferenceState)
        val matches = try { OHJson.equal(current, sent) } finally { current.fill(0) }
        if (!matches) return true
        val owner = read().owner
        val checkpoint = try { checkNotNull(captureGenericPlaylistCheckpoint(owner)) }
        catch (failure: Throwable) { enterCheckpointUncertainty(); throw failure }
        dispatchInternal(emptyList(), owner, null, false, null, null, null, JSONObject(OHJson.utf8(sent)),
            null, null, { check(isCurrent()) { "Raw host acknowledgement retired" } }, null, emptyMap(), false, false,
            checkpointCASOnly = checkpoint)
        return isCurrent()
    }

    /** Scalar-only exact captured-owner gate. Revision is advanced for profile/route invalidation. */
    @Synchronized internal fun <T> withCompleteAccountExportOwnerScalar(owner: VortxNativeOwner, action: () -> T): T {
        requireCompleteAccountExportRoute()
        check(owner.scope == scope && owner.revision == revision) { "Native owner changed" }
        return action()
    }

    /**
     * Captures one full presentation only after the scalar route/account checks pass. A generic JNI
     * runtime additionally requires the coordinator's retained raw-read producer and store CAS.
     * The owner overload additionally rejects a
     * stale Session revision/scope before that one remaining presentation read; it does not claim
     * that current-owner publication is O(1).
     */
    @Synchronized internal fun <T> withCompleteAccountExportRead(genericReadAvailable: Boolean = false, action: (VortxNativeRead) -> T): T {
        requireCompleteAccountExportRoute(genericReadAvailable)
        return action(read())
    }
    @Synchronized internal fun <T> withCompleteAccountExportOwner(
        owner: VortxNativeOwner,
        genericReadAvailable: Boolean = false,
        action: (VortxNativeRead) -> T,
    ): T {
        requireCompleteAccountExportRoute(genericReadAvailable)
        check(owner.scope == scope && owner.revision == revision) { "Native owner changed" }
        val read = read()
        check(read.owner == owner) { "Native owner changed" }
        return action(read)
    }

    /** One current owner/state capture, kept under Session through the caller's admission.
     * Unlike read followed by owned, no monitor-release window needs a second full snapshot. */
    @Synchronized internal fun <T> withCurrentRead(action: (VortxNativeRead) -> T): T {
        check(!closed && !requiresRecovery()) { "Native owner changed" }
        return action(read()) // Validates account, active profile and current revision while Session is held.
    }

    /** The original raw account and authority are supplied by the authenticated gateway. */
    @Synchronized fun receiveOwnerHistory(account: NativeOwnerHistoryAccount, authority: NativeOwnerHistoryAuthority,
                                          historyBindings: NativeOwnerHistoryBindings, remoteHost: JSONObject?): Unit {
        val originalPlaybackRead = read()
        owned(originalPlaybackRead.owner) {
        val oldRuntime = runtime
        val originalPlaybackState = originalPlaybackRead.state
        var changesPlaybackOwner = false
        var changesReceiptProfile = false
        var next = ownerHistory
        var newOwner = false
        if (next == null) {
            val original = checkNotNull(acknowledgedCheckpoint) { "Original acknowledged checkpoint authority unavailable" }
            store.requireCurrentCheckpoint(scope, original)
            val retained = checkNotNull(original.plaintext) { "Native checkpoint unavailable" }
            require(!NativeOwnerHistorySessionAdapter.isEnvelope(retained)) { "Native checkpoint route changed" }
            val local = scope.validateSnapshot(retained)
            val shown = read().state
            check(OHState.ROOT.all { key ->
                if (key != "nativeSync") NativeHostPreferences.equal(local.opt(key), shown.opt(key))
                else OHState.NATIVE.all { field -> NativeHostPreferences.equal(local.getJSONObject(key).opt(field), shown.getJSONObject(key).opt(field)) }
            }) { "Native checkpoint changed during transfer" }
            val carrier = requireNotNull(account.raw(NativeOwnerHistoryAccount.ARCHIVE))
            val ownerUID = NativeOwnerHistorySources.readOwnerUID(scope, carrier)
            val checkpoint = NativeOwnerHistoryCoordinator.Checkpoint(scope, retained.toByteArray(Charsets.UTF_8),
                rawNativeHostPreferenceState, NativeOwnerHistorySources.empty(scope).local(),
                account.encoded(), ownerUID)
            next = try { NativeOwnerHistorySessionAdapter.open(scope, checkpoint, original, historyBindings, store,
                requireNotNull(ownerHistoryAuthority) { "Original mounted account authority unavailable" }, authority) }
            catch (failure: NativeOwnerHistoryCoordinator.Uncertain) {
                com.vortx.android.player.PlaybackOwnerEpoch.invalidate()
                enterCheckpointUncertainty(); unconfirmedHistoryRetirement = true
                slots.values.forEach { it.close() }; slots.clear()
                throw failure
            }
            newOwner = true
        }
        val adapter = requireNotNull(next)
        try {
            val host = NativeHostPreferences.merge(scope, NativeHostPreferences.local(scope, nativeHostPreferenceState), remoteHost)
            val rawHost = NativeRawHostPreferences.reconcile(scope, rawNativeHostPreferenceState, host,
                remoteHost, account.raw("nativeHostPreferences"))
            var projected: JSONObject? = null
            adapter.receive(account, authority, rawHost, local = { bytes ->
                val state = JSONObject(OHJson.utf8(bytes))
                changesReceiptProfile = state.getString("activeProfileId") != originalPlaybackState.getString("activeProfileId")
                val profiles = NativeHostPreferences.projectProfiles(host, hostProfilePreferences,
                    state.getJSONObject("roster").getJSONObject("profiles"))
                NativeHostPreferences.validateProjectedProfiles(profiles)
                changesPlaybackOwner = nativePlaybackOwnerChanged(originalPlaybackState, state)
                projected = profiles
                val projection = state.put("hostProfilePreferences", profiles).put("hostProfileSyncPending", hostProfileSyncPending)
                    .put("nativeHostPreferenceState", host)
                    .put("websiteProfileEditPending", websiteProfileEditPending).put("websiteProfileEditCertificates", websiteProfileEditCertificates)
                    .put("websiteAddonEditPending", websiteAddonEditPending).toString()
                NativeRawHostPreferences.snapshot(projection, rawHost).toByteArray(Charsets.UTF_8)
            }, beforePersist = {
                // This Session monitor excludes new authenticated owner captures until receive
                // and its visible projection complete. Revoke BEFORE native/checkpoint acceptance.
                if (changesPlaybackOwner) com.vortx.android.player.PlaybackOwnerEpoch.invalidate()
                // The generic engine is retired before typed persistence/native acceptance. No
                // second live writer can later overwrite the transferred checkpoint.
                if (newOwner) {
                    retireXperienceObservations()
                    try { oldRuntime.close() }
                    catch (failure: Throwable) { enterCheckpointUncertainty(); throw failure }
                }
            })
            if (newOwner) { runtime = adapter.view(); ownerHistory = adapter }
            if (changesReceiptProfile) { playlistReceiptProfileEpoch += 1; retireXperienceObservations() }
            hostProfilePreferences = requireNotNull(projected)
            nativeHostPreferenceState = host
            replaceRawHostPreferenceState(rawHost.copyOf())
            invalidate(); changes.value += 1
        } catch (failure: Throwable) {
            if (newOwner || adapter.requiresRecovery()) {
                com.vortx.android.player.PlaybackOwnerEpoch.invalidate()
                enterCheckpointUncertainty()
            }
            if (newOwner) {
                // Retain the reservation even if native retirement is uncertain.
                ownerHistory = adapter
                runCatching { adapter.close() }
            }
            slots.values.forEach { it.close() }; slots.clear()
            throw failure
        }
        }
    }
    @Synchronized fun resolve(request: JSONObject, owner: VortxNativeOwner = read().owner): JSONObject = owned(owner) {
        JSONObject(runtime.resolve(request.toString())).also { check(it.getString("kind") != "error") { "Native query rejected" } }
    }
    /** Destructive follow-through requires the exact current authenticated checkpoint, not an
     * action ACK or an in-memory publication. Adjacent host carriers never enter the kernel. */
    @Synchronized fun resolveCommitted(request: JSONObject, owner: VortxNativeOwner): JSONObject = owned(owner) {
        if (runtime.isTyped) {
            // The typed view rechecks the original authenticated envelope and native fence.
            return@owned runtime.resolve(request.toString()).let(::JSONObject).also {
                check(it.getString("kind") != "error" && accepts(owner)) { "Native committed query rejected" }
            }
        }
        val committed = scope.validateSnapshot(requireNotNull(store.read(scope)) { "Native checkpoint unavailable" })
        check(NativeHostPreferences.equal(committed, read().state)) { "Native checkpoint no longer matches the mounted state" }
        val core = JSONObject(committed.toString()).also { value ->
            listOf("hostProfilePreferences", "legacyImportMaterial", "hostProfileSyncPending", "nativeHostPreferenceState",
                "hostDocument", "excludedCredentialPaths", "legacyWebsiteBootstrap",
                "websiteProfileEditPending", "websiteProfileEditCertificates", "websiteAddonEditPending").forEach(value::remove)
        }
        VortxNativeRuntime.hydrate(bindings, core.toString()).use { restored ->
            JSONObject(restored.resolve(request.toString())).also {
                check(it.getString("kind") != "error" && accepts(owner)) { "Native committed query rejected" }
            }
        }
    }
    /**
     * One website event is a full native/host/source/receipt transaction.  A failed host CAS
     * never installs the candidate runtime or its receipt; only the credential-free raw event is
     * retained for explicit resolution and subsequent independent events may continue.
     */
    @Synchronized fun applyWebsiteProfileEdit(event: JSONObject, owner: VortxNativeOwner = read().owner): Boolean =
        applyWebsiteProfileEdit(event, event, owner)
    @Synchronized private fun applyWebsiteProfileEdit(event: JSONObject, retainedSource: JSONObject, owner: VortxNativeOwner): Boolean = owned(owner) {
        scope.rejectCredentials(event)
        val originalRuntime = runtime
        val originalRevision = revision
        val before = originalRuntime.stateJson()
        val candidate = originalRuntime.fork()
        var installed = false
        try {
            val applied = try {
                val action = JSONObject().put("type", "apply_legacy_profile_edits").put("scope", scope.accountID)
                    .put("ownerProfileId", scope.ownerProfileID).put("event", JSONObject(event.toString()).also { it.remove("legacyBootstrapFingerprint") })
                if (event.has("legacyBootstrapFingerprint")) action.put("legacyBootstrapFingerprint", event.get("legacyBootstrapFingerprint"))
                val response = JSONObject(candidate.dispatch(action.toString()))
                val receiptFingerprint = response.optJSONArray("events")?.optJSONObject(0)?.optJSONObject("receipt")?.optJSONObject("source")?.optString("fingerprint")
                val priorReceipt = receiptFingerprint?.let { fingerprint -> JSONObject(before).getJSONObject("nativeSync")
                    .optJSONObject("legacyProfileEditReceipts")?.optJSONObject(fingerprint) }
                NativeWebsiteProfileEdits.admit(scope, event, response, nativeHostPreferenceState,
                    hostProfilePreferences, websiteProfileEditCertificates, priorReceipt)
            } catch (error: NativeWebsiteProfileEdits.Conflict) {
                retainWebsiteProfileEdit(retainedSource, owner); return@owned false
            } catch (error: IllegalArgumentException) {
                // Schema/kernel rejections are sealed for user-visible conflict resolution; the
                // credential guard above is deliberately outside this conversion.
                retainWebsiteProfileEdit(retainedSource, owner); return@owned false
            }
            val fingerprint = applied.receipt.getJSONObject("source").getString("fingerprint")
            val receipts = JSONObject(candidate.stateJson()).getJSONObject("nativeSync").getJSONObject("legacyProfileEditReceipts")
            require(receipts.has(fingerprint) && NativeHostPreferences.equal(receipts.getJSONObject(fingerprint), applied.receipt)) {
                "Native website receipt was not committed"
            }
            val preferences = NativeHostPreferences.projectProfiles(applied.host, hostProfilePreferences,
                JSONObject(candidate.stateJson()).getJSONObject("roster").getJSONObject("profiles"))
            NativeHostPreferences.validateProjectedProfiles(preferences)
            val pending = NativeWebsiteProfileEdits.remove(websiteProfileEditPending, event.getString("eventId"))
            val updated = checkpoint(candidate.stateJson(), preferences, hostProfileSyncPending, applied.host,
                legacyImportMaterial, hostDocumentArchive, legacyWebsiteBootstrap, pending, applied.certificates)
            val state = validatePresentation(updated)
            val prior = JSONObject(before)
            val playbackState = PlaybackCheckpointState(originalRuntime, originalRevision, candidate, updated, prior, state)
            commitCheckpoint(updated, candidate, playbackState = playbackState)
            check(isAccountCurrent()) { "Native account changed" }
            val profileChanged = prior.getJSONObject("roster").toString() != state.getJSONObject("roster").toString()
            val playlistProfileChanged = profileChanged ||
                preferences.toString() != hostProfilePreferences.toString() ||
                state.getString("activeProfileId") != owner.profileID
            if (state.getString("activeProfileId") != owner.profileID) {
                playlistReceiptProfileEpoch += 1; retireXperienceObservations()
            }
            val previous = runtime; runtime = candidate; installed = true; previous.close()
            hostProfilePreferences = JSONObject(preferences.toString())
            nativeHostPreferenceState = applied.host
            websiteProfileEditPending = pending
            websiteProfileEditCertificates = applied.certificates
            if (playlistProfileChanged) {
                if (profileChanged || state.getString("activeProfileId") != owner.profileID) invalidate()
                else signalPlaylistInvalidation()
            }
            changes.value += 1
            true
        } finally { if (!installed) candidate.close() }
    }
    @Synchronized private fun retainWebsiteProfileEdit(event: JSONObject, owner: VortxNativeOwner) = owned(owner) {
        val pending = NativeWebsiteProfileEdits.retain(scope, websiteProfileEditPending, event)
        val updated = checkpoint(runtime.stateJson(), hostProfilePreferences, hostProfileSyncPending, nativeHostPreferenceState,
            legacyImportMaterial, hostDocumentArchive, legacyWebsiteBootstrap, pending, websiteProfileEditCertificates)
        validatePresentation(updated); commitCheckpoint(updated)
        check(isAccountCurrent()) { "Native account changed" }
        websiteProfileEditPending = pending; changes.value += 1
    }
    /** The raw event, kernel membership update, receipt and pending removal form one checkpoint.
     * Always dispatch replays: only the kernel can verify the JCS hash and prevent resurrection. */
    @Synchronized fun applyWebsiteAddonEdit(event: JSONObject, owner: VortxNativeOwner = read().owner,
                                           beforeCommit: () -> Unit = {}): Boolean = applyWebsiteAddonEdits(listOf(event), owner, beforeCommit)
    @Synchronized fun applyWebsiteAddonEdits(events: List<JSONObject>, owner: VortxNativeOwner = read().owner,
                                            beforeCommit: () -> Unit = {}): Boolean = owned(owner) {
        val union = NativeWebsiteAddonEdits.union(scope, websiteAddonEditPending, events)
        val conflicts = union.groupBy { it.getString("eventId") }.filterValues { it.size > 1 }.keys
        if (conflicts.isNotEmpty()) {
            var pending = websiteAddonEditPending
            union.filter { it.getString("eventId") in conflicts }.forEach { pending = NativeWebsiteAddonEdits.retain(scope, pending, it) }
            val updated = checkpoint(runtime.stateJson(), hostProfilePreferences, hostProfileSyncPending, nativeHostPreferenceState,
                legacyImportMaterial, hostDocumentArchive, legacyWebsiteBootstrap, websiteProfileEditPending, websiteProfileEditCertificates, pending)
            validatePresentation(updated); beforeCommit(); commitCheckpoint(updated)
            check(isAccountCurrent()) { "Native account changed" }
            websiteAddonEditPending = pending; changes.value += 1
        }
        var accepted = conflicts.isEmpty()
        for (event in union) if (event.getString("eventId") !in conflicts) {
            // Earlier independent events may retire the resource owner after their durable commit.
            if (!applyWebsiteAddonEditOnce(event, read().owner, beforeCommit)) accepted = false
        }
        accepted
    }
    @Synchronized private fun applyWebsiteAddonEditOnce(event: JSONObject, owner: VortxNativeOwner,
                                                       beforeCommit: () -> Unit): Boolean = owned(owner) {
        NativeWebsiteAddonEdits.validate(scope, event)
        val originalRuntime = runtime
        val originalRevision = revision
        val before = originalRuntime.stateJson()
        val candidate = originalRuntime.fork()
        var installed = false
        try {
            val receipt = try {
                NativeWebsiteAddonEdits.receipt(scope, event,
                    JSONObject(candidate.dispatch(NativeWebsiteAddonEdits.action(scope, event).toString())))
            } catch (error: IllegalArgumentException) {
                val pending = NativeWebsiteAddonEdits.retain(scope, websiteAddonEditPending, event)
                val updated = checkpoint(before, hostProfilePreferences, hostProfileSyncPending, nativeHostPreferenceState,
                    legacyImportMaterial, hostDocumentArchive, legacyWebsiteBootstrap, websiteProfileEditPending,
                    websiteProfileEditCertificates, pending)
                validatePresentation(updated); beforeCommit(); commitCheckpoint(updated)
                check(isAccountCurrent()) { "Native account changed" }
                websiteAddonEditPending = pending; changes.value += 1
                return@owned false
            }
            val receipts = JSONObject(candidate.stateJson()).getJSONObject("nativeSync").getJSONObject("websiteAddonReceipts")
            require(NativeHostPreferences.equal(receipts.optJSONObject(event.getString("eventId")), receipt)) {
                "Native website add-on receipt was not persisted"
            }
            val pending = NativeWebsiteAddonEdits.remove(websiteAddonEditPending, event)
            val updated = checkpoint(candidate.stateJson(), hostProfilePreferences, hostProfileSyncPending, nativeHostPreferenceState,
                legacyImportMaterial, hostDocumentArchive, legacyWebsiteBootstrap, websiteProfileEditPending,
                websiteProfileEditCertificates, pending)
            val state = validatePresentation(updated)
            val prior = JSONObject(before)
            val playbackState = PlaybackCheckpointState(originalRuntime, originalRevision, candidate, updated, prior, state)
            beforeCommit(); commitCheckpoint(updated, candidate, playbackState = playbackState)
            check(isAccountCurrent()) { "Native account changed" }
            val registryChanged = !NativeHostPreferences.equal(prior.getJSONObject("nativeSync").getJSONObject("addons"),
                state.getJSONObject("nativeSync").getJSONObject("addons"))
            val previous = runtime; runtime = candidate; installed = true; previous.close()
            websiteAddonEditPending = pending
            if (registryChanged) invalidate()
            changes.value += 1
            true
        } finally { if (!installed) candidate.close() }
    }
    /**
     * The aggregate has no causal watermark. It is admitted only as the kernel's one-time
     * original-baseline migration, never re-clocked from the receiving device or document.
     */
    @Synchronized fun applyLegacyWebsiteAggregate(raw: Any?, owner: VortxNativeOwner = read().owner): Boolean = owned(owner) {
        val retained = NativeWebsiteProfileEdits.legacyPending(raw)
        val aggregate = raw as? JSONObject ?: run { retainWebsiteProfileEdit(retained, owner); return@owned false }
        val bootstrap = legacyWebsiteBootstrap
        if (bootstrap == null || !NativeHostPreferences.equal(bootstrap.get("aggregate"), aggregate)) { retainWebsiteProfileEdit(retained, owner); return@owned false }
        val import = JSONObject(runtime.stateJson()).getJSONObject("nativeSync").optJSONObject("legacyImport")
        val fingerprint = import?.optString("fingerprint")?.takeIf { it.matches(Regex("[0-9a-f]{64}")) && it == bootstrap.optString("legacyImportFingerprint") }
            ?: run { retainWebsiteProfileEdit(retained, owner); return@owned false }
        applyWebsiteProfileEdit(NativeWebsiteProfileEdits.legacyMigrationEvent(aggregate, fingerprint), retained, owner)
    }
    @Synchronized fun <T> owned(owner: VortxNativeOwner, action: () -> T): T {
        check(accepts(owner)) { "Native owner changed" }; return action()
    }
    @Synchronized fun dispatch(actions: List<JSONObject>, owner: VortxNativeOwner = read().owner,
                              hostProfiles: JSONObject? = null, notifyMutation: Boolean = true,
                              hostArchive: JSONObject? = null, remoteHostPreferences: JSONObject? = null,
                              globalChanges: JSONObject? = null, acknowledgeHostPreferences: JSONObject? = null,
                              baselineHostProfiles: JSONObject? = null,
                              verifyCandidate: ((VortxNativeRuntime) -> Unit)? = null,
                              beforeCommit: () -> Unit = {}, profileFieldChanges: JSONObject? = null,
                              legacyWatchlists: Map<String, List<com.vortx.android.library.WatchlistEntry>> = emptyMap(),
                              progressOnly: Boolean = false): List<String> = dispatchInternal(
        actions, owner, hostProfiles, notifyMutation, hostArchive, remoteHostPreferences, globalChanges,
        acknowledgeHostPreferences, baselineHostProfiles, verifyCandidate, beforeCommit,
        profileFieldChanges, legacyWatchlists, progressOnly, requireCompleteAccountExportBudget = false)

    /**
     * Dedicated playlist route. Its JVM/API surface cannot opt out of the complete-account gate,
     * while the longstanding [dispatch] signature and generated default-call ABI remain unchanged.
     */
    @Synchronized internal fun dispatchBudgetedPlaylist(
        owner: VortxNativeOwner,
        profileFieldChanges: JSONObject,
        beforeCommit: () -> Unit,
        prospectiveGlobalChanges: JSONObject? = null,
        genericAdmission: ((ByteArray, ByteArray, () -> Unit) -> Unit)? = null,
        genericCheckpoint: NativeCheckpointRead? = null,
    ): List<String> {
        check(profileFieldChanges.length() == 1 &&
            profileFieldChanges.keys().asSequence().all { it.startsWith(NativePlaylist.PREFIX) }) {
            "Budgeted playlist dispatch accepts one playlist profile field"
        }
        return dispatchInternal(emptyList(), owner, null, true, null, null, null, null, null, null,
            beforeCommit, profileFieldChanges, emptyMap(), false,
            requireCompleteAccountExportBudget = true, genericAdmission = genericAdmission,
            genericCheckpoint = genericCheckpoint, prospectiveGlobalChanges = prospectiveGlobalChanges)
    }

    private fun dispatchInternal(
        actions: List<JSONObject>,
        owner: VortxNativeOwner,
        hostProfiles: JSONObject?,
        notifyMutation: Boolean,
        hostArchive: JSONObject?,
        remoteHostPreferences: JSONObject?,
        globalChanges: JSONObject?,
        acknowledgeHostPreferences: JSONObject?,
        baselineHostProfiles: JSONObject?,
        verifyCandidate: ((VortxNativeRuntime) -> Unit)?,
        beforeCommit: () -> Unit,
        profileFieldChanges: JSONObject?,
        legacyWatchlists: Map<String, List<com.vortx.android.library.WatchlistEntry>>,
        progressOnly: Boolean,
        requireCompleteAccountExportBudget: Boolean,
        genericAdmission: ((ByteArray, ByteArray, () -> Unit) -> Unit)? = null,
        genericCheckpoint: NativeCheckpointRead? = null,
        prospectiveGlobalChanges: JSONObject? = null,
        xperienceOperation: XperienceOperation? = null,
        xperienceReplacement: NativeXperienceWrite.Replacement? = null,
        typedAdmission: ((ByteArray, ByteArray, () -> Unit) -> Unit)? = null,
        xperienceAdmission: ((ByteArray, XperienceHostPreview, () -> Unit) -> Unit)? = null,
        checkpointCASOnly: NativeCheckpointRead? = null,
    ): List<String> = owned(owner) {
        // This check precedes fork, host Lamport minting and every durable side effect. The later
        // commit flag prevents a future refactor from falling back to the generic local store.
        check(!requireCompleteAccountExportBudget || runtime.isTyped ||
            ((genericAdmission != null || xperienceAdmission != null) && store.supportsCheckpointAuthority)) {
            "Complete account export budget unavailable"
        }
        actions.forEach(scope::rejectCredentials)
        scope.rejectCredentials(hostProfiles)
        scope.rejectCredentials(hostArchive)
        val originalRuntime = runtime
        val originalRevision = revision
        val originalCheckpoint = if (!runtime.isTyped && (requireCompleteAccountExportBudget || checkpointCASOnly != null))
            checkNotNull(genericCheckpoint ?: checkpointCASOnly).also {
                check(acknowledgedCheckpoint === it) { "Original playlist checkpoint changed" }
                store.requireCurrentCheckpoint(scope, it)
            } else null
        val before = originalRuntime.stateJson()
        if (xperienceOperation != null) {
            requireXperienceOperation(xperienceOperation)
            check(requireCompleteAccountExportBudget && xperienceReplacement != null && typedAdmission != null &&
                xperienceAdmission != null && profileFieldChanges == null && actions.isEmpty())
        }
        val candidate = originalRuntime.fork()
        var installed = false
        var xperienceCheckpointStarted = false
        try {
            var heldAction: JSONObject? = null
            var heldReason: String? = null
            val results = actions.map { action ->
                candidate.dispatch(action.toString()).also { result ->
                    if (JSONObject(result).optBoolean("ok")) return@also
                    check(NativeLegacyReconciliationPolicy.holdable(action) && heldAction == null) { "Native action rejected" }
                    heldAction = action; heldReason = NativeLegacyReconciliationPolicy.rejectionCode(result)
                }
            }
            // Verify the requested public projection before installing any part of a batch. A
            // successful action acknowledgement alone is not a watched/replacement receipt.
            verifyCandidate?.invoke(candidate)
            var preferences = hostProfiles ?: hostProfilePreferences
            var pendingPreferences = hostProfileSyncPending
            var hostState = NativeHostPreferences.local(scope, nativeHostPreferenceState)
            if (notifyMutation && hostProfiles != null) hostState = NativeHostPreferences.recordProfiles(scope, hostState, hostProfilePreferences, hostProfiles)
            if (!notifyMutation && pendingPreferences && baselineHostProfiles != null) {
                hostState = NativeHostPreferences.recordProfiles(scope, hostState, baselineHostProfiles, hostProfilePreferences)
                pendingPreferences = false
            }
            hostState = NativeHostPreferences.merge(scope, hostState, remoteHostPreferences)
            val liveRoster = JSONObject(candidate.stateJson()).getJSONObject("roster").getJSONObject("profiles")
            hostState = NativeHostPreferences.seedWatchlists(scope, hostState, legacyWatchlists.filterKeys {
                liveRoster.optJSONObject(it)?.optBoolean("deleted") == false
            })
            if (profileFieldChanges != null) hostState = NativeHostPreferences.recordProfileFields(scope, hostState, owner.profileID, profileFieldChanges)
            if (globalChanges != null) hostState = NativeHostPreferences.recordGlobals(scope, hostState, globalChanges)
            if (acknowledgeHostPreferences != null && NativeHostPreferences.equal(hostState.getJSONObject("document"), acknowledgeHostPreferences))
                hostState.put("pending", false)
            val rawHostState = if (xperienceReplacement != null) xperienceReplacement.local().also {
                hostState = NativeHostPreferences.local(scope, JSONObject(OHJson.utf8(it)))
            } else NativeRawHostPreferences.reconcile(scope, rawNativeHostPreferenceState, hostState,
                remoteHostPreferences, if (remoteHostPreferences != null) rawHostMerge else null)
            if (xperienceOperation == null) preferences = NativeHostPreferences.projectProfiles(hostState, preferences,
                JSONObject(candidate.stateJson()).getJSONObject("roster").getJSONObject("profiles"))
            NativeHostPreferences.validateProjectedProfiles(preferences)
            val retained = legacyImportMaterial ?: actions.firstOrNull { it !== heldAction && it.getString("type") in setOf("import_legacy_sync", "reconcile_legacy_sync") }?.getJSONObject("material")
            val archive = hostArchive ?: hostDocumentArchive
            val updatedProjection = JSONObject(candidate.stateJson()).put("hostProfilePreferences", preferences).put("hostProfileSyncPending", pendingPreferences).put("legacyImportMaterial", retained)
                .put("nativeHostPreferenceState", hostState)
                .put("hostDocument", archive?.getJSONObject("document")).put("excludedCredentialPaths", archive?.getJSONArray("excludedCredentialPaths"))
                .put("legacyWebsiteBootstrap", legacyWebsiteBootstrap)
                .put("websiteProfileEditPending", websiteProfileEditPending).put("websiteProfileEditCertificates", websiteProfileEditCertificates)
                .put("websiteAddonEditPending", websiteAddonEditPending).toString()
            val updated = NativeRawHostPreferences.snapshot(updatedProjection, rawHostState)
            val state = validatePresentation(updated)
            val prior = JSONObject(before)
            val playbackState = PlaybackCheckpointState(originalRuntime, originalRevision, candidate, updated, prior, state)
            val needsPreview = (originalCheckpoint != null && requireCompleteAccountExportBudget) || xperienceOperation != null
            val prospectiveRawHost = if (needsPreview) NativeRawHostPreferences.reconcile(scope, rawHostState,
                prospectiveGlobalChanges?.let { NativeHostPreferences.recordGlobals(scope, hostState, it) } ?: hostState) else null
            val prospectiveHost = prospectiveRawHost?.let(NativeRawHostPreferences::document)
            val xperiencePreview = if (xperienceOperation != null)
                XperienceHostPreview(xperiencePreviewIssuer, xperienceOperation, checkNotNull(prospectiveHost)) else null
            val replace = {
                beforeCommit()
                xperienceOperation?.let(::requireXperienceOperation)
                check(runtime === originalRuntime && revision == originalRevision &&
                    (originalCheckpoint == null || acknowledgedCheckpoint === originalCheckpoint)) {
                    "Original native checkpoint authority changed"
                }
                if (xperienceOperation != null && !candidate.isTyped) xperienceCheckpointStarted = true
                commitCheckpoint(updated, candidate, hostArchive, playbackState,
                    requireCompleteAccountExportBudget = requireCompleteAccountExportBudget,
                    genericOriginalCheckpoint = originalCheckpoint,
                    preparedOriginalCheckpoint = xperienceOperation?.typedCheckpoint,
                    preparedAccountAdmission = if (xperienceOperation != null && candidate.isTyped)
                        NativePreparedAccountAdmission { account, persist ->
                            NativeXperienceWrite.admitOnce({ once ->
                                checkNotNull(typedAdmission).invoke(account, checkNotNull(prospectiveHost), once)
                            }) {
                                beforeCommit()
                                requireXperienceOperation(xperienceOperation)
                                persist()
                            }
                        } else null)
            }
            try { if (originalCheckpoint != null && requireCompleteAccountExportBudget) {
                val native = state.getJSONObject("nativeSync").toString().toByteArray(Charsets.UTF_8)
                // Include every captured pending global value in the complete cloud candidate,
                // but persist only the requested playlist field. This budget preview neither
                // acknowledges dirty stamps nor chooses a new durable global conflict winner.
                try {
                    if (xperienceOperation != null) NativeXperienceWrite.admitOnce({ once ->
                        checkNotNull(xperienceAdmission).invoke(native, checkNotNull(xperiencePreview), once)
                    }, replace)
                    else checkNotNull(genericAdmission).invoke(native, checkNotNull(prospectiveHost), replace)
                } finally { native.fill(0) }
            } else replace() } finally { xperiencePreview?.close(); prospectiveHost?.fill(0); prospectiveRawHost?.fill(0) }
            check(isAccountCurrent()) { "Native account changed" }
            val rosterChanged = prior.getJSONObject("roster").toString() != state.getJSONObject("roster").toString()
            val profileOrRegistryChanged = rosterChanged ||
                prior.getJSONObject("nativeSync").getJSONObject("addons").toString() != state.getJSONObject("nativeSync").getJSONObject("addons").toString() ||
                !NativeHostPreferences.equal(bindingSelections(prior), bindingSelections(state))
            val hostChanged = preferences.toString() != hostProfilePreferences.toString()
            val activeProfileChanged = state.getString("activeProfileId") != owner.profileID
            if (activeProfileChanged) { playlistReceiptProfileEpoch += 1; retireXperienceObservations() }
            val playlistProfileChanged = rosterChanged || hostChanged || activeProfileChanged
            val playlistFieldChanged = profileFieldChanges?.keys()?.asSequence()
                ?.any { it.startsWith(NativePlaylist.PREFIX) } == true
            val previous = runtime; runtime = candidate; installed = true; previous.close()
            hostProfilePreferences = JSONObject(preferences.toString())
            hostProfileSyncPending = pendingPreferences
            nativeHostPreferenceState = hostState
            legacyImportMaterial = retained?.let { JSONObject(it.toString()) }
            if (actions.any(NativeLegacyReconciliationPolicy::holdable)) heldLegacyReconciliation = heldReason
            hostDocumentArchive = archive?.let { JSONObject(it.toString()) }
            // Any profile/registry mutation invalidates in-flight resources. Progress does not.
            val ownerInvalidated = hostChanged || profileOrRegistryChanged || activeProfileChanged || actions.any {
                    it.getString("type") in setOf("patch_profile", "delete_profile", "install_addon", "remove_addon", "reorder_addons")
                }
            if (ownerInvalidated) invalidate()
            // Full host merges are infrequent account-sync boundaries. Signal them without a
            // per-frame/per-resource full-family comparison; local playlist writes and profile
            // ownership changes signal only after the checkpoint and in-memory swap succeeded.
            if (!ownerInvalidated && (remoteHostPreferences != null || playlistFieldChanged || playlistProfileChanged))
                signalPlaylistInvalidation()
            changes.value += 1
            if (notifyMutation) { if (progressOnly) onProgressMutation() else onMutation() }
            results
        } catch (failure: Throwable) {
            // A producer failure after a durable callback cannot leave an old view writable.
            // Typed outcome comes from the actual coordinator/file/authority, never callback
            // invocation. Generic started writes retain their existing uncertainty semantics.
            if (xperienceOperation != null && !installed &&
                (if (xperienceOperation.typedCheckpoint != null) !typedCheckpointStillCurrent(xperienceOperation.typedCheckpoint)
                 else xperienceCheckpointStarted)) enterCheckpointUncertainty()
            throw failure
        } finally { if (!installed) candidate.close() }
    }
    /** Same-UID relinks still change credential authority. Dormant slot merges do not revoke
     * playback, but every actual selection transaction does, including remote A→B→A. */
    private fun bindingSelections(state: JSONObject): JSONObject = JSONObject().also { result ->
        state.optJSONObject("nativeSync")?.optJSONObject("accountSlots")?.let { slots ->
            slots.keys().forEach { result.put(it, slots.getJSONObject(it).getJSONObject("activeBinding")) }
        }
    }
    @Synchronized private fun invalidate() {
        beforeOwnerChange()
        revision = nextRevision.incrementAndGet()
        slots.values.forEach { it.close() }; slots.clear()
        signalPlaylistInvalidation()
    }
    /** Only this Session creates it from its actual original runtime and validated candidate.
     * JSON values are caller-owned locals, never exposed to callbacks or stored as a fresh owner oracle. */
    private class PlaybackCheckpointState(
        val originalRuntime: VortxNativeRuntime,
        val originalRevision: Long,
        val candidate: VortxNativeRuntime,
        val serialized: String,
        val original: JSONObject,
        val validated: JSONObject,
    )
    /** Rename may have succeeded before fsync/readback failed. Keep the previously published view
     * readable, but revoke ALL transaction/resource/reclaim admission until authenticated reopen.
     * In particular, old runtime A must never overwrite a possibly installed binding B. */
    private fun commitCheckpoint(snapshot: String, candidate: VortxNativeRuntime = runtime, hostArchive: JSONObject? = null,
                                 playbackState: PlaybackCheckpointState? = null,
                                 requireCompleteAccountExportBudget: Boolean = false,
                                 genericOriginalCheckpoint: NativeCheckpointRead? = null,
                                 preparedAccountAdmission: NativePreparedAccountAdmission? = null,
                                 preparedOriginalCheckpoint: NativeOwnerHistoryCoordinator.Checkpoint? = null) {
        check(!checkpointUncertain) { "Native checkpoint requires authenticated reopen" }
        check(!requireCompleteAccountExportBudget || candidate.isTyped || genericOriginalCheckpoint != null) {
            "Complete account export budget unavailable"
        }
        // Resource revisions, ordinary progress/settings, unrelated roster edits and dormant
        // slots are not playback ownership. The active exact binding transaction is.
        val changesPlaybackOwner = if (playbackState == null) {
            // Cold/private carrier-only callers have no previously decoded state pair.
            nativePlaybackOwnerChanged(JSONObject(runtime.stateJson()), JSONObject(snapshot))
        } else {
            check(playbackState.originalRuntime === runtime && playbackState.originalRevision == revision &&
                playbackState.candidate === candidate &&
                playbackState.serialized === snapshot) { "Original playback checkpoint candidate changed" }
            nativePlaybackOwnerChanged(playbackState.original, playbackState.validated)
        }
        if (changesPlaybackOwner) {
            com.vortx.android.player.PlaybackOwnerEpoch.invalidate()
        }
        try {
            val archiveChanges = if (hostArchive != null) ownerHistory?.hostArchiveChanges(hostArchive).orEmpty() else emptyMap()
            val committedCompleteAccount = if (preparedAccountAdmission == null)
                candidate.commitTypedCheckpoint(snapshot, archiveChanges)
            else candidate.commitTypedPreparedCheckpoint(snapshot, archiveChanges, preparedAccountAdmission)
            check(preparedAccountAdmission == null || committedCompleteAccount) {
                "Prepared-account admission requires the original typed candidate"
            }
            check(!requireCompleteAccountExportBudget || committedCompleteAccount || genericOriginalCheckpoint != null) {
                "Complete account export budget unavailable"
            }
            if (!committedCompleteAccount) {
                if (genericOriginalCheckpoint != null) {
                    check(acknowledgedCheckpoint === genericOriginalCheckpoint)
                    // The exact original encrypted-file capability is consumed by atomic CAS.
                    acknowledgedCheckpoint = store.compareAndCommitCheckpoint(scope, genericOriginalCheckpoint, snapshot)
                        .also { check(it.plaintext == snapshot) { "Native checkpoint readback failed" } }
                } else {
                    store.commit(scope, snapshot)
                    check(store.read(scope) == snapshot) { "Native checkpoint readback failed" }
                }
                if (genericOriginalCheckpoint == null && store.supportsCheckpointAuthority) {
                    acknowledgedCheckpoint = store.captureCheckpoint(scope).also { check(it.plaintext == snapshot) }
                }
            }
            val acceptedRawHost = OHJson.Obj(snapshot.toByteArray(Charsets.UTF_8)).raw("nativeHostPreferenceState")
            replaceRawHostPreferenceState(acceptedRawHost)
        } catch (error: Throwable) {
            if (preparedAccountAdmission != null && typedCheckpointStillCurrent(preparedOriginalCheckpoint)) throw error
            com.vortx.android.player.PlaybackOwnerEpoch.invalidate()
            enterCheckpointUncertainty()
            slots.values.forEach { it.close() }; slots.clear()
            changes.value += 1
            throw error
        }
    }
    private fun checkpoint(core: String, profiles: JSONObject, pendingProfiles: Boolean, host: JSONObject, material: JSONObject?, archive: JSONObject?, bootstrap: JSONObject?, websitePending: JSONObject, certificates: JSONObject,
                           addonPending: JSONObject = websiteAddonEditPending): String {
        val rawHost = NativeRawHostPreferences.reconcile(scope, rawNativeHostPreferenceState, host)
        val projection = JSONObject(core).put("hostProfilePreferences", profiles).put("hostProfileSyncPending", pendingProfiles)
            .put("nativeHostPreferenceState", host).put("legacyImportMaterial", material)
            .put("hostDocument", archive?.getJSONObject("document")).put("excludedCredentialPaths", archive?.getJSONArray("excludedCredentialPaths"))
            .put("legacyWebsiteBootstrap", bootstrap)
            .put("websiteProfileEditPending", websitePending).put("websiteProfileEditCertificates", certificates)
            .put("websiteAddonEditPending", addonPending).toString()
        return NativeRawHostPreferences.snapshot(projection, rawHost)
    }
    @Synchronized override fun close() {
        if (retirementComplete) return
        if (!closed) { closed = true; retireXperienceObservations(); invalidate() }
        check(!unconfirmedHistoryRetirement) { "Owner history retirement unconfirmed; writer remains reserved" }
        // Failed retirement keeps the exact owner reachable and all admission quarantined.
        // A second close retries it; it must not silently release the account's writer slot.
        runtime.close()
        ownerHistory?.close()
        (transport as? AutoCloseable)?.close()
        rawNativeHostPreferenceState.fill(0)
        retirementComplete = true
        changes.value += 1
    }
    @Synchronized private fun begin(name: String, owner: VortxNativeOwner): Slot = owned(owner) {
        slots.remove(name)?.close()
        Slot(UUID.randomUUID(), owner).also { slots[name] = it }
    }
    @Synchronized private fun current(name: String, slot: Slot): Boolean = accepts(slot.owner) && slots[name] === slot
    @Synchronized private fun bridge(name: String, slot: Slot): VortxResourceBridge {
        check(current(name, slot)) { "Native request superseded" }
        return VortxResourceBridge(transport).also { slot.bridges += it }
    }
    @Synchronized private fun retire(slot: Slot, bridge: VortxResourceBridge) {
        bridge.close()
        slot.bridges.remove(bridge)
    }
    @Synchronized private fun finish(name: String, slot: Slot, revoke: Boolean) {
        slot.close()
        if (revoke && slots[name] === slot) slots.remove(name)
    }

    /** Retire an exact consumer ticket, never a newer request that reused its slot name. */
    @Synchronized fun retireResourceSlot(name: String, ticket: UUID) {
        val slot = slots[name]?.takeIf { it.ticket == ticket } ?: return
        slots.remove(name)
        slot.close()
    }

    /** Parsing may occur off-lock; publication must still belong to the exact latest consumer load. */
    @Synchronized fun <T> publish(name: String, owner: VortxNativeOwner, pages: List<VortxResourceSnapshot>, action: () -> T): T =
        publish(name, owner, pages, null, action)
    @Synchronized fun <T> publish(name: String, owner: VortxNativeOwner, pages: List<VortxResourceSnapshot>,
                                 ticket: UUID?, action: () -> T): T = owned(owner) {
        val slot = slots[name]
        check(slot != null && (ticket == null || slot.ticket == ticket) &&
            slot.completed == pages.map { it.requestId to it.generation }) { "Native request superseded" }
        action()
    }

    /** An auxiliary result may race the next provider receipt. Defer only that receipt mismatch;
     * a replaced slot/owner is still an error and must retire the entire request, never be swallowed. */
    @Synchronized fun <T : Any> publishIfLatestReceipt(name: String, owner: VortxNativeOwner,
        pages: List<VortxResourceSnapshot>, ticket: UUID, action: () -> T): T? = owned(owner) {
        val slot = slots[name]
        check(slot != null && slot.ticket == ticket) { "Native request superseded" }
        if (slot.completed != pages.map { it.requestId to it.generation }) null else action()
    }

    /** A new request replaces only its own consumer slot. Close/profile/account changes fence all slots. */
    suspend fun load(name: String, owner: VortxNativeOwner,
                     requests: List<Pair<VortxResourceRequest, List<VortxResourceAddon>>>): List<VortxResourceSnapshot> {
        val slot = begin(name, owner)
        var completed = false
        try {
            val bridge = bridge(name, slot)
            val result = requests.map { (request, addons) ->
                check(current(name, slot)) { "Native request superseded" }
                bridge.load("${scope.digest}:${owner.profileID}:${owner.revision}", request, addons).also {
                    check(current(name, slot) && bridge.accepts(it)) { "Native request superseded" }
                }
            }
            check(current(name, slot)) { "Native request superseded" }
            synchronized(this) {
                check(current(name, slot)) { "Native request superseded" }
                slot.completed = result.map { it.requestId to it.generation }
            }
            completed = true
            return result
        } finally { finish(name, slot, revoke = !completed) }
    }

    /** One batch lease, independent bridges, and serialized receipts for incremental search. */
    suspend fun loadIncrementally(name: String, owner: VortxNativeOwner,
                                  requests: List<Pair<VortxResourceRequest, List<VortxResourceAddon>>>,
                                  onUpdate: suspend (List<VortxResourceSnapshot>, Boolean, UUID) -> Unit) {
        val slot = begin(name, owner)
        var completed = false
        try {
            collectNativeResourceBatch(requests.size, load = { index ->
                val bridge = bridge(name, slot)
                val (request, addons) = requests[index]
                try {
                    bridge.load("${scope.digest}:${owner.profileID}:${owner.revision}", request, addons).also {
                        check(current(name, slot) && bridge.accepts(it)) { "Native request superseded" }
                    }
                } finally { retire(slot, bridge) }
            }) { pages, pending ->
                synchronized(this) {
                    check(current(name, slot)) { "Native request superseded" }
                    slot.completed = pages.map { it.requestId to it.generation }
                }
                onUpdate(pages, pending, slot.ticket)
            }
            completed = true
        } finally { finish(name, slot, revoke = !completed) }
    }

    /** Source/metadata fanout has one publication lease, but one fresh native budget per provider. */
    suspend fun loadProviders(name: String, owner: VortxNativeOwner, legs: List<NativeProviderLeg>,
                              onUpdate: suspend (NativeProviderUpdate, UUID) -> Unit) {
        val slot = begin(name, owner)
        var completed = false
        try {
            collectNativeProviderBatch(legs, load = { leg ->
                val bridge = bridge(name, slot)
                try {
                    bridge.load("${scope.digest}:${owner.profileID}:${owner.revision}", leg.request, listOf(leg.addon),
                        budgetMs = nativeProviderBudgetMs(leg.request.resource), maxResponseBytes = NATIVE_PROVIDER_BODY_BYTES).also {
                        check(current(name, slot) && bridge.accepts(it)) { "Native request superseded" }
                    }
                } finally { retire(slot, bridge) }
            }) { update ->
                synchronized(this) {
                    check(current(name, slot)) { "Native request superseded" }
                    slot.completed = update.pages.map { it.requestId to it.generation }
                }
                onUpdate(update, slot.ticket)
            }
            completed = true
        } finally { finish(name, slot, revoke = !completed) }
    }
}
