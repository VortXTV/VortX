package com.vortx.android.backup.accountfiles

import android.provider.DocumentsContract
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.io.IOException
import java.io.OutputStream
import java.security.MessageDigest
import java.util.Base64
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Authored recovery proposal only. These tests have not been executed. No real SAF provider is used. */
class AccountBackupDocumentsTest {
    private val suffix = "0123456789abcdef0123456789abcdef"
    private val tree = AccountDocumentHandle("selected-tree")
    private val source = AccountDocumentHandle("selected-source")
    private val generatedName = "vortx-account-$suffix.json"
    private val fileFlags = DocumentsContract.Document.FLAG_SUPPORTS_WRITE or DocumentsContract.Document.FLAG_SUPPORTS_DELETE

    private fun accountBytes(): ByteArray {
        val encrypted = Base64.getEncoder().encodeToString(ByteArray(28) { it.toByte() })
        return (" {\r\n  \"future\": {\"keep\": 1.00}, \"vortxBackup\": 1,\r\n" +
            " \"username\": \"fixture-\u00e9\", \"document\": \"v2.$encrypted\", " +
            "\"version\": 9007199254740991\r\n}\n").toByteArray(Charsets.UTF_8)
    }

    private inner class FakeProvider : AccountDocumentProvider {
        inner class Entry(
            var metadata: AccountDocumentMetadata,
            var data: ByteArray = byteArrayOf(),
            var parent: String? = "root",
            var written: Boolean = false,
        )

        val entries = linkedMapOf<String, Entry>()
        var createResult = "new"
        var returnedName: String? = null
        var returnedIdentity: AccountDocumentIdentity? = null
        var returnedParent: String? = "root"
        var returnedBytes = byteArrayOf()
        var lieAboutEmptySize = false
        var returnedLastModified: Long? = 1
        var duplicateNames = false
        var duplicateIds = false
        var excessiveChildren = false
        var readbackOverride: ByteArray? = null
        var beforeWrite: (() -> Unit)? = null
        var afterOutputClose: (() -> Unit)? = null
        var afterReadbackClose: (() -> Unit)? = null
        var afterEmptyRead: (() -> Unit)? = null
        var afterSourceBulkRead: (() -> Unit)? = null
        var afterReadbackBulkRead: (() -> Unit)? = null
        var throwAfterSourceBulkRead = false
        var sourceCloseThrows = false
        var readbackCloseThrows = false
        var onCleanupObservation: (() -> Unit)? = null
        var createCount = 0
        var outputOpenCount = 0
        var outputClosed = false
        var sourceReadCount = 0
        val deleted = mutableListOf<String>()

        init {
            entries["root"] = Entry(meta("root", "chosen-folder", DocumentsContract.Document.MIME_TYPE_DIR, 0,
                DocumentsContract.Document.FLAG_DIR_SUPPORTS_CREATE), parent = null)
        }

        fun meta(id: String, name: String, mime: String = AccountBackupDocumentCore.JSON_MIME,
                 size: Long? = 0, flags: Int = fileFlags, modified: Long? = 1) =
            AccountDocumentMetadata(AccountDocumentIdentity("fixture.provider", id), name, mime, size, flags, modified)

        fun add(id: String, name: String, data: ByteArray = byteArrayOf(), parent: String? = "root", size: Long? = data.size.toLong()) {
            entries[id] = Entry(meta(id, name, size = size), data.copyOf(), parent)
        }

        override fun treeRoot(tree: AccountDocumentHandle) = AccountDocumentHandle("root")
        override fun metadata(document: AccountDocumentHandle): AccountDocumentMetadata {
            if (document.value == "new" && afterEmptyRead != null && !entries.getValue("new").written) {
                onCleanupObservation?.invoke()
            }
            return entries.getValue(document.value).metadata
        }

        override fun children(root: AccountDocumentHandle): List<AccountDocumentMetadata> {
            val result = entries.values.filter { it.parent == root.value }.map { it.metadata }.toMutableList()
            if (duplicateNames) result += meta("other-name-id", generatedName.uppercase())
            if (duplicateIds && result.isNotEmpty()) result += result.first().copy(name = "another-name.json")
            if (excessiveChildren) return List(AccountBackupDocumentCore.MAXIMUM_CHILDREN + 1) { meta("id-$it", "$it.json") }
            return result
        }

        override fun isChild(root: AccountDocumentHandle, document: AccountDocumentHandle) =
            entries.getValue(document.value).parent == root.value

        override fun create(root: AccountDocumentHandle, name: String): AccountDocumentHandle {
            createCount += 1
            if (!entries.containsKey(createResult)) {
                val actualSize = if (lieAboutEmptySize) 0 else returnedBytes.size.toLong()
                val metadata = meta(createResult, returnedName ?: name, size = actualSize, modified = returnedLastModified)
                entries[createResult] = Entry(metadata.copy(identity = returnedIdentity ?: metadata.identity),
                    returnedBytes.copyOf(), returnedParent)
            }
            return AccountDocumentHandle(createResult)
        }

        override fun openRead(document: AccountDocumentHandle): InputStream {
            val entry = entries.getValue(document.value)
            val data = if (entry.written) readbackOverride ?: entry.data else entry.data
            return object : ByteArrayInputStream(data) {
                override fun read(): Int = super.read().also { value ->
                    if (document == source && value >= 0) sourceReadCount += 1
                    if (document.value == "new" && !entry.written && value < 0) afterEmptyRead?.invoke()
                }
                override fun read(buffer: ByteArray, offset: Int, length: Int): Int = super.read(buffer, offset, length).also {
                    if (document == source && it > 0) {
                        sourceReadCount += it
                        afterSourceBulkRead?.invoke()
                        if (throwAfterSourceBulkRead) throw IOException("fixture provider read failure")
                    }
                    if (entry.written && it > 0) afterReadbackBulkRead?.invoke()
                }
                override fun close() {
                    super.close()
                    if (entry.written) afterReadbackClose?.invoke()
                    if ((document == source && sourceCloseThrows) || (entry.written && readbackCloseThrows)) {
                        throw IOException("fixture provider close failure")
                    }
                }
            }
        }

        override fun openNewOutput(document: AccountDocumentHandle): OutputStream {
            outputOpenCount += 1
            val entry = entries.getValue(document.value)
            return object : ByteArrayOutputStream() {
                override fun write(buffer: ByteArray, offset: Int, length: Int) {
                    beforeWrite?.invoke()
                    super.write(buffer, offset, length)
                }
                override fun close() {
                    super.close()
                    entry.data = toByteArray()
                    entry.written = true
                    entry.metadata = entry.metadata.copy(size = entry.data.size.toLong(), lastModified = 2)
                    outputClosed = true
                    afterOutputClose?.invoke()
                }
            }
        }

        override fun delete(document: AccountDocumentHandle): Boolean {
            deleted += document.value
            return entries.remove(document.value) != null
        }

        fun core() = AccountBackupDocumentCore(this) { suffix }
    }

