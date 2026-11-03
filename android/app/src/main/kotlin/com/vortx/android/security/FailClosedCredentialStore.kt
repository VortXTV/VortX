package com.vortx.android.security

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import com.google.crypto.tink.RegistryConfiguration
import com.google.crypto.tink.TinkProtoKeysetFormat
import com.google.crypto.tink.integration.android.AndroidKeystoreKmsClient
import com.google.crypto.tink.subtle.Hex
import com.vortx.android.engine.AccountFileLocalPresence
import com.vortx.android.sync.AccountFileRestoreManagerExclusion
import java.io.File
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.NoSuchFileException
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import java.nio.file.attribute.BasicFileAttributes
import java.nio.file.attribute.FileTime
import java.security.MessageDigest
import java.util.UUID

/** The three app-owned provider carriers have ordinary open/reopen paths outside the manager.
 * Count them from process startup, including before the process provider binding exists. */
internal object AccountFileProviderWriters {
    private val carriers = setOf("vortx_native_provider_credentials", "vortx_debrid_keys", "vortx_metadata_credentials")
    private val exclusion = AccountFileRestoreManagerExclusion()

    fun contains(carrier: String): Boolean = carrier in carriers

    fun <T> withCarrierWriter(carrier: String, refused: T, work: () -> T): T =
        if (contains(carrier)) withWriter(refused, work) else work()

    fun <T> withWriter(refused: T, work: () -> T): T {
        if (!exclusion.enterWriter(observedEdit = false)) return refused
        return try { work() } finally { exclusion.exitWriter() }
    }

    /** Retain only writer membership during structured transport and publication. */
    suspend fun <T> withEffectfulWriter(refused: T, work: suspend () -> T): T {
        if (!exclusion.enterWriter(observedEdit = false)) return refused
        return try { work() } finally { exclusion.exitWriter() }
    }

    fun tryReserve(): AccountFileRestoreManagerExclusion.Reservation? = exclusion.tryReserve()
    fun isCurrent(reservation: AccountFileRestoreManagerExclusion.Reservation): Boolean = exclusion.isCurrent(reservation)
    fun release(reservation: AccountFileRestoreManagerExclusion.Reservation) = exclusion.release(reservation)
}

/**
 * A tiny encrypted credential store that never falls back to disk plaintext.
 *
 * If Android Keystore or EncryptedSharedPreferences is unavailable, new writes remain usable for the current
 * process from memory and disappear on restart. Any legacy plaintext fallback file is purged at initialization
 * and again on removal. Initial-open and read failures remain retryable. An ambiguous encrypted write outcome
 * permanently blocks backend reopening for this process so SharedPreferences' mutated process cache cannot be
 * mistaken for durable credential truth. The encrypted file is always retained across backend failures.
 */
