package com.vortx.android.security

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class FailClosedCredentialStoreSourceContractTest {

    @Test
    fun encryptedCiphertextIsNeverDeletedByFailClosedRecovery() {
        val source = readStoreSource()
        assertTrue(
            deletionContractViolations(source).joinToString(separator = "\n"),
            deletionContractViolations(source).isEmpty(),
        )
    }

    @Test
    fun legacyPlaintextFallbackIsStillPurgedAndDeleted() {
        val source = readStoreSource()

        assertTrue(source.contains("getSharedPreferences(legacyPlainFileName"))
        assertTrue(source.contains("deleteSharedPreferences(legacyPlainFileName)"))
    }

    @Test
    fun compoundCredentialTombstoneCommitsOnceThenPurgesLegacyPlaintext() {
        val source = readStoreSource()
        val compound = source
            .substringAfter("fun setAndPurgeLegacy(values: Map<String, String?>): Boolean")
            .substringBefore("fun clear(vararg keys: String): Boolean")
        val clear = source
            .substringAfter("fun clear(vararg keys: String): Boolean")
            .substringBefore("private fun purgeLegacyPlaintext()")

        assertEquals(1, compound.windowed("state.write(values)".length).count { it == "state.write(values)" })
        assertTrue(compound.contains("purge = ::purgeLegacyPlaintext"))
        assertTrue(clear.contains("setAndPurgeLegacy(keys.associateWith { null })"))
    }

    @Test
    fun rejectedCompoundCredentialWriteStillPurgesLegacyPlaintext() {
        var writes = 0
        var purges = 0

        val result = writeThenPurgeLegacy(
            write = {
                writes += 1
                false
            },
            purge = { purges += 1 },
        )

        assertFalse(result)
        assertEquals(1, writes)
        assertEquals(1, purges)
    }

    @Test
    fun exceptionalCompoundCredentialWriteStillPurgesLegacyPlaintext() {
        var purges = 0

        assertThrows(IllegalStateException::class.java) {
            writeThenPurgeLegacy(
                write = { error("write failed") },
                purge = { purges += 1 },
            )
        }

        assertEquals(1, purges)
    }

    @Test
    fun historicalAndAlternateDeletionMutationsTurnTheContractRed() {
        val source = readStoreSource()
        val mutations = listOf(
            source + "\nfun historicalOpenFailureMutant() = appContext.deleteSharedPreferences(encryptedFileName)\n",
            source + "\nfun historicalClearFailureMutant() { appContext.deleteSharedPreferences(encryptedFileName) }\n",
            source.replace(
                "appContext.deleteSharedPreferences(legacyPlainFileName)",
                "appContext.run { deleteSharedPreferences(encryptedFileName) }",
            ),
            source + """
                private fun deletePrefs(name: String) = appContext.deleteSharedPreferences(name)
                private fun helperDeletionMutant() = deletePrefs(encryptedFileName)
            """.trimIndent(),
            source + "\nprivate val alternateDeletionMutant = appContext::deleteSharedPreferences\n",
            source + """
                private fun encryptedClearMutant() {
                    appContext.getSharedPreferences(encryptedFileName, Context.MODE_PRIVATE)
                        .edit()
                        .clear()
                        .commit()
                }
            """.trimIndent(),
        )

        mutations.forEachIndexed { index, mutation ->
            assertTrue(
                "Deletion mutation $index escaped the source contract",
                deletionContractViolations(mutation).isNotEmpty(),
            )
        }
    }

    private fun deletionContractViolations(source: String): List<String> = buildList {
        val deleteReferences = Regex("""\bdeleteSharedPreferences\b""").findAll(source).count()
        val allowedDeleteCalls = Regex(
            """appContext\s*\.\s*deleteSharedPreferences\s*\(\s*legacyPlainFileName\s*\)""",
        ).findAll(source).count()
        if (deleteReferences != 1 || allowedDeleteCalls != 1) {
            add("Only appContext.deleteSharedPreferences(legacyPlainFileName) may delete preferences")
        }

        val preferenceOpenReferences = Regex("""\bgetSharedPreferences\b""").findAll(source).count()
        val allowedPreferenceOpens = Regex(
            """appContext\s*\.\s*getSharedPreferences\s*\(\s*legacyPlainFileName\s*,\s*Context\.MODE_PRIVATE\s*\)""",
        ).findAll(source).count()
        if (preferenceOpenReferences != 1 || allowedPreferenceOpens != 1) {
            add("Only the legacy plaintext preference file may be opened directly")
        }

        val editorClearCalls = Regex("""\.\s*clear\s*\(""").findAll(source).count()
        val editorClearReferences = Regex("""::\s*clear\b""").findAll(source).count()
        if (editorClearCalls != 1 || editorClearReferences != 0) {
            add("Only the legacy plaintext preference editor may be cleared")
        }
    }

    private fun readStoreSource(): String {
        val candidates = listOf(
            File("src/main/kotlin/com/vortx/android/security/FailClosedCredentialStore.kt"),
            File("app/src/main/kotlin/com/vortx/android/security/FailClosedCredentialStore.kt"),
            File("android/app/src/main/kotlin/com/vortx/android/security/FailClosedCredentialStore.kt"),
        )
        return candidates.firstOrNull(File::isFile)?.readText()
            ?: error("Could not locate FailClosedCredentialStore.kt from ${File(".").absolutePath}")
    }
}
