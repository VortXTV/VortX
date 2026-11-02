package com.vortx.android.backup.accountfiles

import android.content.ContentResolver
import android.content.Context
import android.database.Cursor
import android.net.Uri
import android.os.Looper
import android.provider.DocumentsContract
import com.vortx.android.sync.AccountBackupFile
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.withContext
import java.io.InputStream
import java.io.OutputStream
import java.security.MessageDigest
import java.util.Locale
import java.util.UUID

internal enum class AccountBackupCopyKind { ACCOUNT, REPAIRED }

internal enum class AccountBackupDocumentReason {
    EMPTY, TOO_LARGE, INVALID_BACKUP, UNSAFE_DOCUMENT, TOO_MANY_DOCUMENTS,
    VERIFICATION_FAILED, UNAVAILABLE, OPERATION_CHANGED, CLEARED,
}

/** Fixed product text only: provider exceptions, document names and URIs never become messages. */
internal class AccountBackupDocumentFailure(
    val reason: AccountBackupDocumentReason,
    val newCopyMayRemain: Boolean = false,
) : Exception(when (reason) {
    AccountBackupDocumentReason.EMPTY -> "Choose a nonempty account backup."
    AccountBackupDocumentReason.TOO_LARGE -> "This backup exceeds the 10 MiB account file limit."
    AccountBackupDocumentReason.INVALID_BACKUP -> "Choose a supported encrypted VortX account backup."
    AccountBackupDocumentReason.UNSAFE_DOCUMENT -> "This document provider could not create a safely separate account copy."
    AccountBackupDocumentReason.TOO_MANY_DOCUMENTS -> "Choose a folder with fewer documents for this account copy."
    AccountBackupDocumentReason.VERIFICATION_FAILED -> "The new account copy could not be verified."
    AccountBackupDocumentReason.UNAVAILABLE -> "The account file could not be read or saved. Try again with an available document provider."
    AccountBackupDocumentReason.OPERATION_CHANGED -> "This account file operation is no longer current."
    AccountBackupDocumentReason.CLEARED -> "Open the account backup again before saving a copy."
} + if (newCopyMayRemain) " A new copy may remain in the selected folder." else "")

/** Exact encrypted file bytes; never a plaintext restore or settings backup. */
internal class AccountBackupBytes internal constructor(
    bytes: ByteArray,
    internal val source: AccountDocumentHandle? = null,
    internal val sourceIdentity: AccountDocumentIdentity? = null,
) : AutoCloseable {
    private val bytes = bytes.copyOf()
    private var closed = false
    val byteCount: Int = bytes.size
    val sha256: String = accountDocumentDigest(bytes)

    @Synchronized fun copyBytes(): ByteArray {
        if (closed) documentFailure(AccountBackupDocumentReason.CLEARED)
        return bytes.copyOf()
    }

    @Synchronized override fun close() {
        bytes.fill(0)
        closed = true
    }

    override fun toString() = "AccountBackupBytes"
}

/** Immutable proof of a closed writer followed by a matching provider readback, and nothing stronger. */
internal class AccountBackupSaveReceipt internal constructor(
    internal val document: AccountDocumentHandle,
    val displayName: String,
    val byteCount: Int,
    val sha256: String,
) {
    val providerReadbackOnly: Boolean get() = true
    fun documentUri(): Uri = Uri.parse(document.value)
    override fun toString() = "AccountBackupSaveReceipt"
}

/**
 * Keep the controller's operation slot until these suspend calls actually return or throw. A blocking
 * provider may ignore cancellation, finish a write physically, or never return. No detached worker or
 * timeout releases that slot. The original Job and isCurrent fence still govern every publication.
 */
internal class AccountBackupDocuments internal constructor(private val core: AccountBackupDocumentCore) {
    constructor(context: Context) : this(AccountBackupDocumentCore(AndroidAccountDocumentProvider(context.applicationContext)))

