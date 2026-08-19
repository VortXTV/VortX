package com.vortx.android.ui.screens

import android.content.Context
import android.content.Intent
import com.vortx.android.sources.CanonicalContentIdentity

internal fun detailShareText(id: String, title: String): String =
    CanonicalContentIdentity.imdb(id)?.let { "https://www.imdb.com/title/$it/" } ?: title

/** Opens the platform share sheet and leaves Detail usable when no activity can handle it. */
internal fun launchDetailShare(context: Context, id: String, title: String) {
    val send = Intent(Intent.ACTION_SEND).apply {
        type = "text/plain"
        putExtra(Intent.EXTRA_TEXT, detailShareText(id, title))
    }
    runCatching { context.startActivity(Intent.createChooser(send, "Share")) }
}
