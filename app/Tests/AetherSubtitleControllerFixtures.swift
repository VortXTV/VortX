import Foundation
import os

// Synthetic chrome/account collaborators for the complete maintained Aether controller harness.
// Real guarded source parsing, outbox and native decode remain separate app/integration gates.
enum SubtitlePoolClient {
    struct ContributionLoad: Sendable {
        final class State: Sendable { let active = OSAllocatedUnfairLock(initialState: true) }
        let token: PlayerLoadToken
        private let state = State()
        init(token: PlayerLoadToken) { self.token = token }
        var isCurrent: Bool { state.active.withLock { $0 } }
        func retire() { state.active.withLock { $0 = false } }
    }
}
struct PlayerLocalSubtitleSource: Sendable {
    let data: Data
    var format = "srt"
    var identityURL = URL(string: "https://example.invalid/guarded.srt")!
    let permitsUse: @Sendable () -> Bool
    func preparedNativeSubtitle() -> (data: Data, format: String)? {
        permitsUse() && !data.isEmpty ? (data, format) : nil
    }
}
enum PlayerExternalSubtitleSelectionResult { case superseded, failed, selectedWithoutAlignment }
struct PlayerSubtitleAlignmentOwner: Sendable {
    let account = 1
    let applicationEpoch: UUID
    let mount = 1
}
struct CredentialScopeRegistry {
    typealias Capture = Int
    static let shared = Self()
    func capture() -> Int { 1 }
    func isCurrent(_ value: Int) -> Bool { value == 1 }
}
enum LegacyWatchOwnership {
    struct SubtitleRendererEpochObservation: Sendable {}
    static func observeSubtitleRendererRetirement(ifCurrent: UUID,
        retire: @escaping @Sendable () -> Void) -> SubtitleRendererEpochObservation? { .init() }
    static func removeSubtitleRendererRetirement(_ observation: SubtitleRendererEpochObservation) {}
    static let epoch = UUID()
    static func captureApplicationEpoch() -> UUID? { epoch }
    static func applicationEpochIsCurrent(_ value: UUID) -> Bool { value == epoch }
}
enum CredentialPublicationOutbox {
    struct SubtitleEffectLease: Sendable {}
    struct SubtitleRendererRegistration: Sendable {}
    static func tryBeginSubtitleEffect(_ owner: Int) -> SubtitleEffectLease? { .init() }
    static func endSubtitleEffect(_ lease: SubtitleEffectLease) {}
    static func unregisterSubtitleRenderer(_ registration: SubtitleRendererRegistration) -> Bool { true }
    static func registerSubtitleRenderer(_ lease: SubtitleEffectLease,
        revoke: @escaping @Sendable () -> Bool) -> SubtitleRendererRegistration? { .init() }
}
final class AVKitSubtitleAlignmentPublication: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)
    private let clear: @MainActor @Sendable (AVKitSubtitleAlignmentPublication) -> Void
    init(clear: @escaping @MainActor @Sendable (AVKitSubtitleAlignmentPublication) -> Void) { self.clear = clear }
    var isRevoked: Bool { state.withLock { $0 } }
    func install(_ registration: CredentialPublicationOutbox.SubtitleRendererRegistration) -> Bool { !isRevoked }
    func revoke() -> Bool { state.withLock { $0 = true }; return false }
    @MainActor func close() { state.withLock { $0 = true }; clear(self) }
}