internal class FailClosedCredentialStore(
    context: Context,
    private val encryptedFileName: String,
    private val legacyPlainFileName: String = "${encryptedFileName}_plain",
    private val tag: String,
) {
    private val appContext = context.applicationContext
    private val backingFile = File(File(appContext.dataDir, "shared_prefs"), "$encryptedFileName.xml")
    private val restoreGate = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
        RestoreCredentialOpenGate.forStore(encryptedFileName, backingFile, File(appContext.dataDir, "no_backup"))
    else null
    private val state: FailClosedCredentialState
    private var initialProviderPurgePending = AccountFileProviderWriters.contains(encryptedFileName)

    init {
        if (!initialProviderPurgePending) purgeLegacyPlaintext()
        state = FailClosedCredentialState(
            backend = openBackend(),
            onBackendFailure = { error ->
                Log.e(tag, "Encrypted credential storage failed; using confirmed state", error)
            },
            reopenBackend = ::openBackend,
        )
    }

    private fun openBackend(): CredentialBackend? = withCarrierWriter(null) {
        // Construction/refetch may initialize encrypted preferences or recover an Android
        // backup. Defer both the open and its initial purge if Restore already holds the gate.
        if (initialProviderPurgePending) {
            purgeLegacyPlaintext()
            initialProviderPurgePending = false
        }
        openCredentialBackendOrNull({
            val gate = restoreGate
            if (gate == null) {
                SharedPreferencesCredentialBackend(openEncryptedPreferences())
            } else {
                // The one genesis attempt must observe physical absence before Android's raw cache.
                val raw by lazy { appContext.getSharedPreferences(encryptedFileName, Context.MODE_PRIVATE) }
                gate.open({ raw.all }, RestoreCredentialBacking::authenticateKeysets) {
                    SharedPreferencesCredentialBackend(openEncryptedPreferences(), raw, gate)
                }
            }
        }) { error ->
            Log.e(tag, "Encrypted credential storage unavailable; using memory only", error)
        }
    }

    private fun <T> withCarrierWriter(refused: T, work: () -> T): T =
        AccountFileProviderWriters.withCarrierWriter(encryptedFileName, refused, work)

    private fun openEncryptedPreferences(): SharedPreferences {
        val masterKey = MasterKey.Builder(appContext)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
        return EncryptedSharedPreferences.create(
            appContext,
            encryptedFileName,
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )
    }

    fun string(key: String): String? = withCarrierWriter<String?>(null) { state.string(key) }

    fun confirmedSnapshot(vararg keys: String): PersistentCredentialSnapshot =
        withCarrierWriter(PersistentCredentialSnapshot(PersistentCredentialAvailability.UNAVAILABLE, emptyMap())) {
            state.confirmedSnapshot(*keys)
        }

    /** Presence only. Never reopen the encrypted backend or expose a credential value. */
    fun inspectExisting(vararg keys: String): AccountFileLocalPresence =
        state.inspectExisting(*keys)

    /** One exact app-owned schema can classify a stored carrier as inert for Restore. */
    fun inspectExisting(key: String, isInert: (String) -> Boolean): AccountFileLocalPresence =
        state.inspectExisting(key, isInert)

    fun setIfConfirmedAbsent(key: String, value: String): ConditionalCredentialWrite =
        withCarrierWriter(ConditionalCredentialWrite.UNAVAILABLE) { state.writeIfConfirmedAbsent(key, value) }

    fun set(key: String, value: String?): Boolean = set(mapOf(key to value))

    fun set(values: Map<String, String?>): Boolean = withCarrierWriter(false) { state.write(values) }

    fun replaceConfirmed(expected: Map<String, String?>, updates: Map<String, String?>): Boolean =
        withCarrierWriter(false) { state.replaceConfirmed(expected, updates) }

    fun setAndPurgeLegacy(values: Map<String, String?>): Boolean = withCarrierWriter(false) {
        writeThenPurgeLegacy(write = { state.write(values) }, purge = ::purgeLegacyPlaintext)
    }

    fun clear(vararg keys: String): Boolean =
        setAndPurgeLegacy(keys.associateWith { null })

    private fun purgeLegacyPlaintext() {
        val cleared = try {
            appContext.getSharedPreferences(legacyPlainFileName, Context.MODE_PRIVATE)
                .edit()
                .clear()
                .commit()
        } catch (error: Exception) {
            Log.e(tag, "Could not purge legacy plaintext credential storage", error)
            false
        }
        val deleted = try {
            appContext.deleteSharedPreferences(legacyPlainFileName)
        } catch (error: Exception) {
            Log.e(tag, "Could not delete legacy plaintext credential storage", error)
            false
        }
        if (!cleared && !deleted) {
            Log.e(tag, "Legacy plaintext credential storage could not be cleared or deleted")
        }
    }
}

internal fun writeThenPurgeLegacy(
    write: () -> Boolean,
    purge: () -> Unit,
): Boolean {
    return try {
        write()
    } finally {
        purge()
    }
}

internal fun openCredentialBackendOrNull(
    opener: () -> CredentialBackend,
    onFailure: (Exception) -> Unit = {},
): CredentialBackend? = try {
    opener()
} catch (error: Exception) {
    onFailure(error)
    null
}