    private fun failed(reason: AccountBackupDocumentReason, work: () -> Unit): AccountBackupDocumentFailure {
        try { work(); fail("A fixed account document failure was required") }
        catch (failure: AccountBackupDocumentFailure) {
            assertEquals(reason, failure.reason)
            return failure
        }
        throw AssertionError("unreachable")
    }

    private fun current(active: () -> Boolean): () -> Unit = {
        if (!active()) throw AccountBackupDocumentFailure(AccountBackupDocumentReason.OPERATION_CHANGED)
    }

    private fun trackedCore(provider: FakeProvider, allocations: MutableList<ByteArray>) = AccountBackupDocumentCore(
        provider,
        allocateReadBytes = { size -> ByteArray(size).also(allocations::add) },
        randomSuffix = { suffix },
    )

    private fun assertWiped(allocations: List<ByteArray>) {
        assertTrue("the actual bounded reader must allocate owned storage", allocations.isNotEmpty())
        allocations.forEach { bytes -> assertTrue("every mutable I/O-owned array must be wiped", bytes.all { it == 0.toByte() }) }
    }

    @Test fun successfulSourceAndVerificationReadsWipeEveryIoOwnedArray() {
        val provider = FakeProvider()
        provider.add("selected-source", "original.json", accountBytes(), parent = null)
        val allocations = mutableListOf<ByteArray>()
        val core = trackedCore(provider, allocations)
        core.read(source) {}.use { backup ->
            assertWiped(allocations)
            assertArrayEquals(accountBytes(), backup.copyBytes())
            val receipt = core.saveNewCopy(tree, backup, AccountBackupCopyKind.ACCOUNT, check = {})
            assertEquals(backup.sha256, receipt.sha256)
            assertWiped(allocations)
            assertArrayEquals(accountBytes(), provider.entries.getValue("new").data)
        }
        assertEquals(4, allocations.size) // Source accumulator/result, then readback accumulator/result.
    }

