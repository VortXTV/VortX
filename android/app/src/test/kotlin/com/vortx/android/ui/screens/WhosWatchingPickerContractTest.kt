package com.vortx.android.ui.screens

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Focused source contract for the launch picker route. The actual Compose route is exercised in the
 * combined Android batch; these assertions keep the security-sensitive branches reviewable in the fast
 * JVM lane without constructing the process-wide ProfileStore singleton.
 */
class WhosWatchingPickerContractTest {

    @Test
    fun `phone picker exposes typed outcome and keeps add edit on the shared editor`() {
        val source = readSource("WhosWatchingScreen.kt")

        assertTrue(source.contains("onSelected: (ProfileSelectionRequest) -> Unit"))
        assertTrue(source.contains("ProfilePickerEditorRoute("))
        assertTrue(source.contains("PhonePickerTile.Action(\"add\", \"Add\")"))
        assertTrue(source.contains("PhonePickerTile.Action(\"edit\", \"Edit\")"))
        assertTrue(source.contains("isNew = true"))
        assertTrue(source.contains("openEditor(current, isNew = false)"))
    }

    @Test
    fun `every phone profile including active is pin gated and stale unlock is rejected`() {
        val source = readSource("WhosWatchingScreen.kt")

        assertTrue(source.contains("requestPin(profile, PickerPinPurpose.Select)"))
        assertTrue(source.contains("requestPin(active, PickerPinPurpose.Edit)"))
        assertTrue(source.contains("store.profiles === expected.roster"))
        assertTrue(source.contains("current === expected.profile && current == expected.profile"))
        assertTrue(source.contains("ContinueWatchingOwnerGate.serialized { revision ->"))
        assertTrue(source.contains("it === target.profile && it == target.profile"))
    }

    @Test
    fun `phone pin panel consumes touches and native selection carries admission witness`() {
        val source = readSource("WhosWatchingScreen.kt")

        assertTrue(source.contains("WhosWatchingBackHandler("))
        assertTrue(source.contains("pinVisible = pinTarget != null"))
        assertTrue(source.contains("editorVisible = editorRequest != null"))
        assertTrue(source.contains("pinVisible -> onCancelPin()"))
        assertTrue(source.contains("editorVisible -> onCancelEditor()"))
        assertTrue(source.contains(".clickable(onClick = {}) // consume panel taps"))
        assertTrue(source.contains("nativeModel?.captureSelection(selected)"))
        assertTrue(source.contains("nativeModel?.commitEditor(captured) {} == true"))
        assertTrue(source.contains("captureProfileSelection(store, profile, outcome, nativeAdmission = nativeAdmission)"))
        assertTrue(source.contains("catch (cancelled: CancellationException)"))
        assertTrue(source.contains("throw cancelled"))
    }

    @Test
    fun `settings profile switch emits the same typed request through existing admission`() {
        val source = readSource("ProfilesScreen.kt")

        assertTrue(source.contains("onSelected: (ProfileSelectionRequest) -> Unit"))
        assertTrue(source.contains("onSelected(captureProfileSelection(store, profile, outcome))"))
        assertTrue(source.contains("onSelected(captureProfileSelection(store, profile, outcome, nativeAdmission = nativeAdmission))"))
        assertTrue(source.contains("val after = checkNotNull(nativeModel?.captureSelection(selected))"))
        assertTrue(source.contains("catch (cancelled: CancellationException)"))
        assertTrue(source.contains("throw cancelled"))
    }

    @Test
    fun `legacy settings pin and editor save use the actual owner gate admission`() {
        val source = readSource("ProfilesScreen.kt")

        assertTrue(source.contains("private data class LegacyProfileAdmission"))
        assertTrue(source.contains("store.profiles === roster"))
        assertTrue(source.contains("store.activeID == activeID"))
        assertTrue(source.contains("current === profile && current == profile"))
        assertTrue(source.contains("if (!witnessMatches || !targetMatches) false else"))
        assertTrue(source.contains("action()"))
        assertTrue(source.contains("legacyAdmission?.commit(store)"))
        assertTrue(source.contains("ProfilesPinRequest(profile, captured, legacyAdmission)"))
        assertTrue(source.contains("The profile changed. Reopen the editor before trying again."))
    }

    @Test
    fun `tv active edit carries a pre-pin selection admission and validates it without selecting`() {
        val source = readTvSource()

        assertTrue(source.contains("val snapshot = gateway.read()"))
        assertTrue(source.contains("val roster = snapshot.profiles"))
        assertTrue(source.contains("val activeId = snapshot.activeID"))
        assertTrue(source.contains("data class Edit(val profile: UserProfile, val admission: TvProfileGateway.Admission)"))
        assertTrue(source.contains("val admission = gateway.capture(active, selection = true)"))
        assertTrue(source.contains("if (!admission.commit { })"))
        assertTrue(source.contains("openEditAfterUnlock(pending.profile, pending.admission)"))
        assertTrue(source.contains("catch (_: Exception)"))
    }

    private fun readSource(fileName: String): String {
        val candidates = listOf(
            File("src/main/kotlin/com/vortx/android/ui/screens/$fileName"),
            File("app/src/main/kotlin/com/vortx/android/ui/screens/$fileName"),
            File("android/app/src/main/kotlin/com/vortx/android/ui/screens/$fileName"),
        )
        return candidates.firstOrNull(File::isFile)?.readText()
            ?: error("Could not locate $fileName from ${File(".").absolutePath}")
    }

    private fun readTvSource(): String {
        val candidates = listOf(
            File("src/main/kotlin/com/vortx/android/ui/tv/TvWhosWatchingScreen.kt"),
            File("app/src/main/kotlin/com/vortx/android/ui/tv/TvWhosWatchingScreen.kt"),
            File("android/app/src/main/kotlin/com/vortx/android/ui/tv/TvWhosWatchingScreen.kt"),
        )
        return candidates.firstOrNull(File::isFile)?.readText()
            ?: error("Could not locate TvWhosWatchingScreen.kt from ${File(".").absolutePath}")
    }
}
