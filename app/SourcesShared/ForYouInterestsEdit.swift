import Foundation

/// The interests picker's original gesture: the profile it opened for, whether that profile was signed in, and
/// the choices it showed. `ForYouStore` pairs it with the credential scope and native admission of that moment
/// and retires it synchronously on any profile, sign-in or credential change, so a draft opened for profile A
/// can never be saved into B, including A -> B -> A where a profile check alone would pass.
struct ForYouInterestsEditSession: Identifiable, Equatable, Sendable {
    let id: UUID
    let profileID: UUID
    let initial: ForYouInterests?
    let signedIn: Bool

    init(profileID: UUID, initial: ForYouInterests?, signedIn: Bool, id: UUID = UUID()) {
        self.id = id
        self.profileID = profileID
        self.initial = initial
        self.signedIn = signedIn
    }
}

/// Which interests session is live. Kept apart from the store so its ordering is testable on its own.
struct ForYouInterestsEditLedger: Equatable, Sendable {
    private(set) var currentID: UUID?

    mutating func open(_ session: ForYouInterestsEditSession) { currentID = session.id }
    /// Retires only the named session; a newer one stays live.
    mutating func retire(_ session: ForYouInterestsEditSession) { if currentID == session.id { currentID = nil } }
    mutating func retireAll() { currentID = nil }

    /// A save may write only while its own session is still the live one, for the same profile and sign-in
    /// state, under an authority (credential scope and native admission) that is still current.
    func admits(_ session: ForYouInterestsEditSession, activeProfile: UUID?, signedIn: Bool, authorityCurrent: Bool) -> Bool {
        currentID == session.id && activeProfile == session.profileID && signedIn == session.signedIn && authorityCurrent
    }
}
