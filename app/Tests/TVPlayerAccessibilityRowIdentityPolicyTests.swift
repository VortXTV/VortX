import Foundation

// Run from the repository root:
//   (sed -n '1p' app/Tests/TVPlayerAccessibilityRowIdentityPolicyTests.swift; \
//    sed -n '/^enum TVPlayerAccessibilityRowIdentityPolicy/,/^\/\/ END TVPlayerAccessibilityRowIdentityPolicy/p' \
//      app/SourcesTV/TVPlayerView.swift; \
//    sed -n '2,$p' app/Tests/TVPlayerAccessibilityRowIdentityPolicyTests.swift) | xcrun swift -

private struct Check {
    var failures = 0

    mutating func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if condition() {
            print("PASS: \(message)")
        } else {
            failures += 1
            print("FAIL: \(message)")
        }
    }
}

private func row(_ label: String, header: Bool = false, explicitID: String? = nil)
    -> TVPlayerAccessibilityRowIdentityPolicy.Candidate {
    .init(explicitID: explicitID, label: label, isHeader: header)
}

private var check = Check()

let initial = [row("Audio", header: true), row("English"), row("French")]
let initialIDs = TVPlayerAccessibilityRowIdentityPolicy.identities(panelKey: "audio", rows: initial)

// A late track can insert above the focused row. Its index changes, but semantic identity must not.
let refreshed = [row("Audio", header: true), row("Spanish"), row("French"), row("English")]
let refreshedIDs = TVPlayerAccessibilityRowIdentityPolicy.identities(panelKey: "audio", rows: refreshed)
let englishID = initialIDs[1]
let restoredEnglish = TVPlayerAccessibilityRowIdentityPolicy.restoredFocusIndex(
    previousID: englishID,
    identities: refreshedIDs,
    fallback: 1
)
check.require(restoredEnglish == 3, "focus follows the English row after an async insertion and reorder")
check.require(refreshedIDs[3] == englishID, "a unique semantic row keeps its identity across snapshots")

// Same-label rows remain unique and deterministic by occurrence, preventing the UIKit dictionary from
// trapping on duplicate keys while still retaining focus when the snapshot is rebuilt unchanged.
let duplicateRows = [row("Track"), row("Track"), row("Track")]
let duplicateIDsA = TVPlayerAccessibilityRowIdentityPolicy.identities(panelKey: "audio", rows: duplicateRows)
let duplicateIDsB = TVPlayerAccessibilityRowIdentityPolicy.identities(panelKey: "audio", rows: duplicateRows)
check.require(Set(duplicateIDsA).count == 3, "same-label rows receive unique occurrence identities")
check.require(duplicateIDsA == duplicateIDsB, "same-label occurrence identities are deterministic")

// Explicit source/track keys win, but an accidental duplicate is still made safe and stable.
let explicitRows = [row("Source A", explicitID: "sources.stream.safe"),
                    row("Source B", explicitID: "sources.stream.safe")]
let explicitIDs = TVPlayerAccessibilityRowIdentityPolicy.identities(panelKey: "sources", rows: explicitRows)
check.require(explicitIDs == ["sources.stream.safe", "sources.stream.safe.duplicate.1"],
              "explicit duplicate identities are disambiguated without crashing")

// Provider-controlled text is hashed into an opaque bounded key rather than copied into the semantic id.
let sensitiveLabel = "https://cdn.example/video?token=private-value"
let opaqueID = TVPlayerAccessibilityRowIdentityPolicy.identities(
    panelKey: "subtitles",
    rows: [row(sensitiveLabel)]
)[0]
check.require(!opaqueID.contains("private-value") && opaqueID.hasPrefix("panel.row."),
              "implicit identities do not expose provider-controlled text")

let fallback = TVPlayerAccessibilityRowIdentityPolicy.restoredFocusIndex(
    previousID: englishID,
    identities: ["different"],
    fallback: 0
)
check.require(fallback == 0, "removed rows fall back to the caller's first selectable row")

if check.failures > 0 {
    print("TV player accessibility row identity policy failed: \(check.failures)")
    exit(1)
}
print("TV player accessibility row identity policy passed")
