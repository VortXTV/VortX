package com.vortx.android.ui.components

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import com.vortx.android.metadata.ProviderBrandLogo
import com.vortx.android.ui.theme.VortXTheme

/**
 * First-party brand fill for one "Streaming Services" tile, the Kotlin port of the Apple TV look driven by
 * `app/SourcesShared/ProviderBrandLogo.swift`: the brand's own color fills the WHOLE rounded tile edge to
 * edge, with the bundled transparent brand mark centered on top (re-rendered white on dark/saturated fills).
 *
 * Fallback ladder, exactly as Apple: a curated brand style + a bundled PNG -> the full-bleed brand mark; a
 * style but no bundled PNG -> the brand color behind the remote TMDB mark (or the full NAME, never a single
 * letter); no curated style -> the remote TMDB mark cropped, else the name. [drewSelfLabel] returns true
 * when the tile already carries its own identity (a brand mark), so the caller can suppress a redundant name
 * overlay. Returns via [onResult] whether a self-labeling mark was drawn.
 */
@Composable
fun ServiceTileArt(
    providerId: Int,
    name: String,
    imageUrl: String?,
    modifier: Modifier = Modifier,
    onResult: (drewSelfLabel: Boolean) -> Unit = {},
) {
    val context = LocalContext.current
    val style = ProviderBrandLogo.brandStyle(providerId)
    val drawableRes = ProviderBrandLogo.drawableRes(context, providerId)

    Box(modifier = modifier.fillMaxSize()) {
        if (style != null) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(Brush.verticalGradient(listOf(style.top, style.bottom))),
            )
            when {
                drawableRes != 0 -> {
                    // The bundled transparent mark centered on the brand fill; tinted white on dark fills.
                    Image(
                        painter = painterResource(drawableRes),
                        contentDescription = name,
                        contentScale = ContentScale.Fit,
                        colorFilter = if (style.tintWhite) ColorFilter.tint(Color.White) else null,
                        modifier = Modifier.fillMaxSize().padding(22.dp).align(Alignment.Center),
                    )
                    onResult(true)
                }
                !imageUrl.isNullOrBlank() -> {
                    // No bundled PNG yet: frame the remote TMDB mark on the brand fill (never a letter).
                    AsyncImage(
                        model = imageUrl,
                        contentDescription = name,
                        contentScale = ContentScale.Fit,
                        modifier = Modifier.fillMaxSize().padding(22.dp).align(Alignment.Center),
                    )
                    onResult(true)
                }
                else -> {
                    BrandName(name)
                    onResult(true)
                }
            }
        } else if (!imageUrl.isNullOrBlank()) {
            // No curated style: the remote TMDB mark cropped, as before. Not self-labeling.
            AsyncImage(
                model = imageUrl,
                contentDescription = name,
                contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize(),
            )
            onResult(false)
        } else {
            onResult(false)
        }
    }
}

/** The provider's full NAME centered on its brand fill (the last-resort label, never a single letter). */
@Composable
private fun BrandName(name: String) {
    Box(modifier = Modifier.fillMaxSize().padding(12.dp), contentAlignment = Alignment.Center) {
        Text(
            text = name,
            style = VortXTheme.type.cardTitle.copy(color = Color.White),
            textAlign = TextAlign.Center,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
    }
}
