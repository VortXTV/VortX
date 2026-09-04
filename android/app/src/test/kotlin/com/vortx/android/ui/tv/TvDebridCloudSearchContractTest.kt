package com.vortx.android.ui.tv

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TvDebridCloudSearchContractTest {

    @Test
    fun `TV Search places debrid cloud directly after play link`() {
        val source = read("src/main/kotlin/com/vortx/android/ui/tv/TvSearchScreen.kt")

        assertTrue(searchActionsAreOrdered(source))
        assertFalse(searchActionsAreOrdered(source.replace("Your cloud", "Downloads")))
        assertFalse(searchActionsAreOrdered(source.replace("TvSearchQuickActions(onPlayLinkClick", "Unit // removed quick actions")))
    }

    @Test
    fun `TV shell overlays cloud and play link without replacing Search`() {
        val shell = read("src/main/kotlin/com/vortx/android/ui/tv/TvShell.kt")
        val app = read("src/main/kotlin/com/vortx/android/ui/tv/TvApp.kt")

        assertTrue(shell.contains("onDebridLibraryClick = { showDebridLibrary = true }"))
        assertTrue(shell.contains("showPlayLinkSheet = true"))
        assertTrue(shell.contains("TvPlayLinkSheet("))
        assertTrue(shell.contains("DebridLibraryScreen("))
        assertTrue(shell.contains("restoreQuickActionsFocusSignal = searchFocusRestoreSignal"))
        assertTrue(app.contains("var shellDestination by remember { mutableStateOf(TvDestination.HOME) }"))
        assertTrue(app.contains("var searchFocusRestoreSignal by remember { mutableStateOf(0) }"))
        assertTrue(app.contains("BackHandler(onBack = ::returnToBrowse)"))
        assertTrue(app.contains("onRestoreSearchFocus = { searchFocusRestoreSignal++ }"))
        assertTrue(shell.contains("onRestoreSearchFocus()"))
        assertFalse(shell.contains("destination = TvDestination.DOWNLOADS"))
        assertFalse(app.contains("showDebridLibrary"))
        assertFalse(app.contains("DebridLibraryScreen("))
    }

    @Test
    fun `cloud focus boundary is on the TV Scaffold root not only its body`() {
        val cloud = read("src/main/kotlin/com/vortx/android/ui/screens/DebridLibraryScreen.kt")

        assertTrue(cloudScaffoldBoundaryIsTopological(cloud))
        assertFalse(
            cloudScaffoldBoundaryIsTopological(
                cloud.replace(
                    "modifier.focusGroup().focusProperties { exit = { FocusRequester.Cancel } }",
                    "modifier",
                ).replace(
                    "modifier = Modifier\n                .fillMaxSize()",
                    "modifier = Modifier\n                .fillMaxSize()\n                .focusGroup().focusProperties { exit = { FocusRequester.Cancel } }",
                ),
            ),
        )
    }

    @Test
    fun `all TV player exits return through the retained browse owner`() {
        val app = read("src/main/kotlin/com/vortx/android/ui/tv/TvApp.kt")

        assertTrue(playerExitCallbacksUseReturnToBrowse(app))
        assertFalse(playerExitCallbacksUseReturnToBrowse(app.replace("onBack = ::returnToBrowse", "onBack = { playing = null }")))
        assertFalse(playerExitCallbacksUseReturnToBrowse(app.replace("onError = ::returnToBrowse", "onError = { playing = null }")))
        assertTrue(app.contains("BackHandler(onBack = ::returnToBrowse)"))
    }

    @Test
    fun `phone and merged Search expose one compact cloud entry rather than a Settings duplicate`() {
        val app = read("src/main/kotlin/com/vortx/android/ui/VortXApp.kt")
        val playLink = read("src/main/kotlin/com/vortx/android/ui/search/PlayLinkScreen.kt")
        val merged = read("src/main/kotlin/com/vortx/android/ui/screens/MergedDiscoverSearchScreen.kt")
        val settings = read("src/main/kotlin/com/vortx/android/ui/screens/OtherScreens.kt")

        assertTrue(app.contains("quickActions = {"))
        assertTrue(app.contains("onDebridLibraryClick = { showDebridLibrary = true }"))
        assertTrue(playLink.contains("FlowRow("))
        assertTrue(playLink.contains("label = \"Your cloud\""))
        assertTrue(merged.contains("quickActions: (@Composable () -> Unit)? = null"))
        assertTrue(merged.contains("quickActions?.invoke()"))
        assertFalse(settings.contains("SettingRow(VortXIcons.playCircle, \"Your cloud\""))
    }

    @Test
    fun `TV dismissal restores focus to the retained Search actions`() {
        val search = read("src/main/kotlin/com/vortx/android/ui/tv/TvSearchScreen.kt")
        val shell = read("src/main/kotlin/com/vortx/android/ui/tv/TvShell.kt")

        assertTrue(search.contains("FocusRequester()"))
        assertTrue(search.contains("LaunchedEffect(restoreFocusSignal)"))
        assertTrue(search.contains("Modifier.focusRequester(playLinkFocus)"))
        assertTrue(shell.contains("onDismiss = ::dismissSearchOverlay"))
        assertTrue(shell.contains("onBack = ::dismissSearchOverlay"))
        assertTrue(shell.contains(".focusProperties { canFocus = !modalVisible }"))
    }

    @Test
    fun `TV overlays own initial focus and keep focus within their modal group`() {
        val shell = read("src/main/kotlin/com/vortx/android/ui/tv/TvShell.kt")
        val cloud = read("src/main/kotlin/com/vortx/android/ui/screens/DebridLibraryScreen.kt")
        val link = read("src/main/kotlin/com/vortx/android/ui/tv/TvDownloadsScreen.kt")

        assertTrue(shell.contains("debridLibraryFocus.requestFocus()"))
        assertTrue(shell.contains("initialFocusRequester = debridLibraryFocus"))
        assertTrue(cloud.contains("Modifier.focusRequester(initialFocusRequester)"))
        assertTrue(cloud.contains("import androidx.compose.foundation.focusGroup"))
        assertTrue(cloud.contains("tvMode: Boolean = false"))
        assertTrue(cloud.contains(".onFocusChanged { focused = it.isFocused }"))
        assertTrue(cloud.contains("colors.accentBright"))
        assertTrue(cloud.contains("if (tvMode)"))
        assertTrue(cloud.contains("modifier.focusGroup().focusProperties { exit = { FocusRequester.Cancel } }"))
        assertTrue(link.contains("urlFocus.requestFocus()"))
        assertTrue(link.contains("import androidx.compose.foundation.focusGroup"))
        assertTrue(link.contains("exit = { FocusRequester.Cancel }"))
    }

    private fun searchActionsAreOrdered(source: String): Boolean {
        val screen = source.substringBefore("/// Adjacent and ordered remote targets", missingDelimiterValue = "")
        val quickActions = source.substringAfter("private fun TvSearchQuickActions", missingDelimiterValue = "")
        val playLink = quickActions.indexOf("label = \"Play a link\"")
        val cloud = quickActions.indexOf("label = \"Your cloud\"")
        val quickActionsCall = screen.indexOf("TvSearchQuickActions(onPlayLinkClick")
        val searchField = screen.indexOf("OutlinedTextField(")
        return playLink >= 0 && cloud > playLink && quickActionsCall >= 0 && searchField > quickActionsCall
    }

    private fun cloudScaffoldBoundaryIsTopological(source: String): Boolean {
        val scaffold = source.substringAfter("Scaffold(", missingDelimiterValue = "")
            .substringBefore(") { padding ->", missingDelimiterValue = "")
        return scaffold.contains("if (tvMode)") &&
            scaffold.contains("modifier.focusGroup().focusProperties { exit = { FocusRequester.Cancel } }") &&
            scaffold.indexOf("modifier = if (tvMode)") < scaffold.indexOf("topBar =")
    }

    private fun playerExitCallbacksUseReturnToBrowse(source: String): Boolean {
        val player = source.substringAfter("PlayerScreen(", missingDelimiterValue = "")
            .substringBefore("return@VortXTheme", missingDelimiterValue = "")
        return player.contains("onBack = ::returnToBrowse") && player.contains("onError = ::returnToBrowse")
    }

    private fun read(relativePath: String): String {
        val candidates = listOf(
            File(relativePath),
            File("app/$relativePath"),
            File("android/app/$relativePath"),
        )
        return candidates.firstOrNull(File::isFile)?.readText()
            ?: error("Could not locate $relativePath from ${File(".").absolutePath}")
    }
}