    suspend fun prepare(bytes: ByteArray, isCurrent: () -> Boolean): AccountBackupBytes =
        ownedProviderWork(isCurrent) { check -> core.prepare(bytes, check) }

    suspend fun read(source: Uri, isCurrent: () -> Boolean): AccountBackupBytes =
        ownedProviderWork(isCurrent) { check -> core.read(AccountDocumentHandle(source.toString()), check) }

    suspend fun saveNewCopy(
        destinationTree: Uri,
        backup: AccountBackupBytes,
        kind: AccountBackupCopyKind = AccountBackupCopyKind.ACCOUNT,
        originalSource: Uri? = null,
        isCurrent: () -> Boolean,
    ): AccountBackupSaveReceipt = saveNewCopy(AccountDocumentHandle(destinationTree.toString()), backup, kind,
        originalSource?.let { AccountDocumentHandle(it.toString()) }, isCurrent)

    /** Same owned blocking path, with opaque synthetic handles for focused no-provider tests. */
    internal suspend fun saveNewCopy(
        destinationTree: AccountDocumentHandle,
        backup: AccountBackupBytes,
        kind: AccountBackupCopyKind = AccountBackupCopyKind.ACCOUNT,
        originalSource: AccountDocumentHandle? = null,
        isCurrent: () -> Boolean,
    ): AccountBackupSaveReceipt = ownedProviderWork(isCurrent) { check ->
        core.saveNewCopy(destinationTree, backup, kind, originalSource, check)
    }

    private suspend fun <T> ownedProviderWork(isCurrent: () -> Boolean, work: (() -> Unit) -> T): T {
        val originalJob = currentCoroutineContext()[Job]
        // A cancellation on dispatcher handoff can discard the return value after allocation.
        var completedResult: Any? = null
        try {
            return withContext(Dispatchers.IO + NonCancellable) {
                val check = {
                    val current = try { isCurrent() } catch (_: Exception) { false }
                    if (originalJob?.isActive == false || !current) {
                        documentFailure(AccountBackupDocumentReason.OPERATION_CHANGED)
                    }
                }
                check()
                val result = work(check)
                completedResult = result
                check() // Final operation fence before transferring ownership to the caller.
                result
            }
        } catch (failure: Throwable) {
            (completedResult as? AccountBackupBytes)?.close()
            if (completedResult is AccountBackupSaveReceipt && failure is AccountBackupDocumentFailure) {
                throw AccountBackupDocumentFailure(failure.reason, newCopyMayRemain = true)
            }
            throw failure
        }
    }
}

/** Opaque provider locator. Neither its diagnostic text nor exception text exposes a raw URI. */
internal class AccountDocumentHandle(internal val value: String) {
    override fun equals(other: Any?) = other is AccountDocumentHandle && value == other.value
    override fun hashCode() = value.hashCode()
    override fun toString() = "AccountDocumentHandle"
}

internal data class AccountDocumentIdentity(val authority: String, val id: String) {
    override fun toString() = "AccountDocumentIdentity"
}

internal data class AccountDocumentMetadata(
    val identity: AccountDocumentIdentity,
    val name: String,
    val mime: String,
    val size: Long?,
    val flags: Int,
    val lastModified: Long?,
) {
    override fun toString() = "AccountDocumentMetadata"
}

/** Blocking operations only. The core is syntheticable without Android provider or filesystem work. */
internal interface AccountDocumentProvider {
    fun treeRoot(tree: AccountDocumentHandle): AccountDocumentHandle
    fun metadata(document: AccountDocumentHandle): AccountDocumentMetadata
    fun children(root: AccountDocumentHandle): List<AccountDocumentMetadata>
    fun isChild(root: AccountDocumentHandle, document: AccountDocumentHandle): Boolean
    fun create(root: AccountDocumentHandle, name: String): AccountDocumentHandle
    fun openRead(document: AccountDocumentHandle): InputStream
    fun openNewOutput(document: AccountDocumentHandle): OutputStream
    fun delete(document: AccountDocumentHandle): Boolean
}

