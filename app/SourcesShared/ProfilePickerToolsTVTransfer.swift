import Foundation
import CoreGraphics

/// TV-specific delivery is deliberately separate from a verified local file Saved receipt.
/// The interface also permits actual controller callback scheduling with inert test transports.
@MainActor
protocol ProfilePickerToolsTransferChannel: AnyObject {
    var owner: ProfilePickerToolsTransferPolicy.Owner { get }
    var publication: ProfilePickerToolsTVTransfer.Publication? { get }
    var stage: ProfilePickerToolsTransferPolicy.Stage { get }
    var localSendOutcome: ProfilePickerToolsTransferPolicy.LocalSendOutcome? { get }
    var outputInfo: ProfilePickerToolsTransferPolicy.OutputInfo? { get }
    var failed: Bool { get }
    var hasOwnedWork: Bool { get }
    var attemptsAreDrained: Bool { get }
    var networkIsDrained: Bool { get }
    var isDrained: Bool { get }
    func start() throws
    func showReview(owner: ProfilePickerToolsTransferPolicy.Owner) throws
    func installOutput(_ bytes: Data, snapshotID: UUID, owner: ProfilePickerToolsTransferPolicy.Owner) throws
    func retrySameOutput(owner: ProfilePickerToolsTransferPolicy.Owner) throws
    func retryInput(owner: ProfilePickerToolsTransferPolicy.Owner) throws
    func closeNetworkForRestore(owner: ProfilePickerToolsTransferPolicy.Owner) throws
    func retire()
}

@MainActor
enum ProfilePickerToolsTVTransfer {
    typealias P = ProfilePickerToolsTransferPolicy
    typealias Grant = @MainActor @Sendable (P.Owner) -> Bool
    typealias Receiver = @MainActor @Sendable (P.ImmutableInput) async -> Void
    typealias Change = @MainActor @Sendable (P.Owner) -> Void
    struct Publication {
        let owner: P.Owner
        let image: CGImage
        // Numeric host:port only. Sensitive capability URL is never exposed as text or logged.
        let address: String
    }
    struct Request {
        let owner: P.Owner
        let mode: P.Mode
        let liveGrant: Grant
        let input: Receiver?
        let changed: Change
    }
    struct Configuration {
        let inspect: @Sendable (Data) async throws -> Void
        let make: @MainActor @Sendable (Request) throws -> any ProfilePickerToolsTransferChannel
    }
}
