import Foundation

/// Executes verbatim production receipt methods in the mechanically extracted, typed facade
/// fixture. It does not instantiate a native session or establish actual bridge concurrency.
enum RandomPickNavigationOwnerTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func fixture() -> RandomNavigationFacadeFixture {
        let fixture = RandomNavigationFacadeFixture()
        fixture.values["native_state"] = .object(["activeProfileId": .string("profile-A")])
        return fixture
    }

    static func run() {
        let busy = fixture()
        let expected = busy.watchlistBinding!
        let receipt = busy.captureAcceptedNavigation(expected: expected)!
        expect(busy.acceptedNavigationIsCurrent(receipt), "current acknowledged navigation")
        busy.pendingProfileTransitions = 1
        expect(busy.registryBinding == nil, "mutation binding still rejects queued merge")
        expect(busy.acceptedNavigationIsCurrent(receipt), "unchanged busy merge retains accepted navigation")
        expect(busy.captureAcceptedNavigation(expected: expected) == receipt, "read-only capture ignores queue occupancy")
        busy.pendingProfileTransitions = 0
        expect(busy.registryBinding != nil && busy.acceptedNavigationIsCurrent(receipt), "unchanged merge acknowledgement")

        let account = fixture()
        let accountReceipt = account.captureAcceptedNavigation(expected: account.watchlistBinding!)!
        account.accountEpoch = UUID()
        expect(!account.acceptedNavigationIsCurrent(accountReceipt), "account generation replacement")
        account.accountEpoch = UUID()
        expect(!account.acceptedNavigationIsCurrent(accountReceipt), "same identity account ABA remains retired")

        let profile = fixture()
        let profileReceipt = profile.captureAcceptedNavigation(expected: profile.watchlistBinding!)!
        profile.values["native_state"] = .object(["activeProfileId": .string("profile-B")])
        profile.watchlistProfileGeneration = UUID()
        expect(!profile.acceptedNavigationIsCurrent(profileReceipt), "acknowledged profile B")
        profile.values["native_state"] = .object(["activeProfileId": .string("profile-A")])
        profile.watchlistProfileGeneration = UUID()
        expect(!profile.acceptedNavigationIsCurrent(profileReceipt), "profile A-B-A generation remains retired")

        let registry = fixture()
        let registryReceipt = registry.captureAcceptedNavigation(expected: registry.watchlistBinding!)!
        registry.resourceRegistryValid = false
        expect(!registry.acceptedNavigationIsCurrent(registryReceipt), "invalid registry cannot retain navigation")
        expect(registry.captureAcceptedNavigation(expected: registry.watchlistBinding!) == nil, "invalid registry cannot mint navigation")
        registry.registryGeneration = UUID()
        registry.resourceRegistryValid = true
        expect(!registry.acceptedNavigationIsCurrent(registryReceipt), "replacement registry generation retires navigation")
        registry.registryGeneration = UUID()
        expect(!registry.acceptedNavigationIsCurrent(registryReceipt), "registry ABA remains retired")

        for boundary in ["closed", "checkpoint", "missing-profile", "account-scope", "owner-scope", "profile-id"] {
            let current = fixture()
            let owner = current.watchlistBinding!
            let captured = current.captureAcceptedNavigation(expected: owner)!
            switch boundary {
            case "closed": current.closed = true
            case "checkpoint": current.checkpointReopenRequired = true
            case "missing-profile": current.values["native_state"] = .object([:])
            case "account-scope": current.session.scope = .init(account: "other-account", ownerProfileID: "owner-A")
            case "owner-scope": current.session.scope = .init(account: "account-A", ownerProfileID: "other-owner")
            default: current.values["native_state"] = .object(["activeProfileId": .string("profile-B")])
            }
            expect(!current.acceptedNavigationIsCurrent(captured), "boundary retires receipt: " + boundary)
            expect(current.captureAcceptedNavigation(expected: owner) == nil, "stale expected owner rejected: " + boundary)
        }
        let stale = fixture()
        let oldOwner = stale.watchlistBinding!
        stale.watchlistProfileGeneration = UUID()
        expect(stale.captureAcceptedNavigation(expected: oldOwner) == nil, "capture cannot substitute newer acknowledged owner")
        let fresh = stale.captureAcceptedNavigation(expected: stale.watchlistBinding!)!
        expect(stale.acceptedNavigationIsCurrent(fresh), "fresh explicit full admission can capture new owner")
        print("Random Pick accepted-navigation production receipt tests PASS")
    }
}