internal class AccountBackupDocumentCore(
    private val provider: AccountDocumentProvider,
    private val allocateReadBytes: (Int) -> ByteArray = { ByteArray(it) },
    private val randomSuffix: () -> String = { UUID.randomUUID().toString().replace("-", "") },
) {
    companion object {
        const val MAXIMUM_BYTES = 10 * 1024 * 1024
        const val MAXIMUM_CHILDREN = 2048
        const val MAXIMUM_METADATA_TEXT = 1024 * 1024
        const val MAXIMUM_ID_CHARS = 4096
        const val MAXIMUM_NAME_CHARS = 1024
        const val JSON_MIME = "application/json"
    }

    fun prepare(bytes: ByteArray, check: () -> Unit): AccountBackupBytes = sanitised {
        check()
        if (bytes.isEmpty()) documentFailure(AccountBackupDocumentReason.EMPTY)
        if (bytes.size > MAXIMUM_BYTES) documentFailure(AccountBackupDocumentReason.TOO_LARGE)
        val snapshot = bytes.copyOf()
        try {
            try { AccountBackupFile.inspect(snapshot) }
            catch (_: AccountBackupFile.Failure) { documentFailure(AccountBackupDocumentReason.INVALID_BACKUP) }
            check()
            AccountBackupBytes(snapshot)
        } finally { snapshot.fill(0) }
    }

    fun read(source: AccountDocumentHandle, check: () -> Unit): AccountBackupBytes = sanitised {
        check() // Before provider metadata or a stream can be opened.
        val before = provider.metadata(source).also(::validateMetadata)
        if (!before.name.lowercase(Locale.ROOT).endsWith(".json") || before.mime == DocumentsContract.Document.MIME_TYPE_DIR) {
            documentFailure(AccountBackupDocumentReason.INVALID_BACKUP)
        }
        if (before.size == 0L) documentFailure(AccountBackupDocumentReason.EMPTY)
        if ((before.size ?: 0) > MAXIMUM_BYTES) documentFailure(AccountBackupDocumentReason.TOO_LARGE)
        check()
        val bytes = readOwned(source, MAXIMUM_BYTES, check)
        try {
            check()
            val after = provider.metadata(source).also(::validateMetadata)
            if (before != after || (after.size != null && after.size != bytes.size.toLong())) {
                documentFailure(AccountBackupDocumentReason.VERIFICATION_FAILED)
            }
            prepare(bytes, check).use { inspected ->
                val exact = inspected.copyBytes()
                try {
                    check()
                    AccountBackupBytes(exact, source, before.identity)
                } finally { exact.fill(0) }
            }
        } finally { bytes.fill(0) }
    }

    fun saveNewCopy(
        tree: AccountDocumentHandle,
        backup: AccountBackupBytes,
        kind: AccountBackupCopyKind,
        originalSource: AccountDocumentHandle? = null,
        check: () -> Unit,
    ): AccountBackupSaveReceipt {
        var created: AccountDocumentHandle? = null
        var emptyProof: EmptyProof? = null
        var outputAttempted = false
        var workingBytes: ByteArray? = null
        try {
            check()
            val bytes = backup.copyBytes().also { workingBytes = it }
            if (bytes.isEmpty() || bytes.size > MAXIMUM_BYTES || accountDocumentDigest(bytes) != backup.sha256) {
                documentFailure(AccountBackupDocumentReason.INVALID_BACKUP)
            }
            val protected = mutableSetOf<AccountDocumentIdentity>()
            backup.sourceIdentity?.let(protected::add)
            listOfNotNull(backup.source, originalSource).distinct().forEach { source ->
                check()
                protected += provider.metadata(source).also(::validateMetadata).identity
            }
            val root = provider.treeRoot(tree)
            val rootMetadata = provider.metadata(root).also(::validateMetadata)
            if (rootMetadata.mime != DocumentsContract.Document.MIME_TYPE_DIR ||
                rootMetadata.flags and DocumentsContract.Document.FLAG_DIR_SUPPORTS_CREATE == 0) {
                documentFailure(AccountBackupDocumentReason.UNSAFE_DOCUMENT)
            }
            val before = snapshot(root)
            val suffix = randomSuffix()
            if (!Regex("^[a-f0-9]{32}$").matches(suffix)) documentFailure(AccountBackupDocumentReason.UNSAFE_DOCUMENT)
            val name = "vortx-account-${if (kind == AccountBackupCopyKind.REPAIRED) "repaired-" else ""}$suffix.json"
            if (before.any { it.name.equals(name, ignoreCase = true) }) documentFailure(AccountBackupDocumentReason.UNSAFE_DOCUMENT)
            check() // Last operation fence before createDocument can change the selected tree.
            val candidate = provider.create(root, name).also { created = it }
            val observed = requireNewEmpty(root, rootMetadata, candidate, name, before, protected, check)
            emptyProof = EmptyProof(root, candidate, observed)
            check()
            // Repeat immediately before the possibly truncating open; provider races are still possible.
            if (provider.metadata(candidate) != observed) documentFailure(AccountBackupDocumentReason.UNSAFE_DOCUMENT)
            check() // A cancellation here must never open the new document for output.
            outputAttempted = true
            provider.openNewOutput(candidate).use { output ->
                var offset = 0
                while (offset < bytes.size) {
                    check()
                    val count = minOf(16 * 1024, bytes.size - offset)
                    output.write(bytes, offset, count)
                    offset += count
                }
                check()
                output.flush()
            } // Writer is closed before readback opens.
            check()
            val readback = try {
                readOwned(candidate, bytes.size, check)
            } catch (failure: AccountBackupDocumentFailure) {
                if (failure.reason == AccountBackupDocumentReason.TOO_LARGE) {
                    documentFailure(AccountBackupDocumentReason.VERIFICATION_FAILED)
                }
                throw failure
            }
            try {
                check()
                if (readback.size != bytes.size || accountDocumentDigest(readback) != backup.sha256) {
                    documentFailure(AccountBackupDocumentReason.VERIFICATION_FAILED)
                }
            } finally { readback.fill(0) }
            val after = provider.metadata(candidate).also(::validateMetadata)
            val listed = snapshot(root).singleOrNull { it.identity == observed.identity }
            if (after.identity != observed.identity || after.name != name || after.mime != JSON_MIME ||
                after.size != bytes.size.toLong() || listed != after || !provider.isChild(root, candidate)) {
                documentFailure(AccountBackupDocumentReason.VERIFICATION_FAILED)
            }
            check() // Original operation/account fence after closed-writer byte-length/SHA readback.
            return AccountBackupSaveReceipt(candidate, name, bytes.size, backup.sha256)
        } catch (failure: Exception) {
            // A written document is left intact: SAF has no atomic compare-and-delete ownership check.
            val removed = !outputAttempted && emptyProof?.let(::removeStillOwnedEmpty) == true
            val reason = (failure as? AccountBackupDocumentFailure)?.reason ?: AccountBackupDocumentReason.UNAVAILABLE
            throw AccountBackupDocumentFailure(reason, created != null && !removed)
        } finally { workingBytes?.fill(0) }
    }

    private data class EmptyProof(
        val root: AccountDocumentHandle,
        val document: AccountDocumentHandle,
        val metadata: AccountDocumentMetadata,
    )

    private fun requireNewEmpty(
        root: AccountDocumentHandle,
        rootMetadata: AccountDocumentMetadata,
        candidate: AccountDocumentHandle,
        name: String,
        before: List<AccountDocumentMetadata>,
        protected: Set<AccountDocumentIdentity>,
        check: () -> Unit,
    ): AccountDocumentMetadata {
        val observed = provider.metadata(candidate).also(::validateMetadata)
        if (observed.identity.authority != rootMetadata.identity.authority || observed.identity == rootMetadata.identity ||
            observed.identity in protected || before.any { it.identity == observed.identity } ||
            observed.name != name || observed.mime != JSON_MIME || observed.size != 0L ||
            observed.flags and DocumentsContract.Document.FLAG_SUPPORTS_WRITE == 0 || !provider.isChild(root, candidate) ||
            snapshot(root).singleOrNull { it.identity == observed.identity } != observed) {
            documentFailure(AccountBackupDocumentReason.UNSAFE_DOCUMENT)
        }
        // Empty metadata alone does not admit a preexisting nonempty stream.
        check()
        provider.openRead(candidate).use { if (it.read() != -1) documentFailure(AccountBackupDocumentReason.UNSAFE_DOCUMENT) }
        if (provider.metadata(candidate) != observed) documentFailure(AccountBackupDocumentReason.UNSAFE_DOCUMENT)
        return observed
    }

    private fun removeStillOwnedEmpty(proof: EmptyProof): Boolean = try {
        val expected = proof.metadata
        // A timestamp is only an observation, never an atomic change token; absent values fail closed.
        if (expected.lastModified == null || expected.flags and DocumentsContract.Document.FLAG_SUPPORTS_DELETE == 0 ||
            provider.metadata(proof.document) != expected || !provider.isChild(proof.root, proof.document) ||
            snapshot(proof.root).singleOrNull { it.identity == expected.identity } != expected) false
        else {
            val empty = provider.openRead(proof.document).use { it.read() == -1 }
            empty && provider.metadata(proof.document) == expected && provider.delete(proof.document)
        }
    } catch (_: Exception) { false }

    private fun snapshot(root: AccountDocumentHandle): List<AccountDocumentMetadata> {
        val children = provider.children(root)
        if (children.size > MAXIMUM_CHILDREN) documentFailure(AccountBackupDocumentReason.TOO_MANY_DOCUMENTS)
        var text = 0L
        val ids = HashSet<AccountDocumentIdentity>()
        val names = HashSet<String>()
        children.forEach {
            validateMetadata(it)
            text += 2L * (it.identity.id.length + it.identity.authority.length + it.name.length + it.mime.length)
            if (text > MAXIMUM_METADATA_TEXT || !ids.add(it.identity) || !names.add(it.name.lowercase(Locale.ROOT))) {
                documentFailure(AccountBackupDocumentReason.UNSAFE_DOCUMENT)
            }
        }
        return children.toList()
    }

    private fun validateMetadata(value: AccountDocumentMetadata) {
        if (value.identity.authority.isBlank() || value.identity.authority.length > 255 ||
            value.identity.id.isEmpty() || value.identity.id.length > MAXIMUM_ID_CHARS ||
            value.name.isEmpty() || value.name.length > MAXIMUM_NAME_CHARS ||
            value.mime.isEmpty() || value.mime.length > 255 || (value.size != null && value.size < 0) ||
            (value.lastModified != null && value.lastModified < 0)) documentFailure(AccountBackupDocumentReason.UNSAFE_DOCUMENT)
    }

    /** Retain a completed array across close: a provider close failure must not discard its owner. */
    private fun readOwned(document: AccountDocumentHandle, limit: Int, check: () -> Unit): ByteArray {
        var completed: ByteArray? = null
        var transferred = false
        try {
            provider.openRead(document).use { input -> completed = readBounded(input, limit, check) }
            val result = completed ?: documentFailure(AccountBackupDocumentReason.UNAVAILABLE)
            transferred = true
            return result
        } finally {
            if (!transferred) completed?.fill(0)
        }
    }

    /** Single bounded owned accumulator, no extra scratch copy; all storage is wiped on every exit. */
    private fun readBounded(input: InputStream, limit: Int, check: () -> Unit): ByteArray {
        val storage = allocateReadBytes(limit + 1)
        try {
            if (storage.size != limit + 1) documentFailure(AccountBackupDocumentReason.UNAVAILABLE)
            var used = 0
            while (true) {
                check()
                val count = input.read(storage, used, minOf(8192, storage.size - used))
                if (count < 0) return completedRead(storage, used)
                if (count == 0) {
                    val next = input.read()
                    if (next < 0) return completedRead(storage, used)
                    storage[used++] = next.toByte()
                } else used += count
                if (used > limit) documentFailure(AccountBackupDocumentReason.TOO_LARGE)
            }
        } finally { storage.fill(0) }
    }

    /** A distinct completed array is transferred only after the copy itself succeeds. */
    private fun completedRead(storage: ByteArray, used: Int): ByteArray {
        val result = allocateReadBytes(used)
        var transferred = false
        try {
            if (result.size != used) documentFailure(AccountBackupDocumentReason.UNAVAILABLE)
            storage.copyInto(result, endIndex = used)
            transferred = true
            return result
        } finally { if (!transferred) result.fill(0) }
    }

    private inline fun <T> sanitised(work: () -> T): T = try { work() }
    catch (failure: AccountBackupDocumentFailure) { throw failure }
    catch (_: Exception) { documentFailure(AccountBackupDocumentReason.UNAVAILABLE) }
}

