package com.vortx.android.sync

import org.junit.Assert.*
import org.junit.Test

internal class MemoryLibraryProofPersistence : LibraryProofPersistence {
    val data = mutableMapOf<String, String>()
    var failWrites = false
    var unavailable = false
    override fun read(key: String): Result<String?> = if (unavailable) Result.failure(IllegalStateException()) else Result.success(data[key])
    override fun write(key: String, value: String): Boolean {
        if (failWrites || unavailable) return false
        data[key] = value
        return true
    }
}

internal fun publicationRow(id: String = "tt1", epoch: Long = 2000) = VortXSyncDoc.OwnerLibraryItem(
    metaId = id, type = "movie", name = "Movie", poster = null, videoId = id,
    timeOffsetMs = 1000, durationMs = 10000, lastWatched = "1970-01-01T00:00:02Z",
    timesWatched = 0, wholeTitleWatched = false, eventEpochMs = epoch, nativeEventEpochMs = epoch,
)

class OwnerLibraryPublicationProofsTest {
    @Test fun `production policies retain ownership through first movie mark load progress remove and readd`() {
        val proofs = OwnerLibraryPublicationProofs(MemoryLibraryProofPersistence())
        val native = NativeLibraryOwner(null)
        val lease = OwnerLibraryPublicationLease("B", proofs) { it() }
        var rows = emptyList<VortXSyncDoc.OwnerLibraryItem>()
        fun mutate(row: VortXSyncDoc.OwnerLibraryItem, policy: (VortXSyncDoc.OwnerLibraryItem?, VortXSyncDoc.OwnerLibraryItem) -> Boolean) {
            assertTrue(lease.mutate(native, row.identity, { rows }, policy) { rows = listOf(row) })
            assertTrue(proofs.owns("B", native, row))
        }
        val firstWatch = publicationRow().copy(timeOffsetMs = 0, durationMs = 0, lastWatched = null, videoId = null, wholeTitleWatched = true, timesWatched = 1)
        mutate(firstWatch, LocalLibraryPublicationPolicy.watched(true))
        val removed = firstWatch.copy(removed = true, eventEpochMs = 3000, nativeEventEpochMs = 3000)
        mutate(removed, LocalLibraryPublicationPolicy::removed)
        mutate(removed.copy(removed = false, eventEpochMs = 4000, nativeEventEpochMs = 4000), LocalLibraryPublicationPolicy::membershipAdded)
        rows = emptyList()
        val loaded = publicationRow("tt2").copy(timeOffsetMs = 0, durationMs = 0, lastWatched = null)
        mutate(loaded, LocalLibraryPublicationPolicy.playerLoaded("tt2"))
        mutate(loaded.copy(timeOffsetMs = 2500, durationMs = 10000, lastWatched = "1970-01-01T00:00:03Z", eventEpochMs = 3000, nativeEventEpochMs = 3000), LocalLibraryPublicationPolicy.progress("tt2", 2500, 10000))
        assertFalse(LocalLibraryPublicationPolicy.playerLoaded("tt2")(null, loaded.copy(watched = "foreign-bits")))
        assertFalse(LocalLibraryPublicationPolicy.watched(true)(null, firstWatch.copy(timeOffsetMs = 1000)))
        // A removal may not claim an existing foreign row merely because it matches the action shape.
        rows = listOf(publicationRow("tt99"))
        val foreignRemoved = rows.single().copy(removed = true, nativeEventEpochMs = 3000, eventEpochMs = 3000)
        lease.mutate(native, foreignRemoved.identity, { rows }, LocalLibraryPublicationPolicy::removed) { rows = listOf(foreignRemoved) }
        assertFalse(proofs.owns("B", native, foreignRemoved))
    }

    @Test fun `exact account native type and entire payload persist across restart`() {
        val disk = MemoryLibraryProofPersistence()
        val proofs = OwnerLibraryPublicationProofs(disk)
        val row = publicationRow()
        assertTrue(proofs.grant("A", NativeLibraryOwner(null), listOf(row)))
        val reopened = OwnerLibraryPublicationProofs(disk)
        assertTrue(reopened.owns("A", NativeLibraryOwner(null), row))
        assertFalse(reopened.owns("B", NativeLibraryOwner(null), row))
        assertFalse(reopened.owns("A", NativeLibraryOwner("native"), row))
        for (changed in listOf(row.copy(type = "series"), row.copy(timeOffsetMs = 0), row.copy(watched = "opaque"), row.copy(removed = true), row.copy(name = "Different"), row.copy(nativeEventEpochMs = 2001))) {
            assertFalse(reopened.owns("A", NativeLibraryOwner(null), changed))
        }
        disk.failWrites = true
        val newer = row.copy(nativeEventEpochMs = 3000)
        assertFalse(proofs.grant("A", NativeLibraryOwner(null), listOf(newer)))
        assertFalse(OwnerLibraryPublicationProofs(disk).owns("A", NativeLibraryOwner(null), newer))
        disk.failWrites = false
        disk.data.keys.toList().forEach { disk.data[it] = "corrupt" }
        assertFalse(proofs.grant("A", NativeLibraryOwner(null), listOf(row)))
        assertFalse(proofs.owns("A", NativeLibraryOwner(null), row))
    }

    @Test fun `only validated absent or previously owned target transitions grant`() {
        for (mode in listOf("new", "owned", "collision", "noop", "invalid", "readFailure", "commitFailure", "expired")) {
            val disk = MemoryLibraryProofPersistence()
            val proofs = OwnerLibraryPublicationProofs(disk)
            val native = NativeLibraryOwner("shared")
            val before = publicationRow(epoch = 1000)
            val after = publicationRow(epoch = 2000)
            var rows: List<VortXSyncDoc.OwnerLibraryItem>? = if (mode == "new") emptyList() else listOf(before)
            if (mode == "owned") assertTrue(proofs.grant("B", native, listOf(before)))
            if (mode == "readFailure") rows = null
            if (mode == "commitFailure") { rows = emptyList(); disk.failWrites = true }
            var writes = 0
            val lease = OwnerLibraryPublicationLease("B", proofs) { action -> if (mode == "expired") false else action() }
            lease.mutate(native, after.identity, { rows }, { _, _ -> mode != "invalid" }) {
                writes++
                if (mode != "noop") rows = listOf(after, publicationRow("tt99"))
            }
            assertEquals(mode, mode in listOf("new", "owned"), proofs.owns("B", native, after))
            assertFalse(proofs.owns("B", native, publicationRow("tt99")))
            assertEquals(if (mode == "expired") 0 else 1, writes)
        }
    }
}