    @Test fun repairedCopyRetainsOriginalReadIdentityEvenIfProviderRebindsTheInputHandle() {
        val provider = FakeProvider()
        val original = accountBytes()
        provider.add("selected-source", "original.json", original, parent = null)
        val core = provider.core()
        core.read(source) {}.use { selected ->
            val observed = checkNotNull(selected.sourceIdentity)
            val existing = provider.entries.getValue("selected-source")
            existing.metadata = existing.metadata.copy(identity = AccountDocumentIdentity("fixture.provider", "rebound"))
            provider.returnedIdentity = observed
            core.prepareRepairedCopy(accountBytes(), selected) {}.use { repaired ->
                assertEquals(observed, repaired.sourceIdentity)
                failed(AccountBackupDocumentReason.UNSAFE_DOCUMENT) {
                    core.saveNewCopy(tree, repaired, AccountBackupCopyKind.REPAIRED, check = {})
                }
                assertEquals(0, provider.outputOpenCount); assertTrue(provider.deleted.isEmpty())
                assertArrayEquals(original, existing.data)
            }
        }
    }

    @Test fun repairedCopyUsesSeparateNameAndVerifiesExactEncryptedBytes() {
        val provider = FakeProvider()
        val original = accountBytes()
        provider.add("selected-source", "original.json", original, parent = null)
        val core = provider.core()
        val repairedBytes = (original.toString(Charsets.UTF_8) + "\n").toByteArray(Charsets.UTF_8)
        core.read(source) {}.use { selected ->
            core.prepareRepairedCopy(repairedBytes, selected) {}.use { repaired ->
                val receipt = core.saveNewCopy(tree, repaired, AccountBackupCopyKind.REPAIRED, check = {})
                assertEquals("vortx-account-repaired-$suffix.json", receipt.displayName)
                assertEquals(repaired.byteCount, receipt.byteCount)
                assertEquals(repaired.sha256, receipt.sha256)
                assertTrue(receipt.providerReadbackOnly)
                assertArrayEquals(repairedBytes, provider.entries.getValue("new").data)
                assertArrayEquals(original, provider.entries.getValue("selected-source").data)
            }
        }
    }

    @Test fun oversizedSourceReadWipesTheAccumulatedPrefix() {
        val provider = FakeProvider()
        provider.add("selected-source", "large.json", ByteArray(AccountBackupDocumentCore.MAXIMUM_BYTES + 1) { 7 },
            parent = null, size = null)
        val allocations = mutableListOf<ByteArray>()
        failed(AccountBackupDocumentReason.TOO_LARGE) { trackedCore(provider, allocations).read(source) {} }
        assertEquals(AccountBackupDocumentCore.MAXIMUM_BYTES + 1, provider.sourceReadCount)
        assertEquals(1, allocations.size)
        assertWiped(allocations)
    }

    @Test fun stalePartialSourceReadWipesTheAccumulatedPrefix() {
        val provider = FakeProvider()
        provider.add("selected-source", "original.json", accountBytes(), parent = null)
        var active = true
        provider.afterSourceBulkRead = { active = false }
        val allocations = mutableListOf<ByteArray>()
        failed(AccountBackupDocumentReason.OPERATION_CHANGED) {
            trackedCore(provider, allocations).read(source, current { active })
        }
        assertTrue(provider.sourceReadCount > 0)
        assertEquals(1, allocations.size)
        assertWiped(allocations)
        assertEquals(0, provider.createCount)
    }

