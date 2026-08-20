package com.vortx.android.ui.tv

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import com.vortx.android.ui.screens.AccountContent
import com.vortx.android.ui.screens.VortXAccountContent
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.viewmodel.AccountViewModel
import com.vortx.android.ui.viewmodel.VortXAccountViewModel

/// The 10-foot sign-in surface, the Android TV analogue of Apple `app/SourcesTV/LoginView.swift` and the
/// couch twin of the phone `UnifiedSignInScreen`. The VortX account is the PRIMARY path at the top -- and on
/// a TV its QR pairing (already inside [VortXAccountContent]'s sign-in mode) is the natural way in, so a
/// viewer signs into the account that owns their add-ons, library, and cross-device sync WITHOUT typing on
/// the remote. Connecting a Stremio account (its own sign-in below) stays the OPTIONAL "bring your Stremio
/// library" step.
///
/// It holds NO account logic and forks NO auth path. Each block is the EXACT chrome-free card stack of its
/// standalone phone screen ([VortXAccountContent] / [AccountContent]), driven by the SAME view models the
/// phone Settings rows drive ([VortXAccountViewModel] over the app-process `VortXSyncManager`;
/// [AccountViewModel] over the shared `AuthRepository`). Because those view models are the only thing that
/// ever touches a token -- the VortX side through the sync manager's secure store, the Stremio side through
/// the Keychain-equivalent auth repository -- this screen never sees, logs, or URL-encodes a credential; it
/// only lays out the two blocks for the couch. [vortxViewModel] is null when the process could not stand up
/// a `VortXSyncManager` (a preview / a wiring failure), in which case only the Stremio block shows, exactly
/// as the phone hides the VortX row when the manager is absent.
@Composable
fun TvLoginScreen(
    vortxViewModel: VortXAccountViewModel?,
    stremioViewModel: AccountViewModel,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    BackHandler { onBack() }
    Column(
        modifier = modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(TvDimens.edge),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.lg),
    ) {
        Column(
            modifier = Modifier.widthIn(max = TvDimens.formMaxWidth),
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.lg),
        ) {
            TvSignInSectionHeader(
                title = "VortX Account",
                subtitle = "Scan the code below, or enter it at vortx.tv/approve, on a phone or browser " +
                    "signed in to VortX. Profiles and watch progress sync across your devices, " +
                    "end-to-end encrypted.",
            )
            if (vortxViewModel != null) {
                VortXAccountContent(vortxViewModel, modifier = Modifier.fillMaxWidth())
            }

            TvSignInSectionHeader(
                title = "Stremio",
                subtitle = "Optional. Sign in to import your Stremio library and add-ons. VortX stays your " +
                    "primary account.",
            )
            AccountContent(stremioViewModel, modifier = Modifier.fillMaxWidth())
        }
    }
}

/// A section eyebrow + one line of guidance above each account block, mirroring the phone
/// `UnifiedSignInScreen`'s `SectionHeader` (kept file-local so the two never fight over one symbol).
@Composable
private fun TvSignInSectionHeader(title: String, subtitle: String) {
    val colors = VortXTheme.colors
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = VortXTheme.spacing.xs),
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs),
    ) {
        Text(title, style = VortXTheme.type.sectionTitle.copy(fontWeight = FontWeight.SemiBold))
        Text(subtitle, style = VortXTheme.type.label.copy(color = colors.textSecondary))
    }
}
