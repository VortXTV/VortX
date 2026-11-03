package com.vortx.android.sync

import android.content.Context
import android.system.Os
import com.vortx.android.security.AccountFileProviderWriters
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.NoSuchFileException
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import java.nio.file.attribute.FileTime
import java.nio.file.attribute.PosixFileAttributes
import java.nio.file.attribute.PosixFilePermissions
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.CancellationException
import java.util.concurrent.atomic.AtomicBoolean
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * App-private Android provider outbox. All callers use the primary app process and the same
 * provider writer exclusion. The caller owns original session/vault checks and transport.
 * Path identity and no-follow checks detect ordinary faults within that app-private namespace.
 */
internal class ProviderRetryOutbox private constructor(
    appDirectory: Path,
    private val appIdentity: () -> AppIdentity,
    private val unixMetadata: (Path) -> UnixMetadata,
    private val beforeDirectoryForce: (Path) -> Unit,
) : ProviderRetryStartLedger {
    constructor(context: Context) : this(context.dataDir.toPath(), {
        check(!context.isDeviceProtectedStorage)
        val uid = Os.geteuid()
        check(uid == context.applicationInfo.uid)
        AppIdentity(uid, Os.getegid())
    }, { path ->
        val stat = Os.lstat(path.toString())
        UnixMetadata(stat.st_uid, stat.st_gid, stat.st_mode)
    }, {})

    private val appRoot = appDirectory.toAbsolutePath().normalize()
    private val noBackup = appRoot.resolve("no_backup")
    private val root = noBackup.resolve("vortx-provider-retries-v1")
    private val issuer = Any()

    enum class Provider(internal val fileName: String) {
        TRAKT("trakt.v1"), SIMKL("simkl.v1"),
    }

    data class Lane(val owner: SessionOwnerSnapshot.Account, val provider: Provider) {
        init {
            requireCanonicalAccount(owner.id)
            require(owner.generation > 0)
        }
    }

    class Row(
        val operationId: UUID,
        val add: Boolean,
        val imdb: String?,
        val tmdb: Int?,
        val isSeries: Boolean?,
        credentialProof: ByteArray,
    ) {
        private val proof = credentialProof.also { require(it.size == PROOF_BYTES) }.copyOf()

        init {
            require(imdb != null || tmdb != null)
            require(imdb == null || IMDB.matches(imdb))
            require(tmdb == null || tmdb > 0)
        }

        fun credentialProof(): ByteArray = proof.copyOf()

        internal fun same(other: Row): Boolean = operationId == other.operationId && add == other.add &&
            imdb == other.imdb && tmdb == other.tmdb && isSeries == other.isSeries &&
            MessageDigest.isEqual(proof, other.proof)

        internal fun encode(output: ByteBuffer) {
            val imdbBytes = imdb?.toByteArray(Charsets.US_ASCII) ?: ByteArray(0)
            output.putLong(operationId.mostSignificantBits)
            output.putLong(operationId.leastSignificantBits)
            output.put((if (add) 1 else 0).toByte())
            output.put((when (isSeries) { null -> 0; false -> 1; true -> 2 }).toByte())
            output.putInt(tmdb ?: 0)
            output.put(imdbBytes.size.toByte())
            output.put(imdbBytes)
            output.put(proof)
        }

        internal fun encodedSize(): Int = ROW_MIN_BYTES + (imdb?.length ?: 0)
    }

    sealed interface Read {
        data object Missing : Read
        data object Unavailable : Read
        class Pending(val head: Snapshot) : Read
    }

    enum class Append { Enqueued, AlreadyQueued, Capacity, Unavailable }
    enum class Retire { Retired, Changed, Unavailable }

    /** The issuer and authenticated file revision bind this head to exactly one local image. */
    class Snapshot internal constructor(
        private val issuer: Any,
        val lane: Lane,
        val row: Row,
        private val revision: String,
    ) {
        internal fun issuedBy(issuer: Any, lane: Lane): Boolean = this.issuer === issuer && this.lane == lane
        internal fun matches(revision: String, head: Row): Boolean = this.revision == revision && row.same(head)
    }

    private class StartedHead(
        val issuer: Any,
        override val head: Snapshot,
        val marker: Node,
        val markerRevision: String,
        private val requireCurrent: () -> Unit,
    ) : ProviderRetryStart {
        private val attempted = AtomicBoolean(false)
        private val claimed = AtomicBoolean(false)

        fun requireOriginal() = requireCurrent()

        override fun tryClaimFirstIo(): Boolean {
            if (!attempted.compareAndSet(false, true)) return false
            try { requireCurrent() } catch (_: Exception) { return false }
            claimed.set(true)
            return true
        }

        override fun wasClaimed(): Boolean = claimed.get()
    }

    /** Capture is only for the Restore worker. It gives no dispatch permission. */
    class RestoreAbsence internal constructor(
        private val issuer: Any,
        private val owner: SessionOwnerSnapshot.Account,
        private val reservation: AccountFileRestoreManagerExclusion.Reservation,
        private val observation: Any,
    ) {
        internal fun isCurrent(issuer: Any, owner: SessionOwnerSnapshot.Account): Boolean =
            this.issuer === issuer && this.owner == owner && AccountFileProviderWriters.isCurrent(reservation)

        internal fun verify(issuer: Any, owner: SessionOwnerSnapshot.Account, observation: Any): RestoreCurrency? =
            if (this.observation == observation && isCurrent(issuer, owner)) RestoreCurrency(issuer, owner, reservation) else null
    }

    class RestoreCurrency internal constructor(
        private val issuer: Any,
        private val owner: SessionOwnerSnapshot.Account,
        private val reservation: AccountFileRestoreManagerExclusion.Reservation,
    ) {
        internal fun isCurrent(issuer: Any, owner: SessionOwnerSnapshot.Account): Boolean =
            this.issuer === issuer && this.owner == owner && AccountFileProviderWriters.isCurrent(reservation)
    }

    /** Callers pass a short original-owner assertion. It must not do storage or transport I/O. */
    fun readHead(lane: Lane, dataKey: ByteArray, requireCurrent: () -> Unit): Read =
        ordinary(Read.Unavailable, requireCurrent) {
            val key = sealKey(dataKey)
            val names = paths(lane)
            val keys = namespace(names, create = false) ?: return@ordinary Read.Missing
            val record = readRecord(names, keys, lane, key) ?: return@ordinary Read.Missing
            requireDurable(names, keys, record, requireCurrent)
            Read.Pending(Snapshot(issuer, lane, record.rows.first(), record.revision))
        }

    fun append(lane: Lane, dataKey: ByteArray, row: Row, requireCurrent: () -> Unit): Append =
        ordinary(Append.Unavailable, requireCurrent) {
            require(lane.provider != Provider.SIMKL || row.add)
            val key = sealKey(dataKey)
            val names = paths(lane)
            val keys = checkNotNull(namespace(names, create = true))
            val old = readRecord(names, keys, lane, key)
            val rows = old?.rows.orEmpty()
            rows.firstOrNull { it.operationId == row.operationId }?.let {
                if (!it.same(row)) return@ordinary Append.Unavailable
                requireDurable(names, keys, checkNotNull(old), requireCurrent)
                return@ordinary Append.AlreadyQueued
            }
            if (rows.size == ROW_CAP) return@ordinary Append.Capacity
            requireCurrent()
            publish(names, keys, lane, key, rows + row, old, requireCurrent)
            Append.Enqueued
        }

    override fun claimBeforeIo(
        lane: Lane, dataKey: ByteArray, expected: Snapshot, requireCurrent: () -> Unit,
    ): ProviderRetryStart? = ordinary(null, requireCurrent) {
        if (!expected.issuedBy(issuer, lane)) return@ordinary null
        val names = paths(lane)
        val keys = namespace(names, create = false) ?: return@ordinary null
        val old = readRecord(names, keys, lane, sealKey(dataKey)) ?: return@ordinary null
        if (!expected.matches(old.revision, old.rows.first())) return@ordinary null
        val markerKey = sealKey(dataKey, "start")
        val plaintext = startPayload(old)
        val sealed = try { seal(markerKey, startAad(lane), plaintext) } finally { plaintext.fill(0) }
        val revision = digest(sealed)
        requireDurable(names, keys, old, requireCurrent)
        requireCurrent()
        writePrivate(names.start, sealed)
        val marker = checkNotNull(node(names.start, directory = false))
        val started = StartedHead(issuer, expected, marker, revision, requireCurrent)
        requireRecord(names, keys, old, start = marker)
        requireStart(names, lane, markerKey, old, started)
        syncDirectory(names.epoch)
        requireRecord(names, keys, old, start = marker)
        requireStart(names, lane, markerKey, old, started)
        started
    }

    override fun retireAccepted(
        lane: Lane, dataKey: ByteArray, start: ProviderRetryStart, accepted: ProviderRetryDispatchOutcome.Accepted,
        requireCurrent: () -> Unit,
    ): Retire {
        val started = start as? StartedHead ?: return Retire.Changed
        val expected = started.head
        if (started.issuer !== issuer || !expected.issuedBy(issuer, lane) || !started.wasClaimed() ||
            !accepted.matches(start)) return Retire.Changed
        fun requireOriginal() {
            started.requireOriginal()
            requireCurrent()
        }
        return ordinary(Retire.Unavailable, ::requireOriginal) {
            val key = sealKey(dataKey)
            val markerKey = sealKey(dataKey, "start")
            val names = paths(lane)
            val keys = namespace(names, create = false) ?: return@ordinary Retire.Changed
            val old = readRecord(names, keys, lane, key, started.marker) ?: return@ordinary Retire.Changed
            if (!expected.matches(old.revision, old.rows.first())) return@ordinary Retire.Changed
            requireStart(names, lane, markerKey, old, started)
            requireOriginal()
            val successor = if (old.rows.size == 1) {
                requireRecord(names, keys, old, start = started.marker)
                requireOriginal()
                Files.delete(names.record)
                requireRecord(names, keys, null, start = started.marker)
                syncDirectory(names.epoch)
                null
            } else {
                publish(names, keys, lane, key, old.rows.drop(1), old, ::requireOriginal, start = started.marker)
            }
            // Keep the start veto until the original ciphertext is durably gone or replaced.
            requireRecord(names, keys, successor, start = started.marker)
            requireStart(names, lane, markerKey, old, started)
            requireOriginal()
            Files.delete(names.start)
            syncDirectory(names.epoch)
            requireRecord(names, keys, successor)
            Retire.Retired
        }
    }

    fun captureRestoreAbsence(
        owner: SessionOwnerSnapshot.Account,
        reservation: AccountFileRestoreManagerExclusion.Reservation,
    ): RestoreAbsence? = guarded(null) {
        if (!AccountFileProviderWriters.isCurrent(reservation)) return@guarded null
        val first = observeEmpty(owner) ?: return@guarded null
        if (observeEmpty(owner) != first || !AccountFileProviderWriters.isCurrent(reservation)) return@guarded null
        RestoreAbsence(issuer, owner, reservation, first)
    }

    /** Final existing-only worker recheck. No data key, file payload, creation, or cleanup. */
    fun recheckExisting(owner: SessionOwnerSnapshot.Account, expected: RestoreAbsence): RestoreCurrency? = guarded(null) {
        if (!expected.isCurrent(issuer, owner)) return@guarded null
        val first = observeEmpty(owner) ?: return@guarded null
        if (observeEmpty(owner) != first) return@guarded null
        expected.verify(issuer, owner, first)
    }

    /** A scalar currency check after final physical revalidation, under the held reservation. */
    fun isCurrent(owner: SessionOwnerSnapshot.Account, verified: RestoreCurrency): Boolean =
        verified.isCurrent(issuer, owner)

    private data class Paths(val account: Path, val epoch: Path, val record: Path, val stage: Path, val retirement: Path, val start: Path)
    private data class AppIdentity(val uid: Int, val gid: Int)
    internal data class UnixMetadata(val uid: Int, val gid: Int, val mode: Int)
    private data class Node(val identity: Any, val modified: FileTime, val size: Long)
    private data class EmptyTree(val prefix: List<Any>, val account: Node?, val epochs: Map<String, Node>)
    private data class Record(val node: Node, val revision: String, val rows: List<Row>)

    private fun accountDirectory(accountId: String): Path {
        requireCanonicalAccount(accountId)
        return root.resolve(digest(accountId.toByteArray(Charsets.US_ASCII)))
    }

    private fun paths(lane: Lane): Paths {
        val account = accountDirectory(lane.owner.id)
        val epoch = account.resolve("e-${lane.owner.generation}")
        val name = lane.provider.fileName
        return Paths(account, epoch, epoch.resolve(name), epoch.resolve("$name.stage"), epoch.resolve("$name.retire"), epoch.resolve("$name.start"))
    }

    private fun node(path: Path, directory: Boolean, platformDirectory: Boolean = false): Node? {
        val attrs = try { Files.readAttributes(path, PosixFileAttributes::class.java, LinkOption.NOFOLLOW_LINKS) }
        catch (_: NoSuchFileException) { return null }
        check(if (directory) attrs.isDirectory else attrs.isRegularFile)
        val metadata = unixMetadata(path)
        val owner = appIdentity()
        check(metadata.uid == owner.uid)
        if (platformDirectory) {
            check(directory && (metadata.mode and OTHER_WRITE) == 0)
            check((metadata.mode and GROUP_WRITE) == 0 || metadata.gid == owner.gid)
        } else {
            check((metadata.mode and PERMISSION_BITS) == if (directory) DIRECTORY_MODE else FILE_MODE)
        }
        return Node(checkNotNull(attrs.fileKey()), attrs.lastModifiedTime(), attrs.size())
    }

    private fun namespace(names: Paths, create: Boolean): List<Any>? {
        val keys = mutableListOf(checkNotNull(node(appRoot, directory = true, platformDirectory = true)).identity)
        for (path in listOf(noBackup, root, names.account, names.epoch)) {
            requireUnambiguousName(path)
            var info = node(path, directory = true, platformDirectory = path == noBackup)
            if (info == null) {
                if (!create) return null
                Files.createDirectory(path, PRIVATE_DIRECTORY)
                info = checkNotNull(node(path, directory = true, platformDirectory = path == noBackup))
            }
            keys.add(info.identity)
        }
        return keys
    }

    private fun observeEmpty(owner: SessionOwnerSnapshot.Account): EmptyTree? {
        require(owner.generation > 0)
        val account = accountDirectory(owner.id)
        val prefix = mutableListOf(checkNotNull(node(appRoot, directory = true, platformDirectory = true)).identity)
        for (path in listOf(noBackup, root)) {
            requireUnambiguousName(path)
            val info = node(path, directory = true, platformDirectory = path == noBackup)
                ?: return EmptyTree(prefix, null, emptyMap())
            prefix.add(info.identity)
        }
        requireUnambiguousName(account)
        val accountNode = node(account, directory = true) ?: return EmptyTree(prefix, null, emptyMap())
        val epochs = linkedMapOf<String, Node>()
        Files.newDirectoryStream(account).use { entries ->
            for (epoch in entries) {
                if (epochs.size == EPOCH_SCAN_CAP) return null
                val name = epoch.fileName.toString()
                val number = name.removePrefix("e-").toLongOrNull()
                if (number == null || number <= 0 || name != "e-$number") return null
                val info = node(epoch, directory = true) ?: return null
                Files.newDirectoryStream(epoch).use { if (it.iterator().hasNext()) return null }
                if (node(epoch, directory = true) != info) return null
                epochs[name] = info
            }
        }
        if (node(account, directory = true) != accountNode) return null
        return EmptyTree(prefix, accountNode, epochs)
    }

    /** Observe names only at shared ancestors. Never traverse a foreign account's directory. */
    private fun requireUnambiguousName(path: Path) {
        val exact = path.fileName.toString()
        Files.newDirectoryStream(path.parent).use { entries ->
            var count = 0
            for (entry in entries) {
                check(++count <= PARENT_SCAN_CAP)
                val name = entry.fileName.toString()
                if (name == exact) continue
                val folded = name.lowercase(java.util.Locale.ROOT)
                check(folded != exact && !folded.startsWith("$exact.") && !folded.startsWith("$exact-") &&
                    (path != root || !folded.startsWith(ROOT_FAMILY_PREFIX)))
            }
        }
    }

    private fun checkedLane(names: Paths, keys: List<Any>, requireNoStage: Boolean = true, start: Node? = null) {
        check(namespace(names, create = false) == keys)
        Files.newDirectoryStream(names.epoch).use { entries ->
            var count = 0
            for (entry in entries) {
                check(++count <= VALID_LEAVES.size && entry.fileName.toString() in VALID_LEAVES)
            }
        }
        if (requireNoStage) check(node(names.stage, directory = false) == null)
        check(node(names.retirement, directory = false) == null)
        check(node(names.start, directory = false) == start)
    }

    private fun readRecord(names: Paths, keys: List<Any>, lane: Lane, key: SecretKeySpec, start: Node? = null): Record? {
        checkedLane(names, keys, start = start)
        val info = node(names.record, directory = false) ?: return null
        val sealed = readSealed(names.record, info)
        val rows = decode(lane, key, sealed)
        checkedLane(names, keys, start = start)
        check(node(names.record, directory = false) == info)
        return Record(info, digest(sealed), rows)
    }

    private fun readSealed(path: Path, info: Node): ByteArray {
        check(info.size in (NONCE_BYTES + TAG_BYTES + HEADER_BYTES + ROW_MIN_BYTES).toLong()..MAX_SEALED.toLong())
        val buffer = ByteBuffer.allocate(info.size.toInt())
        FileChannel.open(path, StandardOpenOption.READ, LinkOption.NOFOLLOW_LINKS).use { channel ->
            check(channel.size() == info.size)
            while (buffer.hasRemaining()) check(channel.read(buffer) > 0)
            check(channel.read(ByteBuffer.allocate(1)) == -1)
        }
        check(node(path, directory = false) == info)
        return buffer.array()
    }

    private fun requireRecord(
        names: Paths, keys: List<Any>, old: Record?, requireNoStage: Boolean = true, start: Node? = null,
    ) {
        checkedLane(names, keys, requireNoStage, start)
        val node = node(names.record, directory = false)
        check(node == old?.node)
        if (node != null) check(digest(readSealed(names.record, node)) == checkNotNull(old).revision)
    }

    private fun startPayload(old: Record): ByteArray = ByteBuffer.allocate(START_PLAIN_BYTES).apply {
        putInt(START_FORMAT)
        val id = old.rows.first().operationId
        putLong(id.mostSignificantBits)
        putLong(id.leastSignificantBits)
        put(old.revision.toByteArray(Charsets.US_ASCII))
        check(!hasRemaining())
    }.array()

    private fun requireStart(names: Paths, lane: Lane, key: SecretKeySpec, old: Record, started: StartedHead) {
        val marker = checkNotNull(node(names.start, directory = false))
        check(marker == started.marker && marker.size == START_SEALED_BYTES.toLong())
        val sealed = readSealed(names.start, marker)
        check(digest(sealed) == started.markerRevision)
        val plaintext = open(key, startAad(lane), sealed)
        val expected = startPayload(old)
        try { check(MessageDigest.isEqual(plaintext, expected)) }
        finally { plaintext.fill(0); expected.fill(0) }
    }

    private fun forceParents(names: Paths) {
        for (path in listOf(appRoot, noBackup, root, names.account)) syncDirectory(path)
    }

    private fun requireDurable(names: Paths, keys: List<Any>, record: Record, requireCurrent: () -> Unit) {
        requireRecord(names, keys, record)
        requireCurrent()
        // A previous publication may have moved the record before its directory force failed.
        forceParents(names)
        syncDirectory(names.epoch)
        requireRecord(names, keys, record)
    }

    private fun publish(
        names: Paths, keys: List<Any>, lane: Lane, key: SecretKeySpec, rows: List<Row>, old: Record?,
        requireCurrent: () -> Unit, start: Node? = null,
    ): Record {
        val sealed = encode(lane, key, rows)
        val revision = digest(sealed)
        requireRecord(names, keys, old, start = start)
        requireCurrent()
        forceParents(names)
        requireRecord(names, keys, old, start = start)
        requireCurrent()
        writePrivate(names.stage, sealed)
        val stage = checkNotNull(node(names.stage, directory = false))
        check(digest(readSealed(names.stage, stage)) == revision)
        requireRecord(names, keys, old, requireNoStage = false, start = start)
        requireCurrent()
        check(node(names.stage, directory = false) == stage)
        if (old == null) {
            Files.createLink(names.record, names.stage)
            Files.delete(names.stage)
        } else {
            Files.move(names.stage, names.record, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
        }
        syncDirectory(names.epoch)
        val observed = checkNotNull(readRecord(names, keys, lane, key, start))
        check(observed.revision == revision && observed.rows.size == rows.size && observed.rows.zip(rows).all { (a, b) -> a.same(b) })
        return observed
    }

    private fun writePrivate(path: Path, sealed: ByteArray) {
        FileChannel.open(path, setOf(StandardOpenOption.CREATE_NEW, StandardOpenOption.WRITE,
            LinkOption.NOFOLLOW_LINKS), PRIVATE_FILE).use { channel ->
            val bytes = ByteBuffer.wrap(sealed)
            while (bytes.hasRemaining()) check(channel.write(bytes) > 0)
            channel.force(true)
        }
    }

    private fun encode(lane: Lane, key: SecretKeySpec, rows: List<Row>): ByteArray {
        check(rows.size in 1..ROW_CAP)
        val plaintext = ByteBuffer.allocate(HEADER_BYTES + rows.sumOf(Row::encodedSize)).apply {
            putInt(FORMAT)
            putInt(rows.size)
            rows.forEach { it.encode(this) }
        }.array()
        return try { seal(key, aad(lane), plaintext) } finally { plaintext.fill(0) }
    }

    private fun decode(lane: Lane, key: SecretKeySpec, sealed: ByteArray): List<Row> {
        val plaintext = open(key, aad(lane), sealed)
        try {
            val input = ByteBuffer.wrap(plaintext)
            check(input.int == FORMAT)
            val count = input.int
            check(count in 1..ROW_CAP)
            val seen = hashSetOf<UUID>()
            val rows = List(count) {
                val id = UUID(input.long, input.long)
                check(seen.add(id))
                val add = when (input.get().toInt()) { 0 -> false; 1 -> true; else -> error("Invalid operation") }
                check(lane.provider != Provider.SIMKL || add)
                val series = when (input.get().toInt()) { 0 -> null; 1 -> false; 2 -> true; else -> error("Invalid media type") }
                val tmdb = input.int.takeUnless { it == 0 }
                val length = input.get().toInt()
                check(length in 0..IMDB_MAX_BYTES)
                val imdbBytes = ByteArray(length)
                input.get(imdbBytes)
                val imdb = imdbBytes.takeIf { it.isNotEmpty() }?.toString(Charsets.US_ASCII)
                val proof = ByteArray(PROOF_BYTES)
                input.get(proof)
                try { Row(id, add, imdb, tmdb, series, proof) } finally { proof.fill(0) }
            }
            check(!input.hasRemaining())
            return rows
        } finally {
            plaintext.fill(0)
        }
    }

    private fun syncDirectory(path: Path) {
        beforeDirectoryForce(path)
        FileChannel.open(path, StandardOpenOption.READ, LinkOption.NOFOLLOW_LINKS).use { it.force(true) }
    }

    private fun <T> ordinary(unavailable: T, requireCurrent: () -> Unit, work: () -> T): T =
        AccountFileProviderWriters.withWriter(unavailable) {
            guarded(unavailable) {
                requireCurrent()
                work().also { requireCurrent() }
            }
        }

    private fun <T> guarded(unavailable: T, work: () -> T): T = synchronized(PROCESS_LOCK) {
        try { work() }
        catch (cancelled: CancellationException) { throw cancelled }
        catch (_: Exception) { unavailable }
    }

    companion object {
        private const val DOMAIN = "vortx-android-provider-retry-outbox-v1"
        private const val CIPHER = "AES/GCM/NoPadding"
        private const val FORMAT = 0x56505231 // VPR1
        private const val START_FORMAT = 0x56505331 // VPS1
        private const val START_PLAIN_BYTES = 4 + 16 + 64
        private const val HEADER_BYTES = 8
        private const val PROOF_BYTES = 32
        private const val NONCE_BYTES = 12
        private const val TAG_BYTES = 16
        private const val START_SEALED_BYTES = NONCE_BYTES + TAG_BYTES + START_PLAIN_BYTES
        private const val IMDB_MAX_BYTES = 32
        private const val ROW_MIN_BYTES = 16 + 1 + 1 + 4 + 1 + PROOF_BYTES
        private const val ROW_CAP = 200
        private const val EPOCH_SCAN_CAP = 256
        private const val PARENT_SCAN_CAP = 4096
        private const val ROOT_FAMILY_PREFIX = "vortx-provider-retries-"
        private const val MAX_SEALED = NONCE_BYTES + TAG_BYTES + HEADER_BYTES + ROW_CAP * (ROW_MIN_BYTES + IMDB_MAX_BYTES)
        private const val PERMISSION_BITS = 0b111_111_111_111
        private const val DIRECTORY_MODE = 0b111_000_000
        private const val FILE_MODE = 0b110_000_000
        private const val GROUP_WRITE = 0b000_010_000
        private const val OTHER_WRITE = 0b000_000_010
        private val PRIVATE_DIRECTORY = PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rwx------"))
        private val PRIVATE_FILE = PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rw-------"))
        private val IMDB = Regex("tt[0-9]{1,30}")
        private val VALID_LEAVES = Provider.entries.flatMap {
            listOf(it.fileName, "${it.fileName}.stage", "${it.fileName}.retire", "${it.fileName}.start")
        }.toSet()
        private val PROCESS_LOCK = Any()

        internal fun forJvmFixture(
            appDirectory: Path, uid: Int, gid: Int, metadata: (Path) -> UnixMetadata, beforeDirectoryForce: (Path) -> Unit = {},
        ): ProviderRetryOutbox = ProviderRetryOutbox(appDirectory, { AppIdentity(uid, gid) }, metadata, beforeDirectoryForce)

        private fun requireCanonicalAccount(id: String) {
            require(UUID.fromString(id).toString() == id)
        }

        private fun aad(lane: Lane): ByteArray =
            "$DOMAIN\u0000${lane.owner.id}\u0000${lane.owner.generation}\u0000${lane.provider.fileName}".toByteArray(Charsets.US_ASCII)

        private fun startAad(lane: Lane): ByteArray = "$DOMAIN/start\u0000".toByteArray(Charsets.US_ASCII) + aad(lane)

        private fun seal(key: SecretKeySpec, aad: ByteArray, plaintext: ByteArray): ByteArray {
            val cipher = Cipher.getInstance(CIPHER)
            cipher.init(Cipher.ENCRYPT_MODE, key)
            check(cipher.iv.size == NONCE_BYTES)
            cipher.updateAAD(aad)
            return cipher.iv + cipher.doFinal(plaintext)
        }

        private fun open(key: SecretKeySpec, aad: ByteArray, sealed: ByteArray): ByteArray {
            val cipher = Cipher.getInstance(CIPHER)
            cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(TAG_BYTES * 8, sealed, 0, NONCE_BYTES))
            cipher.updateAAD(aad)
            return cipher.doFinal(sealed, NONCE_BYTES, sealed.size - NONCE_BYTES)
        }

        private fun digest(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes)
            .joinToString("") { "%02x".format(java.util.Locale.ROOT, it.toInt() and 255) }

        private fun sealKey(dataKey: ByteArray, purpose: String = "seal"): SecretKeySpec {
            require(dataKey.size == 32)
            val mac = Mac.getInstance("HmacSHA256")
            mac.init(SecretKeySpec(dataKey, "HmacSHA256"))
            val derived = mac.doFinal("$DOMAIN/$purpose".toByteArray(Charsets.US_ASCII))
            return try { SecretKeySpec(derived, "AES") } finally { derived.fill(0) }
        }
    }
}
