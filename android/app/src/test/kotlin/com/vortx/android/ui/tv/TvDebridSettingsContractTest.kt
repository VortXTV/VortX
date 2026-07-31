package com.vortx.android.ui.tv

import androidx.compose.ui.graphics.Color
import com.vortx.android.debrid.DebridService
import java.io.File
import kotlin.math.pow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TvDebridSettingsContractTest {

    @Test
    fun `TV exposes the same four debrid services`() {
        assertEquals(
            listOf("realDebrid", "allDebrid", "premiumize", "torBox"),
            DebridService.entries.map { it.id },
        )
    }

    @Test
    fun `fresh account snapshot starts with a blank editor and never a stored key`() {
        val state = tvDebridEditorState(
            hasValue = true,
            durablyConfigured = true,
            storageUnavailable = false,
        )

        assertEquals("", state.pendingKey)
        assertTrue(state.hasValue)
        assertEquals(TvDebridStatus.SET, state.status)
    }

    @Test
    fun `failed save stays focusable and the production mutation retries to set`() {
        val access = RecoveringDebridAccess()
        val pending = tvDebridEditorState(false, false, false).copy(pendingKey = "secret")

        val failed = tvApplyDebridMutation(
            editor = pending,
            access = access,
            service = DebridService.REAL_DEBRID,
            mutation = TvDebridMutation.SAVE,
            value = pending.pendingKey,
            trigger = TvDebridMutationTrigger.DPAD,
        )

        assertEquals(listOf("set", "snapshot"), access.calls)
        assertEquals(TvDebridStatus.STORAGE_UNAVAILABLE, failed.editor.status)
        assertFalse(failed.editor.pendingKey.isBlank())
        assertTrue(failed.editor.hasValue)
        assertFalse(failed.editor.durablyConfigured)
        assertEquals(TvDebridFocusTarget.SAVE, failed.focusTarget)

        access.storageAvailable = true
        access.calls.clear()
        val recovered = tvApplyDebridMutation(
            editor = failed.editor,
            access = access,
            service = DebridService.REAL_DEBRID,
            mutation = TvDebridMutation.SAVE,
            value = failed.editor.pendingKey,
            trigger = TvDebridMutationTrigger.DPAD,
        )

        assertEquals(listOf("set", "snapshot"), access.calls)
        assertEquals(TvDebridStatus.SET, recovered.editor.status)
        assertEquals("", recovered.editor.pendingKey)
        assertEquals(TvDebridFocusTarget.KEY_FIELD, recovered.focusTarget)
    }

    @Test
    fun `failed clear stays focusable and the production mutation retries to cleared`() {
        val access = RecoveringDebridAccess(
            hasValue = true,
            durablyConfigured = true,
        )
        val configured = tvDebridEditorState(true, true, false)

        val failed = tvApplyDebridMutation(
            editor = configured,
            access = access,
            service = DebridService.ALL_DEBRID,
            mutation = TvDebridMutation.CLEAR,
            value = "",
            trigger = TvDebridMutationTrigger.DPAD,
        )

        assertEquals(listOf("set", "snapshot"), access.calls)
        assertEquals(TvDebridStatus.STORAGE_UNAVAILABLE, failed.editor.status)
        assertEquals(TvDebridFocusTarget.CLEAR, failed.focusTarget)

        access.storageAvailable = true
        access.calls.clear()
        val recovered = tvApplyDebridMutation(
            editor = failed.editor,
            access = access,
            service = DebridService.ALL_DEBRID,
            mutation = TvDebridMutation.CLEAR,
            value = "",
            trigger = TvDebridMutationTrigger.DPAD,
        )

        assertEquals(listOf("set", "snapshot"), access.calls)
        assertEquals(TvDebridStatus.CLEARED, recovered.editor.status)
        assertEquals(TvDebridFocusTarget.KEY_FIELD, recovered.focusTarget)
    }

    @Test
    fun `IME save returns focus to the masked key field`() {
        val access = RecoveringDebridAccess(storageAvailable = true)
        val pending = tvDebridEditorState(false, false, false).copy(pendingKey = "secret")

        val saved = tvApplyDebridMutation(
            editor = pending,
            access = access,
            service = DebridService.PREMIUMIZE,
            mutation = TvDebridMutation.SAVE,
            value = pending.pendingKey,
            trigger = TvDebridMutationTrigger.IME,
        )

        assertEquals(TvDebridStatus.SET, saved.editor.status)
        assertEquals(TvDebridFocusTarget.KEY_FIELD, saved.focusTarget)
    }

    @Test
    fun `entry and Back have deterministic TV focus targets`() {
        assertEquals(
            TvDebridFocusTarget.BACK,
            tvDebridFocusTarget(TvDebridFocusEvent.SCREEN_ENTRY),
        )
        assertEquals(TvSettingsRoute.ROOT, TvSettingsRoute.DEBRID.back())
        assertEquals(TvSettingsRoute.ROOT, TvSettingsRoute.ROOT.back())
        assertEquals(
            TvDebridFocusTarget.DEBRID_SERVICES,
            tvDebridFocusTarget(TvDebridFocusEvent.BACK_TO_SETTINGS),
        )
    }

    @Test
    fun `entry and Back restoration attach and invoke their production focus requesters`() {
        val keysSource = readProjectFile(
            "src/main/kotlin/com/vortx/android/ui/tv/TvDebridKeysScreen.kt",
        )
        val settingsSource = readProjectFile(
            "src/main/kotlin/com/vortx/android/ui/tv/TvSettingsScreen.kt",
        )

        assertTrue(entryAndBackFocusContract(keysSource, settingsSource))

        val mutations = listOf(
            keysSource.replace("focusRequester = backFocus", "focusRequester = null") to settingsSource,
            keysSource.replace("backFocus.requestFocus()", "false") to settingsSource,
            keysSource to settingsSource.replace(
                "focusRequester = debridServicesFocus",
                "focusRequester = null",
            ),
            keysSource to settingsSource.replace("debridServicesFocus.requestFocus()", "false"),
            keysSource to settingsSource.replace("state = settingsListState", "state = rememberLazyListState()"),
        )
        mutations.forEachIndexed { index, (mutatedKeys, mutatedSettings) ->
            assertFalse(
                "focus-wiring mutation $index survived",
                entryAndBackFocusContract(mutatedKeys, mutatedSettings),
            )
        }
    }

    @Test
    fun `key field and retry actions attach and invoke the selected focus requester`() {
        val source = readProjectFile(
            "src/main/kotlin/com/vortx/android/ui/tv/TvDebridKeysScreen.kt",
        )

        assertTrue(editorFocusContract(source))

        val mutations = listOf(
            "TvDebridFocusTarget.KEY_FIELD -> keyFieldFocus" to
                "TvDebridFocusTarget.KEY_FIELD -> saveFocus",
            "TvDebridFocusTarget.SAVE -> saveFocus" to
                "TvDebridFocusTarget.SAVE -> keyFieldFocus",
            "TvDebridFocusTarget.CLEAR -> clearActionFocus" to
                "TvDebridFocusTarget.CLEAR -> keyFieldFocus",
            ".focusRequester(keyFieldFocus)" to ".focusRequester(saveFocus)",
            "focusRequester = saveFocus" to "focusRequester = null",
            "focusRequester = clearActionFocus" to "focusRequester = null",
            "requester.requestFocus()" to "false",
        )
        mutations.forEachIndexed { index, (before, after) ->
            assertFalse(
                "editor-focus mutation $index survived",
                editorFocusContract(source.replace(before, after)),
            )
        }
    }

    @Test
    fun `key entry is password masked in the production field`() {
        val source = readProjectFile(
            "src/main/kotlin/com/vortx/android/ui/tv/TvDebridKeysScreen.kt",
        )

        assertTrue(passwordMaskingContract(source))
        assertFalse(
            passwordMaskingContract(
                source.replace(
                    "visualTransformation = PasswordVisualTransformation()",
                    "visualTransformation = VisualTransformation.None",
                ),
            ),
        )
        assertFalse(
            passwordMaskingContract(
                source.replace(
                    "keyboardType = KeyboardType.Password",
                    "keyboardType = KeyboardType.Text",
                ),
            ),
        )
    }

    @Test
    fun `production adapter writes once then rereads every storage truth field`() {
        val source = readProjectFile(
            "src/main/kotlin/com/vortx/android/ui/tv/TvDebridKeysScreen.kt",
        )

        assertTrue(productionAdapterContract(source))

        val mutations = listOf(
            "keys.setKey(service, value)" to "true",
            "val status = keys.status(service)" to
                "val status = TvDebridStorageSnapshot(false, false, false)",
            "hasValue = status.hasValue" to "hasValue = false",
            "durablyConfigured = status.durablyConfigured" to "durablyConfigured = false",
            "storageUnavailable = status.storageUnavailable" to "storageUnavailable = false",
        )
        mutations.forEachIndexed { index, (before, after) ->
            assertFalse(
                "adapter mutation $index survived",
                productionAdapterContract(source.replace(before, after)),
            )
        }
    }

    @Test
    fun `status changes are polite live regions and only storage failure is an error`() {
        val source = readProjectFile(
            "src/main/kotlin/com/vortx/android/ui/tv/TvDebridKeysScreen.kt",
        )

        assertFalse(TvDebridStatus.NOT_SET.isAccessibilityError)
        assertFalse(TvDebridStatus.SET.isAccessibilityError)
        assertFalse(TvDebridStatus.CLEARED.isAccessibilityError)
        assertTrue(TvDebridStatus.STORAGE_UNAVAILABLE.isAccessibilityError)
        assertTrue(statusAccessibilityContract(source))

        val mutations = listOf(
            "liveRegion = LiveRegionMode.Polite" to "liveRegion = LiveRegionMode.None",
            "stateDescription = statusAccessibilityText" to "stateDescription = \"\"",
            "if (editor.status.isAccessibilityError)" to "if (false)",
            "error(statusAccessibilityText)" to "stateDescription = statusAccessibilityText",
        )
        mutations.forEachIndexed { index, (before, after) ->
            assertFalse(
                "status-semantics mutation $index survived",
                statusAccessibilityContract(source.replace(before, after)),
            )
        }
    }

    @Test
    fun `focused action label and icon consume the TV Surface content color`() {
        val source = readProjectFile(
            "src/main/kotlin/com/vortx/android/ui/tv/TvDebridKeysScreen.kt",
        )

        assertTrue(focusedActionContentColorContract(source))
        val mutations = listOf(
            "color = LocalContentColor.current" to "color = colors.textSecondary",
            "tint = LocalContentColor.current" to "tint = colors.textSecondary",
            "focusedContainerColor = colors.surface3" to "focusedContainerColor = colors.accent",
            "focusedContentColor = colors.textPrimary" to "focusedContentColor = colors.onAccent",
        )
        mutations.forEachIndexed { index, (before, after) ->
            assertFalse(
                "focused content-color mutation $index survived",
                focusedActionContentColorContract(source.replace(before, after)),
            )
        }
    }

    @Test
    fun `focused action token pair clears normal text contrast across every surface variant`() {
        // Non-OLED surface3 is HSV value 0.225, so neutral #393939 is the highest-luminance
        // possible surface at that value. Every accent-tinted surface3 is no brighter; OLED is darker.
        val textPrimary = Color(0xFFF6F1E9)
        val worstCaseNonOledSurface3 = Color(0xFF393939)
        val oledSurface3 = Color(0xFF242426)

        assertTrue(contrastRatio(textPrimary, worstCaseNonOledSurface3) >= 4.5)
        assertTrue(contrastRatio(textPrimary, oledSurface3) >= 4.5)
    }

    @Test
    fun `provider fields and actions have unique service names and traversal groups`() {
        val labels = DebridService.entries.map {
            tvDebridControlAccessibilityLabel(it, "Save API key")
        }
        val source = readProjectFile(
            "src/main/kotlin/com/vortx/android/ui/tv/TvDebridKeysScreen.kt",
        )

        assertEquals(DebridService.entries.size, labels.toSet().size)
        assertTrue(labels.contains("TorBox: Save API key"))
        assertTrue(providerAccessibilityContract(source))
    }

    @Test
    fun `secure storage failure uses the high contrast theme text token`() {
        val source = readProjectFile(
            "src/main/kotlin/com/vortx/android/ui/tv/TvDebridKeysScreen.kt",
        )

        assertTrue(dangerStatusContrastContract(source))
        assertFalse(
            dangerStatusContrastContract(
                source.replace(
                    "TvDebridStatus.STORAGE_UNAVAILABLE -> colors.textPrimary",
                    "TvDebridStatus.STORAGE_UNAVAILABLE -> colors.danger",
                ),
            ),
        )
    }

    @Test
    fun `secure storage failure copy is exact and focus is never cleared`() {
        val strings = readProjectFile("src/main/res/values/strings.xml")
        val source = readProjectFile(
            "src/main/kotlin/com/vortx/android/ui/tv/TvDebridKeysScreen.kt",
        )

        assertEquals(
            "Secure storage unavailable",
            Regex(
                """<string name="tv_debrid_status_storage_unavailable">([^<]+)</string>""",
            ).find(strings)?.groupValues?.get(1),
        )
        assertFalse(source.contains("clearFocus("))
        assertTrue(source.contains("keyboardController?.hide()"))
    }

    private fun entryAndBackFocusContract(keysSource: String, settingsSource: String): Boolean =
        keysSource.contains("focusRequester = backFocus") &&
            keysSource.contains("backFocus.requestFocus()") &&
            settingsSource.contains("val settingsListState = rememberLazyListState()") &&
            settingsSource.contains("state = settingsListState") &&
            settingsSource.contains("focusRequester = debridServicesFocus") &&
            settingsSource.contains("debridServicesFocus.requestFocus()") &&
            settingsSource.contains(
                "restoreFocusTarget = tvDebridFocusTarget(TvDebridFocusEvent.BACK_TO_SETTINGS)",
            )

    private fun editorFocusContract(source: String): Boolean =
        source.contains("TvDebridFocusTarget.KEY_FIELD -> keyFieldFocus") &&
            source.contains("TvDebridFocusTarget.SAVE -> saveFocus") &&
            source.contains("TvDebridFocusTarget.CLEAR -> clearActionFocus") &&
            source.contains(".focusRequester(keyFieldFocus)") &&
            source.contains("focusRequester = saveFocus") &&
            source.contains("focusRequester = clearActionFocus") &&
            source.contains("requester.requestFocus()")

    private fun passwordMaskingContract(source: String): Boolean =
        source.contains("visualTransformation = PasswordVisualTransformation()") &&
            source.contains("keyboardType = KeyboardType.Password")

    private fun productionAdapterContract(source: String): Boolean =
        source.contains("keys.setKey(service, value)") &&
            source.contains("val status = keys.status(service)") &&
            source.contains("hasValue = status.hasValue") &&
            source.contains("durablyConfigured = status.durablyConfigured") &&
            source.contains("storageUnavailable = status.storageUnavailable")

    private fun statusAccessibilityContract(source: String): Boolean =
        source.contains("liveRegion = LiveRegionMode.Polite") &&
            source.contains("stateDescription = statusAccessibilityText") &&
            source.contains("if (editor.status.isAccessibilityError)") &&
            source.contains("error(statusAccessibilityText)")

    private fun focusedActionContentColorContract(source: String): Boolean =
        source.contains("color = LocalContentColor.current") &&
            source.contains("tint = LocalContentColor.current") &&
            source.contains("focusedContainerColor = colors.surface3") &&
            source.contains("focusedContentColor = colors.textPrimary")

    private fun providerAccessibilityContract(source: String): Boolean =
        source.contains("isTraversalGroup = true") &&
            source.contains("tvDebridControlAccessibilityLabel(service, keyFieldLabel)") &&
            source.contains("accessibilityLabel = tvDebridControlAccessibilityLabel(") &&
            source.contains("contentDescription = accessibilityLabel")

    private fun dangerStatusContrastContract(source: String): Boolean =
        source.contains("TvDebridStatus.STORAGE_UNAVAILABLE -> colors.textPrimary")

    private fun contrastRatio(foreground: Color, background: Color): Double {
        val lighter = maxOf(relativeLuminance(foreground), relativeLuminance(background))
        val darker = minOf(relativeLuminance(foreground), relativeLuminance(background))
        return (lighter + 0.05) / (darker + 0.05)
    }

    private fun relativeLuminance(color: Color): Double {
        fun linear(channel: Float): Double {
            val value = channel.toDouble()
            return if (value <= 0.04045) {
                value / 12.92
            } else {
                ((value + 0.055) / 1.055).pow(2.4)
            }
        }
        return 0.2126 * linear(color.red) +
            0.7152 * linear(color.green) +
            0.0722 * linear(color.blue)
    }

    private fun readProjectFile(relativePath: String): String {
        val candidates = listOf(
            File(relativePath),
            File("app/$relativePath"),
            File("android/app/$relativePath"),
        )
        return candidates.firstOrNull(File::isFile)?.readText()
            ?: error("Could not locate $relativePath from ${File(".").absolutePath}")
    }

    private class RecoveringDebridAccess(
        var storageAvailable: Boolean = false,
        private var hasValue: Boolean = false,
        private var durablyConfigured: Boolean = false,
    ) : TvDebridKeyAccess {
        val calls = mutableListOf<String>()

        override fun setKey(service: DebridService, value: String): Boolean {
            calls += "set"
            hasValue = value.trim().isNotEmpty()
            durablyConfigured = hasValue && storageAvailable
            return storageAvailable
        }

        override fun snapshot(service: DebridService): TvDebridStorageSnapshot {
            calls += "snapshot"
            return TvDebridStorageSnapshot(
                hasValue = hasValue,
                durablyConfigured = durablyConfigured,
                storageUnavailable = !storageAvailable,
            )
        }
    }
}
