// Compile the REAL shared settings view at the oldest supported iOS deployment target:
// xcrun swiftc -typecheck -swift-version 5 -target arm64-apple-ios16.0 \
//   -sdk "$(xcrun --sdk iphoneos --show-sdk-path)" \
//   app/Tests/ServerConfigViewAvailabilityTests.swift app/SourcesShared/ServerConfigView.swift
// Only app-wide styling/server dependencies are stubs. SwiftUI, the complete view body and its lifecycle
// handlers are real, so accidentally choosing the iOS-17-only two-argument onChange fails compilation.
import SwiftUI

enum StremioServer {
    static let isCustom = false
    static let base = "http://127.0.0.1:11470"
    static func normalize(_ value: String) -> String? { value }
    static func reachable(_ value: String) async -> Bool { true }
    static func setBase(_ value: String) {}
    static func useEmbedded() {}
}

enum Theme {
    enum Palette {
        static let canvas = Color.black
        static let textPrimary = Color.white
        static let textSecondary = Color.gray
        static let textTertiary = Color.gray
        static let danger = Color.red
    }
    enum Space {
        static let sm: CGFloat = 8
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
        static let screenInset: CGFloat = 24
    }
    enum Radius { static let control: CGFloat = 12 }
    enum Typography { static let body = Font.body }
}

struct PrimaryActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}
struct ChipButtonStyle: ButtonStyle {
    var selected = false
    var accent = Color.orange
    var accentText = Color.orange
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}
extension View {
    func screenTitleStyle() -> some View { self }
    func vortxGlassField<S: Shape>(in shape: S) -> some View { self }
}
