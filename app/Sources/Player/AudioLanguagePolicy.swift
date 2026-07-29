import Foundation

/// One canonical language identity for both pre-remux source selection and post-load track selection.
///
/// Region suffixes and Matroska's common ISO 639-2/B spellings collapse to the same base code. Foundation
/// resolves standard three-letter identities; explicit overrides retain legacy media codes. An unknown
/// three-letter tag stays distinct instead of being guessed from a potentially unrelated two-letter prefix.
enum AudioLanguagePolicy {
    static func canonical(_ raw: String) -> String {
        let base = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first
            .map(String.init) ?? ""
        if base.count == 3 {
            if let mapped = alpha3To2[base] { return mapped }
            if let mapped = Locale(identifier: base).language.languageCode?.identifier.lowercased(),
               mapped.count == 2 {
                return mapped
            }
            return base
        }
        return String(base.prefix(2))
    }

    /// Explicit stable mappings for common metadata plus legacy OpenSubtitles aliases. Locale handles the
    /// remaining standard ISO 639 identities, including `gla` -> `gd` and `srd` -> `sc`.
    private static let alpha3To2: [String: String] = [
        "eng": "en", "spa": "es", "fra": "fr", "fre": "fr", "deu": "de", "ger": "de",
        "ita": "it", "por": "pt", "rus": "ru", "jpn": "ja", "kor": "ko", "zho": "zh",
        "chi": "zh", "ara": "ar", "hin": "hi", "nld": "nl", "dut": "nl", "swe": "sv",
        "nor": "no", "dan": "da", "fin": "fi", "pol": "pl", "tur": "tr", "tha": "th",
        "vie": "vi", "ind": "id", "heb": "he", "ell": "el", "gre": "el", "ces": "cs",
        "cze": "cs", "ron": "ro", "rum": "ro", "bul": "bg", "slk": "sk", "slo": "sk",
        "fas": "fa", "per": "fa", "est": "et", "lav": "lv", "lit": "lt", "isl": "is",
        "ice": "is", "mkd": "mk", "mac": "mk", "sqi": "sq", "alb": "sq", "hye": "hy",
        "arm": "hy", "kat": "ka", "geo": "ka", "eus": "eu", "baq": "eu", "cym": "cy",
        "wel": "cy", "msa": "ms", "may": "ms", "ben": "bn", "mal": "ml", "mar": "mr",
        "kan": "kn", "mya": "my", "bur": "my", "khm": "km", "lao": "lo", "kaz": "kk",
        "bos": "bs", "mlt": "mt", "gle": "ga", "fil": "tl", "tgl": "tl", "pob": "pt",
        "scc": "sr", "scr": "hr",
    ]
}
