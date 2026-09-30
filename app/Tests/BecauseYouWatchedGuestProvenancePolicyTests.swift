import Foundation

@main
private enum BecauseYouWatchedGuestProvenancePolicyTests {
    static func main() throws {
        typealias Policy = BecauseYouWatchedGuestProvenancePolicy
        precondition(Policy.exclusionReceipt(from: nil) == nil)
        precondition(Policy.exclusionReceipt(from: NSNumber(value: 0)) == nil)
        precondition(Policy.exclusionReceipt(from: "false") == nil)
        precondition(Policy.exclusionReceipt(from: false) == false)
        precondition(Policy.exclusionReceipt(from: true) == true)
        precondition(!Policy.acceptsDeviceHistory(exclusionReceipt: nil, isSignedOutDevice: true))
        precondition(!Policy.acceptsDeviceHistory(exclusionReceipt: true, isSignedOutDevice: true))
        precondition(Policy.acceptsDeviceHistory(exclusionReceipt: false, isSignedOutDevice: true))
        precondition(!Policy.acceptsDeviceHistory(exclusionReceipt: false, isSignedOutDevice: false))
        precondition(Policy.canEstablishCleanDevice(
            exclusionReceipt: nil, isSignedOutDevice: true, storageIsKnownFresh: true))
        precondition(!Policy.canEstablishCleanDevice(
            exclusionReceipt: true, isSignedOutDevice: true, storageIsKnownFresh: true))
        precondition(!Policy.canEstablishCleanDevice(
            exclusionReceipt: nil, isSignedOutDevice: true, storageIsKnownFresh: false))
        precondition(!Policy.canEstablishCleanDevice(
            exclusionReceipt: nil, isSignedOutDevice: false, storageIsKnownFresh: true))

        let fm = FileManager.default
        let fixtures = URL(fileURLWithPath: fm.currentDirectoryPath)
            .appendingPathComponent("app/build/apple-parity-contracts/guest-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: fixtures, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: fixtures) }
        let missing = fixtures.appendingPathComponent("missing", isDirectory: true)
        precondition(Policy.storageIsKnownFresh(at: missing))
        let storage = fixtures.appendingPathComponent("storage", isDirectory: true)
        try fm.createDirectory(at: storage, withIntermediateDirectories: false)
        precondition(Policy.storageIsKnownFresh(at: storage))
        let existing = storage.appendingPathComponent("previous-owner.fixture")
        try Data([0]).write(to: existing)
        precondition(!Policy.storageIsKnownFresh(at: storage))
        precondition(!Policy.storageIsKnownFresh(at: existing))
        print("PASS  17 production guest-provenance decisions and real storage fixtures")
    }
}
