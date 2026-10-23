import Combine
import Foundation

// The runner extracts TVSearchFieldModel directly from the shipping SearchView.
@main
@MainActor
enum TVSearchFieldModelTests {
    static func main() {
        let field = TVSearchFieldModel()
        var hostChanges = 0
        var queryChanges = 0
        let host = field.objectWillChange.sink { hostChanges += 1 }
        let query = field.live.objectWillChange.sink { queryChanges += 1 }
        var checks = 0
        func expect(_ condition: Bool, _ label: String) {
            precondition(condition, label)
            checks += 1
        }

        expect(field.fieldText.isEmpty && field.live.text.isEmpty, "empty initial query")
        for value in ["c", "ca", "café", "café 日本語"] { field.userTyped(value) }
        expect(field.fieldText == "café 日本語" && field.live.text == field.fieldText,
               "typing preserves exact Unicode text in field and content")
        expect(queryChanges == 4, "each changed keystroke publishes to the child")
        expect(hostChanges == 0 && field.programmaticRevision == 0,
               "typing never invalidates the searchable host")
        field.userTyped(field.fieldText)
        expect(queryChanges == 4 && hostChanges == 0, "duplicate bindings publish nothing")
        field.submitted.fire()
        field.submitted.fire()
        expect(field.submitted.count == 2, "repeated Return submits even with unchanged text")
        expect(hostChanges == 0 && queryChanges == 4, "Return does not rewrite or republish the text")
        field.replace(with: "  Recent Search  ")
        expect(field.fieldText == "  Recent Search  " && field.live.text == field.fieldText,
               "Recent Search replaces both exact query values")
        expect(field.programmaticRevision == 1 && hostChanges == 1 && queryChanges == 5,
               "programmatic changes alone refresh the host")
        field.userTyped("")
        expect(field.fieldText.isEmpty && field.live.text.isEmpty, "clear updates field and child")
        expect(hostChanges == 1 && queryChanges == 6, "clear still avoids host invalidation")
        field.replace(with: "")
        expect(field.programmaticRevision == 2 && hostChanges == 2,
               "same-value programmatic replacement remains an explicit refresh")
        withExtendedLifetime((host, query)) {}
        print("PASS TVSearchFieldModelTests: \(checks) actual-source input and observation checks")
    }
}