internal interface CredentialBackend {
    fun string(key: String): String?
    /** Exact disk-backed keys, or null when this backend cannot prove its read health. */
    fun readExistingForRestore(keys: List<String>): Map<String, String?>? = null
    fun write(values: Map<String, String?>): Boolean
}

internal enum class PersistentCredentialAvailability {
    AVAILABLE,
    UNAVAILABLE,
}

internal data class PersistentCredentialSnapshot(
    val availability: PersistentCredentialAvailability,
    val values: Map<String, String?>,
)

internal enum class ConditionalCredentialWrite {
    WRITTEN,
    ALREADY_PRESENT,
    UNAVAILABLE,
    REJECTED,
}

private class SharedPreferencesCredentialBackend(
    private val prefs: SharedPreferences,
    private val encryptedPrefs: SharedPreferences? = null,
    private val restoreGate: RestoreCredentialOpenGate? = null,
) : CredentialBackend {
    override fun string(key: String): String? = prefs.getString(key, null)

    override fun readExistingForRestore(keys: List<String>): Map<String, String?>? =
        restoreGate?.inspect({ checkNotNull(encryptedPrefs).all }, RestoreCredentialBacking::authenticateKeysets) { before ->
            // Validate the authenticated logical index, not just selected-key defaults. A corrupt
            // encrypted key must not look like the absence of a different deterministic key.
            val decoded = prefs.all
            check(decoded.size == before.size - RestoreCredentialBacking.KEYSET_COUNT &&
                decoded.values.all { it is String })
            keys.associateWith { key ->
                val value = prefs.getString(key, null)
                check(prefs.contains(key) == (value != null) && decoded[key] == value)
                value
            }
        }

    override fun write(values: Map<String, String?>): Boolean {
        val gate = restoreGate
        return if (gate == null || values.isEmpty()) commit(values) else gate.write(
            { checkNotNull(encryptedPrefs).all }, { prefs.getString(RESTORE_SOURCE_GENERATION, null) },
        ) { generation ->
            commit(values + (RESTORE_SOURCE_GENERATION to generation))
        }
    }

    private fun commit(values: Map<String, String?>): Boolean {
        val editor = prefs.edit()
        values.forEach { (key, value) ->
            if (value == null) editor.remove(key) else editor.putString(key, value)
        }
        return editor.commit()
    }

    private companion object {
        // Private local encrypted metadata. No account-file or cloud wire representation.
        const val RESTORE_SOURCE_GENERATION = "vortx.internal.account-file-restore-generation.v1"
    }
}

