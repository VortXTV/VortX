package com.vortx.android.ui

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VortXAppDebridOwnerContractTest {

    @Test
    fun playerOverlayAndDetailLayerUseTheSameBoundedOwner() {
        val source = readSource()

        assertTrue(
            ownerScopedKeyViolations(source).joinToString(separator = "\n"),
            ownerScopedKeyViolations(source).isEmpty(),
        )
    }

    @Test
    fun omittingThePlayerBoundedOwnerTurnsTheContractRed() {
        val source = readSource()
        val mutation = source.replace(
            PLAYER_BOUNDED_OWNER,
            """key = "detail-${'$'}{showForNext.id}",""",
        )

        assertTrue(ownerScopedKeyViolations(mutation).isNotEmpty())
    }

    @Test
    fun phoneDebridOverlayRestoresSettingsScrollAndInvokingRowFocus() {
        val appSource = readSource()
        val settingsSource = readOtherScreensSource()

        assertTrue(settingsReturnContract(appSource, settingsSource))
        val mutations = listOf(
            appSource.replace(
                "val settingsScrollState = rememberScrollState()",
                "val settingsScrollState = ScrollState(0)",
            ) to settingsSource,
            appSource.replace(
                "debridServicesFocusRequester.requestFocus()",
                "false",
            ) to settingsSource,
            appSource to settingsSource.replace(
                ".verticalScroll(settingsScrollState)",
                ".verticalScroll(rememberScrollState())",
            ),
            appSource to settingsSource.replace(
                "Modifier.focusRequester(debridServicesFocusRequester)",
                "Modifier",
            ),
        )
        mutations.forEachIndexed { index, (mutatedApp, mutatedSettings) ->
            assertFalse(
                "phone Settings return mutation $index survived",
                settingsReturnContract(mutatedApp, mutatedSettings),
            )
        }
    }

    private fun ownerScopedKeyViolations(source: String): List<String> = buildList {
        if (!source.contains(DETAIL_SOURCE_EPOCH)) {
            add("The detail epoch must include owner, credential, and source-setting revisions")
        }
        if (!source.contains(BOUNDED_OWNER_GENERATION)) {
            add("The bounded DetailViewModel owner must replace its store for every source epoch")
        }
        if (!source.contains(PLAYER_BOUNDED_OWNER)) {
            add("The active-player DetailViewModel must use the bounded detail owner")
        }
        if (!source.contains(DETAIL_BOUNDED_OWNER)) {
            add("The detail-layer DetailViewModel must use the same bounded detail owner")
        }
    }

    private fun readSource(): String {
        val candidates = listOf(
            File("src/main/kotlin/com/vortx/android/ui/VortXApp.kt"),
            File("app/src/main/kotlin/com/vortx/android/ui/VortXApp.kt"),
            File("android/app/src/main/kotlin/com/vortx/android/ui/VortXApp.kt"),
        )
        return candidates.firstOrNull(File::isFile)?.readText()
            ?: error("Could not locate VortXApp.kt from ${File(".").absolutePath}")
    }

    private fun readOtherScreensSource(): String {
        val candidates = listOf(
            File("src/main/kotlin/com/vortx/android/ui/screens/OtherScreens.kt"),
            File("app/src/main/kotlin/com/vortx/android/ui/screens/OtherScreens.kt"),
            File("android/app/src/main/kotlin/com/vortx/android/ui/screens/OtherScreens.kt"),
        )
        return candidates.firstOrNull(File::isFile)?.readText()
            ?: error("Could not locate OtherScreens.kt from ${File(".").absolutePath}")
    }

    private fun settingsReturnContract(appSource: String, settingsSource: String): Boolean =
        appSource.contains("val settingsScrollState = rememberScrollState()") &&
            appSource.contains("val debridServicesFocusRequester = remember { FocusRequester() }") &&
            appSource.contains("BackHandler(onBack = closeDebridKeys)") &&
            appSource.contains("onBack = closeDebridKeys") &&
            appSource.contains("debridServicesFocusRequester.requestFocus()") &&
            appSource.contains("settingsScrollState = settingsScrollState") &&
            settingsSource.contains(".verticalScroll(settingsScrollState)") &&
            settingsSource.contains("Modifier.focusRequester(debridServicesFocusRequester)")

    private companion object {
        const val BOUNDED_OWNER_GENERATION =
            """detail?.let { "${'$'}{it.type}:${'$'}{it.id}:${'$'}detailSourceEpoch" }"""
        const val PLAYER_BOUNDED_OWNER =
            """viewModelStoreOwner = detailVmOwner,
                        key = detailViewModelKey(
                            prefix = "detail",
                            typeId = showForNext.type.id,
                            mediaId = showForNext.id,"""
        const val DETAIL_BOUNDED_OWNER =
            """viewModelStoreOwner = detailVmOwner,
                    key = detailViewModelKey(
                        prefix = "detail",
                        typeId = current.type.id,
                        mediaId = current.id,"""
        const val DETAIL_SOURCE_EPOCH =
            """val detailSourceEpoch = "${'$'}debridOwnerEpoch:${'$'}debridCredentialRevision:${'$'}sourceSettingsRevision""""
    }
}
