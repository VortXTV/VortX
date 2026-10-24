package com.vortx.android.ui.randompick

import com.vortx.android.data.ContinueWatchingOwner
import com.vortx.android.model.MediaType
import com.vortx.android.profile.UserProfile
import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RandomTitlePlayRequestTest {
    private val profile = UserProfile(id = "profile-a", name = "Viewer", avatar = "ember", pin = "hashed-pin")
    private val owner = ContinueWatchingOwner("profile-a", "slot-a", "principal-a", true, 7L)
    private val request = RandomTitlePlayRequest(MediaType.SERIES, "tt123", owner, profile, 5L)

    private fun accepts(
        value: RandomTitlePlayRequest = request,
        currentOwner: ContinueWatchingOwner = owner,
        currentProfile: UserProfile? = profile,
        needsPicker: Boolean = false,
        type: MediaType? = MediaType.SERIES,
        id: String? = "tt123",
        generation: Long = 5L,
    ) = value.isCurrent(currentOwner, currentProfile, needsPicker, type, id, generation)

    @Test fun `only exact live route is admitted`() {
        assertTrue(accepts())
        assertFalse(accepts(type = MediaType.MOVIE))
        assertFalse(accepts(id = "tt456"))
        assertFalse(accepts(type = null, id = null))
        assertFalse(accepts(generation = 6L))
        assertFalse(accepts(value = request.copy(id = ""), id = ""))
        assertFalse(accepts(value = request.copy(type = MediaType.CHANNEL), type = MediaType.CHANNEL))
    }

    @Test fun `every owner field including ABA revision must still match`() {
        assertFalse(accepts(currentOwner = owner.copy(profileId = "profile-b")))
        assertFalse(accepts(currentOwner = owner.copy(accountSlot = "slot-b")))
        assertFalse(accepts(currentOwner = owner.copy(principal = "principal-b")))
        assertFalse(accepts(currentOwner = owner.copy(usesEngineHistory = false)))
        assertFalse(accepts(currentOwner = owner.copy(revision = 8L)))
    }

    @Test fun `actual whole profile and completed picker are required`() {
        assertFalse(accepts(currentProfile = null))
        assertFalse(accepts(needsPicker = true))
        assertFalse(accepts(currentProfile = profile.copy(id = "profile-b")))
        assertFalse(accepts(currentProfile = profile.copy(isKids = true)))
        assertFalse(accepts(currentProfile = profile.copy(pin = "changed-pin")))
        assertFalse(accepts(currentProfile = profile.copy(name = "Edited viewer")))
        val mismatched = owner.copy(profileId = UserProfile.OWNER_ID)
        assertFalse(accepts(value = request.copy(owner = mismatched), currentOwner = mismatched))
    }

    @Test fun `consumption retains resolve authority without changing its captured identity`() {
        assertTrue(accepts(value = request.copy(consumed = true)))
        assertFalse(accepts(value = request.copy(consumed = true), currentProfile = profile.copy(isKids = true)))
        assertTrue(request.sameIntent(request.copy(consumed = true)))
        assertFalse(request.sameIntent(null))
        assertFalse(request.sameIntent(request.copy(detailGeneration = 6L)))
        assertFalse(request.sameIntent(request.copy(owner = owner.copy(revision = 8L))))
    }

    @Test fun `manual cancellation gates the action and keeps the current detail`() {
        val source = tvSource()
        assertTrue(source.contains("onAutoWatchCancelled = {"))
        val callback = source.substringAfter("onAutoWatchCancelled = {")
            .substringBefore("// A Person-page filmography")
        assertTrue(callback.contains("val request = libraryPlayRequest"))
        assertTrue(callback.contains("val admitted = detailGeneration == routeGeneration"))
        assertTrue(callback.contains("request.sameIntent(pendingLibraryPlay) && isLibraryPlayCurrent(request)"))
        assertTrue(callback.contains("pendingLibraryPlay = null"))
        assertTrue(callback.contains("detailVm.abandonPlaybackRoute()"))
        assertTrue(callback.contains("admitted"))
        assertFalse(callback.contains("retireLibraryPlayRoute()"))
        assertFalse(callback.contains("detail ="))
        assertFalse(callback.contains("detailGeneration +="))
    }

    @Test fun `obsolete TV consumption cannot consume or retire a replacement intent`() {
        val source = tvSource()
        assertTrue(consumptionIsBound(source))
        assertFalse(consumptionIsBound(source.replace("request.sameIntent(pendingLibraryPlay) &&", "")))
        assertFalse(consumptionIsBound(source.replace("routeGeneration == detailGeneration &&", "")))
        assertFalse(consumptionIsBound(source.replace("pendingLibraryPlay?.consumed != false", "false")))
        assertFalse(consumptionIsBound(source.replace("val request = libraryPlayRequest", "val request = pendingLibraryPlay")))
    }

    private fun consumptionIsBound(source: String): Boolean {
        val callback = source.substringAfter("onAutoWatchConsumed = {", "")
            .substringBefore("onAutoWatchCancelled = {")
        val guard = callback.substringBefore("if (!ownsRoute || request == null || pendingLibraryPlay?.consumed != false)")
        val rejection = callback.substringAfter(
            "if (!ownsRoute || request == null || pendingLibraryPlay?.consumed != false) {", "",
        ).substringBefore("} else {")
        return guard.contains("val request = libraryPlayRequest") &&
            guard.contains("request.sameIntent(pendingLibraryPlay) &&") &&
            guard.contains("routeGeneration == detailGeneration &&") &&
            guard.contains("detail?.type == current.type && detail?.id == current.id") &&
            rejection.contains("false") && !rejection.contains("pendingLibraryPlay =") &&
            !rejection.contains("retireLibraryPlayRoute()") && !rejection.contains("abandonPlaybackRoute()")
    }

    private fun tvSource(): String = listOf(
            File("src/main/kotlin/com/vortx/android/ui/tv/TvApp.kt"),
            File("app/src/main/kotlin/com/vortx/android/ui/tv/TvApp.kt"),
            File("android/app/src/main/kotlin/com/vortx/android/ui/tv/TvApp.kt"),
        ).firstOrNull(File::isFile)?.readText() ?: error("Could not locate TvApp.kt")
}
