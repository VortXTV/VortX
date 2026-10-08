package com.vortx.android.library

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

/** Source callsite fences supplement, not replace, the actual Android/Compose compiler gate. */
class NativeWatchlistUiCaptureContractTest {
    @Test fun `Quick View captures owner before coroutine and reports success only after acknowledgement`() {
        val click = source("ui/screens/CinemaQuickViewScreen.kt").substringAfter("onClick = {")
        assertTrue(click.indexOf("captureToggle(item)") in 0 until click.indexOf("scope.launch"))
        val task = click.substringAfter("scope.launch {")
        assertTrue(task.indexOf("watchlistStore.toggle(intent)") in 0 until task.indexOf("watchlistMessage = if (nowWatchlisted)"))
        assertTrue(click.contains("it.id == item.id && it.type == item.type") || source("ui/screens/CinemaQuickViewScreen.kt").contains("it.id == item.id && it.type == item.type"))
    }

    @Test fun `touch and TV Detail share synchronous typed Watchlist intent and failure surface`() {
        val vm = source("ui/viewmodel/DetailViewModel.kt")
        val method = vm.substringAfter("fun toggleWatchlist() {").substringBefore("private fun launchDetailMutation")
        assertTrue(method.indexOf("captureToggle(") in 0 until method.indexOf("viewModelScope.launch"))
        assertTrue(method.contains("watchlistStore.toggle(intent)"))
        assertTrue(method.contains("_mutationError.value ="))
        assertTrue(vm.contains("it.id == id && it.type == type"))
        assertTrue(source("ui/screens/WatchlistScreen.kt").contains("store.error.collectAsStateWithLifecycle()"))
        assertTrue(source("ui/tv/TvLibraryRoutes.kt").contains("store.error.collectAsStateWithLifecycle()"))
    }

    @Test fun `production singleton selects real native flag before its initial reload`() {
        val store = source("library/WatchlistStore.kt")
        assertTrue(store.contains("initialNativeEnabled = { com.vortx.android.BuildConfig.NATIVE_ENGINE_ENABLED }"))
        assertTrue(store.contains("private var nativeEnabled: () -> Boolean = initialNativeEnabled"))
    }

    private fun source(path: String): String {
        val relative = "src/main/kotlin/com/vortx/android/$path"
        return listOf(File(relative), File("android/app/$relative")).first { it.isFile }.readText()
    }
}
