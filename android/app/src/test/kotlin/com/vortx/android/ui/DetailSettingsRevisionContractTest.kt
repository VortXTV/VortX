package com.vortx.android.ui

import java.io.File
import com.vortx.android.profile.ProfileStore
import com.vortx.android.sources.SourcePinStore
import com.vortx.android.sources.SourceSettingsRevision
import org.junit.Assert.assertTrue
import org.junit.Test

class DetailSettingsRevisionContractTest {
    @Test
    fun `phone tv and nested details are keyed by credential and source revisions`() {
        val phone = source("src/main/kotlin/com/vortx/android/ui/VortXApp.kt")
        val tv = source("src/main/kotlin/com/vortx/android/ui/tv/TvApp.kt")
        val detail = source("src/main/kotlin/com/vortx/android/ui/screens/DetailScreen.kt")

        assertTrue(phone.contains("DebridKeys.credentialRevision.collectAsStateWithLifecycle()"))
        assertTrue(phone.contains("SourceSettingsRevision.observe(appContext).collectAsStateWithLifecycle()"))
        assertTrue(phone.contains("rememberReplacingViewModelStoreOwner"))
        assertTrue(phone.contains("viewModelStoreOwner = detailVmOwner"))
        assertTrue(tv.contains("rememberReplacingViewModelStoreOwner"))
        assertTrue(tv.contains("viewModelStoreOwner = detailVmOwner"))
        assertTrue(detail.contains("rememberReplacingViewModelStoreOwner"))
        assertTrue(detail.contains("viewModelStoreOwner = nestedVmOwner"))

        val boundedOwner = source("src/main/kotlin/com/vortx/android/ui/viewmodel/ReplacingViewModelStoreOwner.kt")
        assertTrue(boundedOwner.contains("remember(generation)"))
        assertTrue(boundedOwner.contains("override fun onForgotten() = clear()"))
        assertTrue(boundedOwner.contains("override fun onAbandoned() = clear()"))

        val revisions = source("src/main/kotlin/com/vortx/android/sources/SourceSettingsRevision.kt")
        assertTrue(revisions.contains("affectsSourceResults(key)"))
        assertTrue(revisions.contains("TrackPreferencesStore.KEY_AUDIO"))
    }

    @Test
    fun `profile safety and per-profile pin mutations invalidate source results`() {
        assertTrue(SourceSettingsRevision.affectsSourceResults(ProfileStore.ACTIVE_PROFILE_KEY))
        assertTrue(SourceSettingsRevision.affectsSourceResults(ProfileStore.ACTIVE_DISABLED_ADDONS_KEY))
        assertTrue(SourceSettingsRevision.affectsSourceResults(ProfileStore.ACTIVE_KIDS_KEY))
        assertTrue(SourceSettingsRevision.affectsSourceResults(SourcePinStore.preferenceKey("profile-a")))

        val detail = source("src/main/kotlin/com/vortx/android/ui/viewmodel/DetailViewModel.kt")
        assertTrue(detail.contains("SourcePinStore(app) {"))
        assertTrue(detail.contains("ProfileStore.sharedOrNull()?.activeProfileId"))
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
