package com.vortx.android.trickplay

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CommunityTrickplayConsentContractTest {

    @Test
    fun `phone setting persists the shared consent and gates capture work`() {
        val phoneSettings = projectFile("src/main/kotlin/com/vortx/android/ui/screens/PlaybackSettingsScreen.kt")
        val preference = projectFile("src/main/kotlin/com/vortx/android/trickplay/CommunityTrickplay.kt")
        val session = projectFile("src/main/kotlin/com/vortx/android/trickplay/TrickplaySession.kt")

        assertTrue(phoneSettings.contains("label = \"Community scrub previews\""))
        assertTrue(phoneSettings.contains("footer = \"Share anonymized scrub previews so titles get instant thumbnails for everyone.\""))
        assertTrue(phoneSettings.contains("mutableStateOf(CommunityTrickplay.isEnabled(appContext))"))
        assertTrue(phoneSettings.contains("CommunityTrickplay.setEnabled(appContext, it)"))

        assertTrue(preference.contains("const val SETTING_KEY = \"stremiox.communityTrickplay\""))
        assertTrue(preference.contains("if (!prefs.contains(SETTING_KEY)) return true"))
        assertTrue(preference.contains(".putBoolean(SETTING_KEY, enabled)"))

        assertTrue(session.contains("fun configure(mediaRef: MediaRef?, durationSeconds: Double) {\n        if (!CommunityTrickplay.isEnabled(context)) return"))
        assertTrue(session.contains("fun recordFrame(jpeg: ByteArray, timeSeconds: Double, videoHeight: Int) {\n        if (!CommunityTrickplay.isEnabled(context)) return"))
        assertTrue(session.contains("admissionQueue.enqueue {\n            if (!contributionIsCurrent(generation)) return@enqueue"))
        assertTrue(session.contains("private fun uploadDecision(progressive: Boolean, generation: Long): PendingUpload? {\n        if (!contributionIsCurrent(generation)) return null"))
        assertTrue(session.contains("activeRequests.forEach(CommunityTrickplayRequestControl::cancel)"))
        assertTrue(session.contains("scope.coroutineContext.cancelChildren()"))
        assertTrue(session.contains("canContribute = { contributionIsCurrent(push.consentGeneration) }"))
        assertTrue(session.contains("CommunityTrickplay.fetch(key, requestControl)"))
        assertFalse(phoneSettings.contains("CommunityTrickplay.setEnabled(appContext, !it)"))
    }

    private fun projectFile(relativePath: String): String {
        val candidates = listOf(File(relativePath), File("app/$relativePath"), File("android/app/$relativePath"))
        return candidates.firstOrNull(File::isFile)?.readText()
            ?: error("Could not locate $relativePath from ${File(".").absolutePath}")
    }
}
