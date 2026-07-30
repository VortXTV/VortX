package com.vortx.android.security

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class FailClosedCredentialStateTest {

    @Test
    fun missingSecureBackendUsesMemoryOnly() {
        val state = FailClosedCredentialState(backend = null)

        assertFalse(state.write(mapOf("token" to "secret")))
        assertEquals("secret", state.string("token"))
        assertFalse(state.hasPersistentBackend)
    }

    @Test
    fun secureOpenFailureReturnsNoDiskBackend() {
        var failures = 0

        val backend = openCredentialBackendOrNull(
            opener = { throw IllegalStateException("keystore unavailable") },
            onFailure = { failures += 1 },
        )

        assertNull(backend)
        assertEquals(1, failures)
    }

    @Test
    fun secureOpenSuccessPersistsAndMirrorsMemory() {
        val backend = FakeBackend()
        val state = FailClosedCredentialState(backend)

        assertTrue(state.write(mapOf("token" to "secret")))
        assertEquals("secret", backend.values["token"])
        assertEquals("secret", state.string("token"))
        assertTrue(state.hasPersistentBackend)
    }

    @Test
    fun postOpenReadFailureDisablesBackendAndReturnsAbsent() {
        var failures = 0
        val backend = FakeBackend().apply { failReads = true }
        val state = FailClosedCredentialState(backend) { failures += 1 }

        assertNull(state.string("token"))
        assertFalse(state.hasPersistentBackend)
        assertEquals(1, failures)
        assertFalse(state.write(mapOf("token" to "memory-secret")))
        assertEquals("memory-secret", state.string("token"))
    }

    @Test
    fun rejectedEncryptedWriteNeverUsesAnotherDiskBackend() {
        var failures = 0
        val backend = FakeBackend().apply { rejectWrites = true }
        val state = FailClosedCredentialState(backend) { failures += 1 }

        assertFalse(state.write(mapOf("token" to "memory-secret")))
        assertFalse(state.hasPersistentBackend)
        assertEquals("memory-secret", state.string("token"))
        assertEquals(1, backend.writeAttempts)
        assertEquals(1, failures)
    }

    @Test
    fun clearRemovesMemoryValueAfterBackendFailure() {
        val state = FailClosedCredentialState(backend = null)
        state.write(mapOf("token" to "memory-secret"))

        state.write(mapOf("token" to null))

        assertNull(state.string("token"))
    }

    private class FakeBackend : CredentialBackend {
        val values = mutableMapOf<String, String>()
        var failReads = false
        var rejectWrites = false
        var writeAttempts = 0

        override fun string(key: String): String? {
            if (failReads) error("read failure")
            return values[key]
        }

        override fun write(values: Map<String, String?>): Boolean {
            writeAttempts += 1
            if (rejectWrites) return false
            values.forEach { (key, value) ->
                if (value == null) this.values.remove(key) else this.values[key] = value
            }
            return true
        }
    }
}