    @Test fun providerFailureAfterCopyingIntoSourceBufferStillWipesThePartialBytes() {
        val provider = FakeProvider()
        provider.add("selected-source", "original.json", accountBytes(), parent = null)
        provider.throwAfterSourceBulkRead = true
        val allocations = mutableListOf<ByteArray>()
        val failure = failed(AccountBackupDocumentReason.UNAVAILABLE) { trackedCore(provider, allocations).read(source) {} }
        assertTrue(provider.sourceReadCount > 0)
        assertEquals(1, allocations.size)
        assertWiped(allocations)
        assertNull(failure.cause)
    }

    @Test fun sourceCloseFailureWipesTheCompletedArrayBeforeOwnershipCanBeLost() {
        val provider = FakeProvider()
        provider.add("selected-source", "original.json", accountBytes(), parent = null)
        provider.sourceCloseThrows = true
        val allocations = mutableListOf<ByteArray>()
        val failure = failed(AccountBackupDocumentReason.UNAVAILABLE) { trackedCore(provider, allocations).read(source) {} }
        assertEquals(2, allocations.size)
        assertEquals(accountBytes().size, allocations.last().size)
        assertWiped(allocations)
        assertNull(failure.cause)
        assertEquals(0, provider.createCount)
    }

    @Test fun verificationCloseFailureWipesTheCompletedArrayAndRefusesAReceipt() {
        val provider = FakeProvider().apply { readbackCloseThrows = true }
        val allocations = mutableListOf<ByteArray>()
        val core = trackedCore(provider, allocations)
        core.prepare(accountBytes()) {}.use { backup ->
            val failure = failed(AccountBackupDocumentReason.UNAVAILABLE) {
                core.saveNewCopy(tree, backup, AccountBackupCopyKind.ACCOUNT, check = {})
            }
            assertTrue(failure.newCopyMayRemain)
            assertNull(failure.cause)
        }
        assertEquals(2, allocations.size)
        assertEquals(accountBytes().size, allocations.last().size)
        assertWiped(allocations)
        assertTrue(provider.outputClosed)
        assertTrue(provider.deleted.isEmpty())
    }

    @Test fun oversizedVerificationReadWipesItsPrefixAndLeavesTheWrittenCopy() {
        val provider = FakeProvider().apply { readbackOverride = accountBytes() + byteArrayOf(7) }
        val allocations = mutableListOf<ByteArray>()
        val core = trackedCore(provider, allocations)
        core.prepare(accountBytes()) {}.use { backup ->
            val failure = failed(AccountBackupDocumentReason.VERIFICATION_FAILED) {
                core.saveNewCopy(tree, backup, AccountBackupCopyKind.ACCOUNT, check = {})
            }
            assertTrue(failure.newCopyMayRemain)
        }
        assertEquals(1, allocations.size)
        assertWiped(allocations)
        assertTrue(provider.deleted.isEmpty())
    }

    @Test fun stalePartialVerificationReadWipesItsPrefixAndNeverReturnsAReceipt() {
        val provider = FakeProvider()
        var active = true
        provider.afterReadbackBulkRead = { active = false }
        val allocations = mutableListOf<ByteArray>()
        val core = trackedCore(provider, allocations)
        core.prepare(accountBytes()) {}.use { backup ->
            val failure = failed(AccountBackupDocumentReason.OPERATION_CHANGED) {
                core.saveNewCopy(tree, backup, AccountBackupCopyKind.ACCOUNT, check = current { active })
            }
            assertTrue(failure.newCopyMayRemain)
        }
        assertEquals(1, allocations.size)
        assertWiped(allocations)
        assertTrue(provider.deleted.isEmpty())
    }

    @Test fun exactEncryptedInputAndOutputBytesRemainUnchanged() {
        val provider = FakeProvider()
        val bytes = accountBytes()
        provider.add("selected-source", "original.JSON", bytes, parent = null)
        provider.core().read(source) {}.use { backup ->
            assertArrayEquals(bytes, backup.copyBytes())
            val receipt = provider.core().saveNewCopy(tree, backup, AccountBackupCopyKind.ACCOUNT, check = {})
            assertArrayEquals(bytes, provider.entries.getValue("new").data)
            assertArrayEquals(bytes, provider.entries.getValue("selected-source").data)
            assertEquals(bytes.size, receipt.byteCount)
            assertEquals(sha256(bytes), receipt.sha256)
            assertEquals(generatedName, receipt.displayName)
            assertTrue(receipt.providerReadbackOnly)
            assertTrue(provider.outputClosed)
            assertTrue(provider.deleted.isEmpty())
        }
    }

