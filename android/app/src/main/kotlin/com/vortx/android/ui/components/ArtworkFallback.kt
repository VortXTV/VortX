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
) {
    val candidates = artworkCandidates(urls)
    key(candidates) {
        var index by remember { mutableIntStateOf(0) }
        val requestIndex = index
        Box(modifier = modifier) {
            placeholder()
            candidates.getOrNull(requestIndex)?.let { url ->
                AsyncImage(
                    model = url,
                    contentDescription = contentDescription,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.fillMaxSize(),
                    onError = { index = nextArtworkCandidate(index, requestIndex, candidates.size) },
                )
            }
        }
    }
}
