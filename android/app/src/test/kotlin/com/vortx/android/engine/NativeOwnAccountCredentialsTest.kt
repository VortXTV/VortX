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
        var failReadAfterSelectorWrite = false
        var rejectAfterSelectorWrite = false
        var available = true
        fun journal() = NativeOwnAccountCredentials({ key -> PersistentCredentialSnapshot(
            if (available) PersistentCredentialAvailability.AVAILABLE else PersistentCredentialAvailability.UNAVAILABLE,
            mapOf(key to records[key])) }, { key, value ->
            if (writes) { records[key] = value
                if (key.startsWith("owner-selection.") && failReadAfterSelectorWrite) available = false
                !(key.startsWith("owner-selection.") && rejectAfterSelectorWrite)
            } else false
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

    @Test fun `owner selector is account and owner qualified and never adopts global or staged credentials`() {
        val store = Store(); val journal = store.journal()
        store.records["stremiox.authKey"] = "unscoped"
        val initial = journal.ownerSelection(account, profile) { it() }
        assertNull(journal.captureOwner(account, initial) { it() })
        val revision = "owner:00000000-0000-0000-0000-000000000001"
        val staged = journal.storeVerified(journal.begin(account, profile, { it() }, revision), "verified", "uid-a")
        assertNull(journal.captureOwner(account, initial) { it() })
        journal.selectOwner(account, initial, staged) { it() }
        val selected = journal.ownerSelection(account, profile) { it() }
        assertEquals("verified", journal.captureOwner(account, selected) { it() }!!.request(JSONObject()).getString("authKey"))
        val other = account.copy(id = "00000000-0000-0000-0000-000000000789")
        assertNull(journal.captureOwner(other, journal.ownerSelection(other, profile) { it() }) { it() })
        val otherOwner = "22222222-2222-2222-2222-222222222222"
        assertNull(journal.captureOwner(account, journal.ownerSelection(account, otherOwner) { it() }) { it() })
        val reopened = store.journal()
        assertEquals("uid-a", reopened.ownerSelection(account, profile) { it() }.verifiedUID)
        assertTrue(store.records.values.filterNotNull().filter { it.startsWith("{") }.none { it.contains("unscoped") })
    }

    @Test fun `owner clear and reconnect ABA cannot revive captured selector or tokens`() {
        val store = Store(); val journal = store.journal()
        fun stage(revision: String) = journal.storeVerified(journal.begin(account, profile, { it() }, "owner:$revision"), "same-token", "uid")
        val initial = journal.ownerSelection(account, profile) { it() }
        journal.selectOwner(account, initial, stage("00000000-0000-0000-0000-000000000001")) { it() }
        val a = journal.ownerSelection(account, profile) { it() }
        val capture = journal.captureOwner(account, a) { it() }!!
        journal.clearOwner(account, a, { it() }) { it() }
        assertTrue(runCatching { capture.request(JSONObject()) }.isFailure)
        journal.selectOwner(account, journal.ownerSelection(account, profile) { it() }, stage("00000000-0000-0000-0000-000000000002")) { it() }
        val current = journal.ownerSelection(account, profile) { it() }
        assertTrue(runCatching { journal.clearOwner(account, a, { it() }) { it() } }.isFailure)
        assertEquals(current.raw, journal.ownerSelection(account, profile) { it() }.raw)
        assertTrue(runCatching { journal.selectOwner(account, a, stage("00000000-0000-0000-0000-000000000003")) { it() } }.isFailure)
        assertEquals(current.raw, journal.ownerSelection(account, profile) { it() }.raw)
    }

    @Test fun `certified selector commit is not reported failed by later read outage and cold intent reconciles actual revision`() {
        val store = Store(); val journal = store.journal()
        fun stage(n: Int) = journal.storeVerified(journal.begin(account, profile, { it() },
            "owner:00000000-0000-0000-0000-${n.toString().padStart(12, '0')}"), "token-$n", "uid")
        journal.selectOwner(account, journal.ownerSelection(account, profile) { it() }, stage(1)) { it() }
        val before = journal.ownerSelection(account, profile) { it() }
        val candidate = stage(2)
        val oldCaptureAfterStaging = journal.captureOwner(account, before) { it() }!!
        store.failReadAfterSelectorWrite = true
        assertTrue(runCatching { journal.selectOwner(account, before, candidate) { it() } }.isSuccess)
        assertTrue(runCatching { oldCaptureAfterStaging.request(JSONObject()) }.isFailure)
        store.available = true // Simulated fresh secure-store reopen, not an in-process fallback.
        val reopened = store.journal()
        val installed = reopened.ownerSelection(account, profile) { it() }
        assertEquals("token-2", reopened.captureOwner(account, installed) { it() }!!.request(JSONObject()).getString("authKey"))
        assertTrue(runCatching { journal.clearOwner(account, before, { it() }) { it() } }.isFailure)
    }

    @Test fun `uncertified installed selector is explicitly uncertain and cold authority requires durable exact intent`() {
        val store = Store(); val journal = store.journal()
        val initial = journal.ownerSelection(account, profile) { it() }
        val candidate = journal.storeVerified(journal.begin(account, profile, { it() },
            "owner:00000000-0000-0000-0000-000000000001"), "verified", "uid")
        store.failReadAfterSelectorWrite = true; store.rejectAfterSelectorWrite = true
        assertTrue(runCatching { journal.selectOwner(account, initial, candidate) { it() } }.exceptionOrNull() is NativeOwnerPublicationUncertain)
        assertTrue(runCatching { journal.ownerSelection(account, profile) { it() } }.isFailure)
        store.available = true
        val reopened = store.journal()
        val reconciled = reopened.ownerSelection(account, profile) { it() }
        assertEquals("verified", reopened.captureOwner(account, reconciled) { it() }!!.request(JSONObject()).getString("authKey"))
        store.records.keys.single { it.startsWith("owner-intent.") }.let(store.records::remove)
        assertTrue(runCatching { store.journal().ownerSelection(account, profile) { it() } }.isFailure)
    }

    @Test fun `owner selector failed write or retired admission cannot publish staged credentials`() {
        val store = Store(); val journal = store.journal(); var current = true
        val admission: (() -> Boolean) -> Boolean = { current && it() }
        val initial = journal.ownerSelection(account, profile, admission)
        val candidate = journal.storeVerified(journal.begin(account, profile, admission,
            "owner:00000000-0000-0000-0000-000000000001"), "verified", "uid")
        store.writes = false
        assertTrue(runCatching { journal.selectOwner(account, initial, candidate) { it() } }.isFailure)
        assertNull(journal.ownerSelection(account, profile, admission).verifiedUID)
        current = false
        assertTrue(runCatching { journal.captureOwner(account, initial, admission) }.isFailure)
    }

    @Test fun `production fail closed store poisoned after-effect reconciles intent only on fresh store`() {
        val records = mutableMapOf<String, String?>(); var afterEffect = false
        val backend = object : com.vortx.android.security.CredentialBackend {
            override fun string(key: String) = records[key]
            override fun write(values: Map<String, String?>): Boolean {
                records.putAll(values)
                return !(afterEffect && values.keys.any { it.startsWith("owner-selection.") })
            }
        }
        fun open(): NativeOwnAccountCredentials {
            val state = com.vortx.android.security.FailClosedCredentialState(backend, reopenBackend = { backend })
            return NativeOwnAccountCredentials({ state.confirmedSnapshot(it) }, { key, value -> state.write(mapOf(key to value)) })
        }
        val journal = open(); val initial = journal.ownerSelection(account, profile) { it() }
        val candidate = journal.storeVerified(journal.begin(account, profile, { it() },
            "owner:00000000-0000-0000-0000-000000000001"), "verified", "uid")
        afterEffect = true
        assertTrue(runCatching { journal.selectOwner(account, initial, candidate) { it() } }.exceptionOrNull() is NativeOwnerPublicationUncertain)
        assertTrue(runCatching { journal.ownerSelection(account, profile) { it() } }.isFailure)
        afterEffect = false
        val reopened = open(); val selection = reopened.ownerSelection(account, profile) { it() }
        assertEquals("verified", reopened.captureOwner(account, selection) { it() }!!.request(JSONObject()).getString("authKey"))
        reopened.clearOwner(account, selection, { it() }) { it() }
        val cleared = open(); val tombstone = cleared.ownerSelection(account, profile) { it() }
        assertNotNull(tombstone.raw); assertNull(tombstone.verifiedUID)
        assertNull(cleared.captureOwner(account, tombstone) { it() })
    }
}
