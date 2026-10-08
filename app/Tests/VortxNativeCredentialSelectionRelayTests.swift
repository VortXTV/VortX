import Foundation

@MainActor private final class AccountReceiver {
    var selections: [String] = []
}

@main struct VortxNativeCredentialSelectionRelayTests {
    static func check(_ value: Bool, _ message: String) { precondition(value, message) }
    @MainActor static func main() throws {
        let relay = VortxNativeCredentialSelectionRelay()
        let appAccount = AccountReceiver()
        var currentSlot = "account-A/profile-P/uid-A/txn-1"
        relay.observe(appAccount) { $0.selections.append(currentSlot) }
        // Registration is idempotent for one app-owned model, not another model construction.
        relay.observe(appAccount) { $0.selections.append(currentSlot) }
        let initial = currentSlot
        relay.publish { currentSlot == initial }
        check(appAccount.selections == [initial], "existing app account must receive accepted selection once")
        currentSlot = "account-A/profile-P/uid-A/txn-2"
        relay.publish { currentSlot == initial }
        check(appAccount.selections.count == 1, "retired same-UID transaction must not reload newer account")
        relay.publish { true }
        check(appAccount.selections.last == currentSlot, "same-user replacement must reload despite unchanged signed-in state")

        let reentrant = VortxNativeCredentialSelectionRelay()
        let first = AccountReceiver(), second = AccountReceiver()
        var selected = "A"
        reentrant.observe(first) { account in
            account.selections.append(selected)
            if selected == "A" {
                selected = "B"
                reentrant.publish { selected == "B" }
            }
        }
        reentrant.observe(second) { $0.selections.append(selected) }
        reentrant.publish { true }
        check(first.selections == ["A", "B"] && second.selections == ["B"], "new synchronous publication must retire outer notification")
        var ephemeral: AccountReceiver? = AccountReceiver()
        weak var released = ephemeral
        reentrant.observe(ephemeral!) { _ in check(false, "deallocated observer must not fire") }
        ephemeral = nil
        check(released == nil, "relay must not retain app-owned account")
        released = nil
        reentrant.publish { selected == "B" }
        check(second.selections == ["B", "B"], "live observer remains registered")

        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let core = try String(contentsOf: root.appendingPathComponent("app/SourcesShared/CoreBridge.swift"), encoding: .utf8)
        let model = try String(contentsOf: root.appendingPathComponent("app/SourcesShared/StremioAccount.swift"), encoding: .utf8)
        check(!core.contains("StremioAccount.shared"), "account model is app-owned, not a singleton")
        check(model.contains("VortxNativeCredentialSelectionRelay.shared.observe(self) { account in\n            account.reloadForActiveProfile()"), "production existing model must register real reload callback")
        let start = core.range(of: "private func refreshNativeProfiles(reloadCredentials:")!.lowerBound
        let end = core.range(of: "func saveNativeProfile(", range: start..<core.endIndex)!.lowerBound
        let refresh = String(core[start..<end])
        let epoch = refresh.range(of: "nativePublishedAccountGeneration = snapshot.generation")!.lowerBound
        let publish = refresh.range(of: "VortxNativeCredentialSelectionRelay.shared.publish")!.lowerBound
        check(epoch < publish, "publish current native epoch before synchronous receiver checks")
        check(refresh.contains("projection.stillOwnsCurrentContext(core: self)") && refresh.contains("ProfileStore.shared.activeKeychainAccount == slot"), "callback must retain captured profile/account/installation/epoch and exact slot fences")
        check(refresh.contains("nativePublishedCredentialSlot != slot && reloadCredentials"), "explicit auth flow retains its manual reload boundary")
        check(model.contains("if isSignedIn != signedIn { isSignedIn = signedIn }"), "same-user reload must preserve published reentrancy suppression")
        print("Native credential selection relay: existing weak app model, same-user change, stale selection rejection, reentrant supersession and production epoch/slot wiring passed")
    }
}
