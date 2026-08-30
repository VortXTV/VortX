// Executable regression contract for tvOS public issue #206.
//
//   swiftc -parse-as-library \
//     app/SourcesTV/TVDetailSourceColumnFocusPolicy.swift \
//     app/Tests/TVDetailSourceColumnFocusContractTests.swift \
//     -o /tmp/tv-detail-source-column-focus-contract \
//     && /tmp/tv-detail-source-column-focus-contract
//
// This invokes the Foundation-only production policy used by DetailView.swift. The UI wiring
// remains deliberately small: it asks this policy at its two real boundary seats rather than
// duplicating the predicate in a source-text test.

import Foundation

private var failures = 0

private func expect(_ condition: Bool, _ message: String) {
    if condition {
        print("PASS  \(message)")
    } else {
        failures += 1
        print("FAIL  \(message)")
    }
}

@main
private struct TVDetailSourceColumnFocusContractTests {
    static func main() {
        expect(!TVDetailSourceColumnFocusPolicy.filterBarOwnsUpEscape(groupsCount: 0),
               "no groups: no filter-bar escape")
        expect(!TVDetailSourceColumnFocusPolicy.filterBarOwnsUpEscape(groupsCount: 1),
               "one group: no filter-bar escape")
        expect(TVDetailSourceColumnFocusPolicy.filterBarOwnsUpEscape(groupsCount: 2),
               "two groups: filter bar owns the escape")
        expect(TVDetailSourceColumnFocusPolicy.filterBarOwnsUpEscape(groupsCount: 5),
               "many groups: filter bar owns the escape")

        for groupsCount in [0, 1] {
            expect(TVDetailSourceColumnFocusPolicy.sourceRowOwnsUpEscape(at: 0, groupsCount: groupsCount),
                   "\(groupsCount) group(s): first source row owns the escape")
            for index in 1...5 {
                expect(!TVDetailSourceColumnFocusPolicy.sourceRowOwnsUpEscape(at: index, groupsCount: groupsCount),
                       "\(groupsCount) group(s): source row \(index) keeps native Up")
            }
        }

        for groupsCount in [2, 5] {
            for index in 0...5 {
                expect(!TVDetailSourceColumnFocusPolicy.sourceRowOwnsUpEscape(at: index, groupsCount: groupsCount),
                       "\(groupsCount) groups: source row \(index) keeps native Up below the filter bar")
            }
        }

        exit(failures == 0 ? 0 : 1)
    }
}
