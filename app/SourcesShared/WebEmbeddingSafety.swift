import Foundation

enum WebEmbeddingSafety {
    /// Produces one JavaScript string literal that is also safe inside an HTML script element.
    /// JSON handles JavaScript quoting. The extra substitutions prevent the HTML parser from seeing a
    /// caller-provided closing script tag and cover the two legacy JavaScript line separators.
    static func javaScriptStringLiteral(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let encoded = String(data: data, encoding: .utf8),
              encoded.first == "[",
              encoded.last == "]" else {
            return "\"\""
        }
        return String(encoded.dropFirst().dropLast())
            .replacingOccurrences(of: "<", with: "\\u003C")
            .replacingOccurrences(of: ">", with: "\\u003E")
            .replacingOccurrences(of: "&", with: "\\u0026")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }
}
