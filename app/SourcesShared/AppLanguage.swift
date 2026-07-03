import Foundation

/// In-app UI language override. iOS / iPadOS / macOS / tvOS normally follow the system language; this lets
/// the user pin a specific language regardless of the system setting by writing the standard
/// `AppleLanguages` user default, which the bundle's `.lproj` string loading reads at the NEXT launch.
///
/// Because the localized bundle is chosen once at launch, a change only fully takes effect after a relaunch
/// (the picker tells the user this). `set(nil)` removes the override and falls back to the system language.
///
/// The codes here match the languages the `Localizable.xcstrings` String Catalog ships, so every option
/// resolves to a real `.lproj`. Names are autonyms (each language in its own script) so users recognise
/// their language at a glance.
enum AppLanguage {
    /// (code, autonym) for every shipped language, in the catalog's order.
    static let supported: [(code: String, name: String)] = [
        ("af", "Afrikaans"), ("ar", "العربية"), ("az", "Azərbaycan"), ("bg", "Български"), ("bn", "বাংলা"),
        ("ca", "Català"), ("cs", "Čeština"), ("da", "Dansk"),
        ("de", "Deutsch"), ("el", "Ελληνικά"), ("en", "English"), ("es", "Español"), ("et", "Eesti"),
        ("eu", "Euskara"), ("gl", "Galego"), ("is", "Íslenska"), ("mk", "Македонски"), ("sq", "Shqip"),
        ("fa", "فارسی"), ("fi", "Suomi"), ("fil", "Filipino"), ("fr", "Français"), ("gu", "ગુજરાતી"),
        ("he", "עברית"), ("hi", "हिन्दी"), ("hr", "Hrvatski"), ("hu", "Magyar"), ("id", "Bahasa Indonesia"),
        ("it", "Italiano"), ("ja", "日本語"), ("kn", "ಕನ್ನಡ"), ("ko", "한국어"), ("lt", "Lietuvių"),
        ("lv", "Latviešu"), ("ml", "മലയാളം"), ("mr", "मराठी"), ("ms", "Bahasa Melayu"), ("nb", "Norsk Bokmål"),
        ("nl", "Nederlands"), ("pl", "Polski"), ("pt-BR", "Português (Brasil)"), ("pt-PT", "Português (Portugal)"),
        ("ro", "Română"), ("ru", "Русский"), ("sk", "Slovenčina"), ("sl", "Slovenščina"), ("sr", "Српски"),
        ("sv", "Svenska"), ("ta", "தமிழ்"), ("te", "తెలుగు"), ("th", "ไทย"), ("tr", "Türkçe"),
        ("uk", "Українська"), ("ur", "اردو"), ("vi", "Tiếng Việt"), ("zh-Hans", "简体中文"), ("zh-Hant", "繁體中文"),
        ("sw", "Kiswahili"), ("kk", "Қазақ"), ("hy", "Հայերեն"), ("ka", "ქართული"),
        ("pa", "ਪੰਜਾਬੀ"), ("ne", "नेपाली"), ("km", "ខ្មែរ"), ("am", "አማርኛ"),
        // Extended world-language roster (0.3.9): pushes coverage past 100.
        ("be", "Беларуская"), ("bs", "Bosanski"), ("cy", "Cymraeg"), ("ga", "Gaeilge"), ("gd", "Gàidhlig"),
        ("lb", "Lëtzebuergesch"), ("mt", "Malti"), ("uz", "Oʻzbek"), ("ky", "Кыргызча"), ("tg", "Тоҷикӣ"),
        ("mn", "Монгол"), ("lo", "ລາວ"), ("my", "မြန်မာ"), ("si", "සිංහල"), ("or", "ଓଡ଼ିଆ"),
        ("as", "অসমীয়া"), ("sd", "سنڌي"), ("ps", "پښتو"), ("ha", "Hausa"), ("yo", "Yorùbá"),
        ("ig", "Igbo"), ("zu", "isiZulu"), ("xh", "isiXhosa"), ("st", "Sesotho"), ("sn", "chiShona"),
        ("so", "Soomaali"), ("rw", "Kinyarwanda"), ("mg", "Malagasy"), ("ny", "Chichewa"), ("tt", "Татарча"),
        ("ug", "ئۇيغۇرچە"), ("ku", "Kurdî"), ("oc", "Occitan"), ("jv", "Basa Jawa"), ("su", "Basa Sunda"),
        ("ht", "Kreyòl Ayisyen"), ("sm", "Gagana Samoa"), ("mi", "Māori"), ("br", "Brezhoneg"), ("fy", "Frysk"),
        ("ceb", "Cebuano"), ("fo", "Føroyskt"),
    
    ]

    private static let appleLanguagesKey = "AppleLanguages"
    private static let overrideKey = "stremiox.languageOverride"   // "" / absent = follow system

    /// The currently pinned language code, or nil when following the system language.
    static var current: String? {
        let v = UserDefaults.standard.string(forKey: overrideKey)
        return (v?.isEmpty ?? true) ? nil : v
    }

    /// Pin a language (nil = follow the system). Writes the standard `AppleLanguages` default so the chosen
    /// `.lproj` loads on the next launch; full effect comes after a relaunch.
    static func set(_ code: String?) {
        let d = UserDefaults.standard
        if let code, !code.isEmpty {
            d.set(code, forKey: overrideKey)
            d.set([code], forKey: appleLanguagesKey)
        } else {
            d.removeObject(forKey: overrideKey)
            d.removeObject(forKey: appleLanguagesKey)   // restore the system language order
        }
    }

    /// Display name (autonym) for a code, falling back to the system-localized name, then the raw code.
    static func name(for code: String) -> String {
        supported.first { $0.code == code }?.name
            ?? Locale.current.localizedString(forIdentifier: code)
            ?? code
    }
}
