package com.vortx.android.ui.tv

import androidx.compose.foundation.border
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import com.vortx.android.ui.screens.ProfilesScreen
import com.vortx.android.ui.theme.VortXShapes
import com.vortx.android.ui.theme.VortXTheme

internal val LocalTvProfilePresentation = staticCompositionLocalOf { false }

/** Reuse the native profile editor and its captured account/PIN authority; only presentation differs. */
@Composable
internal fun TvProfilesScreen(onBack: () -> Unit, modifier: Modifier = Modifier) {
    CompositionLocalProvider(LocalTvProfilePresentation provides true) {
        ProfilesScreen(onBack, modifier.fillMaxSize().padding(TvDimens.edge))
    }
}

@Composable
internal fun Modifier.profilePageFocus(): Modifier {
    if (!LocalTvProfilePresentation.current) return this
    val entryFocus = remember { FocusRequester() }
    LaunchedEffect(Unit) { withFrameNanos { }; entryFocus.requestFocus() }
    return this.focusRequester(entryFocus).focusGroup()
}

/** Keep the existing clickable's semantics and keyboard action; draw a distinct remote focus ring. */
@Composable
internal fun Modifier.profileFocusTarget(): Modifier {
    if (!LocalTvProfilePresentation.current) return this
    var focused by remember { mutableStateOf(false) }
    return this.heightIn(min = 48.dp).onFocusChanged { focused = it.isFocused }
        .border(2.dp, if (focused) VortXTheme.colors.accentBright else Color.Transparent, VortXShapes.control)
}