/** Real SAF adapter. Limits bound admitted rows/strings/bytes, not an uncooperative provider's internals. */
private class AndroidAccountDocumentProvider(private val context: Context) : AccountDocumentProvider {
    private val resolver: ContentResolver = context.contentResolver
    private val projection = arrayOf(
        DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME,
        DocumentsContract.Document.COLUMN_MIME_TYPE, DocumentsContract.Document.COLUMN_SIZE,
        DocumentsContract.Document.COLUMN_FLAGS, DocumentsContract.Document.COLUMN_LAST_MODIFIED,
    )

    override fun treeRoot(tree: AccountDocumentHandle): AccountDocumentHandle {
        val uri = uri(tree)
        if (!DocumentsContract.isTreeUri(uri) || uri.pathSegments.size != 2) unsafe()
        val id = DocumentsContract.getTreeDocumentId(uri)
        if (id.isEmpty() || id.length > AccountBackupDocumentCore.MAXIMUM_ID_CHARS) unsafe()
        return AccountDocumentHandle(DocumentsContract.buildDocumentUriUsingTree(uri, id).toString())
    }

    override fun metadata(document: AccountDocumentHandle): AccountDocumentMetadata {
        val uri = documentUri(document)
        val expectedId = DocumentsContract.getDocumentId(uri)
        return resolver.query(uri, projection, null, null, null)?.use { cursor ->
            if (!cursor.moveToFirst()) unsafe()
            val value = metadata(cursor, uri.authority!!)
            if (value.identity.id != expectedId || cursor.moveToNext()) unsafe()
            value
        } ?: unavailable()
    }

