package com.vortx.android.ui.tv

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TvAddonsContractTest {
    @Test
    fun `TV settings routes to add-ons and Back restores the settings target`() {
        assertEquals(TvSettingsRoute.ROOT, TvSettingsRoute.ADDONS.back())
        assertEquals(TvAddonsFocusTarget.BACK, tvAddonsFocusTarget(TvAddonsFocusEvent.SCREEN_ENTRY))
        assertEquals(
            TvAddonsFocusTarget.SETTINGS_ADDONS,
            tvAddonsFocusTarget(TvAddonsFocusEvent.BACK_TO_SETTINGS),
        )
    }

    @Test
    fun `TV route passes one shared AddonsViewModel into the add-ons surface`() {
        val shell = readProjectFile("src/main/kotlin/com/vortx/android/ui/tv/TvShell.kt")
        val settings = readProjectFile("src/main/kotlin/com/vortx/android/ui/tv/TvSettingsScreen.kt")
        val addons = readProjectFile("src/main/kotlin/com/vortx/android/ui/tv/TvAddonsScreen.kt")

        assertTrue(shell.contains("TvSettingsScreen(repo = repo)"))
        assertTrue(settings.contains("if (route == TvSettingsRoute.ADDONS)"))
        assertTrue(settings.contains("viewModel<AddonsViewModel>"))
        assertTrue(settings.contains("TvAddonsScreen(") && settings.contains("viewModel = addonsVm"))
        assertTrue(addons.contains("val health by viewModel.health.collectAsStateWithLifecycle()"))
        assertFalse(addons.contains("AddonHealthStore()"))
    }

    @Test
    fun `phone and TV screen entry invoke the shared non-forced refresh hook`() {
        val phone = readProjectFile("src/main/kotlin/com/vortx/android/ui/screens/AddonsScreen.kt")
        val tv = readProjectFile("src/main/kotlin/com/vortx/android/ui/tv/TvAddonsScreen.kt")

        assertTrue(phone.contains("LaunchedEffect(viewModel)"))
        assertTrue(phone.contains("viewModel.onScreenEntry()"))
        assertTrue(tv.contains("LaunchedEffect(viewModel)"))
        assertTrue(tv.contains("viewModel.onScreenEntry()"))
    }

    @Test
    fun `TV add-ons rows badges and re-check action are D-pad focusable`() {
        val addons = readProjectFile("src/main/kotlin/com/vortx/android/ui/tv/TvAddonsScreen.kt")
        val settings = readProjectFile("src/main/kotlin/com/vortx/android/ui/tv/TvSettingsScreen.kt")

        assertTrue(addonsFocusContract(addons, settings))

        val mutations = listOf(
            addons.replace("focusRequester = backFocus", "focusRequester = null") to settings,
            addons.replace("backFocus.requestFocus()", "false") to settings,
            addons.replace("onClick = viewModel::recheckHealth", "onClick = {}") to settings,
            addons.replace("AddonHealthIndicator(health)", "Text(health.label)") to settings,
            addons to settings.replace("focusRequester = addonsFocus", "focusRequester = null"),
            addons to settings.replace("addonsFocus.requestFocus()", "false"),
        )
        mutations.forEachIndexed { index, (mutatedAddons, mutatedSettings) ->
            assertFalse(
                "TV add-ons focus mutation $index survived",
                addonsFocusContract(mutatedAddons, mutatedSettings),
            )
        }
    }

    @Test
    fun `new phone and TV add-on health copy is resource backed`() {
        val phone = readProjectFile("src/main/kotlin/com/vortx/android/ui/screens/AddonsScreen.kt")
        val tv = readProjectFile("src/main/kotlin/com/vortx/android/ui/tv/TvAddonsScreen.kt")
        val settings = readProjectFile("src/main/kotlin/com/vortx/android/ui/tv/TvSettingsScreen.kt")
        val resources = readProjectFile("src/main/res/values/strings.xml")

        val ids = listOf(
            "addons_title",
            "addon_health_not_checked",
            "addon_health_checking",
            "addon_health_online_ms",
            "addon_health_slow_ms",
            "addon_health_unreachable",
            "addon_health_recheck",
            "addon_health_tv_description",
            "addon_health_loading",
            "addon_health_empty",
            "addon_health_try_again",
            "addon_health_managed",
            "addon_health_turn_on",
            "addon_health_turn_off",
            "addon_health_tv_navigation_description",
        )
        ids.forEach { id ->
            assertTrue("missing string resource $id", resources.contains("name=\"$id\""))
        }
        assertTrue(phone.contains("stringResource(R.string.addon_health_recheck)"))
        assertTrue(phone.contains("stringResource(R.string.addon_health_online_ms"))
        assertTrue(tv.contains("stringResource(R.string.addon_health_tv_description)"))
        assertTrue(tv.contains("stringResource(R.string.addon_health_recheck)"))
        assertTrue(settings.contains("stringResource(R.string.addons_title)"))
        assertFalse(tv.contains("\"Re-check status\""))
        assertFalse(tv.contains("\"Loading your add-ons...\""))
        assertFalse(tv.contains("\"No add-ons installed.\""))
    }

    private fun addonsFocusContract(addons: String, settings: String): Boolean =
        addons.contains("focusRequester = backFocus") &&
            addons.contains("backFocus.requestFocus()") &&
            addons.contains("onClick = viewModel::recheckHealth") &&
            addons.contains("AddonHealthIndicator(health)") &&
            addons.contains("TvAddonRow(") &&
            addons.contains("Surface(") &&
            settings.contains("focusRequester = addonsFocus") &&
            settings.contains("addonsFocus.requestFocus()")

    private fun readProjectFile(relativePath: String): String {
        val candidates = listOf(File(relativePath), File("app/$relativePath"), File("android/app/$relativePath"))
        return candidates.firstOrNull(File::isFile)?.readText()
            ?: error("Could not locate $relativePath from ${File(".").absolutePath}")
    }
}
