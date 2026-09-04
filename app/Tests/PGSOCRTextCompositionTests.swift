// Pure regression contract for PGS OCR composition cleanup.
//
// Run with:
//   swiftc -parse-as-library -o /tmp/pgs-text-composition \
//     app/Sources/Player/PGSOCRTextComposition.swift \
//     app/Tests/PGSOCRTextCompositionTests.swift && /tmp/pgs-text-composition

import Foundation

@main
enum PGSOCRTextCompositionTests {
    static func main() {
        var failures = 0
        func check(_ name: String, _ condition: @autoclosure () -> Bool) {
            if condition() {
                print("PASS  \(name)")
            } else {
                failures += 1
                print("FAIL  \(name)")
            }
        }

        check("normalizes whitespace without changing visual order",
              PGSOCRTextComposition.normalizedLines([
                "  First\tline  ",
                "Second\nline",
                "Third line",
              ]) == ["First line", "Second line", "Third line"])
        check("removes only exact normalized duplicates in one composition",
              PGSOCRTextComposition.normalizedLines([
                "Hello   world",
                "Hello world",
                "HELLO WORLD",
                "Hello world!",
              ]) == ["Hello world", "HELLO WORLD", "Hello world!"])
        check("drops empty OCR observations",
              PGSOCRTextComposition.normalizedLines([" \n\t ", ""]) == [])

        if failures > 0 { exit(1) }
    }
}