    override fun children(root: AccountDocumentHandle): List<AccountDocumentMetadata> {
        val rootUri = documentUri(root)
        if (!DocumentsContract.isTreeUri(rootUri)) unsafe()
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(rootUri, DocumentsContract.getDocumentId(rootUri))
        return resolver.query(childrenUri, projection, null, null, null)?.use { cursor ->
            val result = ArrayList<AccountDocumentMetadata>()
            var text = 0L
            while (cursor.moveToNext()) {
                if (result.size == AccountBackupDocumentCore.MAXIMUM_CHILDREN) {
                    documentFailure(AccountBackupDocumentReason.TOO_MANY_DOCUMENTS)
                }
                val value = metadata(cursor, rootUri.authority!!)
                text += 2L * (value.identity.id.length + value.identity.authority.length + value.name.length + value.mime.length)
                if (text > AccountBackupDocumentCore.MAXIMUM_METADATA_TEXT) unsafe()
                result += value
            }
            result
        } ?: unavailable()
    }

    override fun isChild(root: AccountDocumentHandle, document: AccountDocumentHandle): Boolean {
        val parent = documentUri(root)
        val child = documentUri(document)
        return parent.authority == child.authority && DocumentsContract.isChildDocument(resolver, parent, child)
    }

    override fun create(root: AccountDocumentHandle, name: String): AccountDocumentHandle =
        AccountDocumentHandle((DocumentsContract.createDocument(resolver, documentUri(root),
            AccountBackupDocumentCore.JSON_MIME, name) ?: unavailable()).toString())

