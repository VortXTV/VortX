import Foundation

/// Cold classification only. A source-bearing response must reach its typed authenticated
/// reader before any Foundation/Double projection; classification is not schema acceptance.
actor VortxNativeOwnerHistoryIngress {
    static let shared = VortxNativeOwnerHistoryIngress()
    enum Failure: Error { case mainThreadExecution }
    func requiresTypedRoute(_ plaintext: Data) throws -> Bool {
        guard !Thread.isMainThread else { throw Failure.mainThreadExecution }
        try Task.checkCancellation()
        let account = try OwnerHistoryExactJSON.Object(plaintext)
        if account["nativeOwnerHistorySources"] != nil { return true }
        guard let nativeBytes = account["nativeSync"] else { return false }
        let native = try OwnerHistoryExactJSON.Object(nativeBytes)
        let typed = native["ownerHistory"] != nil || native["schemaVersion"] == Data("6".utf8)
        try Task.checkCancellation()
        return typed
    }
}
