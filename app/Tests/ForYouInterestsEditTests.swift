import Foundation

/// The interests picker may save only under the session it opened with (ForYouInterestsEdit.swift).
@main
enum ForYouInterestsEditTests {
    static func main() {
        let a = UUID(), b = UUID()
        var ledger = ForYouInterestsEditLedger()
        let picker = ForYouInterestsEditSession(profileID: a, initial: nil, signedIn: true)
        ledger.open(picker)
        precondition(ledger.admits(picker, activeProfile: a, signedIn: true, authorityCurrent: true))

        // A -> B before the store's synchronous retirement runs: the profile check alone refuses B.
        precondition(!ledger.admits(picker, activeProfile: b, signedIn: true, authorityCurrent: true))
        // The store retires every interests session on any profile change, so A -> B -> A stays refused.
        ledger.retireAll()
        precondition(!ledger.admits(picker, activeProfile: a, signedIn: true, authorityCurrent: true))
        print("PASS an A draft never saves into B, nor into A again after A -> B -> A")

        let fresh = ForYouInterestsEditSession(profileID: a, initial: nil, signedIn: true)
        ledger.open(fresh)
        precondition(!ledger.admits(fresh, activeProfile: a, signedIn: true, authorityCurrent: false))
        precondition(!ledger.admits(fresh, activeProfile: a, signedIn: false, authorityCurrent: true))
        print("PASS a credential change or a sign-in flip refuses the save")

        let newer = ForYouInterestsEditSession(profileID: a, initial: nil, signedIn: true)
        ledger.open(newer)
        precondition(!ledger.admits(fresh, activeProfile: a, signedIn: true, authorityCurrent: true))
        ledger.retire(fresh)   // a stale picker closing must not retire the live one
        precondition(ledger.admits(newer, activeProfile: a, signedIn: true, authorityCurrent: true))
        print("PASS a newer picker supersedes the older one, and the older one closing leaves it live")

        // A successful save retires its own session before its change note, so a second tap cannot save again
        // and the note's reload sees no live editor to invalidate.
        ledger.retire(newer)
        precondition(ledger.currentID == nil)
        precondition(!ledger.admits(newer, activeProfile: a, signedIn: true, authorityCurrent: true))
        print("PASS a saved picker cannot save twice")
    }
}
