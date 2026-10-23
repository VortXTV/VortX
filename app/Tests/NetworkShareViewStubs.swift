import SwiftUI

// Extra signature stubs for scripts/test-network-share-views.sh, on top of ForYouViewStubs.swift. Each
// mirrors the real declaration's name, labels and shape; behavior is irrelevant.

extension Theme.Radius { static let control: CGFloat = 12 }

extension View {
    func vortxGlassField<S: InsettableShape>(in shape: S) -> some View { background(shape.fill(Color.gray)) }
}

struct PrimaryActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}

enum CredentialMutationResult: Equatable, Sendable { case success, failure }

enum Keychain {
    static func string(_ account: String) -> String? { nil }
    @discardableResult static func set(_ value: String?, for account: String) -> CredentialMutationResult { .success }
}

#if os(tvOS)
struct PlaybackRequest: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
    var headers: [String: String]? = nil
    var forceMPV: Bool = false
}

final class PlayerPresenter: ObservableObject {
    @Published var request: PlaybackRequest?
}
#else
struct iOSPlayerLaunch: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
    var headers: [String: String]? = nil
}
#endif
