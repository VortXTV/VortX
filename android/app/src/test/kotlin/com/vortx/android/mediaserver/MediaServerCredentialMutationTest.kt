package com.vortx.android.mediaserver

import com.vortx.android.integrations.CredentialStoreAccess
import com.vortx.android.security.PersistentCredentialAvailability
import com.vortx.android.security.PersistentCredentialSnapshot
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MediaServerCredentialMutationTest {

    private val serverId = UUID.fromString("00000000-0000-0000-0000-000000000001")
    private val tokenKey = "server-token"
    private val backupKey = "server-add-backup"
    private val plexKey = "plex-account-token"

    @Test
    fun `rollback restart restores prior server and existing plex account tokens`() {
        val store = RecordingStore(
            initial = mapOf(
                tokenKey to "prior-server-secret",
                plexKey to "prior-account-secret",
            ),
        )
        var journals = listOf(
            MediaServerAddJournal(serverId, MediaServerAddDisposition.ROLLBACK),
        )
        val events = mutableListOf("journal:rollback")
        val preparation = prepareMediaServerAddCredentials(
            store = store,
            tokenKey = tokenKey,
            backupKey = backupKey,
            token = "replacement-server-secret",
            plexAccountTokenKey = plexKey,
            plexAccountToken = "replacement-account-secret",
        ) as MediaServerAddCredentialPreparation.Ready

        assertTrue(store.set(preparation.values).also { events += "credentials" })
        assertEquals(listOf("journal:rollback", "credentials"), events)
        assertEquals("replacement-server-secret", store.confirmedString(tokenKey))
        assertEquals("prior-account-secret", store.confirmedString(plexKey))
        assertTrue(store.confirmedString(backupKey)?.contains("prior-server-secret") == true)
        assertTrue(store.confirmedString(backupKey)?.contains("prior-account-secret") == true)
        val restarted = store.restart()

        val remaining = resumeMediaServerAddJournals(
            journals = journals,
            resolveCredentials = { journal ->
                resolveMediaServerAddCredentials(
                    store = restarted,
                    tokenKey = tokenKey,
                    backupKey = backupKey,
                    plexAccountTokenKey = plexKey,
                    disposition = journal.disposition,
                )
            },
            publishRemaining = {
                journals = it
                true
            },
        )

        assertTrue(remaining.isEmpty())
        assertTrue(journals.isEmpty())
        assertEquals("prior-server-secret", restarted.confirmedString(tokenKey))
        assertNull(restarted.confirmedString(backupKey))
        assertEquals("prior-account-secret", restarted.confirmedString(plexKey))
    }

    @Test
    fun `committed journal restart discards backup without rolling back connected token`() {
        val store = RecordingStore(initial = mapOf(tokenKey to "prior-server-secret"))
        val preparation = prepareMediaServerAddCredentials(
            store = store,
            tokenKey = tokenKey,
            backupKey = backupKey,
            token = "connected-server-secret",
            plexAccountTokenKey = plexKey,
            plexAccountToken = "account-secret",
        ) as MediaServerAddCredentialPreparation.Ready
        assertTrue(store.set(preparation.values))
        val committed = MediaServerAddJournal(serverId, MediaServerAddDisposition.COMMITTED)
        val restarted = store.restart()

        assertTrue(
            resumeMediaServerAddJournals(
                journals = listOf(committed),
                resolveCredentials = { journal ->
                    resolveMediaServerAddCredentials(
                        store = restarted,
                        tokenKey = tokenKey,
                        backupKey = backupKey,
                        plexAccountTokenKey = plexKey,
                        disposition = journal.disposition,
                    )
                },
                publishRemaining = { true },
            ).isEmpty(),
        )

        assertEquals("connected-server-secret", restarted.confirmedString(tokenKey))
        assertEquals("account-secret", restarted.confirmedString(plexKey))
        assertNull(restarted.confirmedString(backupKey))
    }

    @Test
    fun `rollback restart clears plex account token inserted by interrupted add`() {
        val store = RecordingStore()
        val preparation = prepareMediaServerAddCredentials(
            store = store,
            tokenKey = tokenKey,
            backupKey = backupKey,
            token = "new-server-secret",
            plexAccountTokenKey = plexKey,
            plexAccountToken = "new-account-secret",
        ) as MediaServerAddCredentialPreparation.Ready
        assertTrue(store.set(preparation.values))
        assertEquals("new-account-secret", store.confirmedString(plexKey))
        assertTrue(store.confirmedString(backupKey)?.contains("\"owned\":true") == true)
        val restarted = store.restart()

        assertTrue(
            resolveMediaServerAddCredentials(
                store = restarted,
                tokenKey = tokenKey,
                backupKey = backupKey,
                plexAccountTokenKey = plexKey,
                disposition = MediaServerAddDisposition.ROLLBACK,
            ),
        )

        assertNull(restarted.confirmedString(tokenKey))
        assertNull(restarted.confirmedString(plexKey))
        assertNull(restarted.confirmedString(backupKey))
    }

    @Test
    fun `rejected atomic credential mutation retains prior values for journal replay`() {
        val store = RecordingStore(initial = mapOf(tokenKey to "prior-server-secret")).apply {
            rejectWrites = true
        }
        val preparation = prepareMediaServerAddCredentials(
            store = store,
            tokenKey = tokenKey,
            backupKey = backupKey,
            token = "replacement-server-secret",
            plexAccountTokenKey = plexKey,
            plexAccountToken = null,
        ) as MediaServerAddCredentialPreparation.Ready

        assertFalse(store.set(preparation.values))
        assertEquals("prior-server-secret", store.confirmedString(tokenKey))
        assertNull(store.confirmedString(backupKey))

        store.rejectWrites = false
        assertTrue(
            resolveMediaServerAddCredentials(
                store = store,
                tokenKey = tokenKey,
                backupKey = backupKey,
                plexAccountTokenKey = plexKey,
                disposition = MediaServerAddDisposition.ROLLBACK,
            ),
        )
        assertEquals("prior-server-secret", store.confirmedString(tokenKey))
    }

    @Test
    fun `existing plex account token is never overwritten by a server add`() {
        val store = RecordingStore(initial = mapOf(plexKey to "prior-account-secret"))
        val preparation = prepareMediaServerAddCredentials(
            store = store,
            tokenKey = tokenKey,
            backupKey = backupKey,
            token = "server-secret",
            plexAccountTokenKey = plexKey,
            plexAccountToken = "replacement-account-secret",
        ) as MediaServerAddCredentialPreparation.Ready

        assertEquals(
            setOf(backupKey, tokenKey),
            preparation.values.keys,
        )
        assertTrue(store.set(preparation.values))
        assertEquals("prior-account-secret", store.confirmedString(plexKey))
    }

    @Test
    fun `legacy rollback backup leaves unrelated plex account token untouched`() {
        val store = RecordingStore(
            initial = mapOf(
                tokenKey to "interrupted-server-secret",
                backupKey to """{"present":false}""",
                plexKey to "unrelated-account-secret",
            ),
        )

        assertTrue(
            resolveMediaServerAddCredentials(
                store = store,
                tokenKey = tokenKey,
                backupKey = backupKey,
                plexAccountTokenKey = plexKey,
                disposition = MediaServerAddDisposition.ROLLBACK,
            ),
        )

        assertNull(store.confirmedString(tokenKey))
        assertNull(store.confirmedString(backupKey))
        assertEquals("unrelated-account-secret", store.confirmedString(plexKey))
    }

    @Test
    fun `unavailable credential snapshot cannot prepare a mutation`() {
        val store = RecordingStore().apply { readsAvailable = false }

        assertEquals(
            MediaServerAddCredentialPreparation.Unavailable,
            prepareMediaServerAddCredentials(
                store = store,
                tokenKey = tokenKey,
                backupKey = backupKey,
                token = "server-secret",
                plexAccountTokenKey = plexKey,
                plexAccountToken = "account-secret",
            ),
        )
        assertTrue(store.writeAttempts.isEmpty())
    }

    @Test
    fun `orphaned encrypted backup blocks overwrite until recovery resolves it`() {
        val store = RecordingStore(initial = mapOf(backupKey to """{"present":false}"""))

        assertEquals(
            MediaServerAddCredentialPreparation.RecoveryPending,
            prepareMediaServerAddCredentials(
                store = store,
                tokenKey = tokenKey,
                backupKey = backupKey,
                token = "server-secret",
                plexAccountTokenKey = plexKey,
                plexAccountToken = null,
            ),
        )
        assertTrue(store.writeAttempts.isEmpty())
    }

    private class RecordingStore(
        initial: Map<String, String> = emptyMap(),
    ) : CredentialStoreAccess {
        private val durable = initial.toMutableMap()
        val writeAttempts = mutableListOf<Map<String, String?>>()
        var rejectWrites = false
        var readsAvailable = true

        override fun string(key: String): String? = durable[key]

        override fun confirmedSnapshot(vararg keys: String): PersistentCredentialSnapshot =
            PersistentCredentialSnapshot(
                availability = if (readsAvailable) {
                    PersistentCredentialAvailability.AVAILABLE
                } else {
                    PersistentCredentialAvailability.UNAVAILABLE
                },
                values = keys.associateWith(durable::get),
            )

        override fun set(key: String, value: String?): Boolean = set(mapOf(key to value))

        override fun set(values: Map<String, String?>): Boolean {
            writeAttempts += LinkedHashMap(values)
            if (rejectWrites) return false
            values.forEach { (key, value) ->
                if (value == null) durable.remove(key) else durable[key] = value
            }
            return true
        }

        override fun clear(vararg keys: String): Boolean = set(keys.associateWith { null })

        fun restart(): RecordingStore = RecordingStore(durable)
    }
}
