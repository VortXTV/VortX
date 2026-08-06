package com.vortx.android.ui.screens

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.whatsnew.ChangelogBlock
import com.vortx.android.whatsnew.ChangelogBlockKind
import com.vortx.android.whatsnew.ChangelogParser
import com.vortx.android.whatsnew.WhatsNew

@Composable
fun WhatsNewScreen(onBack: () -> Unit, modifier: Modifier = Modifier) {
    BackHandler(onBack = onBack)
    val context = LocalContext.current
    val blocks = remember(context) { WhatsNew.load(context) }

    Column(modifier = modifier.fillMaxSize().background(VortXTheme.colors.canvas)) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(VortXTheme.spacing.edge),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            IconButton(onClick = onBack) {
                Icon(VortXIcons.back, contentDescription = "Back", tint = VortXTheme.colors.textPrimary)
            }
            Spacer(Modifier.width(VortXTheme.spacing.sm))
            Column {
                Text("What's New", style = VortXTheme.type.screenTitle)
                Text(
                    "You're on VortX ${WhatsNew.version}",
                    style = VortXTheme.type.label.copy(color = VortXTheme.colors.textSecondary),
                )
            }
        }
        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(VortXTheme.spacing.edge),
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
        ) {
            items(blocks) { block -> PhoneChangelogBlock(block) }
        }
    }
}

@Composable
private fun PhoneChangelogBlock(block: ChangelogBlock) {
    val text = ChangelogParser.inlineText(block.text)
    when (block.kind) {
        ChangelogBlockKind.VERSION -> Text(
            text,
            style = VortXTheme.type.sectionTitle,
            modifier = Modifier.padding(top = VortXTheme.spacing.lg),
        )
        ChangelogBlockKind.SUBHEAD -> Text(
            text,
            style = VortXTheme.type.cardTitle,
            modifier = Modifier.padding(top = VortXTheme.spacing.sm),
        )
        ChangelogBlockKind.BULLET -> Row(modifier = Modifier.fillMaxWidth()) {
            Text("•", style = VortXTheme.type.body.copy(color = VortXTheme.colors.accent))
            Spacer(Modifier.width(VortXTheme.spacing.sm))
            Text(text, style = VortXTheme.type.body, modifier = Modifier.weight(1f))
        }
        ChangelogBlockKind.PARAGRAPH -> Text(
            text,
            style = VortXTheme.type.body.copy(
                color = VortXTheme.colors.textSecondary,
                fontWeight = FontWeight.Normal,
            ),
        )
    }
}
