package com.vortx.android.ui.screens

import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import com.vortx.android.debrid.DebridKeyStatus
import com.vortx.android.debrid.DebridService
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class DebridKeysScreenContractTest {

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
        ).afterClear(
            DebridKeyStatus(
                hasValue = true,
                durablyConfigured = false,
                storageUnavailable = true,
            ),
        )

        assertTrue(afterFailedClear.hasValue)
        assertEquals("Secure storage unavailable", afterFailedClear.statusText)
        assertEquals("", afterFailedClear.pendingKey)
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
}