/** Restore uses a positive same-install receipt. Missing proof never changes an ordinary result. */
internal class RestoreCredentialOpenGate(
    private val file: File,
    private val receipt: RestoreCredentialReceipt,
) {
    private var checkedGenesis = false
    private var unverifiedMutation = false

    @Synchronized fun <T> open(readRaw: () -> Map<String, *>,
                               authenticate: (Map<String, String>) -> Unit, opener: () -> T): T {
        if (checkedGenesis) return opener()
        checkedGenesis = true
        // Only the first ordinary open can prove a genuinely fresh physical carrier. An old,
        // restored, repaired or unreadable existing carrier cannot be enrolled by opening it.
        val fresh = try {
            receipt.isAbsent() && RestoreCredentialBacking.isFresh(file) &&
                readRaw().isEmpty() && RestoreCredentialBacking.isFresh(file)
        } catch (_: Exception) { false }
        val opened = opener()
        if (fresh) {
            try {
                val created = readPhysicalAndCache(readRaw)
                check(created.entries.size == RestoreCredentialBacking.KEYSET_COUNT)
                authenticate(created.entries)
                receipt.save(created.identity)
            } catch (_: Exception) {
                // No positive receipt can be derived from an uncertain initialization.
            }
        }
        return opened
    }

    @Synchronized fun <T> inspect(readRaw: () -> Map<String, *>,
                                  authenticate: (Map<String, String>) -> Unit,
                                  inspect: (Map<String, String>) -> T): T? {
        if (unverifiedMutation) return null
        val before = verified(readRaw) ?: return null
        authenticate(before.entries)
        val result = inspect(before.entries)
        check(verified(readRaw) == before)
        return result
    }

    @Synchronized fun write(readRaw: () -> Map<String, *>, readGeneration: () -> String?,
                            commit: (String) -> Boolean): Boolean {
        val before = if (unverifiedMutation) null else try { verified(readRaw) } catch (_: Exception) { null }
        // Even if the old receipt cannot be read now, the same encrypted editor commits a
        // fresh generation. A false commit cannot recreate an older qualifying ciphertext map.
        val generation = UUID.randomUUID().toString()
        val committed = try { commit(generation) } catch (error: Exception) {
            unverifiedMutation = true
            throw error
        }
        if (!committed || before == null) {
            unverifiedMutation = true
            return committed
        }
        try {
            val after = readPhysicalAndCache(readRaw)
            check(readGeneration() == generation &&
                RestoreCredentialBacking.keysetIdentity(after.entries) ==
                RestoreCredentialBacking.keysetIdentity(before.entries))
            receipt.save(after.identity)
        } catch (_: Exception) {
            // An earlier receipt cannot match this generation. Preserve the true commit result.
            unverifiedMutation = true
        }
        return true
    }

    private fun verified(readRaw: () -> Map<String, *>): RestoreCredentialBacking.Observation? {
        val expected = receipt.read() ?: return null
        val backing = readPhysicalAndCache(readRaw)
        return backing.takeIf { it.identity == expected && receipt.read() == expected }
    }

    private fun readPhysicalAndCache(readRaw: () -> Map<String, *>): RestoreCredentialBacking.Observation {
        val before = RestoreCredentialBacking.observe(file)
        check(before.entries == readRaw() && before == RestoreCredentialBacking.observe(file))
        return before
    }

    companion object {
        private val protectedFiles = setOf("vortx_native_provider_credentials", "vortx_debrid_keys",
            "vortx_metadata_credentials", "vortx_owner_watched_intents", "vortx_library_publication",
            "vortx_addon_publication")
        private val gates = mutableMapOf<String, RestoreCredentialOpenGate>()

        @Synchronized fun forStore(name: String, file: File, noBackup: File): RestoreCredentialOpenGate? =
            if (name in protectedFiles) gates.getOrPut(file.absolutePath) {
                RestoreCredentialOpenGate(file, RestoreCredentialReceipt(
                    File(noBackup, "vortx-restore-credential-proof-v1-$name")))
            } else null
    }
}

/** A bounded device-local receipt carries only the digest of one observed backing. */
internal class RestoreCredentialReceipt(file: File) {
    private val path = file.toPath()
    private val directory = path.parent

    fun isAbsent(): Boolean = receiptAttributes() == null

    fun read(): String? {
        val before = receiptAttributes() ?: return null
        check(before.isRegularFile && before.size() == DIGEST_LENGTH.toLong())
        val bytes = ByteArray(DIGEST_LENGTH)
        Files.newInputStream(path, LinkOption.NOFOLLOW_LINKS).use { input ->
            var offset = 0
            while (offset < bytes.size) {
                val count = input.read(bytes, offset, bytes.size - offset)
                check(count > 0)
                offset += count
            }
            check(input.read() == -1)
        }
        val after = checkNotNull(receiptAttributes())
        check(after.isRegularFile && before.fileKey() == after.fileKey() &&
            before.size() == after.size() && before.lastModifiedTime() == after.lastModifiedTime())
        return bytes.toString(Charsets.US_ASCII).also { check(DIGEST.matches(it)) }
    }

