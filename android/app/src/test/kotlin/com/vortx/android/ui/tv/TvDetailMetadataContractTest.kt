package com.vortx.android.ui.tv

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

class TvDetailMetadataContractTest {

    @Test
    fun `TV detail keeps sparse and localized metadata fallbacks connected`() {
        val source = sequenceOf(
            File("src/main/kotlin/com/vortx/android/ui/tv/TvDetailScreen.kt"),
            File("app/src/main/kotlin/com/vortx/android/ui/tv/TvDetailScreen.kt"),
            File("android/app/src/main/kotlin/com/vortx/android/ui/tv/TvDetailScreen.kt"),
        ).firstOrNull(File::isFile)?.readText() ?: error("TvDetailScreen.kt not found")

        assertTrue(source.contains("LocalizedMetadataStore.title(detail.id)"))
        assertTrue(source.contains("LocalizedMetadataStore.logo(detail.id)"))
        assertTrue(source.contains("TMDBPersonClient.overview(detail.id, detail.type)"))
        assertTrue(source.contains("ReleaseDatesClient.releaseDates("))
        assertTrue(source.contains("mergeTvSimilar(recommendations, addonSimilar, detail.id)"))
    }
}
