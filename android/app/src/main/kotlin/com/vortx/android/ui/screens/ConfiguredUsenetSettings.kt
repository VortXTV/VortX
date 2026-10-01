package com.vortx.android.ui.screens

import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import com.vortx.android.debrid.DebridKeys
import com.vortx.android.nzb.NzbIndexerStore
import com.vortx.android.profile.ProfileStore
import com.vortx.android.profile.UserProfile
import com.vortx.android.usenet.UsenetProviderStore

/** Shared phone/TV route adapters use the same credential owner as actual playback resolution. */
@Composable
internal fun ConfiguredNzbIndexerSettingsScreen(onBack: () -> Unit, modifier: Modifier = Modifier) {
    val context = LocalContext.current.applicationContext
    val keys = remember(context) { DebridKeys(context) }
    val store = remember(keys) {
        NzbIndexerStore(context, keys::ownerToken,
            { ProfileStore.sharedOrNull()?.activeProfileId ?: UserProfile.OWNER_ID }, keys::mutateCurrentOwner)
    }
    NzbIndexerSettingsScreen(store = store, onBack = onBack, modifier = modifier)
}

@Composable
internal fun ConfiguredUsenetServersSettingsScreen(onBack: () -> Unit, modifier: Modifier = Modifier) {
    val context = LocalContext.current.applicationContext
    val keys = remember(context) { DebridKeys(context) }
    val store = remember(keys) { UsenetProviderStore(context, keys::ownerToken, keys::mutateCurrentOwner) }
    UsenetServersSettingsScreen(store = store, onBack = onBack, modifier = modifier)
}
