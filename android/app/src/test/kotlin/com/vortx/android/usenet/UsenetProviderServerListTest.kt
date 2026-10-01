package com.vortx.android.usenet

import com.vortx.android.debrid.DebridOwnerScope
import com.vortx.android.debrid.DebridOwnerToken
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class UsenetProviderServerListTest {
    @Test fun `owner transaction serializes concurrent snapshot and save without lock inversion`() {
        val credentialOwnerLock = Any()
        val documentLock = Any()
        val owner = DebridOwnerToken(DebridOwnerScope.SignedOutLocal, generation = 7)
        val start = CountDownLatch(2)
        val complete = CountDownLatch(2)
        val mutate: (DebridOwnerToken, () -> Boolean) -> Boolean = { _, mutation ->
            synchronized(credentialOwnerLock) { mutation() }
        }
        val operation = { label: String ->
            Thread {
                start.countDown()
                start.await()
                assertEquals(
                    label,
                    UsenetProviderOwnerTransaction.run(
                        owner = owner,
                        mutateCurrentOwner = mutate,
                        storeLock = documentLock,
                        rejected = { "rejected" },
                        operation = { label },
                    ),
                )
                complete.countDown()
            }.apply { isDaemon = true; start() }
        }

        operation("snapshot")
        operation("save")
        assertTrue("owner-then-document operations deadlocked", complete.await(2, TimeUnit.SECONDS))
    }

    @Test fun `legacy single credential migrates into stable server list`() {
        val legacy = credentials("one.example").toJson().toString()
        val decoded = requireNotNull(UsenetProviderServerList.decode(legacy))
        assertEquals(UsenetProviderServerList.CURRENT_VERSION, decoded.version)
        assertEquals(listOf(UsenetProviderServer.LEGACY_ID), decoded.servers.map { it.id })
        assertEquals("one.example", decoded.firstEnabledCredentials?.host)
    }

    @Test fun `versioned document preserves priority ids enabled state and secrets on round trip`() {
        val original = UsenetProviderServerList(servers = listOf(server("first"), server("second", enabled = false)))
        val decoded = requireNotNull(UsenetProviderServerList.decode(original.toJson().toString()))
        assertEquals(original, decoded)
        assertEquals(listOf("first"), decoded.enabledServers.map { it.id })
        assertFalse(decoded.toJson().toString().contains("<redacted>"))
    }

    @Test fun `edit keeps stable identity and adjacent fallbacks`() {
        val first = server("first")
        val second = server("second")
        val saved = UsenetProviderServerList(servers = listOf(first, second))
        val edited = saved.copy(servers = saved.servers.map { server ->
            if (server.id == first.id) server.copy(name = "Renamed", host = "renamed.example") else server
        })
        assertEquals(listOf("first", "second"), edited.servers.map { it.id })
        assertEquals("secret-first", edited.servers.first().password)
    }

    @Test fun `nonempty corrupt or unsupported version never decodes as empty`() {
        assertEquals(null, UsenetProviderServerList.decode("not json"))
        assertEquals(null, UsenetProviderServerList.decode("""{"version":99,"servers":[]}"""))
        assertEquals(null, UsenetProviderServerList.decode("""{"version":2,"servers":[{"id":"x"}]}"""))
        assertEquals(null, UsenetProviderServerList.decode("{}"))
    }

    @Test fun `strict document rejects duplicate ids and invalid disabled records`() {
        val duplicate = UsenetProviderServerList(servers = listOf(server("same"), server("same", host = "two.example")))
        assertFalse(UsenetProviderServerList.isValid(duplicate))
        val invalidDisabled = server("off", enabled = false).copy(host = "https://not-a-host")
        assertFalse(UsenetProviderServerList.isValid(UsenetProviderServerList(servers = listOf(invalidDisabled))))
    }

    @Test fun `fallback tries enabled priority then second server and leaves cloud to caller`() = runTest {
        val attempts = mutableListOf<String>()
        val result = UsenetProviderFallbackPolicy.firstReady(
            servers = listOf(server("first"), server("disabled", enabled = false), server("second")),
            stillCurrent = { true },
        ) { candidate ->
            attempts += candidate.id
            if (candidate.id == "first") error("first unavailable")
            "native-prefix"
        }
        assertEquals("native-prefix", result)
        assertEquals(listOf("first", "second"), attempts)
    }

    @Test fun `owner or config switch cancels instead of accepting stale server result`() = runTest {
        var current = true
        val failure = assertThrows(CancellationException::class.java) {
            kotlinx.coroutines.runBlocking {
                UsenetProviderFallbackPolicy.firstReady(listOf(server("only")), { current }) {
                    current = false
                    "late-result"
                }
            }
        }
        assertTrue(failure.message.orEmpty().contains("changed"))
    }

    @Test fun `all disabled has meaningful typed readiness failure`() = runTest {
        assertThrows(UsenetProviderFallbackPolicy.NoEnabledProviders::class.java) {
            kotlinx.coroutines.runBlocking {
                UsenetProviderFallbackPolicy.firstReady(listOf(server("off", enabled = false)), { true }) { "never" }
            }
        }
    }

    private fun credentials(host: String) = UsenetProviderCredentials(host, 563, "user", "secret", 4, true)
    private fun server(id: String, host: String = "$id.example", enabled: Boolean = true) = UsenetProviderServer(
        id = id, name = id, host = host, port = 563, username = "user-$id", password = "secret-$id",
        maxConnections = 4, useSSL = true, enabled = enabled,
    )
}
