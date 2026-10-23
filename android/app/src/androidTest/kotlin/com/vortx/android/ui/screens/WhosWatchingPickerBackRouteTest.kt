package com.vortx.android.ui.screens

import android.view.KeyEvent
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.vortx.android.ui.theme.VortXTheme
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Actual Compose coverage for the phone launch picker's state-aware system Back policy. */
@RunWith(AndroidJUnit4::class)
class WhosWatchingPickerBackRouteTest {
    @get:Rule val compose = createComposeRule()

    private fun show(pinInitially: Boolean = false, editorInitially: Boolean = false) {
        compose.setContent {
            VortXTheme {
                PhoneBackHarness(pinInitially = pinInitially, editorInitially = editorInitially)
            }
        }
        compose.waitForIdle()
    }

    private fun back() {
        InstrumentationRegistry.getInstrumentation()
            .sendKeyDownUpSync(KeyEvent.KEYCODE_BACK)
        compose.waitForIdle()
    }

    @Test
    fun backCancelsPinBeforeFinishingPicker() {
        show(pinInitially = true)

        back()

        compose.onNodeWithTag("phone-back-pin").assertTextEquals("hidden")
        compose.onNodeWithTag("phone-back-editor").assertTextEquals("hidden")
        compose.onNodeWithTag("phone-back-done").assertTextEquals("waiting")
    }

    @Test
    fun backCancelsEditorWithoutSubmittingOrFinishingPicker() {
        show(editorInitially = true)

        back()

        compose.onNodeWithTag("phone-back-pin").assertTextEquals("hidden")
        compose.onNodeWithTag("phone-back-editor").assertTextEquals("hidden")
        compose.onNodeWithTag("phone-back-done").assertTextEquals("waiting")
    }

    @Test
    fun pinPrecedenceWinsWhenPinAndEditorStatesOverlap() {
        show(pinInitially = true, editorInitially = true)

        back()

        compose.onNodeWithTag("phone-back-pin").assertTextEquals("hidden")
        compose.onNodeWithTag("phone-back-editor").assertTextEquals("visible")
        compose.onNodeWithTag("phone-back-done").assertTextEquals("waiting")
    }

    @Test
    fun backFinishesPickerOnlyWhenNoTransientStateIsActive() {
        show()

        back()

        compose.onNodeWithTag("phone-back-pin").assertTextEquals("hidden")
        compose.onNodeWithTag("phone-back-editor").assertTextEquals("hidden")
        compose.onNodeWithTag("phone-back-done").assertTextEquals("done")
    }

    @Composable
    private fun PhoneBackHarness(pinInitially: Boolean, editorInitially: Boolean) {
        var pinVisible by remember { mutableStateOf(pinInitially) }
        var editorVisible by remember { mutableStateOf(editorInitially) }
        var done by remember { mutableStateOf(false) }
        WhosWatchingBackHandler(
            pinVisible = pinVisible,
            editorVisible = editorVisible,
            onCancelPin = { pinVisible = false },
            onCancelEditor = { editorVisible = false },
            onDone = { done = true },
        )
        Column(Modifier.fillMaxSize()) {
            Text(if (pinVisible) "visible" else "hidden", Modifier.testTag("phone-back-pin"))
            Text(if (editorVisible) "visible" else "hidden", Modifier.testTag("phone-back-editor"))
            Text(if (done) "done" else "waiting", Modifier.testTag("phone-back-done"))
        }
    }
}
