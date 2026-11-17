package com.vortx.android.profile

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

class BackupRecoveryEntryWiringTest {
    @Test fun phoneAndTvOfferBackupRecoveryAgainAfterSignOut() {
        val sourceRoot = listOf("src/main/kotlin", "app/src/main/kotlin", "android/app/src/main/kotlin")
            .map { File(it, "com/vortx/android") }.first(File::isDirectory)
        val shells = mapOf("ui/VortXApp.kt" to "vortxSessionUi", "ui/tv/TvApp.kt" to "sessionUiState")
        for ((path, session) in shells) {
            val source = File(sourceRoot, path).readText()
            val entry = source.substringAfter("var dismissedFileRecoveryEntry")
                .substringBefore("val restoreStatusOwner")
            assertTrue(path, entry.contains("val showFileRecoveryEntry = !dismissedFileRecoveryEntry"))
            assertTrue(path, entry.contains("$session == VortXSyncManager.SessionUiState.SignedOut"))
            assertTrue(path, entry.contains("if ($session is VortXSyncManager.SessionUiState.SignedIn) dismissedFileRecoveryEntry = false"))
            assertTrue(path, source.contains("else ({ dismissedFileRecoveryEntry = true })"))
        }
    }
}