    @Test fun preparationCopiesInputAndCloseIsIdempotent() {
        val provider = FakeProvider()
        val input = accountBytes()
        val expected = input.copyOf()
        val backup = provider.core().prepare(input) {}
        input.fill(0)
        val exposed = backup.copyBytes()
        exposed.fill(0)
        assertArrayEquals(expected, backup.copyBytes())
        backup.close()
        backup.close()
        failed(AccountBackupDocumentReason.CLEARED) { backup.copyBytes() }
        assertEquals(expected.size, backup.byteCount)
        assertEquals(sha256(expected), backup.sha256)
    }

    @Test fun emptyAndSettingsBackupInputsAreRefused() {
        val core = FakeProvider().core()
        failed(AccountBackupDocumentReason.EMPTY) { core.prepare(byteArrayOf()) {} }
        failed(AccountBackupDocumentReason.INVALID_BACKUP) {
            core.prepare("{\"format\":\"vortx-backup\",\"schema\":1}".toByteArray()) {}
        }
    }

    @Test fun unknownSizeInputStopsAtLimitPlusOneByte() {
        val provider = FakeProvider()
        provider.add("selected-source", "large.json", ByteArray(AccountBackupDocumentCore.MAXIMUM_BYTES + 64),
            parent = null, size = null)
        failed(AccountBackupDocumentReason.TOO_LARGE) { provider.core().read(source) {} }
        assertEquals(AccountBackupDocumentCore.MAXIMUM_BYTES + 1, provider.sourceReadCount)
        assertEquals(0, provider.createCount)
    }

    @Test fun advertisedOversizeInputIsRejectedBeforeStreamOpen() {
        val provider = FakeProvider()
        provider.add("selected-source", "large.json", size = AccountBackupDocumentCore.MAXIMUM_BYTES + 1L)
        failed(AccountBackupDocumentReason.TOO_LARGE) { provider.core().read(source) {} }
        assertEquals(0, provider.sourceReadCount)
    }

    @Test fun reusedOldIdIsNeverOpenedForOutputOrDeleted() {
        val provider = FakeProvider()
        provider.add("old", generatedName)
        provider.createResult = "old"
        provider.core().prepare(accountBytes()) {}.use { backup ->
            failed(AccountBackupDocumentReason.UNSAFE_DOCUMENT) {
                provider.core().saveNewCopy(tree, backup, AccountBackupCopyKind.ACCOUNT, check = {})
            }
        }
        assertEquals(0, provider.outputOpenCount)
        assertTrue(provider.deleted.isEmpty())
        assertTrue(provider.entries.containsKey("old"))
    }

    @Test fun reusedIdWithDifferentNameIsRejectedAfterCreate() {
        val provider = FakeProvider()
        provider.add("old", "previous.json")
        provider.createResult = "old"
        provider.core().prepare(accountBytes()) {}.use { backup ->
            failed(AccountBackupDocumentReason.UNSAFE_DOCUMENT) {
                provider.core().saveNewCopy(tree, backup, AccountBackupCopyKind.ACCOUNT, check = {})
            }
        }
        assertEquals(1, provider.createCount)
        assertEquals(0, provider.outputOpenCount)
        assertTrue(provider.deleted.isEmpty())
    }

    @Test fun returningSelectedSourceIdentityNeverTruncatesOrDeletesIt() {
        val provider = FakeProvider()
        val bytes = accountBytes()
        provider.add("selected-source", "original.json", bytes, parent = null)
        provider.createResult = "selected-source"
        provider.core().read(source) {}.use { backup ->
            failed(AccountBackupDocumentReason.UNSAFE_DOCUMENT) {
                provider.core().saveNewCopy(tree, backup, AccountBackupCopyKind.REPAIRED, check = {})
            }
        }
        assertArrayEquals(bytes, provider.entries.getValue("selected-source").data)
        assertEquals(0, provider.outputOpenCount)
        assertTrue(provider.deleted.isEmpty())
    }

