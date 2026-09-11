import Foundation

@main
struct AddonOrderSyncTests {
    static func main() throws {
        let account = "owner-a"
        let original = ["a", "b", "c"]
        let peer = ["c", "a", "b"]
        func merge(_ remote: [String]?, _ seed: [String], _ intent: AddonOrderIntent? = nil,
                   removed: Set<String> = []) -> [String]? {
            AddonOrderSyncPolicy.merge(remote: remote, seed: seed, intent: intent,
                                      accountID: account, removed: removed)
        }
        precondition(merge(peer, original) == peer, "unrelated push must preserve the peer reorder")
        precondition(merge(peer, []) == peer, "empty engine is not permission to delete order")
        precondition(merge(peer, ["a"]) == peer, "partial engine must not shrink the remote spine")
        precondition(merge(nil, original) == original, "new account can seed its order")
        precondition(merge(nil, []) == nil, "empty account need not manufacture an order")
        let edit = AddonOrderIntent(accountID: account, order: ["b", "a", "c"])
        precondition(merge(peer + ["d"], ["e"], edit) == ["b", "a", "c", "d", "e"],
                     "explicit reorder preserves remote-only and newly installed entries")
        precondition(merge(peer, original, edit, removed: ["a"]) == ["b", "c"],
                     "order never resurrects timestamp-removed membership")
        let retry = merge(["d", "c", "b", "a"], original, edit)
        precondition(retry == ["b", "a", "c", "d"], "retry rebases captured intent on fresh remote entries")
        let otherAccount = AddonOrderIntent(accountID: "owner-b", order: ["b", "c", "a"])
        precondition(merge(peer, original, otherAccount) == peer, "intent cannot cross account scope")
        precondition(AddonOrderSyncPolicy.acknowledges(edit, sent: edit, accountID: account))
        let newer = AddonOrderIntent(accountID: account, order: peer)
        precondition(!AddonOrderSyncPolicy.acknowledges(newer, sent: edit, accountID: account),
                     "edit during GET/PUT must survive an older acknowledgement")
        let undo = AddonOrderIntent(accountID: account, order: edit.order)
        precondition(!AddonOrderSyncPolicy.acknowledges(undo, sent: edit, accountID: account),
                     "A -> B -> A is a distinct user intent, not the original acknowledgement")
        precondition(!AddonOrderSyncPolicy.acknowledges(edit, sent: edit, accountID: "owner-b"))
        precondition(!AddonOrderSyncPolicy.acknowledges(edit, sent: nil, accountID: account),
                     "unrelated accepted push cannot clear an edit")
        let restored = try JSONDecoder().decode(AddonOrderIntent.self, from: JSONEncoder().encode(edit))
        precondition(restored == edit, "offline/failure/relaunch retains exact pending nonce and order")
        precondition(merge(peer, [], restored) == edit.order, "pull while edit pending preserves the edit")
        precondition(AddonOrderSyncPolicy.unique(["a", "", "a", "b"]) == ["a", "b"])
        print("Addon order sync: 17 regressions passed")
    }
}
