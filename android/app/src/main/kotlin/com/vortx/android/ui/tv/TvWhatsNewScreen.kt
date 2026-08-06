package com.vortx.android.ui.tv

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.tv.material3.Border
import androidx.tv.material3.ClickableSurfaceDefaults
import androidx.tv.material3.ExperimentalTvMaterial3Api
import androidx.tv.material3.Surface
import com.vortx.android.ui.theme.VortXShapes
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.whatsnew.ChangelogBlock
import com.vortx.android.whatsnew.ChangelogBlockKind
import com.vortx.android.whatsnew.ChangelogParser
import com.vortx.android.whatsnew.WhatsNew

internal data class ChangelogRelease(
    val title: String,
    val blocks: List<ChangelogBlock>,
)

internal fun changelogReleases(blocks: List<ChangelogBlock>): List<ChangelogRelease> {
    val releases = mutableListOf<ChangelogRelease>()
    var title: String? = null
    var body = mutableListOf<ChangelogBlock>()
    fun flush() {
        val current = title ?: return
        releases += ChangelogRelease(current, body)
        body = mutableListOf()
    }
    blocks.forEach { block ->
        if (block.kind == ChangelogBlockKind.VERSION) {
            flush()
            title = block.text
        } else if (title != null) {
            body += block
        }
    }
    flush()
    return releases
}

@OptIn(ExperimentalTvMaterial3Api::class)
@Composable
fun TvWhatsNewScreen(onBack: () -> Unit, modifier: Modifier = Modifier) {
    BackHandler(onBack = onBack)
    val context = LocalContext.current
    val releases = remember(context) { changelogReleases(WhatsNew.load(context)) }
    val colors = VortXTheme.colors

    LazyColumn(
        modifier = modifier.fillMaxSize().background(colors.canvas),
        contentPadding = PaddingValues(TvDimens.edge),
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
    ) {
        item {
            Column {
                Text("What's New", style = VortXTheme.type.screenTitle)
                Text(
                    "You're on VortX ${WhatsNew.version}",
                    style = VortXTheme.type.label.copy(color = colors.textSecondary),
                )
            }
        }
        items(releases, key = { it.title }) { release ->
            Surface(
                onClick = {},
                modifier = Modifier.fillMaxWidth(),
                shape = ClickableSurfaceDefaults.shape(shape = VortXShapes.card),
                colors = ClickableSurfaceDefaults.colors(
                    containerColor = colors.surface1,
                    contentColor = colors.textPrimary,
                    focusedContainerColor = colors.surface3,
                    focusedContentColor = colors.textPrimary,
                ),
                scale = ClickableSurfaceDefaults.scale(focusedScale = 1.02f),
                border = ClickableSurfaceDefaults.border(
                    focusedBorder = Border(
                        border = BorderStroke(2.dp, colors.accentBright),
                        shape = VortXShapes.card,
                    ),
                ),
            ) {
                Column(
                    modifier = Modifier.fillMaxWidth().padding(VortXTheme.spacing.lg),
                    verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
                ) {
                    Text(release.title, style = VortXTheme.type.sectionTitle)
                    release.blocks.forEach { TvChangelogBlock(it) }
                }
            }
        }
    }
}

@Composable
private fun TvChangelogBlock(block: ChangelogBlock) {
    val text = ChangelogParser.inlineText(block.text)
    when (block.kind) {
        ChangelogBlockKind.SUBHEAD -> Text(text, style = VortXTheme.type.cardTitle)
        ChangelogBlockKind.BULLET -> Row(modifier = Modifier.fillMaxWidth()) {
            Text("•", style = VortXTheme.type.body.copy(color = VortXTheme.colors.accent))
            Spacer(Modifier.width(VortXTheme.spacing.sm))
            Text(text, style = VortXTheme.type.body, modifier = Modifier.weight(1f))
        }
        ChangelogBlockKind.PARAGRAPH -> Text(
            text,
            style = VortXTheme.type.body.copy(color = VortXTheme.colors.textSecondary),
        )
        ChangelogBlockKind.VERSION -> Unit
    }
}
