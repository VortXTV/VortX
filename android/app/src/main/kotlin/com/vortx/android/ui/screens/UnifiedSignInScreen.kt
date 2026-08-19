package com.vortx.android.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.viewmodel.AccountViewModel
import com.vortx.android.ui.viewmodel.VortXAccountViewModel

/// The unified, VortX-primary sign-in surface (ACC-8), the Android port of Apple `iOSSignInView`. One screen
/// presents both accounts in the right hierarchy: the VortX account is the PRIMARY login at the top (sign in
/// / create / recover, cross-device sync, plus the QR joiner already inside [VortXAccountContent]); the
/// Stremio account is the OPTIONAL import below it.
///
/// It holds NO account logic. Each section is the exact card stack of its standalone screen
/// ([VortXAccountContent] / [AccountContent]), so the two surfaces can never drift, and every action still
/// runs through the same view models the Settings rows drive. The screen only supplies the shared chrome,
/// the single scroll, and the primary/secondary framing.
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun UnifiedSignInScreen(
    vortxViewModel: VortXAccountViewModel,
    stremioViewModel: AccountViewModel,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Sign in", style = VortXTheme.type.cardTitle) },
                navigationIcon = {
                    IconButton(onClick = onBack) { Icon(VortXIcons.back, contentDescription = "Back") }
                },
            )
        },
    ) { padding ->
        Column(
            modifier = modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(VortXTheme.spacing.edge),
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.lg),
        ) {
            SectionHeader(
                title = "VortX Account",
                subtitle = "Your primary account. Profiles and watch progress sync across your devices, " +
                    "end-to-end encrypted.",
            )
            VortXAccountContent(vortxViewModel)

            SectionHeader(
                title = "Stremio",
                subtitle = "Optional. Sign in to import your Stremio library and add-ons. VortX stays your " +
                    "primary account.",
            )
            AccountContent(stremioViewModel)
        }
    }
}

@Composable
private fun SectionHeader(title: String, subtitle: String) {
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
