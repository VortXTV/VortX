package com.vortx.android.profile

import java.io.File
import org.junit.Assert.*
import org.junit.Test

/** Source wiring audit complements coordinator tests when a Compose runtime is unavailable. */
class ProfileSelectionWiringTest {
    private fun source(path: String): String = listOf("src/main/kotlin", "app/src/main/kotlin", "android/app/src/main/kotlin")
        .map { File("$it/com/vortx/android/$path") }.first(File::isFile).readText()

    @Test fun `both cold hosts gate content on typed completion and return Back to picker`() {
        val phone = source("ui/VortXApp.kt")
        val tv = source("ui/tv/TvApp.kt")
        assertTrue(phone.contains("WhosWatchingScreen(onDone = { showWhosWatching = false }, onSelected = { profileSelection = it })"))
        assertTrue(tv.contains("TvWhosWatching(onDone = { showPicker = false }, onSelected = { profileSelection = it })"))
        for (host in listOf(phone, tv)) {
            val selection = host.substringAfter("profileSelection?.let { request ->").substringBefore("// The title currently")
            assertTrue(selection.contains("ProfileSelectionSurface(request, handoff,"))
            assertTrue(selection.contains("return@VortXTheme"))
            assertTrue(selection.contains("onChooseAgain = { profileSelection = null; show"))
        }
        val surface = source("ui/profilepicker/ProfileSelectionSurface.kt")
        assertTrue(surface.contains("handoff.complete(request)) onComplete()"))
        assertTrue(surface.contains("BackHandler(onBack = onChooseAgain)"))
        assertTrue(surface.contains("handoff.signIn(request, email, password)"))
    }

    @Test fun `settings selections preserve typed result to the same host`() {
        assertTrue(source("ui/VortXApp.kt").contains("ProfilesScreen(onBack = { showProfiles = false }, onSelected = { profileSelection = it })"))
        assertTrue(source("ui/tv/TvShell.kt").contains("onProfileSelected = onProfileSelected"))
        assertTrue(source("ui/tv/TvSettingsScreen.kt").contains("onSelected = onProfileSelected"))
        val gateway = source("ui/tv/TvProfilesScreen.kt")
        assertTrue(gateway.contains("Result<ProfileSelectionRequest>"))
        assertTrue(gateway.contains("captureProfileSelection(store, profile, outcome,"))
        assertTrue(gateway.contains("gateway.select(profile, captured).fold(onSuccess = onSelected"))
        assertFalse(gateway.contains("The current account session remains in use"))
    }

    @Test fun `pending selection survives composition recreation without bypassing native authority`() {
        assertTrue(source("profile/ProfileStore.kt").contains("selectionPending || (profiles.size > 1 && !pickedThisLaunch)"))
        val request = source("profile/ProfileSelectionRequest.kt")
        assertTrue(request.contains("store.selectionPending = true"))
        assertTrue(request.contains("store.selectionPending = false"))
        assertTrue(request.contains("checkNotNull(nativeAdmission)"))
        assertTrue(request.contains("nativeAdmission?.invoke() != false"))
    }
}
