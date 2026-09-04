package com.vortx.android.usenet

import java.io.ByteArrayInputStream
import java.net.InetAddress
import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Test

class NzbFetchPolicyTest {
    private val public = arrayOf(InetAddress.getByName("8.8.8.8"))
    private val loopback = arrayOf(InetAddress.getByName("127.0.0.1"))

    @Test fun `rejects non HTTPS and userinfo`() {
        rejected { NzbFetchPolicy.checkedUrl("http://example.test/a", { public }) }
        rejected { NzbFetchPolicy.checkedUrl("https://user:secret@example.test/a", { public }) }
    }

    @Test fun `rejects private initial and redirect hosts`() {
        rejected { NzbFetchPolicy.checkedUrl("https://example.test/a", { loopback }) }
        rejected { NzbFetchPolicy.redirect(java.net.URL("https://example.test/a"), "https://private.test/b", { loopback }) }
    }

    @Test fun `redirect is revalidated and HTTPS public URL passes`() {
        assertEquals("https://next.test/b", NzbFetchPolicy.redirect(java.net.URL("https://example.test/a"), "https://next.test/b", { public }).toString())
    }

    @Test fun `bounded read rejects oversized input`() {
        rejected { NzbFetchPolicy.readBoundedUtf8(ByteArrayInputStream(ByteArray(5)), limit = 4) }
    }

    private fun rejected(block: () -> Unit) {
        try { block(); fail("expected fetch policy rejection") } catch (_: UsenetLocalResolver.ResolveException) { }
    }
}
