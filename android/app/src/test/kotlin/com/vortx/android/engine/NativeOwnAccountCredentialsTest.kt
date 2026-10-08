package com.vortx.android.engine

import com.vortx.android.security.PersistentCredentialAvailability
import com.vortx.android.security.PersistentCredentialSnapshot
import com.vortx.android.sync.SessionOwnerSnapshot
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class NativeOwnAccountCredentialsTest {
    private val account = SessionOwnerSnapshot.Account("00000000-0000-0000-0000-000000000456", 1)
    private val profile = "11111111-1111-1111-1111-111111111111"
    private class Store {
        val records = mutableMapOf<String, String?>()
        var writes = true
        fun journal() = NativeOwnAccountCredentials({ key -> PersistentCredentialSnapshot(
            PersistentCredentialAvailability.AVAILABLE, mapOf(key to records[key])) }, { key, value ->
            if (writes) { records[key] = value; true } else false
        })
    }

    @Test fun `staged same UID revision cannot replace selected token before native CAS`() {
        val store = Store(); val journal = store.journal()
        val first = journal.begin(account, profile, { it() }, "transaction-a")
        journal.storeVerified(first, "fake-a", "uid")
        val second = journal.begin(account, profile, { it() }, "transaction-b")
        journal.storeVerified(second, "fake-b", "uid")
        fun token(tx: String) = requireNotNull(journal.capture(account, profile, "uid", tx) { it() }).request(JSONObject()).getString("authKey")
        assertEquals("fake-a", token("transaction-a"))
        assertEquals("fake-b", token("transaction-b"))
        assertNull(journal.capture(account, profile, "uid", "transaction-missing") { it() })
        assertNull(journal.capture(account, profile, "uid", null) { it() })
        // Crash/restart has no mutable active pointer to lose. Native state supplies exact A or B.
        val restarted = store.journal()
        assertEquals("fake-a", restarted.capture(account, profile, "uid", "transaction-a") { it() }!!.request(JSONObject()).getString("authKey"))
        assertEquals(2, store.records.size)
        assertTrue(store.records.keys.all { it.matches(Regex("revision\\.[0-9a-f]{64}")) })
    }

    @Test fun `immutable slot rejects replacement and isolation is account profile UID and transaction exact`() {
        val store = Store(); val journal = store.journal()
        journal.storeVerified(journal.begin(account, profile, { it() }, "a"), "original", "uid")
        val before = store.records.toMap()
        assertTrue(runCatching { journal.storeVerified(journal.begin(account, profile, { it() }, "a"), "changed", "uid") }.isFailure)
        assertEquals(before, store.records)
        assertNull(journal.capture(account.copy(id = "00000000-0000-0000-0000-000000000789"), profile, "uid", "a") { it() })
        assertNull(journal.capture(account, "22222222-2222-2222-2222-222222222222", "uid", "a") { it() })
        assertNull(journal.capture(account, profile, "other-uid", "a") { it() })
        store.writes = false
        assertTrue(runCatching { journal.storeVerified(journal.begin(account, profile, { it() }, "b"), "candidate", "uid") }.isFailure)
        assertEquals(before, store.records)
    }

    @Test fun `same token same revision new attempt revokes in-flight capture and account admission is final`() {
        val store = Store(); val journal = store.journal(); var active = true
        val admission: (() -> Boolean) -> Boolean = { active && it() }
        val first = journal.storeVerified(journal.begin(account, profile, admission, "a"), "fixture", "uid")
        journal.storeVerified(journal.begin(account, profile, admission, "a"), "fixture", "uid")
        assertTrue(runCatching { first.request(JSONObject()) }.isFailure)
        val current = journal.capture(account, profile, "uid", "a", admission)!!
        active = false
        assertTrue(runCatching { current.request(JSONObject()) }.isFailure)
        active = true; journal.invalidateContext()
        assertTrue(runCatching { current.request(JSONObject()) }.isFailure)
    }
}
