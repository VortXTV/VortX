package com.vortx.android.player.extras

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.widget.Toast
import com.vortx.android.model.Playable

/**
 * Sending the current stream OUT of the player: the system share sheet and a hand-off to a user-chosen
 * external player. The Android analogue of Apple's `ShareSheet` + `ExternalPlayer`, adapted to Android's
 * Intent model: instead of Apple's curated per-app URL schemes we fire `ACTION_VIEW` / `ACTION_SEND` through
 * the system chooser, so EVERY installed video player is offered and Android remembers the viewer's "always"
 * choice itself (no per-app default to persist, and nothing platform-specific to sync).
 */
object PlayerHandoff {

    /**
     * Whether this stream can meaningfully leave the app. A loopback torrent stream (served by the in-process
     * streaming server on 127.0.0.1) is not reachable by another app or device, and a trailer is not a stream
     * a viewer shares, so both are excluded. Mirrors Apple's `canRouteExternally` gate (non-torrent, real
     * remote URL).
     */
    fun canRouteExternally(playable: Playable): Boolean {
        if (playable.isTorrent || playable.isTrailer) return false
        val url = playable.url
        val isRemote = url.startsWith("http://", ignoreCase = true) || url.startsWith("https://", ignoreCase = true)
        val isLoopback = url.contains("127.0.0.1") || url.contains("://localhost")
        return isRemote && !isLoopback
    }

    /** Share the current stream link through the system share sheet (title as subject, URL as the text). */
    fun shareStream(context: Context, playable: Playable) {
        val send = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_SUBJECT, playable.title)
            putExtra(Intent.EXTRA_TEXT, playable.url)
        }
        launch(context, Intent.createChooser(send, "Share stream"), "No app can share this link")
    }

    /**
     * Hand the current stream to another installed player via `ACTION_VIEW` with a video MIME, through the
     * system chooser so the viewer picks (and Android remembers). Passes the title and, best-effort, the
     * per-stream HTTP headers in the array form MX Player / VLC read, so an add-on stream that needs a Referer
     * or User-Agent still plays. Mirrors Apple's deep-link hand-off, in Android's Intent idiom.
     */
    fun openInExternalPlayer(context: Context, playable: Playable) {
        val view = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(Uri.parse(playable.url), "video/*")
            putExtra("title", playable.title)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            if (playable.headers.isNotEmpty()) {
                // MX Player / VLC convention: a flat [name, value, name, value, ...] string array.
                val flat = playable.headers.flatMap { (name, value) -> listOf(name, value) }.toTypedArray()
                putExtra("headers", flat)
            }
        }
        launch(context, Intent.createChooser(view, "Open in another player"), "No external player is installed")
    }

    /** Start an activity fail-soft: an unresolved chooser (nothing installed) shows a toast, never crashes. */
    private fun launch(context: Context, intent: Intent, emptyMessage: String) {
        // A non-activity context needs NEW_TASK; harmless when the context is already an activity.
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        runCatching { context.startActivity(intent) }
            .onFailure { Toast.makeText(context.applicationContext, emptyMessage, Toast.LENGTH_SHORT).show() }
    }
}