    fun save(identity: String) {
        check(DIGEST.matches(identity))
        check(attributes(directory.parent)?.isDirectory == true)
        try { Files.createDirectory(directory) } catch (_: java.nio.file.FileAlreadyExistsException) { }
        check(attributes(directory)?.isDirectory == true)
        val pending = Files.createTempFile(directory, path.fileName.toString(), ".pending")
        try {
            FileChannel.open(pending, StandardOpenOption.WRITE, LinkOption.NOFOLLOW_LINKS).use { channel ->
                val bytes = java.nio.ByteBuffer.wrap(identity.toByteArray(Charsets.US_ASCII))
                while (bytes.hasRemaining()) check(channel.write(bytes) > 0)
                channel.force(true)
            }
            Files.move(pending, path, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
            FileChannel.open(directory, StandardOpenOption.READ).use { it.force(true) }
            FileChannel.open(directory.parent, StandardOpenOption.READ).use { it.force(true) }
        } finally {
            Files.deleteIfExists(pending)
        }
    }

    private fun receiptAttributes(): BasicFileAttributes? {
        val parent = attributes(directory) ?: return null
        check(parent.isDirectory)
        return attributes(path)
    }

    private fun attributes(path: Path): BasicFileAttributes? =
        try { Files.readAttributes(path, BasicFileAttributes::class.java, LinkOption.NOFOLLOW_LINKS) }
        catch (_: NoSuchFileException) { null }

    private companion object {
        const val DIGEST_LENGTH = 64
        val DIGEST = Regex("[0-9a-f]{64}")
    }
}

/** Strict, read-only evidence for Android's text SharedPreferences writer. The selected
 * backend must independently match this encrypted backing map before using decrypted data. */
internal object RestoreCredentialBacking {
    private const val MAX_BYTES = 16_777_216
    private const val MAX_KEYS = 100_000
    private val keysets = setOf("__androidx_security_crypto_encrypted_prefs_key_keyset__",
        "__androidx_security_crypto_encrypted_prefs_value_keyset__")
    val KEYSET_COUNT: Int get() = keysets.size

    fun keysetIdentity(entries: Map<String, String>): String = mapIdentity(entries.filterKeys(keysets::contains))

