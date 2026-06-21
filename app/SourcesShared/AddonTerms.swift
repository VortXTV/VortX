import Foundation

/// Client-side localization of add-on-provided category / genre / content-type names.
///
/// Add-ons (Cinemeta and friends) return catalog row titles and genre options in their own wording,
/// almost always English ("Popular", "Action", "Top Movies"). Stremio localizes these client-side by
/// mapping the common add-on vocabulary to the app's own translations and passing anything unknown
/// through unchanged; VortX does the same here. The vocabulary lives in the String Catalog
/// (`Localizable.xcstrings`) - a term we have a translation for is localized into the active language,
/// an obscure add-on name degrades gracefully to its original text.
///
/// Whole-string lookup only (no word-by-word splicing), so a language we have a real translation for is
/// never mangled by reordering or re-casing its words.
enum AddonTerms {
    /// Localize one add-on-provided term against the String Catalog, or return it unchanged when there is
    /// no translation. `NSLocalizedString` resolves the runtime key against the compiled catalog and
    /// returns the key itself when it is absent, which is exactly the graceful passthrough we want; it
    /// also honors the in-app language override (the `AppleLanguages` default `AppLanguage` writes).
    static func localize(_ raw: String) -> String {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return raw }
        return NSLocalizedString(key, comment: "Add-on-provided category / genre / content-type name")
    }
}
