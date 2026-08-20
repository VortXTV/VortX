package com.vortx.android.player.mpv

import android.content.Context
import android.util.Log
import java.io.File

/**
 * Extracts the bundled Anime4K GLSL shaders (full-flavor `assets/shaders/`) to a real filesystem path and
 * builds the `glsl-shaders` option value libmpv / libplacebo (gpu-next) needs. mpv reads shader FILES, not
 * asset streams, so the packaged shaders are copied once into the app's files dir and referenced by absolute
 * path. The Android analogue of the Apple app resolving its bundled shader files for the same preset.
 *
 * Fail-soft: any missing asset or IO failure returns null, and [MpvPlayer] then simply does NOT arm the
 * shader chain (it falls back to the plain baseline rather than a half-applied chain). Only the full flavor
 * carries these assets or this file; the play flavor has no libmpv and never reaches here.
 */
internal object Anime4KShaders {

    private const val TAG = "anime4k"
    private const val ASSET_DIR = "shaders"
    private const val EXTRACT_DIR = "vortx-shaders"

    /**
     * Ensure [fileNames] are present on disk (extracting from assets when absent or stale) and return them
     * joined for mpv's `glsl-shaders` option, in the given CHAIN ORDER, or null when any is unavailable.
     * mpv accepts a list separated by the platform path separator; on Android (`:`) that is safe because the
     * extracted paths never contain a colon.
     */
    fun glslShadersOption(context: Context, fileNames: List<String>): String? {
        if (fileNames.isEmpty()) return null
        val dir = File(context.applicationContext.filesDir, EXTRACT_DIR)
        if (!dir.exists() && !dir.mkdirs()) {
            Log.d(TAG, "could not create shader dir; Anime4K disabled this session")
            return null
        }
        val paths = fileNames.map { name ->
            val out = File(dir, name)
            if (!out.exists() || out.length() == 0L) {
                val ok = runCatching {
                    context.applicationContext.assets.open("$ASSET_DIR/$name").use { input ->
                        out.outputStream().use { input.copyTo(it) }
                    }
                }.isSuccess
                if (!ok || out.length() == 0L) {
                    Log.d(TAG, "shader $name missing/failed to extract; Anime4K disabled this session")
                    return null
                }
            }
            out.absolutePath
        }
        return paths.joinToString(File.pathSeparator)
    }
}