    fun mapIdentity(entries: Map<String, String>): String {
        val digest = MessageDigest.getInstance("SHA-256")
        // NUL cannot occur in the strict XML 1.0 string map.
        for (key in entries.keys.sorted()) {
            digest.update(key.toByteArray(Charsets.UTF_8))
            digest.update(0.toByte())
            digest.update(entries.getValue(key).toByteArray(Charsets.UTF_8))
            digest.update(0.toByte())
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    data class Observation(val entries: Map<String, String>, val identity: String)

    fun isFresh(file: File): Boolean {
        val path = file.toPath()
        val parent = path.parent
        require(attributes(parent.parent).isDirectory)
        val directory = attributesIfPresent(parent)
        require(directory == null || directory.isDirectory)
        requireNoTransaction(file)
        return attributesIfPresent(path) == null
    }

    fun authenticateKeysets(entries: Map<String, String>) {
        val master = AndroidKeystoreKmsClient().getAead(
            AndroidKeystoreKmsClient.PREFIX + MasterKey.DEFAULT_MASTER_KEY_ALIAS)
        for (key in keysets) {
            val hex = entries.getValue(key)
            check(hex.length <= 131_072)
            TinkProtoKeysetFormat.parseEncryptedKeyset(
                Hex.decode(hex), master, byteArrayOf(), RegistryConfiguration.get())
        }
    }

    fun observe(file: File): Observation {
        val path = file.toPath()
        val before = physicalIdentity(path)
        val entries = read(file)
        check(before == physicalIdentity(path))
        val digest = MessageDigest.getInstance("SHA-256").digest(
            "$before\u0000${mapIdentity(entries)}".toByteArray(Charsets.UTF_8))
        return Observation(entries, digest.joinToString("") { "%02x".format(it) })
    }

    private fun physicalIdentity(path: Path): String {
        val attrs = Files.readAttributes(path, "unix:dev,ino,ctime", LinkOption.NOFOLLOW_LINKS)
        val dev = attrs["dev"] as Long
        val ino = attrs["ino"] as Long
        val changed = attrs["ctime"] as FileTime
        return "$dev:$ino:$changed"
    }

    fun read(file: File): Map<String, String> =
        checkNotNull(readIfPresent(file)) { "Encrypted credential backing is missing" }

    /** Null proves that the primary and both transaction siblings are physically absent. */
    fun readIfPresent(file: File): Map<String, String>? {
        val path = file.toPath()
        val parent = path.parent
        require(attributes(parent.parent).isDirectory)
        val directory = attributesIfPresent(parent)
        require(directory == null || directory.isDirectory)
        requireNoTransaction(file)
        val original = attributesIfPresent(path)
        if (original == null) {
            requireNoTransaction(file)
            require(attributesIfPresent(path) == null)
            return null
        }
        require(original.isRegularFile && original.size() in 1L..MAX_BYTES.toLong())
        val bytes = ByteArray(original.size().toInt())
        Files.newInputStream(path, LinkOption.NOFOLLOW_LINKS).use { input ->
            var offset = 0
            while (offset < bytes.size) {
                val count = input.read(bytes, offset, bytes.size - offset)
                require(count > 0) { "Credential backing changed during read" }
                offset += count
            }
            require(input.read() == -1)
        }
        val result = parse(bytes)
        val after = attributes(path)
        require(after.isRegularFile && original.fileKey() == after.fileKey() &&
            original.size() == after.size() && original.lastModifiedTime() == after.lastModifiedTime())
        requireNoTransaction(file)
        return result
    }

    private fun attributes(path: Path): BasicFileAttributes =
        Files.readAttributes(path, BasicFileAttributes::class.java, LinkOption.NOFOLLOW_LINKS)

    private fun attributesIfPresent(path: Path): BasicFileAttributes? =
        try { attributes(path) } catch (_: NoSuchFileException) { null }

    private fun requireNoTransaction(file: File) {
        for (suffix in listOf(".bak", ".new")) {
            require(attributesIfPresent(File(file.path + suffix).toPath()) == null) {
                "Credential backing transaction is unresolved"
            }
        }
    }

    private fun parse(bytes: ByteArray): Map<String, String> {
        val text = Charsets.UTF_8.newDecoder()
            .onMalformedInput(java.nio.charset.CodingErrorAction.REPORT)
            .onUnmappableCharacter(java.nio.charset.CodingErrorAction.REPORT)
            .decode(java.nio.ByteBuffer.wrap(bytes)).toString()
        // The platform string-map writer uses neither DTDs nor other markup declarations.
        require("<!" !in text)
        val builder = javax.xml.parsers.DocumentBuilderFactory.newInstance().apply {
            isNamespaceAware = true
            isExpandEntityReferences = false
        }.newDocumentBuilder()
        builder.setEntityResolver { _, _ -> throw org.xml.sax.SAXException("External credential document refused") }
        builder.setErrorHandler(object : org.xml.sax.helpers.DefaultHandler() {
            override fun error(e: org.xml.sax.SAXParseException) { throw e }
            override fun fatalError(e: org.xml.sax.SAXParseException) { throw e }
        })
        val root = builder.parse(org.xml.sax.InputSource(java.io.StringReader(text))).documentElement
        require(root.tagName == "map" && root.namespaceURI == null && root.attributes.length == 0)
        val result = linkedMapOf<String, String>()
        val nodes = root.childNodes
        for (index in 0 until nodes.length) {
            val node = nodes.item(index)
            if (node.nodeType == org.w3c.dom.Node.TEXT_NODE) {
                require(node.nodeValue.isBlank())
                continue
            }
            require(result.size < MAX_KEYS)
            val entry = node as? org.w3c.dom.Element ?: error("Malformed credential backing map")
            require(entry.tagName == "string" && entry.namespaceURI == null &&
                entry.attributes.length == 1 && entry.hasAttribute("name"))
            val children = entry.childNodes
            require((0 until children.length).all { children.item(it).nodeType == org.w3c.dom.Node.TEXT_NODE })
            val name = entry.getAttribute("name")
            val value = entry.textContent
            require(name.isNotEmpty() && value.isNotEmpty() && result.put(name, value) == null)
        }
        require(keysets.all { key ->
            val value = result[key]
            value != null && value.length % 2 == 0 && value.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }
        })
        return result
    }
}

/**
 * Pure state machine behind [FailClosedCredentialStore]. Keeping this independent of Android makes the
 * secure-open, post-open read, and post-open write failure paths executable in local unit tests.
 */
internal class FailClosedCredentialState(
    backend: CredentialBackend?,
    private val reopenBackend: () -> CredentialBackend? = { null },
    private val onBackendFailure: (Exception) -> Unit = {},
) {
    private var backend: CredentialBackend? = backend
    private var writeFailurePoisoned = false
    private val memory = mutableMapOf<String, String>()
    private val confirmed = mutableMapOf<String, String>()
    private val unconfirmedMemoryKeys = mutableSetOf<String>()

    val hasPersistentBackend: Boolean
        @Synchronized get() = backend != null

    @Synchronized
    fun string(key: String): String? {
        val persistent = backend ?: reopenPersistentBackend()
        if (persistent != null) {
            try {
                val value = persistent.string(key)
                rememberConfirmed(key, value)
                return value
            } catch (error: Exception) {
                disableBackend(error)
            }
        }
        return memory[key]
    }

    @Synchronized
    fun confirmedSnapshot(vararg keys: String): PersistentCredentialSnapshot {
        val requestedKeys = keys.distinct()
        val persistent = backend ?: reopenPersistentBackend()
        if (persistent == null) {
            return unavailableSnapshot(requestedKeys)
        }
        return try {
            val values = requestedKeys.associateWith(persistent::string)
            values.forEach(::rememberConfirmed)
            PersistentCredentialSnapshot(
                availability = PersistentCredentialAvailability.AVAILABLE,
                values = values,
            )
        } catch (error: Exception) {
            disableBackend(error)
            unavailableSnapshot(requestedKeys)
        }
    }

    /** A memory-only value or last confirmed value must not be mistaken for clean absence.
     * The restore caller uses the already-open store instance. This never opens/reopens a
     * backend, purges legacy files, changes cache state, or logs an exception with key data. */
    fun inspectExisting(vararg keys: String): AccountFileLocalPresence =
        inspectExisting(keys.asList()) { false }

    fun inspectExisting(key: String, isInert: (String) -> Boolean): AccountFileLocalPresence =
        inspectExisting(listOf(key), isInert)

    @Synchronized private fun inspectExisting(keys: List<String>, isInert: (String) -> Boolean): AccountFileLocalPresence {
        if (keys.isEmpty()) return AccountFileLocalPresence.UNAVAILABLE
        if (keys.any(unconfirmedMemoryKeys::contains)) return AccountFileLocalPresence.PRESENT
        return try {
            val existing = backend?.readExistingForRestore(keys) ?: return AccountFileLocalPresence.UNAVAILABLE
            check(existing.keys == keys.toSet())
            // Cache state can veto absence, but only a matching disk-backed value can be inert.
            if (keys.any { key ->
                    memory[key]?.let { it != existing[key] } == true ||
                        confirmed[key]?.let { it != existing[key] } == true
                }) return AccountFileLocalPresence.UNAVAILABLE
            if (existing.values.any { it != null && !isInert(it) }) AccountFileLocalPresence.PRESENT
            else AccountFileLocalPresence.ABSENT
        } catch (cancelled: kotlin.coroutines.cancellation.CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            AccountFileLocalPresence.UNAVAILABLE
        }
    }

    /**
     * Atomically adopt [value] only after this same persistent backend confirms [key] is absent. This prevents
     * a read outage followed by a successful reopen from overwriting a credential that was durable all along.
     */
    @Synchronized
    fun writeIfConfirmedAbsent(key: String, value: String): ConditionalCredentialWrite {
        val persistent = backend ?: reopenPersistentBackend()
        if (persistent == null) return ConditionalCredentialWrite.UNAVAILABLE
        val existing = try {
            persistent.string(key)
        } catch (error: Exception) {
            disableBackend(error)
            return ConditionalCredentialWrite.UNAVAILABLE
        }
        rememberConfirmed(key, existing)
        if (existing != null) {
            return ConditionalCredentialWrite.ALREADY_PRESENT
        }
        val stored = try {
            persistent.write(mapOf(key to value))
        } catch (error: Exception) {
            poisonBackend(error)
            return ConditionalCredentialWrite.UNAVAILABLE
        }
        return if (stored) {
            memory[key] = value
            confirmed[key] = value
            unconfirmedMemoryKeys.remove(key)
            ConditionalCredentialWrite.WRITTEN
        } else {
            poisonBackend(IllegalStateException("Encrypted credential commit was rejected"))
            ConditionalCredentialWrite.REJECTED
        }
    }

    /** Exact confirmed tuple CAS. A rejected/ambiguous commit or readback poisons this process's
     * backend, so its mutated SharedPreferences cache can never certify a replacement credential. */
    @Synchronized
    fun replaceConfirmed(expected: Map<String, String?>, updates: Map<String, String?>): Boolean {
        if (expected.isEmpty() || updates.isEmpty() || !expected.keys.containsAll(updates.keys)) return false
        val persistent = backend ?: reopenPersistentBackend() ?: return false
        val before = try { expected.keys.associateWith(persistent::string) }
            catch (error: Exception) { disableBackend(error); return false }
        before.forEach(::rememberConfirmed)
        if (before != expected) return false
        val replacement = before + updates
        val stored = try { persistent.write(updates) }
            catch (error: Exception) { poisonBackend(error); return false }
        if (!stored) {
            poisonBackend(IllegalStateException("Encrypted credential compare-and-set rejected"))
            return false
        }
        val after = try { expected.keys.associateWith(persistent::string) }
            catch (error: Exception) { poisonBackend(error); return false }
        if (after != replacement) {
            poisonBackend(IllegalStateException("Encrypted credential readback mismatch"))
            return false
        }
        after.forEach(::rememberConfirmed)
        unconfirmedMemoryKeys.removeAll(updates.keys)
        return true
    }

    @Synchronized
    fun write(values: Map<String, String?>): Boolean {
        val persistent = backend ?: reopenPersistentBackend()
        if (persistent == null) {
            if (!writeFailurePoisoned) {
                apply(memory, values)
                unconfirmedMemoryKeys.addAll(values.keys)
            }
            return false
        }
        val previousValues = try {
            values.keys.associateWith(persistent::string)
        } catch (error: Exception) {
            disableBackend(error)
            return false
        }
        previousValues.forEach(::rememberConfirmed)
        val stored = try {
            persistent.write(values)
        } catch (error: Exception) {
            poisonBackend(error)
            return false
        }
        if (!stored) {
            poisonBackend(IllegalStateException("Encrypted credential commit was rejected"))
            return false
        }
        apply(memory, values)
        apply(confirmed, values)
        unconfirmedMemoryKeys.removeAll(values.keys)
        return true
    }

    private fun reopenPersistentBackend(): CredentialBackend? {
        if (writeFailurePoisoned) return null
        val reopened = try {
            reopenBackend()
        } catch (error: Exception) {
            onBackendFailure(error)
            null
        }
        backend = reopened
        return reopened
    }

    private fun unavailableSnapshot(keys: Collection<String>): PersistentCredentialSnapshot =
        PersistentCredentialSnapshot(
            availability = PersistentCredentialAvailability.UNAVAILABLE,
            values = keys.associateWith(confirmed::get),
        )

    private fun rememberConfirmed(key: String, value: String?) {
        if (value == null) {
            confirmed.remove(key)
            memory.remove(key)
        } else {
            confirmed[key] = value
            memory[key] = value
        }
    }

    private fun apply(target: MutableMap<String, String>, values: Map<String, String?>) {
        values.forEach { (key, value) ->
            if (value == null) target.remove(key) else target[key] = value
        }
    }

    private fun disableBackend(error: Exception) {
        if (backend == null) return
        backend = null
        onBackendFailure(error)
    }

    private fun poisonBackend(error: Exception) {
        backend = null
        writeFailurePoisoned = true
        onBackendFailure(error)
    }
}
