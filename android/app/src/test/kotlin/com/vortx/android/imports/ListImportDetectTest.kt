package com.vortx.android.imports

import com.vortx.android.home.ImportedListProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Locks the SSRF-safe URL parsing of [ListImport.detect] (the Android port of Apple `ListImport.detect`): the
 * host is re-asserted from the recognized provider and never trusted from the pasted string, and each path
 * segment is validated. A link that is not a recognized public-list URL, or whose host merely embeds a
 * provider name, returns null so the fetch can never be pointed at an arbitrary host.
 */
class ListImportDetectTest {

    @Test
    fun `letterboxd public list is detected with a fixed host`() {
        val d = ListImport.detect("https://letterboxd.com/dave/list/official-top-250/")
        assertEquals(ImportedListProvider.LETTERBOXD, d?.provider)
        assertEquals("dave", d?.user)
        assertEquals("official-top-250", d?.slug)
        assertEquals("https://letterboxd.com/dave/list/official-top-250/", d?.canonicalUrl)
        assertEquals("imported:letterboxd:dave:official-top-250", d?.let(ListImport::stableId))
    }

    @Test
    fun `mdblist public list is detected`() {
        val d = ListImport.detect("mdblist.com/lists/linaspurinis/top-watched-movies-of-the-week")
        assertEquals(ImportedListProvider.MDBLIST, d?.provider)
        assertEquals("linaspurinis", d?.user)
        assertEquals("top-watched-movies-of-the-week", d?.slug)
    }

    @Test
    fun `trakt user list and short list forms are detected`() {
        val user = ListImport.detect("https://trakt.tv/users/me/lists/marvel")
        assertEquals(ImportedListProvider.TRAKT, user?.provider)
        assertEquals("me", user?.user)
        assertEquals("marvel", user?.slug)

        val short = ListImport.detect("https://trakt.tv/lists/12345")
        assertEquals(ImportedListProvider.TRAKT, short?.provider)
        assertEquals("", short?.user)
        assertEquals("12345", short?.slug)
    }

    @Test
    fun `www prefix is stripped and host still re-asserted`() {
        val d = ListImport.detect("https://www.letterboxd.com/dave/list/top/")
        assertEquals(ImportedListProvider.LETTERBOXD, d?.provider)
        assertEquals("https://letterboxd.com/dave/list/top/", d?.canonicalUrl)
    }

    @Test
    fun `a lookalike host that only embeds a provider name is rejected`() {
        assertNull(ListImport.detect("https://letterboxd.com.evil.example/dave/list/top/"))
        assertNull(ListImport.detect("https://evil.example/letterboxd.com/dave/list/top/"))
    }

    @Test
    fun `unknown host and private address host are rejected`() {
        assertNull(ListImport.detect("https://attacker.example/lists/me/x"))
        assertNull(ListImport.detect("http://127.0.0.1/lists/me/x"))
        assertNull(ListImport.detect("http://169.254.169.254/lists/me/x"))
    }

    @Test
    fun `path traversal and empty segments are rejected`() {
        assertNull(ListImport.detect("https://letterboxd.com/../list/x/"))
        assertNull(ListImport.detect("https://letterboxd.com/dave/list/"))
        assertNull(ListImport.detect("not a url at all"))
    }

    @Test
    fun `helpers normalize ids and humanize slugs`() {
        assertEquals("tt0111161", ListImport.normalizedTt(" tt0111161 "))
        assertNull(ListImport.normalizedTt("tt"))
        assertNull(ListImport.normalizedTt("tt12ab"))
        assertEquals("Official Top 250", ListImport.humanize("official-top-250"))
        assertEquals("Imported list", ListImport.humanize(""))
    }
}
