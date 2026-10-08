import Foundation

let root = CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath
func source(_ path: String) throws -> String {
    try String(contentsOfFile: root + "/" + path, encoding: .utf8)
}
var checks = 0
func expect(_ condition: Bool, _ label: String) {
    precondition(condition, label)
    checks += 1
}
let presentation = try source("app/SourcesiOS/CinemaPresentation.swift")
expect(presentation.contains("@State private var sheetDetent: PresentationDetent = .large")
       && presentation.contains(".presentationDetents([.medium, .large], selection: $sheetDetent)"),
       "Quick View initially exposes the large sheet while retaining both detents")
let detail = try source("app/SourcesiOS/iOSDetailView.swift")
let labels = detail.components(separatedBy: "struct iOSStreamLabel: View {")[1]
    .components(separatedBy: "private struct iOSLoadingRow")[0]
expect(labels.contains("FlowLayout(spacing: 8, constrainOversizedItems: true)")
       && !labels.contains("ScrollView(.horizontal"), "source badges wrap without a hidden horizontal badge scroller")
expect(labels.contains("SourcePresentationPolicy.text(") && labels.contains("Text(verbatim: line)"),
       "wrapping preserves the add-on's authored source details")
expect(detail.contains("var constrainOversizedItems = false")
       && detail.contains("guard constrainOversizedItems, natural.width > maxWidth else { return natural }"),
       "oversized-badge bounding is opt-in; unrelated hero/action layouts retain their behavior")
expect(labels.contains(".lineLimit(1)") && labels.contains(".fixedSize(horizontal: false, vertical: true)"),
       "an oversized badge stays a single-line label, not vertical letters")
let renderer = try source("app/SourcesiOS/CinemaUISmokeIOSRendererApp.swift")
let app = try source("app/SourcesiOS/VortXiOSApp.swift")
expect(renderer.contains(".background(Theme.Palette.canvas.ignoresSafeArea())")
       && !renderer.contains("\n            .ignoresSafeArea()"),
       "native fixture content respects system safe areas; only its background bleeds")
expect(renderer.contains(".preferredColorScheme(.dark)") && app.contains(".preferredColorScheme(.dark)"),
       "fixture glass matches the production scene's dark appearance")
expect(!renderer.contains("CoreBridge.shared") && !renderer.contains("PlayerScreen("),
       "presentation correction does not construct production owners")
print("CinemaNativePresentationContractTests: \(checks) checks passed")
