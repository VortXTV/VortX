// Standalone executable contract for the shipping application/x-www-form-urlencoded encoder.
//
// Extract DebridForm from DebridResolver.swift, then compile the exact production implementation:
//
//   sed -n '1p;/^enum DebridForm {/,/^enum DebridHTTP {/p' app/SourcesShared/DebridResolver.swift |
//     sed '$d' > /tmp/vortx-debrid-form.swift &&
//   xcrun swiftc /tmp/vortx-debrid-form.swift app/Tests/DebridFormEncodingTests.swift \
//     -o /tmp/vortx-debrid-form-tests &&
//   /tmp/vortx-debrid-form-tests

import Foundation

private var failures = 0

private func check(_ condition: Bool, _ name: String) {
    if condition {
        print("PASS  \(name)")
    } else {
        failures += 1
        print("FAIL  \(name)")
    }
}

private func body(_ data: Data) -> String {
    String(decoding: data, as: UTF8.self)
}

@main
private enum DebridFormEncodingTests {
    static func main() {
        let magnet = "magnet:?xt=urn:btih:abc&dn=A+B C/é"
        check(
            body(DebridForm.encode(["magnet": magnet]))
                == "magnet=magnet%3A%3Fxt%3Durn%3Abtih%3Aabc%26dn%3DA%2BB+C%2F%C3%A9",
            "magnet delimiters, literal plus, space, slash, and UTF-8 are encoded"
        )

        check(
            body(DebridForm.encode([("items[]", "a&b"), ("items[]", "c=d")]))
                == "items%5B%5D=a%26b&items%5B%5D=c%3Dd",
            "repeated keys retain order without allowing value injection"
        )

        check(
            body(DebridForm.encode([("a&b", "x=y")])) == "a%26b=x%3Dy",
            "field names cannot inject additional form fields"
        )

        if failures == 0 {
            print("ALL TESTS PASSED")
            exit(0)
        }
        print("\(failures) TEST(S) FAILED")
        exit(1)
    }
}