    @Test fun separatelySuppliedOriginalIdentityIsAlsoProtected() {
        val provider = FakeProvider()
        provider.add("selected-source", "original.json", parent = null)
        provider.createResult = "selected-source"
        provider.core().prepare(accountBytes()) {}.use { backup ->
            failed(AccountBackupDocumentReason.UNSAFE_DOCUMENT) {
                provider.core().saveNewCopy(tree, backup, AccountBackupCopyKind.ACCOUNT, source, check = {})
            }
        }
        assertEquals(0, provider.outputOpenCount)
        assertTrue(provider.deleted.isEmpty())
    }

    @Test fun differentLocatorWithTheSourceDocumentIdIsStillRefused() {
        val provider = FakeProvider()
        provider.add("selected-source", "original.json", accountBytes(), parent = null)
        provider.entries["alias-locator"] = provider.Entry(provider.meta("selected-source", generatedName))
        provider.createResult = "alias-locator"
        provider.core().read(source) {}.use { backup ->
            failed(AccountBackupDocumentReason.UNSAFE_DOCUMENT) {
                provider.core().saveNewCopy(tree, backup, AccountBackupCopyKind.ACCOUNT, check = {})
            }
        }
        assertEquals(0, provider.outputOpenCount)
        assertTrue(provider.deleted.isEmpty())
    }

    @Test fun providerRenamingTheGeneratedFilenameIsRefused() {
        val provider = FakeProvider().apply { returnedName = "changed.json" }
        provider.core().prepare(accountBytes()) {}.use { backup ->
            failed(AccountBackupDocumentReason.UNSAFE_DOCUMENT) {
                provider.core().saveNewCopy(tree, backup, AccountBackupCopyKind.ACCOUNT, check = {})
            }
        }
        assertEquals(0, provider.outputOpenCount)
        assertTrue(provider.deleted.isEmpty())
    }

    @Test fun documentOutsideSelectedParentIsRefused() {
        val provider = FakeProvider().apply { returnedParent = "other-root" }
        provider.core().prepare(accountBytes()) {}.use { backup ->
            failed(AccountBackupDocumentReason.UNSAFE_DOCUMENT) {
                provider.core().saveNewCopy(tree, backup, AccountBackupCopyKind.ACCOUNT, check = {})
            }
        }
        assertEquals(0, provider.outputOpenCount)
        assertTrue(provider.deleted.isEmpty())
    }

    @Test fun nonemptyReturnedEntryIsNeverOpenedForOutput() {
        val provider = FakeProvider().apply { returnedBytes = byteArrayOf(1) }
        provider.core().prepare(accountBytes()) {}.use { backup ->
            val failure = failed(AccountBackupDocumentReason.UNSAFE_DOCUMENT) {
                provider.core().saveNewCopy(tree, backup, AccountBackupCopyKind.ACCOUNT, check = {})
            }
            assertTrue(failure.newCopyMayRemain)
        }
        assertEquals(0, provider.outputOpenCount)
        assertTrue(provider.deleted.isEmpty())
    }

    @Test fun lyingZeroSizeDoesNotAdmitAContentBearingEntry() {
        val provider = FakeProvider().apply { returnedBytes = byteArrayOf(1); lieAboutEmptySize = true }
        provider.core().prepare(accountBytes()) {}.use { backup ->
            failed(AccountBackupDocumentReason.UNSAFE_DOCUMENT) {
                provider.core().saveNewCopy(tree, backup, AccountBackupCopyKind.ACCOUNT, check = {})
            }
        }
        assertEquals(0, provider.outputOpenCount)
        assertTrue(provider.deleted.isEmpty())
    }

    @Test fun ambiguousIdsOrNamesAndLargeDirectoriesAreRefused() {
        for (duplicateId in listOf(false, true)) {
            val provider = FakeProvider()
            provider.add("existing", "existing.json")
            if (duplicateId) provider.duplicateIds = true else {
                provider.add("case-duplicate", "EXISTING.JSON")
            }
            provider.core().prepare(accountBytes()) {}.use { backup ->
                failed(AccountBackupDocumentReason.UNSAFE_DOCUMENT) {
                    provider.core().saveNewCopy(tree, backup, AccountBackupCopyKind.ACCOUNT, check = {})
                }
            }
            assertEquals(0, provider.createCount)
        }
        val crowded = FakeProvider().apply { excessiveChildren = true }
        crowded.core().prepare(accountBytes()) {}.use { backup ->
            failed(AccountBackupDocumentReason.TOO_MANY_DOCUMENTS) {
                crowded.core().saveNewCopy(tree, backup, AccountBackupCopyKind.ACCOUNT, check = {})
            }
        }
        assertEquals(0, crowded.createCount)
    }

