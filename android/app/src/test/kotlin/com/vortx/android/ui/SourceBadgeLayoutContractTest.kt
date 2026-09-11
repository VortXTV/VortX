package com.vortx.android.ui

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

class SourceBadgeLayoutContractTest {
    @Test
    fun `badge cluster wraps inside the width left by the play icon without losing badges`() {
        val relative = "src/main/kotlin/com/vortx/android/ui/components/SourceRow.kt"
        val source = listOf(File(relative), File("app/$relative"), File("android/app/$relative"))
            .first(File::isFile).readText()
        val cluster = source.substringAfter("FlowRow(").substringBefore("val detailParts")
        assertTrue(source.contains("modifier = Modifier.weight(1f)"))
        assertTrue(cluster.contains("verticalArrangement = Arrangement.spacedBy(4.dp)"))
        for (badge in listOf("Badge(\"Pinned\")", "quality?.let { Badge(it) }", "Badge(addon)", "Badge(\"Torrent\")", "Badge(\"⚡ Cached\", prominent = true)")) {
            assertTrue("Missing badge: $badge", cluster.contains(badge))
        }
    }
}