    override fun openRead(document: AccountDocumentHandle): InputStream =
        resolver.openInputStream(documentUri(document)) ?: unavailable()

    override fun openNewOutput(document: AccountDocumentHandle): OutputStream =
        resolver.openOutputStream(documentUri(document), "wt") ?: unavailable()

    override fun delete(document: AccountDocumentHandle): Boolean = DocumentsContract.deleteDocument(resolver, documentUri(document))

    private fun uri(handle: AccountDocumentHandle): Uri {
        if (Looper.myLooper() == Looper.getMainLooper()) unavailable()
        if (handle.value.length > 8192) unsafe()
        val uri = Uri.parse(handle.value)
        if (uri.scheme != "content" || uri.authority.isNullOrBlank() || uri.authority!!.length > 255 ||
            uri.query != null || uri.fragment != null) unsafe()
        return uri
    }

    private fun documentUri(handle: AccountDocumentHandle): Uri = uri(handle).also {
        if (!DocumentsContract.isDocumentUri(context, it)) unsafe()
        val id = DocumentsContract.getDocumentId(it)
        if (id.isEmpty() || id.length > AccountBackupDocumentCore.MAXIMUM_ID_CHARS) unsafe()
    }

    private fun metadata(cursor: Cursor, authority: String): AccountDocumentMetadata {
        fun text(column: String, maximum: Int): String {
            val index = cursor.getColumnIndexOrThrow(column)
            if (cursor.getType(index) != Cursor.FIELD_TYPE_STRING) unsafe()
            val value = if (cursor.isNull(index)) null else cursor.getString(index)
            if (value.isNullOrEmpty() || value.length > maximum) unsafe()
            return value
        }
        fun number(column: String): Long? {
            val index = cursor.getColumnIndexOrThrow(column)
            if (!cursor.isNull(index) && cursor.getType(index) != Cursor.FIELD_TYPE_INTEGER) unsafe()
            return if (cursor.isNull(index)) null else cursor.getLong(index)
        }
        val flags = number(DocumentsContract.Document.COLUMN_FLAGS) ?: unsafe()
        if (flags !in 0..Int.MAX_VALUE.toLong()) unsafe()
        return AccountDocumentMetadata(AccountDocumentIdentity(authority,
            text(DocumentsContract.Document.COLUMN_DOCUMENT_ID, AccountBackupDocumentCore.MAXIMUM_ID_CHARS)),
            text(DocumentsContract.Document.COLUMN_DISPLAY_NAME, AccountBackupDocumentCore.MAXIMUM_NAME_CHARS),
            text(DocumentsContract.Document.COLUMN_MIME_TYPE, 255), number(DocumentsContract.Document.COLUMN_SIZE),
            flags.toInt(), number(DocumentsContract.Document.COLUMN_LAST_MODIFIED))
    }

    private fun unsafe(): Nothing = documentFailure(AccountBackupDocumentReason.UNSAFE_DOCUMENT)
    private fun unavailable(): Nothing = documentFailure(AccountBackupDocumentReason.UNAVAILABLE)
}

private fun documentFailure(reason: AccountBackupDocumentReason): Nothing = throw AccountBackupDocumentFailure(reason)

private fun accountDocumentDigest(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes)
    .joinToString("") { (it.toInt() and 0xff).toString(16).padStart(2, '0') }
