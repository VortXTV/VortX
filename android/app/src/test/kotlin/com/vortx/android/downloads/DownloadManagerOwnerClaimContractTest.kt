package com.vortx.android.downloads

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

class DownloadManagerOwnerClaimContractTest {

    @Test
    fun freshlyReloadedRecordIsOwnerCheckedInsideClaimBeforePublication() {
        val source = readSource()
        val claimBody = source
            .substringAfter("fun claimTransfer(id: String, generation: String): Boolean {")
            .substringBefore("/** Fail a revived/in-flight native-debrid transfer")
        val reload = claimBody.indexOf("val record = DownloadStore.record(id)")
        val ownerCheck = claimBody.indexOf("isOwnerCurrent = ::isDebridOwnerCurrent")
        val publication = claimBody.indexOf("activeGenerations[id] = generation")

        assertTrue("claimTransfer must freshly reload the record", reload >= 0)
        assertTrue(
            "claimTransfer must owner-check the freshly reloaded record before publishing its generation",
            ownerCheck > reload && ownerCheck < publication,
        )
    }

    private fun readSource(): String {
        val candidates = listOf(
            File("src/main/kotlin/com/vortx/android/downloads/DownloadManager.kt"),
            File("app/src/main/kotlin/com/vortx/android/downloads/DownloadManager.kt"),
            File("android/app/src/main/kotlin/com/vortx/android/downloads/DownloadManager.kt"),
        )
        return candidates.firstOrNull(File::isFile)?.readText()
            ?: error("Could not locate DownloadManager.kt from ${File(".").absolutePath}")
    }
}
