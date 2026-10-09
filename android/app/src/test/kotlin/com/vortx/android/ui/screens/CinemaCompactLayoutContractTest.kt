package com.vortx.android.ui.screens

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Production callsite checks supplement compilation; they are not device/viewport measurements. */
class CinemaCompactLayoutContractTest {
    @Test fun `Quick View keeps Watch Watchlist and Details outside the scrolling copy`() {
        val source = source("ui/screens/CinemaQuickViewScreen.kt")
        val scrollBody = bodyAfter(source, ".verticalScroll(rememberScrollState())")
        assertFalse("Watch must remain in the pinned initial-viewport footer", scrollBody.contains("onClick = onWatch"))
        assertFalse("Watchlist must remain in the pinned initial-viewport footer", scrollBody.contains("captureToggle(item)"))
        assertFalse("Details must remain in the pinned initial-viewport footer", scrollBody.contains("onClick = onDetails"))
        val footer = source.substringAfter(scrollBody)
        assertTrue(footer.contains("onClick = onWatch"))
        assertTrue(footer.contains("captureToggle(item)"))
        assertTrue(footer.contains("onClick = onDetails"))
    }

    @Test fun `Quick View footer wraps secondary actions rather than clipping them`() {
        val source = source("ui/screens/CinemaQuickViewScreen.kt")
        val actions = bodyAfter(source, "FlowRow(")
        assertTrue(actions.contains("captureToggle(item)"))
        assertTrue(actions.contains("onClick = onDetails"))
        assertTrue(source.contains("PrimaryButton(text = \"Watch\", onClick = onWatch, modifier = Modifier.fillMaxWidth()"))
    }

    @Test fun `disabled Quick View preference also removes Home long press entry`() {
        val home = source("ui/VortXApp.kt").substringAfter("HomeScreen(").substringBefore("Tab.LIBRARY ->")
        assertTrue(home.contains("onQuickView = if (cinemaQuickView)"))
        assertTrue(home.substringAfter("onQuickView = if (cinemaQuickView)").contains("else null"))
    }

    @Test fun `compact add-on install and QR actions wrap together`() {
        val source = source("ui/screens/AddonsScreen.kt")
        val install = source.indexOf("label = if (installing)")
        val flow = source.lastIndexOf("FlowRow(", install)
        assertTrue("Install controls need a wrapping layout", flow >= 0)
        val actions = bodyAfter(source.substring(flow), "FlowRow(")
        assertTrue(actions.contains("onClick = viewModel::install"))
        assertTrue(actions.contains("onClick = onInstallByQr"))
    }

    @Test fun `touch source tabs jump through all ordered groups and All returns to start`() {
        val source = source("ui/screens/DetailScreen.kt").substringAfter("private fun SourcesSection(")
        assertFalse("A jump tab must not filter neighboring sections away", source.contains("groups.filter { effectiveSourceFilter"))
        assertTrue(source.contains("cinemaSourceWindow(groups, collapsed, renderLimit, effectiveJumpGroupKey)"))
        assertTrue(source.contains("onClick = { requestSourceJump(null) }"))
        assertTrue(source.contains("sourceListAnchor.bringIntoView()"))
        assertTrue(source.contains("cinemaSourceGroupKey(group, index)"))
        assertTrue(source.contains("sourceTabs.forEach { tab ->"))
        assertTrue(source.contains("takeIf { entry.firstProviderSection }"))
    }

    private fun bodyAfter(source: String, marker: String): String {
        val markerIndex = source.indexOf(marker)
        require(markerIndex >= 0) { "Missing production layout marker: $marker" }
        val start = source.indexOf(") {", markerIndex) + 2
        require(start >= 2 && source[start] == '{') { "Missing layout body after $marker" }
        var depth = 1
        var cursor = start + 1
        // Layout bodies below have balanced Kotlin strings/comments; brace depth identifies siblings,
        // unlike a substring ending at the first nested watchlist callback.
        while (cursor < source.length && depth > 0) {
            when (source[cursor]) { '{' -> depth++; '}' -> depth-- }
            cursor++
        }
        require(depth == 0) { "Unbalanced production layout body" }
        return source.substring(start + 1, cursor - 1)
    }

    private fun source(path: String): String {
        val relative = "src/main/kotlin/com/vortx/android/$path"
        return listOf(File(relative), File("android/app/$relative")).first { it.isFile }.readText()
    }
}
