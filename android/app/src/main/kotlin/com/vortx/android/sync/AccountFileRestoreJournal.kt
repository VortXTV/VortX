package com.vortx.android.sync

import android.content.Context
import android.system.Os
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.nio.file.FileAlreadyExistsException
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.NoSuchFileException
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import java.nio.file.attribute.PosixFileAttributes
import java.nio.file.attribute.PosixFilePermissions
import java.security.MessageDigest
import java.util.Locale
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Retained file-origin evidence. The manager owns authenticated reads, admission, its live account
 * fence, the one PUT, and interpretation of its result. Use the app Context and the original
 * session's existing data key. The journal lives only beneath Context.noBackupFilesDir.
 *
 * One record per account. Admission is create-only and there is no erase or release operation.
 * The original intent and possible-send state share one sealed atomic record across restarts.
 * The app-private namespace is trusted. All writers must use this journal and its lock. NIO
 * leaf no-follow and file-key checks detect ordinary pathname faults. They do not pin ancestor
 * descriptors or defend against a hostile same-UID process renaming paths between syscalls.
 */
internal class AccountFileRestoreJournal private constructor(
    rootDirectory: Path,
    private val appIdentity: () -> AppIdentity,
    private val unixMetadata: (Path) -> UnixMetadata,
) {
    constructor(context: Context) : this(context.noBackupFilesDir.toPath(), {
        val uid = Os.geteuid()
        check(uid == context.applicationInfo.uid)
        AppIdentity(uid, Os.getegid())
    }, { path ->
        val stat = Os.lstat(path.toString())
        UnixMetadata(stat.st_uid, stat.st_gid, stat.st_mode)
    })

    private val root = rootDirectory.toAbsolutePath().normalize()
    private val directory = root.resolve("account-file-restores-v1")
    private val issuer = Any()

    enum class State(internal val wire: Int, val mayHaveSent: Boolean) {
        Retained(0, false),
        NotSubmitted(1, false),
        PossibleSend(2, true),
        DeliveryUnconfirmed(3, true),
        Conflict(4, true),
        UploadAccepted(5, true),
        ServerConfirmed(6, true);

        internal fun permits(next: State): Boolean = when (this) {
            Retained -> next == PossibleSend || next == NotSubmitted
            PossibleSend -> next in setOf(DeliveryUnconfirmed, Conflict, UploadAccepted, ServerConfirmed)
            DeliveryUnconfirmed, UploadAccepted -> next == ServerConfirmed
            NotSubmitted, Conflict, ServerConfirmed -> false
        }
    }

    class Intent private constructor(
        val operationId: UUID,
        val accountId: String,
        val ownerProfileId: String,
        val baseRevision: Long,
        val revision: Long,
        val plaintextSha256: String,
        private val payload: Payload,
    ) {
        constructor(
            operationId: UUID,
            accountId: String,
            ownerProfileId: String,
            baseRevision: Long,
            revision: Long,
            plaintextSha256: String,
            selectedFile: ByteArray,
            candidateFile: ByteArray,
            displacedHeadResponse: ByteArray,
            submissionBytes: ByteArray,
        ) : this(operationId, accountId, ownerProfileId, baseRevision, revision, plaintextSha256,
            Payload(checkedCopy(selectedFile, FILE_LIMIT), checkedCopy(candidateFile, FILE_LIMIT),
                checkedCopy(displacedHeadResponse, HEAD_LIMIT), checkedCopy(submissionBytes, FILE_LIMIT)))

        init {
            requireCanonicalAccount(accountId)
            require(UUID.fromString(ownerProfileId).toString().uppercase(Locale.ROOT) == ownerProfileId)
            require(BackupRevisionPolicy.next(baseRevision) == revision)
            require(HEX_SHA256.matches(plaintextSha256))
        }

        val sourceKind: String get() = SOURCE_KIND
        fun selectedFile(): ByteArray = payload.selected.copyOf()
        fun candidateFile(): ByteArray = payload.candidate.copyOf()
        fun displacedHeadResponse(): ByteArray = payload.head.copyOf()
        fun submissionBytes(): ByteArray = payload.submission.copyOf()

        // Fixed-width metadata and four bounded, length-prefixed exact byte strings.
        internal fun encode(state: State): ByteArray {
            val fields = listOf(payload.selected, payload.candidate, payload.head, payload.submission)
            return ByteBuffer.allocate(HEADER_BYTES + fields.sumOf { it.size }).apply {
                putInt(FORMAT)
                put(state.wire.toByte())
                putLong(operationId.mostSignificantBits)
                putLong(operationId.leastSignificantBits)
                put(accountId.toByteArray(Charsets.US_ASCII))
                put(ownerProfileId.toByteArray(Charsets.US_ASCII))
                putLong(baseRevision)
                putLong(revision)
                put(plaintextSha256.toByteArray(Charsets.US_ASCII))
                for (field in fields) {
                    putInt(field.size)
                    put(field)
                }
            }.array()
        }

        private class Payload(val selected: ByteArray, val candidate: ByteArray,
                              val head: ByteArray, val submission: ByteArray)

        internal companion object {
            fun decode(plain: ByteArray, expectedAccount: String): Pair<Intent, State> {
                val input = ByteBuffer.wrap(plain)
                require(input.remaining() >= HEADER_BYTES)
                require(input.int == FORMAT)
                val wire = input.get().toInt()
                val state = State.entries.single { it.wire == wire }
                val operation = UUID(input.long, input.long)
                val account = input.ascii(36)
                require(account == expectedAccount)
                val owner = input.ascii(36)
                val base = input.long
                val revision = input.long
                val digest = input.ascii(64)
                val selected = input.field(FILE_LIMIT)
                val candidate = input.field(FILE_LIMIT)
                val head = input.field(HEAD_LIMIT)
                val submission = input.field(FILE_LIMIT)
                require(!input.hasRemaining())
                return Intent(operation, account, owner, base, revision, digest,
                    Payload(selected, candidate, head, submission)) to state
            }

            private fun ByteBuffer.ascii(count: Int): String =
                ByteArray(count).also { get(it) }.toString(Charsets.US_ASCII)

            private fun ByteBuffer.field(limit: Int): ByteArray {
                val count = int
                require(count in 1..limit && count <= remaining())
                return ByteArray(count).also { get(it) }
            }
        }
    }

    class Snapshot internal constructor(
        val intent: Intent,
        val state: State,
        private val issuer: Any,
        private val sealedDigest: String,
        private val keyBinding: String,
        private var originalAdmissionGrant: Boolean = false,
    ) {
        internal fun issuedBy(issuer: Any): Boolean = this.issuer === issuer
        internal fun matchesKey(binding: String): Boolean = keyBinding == binding
        internal fun matchesSeal(digest: String): Boolean = sealedDigest == digest

        // Called with the original account's exclusive storage lock held. A failed publication
        // consumes the attempt as well, so a possibly interrupted transition cannot be retried.
        internal fun consumeOriginalAdmission(issuer: Any): Boolean {
            if (!issuedBy(issuer) || !originalAdmissionGrant) return false
            originalAdmissionGrant = false
            return true
        }
    }

    sealed interface Read {
        data object Missing : Read
        data object Unavailable : Read
        data class Present(val snapshot: Snapshot) : Read
    }

    sealed interface Mutation {
        data object Changed : Mutation
        data object Unavailable : Mutation
        data class Applied(val snapshot: Snapshot) : Mutation
    }

    /** Only checked absence returns Missing. Existing bytes require the original existing key. */
    fun readExisting(accountId: String, dataKey: ByteArray?): Read = guarded(Read.Unavailable) {
        val paths = paths(accountId)
        val namespace = openDirectory(create = false) ?: return@guarded Read.Missing
        if (attributes(paths.lock) == null) {
            check(attributes(paths.record) == null && attributes(paths.stage) == null)
            requireNamespace(namespace)
            return@guarded Read.Missing
        }
        locked(namespace, paths, shared = true) { _ ->
            check(attributes(paths.stage) == null)
            val bytes = checkNotNull(readSealed(paths.record))
            val keys = JournalKeys(requireNotNull(dataKey))
            val (intent, state) = authenticate(accountId, keys, bytes)
            Read.Present(Snapshot(intent, state, issuer, digest(bytes), keys.binding))
        }
    }

    fun admit(intent: Intent, dataKey: ByteArray): Mutation = guarded(Mutation.Unavailable) {
        val keys = JournalKeys(dataKey)
        val paths = paths(intent.accountId)
        val namespace = checkNotNull(openDirectory(create = true))
        if (attributes(paths.lock) == null) {
            // The lock is created before any published bytes. An orphan is a recovery failure.
            check(attributes(paths.record) == null && attributes(paths.stage) == null)
            requireNamespace(namespace)
            val claim = createClaim(paths.lock)
            if (claim != null) {
                return@guarded claim.use { channel ->
                    locked(namespace, paths, shared = false, claim = channel) { checkPaths ->
                        check(attributes(paths.record) == null && attributes(paths.stage) == null)
                        channel.force(true)
                        Mutation.Applied(publish(paths, intent, State.Retained, keys,
                            replace = false, checkPaths = checkPaths))
                    }
                }
            }
        }
        // A pre-existing claim cannot initialize anything, including after a crash.
        locked(namespace, paths, shared = false) { _ ->
            check(attributes(paths.stage) == null)
            authenticate(intent.accountId, keys, checkNotNull(readSealed(paths.record)))
            Mutation.Changed
        }
    }

    /**
     * Snapshot CAS binds the current sealed bytes, this journal instance and the original key.
     * Only the exact original admission snapshot carries the one-use, in-memory PossibleSend
     * grant. A restart read can reconcile evidence or retire a Retained operation as NotSubmitted.
     */
    fun compareAndAdvance(expected: Snapshot, next: State, dataKey: ByteArray): Mutation =
        guarded(Mutation.Unavailable) {
            if (!expected.issuedBy(issuer) || !expected.state.permits(next)) return@guarded Mutation.Changed
            val keys = JournalKeys(dataKey)
            if (!expected.matchesKey(keys.binding)) return@guarded Mutation.Unavailable
            val paths = paths(expected.intent.accountId)
            val namespace = openDirectory(create = false) ?: return@guarded Mutation.Unavailable
            locked(namespace, paths, shared = false) { checkPaths ->
                check(attributes(paths.stage) == null)
                val current = sealedDigest(paths.record) ?: return@locked Mutation.Unavailable
                if (!expected.matchesSeal(current)) {
                    val observed = checkNotNull(readSealed(paths.record))
                    check(digest(observed) == current)
                    authenticate(expected.intent.accountId, keys, observed)
                    return@locked Mutation.Changed
                }
                if (next == State.PossibleSend && !expected.consumeOriginalAdmission(issuer)) {
                    return@locked Mutation.Changed
                }
                Mutation.Applied(publish(paths, expected.intent, next, keys, replace = true,
                    checkPaths = checkPaths))
            }
        }

    private data class Paths(val lock: Path, val record: Path, val stage: Path)
    private data class Namespace(val rootKey: Any?, val directoryKey: Any?)
    private data class AppIdentity(val uid: Int, val gid: Int)
    internal data class UnixMetadata(val uid: Int, val gid: Int, val mode: Int)

    private fun paths(accountId: String): Paths {
        requireCanonicalAccount(accountId)
        val stem = digest(accountId.toByteArray(Charsets.US_ASCII))
        return Paths(directory.resolve("$stem.lock"), directory.resolve("$stem.sealed"), directory.resolve("$stem.stage"))
    }

    private fun attributes(path: Path): PosixFileAttributes? =
        try { Files.readAttributes(path, PosixFileAttributes::class.java, LinkOption.NOFOLLOW_LINKS) }
        catch (_: NoSuchFileException) { null }

    private fun privateAttributes(path: Path): PosixFileAttributes? = attributes(path)?.also {
        val metadata = unixMetadata(path)
        check(metadata.uid == appIdentity().uid)
        val expected = if (it.isDirectory) DIRECTORY_MODE else FILE_MODE
        check((metadata.mode and PERMISSION_BITS) == expected)
    }

    private fun checkedRoot(): PosixFileAttributes = checkNotNull(attributes(root)).also {
        check(it.isDirectory)
        val metadata = unixMetadata(root)
        val identity = appIdentity()
        check(metadata.uid == identity.uid && (metadata.mode and OTHER_WRITE) == 0)
        // ContextImpl may create this app-private parent with mode 0771. Only the app's
        // effective group may have write access there. Journal descendants stay 0700/0600.
        check((metadata.mode and GROUP_WRITE) == 0 || metadata.gid == identity.gid)
    }

    private fun openDirectory(create: Boolean): Namespace? {
        val rootInfo = checkedRoot()
        if (create && attributes(directory) == null) {
            try { Files.createDirectory(directory, PRIVATE_DIRECTORY) } catch (_: FileAlreadyExistsException) { }
        }
        val actual = privateAttributes(directory) ?: return null
        check(actual.isDirectory)
        return Namespace(rootInfo.fileKey(), actual.fileKey())
    }

    private fun requireNamespace(expected: Namespace) {
        check(openDirectory(create = false) == expected)
    }

    private fun createClaim(path: Path): FileChannel? = try {
        FileChannel.open(path, setOf(StandardOpenOption.WRITE, StandardOpenOption.CREATE_NEW,
            LinkOption.NOFOLLOW_LINKS), PRIVATE_FILE)
    } catch (_: FileAlreadyExistsException) {
        null
    }

    private fun checkedLock(path: Path): PosixFileAttributes {
        val info = checkNotNull(privateAttributes(path))
        check(info.isRegularFile && info.size() == 0L)
        return info
    }

    private fun <T> locked(
        namespace: Namespace,
        paths: Paths,
        shared: Boolean,
        claim: FileChannel? = null,
        block: (checkPaths: () -> Unit) -> T,
    ): T {
        requireNamespace(namespace)
        val lockKey = checkedLock(paths.lock).fileKey()
        fun checkPaths() {
            requireNamespace(namespace)
            check(checkedLock(paths.lock).fileKey() == lockKey)
        }
        fun usingChannel(channel: FileChannel): T {
            check(channel.size() == 0L)
            val lock = checkNotNull(channel.tryLock(0L, Long.MAX_VALUE, shared))
            try {
                checkPaths()
                return block(::checkPaths).also { checkPaths() }
            } finally {
                lock.release()
            }
        }
        if (claim != null) return usingChannel(claim)
        val mode = if (shared) StandardOpenOption.READ else StandardOpenOption.WRITE
        return FileChannel.open(paths.lock, mode, LinkOption.NOFOLLOW_LINKS).use(::usingChannel)
    }

    private fun <T> readRecord(path: Path, read: (FileChannel, Int) -> T): T? {
        val info = privateAttributes(path) ?: return null
        check(info.isRegularFile && info.size() in MINIMUM_SEALED.toLong()..MAXIMUM_SEALED.toLong())
        return FileChannel.open(path, StandardOpenOption.READ, LinkOption.NOFOLLOW_LINKS).use { channel ->
            check(channel.size() == info.size())
            val result = read(channel, info.size().toInt())
            check(channel.read(ByteBuffer.allocate(1)) == -1)
            result
        }
    }

    private fun readSealed(path: Path): ByteArray? = readRecord(path) { channel, size ->
        val buffer = ByteBuffer.allocate(size)
        while (buffer.hasRemaining()) check(channel.read(buffer) > 0)
        buffer.array()
    }

    private fun sealedDigest(path: Path): String? = readRecord(path) { channel, size ->
        val digest = MessageDigest.getInstance("SHA-256")
        val buffer = ByteBuffer.allocate(8192)
        var remaining = size
        while (remaining > 0) {
            buffer.clear()
            buffer.limit(minOf(buffer.capacity(), remaining))
            val count = channel.read(buffer)
            check(count > 0)
            digest.update(buffer.array(), 0, count)
            remaining -= count
        }
        hex(digest.digest())
    }

    private fun publish(paths: Paths, intent: Intent, state: State, keys: JournalKeys,
                        replace: Boolean, checkPaths: () -> Unit): Snapshot {
        // Sync the parent even on retry after an earlier incomplete directory creation.
        checkPaths()
        syncDirectory(root)
        if (!replace) syncDirectory(directory) // Retain the new claim before writing any intent.
        val plain = intent.encode(state)
        val sealed = try {
            val cipher = Cipher.getInstance(CIPHER)
            cipher.init(Cipher.ENCRYPT_MODE, keys.aes)
            check(cipher.iv.size == NONCE_BYTES)
            cipher.updateAAD(aad(intent.accountId))
            ByteArray(NONCE_BYTES + plain.size + TAG_BYTES).also { output ->
                cipher.iv.copyInto(output)
                check(cipher.doFinal(plain, 0, plain.size, output, NONCE_BYTES) == plain.size + TAG_BYTES)
            }
        } finally {
            plain.fill(0)
        }
        val expectedDigest = digest(sealed)
        checkPaths()
        // A surviving stage is uncertainty. Retain it and fail closed on subsequent reads.
        FileChannel.open(paths.stage, setOf(StandardOpenOption.CREATE_NEW, StandardOpenOption.WRITE,
            LinkOption.NOFOLLOW_LINKS), PRIVATE_FILE).use { channel ->
            val buffer = ByteBuffer.wrap(sealed)
            while (buffer.hasRemaining()) check(channel.write(buffer) > 0)
            channel.force(true)
        }
        check(sealedDigest(paths.stage) == expectedDigest)
        checkPaths()
        if (replace) {
            Files.move(paths.stage, paths.record, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
        } else {
            Files.createLink(paths.record, paths.stage)
            Files.delete(paths.stage)
        }
        syncDirectory(directory)
        check(sealedDigest(paths.record) == expectedDigest)
        return Snapshot(intent, state, issuer, expectedDigest, keys.binding, originalAdmissionGrant = !replace)
    }

    private fun syncDirectory(path: Path) {
        FileChannel.open(path, StandardOpenOption.READ, LinkOption.NOFOLLOW_LINKS).use { it.force(true) }
    }

    private fun open(accountId: String, key: SecretKeySpec, sealed: ByteArray): ByteArray {
        val cipher = Cipher.getInstance(CIPHER)
        cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, sealed, 0, NONCE_BYTES))
        cipher.updateAAD(aad(accountId))
        return cipher.doFinal(sealed, NONCE_BYTES, sealed.size - NONCE_BYTES)
    }

    private fun authenticate(accountId: String, keys: JournalKeys, sealed: ByteArray): Pair<Intent, State> {
        val plaintext = open(accountId, keys.aes, sealed)
        return try { Intent.decode(plaintext, accountId) } finally { plaintext.fill(0) }
    }

    private class JournalKeys(dataKey: ByteArray) {
        init { require(dataKey.size == 32) }
        private val mac = Mac.getInstance("HmacSHA256").apply {
            init(SecretKeySpec(dataKey, "HmacSHA256"))
        }
        val aes: SecretKeySpec = mac.doFinal("$DOMAIN/seal".toByteArray(Charsets.US_ASCII)).let { derived ->
            try { SecretKeySpec(derived, "AES") } finally { derived.fill(0) }
        }
        val binding: String = mac.doFinal("$DOMAIN/capture".toByteArray(Charsets.US_ASCII)).let { derived ->
            try { hex(derived) } finally { derived.fill(0) }
        }
    }

    private fun <T> guarded(unavailable: T, block: () -> T): T = synchronized(PROCESS_LOCK) {
        try { block() } catch (_: Exception) { unavailable }
    }

    companion object {
        private const val DOMAIN = "vortx-android-account-file-restore-journal-v1"
        private const val SOURCE_KIND = "user_selected_file"
        private const val FORMAT = 0x56465231 // VFR1
        private const val CIPHER = "AES/GCM/NoPadding"
        private const val NONCE_BYTES = 12
        private const val TAG_BYTES = 16
        private const val FILE_LIMIT = AccountBackupFile.MAXIMUM_FILE_BYTES
        private const val HEAD_LIMIT = AccountBackupFile.MAXIMUM_RESPONSE_BYTES
        private const val HEADER_BYTES = 4 + 1 + 16 + 36 + 36 + 8 + 8 + 64 + 4 * 4
        private const val MINIMUM_SEALED = HEADER_BYTES + 4 + NONCE_BYTES + TAG_BYTES
        private const val MAXIMUM_SEALED = HEADER_BYTES + 3 * FILE_LIMIT + HEAD_LIMIT + NONCE_BYTES + TAG_BYTES
        private const val PERMISSION_BITS = 0b111_111_111_111
        private const val DIRECTORY_MODE = 0b111_000_000 // 0700
        private const val FILE_MODE = 0b110_000_000 // 0600
        private const val GROUP_WRITE = 0b000_010_000
        private const val OTHER_WRITE = 0b000_000_010
        private val HEX_SHA256 = Regex("[0-9a-f]{64}")
        private val PRIVATE_DIRECTORY = PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rwx------"))
        private val PRIVATE_FILE = PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rw-------"))
        private val PROCESS_LOCK = Any()

        /** JVM fixture metadata seam. The production constructor obtains these facts from Android. */
        internal fun forJvmFixture(
            rootDirectory: Path,
            uid: Int,
            gid: Int,
            metadata: (Path) -> UnixMetadata,
        ): AccountFileRestoreJournal = AccountFileRestoreJournal(rootDirectory, { AppIdentity(uid, gid) }, metadata)

        private fun requireCanonicalAccount(accountId: String) {
            require(UUID.fromString(accountId).toString() == accountId)
        }

        private fun checkedCopy(bytes: ByteArray, limit: Int): ByteArray {
            require(bytes.size in 1..limit)
            return bytes.copyOf()
        }

        private fun aad(accountId: String): ByteArray = "$DOMAIN\u0000$SOURCE_KIND\u0000$accountId".toByteArray(Charsets.US_ASCII)
        private fun digest(bytes: ByteArray): String = hex(MessageDigest.getInstance("SHA-256").digest(bytes))
        private fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it) }
    }
}
