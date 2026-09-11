package com.vortx.android.ui

import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class ManualSourceOverlayContractTest {
    private fun overlay(): String {
        val path = "src/main/kotlin/com/vortx/android/ui/VortXApp.kt"
        val source = listOf(File(path), File("app/$path"), File("android/app/$path"))
            .first(File::isFile).readText()
        return source.substringAfter("private fun ManualSourcePickOverlay(")
    }

    @Test fun `failed-source controls take visible focus and restore it after resolution`() {
        val source = overlay()
        assertTrue(source.contains("LaunchedEffect(sources.firstOrNull()?.id, resolving)"))
        assertTrue(source.indexOf("withFrameNanos") < source.indexOf("firstSourceFocus.requestFocus()"))
        assertTrue(source.contains("else closeFocus.requestFocus()"))
        assertTrue(source.contains("manualSourceControlFocus(if (source.id == sources.firstOrNull()?.id) firstSourceFocus else null)"))
        assertTrue(source.contains(".onFocusChanged { focused = it.isFocused }"))
    }

    @Test fun `cancel loading stays clickable while source actions are disabled`() {
        val source = overlay()
        assertTrue(source.contains(".clickable(enabled = !resolving, onClick = onRefind)"))
        assertTrue(source.contains(".clickable(onClick = onClose)"))
        assertTrue(!source.contains(".clickable(enabled = !resolving, onClick = onClose)"))
    }
}
