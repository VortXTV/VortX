package com.vortx.android.ui.tv

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

class TvDetailRetryContractTest {

    @Test
    fun `TV detail error retries its view model instead of leaving the title`() {
        val source = sequenceOf(
            File("src/main/kotlin/com/vortx/android/ui/tv/TvDetailScreen.kt"),
            File("app/src/main/kotlin/com/vortx/android/ui/tv/TvDetailScreen.kt"),
            File("android/app/src/main/kotlin/com/vortx/android/ui/tv/TvDetailScreen.kt"),
        ).firstOrNull(File::isFile)?.readText() ?: error("TvDetailScreen.kt not found")

        assertTrue(source.contains("TvError(meta.message, onRetry = viewModel::retryMeta)"))
    }
}
