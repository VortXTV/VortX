import Foundation
private enum CredentialScopeRegistry { struct Capture: Equatable { let generation: Int } }
@MainActor private final class Authority {
    var generation = 1
    func capture() -> CredentialScopeRegistry.Capture { .init(generation: generation) }
}
@MainActor private final class CoreBridge {
    static let shared = CoreBridge()
    var mount = 1
    func captureNativePlaybackTarget() -> Int { mount }
    func nativePlaybackTargetIsCurrent(_ target: Int) -> Bool { target == mount }
}
private typealias AddonOrderIntent = String
@MainActor private final class ReadHarness {
    let credentialAuthority = Authority()
    var isSignedIn = true
    var dataKey: Data? = Data([1])
    var lastSyncedVersion = 0
    var nativePreparedSeedCapture: CredentialScopeRegistry.Capture?
    var seeds = 0
    var afterRead: (() -> Void)?
    private var read: VersionedPull = .empty
    func readExisting() { read = .doc(doc: ["peer": "retained"], version: 9) }
    func isCurrent(_ capture: CredentialScopeRegistry.Capture) -> Bool { capture == credentialAuthority.capture() }
    private func pullDocVersionedResult(credentialCapture: CredentialScopeRegistry.Capture) async -> VersionedPull {
        await Task.yield(); afterRead?(); return read
    }
    private func nativeEmptyAccountDocument(capture: CredentialScopeRegistry.Capture) throws -> [String: Any] {
        guard isCurrent(capture) else { throw NSError(domain: "superseded", code: 1) }
        seeds += 1; return ["synthetic": true]
    }
    func candidate() async -> Bool { await mergeLocalIntoDoc(orderIntent: nil) != nil }
    /* PRODUCTION_READ_BOUNDARY */
}
@main @MainActor private enum CandidateReadChecks {
    static func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
        guard condition() else { print("FAIL \(label)"); exit(1) }; print("PASS \(label)")
    }
    static func main() async {
        let initial = ReadHarness()
        let admitted = await initial.candidate()
        expect(admitted, "current authenticated absent read reaches candidate construction")
        for absent in [true, false] {
            for retirement in ["credential", "key", "mount"] {
                let h = ReadHarness()
                if !absent { h.readExisting() }
                h.afterRead = {
                    if retirement == "credential" { h.credentialAuthority.generation += 1 }
                    if retirement == "key" { h.dataKey = Data([2]) }
                    if retirement == "mount" { CoreBridge.shared.mount += 1 }
                }
                let accepted = await h.candidate()
                expect(!accepted && h.seeds == 0 && h.nativePreparedSeedCapture == nil,
                       "post-read \(retirement) retirement rejects \(absent ? "absent" : "existing") candidate before seed/local effects")
            }
        }
    }
}
