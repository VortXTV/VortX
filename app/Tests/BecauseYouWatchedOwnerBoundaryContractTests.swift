// Standalone source contract for the Apple Because You Watched owner boundary.
//
// Run from repository root:
//   swiftc -warnings-as-errors -o /tmp/because-you-watched-owner-contract \
//     app/Tests/BecauseYouWatchedOwnerBoundaryContractTests.swift && \
//   /tmp/because-you-watched-owner-contract .

import Foundation

private var failures = 0

private func check(_ condition: Bool, _ name: String) {
    if condition { print("PASS  \(name)") }
    else { failures += 1; print("FAIL  \(name)") }
}

private func body(_ signature: String, in source: String) -> String? {
    guard let range = source.range(of: signature),
          let open = source[range.lowerBound...].firstIndex(of: "{") else { return nil }
    var depth = 0
    var index = open
    while index < source.endIndex {
        if source[index] == "{" { depth += 1 }
        if source[index] == "}" {
            depth -= 1
            if depth == 0 { return String(source[open...index]) }
        }
        index = source.index(after: index)
    }
    return nil
}

let root = CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath
let path = URL(fileURLWithPath: root).appendingPathComponent("app/SourcesShared/BecauseYouWatchedModel.swift")
guard let source = try? String(contentsOf: path, encoding: .utf8) else {
    print("FAIL  could not read \(path.path)")
    exit(1)
}

let refresh = body("    func refresh(", in: source) ?? ""
let clear = body("    func clear()", in: source) ?? ""
check(source.contains("private var activeOwnerKey: String?"),
      "Apple rail stores the complete history owner boundary")
check(refresh.contains("let ownerChanged = activeProfileID != profileID || activeOwnerKey != ownerKey"),
      "same-profile account/principal changes are treated as owner changes")
check(refresh.contains("if !ownerChanged, signature == lastSignature, rail != nil") &&
        refresh.contains("if !ownerChanged, signature == inFlightSignature"),
      "owner changes cannot take a cache or in-flight fast path")
check(refresh.contains("if ownerChanged {\n            rail = nil\n            lastSignature = nil\n        }") &&
        refresh.contains("activeOwnerKey = ownerKey\n\n        guard !seeds.isEmpty else"),
      "owner changes clear the visible rail before empty-history handling")
check(refresh.contains("[seeds, owned, signature, generation, profileID, ownerKey]") &&
        refresh.contains("self.requestGeneration == generation") &&
        refresh.contains("self.activeOwnerKey = ownerKey"),
      "late recommendation responses remain fenced to their owner generation")
check(clear.contains("activeOwnerKey = nil") && clear.contains("rail = nil"),
      "clear removes both owner identity and personalized output")

if failures == 0 {
    print("ALL TESTS PASSED")
    exit(0)
}
print("\(failures) TEST(S) FAILED")
exit(1)
