// Executable contract:
//
//   xcrun swiftc -o /tmp/web-embedding-safety-contract \
//     app/SourcesShared/WebEmbeddingSafety.swift \
//     app/Tests/WebEmbeddingSafetyContractTests.swift &&
//     /tmp/web-embedding-safety-contract

import Foundation

private var failures = 0

private func check(_ name: String, _ condition: Bool) {
    if condition {
        print("PASS  \(name)")
    } else {
        failures += 1
        print("FAIL  \(name)")
    }
}

private func decoded(_ literal: String) -> String? {
    guard let data = "[\(literal)]".data(using: .utf8),
          let values = try? JSONSerialization.jsonObject(with: data) as? [String] else {
        return nil
    }
    return values.first
}

@main
private enum WebEmbeddingSafetyContractTests {
    static func main() {
        let ordinary = "dQw4w9WgXcQ"
        check(
            "ordinary YouTube identifier round-trips",
            decoded(WebEmbeddingSafety.javaScriptStringLiteral(ordinary)) == ordinary)

        let hostile = "'; alert(1); </script><script>alert(2)</script>\u{2028}\u{2029}&"
        let hostileLiteral = WebEmbeddingSafety.javaScriptStringLiteral(hostile)
        check("hostile value round-trips", decoded(hostileLiteral) == hostile)
        check("literal cannot close its script element", !hostileLiteral.lowercased().contains("</script"))
        check("legacy line separators are escaped",
              hostileLiteral.contains("\\u2028") && hostileLiteral.contains("\\u2029"))

        if failures > 0 {
            print("\n\(failures) FAILED")
            exit(1)
        }
        print("\nALL PASS")
    }
}
