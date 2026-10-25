import Foundation

/// Source wiring only. The real SwiftUI helper and its callers still require the Apple SDK build
/// and mounted-view timing/lease checks; these assertions do not model that framework behavior.
@main
struct ValueChangeObservationContractTests {
    static func main() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func read(_ path: String) throws -> String {
            try String(contentsOf: app.appendingPathComponent(path), encoding: .utf8)
        }
        let helper = try read("SourcesShared/ValueChangeObservation.swift")
        let player = try read("Sources/PlayerScreen.swift")
        let detail = try read("SourcesiOS/iOSDetailView.swift")
        let root = try read("SourcesiOS/iOSRootView.swift")
        let keys = try read("SourcesShared/MetadataKeysView.swift")
        precondition(helper.components(separatedBy: "#available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)").count == 3,
                     "both overloads retain an actual older-iOS fallback")
        precondition(helper.contains("onChange(of: value, initial: false) { _, newValue in action(newValue) }")
                     && helper.contains("onChange(of: value, perform: action)"),
                     "one-value actions forward the callback's actual new value without initial delivery")
        precondition(helper.contains("onChange(of: value, initial: false, action)")
                     && helper.contains("onChange(of: value) { [value] newValue in action(value, newValue) }"),
                     "old-value effects receive framework old/new values or the original iOS16 capture")
        precondition(!helper.contains("Task {") && !helper.contains("DispatchQueue")
                     && !helper.contains("initial: true") && !helper.contains(".onAppear")
                     && !helper.contains("@unchecked") && !helper.contains("@preconcurrency"),
                     "the adapter adds no delivery hop, initial effect or suppression")
        precondition(player.contains(".onValueChange(of: curDebridRef?.nativeUsenetLease) { oldLease, newLease in")
                     && player.contains("if oldLease != newLease { oldLease?.close() }"),
                     "lease replacement closes only the explicit previous lease")
        precondition(detail.components(separatedBy: "static let defaultValue: CGFloat").count == 4
                     && !detail.contains("static var defaultValue: CGFloat"),
                     "all three preference defaults are immutable, not actor-isolated protocol workarounds")
        precondition(detail.contains("extension iOSSourceList: @MainActor Equatable {")
                     && detail.components(separatedBy: ".equatable()").count >= 4,
                     "the UI equality witness retains the source-list diff optimization on its actual owner")
        precondition(detail.contains("String(describing: profiles.activeID)"),
                     "optional episode-rail scope keeps its prior debug-string identity explicitly")
        precondition(root.contains("@MainActor\nfinal class AppleSearchPresentation: ObservableObject {")
                     && root.contains("self.results = self.projectResults(items)")
                     && root.contains("self.suggestionsRefreshScheduled = false"),
                     "search presentation retains immediate accepted payload projection and coalesced committed suggestions")
        precondition(keys.contains("@MainActor\n@ViewBuilder fileprivate func metaKeyField")
                     && keys.contains("@MainActor\n@ViewBuilder fileprivate func metaURLField"),
                     "both shared key field builders run on the presentation owner")
        print("PASS 10 SwiftUI compatibility/owner source-wiring checks; no mounted-view proof claimed")
    }
}