    @Test fun readbackDigestMismatchCannotReturnASuccessReceipt() {
        val provider = FakeProvider()
        val bytes = accountBytes()
        provider.readbackOverride = bytes.copyOf().also { it[it.lastIndex] = 1 }
        provider.core().prepare(bytes) {}.use { backup ->
            val failure = failed(AccountBackupDocumentReason.VERIFICATION_FAILED) {
                provider.core().saveNewCopy(tree, backup, AccountBackupCopyKind.ACCOUNT, check = {})
            }
            assertTrue(failure.newCopyMayRemain)
        }
        assertTrue(provider.outputClosed)
        assertTrue(provider.deleted.isEmpty())
    }

    @Test fun oversizedReadbackIsAVerificationFailure() {
        val provider = FakeProvider().apply { readbackOverride = accountBytes() + byteArrayOf(1) }
        provider.core().prepare(accountBytes()) {}.use { backup ->
            failed(AccountBackupDocumentReason.VERIFICATION_FAILED) {
                provider.core().saveNewCopy(tree, backup, AccountBackupCopyKind.ACCOUNT, check = {})
            }
        }
    }

    @Test fun cancellationBeforeCreateHasNoProviderMutation() {
        val provider = FakeProvider()
        provider.core().prepare(accountBytes()) {}.use { backup ->
            failed(AccountBackupDocumentReason.OPERATION_CHANGED) {
                provider.core().saveNewCopy(tree, backup, AccountBackupCopyKind.ACCOUNT, check = current { false })
            }
        }
        assertEquals(0, provider.createCount)
        assertEquals(0, provider.outputOpenCount)
        assertTrue(provider.deleted.isEmpty())
    }

    @Test fun cancellationBeforeOutputCanDeleteOnlyTheUnchangedEmptyCreation() {
        val provider = FakeProvider()
        provider.add("existing", "keep.json", byteArrayOf(4, 5))
        var active = true
        provider.afterEmptyRead = { active = false }
        provider.core().prepare(accountBytes()) {}.use { backup ->
            val failure = failed(AccountBackupDocumentReason.OPERATION_CHANGED) {
                provider.core().saveNewCopy(tree, backup, AccountBackupCopyKind.ACCOUNT, check = current { active })
            }
            assertFalse(failure.newCopyMayRemain)
        }
        assertEquals(0, provider.outputOpenCount)
        assertEquals(listOf("new"), provider.deleted)
        assertArrayEquals(byteArrayOf(4, 5), provider.entries.getValue("existing").data)
    }

    @Test fun cleanupRefusesAnEntryWhoseIdentityOrNameChanged() {
        val provider = FakeProvider()
        var active = true
        provider.afterEmptyRead = { active = false }
        var observation = 0
        provider.onCleanupObservation = {
            // Admission observes twice; cleanup's third fresh observation changes identity and name.
            observation += 1
            if (observation == 3) {
                val entry = provider.entries.getValue("new")
                entry.metadata = entry.metadata.copy(identity = AccountDocumentIdentity("fixture.provider", "foreign"), name = "foreign.json")
            }
        }
        provider.core().prepare(accountBytes()) {}.use { backup ->
            val failure = failed(AccountBackupDocumentReason.OPERATION_CHANGED) {
                provider.core().saveNewCopy(tree, backup, AccountBackupCopyKind.ACCOUNT, check = current { active })
            }
            assertTrue(failure.newCopyMayRemain)
        }
        assertTrue(provider.deleted.isEmpty())
        assertTrue(provider.entries.containsKey("new"))
    }

    @Test fun cleanupWithoutAChangeTokenLeavesTheEmptyCopyHonestly() {
        val provider = FakeProvider().apply { returnedLastModified = null }
        var active = true
        provider.afterEmptyRead = { active = false }
        provider.core().prepare(accountBytes()) {}.use { backup ->
            val failure = failed(AccountBackupDocumentReason.OPERATION_CHANGED) {
                provider.core().saveNewCopy(tree, backup, AccountBackupCopyKind.ACCOUNT, check = current { active })
            }
            assertTrue(failure.newCopyMayRemain)
        }
        assertTrue(provider.deleted.isEmpty())
    }

