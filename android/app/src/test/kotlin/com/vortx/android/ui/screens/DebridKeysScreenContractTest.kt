package com.vortx.android.ui.screens

import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import com.vortx.android.debrid.DebridKeyStatus
import com.vortx.android.debrid.DebridService
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class DebridKeysScreenContractTest {

    @Test
    fun `Usenet transient credentials are keyed to the active account`() {
        val source = readSource()
        assertTrue(source.contains("accountIdentity = accountIdentity"))
        assertTrue(source.contains("fun UsenetProviderSection("))
        assertTrue(source.contains("remember(accountIdentity) { mutableStateOf(\"\") }"))
        assertTrue(source.contains("remember(ownerKnown, accountIdentity)"))
    }

    @Test
    fun storageFailureUsesTheExactSecurityCopy() {
        val state = DebridKeyEditorState.from(
            DebridKeyStatus(
                hasValue = false,
                durablyConfigured = false,
                storageUnavailable = true,
            ),
        )

        assertEquals("Secure storage unavailable", state.statusText)
    }

    @Test
    fun storedCredentialIsStatusOnlyAndNeverBecomesEditorText() {
        val state = DebridKeyEditorState.from(
            DebridKeyStatus(
                hasValue = true,
                durablyConfigured = true,
                storageUnavailable = false,
            ),
        )

        assertEquals("Set", state.statusText)
        assertEquals("", state.pendingKey)
    }

    @Test
    fun failedClearRereadKeepsTheConfirmedValueTruth() {
        val afterFailedClear = DebridKeyEditorState.from(
            DebridKeyStatus(
                hasValue = true,
                durablyConfigured = true,
                storageUnavailable = false,
            ),
        ).copy(pendingKey = "keep-for-retry").afterClear(
            DebridKeyStatus(
                hasValue = true,
                durablyConfigured = false,
                storageUnavailable = true,
            ),
        )

        assertTrue(afterFailedClear.hasValue)
        assertEquals("Secure storage unavailable", afterFailedClear.statusText)
        assertEquals("keep-for-retry", afterFailedClear.pendingKey)
    }

    @Test
    fun failedSaveKeepsRetryTextAndSuccessfulRetryClearsIt() {
        val failed = DebridKeyEditorState.from(
            DebridKeyStatus(
                hasValue = false,
                durablyConfigured = false,
                storageUnavailable = false,
            ),
        ).afterSave(
            attemptedKey = "retry-me",
            status = DebridKeyStatus(
                hasValue = false,
                durablyConfigured = false,
                storageUnavailable = true,
            ),
        )
        assertEquals("retry-me", failed.pendingKey)
        assertEquals("Secure storage unavailable", failed.statusText)

        val recovered = failed.afterSave(
            attemptedKey = failed.pendingKey,
            status = DebridKeyStatus(
                hasValue = true,
                durablyConfigured = true,
                storageUnavailable = false,
            ),
        )
        assertEquals("", recovered.pendingKey)
        assertTrue(recovered.hasValue)
        assertEquals("Set", recovered.statusText)
    }

    @Test
    fun editorIdentityIsAccountKeyed() {
        val accountA = debridEditorStateKey(DebridService.TOR_BOX, "account-a")
        val local = debridEditorStateKey(DebridService.TOR_BOX, "local")
        val accountB = debridEditorStateKey(DebridService.TOR_BOX, "account-b")

        assertNotEquals(accountA, local)
        assertNotEquals(local, accountB)
        assertNotEquals(accountA, accountB)
        assertEquals(accountA, debridEditorStateKey(DebridService.TOR_BOX, "account-a"))
    }

    @Test
    fun editorUsesPasswordTransformationAndPasswordKeyboardSemantics() {
        assertTrue(debridKeyVisualTransformation() is PasswordVisualTransformation)
        assertEquals(KeyboardType.Password, debridKeyKeyboardOptions.keyboardType)
    }

    @Test
    fun rejectedMutationCannotBeRenderedAsSavedOrNotSet() {
        val reread = DebridKeyStatus(
            hasValue = true,
            durablyConfigured = true,
            storageUnavailable = false,
        )

        val status = debridMutationStatus(saved = false, reread = reread)

        assertTrue(status.storageUnavailable)
        assertEquals(false, status.durablyConfigured)
    }

    @Test
    fun mutationStatusIsAPoliteServiceSpecificLiveRegionWithErrorSemantics() {
        val source = readSource()

        assertTrue(phoneStatusAccessibilityContract(source))
        listOf(
            "liveRegion = LiveRegionMode.Polite" to "liveRegion = LiveRegionMode.None",
            "stateDescription = statusAccessibilityText" to "stateDescription = \"\"",
            "if (editor.storageUnavailable)" to "if (false)",
            "error(statusAccessibilityText)" to "stateDescription = statusAccessibilityText",
            "isError = editor.storageUnavailable" to "isError = false",
        ).forEachIndexed { index, (before, after) ->
            assertFalse(
                "phone status accessibility mutation $index survived",
                phoneStatusAccessibilityContract(source.replace(before, after)),
            )
        }
    }

    @Test
    fun failedMutationsKeepFocusWhileSuccessfulMutationsMayDismissTheKeyboard() {
        val failed = DebridKeyEditorState(
            pendingKey = "retry-me",
            hasValue = false,
            durablyConfigured = false,
            storageUnavailable = true,
        )
        val saved = failed.copy(
            pendingKey = "",
            hasValue = true,
            durablyConfigured = true,
            storageUnavailable = false,
        )

        assertFalse(failed.shouldClearMutationFocus())
        assertTrue(saved.shouldClearMutationFocus())
        assertTrue(phoneFocusRetentionContract(readSource()))
    }

    @Test
    fun repeatedProviderControlsHaveUniqueNamesAndTraversalGroups() {
        val labels = DebridService.entries.map {
            debridControlAccessibilityLabel(it, "Save API key")
        }

        assertEquals(DebridService.entries.size, labels.toSet().size)
        assertTrue(labels.contains("Real-Debrid: Save API key"))
        assertTrue(phoneProviderAccessibilityContract(readSource()))
    }

    @Test
    fun secureStorageFailureUsesTheHighContrastThemeTextToken() {
        val source = readSource()

        assertTrue(phoneDangerStatusContrastContract(source))
        assertFalse(
            phoneDangerStatusContrastContract(
                source.replace(
                    "editor.storageUnavailable -> colors.textPrimary",
                    "editor.storageUnavailable -> colors.danger",
                ),
            ),
        )
    }

    private fun phoneStatusAccessibilityContract(source: String): Boolean =
        source.contains("liveRegion = LiveRegionMode.Polite") &&
            source.contains("stateDescription = statusAccessibilityText") &&
            source.contains("if (editor.storageUnavailable)") &&
            source.contains("error(statusAccessibilityText)") &&
            source.contains("supportingText = if (editor.storageUnavailable)") &&
            source.contains("Text(statusAccessibilityText, color = colors.textPrimary)") &&
            source.contains("isError = editor.storageUnavailable")

    private fun phoneFocusRetentionContract(source: String): Boolean =
        source.windowed(
            "if (updated.shouldClearMutationFocus()) focusManager.clearFocus()".length,
        ).count {
            it == "if (updated.shouldClearMutationFocus()) focusManager.clearFocus()"
        } == 2 &&
            source.contains("pendingKey = pendingKey.takeIf { status.storageUnavailable }.orEmpty()")

    private fun phoneProviderAccessibilityContract(source: String): Boolean =
        source.contains("isTraversalGroup = true") &&
            source.contains("debridControlAccessibilityLabel(service, fieldLabel)") &&
            source.contains("\"${'$'}saveLabel API key\"") &&
            source.contains("debridControlAccessibilityLabel(service, \"Clear API key\")")

    private fun phoneDangerStatusContrastContract(source: String): Boolean =
        source.contains("editor.storageUnavailable -> colors.textPrimary")

    private fun readSource(): String {
        val candidates = listOf(
            File("src/main/kotlin/com/vortx/android/ui/screens/DebridKeysScreen.kt"),
            File("app/src/main/kotlin/com/vortx/android/ui/screens/DebridKeysScreen.kt"),
            File("android/app/src/main/kotlin/com/vortx/android/ui/screens/DebridKeysScreen.kt"),
        )
        return candidates.firstOrNull(File::isFile)?.readText()
            ?: error("Could not locate DebridKeysScreen.kt from ${File(".").absolutePath}")
    }
}
