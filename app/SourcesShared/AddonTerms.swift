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
        let whole = NSLocalizedString(key, comment: "Add-on-provided category / genre / content-type name")
        if whole != key { return whole }   // whole-string translation exists, use it as-is
        return tokenized(key) ?? whole      // else try word-wise (compound names), else passthrough
    }

    /// Word-wise fallback for compound add-on names ("Popular Movies", "Top Series") whose whole string is
    /// not in the catalog but whose individual words are. Localizes each space-separated word and re-joins
    /// ONLY when every word resolved to a real translation; if any word is unknown it returns nil so the
    /// caller keeps the original wording untouched. This preserves the whole-string safety invariant (never
    /// half-translate or reorder a name) while still localizing the common Cinemeta compound titles, which
    /// is why so many catalog rows read as English even when the per-word vocabulary is present.
    private static func tokenized(_ key: String) -> String? {
        let words = key.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard words.count > 1 else { return nil }   // single word already missed the whole-string lookup
        var out: [String] = []
        for w in words {
            let t = NSLocalizedString(w, comment: "Add-on category word")
            if t == w { return nil }   // an unknown word aborts: keep the original compound name intact
            out.append(t)
        }
        return out.joined(separator: " ")
    }
}