    @Test fun cleanupRefusesNewContentEvenWhenTheProviderStillReportsZeroSize() {
        val provider = FakeProvider()
        var active = true
        provider.afterEmptyRead = {
            active = false
            provider.entries.getValue("new").data = byteArrayOf(7)
        }
        provider.core().prepare(accountBytes()) {}.use { backup ->
            val failure = failed(AccountBackupDocumentReason.OPERATION_CHANGED) {
                provider.core().saveNewCopy(tree, backup, AccountBackupCopyKind.ACCOUNT, check = current { active })
            }
            assertTrue(failure.newCopyMayRemain)
        }
        assertTrue(provider.deleted.isEmpty())
        assertArrayEquals(byteArrayOf(7), provider.entries.getValue("new").data)
    }

    @Test fun stalePostReadbackCompletionNeverPublishesOrDeletesTheWrittenCopy() {
        val provider = FakeProvider()
        var active = true
        provider.afterReadbackClose = { active = false }
        provider.core().prepare(accountBytes()) {}.use { backup ->
            val failure = failed(AccountBackupDocumentReason.OPERATION_CHANGED) {
                provider.core().saveNewCopy(tree, backup, AccountBackupCopyKind.ACCOUNT, check = current { active })
            }
            assertTrue(failure.newCopyMayRemain)
        }
        assertArrayEquals(accountBytes(), provider.entries.getValue("new").data)
        assertTrue(provider.deleted.isEmpty())
    }

    @Test fun cancelledSuspendCallWaitsForActualBlockingProviderReturn() = runBlocking {
        val provider = FakeProvider()
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val drained = CountDownLatch(1)
        provider.beforeWrite = {
            entered.countDown()
            check(release.await(5, TimeUnit.SECONDS))
        }
        val core = provider.core()
        val helper = AccountBackupDocuments(core)
        val backup = core.prepare(accountBytes()) {}
        try {
            val operation = launch(Dispatchers.Default) {
                try { helper.saveNewCopy(tree, backup, isCurrent = { true }) }
                catch (_: CancellationException) { }
                catch (failure: AccountBackupDocumentFailure) {
                    assertEquals(AccountBackupDocumentReason.OPERATION_CHANGED, failure.reason)
                }
                finally { drained.countDown() }
            }
            try {
                assertTrue(withContext(Dispatchers.IO) { entered.await(5, TimeUnit.SECONDS) })
                operation.cancel()
                assertFalse(operation.isCompleted)
                assertEquals(1L, drained.count)
            } finally {
                release.countDown()
                withContext(NonCancellable) { operation.join() }
            }
            assertEquals(0L, drained.count)
            assertTrue(provider.outputClosed)
            assertArrayEquals(accountBytes(), provider.entries.getValue("new").data)
            assertTrue(provider.deleted.isEmpty())
        } finally { backup.close(); release.countDown() }
    }

    @Test fun repairedCopyUsesAnIndependentGeneratedName() {
        val provider = FakeProvider()
        provider.core().prepare(accountBytes()) {}.use { backup ->
            val receipt = provider.core().saveNewCopy(tree, backup, AccountBackupCopyKind.REPAIRED, check = {})
            assertEquals("vortx-account-repaired-$suffix.json", receipt.displayName)
        }
    }

    @Test fun fixedErrorsAndOpaqueDiagnosticsDoNotExposeLocatorsOrBytes() {
        val handle = AccountDocumentHandle("content://private.provider/document/private-id")
        assertFalse(handle.toString().contains("private"))
        val failure = AccountBackupDocumentFailure(AccountBackupDocumentReason.UNAVAILABLE, true)
        assertNull(failure.cause)
        assertTrue(failure.message!!.endsWith("A new copy may remain in the selected folder."))
        assertFalse(failure.message!!.contains("content://"))
    }

    private fun sha256(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes)
        .joinToString("") { (it.toInt() and 0xff).toString(16).padStart(2, '0') }
}
