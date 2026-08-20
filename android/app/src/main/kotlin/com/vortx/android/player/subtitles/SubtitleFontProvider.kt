package com.vortx.android.player.subtitles

import android.content.Context
import java.io.File

/**
 * CJK (and other non-Latin) fallback font resolution for subtitle rendering. The Android equivalent of the
 * libass bundled-font path Apple sets in MPVMetalViewController (`sub-fonts-dir` pointed at the Noto fonts
 * shipped in the app bundle) so non-Latin subtitles have glyph coverage instead of rendering as tofu boxes.
 *
 * Apple bundles the Noto family in every target and points libass at it. Android's shipped libmpv artifact
 * carries no bundled face, which is the exact divergence [com.vortx.android.player.SubtitleStyle] documents.
 * The faithful Android fix is to give libass a fonts DIRECTORY to draw fallback glyphs from, WITHOUT forcing a
 * base face name (`sub-font`) which, per that divergence note, can render NO subtitles when the named face is
 * absent. We resolve, in Apple's bundle-first order:
 *
 *   1. An app-bundled fonts directory if a build ships one (extracted to `<files>/[BUNDLED_FONTS_DIRNAME]`),
 *      the direct analog of Apple's `resourcePath + "/fonts"`.
 *   2. The OS font directory ([OS_FONTS_DIR]), which ships Noto Sans CJK (and Noto Arabic / Hebrew / Thai /
 *      Devanagari) on every Android device per the Compatibility Definition, i.e. the OS-bundled equivalent of
 *      Apple bundling Noto in the app.
 *
 * The ExoPlayer render path needs no equivalent: Android's text stack applies system font fallback (the same
 * Noto CJK) to the SubtitleView's default typeface automatically for any missing glyph, so forcing a CJK face
 * there is unnecessary and would restyle Latin subtitles. This provider therefore serves the libmpv engine,
 * whose libass fallback is explicit.
 */
object SubtitleFontProvider {

    /** The Android OS font directory, guaranteed to hold Noto CJK + other non-Latin faces. */
    private const val OS_FONTS_DIR = "/system/fonts"

    /**
     * Optional app-bundled fonts directory (relative to the app files dir), checked first so a future build that
     * ships subsetted Noto CJK just works with no code change. Empty/absent today (no binary font is bundled).
     */
    private const val BUNDLED_FONTS_DIRNAME = "subfonts"

    private val fontExtensions = setOf(".ttf", ".otf", ".ttc")

    /** Memoized OS-directory resolution; the OS font set does not change at runtime. */
    @Volatile
    private var cachedOsFontsDir: String? = null

    @Volatile
    private var osFontsDirResolved = false

    /**
     * The directory to hand libmpv as `sub-fonts-dir` for non-Latin subtitle fallback, or null when neither a
     * bundled set nor an OS font directory with usable faces is present (then libass keeps its existing
     * `embeddedfonts` + `subs-fallback` behaviour, exactly as before this path existed).
     *
     * @param context optional; when supplied, an app-bundled fonts directory is preferred over the OS one.
     */
    fun mpvFontsDir(context: Context? = null): String? {
        context?.let { ctx ->
            val bundled = File(ctx.applicationContext.filesDir, BUNDLED_FONTS_DIRNAME)
            if (bundled.isDirectory && hasFontFiles(bundled)) return bundled.absolutePath
        }
        return osFontsDir()
    }

    /** The OS font directory absolute path when it exists and holds at least one usable face, else null. */
    private fun osFontsDir(): String? {
        if (osFontsDirResolved) return cachedOsFontsDir
        val dir = File(OS_FONTS_DIR)
        val resolved = if (dir.isDirectory && hasFontFiles(dir)) dir.absolutePath else null
        cachedOsFontsDir = resolved
        osFontsDirResolved = true
        return resolved
    }

    private fun hasFontFiles(dir: File): Boolean {
        val files = dir.listFiles() ?: return false
        return files.any { file ->
            file.isFile && fontExtensions.any { ext -> file.name.endsWith(ext, ignoreCase = true) }
        }
    }
}
