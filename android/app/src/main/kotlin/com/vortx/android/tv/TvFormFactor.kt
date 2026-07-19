package com.vortx.android.tv

import android.app.UiModeManager
import android.content.Context
import android.content.pm.PackageManager
import android.content.res.Configuration

/// Is this process running on a television?
///
/// ANDROID-PLAN.md §0 "Form factors & packaging" (hard invariant #7) fixes ONE binary per flavor for
/// phone, tablet and TV: there is no TV flavor and no TV applicationId, because a second id would
/// split a user's account/settings across their own devices (invariant #1). So the phone shell and the
/// TV shell are both compiled into every build and the choice is made HERE, at runtime, in
/// [com.vortx.android.MainActivity].
///
/// Runtime detection rather than a leanback-only `TvActivity`: a sideloaded launch on Fire TV / Google
/// TV does not reliably arrive through LEANBACK_LAUNCHER (Downloader and `adb shell am start` fire a
/// plain ACTION_MAIN), so keying the TV UI off the launcher category alone would strand a TV on the
/// phone UI. The single activity already declares BOTH categories (AndroidManifest.xml), which is the
/// supported pattern; this check then covers every entry path into it.
///
/// Two signals, either of which is sufficient:
///  - [UiModeManager.getCurrentModeType] == [Configuration.UI_MODE_TYPE_TELEVISION] is the system's own
///    live answer, and is what a TV device reports even when the app was started from a non-leanback
///    entry point.
///  - [PackageManager.FEATURE_LEANBACK] is the static "this hardware is a TV" declaration, and covers a
///    device whose ui mode has not resolved to TELEVISION (some Fire TV builds report NORMAL).
///
/// Deliberately NOT consulted: `FEATURE_TELEVISION` (deprecated since API 21 in favour of
/// FEATURE_LEANBACK, and `lint { abortOnError = true }` is on), and screen size (a tablet is not a TV).
fun isTelevision(context: Context): Boolean {
    val uiMode = (context.getSystemService(Context.UI_MODE_SERVICE) as? UiModeManager)?.currentModeType
    if (uiMode == Configuration.UI_MODE_TYPE_TELEVISION) return true
    return context.packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK)
}
