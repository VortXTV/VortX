package com.vortx.android.ui.tv

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TvSettingsSemanticsContractTest {
    @Test
    fun `option and toggle rows expose one merged control with role and state`() {
        val source = readProjectFile("src/main/kotlin/com/vortx/android/ui/tv/TvSettingsScreen.kt")

        assertTrue(settingsControlSemanticsContract(source))
        assertFalse(settingsControlSemanticsContract(source.replace("role = Role.RadioButton", "")))
        assertFalse(settingsControlSemanticsContract(source.replace("this.selected = selected", "")))
        assertFalse(settingsControlSemanticsContract(source.replace("role = Role.Switch", "")))
        assertFalse(settingsControlSemanticsContract(source.replace("toggleableState = if (checked)", "if (checked)")))
        assertFalse(settingsControlSemanticsContract(source.replace("mergeDescendants = true", "mergeDescendants = false")))
    }

    private fun settingsControlSemanticsContract(source: String): Boolean =
        hasAtLeastTwoMergedControls(source) &&
            source.contains("role = Role.RadioButton") &&
            source.contains("this.selected = selected") &&
            source.contains("role = Role.Switch") &&
            source.contains("toggleableState = if (checked) ToggleableState.On else ToggleableState.Off") &&
            source.contains("RadioButton(\n                selected = selected,\n                onClick = null") &&
            source.contains("Switch(\n                checked = checked,\n                onCheckedChange = null")

    private fun hasAtLeastTwoMergedControls(source: String): Boolean {
        val token = "mergeDescendants = true"
        val first = source.indexOf(token)
        return first >= 0 && source.indexOf(token, first + token.length) >= 0
    }

    private fun readProjectFile(relativePath: String): String {
        val candidates = listOf(File(relativePath), File("app/$relativePath"), File("android/app/$relativePath"))
        return candidates.firstOrNull(File::isFile)?.readText()
            ?: error("Could not locate $relativePath from ${File(".").absolutePath}")
    }
}
