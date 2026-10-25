package com.vortx.android.ui.components

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.ContentScale
import coil3.compose.AsyncImage
import coil3.compose.LocalPlatformContext
import coil3.request.ImageRequest
import coil3.request.crossfade

internal fun artworkCandidates(urls: List<String?>): List<String> =
    urls.mapNotNull { it?.trim()?.takeIf(String::isNotEmpty) }.distinct()

internal fun nextArtworkCandidate(current: Int, failed: Int, count: Int): Int =
    if (current == failed && current < count) current + 1 else current

/** Try each metadata URL once. A new title/URL list owns fresh state; old errors cannot advance it. */
@Composable
internal fun FallbackArtwork(
    urls: List<String?>,
    contentDescription: String?,
    modifier: Modifier = Modifier,
    placeholder: @Composable () -> Unit = {},
    /** Caps the decoded size (longest edge, px) below the on-screen size; null decodes at the view size. */
    maxDecodePx: Int? = null,
    /** Keep existing Crop/FILL requests by default; scoped callers can bound the decode with FIT. */
    decodeScale: coil3.size.Scale = coil3.size.Scale.FILL,
    /** Keep the shared ImageLoader default when null; startup covers explicitly pass false. */
    contentScale: ContentScale = ContentScale.Crop,
    crossfade: Boolean? = null,
) {
    val candidates = artworkCandidates(urls)
    key(candidates) {
        var index by remember { mutableIntStateOf(0) }
        val requestIndex = index
        Box(modifier = modifier) {
            placeholder()
            candidates.getOrNull(requestIndex)?.let { url ->
                val context = LocalPlatformContext.current
                val model = if (maxDecodePx != null || crossfade != null) {
                    ImageRequest.Builder(context).data(url).apply {
                        maxDecodePx?.let {
                            size(it).scale(decodeScale).precision(coil3.size.Precision.INEXACT)
                        }
                        crossfade?.let { requested -> crossfade(requested) }
                    }.build()
                } else {
                    url
                }
                AsyncImage(
                    model = model,
                    contentDescription = contentDescription,
                    contentScale = contentScale,
                    modifier = Modifier.fillMaxSize(),
                    onError = { index = nextArtworkCandidate(index, requestIndex, candidates.size) },
                )
            }
        }
    }
}
