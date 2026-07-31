package com.vortx.android.ui

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

class StremioXAppDebridOwnerContractTest {

    @Test
    fun playerOverlayAndDetailLayerUseTheSameOwnerScopedViewModelKey() {
        val source = readSource()

        assertTrue(
            ownerScopedKeyViolations(source).joinToString(separator = "\n"),
            ownerScopedKeyViolations(source).isEmpty(),
        )
    }

    @Test
    fun omittingThePlayerOwnerEpochTurnsTheContractRed() {
        val source = readSource()
        val mutation = source.replace(
            PLAYER_OWNER_SCOPED_KEY,
            """key = "detail-${'$'}{showForNext.id}"""",
        )

        assertTrue(ownerScopedKeyViolations(mutation).isNotEmpty())
    }

    private fun ownerScopedKeyViolations(source: String): List<String> = buildList {
        if (!source.contains(PLAYER_OWNER_SCOPED_KEY)) {
            add("The active-player DetailViewModel key must include the current debrid owner epoch")
        }
        if (!source.contains(DETAIL_OWNER_SCOPED_KEY)) {
            add("The detail-layer DetailViewModel key must include the current debrid owner epoch")
        }
    }

    private fun readSource(): String {
        val candidates = listOf(
            File("src/main/kotlin/com/vortx/android/ui/StremioXApp.kt"),
            File("app/src/main/kotlin/com/vortx/android/ui/StremioXApp.kt"),
            File("android/app/src/main/kotlin/com/vortx/android/ui/StremioXApp.kt"),
        )
        return candidates.firstOrNull(File::isFile)?.readText()
            ?: error("Could not locate StremioXApp.kt from ${File(".").absolutePath}")
    }

    private companion object {
        const val PLAYER_OWNER_SCOPED_KEY =
            """key = "detail-${'$'}{showForNext.id}-${'$'}debridOwnerEpoch""""
        const val DETAIL_OWNER_SCOPED_KEY =
            """key = "detail-${'$'}{current.id}-${'$'}debridOwnerEpoch""""
    }
}
