package com.vortx.android.ui

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

class DetailSettingsRevisionContractTest {
    @Test
    fun `phone tv and nested details are keyed by credential and source revisions`() {
        val phone = source("src/main/kotlin/com/vortx/android/ui/StremioXApp.kt")
        val tv = source("src/main/kotlin/com/vortx/android/ui/tv/TvApp.kt")
        val detail = source("src/main/kotlin/com/vortx/android/ui/screens/DetailScreen.kt")

        assertTrue(phone.contains("DebridKeys.credentialRevision.collectAsStateWithLifecycle()"))
        assertTrue(phone.contains("SourceSettingsRevision.observe(appContext).collectAsStateWithLifecycle()"))
        assertTrue(phone.contains("key = \"detail-${'$'}{current.id}-${'$'}detailSourceEpoch\""))
        assertTrue(tv.contains("key = \"tv-detail-${'$'}{current.id}-${'$'}detailSourceEpoch\""))
        assertTrue(detail.contains("detail-nested-${'$'}{target.id}-${'$'}nestedOwner:"))

        val revisions = source("src/main/kotlin/com/vortx/android/sources/SourceSettingsRevision.kt")
        assertTrue(revisions.contains("key == null || key in RESULT_KEYS"))
        assertTrue(revisions.contains("TrackPreferencesStore.KEY_AUDIO"))
    }

    @Test
    fun `cache evidence is bound to credential revision`() {
        val detail = source("src/main/kotlin/com/vortx/android/ui/viewmodel/DetailViewModel.kt")

        assertTrue(detail.contains("val credentialRevision: Long"))
        assertTrue(detail.contains("it.credentialRevision == credentialRevision"))
        assertTrue(detail.contains("debridKeys.currentCredentialRevision() != credentialRevision"))
    }

    @Test
    fun `detail source index and torbox share canonical episode identity`() {
        val detail = source("src/main/kotlin/com/vortx/android/ui/viewmodel/DetailViewModel.kt")
        val sourceIndex = source("src/main/kotlin/com/vortx/android/singularity/SourceIndexClient.kt")
        val torbox = source("src/main/kotlin/com/vortx/android/torbox/TorBoxSearchSource.kt")

        assertTrue(detail.contains("CanonicalContentIdentity.imdb(imdb, season, episodeNum)"))
        assertTrue(detail.contains("val season = if (type == MediaType.SERIES) ep?.season else null"))
        assertTrue(sourceIndex.contains("return CanonicalContentIdentity.imdb(imdbId, season, episode)"))
        assertTrue(torbox.contains("CanonicalContentIdentity.imdb(imdbId, season, episode)"))
    }

    private fun source(relative: String): String {
        val candidates = listOf(File(relative), File("app/$relative"), File("android/app/$relative"))
        return candidates.firstOrNull(File::isFile)?.readText()
            ?: error("Could not locate $relative from ${File(".").absolutePath}")
    }
}
