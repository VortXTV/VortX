package com.vortx.android.mediaserver

import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class PlexPinLinkContractTest {
    @Test fun `manual link flow requests a short code rather than browser auth code`() {
        val path = "src/main/kotlin/com/vortx/android/mediaserver/PlexClient.kt"
        val source = listOf(File(path), File("app/$path"), File("android/app/$path"))
            .first(File::isFile).readText()
        val request = source.substringAfter("suspend fun requestPin(").substringBefore("suspend fun pollForToken(")
        assertTrue(request.contains("?strong=false"))
        assertTrue(!request.contains("?strong=true"))
        assertTrue(request.contains("headers = headers(clientId)"))
        assertTrue(source.contains("suspend fun pollForToken("))
    }
}
