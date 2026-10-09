package com.vortx.android.integrations

import org.junit.Assert.*
import org.junit.Test

class SimklReadQueryTest {
    private val required = "client_id=fixture&app-name=VortX&app-version=1"
    @Test fun `path-only read keeps mandatory authentication metadata`() {
        assertEquals("/sync/activities?$required", simklSessionQueryPath("/sync/activities", required))
    }
    @Test fun `typed existing query is escaped once and mandatory metadata uses ampersand`() {
        val path = simklReadPath("/sync/all-items", mapOf("date_from" to "2026-10-09T10:20:30+02:00", "next_watch_info" to "yes"))
        assertEquals("/sync/all-items?date_from=2026-10-09T10%3A20%3A30%2B02%3A00&next_watch_info=yes&$required", simklSessionQueryPath(path, required))
    }
    @Test fun `reserved authentication overrides fragments and malformed queries reject`() {
        listOf("/sync/activities?client_id=other", "/sync/activities?client%5Fid=other", "/sync/activities#fragment",
            "/sync/activities?", "/sync/activities?limit=2?limit=3", "/sync/playback?limit=2&limit=3", "//other.example/sync/activities").forEach { path ->
            assertTrue(path, runCatching { simklSessionQueryPath(path, required) }.isFailure)
        }
        assertTrue(runCatching { simklReadPath("/sync/all-items", mapOf("client_id" to "other")) }.isFailure)
    }
}
