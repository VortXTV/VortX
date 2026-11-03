import Foundation

extension ProfilePickerToolsTVTransfer.Configuration {
    /// No file URL, settings-backup substitute, browser acknowledgement or account recapture.
    static var live: Self {
        .init(inspect: { bytes in
            // Await the real worker even when cancellation is ignored; the caller retains its slot.
            try await Task.detached(priority: .utility) {
                _ = try VortxAccountBackupFile.inspect(bytes)
            }.value
        }, make: { request in
            try ProfilePickerToolsLANChannel(request)
        })
    }
}

@MainActor
private final class ProfilePickerToolsLANChannel: ProfilePickerToolsTransferChannel {
    private let adapter: ProfilePickerToolsLANTransfer
    var owner: ProfilePickerToolsTransferPolicy.Owner { adapter.owner }
    var publication: ProfilePickerToolsTVTransfer.Publication? {
        guard let value = adapter.publication else { return nil }
        return .init(owner: value.owner, image: value.qrImage, address: value.endpoint.authority)
    }
    var stage: ProfilePickerToolsTransferPolicy.Stage { adapter.stage }
    var localSendOutcome: ProfilePickerToolsTransferPolicy.LocalSendOutcome? { adapter.localSendOutcome }
    var outputInfo: ProfilePickerToolsTransferPolicy.OutputInfo? { adapter.outputInfo }
    var failed: Bool { adapter.failure != nil }
    var hasOwnedWork: Bool { adapter.hasOwnedWork }
    var attemptsAreDrained: Bool { adapter.attemptsAreDrained }
    var networkIsDrained: Bool { adapter.networkIsDrained }
    var isDrained: Bool { adapter.isDrained }
    init(_ request: ProfilePickerToolsTVTransfer.Request) throws {
        let input: ProfilePickerToolsLANTransfer.InputHandling
        if let receiver = request.input { input = .receive(receiver) } else { input = .notAccepted }
        adapter = try ProfilePickerToolsLANTransfer(owner: request.owner, mode: request.mode,
            liveGrant: request.liveGrant, input: input, onChange: request.changed)
    }
    func start() throws { try adapter.start() }
    func showReview(owner: ProfilePickerToolsTransferPolicy.Owner) throws { try adapter.showReview(owner: owner) }
    func installOutput(_ bytes: Data, snapshotID: UUID, owner: ProfilePickerToolsTransferPolicy.Owner) throws {
        _ = try adapter.installOutput(bytes, snapshotID: snapshotID, owner: owner)
    }
    func retrySameOutput(owner: ProfilePickerToolsTransferPolicy.Owner) throws {
        _ = try adapter.retrySameOutput(owner: owner)
    }
    func retryInput(owner: ProfilePickerToolsTransferPolicy.Owner) throws { try adapter.retryInput(owner: owner) }
    func closeNetworkForRestore(owner: ProfilePickerToolsTransferPolicy.Owner) throws {
        try adapter.closeNetworkForRestore(owner: owner)
    }
    func retire() { adapter.retire() }
}
