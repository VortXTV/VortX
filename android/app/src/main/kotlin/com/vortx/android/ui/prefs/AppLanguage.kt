package com.vortx.android.ui.prefs

import android.content.Context
import android.os.Build
import android.os.LocaleList

/**
 * In-app UI language override, the Android port of Apple `app/SourcesShared/AppLanguage.swift`. Android
 * normally follows the system (or the OS per-app language on Android 13+); this lets the user pin a specific
 * language regardless, persisted under Apple's EXACT key `stremiox.languageOverride` ("" / absent = follow
 * system) so the choice rides the same cross-device settings blob as the Apple apps.
 *
 * APPLY PATH: on Android 13+ (API 33) the framework `LocaleManager.setApplicationLocales` applies + persists
 * the per-app locale system-side, so a pick takes effect on the next resumed Activity and survives restart
 * with no relaunch dance. Below 33 the framework has no per-app locale API and this project does not depend
 * on androidx.appcompat (whose `AppCompatDelegate.setApplicationLocales` backports it), so the override is
 * STORED for cross-device sync but not applied to the running process. Fail-soft: nothing here can crash or
 * blank a screen, and an unsupported OS simply keeps the system language while the choice still syncs.
 *
 * The curated [supported] list is byte-for-byte the Apple `AppLanguage.supported` roster (autonyms, in the
 * catalog's order) so both platforms offer the SAME options; SET-8's trailer-language picker reuses it too.
 */
object AppLanguage {

    /** (code, autonym) for every offered language, in the Apple catalog's order. Mirrors Apple `supported`. */
    val supported: List<Pair<String, String>> = listOf(
        "af" to "Afrikaans", "ar" to "العربية", "az" to "Azərbaycan", "bg" to "Български", "bn" to "বাংলা",
        "ca" to "Català", "cs" to "Čeština", "da" to "Dansk",
        "de" to "Deutsch", "el" to "Ελληνικά", "en" to "English", "es" to "Español", "et" to "Eesti",
        "eu" to "Euskara", "gl" to "Galego", "is" to "Íslenska", "mk" to "Македонски", "sq" to "Shqip",
        "fa" to "فارسی", "fi" to "Suomi", "fil" to "Filipino", "fr" to "Français", "gu" to "ગુજરાતી",
        "he" to "עברית", "hi" to "हिन्दी", "hr" to "Hrvatski", "hu" to "Magyar", "id" to "Bahasa Indonesia",
        "it" to "Italiano", "ja" to "日本語", "kn" to "ಕನ್ನಡ", "ko" to "한국어", "lt" to "Lietuvių",
        "lv" to "Latviešu", "ml" to "മലയാളം", "mr" to "मराठी", "ms" to "Bahasa Melayu", "nb" to "Norsk Bokmål",
        "nl" to "Nederlands", "pl" to "Polski", "pt-BR" to "Português (Brasil)", "pt-PT" to "Português (Portugal)",
        "ro" to "Română", "ru" to "Русский", "sk" to "Slovenčina", "sl" to "Slovenščina", "sr" to "Српски",
        "sv" to "Svenska", "ta" to "தமிழ்", "te" to "తెలుగు", "th" to "ไทย", "tr" to "Türkçe",
        "uk" to "Українська", "ur" to "اردو", "vi" to "Tiếng Việt", "zh-Hans" to "简体中文", "zh-Hant" to "繁體中文",
        "sw" to "Kiswahili", "kk" to "Қазақ", "hy" to "Հայերեն", "ka" to "ქართული",
        "pa" to "ਪੰਜਾਬੀ", "ne" to "नेपाली", "km" to "ខ្មែរ", "am" to "አማርኛ",
        "be" to "Беларуская", "bs" to "Bosanski", "cy" to "Cymraeg", "ga" to "Gaeilge", "gd" to "Gàidhlig",
        "lb" to "Lëtzebuergesch", "mt" to "Malti", "uz" to "Oʻzbek", "ky" to "Кыргызча", "tg" to "Тоҷикӣ",
        "mn" to "Монгол", "lo" to "ລາວ", "my" to "မြန်မာ", "si" to "සිංහල", "or" to "ଓଡ଼ିଆ",
        "as" to "অসমীয়া", "sd" to "سنڌي", "ps" to "پښتو", "ha" to "Hausa", "yo" to "Yorùbá",
        "ig" to "Igbo", "zu" to "isiZulu", "xh" to "isiXhosa", "st" to "Sesotho", "sn" to "chiShona",
        "so" to "Soomaali", "rw" to "Kinyarwanda", "mg" to "Malagasy", "ny" to "Chichewa", "tt" to "Татарча",
        "ug" to "ئۇيغۇرچە", "ku" to "Kurdî", "oc" to "Occitan", "jv" to "Basa Jawa", "su" to "Basa Sunda",
        "ht" to "Kreyòl Ayisyen", "sm" to "Gagana Samoa", "mi" to "Māori", "br" to "Brezhoneg", "fy" to "Frysk",
        "ceb" to "Cebuano", "fo" to "Føroyskt",
    )

    /** The exact Apple key; "" / absent = follow the system language. */
    const val OVERRIDE_KEY = "stremiox.languageOverride"

    private const val PREFS_FILE = "vortx_settings"

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)

    /** The currently pinned language code, or null when following the system language. Mirrors Apple `current`. */
    fun current(context: Context): String? =
        prefs(context).getString(OVERRIDE_KEY, null)?.takeIf { it.isNotEmpty() }

    /** True on the OS versions where a pick is applied to the running app (not merely stored for sync). */
    val canApply: Boolean get() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU

    /**
     * Pin a language (null / "" = follow the system). Persists the override on Apple's key, then applies it
     * via the framework per-app locale on API 33+. Fail-soft on every OS: the write always succeeds so the
     * choice syncs, and the apply is a best-effort no-op where the framework has no per-app locale API.
     */
    fun set(context: Context, code: String?) {
        val normalized = code?.takeIf { it.isNotEmpty() }.orEmpty()
        prefs(context).edit().putString(OVERRIDE_KEY, normalized).apply()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val manager = context.applicationContext.getSystemService(android.app.LocaleManager::class.java)
            manager?.applicationLocales = if (normalized.isEmpty()) {
                LocaleList.getEmptyLocaleList()
            } else {
                LocaleList.forLanguageTags(normalized)
            }
        }
    }

    /** Display name (autonym) for a code, falling back to the raw code. Mirrors Apple `name(for:)`. */
    fun name(code: String): String = supported.firstOrNull { it.first == code }?.second ?: code
}
