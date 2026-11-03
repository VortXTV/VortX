import Foundation
import Combine

// Generated fixture executes the actual production picker methods and selected event callbacks.
// It does not instantiate SwiftUI, the app, Keychain, checkpoint storage, or any account client.
@propertyWrapper
struct Cell<Value> {
    final class Box { var value: Value; init(_ value: Value) { self.value = value } }
    let box: Box
    init(wrappedValue: Value) { box = Box(wrappedValue) }
    init(initialValue: Value) { box = Box(initialValue) }
    var wrappedValue: Value {
        get { box.value }
        nonmutating set { box.value = newValue }
    }
}

// Explicit SwiftUI State initialization seam. The assigned value comes from the actual initializer.
typealias State<Value> = Cell<Value>

struct UserProfile: Equatable {
    var id = UUID()
    var name: String
    var avatar = "test"
    var accentID = "test"
    var pin: String?
    var isKids = false
    var hasPin: Bool { pin != nil }
}

// Explicit account-scope collaborators for actual openTools route capture. No account I/O.
enum CredentialScope: Equatable, Sendable {
    case fixture
    init?(canonicalRemoteAccountID: String) {
        guard canonicalRemoteAccountID == "fixture-account" else { return nil }
        self = .fixture
    }
}

@MainActor final class CredentialScopeRegistry {
    struct Capture: Equatable, Sendable { let generation: Int; var scope: CredentialScope { .fixture } }
    static let shared = CredentialScopeRegistry()
    private var generation = 0
    func capture() -> Capture { .init(generation: generation) }
    func isCurrent(_ capture: Capture) -> Bool { capture == self.capture() }
    func change() { generation += 1 }
}

@MainActor final class FakeStore {
    var profiles: [UserProfile]
    var activeID: UUID?
    var nativeProfileError: String?
    /* ACTUAL_PICKER_PRESENTATION_STATE */
    /* ACTUAL_PICKER_NEEDED */
    var selectResult = true
    var selected: [UUID] = []
    var finishPickerArguments: [Bool] = []
    var afterSelection: (() -> Void)?
    init(_ profiles: [UserProfile]) { self.profiles = profiles; activeID = profiles.first?.id }
    func selectNative(_ profile: UserProfile, admission: FakeCore.Admission, finishPicker: Bool = true) async -> Bool {
        selected.append(profile.id)
        finishPickerArguments.append(finishPicker)
        await Task.yield()
        guard CredentialScopeRegistry.shared.isCurrent(admission.owner) else {
            nativeProfileError = "Synthetic superseded owner"; return false
        }
        guard selectResult else { nativeProfileError = "Synthetic checkpoint write failure"; return false }
        activeID = profile.id
        if finishPicker { pickedThisLaunch = true }
        nativeProfileError = nil
        let completed = afterSelection; afterSelection = nil; completed?()
        return true
    }
}

@MainActor final class FakeCore {
    struct Admission {
        let owner: CredentialScopeRegistry.Capture
        var credential: CredentialScopeRegistry.Capture { owner }
    }
    let store: FakeStore
    var certified = true
    var modes: [UUID: String] = [:]
    init(_ store: FakeStore) { self.store = store }
    func hasCertifiedNativeSession(capture: CredentialScopeRegistry.Capture, profileID: UUID?) -> Bool {
        certified && CredentialScopeRegistry.shared.isCurrent(capture) && profileID == store.activeID
    }
    func captureNativeProfileActionAdmission() -> Admission { .init(owner: CredentialScopeRegistry.shared.capture()) }
    var nativeProfileRecoveryMessage: String { "Synthetic profile preparation failure" }
    func nativeAccountMode(profileID: UUID) -> String { modes[profileID] ?? "shared" }
}

@MainActor final class FakeSync {
    enum RestoreState { case idle, restoring, ready, failed }
    @Published var nativeCheckpointStatus = "mounted"
    @Published var accountRestoreState = RestoreState.idle
    var isSignedIn = true
    struct Account { let id: String }
    var account: Account? = .init(id: "fixture-account")
    var accountReconnectRequired = false
    var preparations = 0
    var continuation: CheckedContinuation<Bool, Never>?
    func prepareNativeProfileSelection(credentialCapture: CredentialScopeRegistry.Capture) async -> Bool {
        preparations += 1
        return await withCheckedContinuation { continuation = $0 }
    }
    func complete(_ accepted: Bool) {
        precondition(continuation != nil, "No synthetic preparation waiting")
        let pending = continuation; continuation = nil; pending?.resume(returning: accepted)
    }
}
@MainActor final class FakeAccount {
    var reloads = 0
    var isSignedIn = true
    var signInError: String?
    func reloadForActiveProfile() { reloads += 1 }
}
struct FakeTheme { let accentID = "test" }
final class FakeArtwork { var stops = 0; func stopRotation() { stops += 1 } }
enum FakeScene { case active, background }
@MainActor final class Lifetime { var subscriptions = Set<AnyCancellable>(); var live = true }

@MainActor final class FakeAuthentication {
    var credentialChanges = 0
    var blocksDismissal = false
    func credentialDidChange() { credentialChanges += 1 }
}
/// Explicit controller collaborator for extracted picker retirement. Real Tools schedules have their own suite.
@MainActor final class ProfilePickerToolsController {
    typealias Owner = ProfilePickerToolsAccountOwner
    static let shared = ProfilePickerToolsController()
    var credentialChanges = 0
    var dismissed: [UUID] = []
    func credentialDidChange() { credentialChanges += 1 }
    func dismiss(_ id: UUID) { dismissed.append(id) }
}
// The root setter bodies are production-extracted; these are explicit presentation collaborators.
@MainActor final class PickerRootHarness {
    let profiles: FakeStore
    let profileAuthentication = FakeAuthentication()
    init(_ profiles: FakeStore) { self.profiles = profiles }
    func admissionAtConstruction() -> @MainActor @Sendable () -> Bool { /* ACTUAL_ROOT_PICKER_ARGUMENT */
    }
    func dismissalAtConstruction() -> (@MainActor @Sendable () -> Void)? { /* ACTUAL_ROOT_PICKER_DISMISSAL_ARGUMENT */
    }
    func setIOSPresented(_ presented: Bool) { /* ACTUAL_IOS_PICKER_DISMISSAL */
    }
    func setTVPresented(_ presented: Bool) { /* ACTUAL_TV_PICKER_DISMISSAL */
    }
}

@MainActor struct PickerHarness {
    let store: FakeStore
    let core: FakeCore
    let nativeSync = FakeSync()
    let account = FakeAccount()
    let theme = FakeTheme()
    let artwork = FakeArtwork()
    let profileAction = ProfileMutationPresentation()
    let accountAuthentication = FakeAuthentication()
    let lifetime = Lifetime()
    @Cell var scenePhase = FakeScene.active
    @Cell var deferredSelection = NativeProfileActionPreparation.DeferredSelection<CredentialScopeRegistry.Capture>()
    @Cell var pinCredential: CredentialScopeRegistry.Capture? = nil
    @Cell var signInCredential: CredentialScopeRegistry.Capture? = nil
    @Cell var signInProfileID: UUID? = nil
    @Cell var pinTarget: UserProfile? = nil
    @Cell var pinIsForEditing = false
    @Cell var editorProfile: UserProfile? = nil
    @Cell var isEditing = false
    @Cell var signInNeeded = false
    @Cell var accountHelpNeeded = false
    @Cell var accountHelpAllowsDiagnostics = false
    @Cell var accountHelpDiagnosticCredential: CredentialScopeRegistry.Capture? = nil
    @Cell var accountHelpDiagnosticGrant: ProfilePickerToolsDiagnosticGrant? = nil
    @Cell var toolsRoute: ProfilePickerToolsRoute? = nil
    @Cell var pickerAdmission: (@MainActor @Sendable () -> Bool)? = nil
    @Cell var manualPickerDismissal: (@MainActor @Sendable () -> Void)? = nil

    init(_ profiles: [UserProfile], manualPicker: Bool = false, originalStore: FakeStore? = nil,
         capturedAdmission: (@MainActor @Sendable () -> Bool)? = nil,
         capturedDismissal: (@MainActor @Sendable () -> Void)? = nil) {
        CredentialScopeRegistry.shared.change()
        store = originalStore ?? FakeStore(profiles)
        core = FakeCore(store)
        if manualPicker { store.requestPicker() }
        let pickerAdmission = capturedAdmission ?? store.manualPickerToolsAdmission()
        let manualPickerDismissal = capturedDismissal ?? store.manualPickerDismissal()
        /* ACTUAL_PICKER_STATE_INITIALIZER */
        /* ACTUAL_PICKER_DISMISSAL_INITIALIZER */
    }
    func installObservers() {
        profileAction.$errorMessage.dropFirst().sink { _ in
            Task { @MainActor in if lifetime.live { resumeDeferredSelection() } }
        }.store(in: &lifetime.subscriptions)
        nativeSync.$nativeCheckpointStatus.dropFirst().sink { _ in
            Task { @MainActor in if lifetime.live { resumeDeferredSelection() } }
        }.store(in: &lifetime.subscriptions)
        nativeSync.$accountRestoreState.dropFirst().sink { _ in
            // SwiftUI observes the coalesced render value, not every Combine willSet payload.
            Task { @MainActor in if lifetime.live { restoreChanged(nativeSync.accountRestoreState) } }
        }.store(in: &lifetime.subscriptions)
    }
    func stop() { lifetime.live = false; lifetime.subscriptions.removeAll(); disappear() }
    func tap(_ profile: UserProfile) { pick(profile) }
    func openToolsForTest() { openTools() }
    func backForTest() { closeManualPicker() }
    func appearForTest() {} // Production has no appearance-time admission capture.
    func closeToolsForTest() { if let route = toolsRoute { closeTools(route.id) } }
    func unlock(_ prompt: UserProfile) { finishPIN(prompt) }
    func resume() { resumeDeferredSelection() }
    func foreground() { scenePhase = .active; resumeDeferredSelection() }
    func dismissAuth() { signInNeeded = false; signInChanged(false) }
    func signInChanged(_ presented: Bool) { /* ACTUAL_SIGNIN_EVENT */
    }
    func dismissAccountHelp() { accountHelpNeeded = false; accountHelpChanged(false) }
    func accountHelpChanged(_ presented: Bool) { /* ACTUAL_ACCOUNT_HELP_EVENT */
    }
    func credentialChanged() { /* ACTUAL_CREDENTIAL_EVENT */
    }
    func disappear() { /* ACTUAL_DISAPPEAR_EVENT */
    }
    func restoreChanged(_ state: FakeSync.RestoreState) { /* ACTUAL_RESTORE_EVENT */
    }
    func add() { /* ACTUAL_ADD_ACTION */
    }
    func edit() { /* ACTUAL_EDIT_ACTION */
    }
    func recoverAccount() { /* ACTUAL_RECOVERY_ACTION */
    }

/* ACTUAL_PICKER_ADMISSION */
/* ACTUAL_PREPARING */
/* ACTUAL_METHODS */
}

@main enum PickerSourceExtractionTests {
    @MainActor static func drain(_ count: Int = 40) async {
        for _ in 0..<count { await Task.yield() }
    }
    @MainActor static func until(_ label: String, _ predicate: () -> Bool) async {
        for _ in 0..<2000 {
            if predicate() { return }
            await Task.yield()
        }
        preconditionFailure("Timed out: \(label)")
    }
    @MainActor static func fixture(pin: String? = nil) -> (PickerHarness, UserProfile, UserProfile) {
        let first = UserProfile(name: "Synthetic A", pin: pin)
        let second = UserProfile(name: "Synthetic B")
        let h = PickerHarness([first, second]); h.installObservers()
        return (h, first, second)
    }
    @MainActor static func ready(_ h: PickerHarness) {
        h.core.certified = true; h.nativeSync.nativeCheckpointStatus = "mounted"
    }
    @MainActor static func busy(_ h: PickerHarness) {
        h.core.certified = false; h.nativeSync.nativeCheckpointStatus = "restoring"
    }
    @MainActor static func main() async {
        var passed = 0
        for count in 0...1 {
            for observer in ["root", "grant"] {
                let profiles = (0..<count).map { UserProfile(name: "Original \($0)") }
                let store = FakeStore(profiles)
                store.requestPicker()
                let original = store.manualPickerToolsAdmission()
                if count == 0 { store.activeID = UUID() } else { store.profiles[0].isKids = true }
                if observer == "root" { precondition(!store.needsPicker) } else { precondition(!original()) }
                // Mac can remove the cover directly, without invoking a binding setter.
                // Returning to the original projection cannot revive that observed-retired request.
                if count == 0 { store.activeID = nil } else { store.profiles[0].isKids = false }
                precondition(!store.needsPicker && !original(), "observed retirement is one-way")
                store.requestPicker()
                precondition(store.needsPicker && store.manualPickerToolsAdmission()() && !original())
                passed += 1
            }
        }
        do {
            let h = PickerHarness([], manualPicker: true)
            precondition(h.manualPickerDismissal != nil && h.store.needsPicker)
            h.openToolsForTest(); precondition(h.toolsRoute != nil)
            h.closeToolsForTest(); precondition(h.store.needsPicker)
            h.accountAuthentication.blocksDismissal = true
            h.backForTest(); precondition(h.store.needsPicker)
            h.accountAuthentication.blocksDismissal = false
            let capture = CredentialScopeRegistry.shared.capture()
            h.profileAction.start(operation: { await h.nativeSync.prepareNativeProfileSelection(credentialCapture: capture) },
                failureMessage: { "Synthetic held profile operation" }, onSuccess: {})
            await until("manual Back held by profile action") { h.nativeSync.continuation != nil }
            h.backForTest(); precondition(h.store.needsPicker)
            h.nativeSync.complete(false)
            await until("manual Back profile action ends") { !h.profileAction.isRunning }
            h.backForTest(); precondition(!h.store.needsPicker && h.store.pickedThisLaunch)
            h.stop(); passed += 1
        }
        do {
            let old = PickerHarness([], manualPicker: true)
            old.store.requestPicker()
            old.backForTest(); precondition(old.store.needsPicker, "stale Back cannot consume replacement")
            let current = PickerHarness([], originalStore: old.store)
            current.backForTest(); precondition(!old.store.needsPicker)
            let ordinary = PickerHarness([UserProfile(name: "A"), UserProfile(name: "B")])
            precondition(ordinary.manualPickerDismissal == nil)
            ordinary.backForTest(); precondition(ordinary.store.needsPicker, "ordinary picker has no manual Back")
            old.stop(); current.stop(); ordinary.stop(); passed += 1
        }
        for count in 0...1 {
            let profiles = (0..<count).map { UserProfile(name: "Original \($0)") }
            let store = FakeStore(profiles)
            store.requestPicker()
            let root = PickerRootHarness(store)
            // The actual root argument is evaluated and retained by the actual State assignment
            // while constructing A. No appearance event has occurred when B replaces the request.
            let a = PickerHarness([], originalStore: store, capturedAdmission: root.admissionAtConstruction(), capturedDismissal: root.dismissalAtConstruction())
            store.requestPicker()
            a.appearForTest(); a.openToolsForTest(); a.recoverAccount(); a.add(); a.edit()
            precondition(a.toolsRoute == nil && !a.accountHelpNeeded && a.editorProfile == nil && !a.isEditing)
            let b = PickerHarness([], originalStore: store, capturedAdmission: root.admissionAtConstruction(), capturedDismissal: root.dismissalAtConstruction())
            b.appearForTest(); b.openToolsForTest()
            let route = b.toolsRoute!
            precondition(route.accountFiles.permits(route.accountFiles.owner!))
            a.stop(); b.stop(); passed += 1
        }
        // Actual store state/gate plus both actual root dismissal setters. No SwiftUI host is created.
        for change in ["dismissal", "replacement", "kids", "pin", "stale-empty", "became-multiple"] {
            let empty = change == "stale-empty"
            let h = PickerHarness(empty ? [] : [UserProfile(name: "Original adult")], manualPicker: true)
            h.openToolsForTest(); precondition(h.toolsRoute != nil)
            h.closeToolsForTest()
            switch change {
            case "dismissal": h.store.pickedThisLaunch = true
            case "replacement": h.store.requestPicker()
            case "kids": h.store.profiles[0].isKids = true
            case "pin": h.store.profiles[0].pin = "synthetic-pin"
            case "stale-empty": h.store.activeID = UUID()
            case "became-multiple": h.store.profiles.append(UserProfile(name: "Another adult"))
            default: preconditionFailure()
            }
            h.appearForTest() // Reappearance cannot adopt the new request or reinterpret nil as ordinary.
            h.openToolsForTest(); h.recoverAccount(); h.add(); h.edit()
            precondition(h.toolsRoute == nil && !h.accountHelpNeeded && h.editorProfile == nil && !h.isEditing, change)
            if change != "replacement" { precondition(!h.store.needsPicker, "manual-only eligibility retired") }
            h.stop(); passed += 1
        }
        for count in 0...2 {
            for platform in ["iOS/Mac", "tvOS"] {
                let store = FakeStore((0..<count).map { UserProfile(name: "Synthetic \($0)") })
                let root = PickerRootHarness(store)
                precondition(store.needsPicker == (count > 1), "ordinary cold launch")
                store.requestPicker()
                precondition(store.needsPicker, "explicit zero/one/multiple request")
                let admission = store.manualPickerToolsAdmission()
                precondition(admission())
                root.profileAuthentication.blocksDismissal = true
                if platform == "tvOS" { root.setTVPresented(false) } else { root.setIOSPresented(false) }
                precondition(store.needsPicker && admission(), "authentication still blocks dismissal")
                root.profileAuthentication.blocksDismissal = false
                if platform == "tvOS" { root.setTVPresented(true) } else { root.setIOSPresented(true) }
                precondition(store.needsPicker, "presenting does not consume the request")
                if platform == "tvOS" { root.setTVPresented(false) } else { root.setIOSPresented(false) }
                precondition(!store.needsPicker && store.pickedThisLaunch, "dismissal consumes the request")
                precondition(!admission(), "original presentation admission retired")
                store.pickedThisLaunch = false
                precondition(store.needsPicker == (count > 1), "ordinary reset does not recreate a manual request")
                store.requestPicker()
                precondition(store.needsPicker, "explicit reopen")
                if count < 2 { precondition(!admission(), "replacement does not revive old admission") }
                passed += 1
            }
        }
        for restriction in ["kids", "pin", "unmatched", "empty-stale-active"] {
            var profile = UserProfile(name: "Restricted")
            if restriction == "kids" { profile.isKids = true }
            if restriction == "pin" { profile.pin = "synthetic-pin" }
            let store = FakeStore(restriction == "empty-stale-active" ? [] : [profile])
            if restriction == "unmatched" || restriction == "empty-stale-active" { store.activeID = UUID() }
            precondition(!store.canRequestPicker)
            store.requestPicker()
            precondition(!store.needsPicker, restriction)
            store.profiles = [profile, UserProfile(name: "Existing alternative")]
            precondition(store.canRequestPicker && store.needsPicker, "existing multi-profile policy remains")
            passed += 1
        }
        for change in ["empty-populated", "kids", "pin", "active", "roster", "dismissal", "replacement", "pending-pin", "credential"] {
            let empty = change == "empty-populated"
            let h = PickerHarness(empty ? [] : [UserProfile(name: "Current adult")], manualPicker: true)
            h.openToolsForTest()
            let route = h.toolsRoute!
            let owner = route.accountFiles.owner!
            precondition(route.accountFiles.permits(owner) && route.diagnostics.permitsExport)
            switch change {
            case "empty-populated": h.store.profiles.append(UserProfile(name: "Restored adult"))
            case "kids": h.store.profiles[0].isKids = true
            case "pin": h.store.profiles[0].pin = "synthetic-pin"
            case "active": h.store.activeID = UUID()
            case "roster": h.store.profiles[0] = UserProfile(name: "Replacement adult")
            case "dismissal": h.store.pickedThisLaunch = true
            case "replacement": h.store.requestPicker()
            case "pending-pin": h.pinTarget = h.store.profiles[0]
            case "credential": CredentialScopeRegistry.shared.change()
            default: preconditionFailure()
            }
            precondition(!route.accountFiles.permits(owner), change)
            // Pending-PIN diagnostic revocation is an existing separate policy; this delta adds
            // the original manual admission to every pre-existing diagnostic grant boundary.
            if change != "pending-pin" { precondition(!route.diagnostics.permitsExport, change) }
            h.stop(); passed += 1
        }
        do {
            let h = PickerHarness([UserProfile(name: "Current adult")], manualPicker: true)
            let original = h.store.manualPickerToolsAdmission()
            let admission = h.core.captureNativeProfileActionAdmission()
            let selected = await h.store.selectNative(h.store.profiles[0], admission: admission, finishPicker: false)
            precondition(selected)
            precondition(h.store.needsPicker && original(), "editor selection retains manual parent")
            h.tap(h.store.profiles[0])
            await until("manual ordinary selection finishes") { !h.profileAction.isRunning }
            precondition(h.store.pickedThisLaunch && !h.store.needsPicker && !original())
            h.stop(); passed += 1
        }
        do {
            let (h, _, _) = fixture(pin: "synthetic-pin")
            h.recoverAccount()
            precondition(h.accountHelpNeeded && !h.accountHelpAllowsDiagnostics)
            precondition(h.accountHelpDiagnosticCredential == CredentialScopeRegistry.shared.capture())
            let refused = h.accountHelpDiagnosticGrant!
            precondition(!refused.permitsExport)
            h.toolsRoute = .init(diagnostics: refused, focusDiagnostics: false)
            let retiredRoute = h.toolsRoute!.id
            CredentialScopeRegistry.shared.change(); h.credentialChanged()
            precondition(!refused.permitsExport && h.toolsRoute == nil
                         && ProfilePickerToolsController.shared.dismissed.contains(retiredRoute))
            precondition(!h.accountHelpAllowsDiagnostics && h.accountHelpDiagnosticCredential == nil
                         && h.accountAuthentication.credentialChanges == 1)
            h.stop(); passed += 1
        }
        do {
            let (h, _, b) = fixture(pin: "synthetic-pin")
            h.store.selectResult = false; h.tap(b)
            await until("synthetic failed-open diagnostic admission") { h.profileAction.errorMessage != nil }
            h.recoverAccount()
            precondition(h.accountHelpAllowsDiagnostics
                         && h.accountHelpDiagnosticCredential == CredentialScopeRegistry.shared.capture())
            let grant = h.accountHelpDiagnosticGrant!
            precondition(grant.permitsExport)
            h.disappear() // Full-screen Account help hides its presenter.
            precondition(h.profileAction.errorMessage != nil && grant.permitsExport)
            h.restoreChanged(.ready)
            precondition(grant.permitsExport) // The nested QR inherits this same original grant.
            h.dismissAccountHelp()
            precondition(h.accountHelpDiagnosticGrant == nil && h.profileAction.errorMessage == nil && !grant.permitsExport)
            h.stop(); passed += 1
        }
        do {
            let (h, a, _) = fixture()
            h.nativeSync.accountReconnectRequired = true
            h.tap(a); await drain()
            precondition(h.store.selected.isEmpty && h.nativeSync.preparations == 0
                         && h.deferredSelection.profileID == nil)
            h.stop(); passed += 1
        }
        do {
            let (h, a, _) = fixture(); busy(h); h.tap(a)
            precondition(h.deferredSelection.profileID == a.id)
            h.nativeSync.accountReconnectRequired = true
            ready(h); h.resume(); await drain()
            precondition(h.store.selected.isEmpty && h.deferredSelection.profileID == nil)
            h.stop(); passed += 1
        }
        do {
            let (h, a, _) = fixture(); h.tap(a)
            await until("ready selection") { !h.profileAction.isRunning }
            precondition(h.store.selected == [a.id] && h.account.reloads == 1 && h.deferredSelection.profileID == nil)
            precondition(h.store.pickedThisLaunch && h.store.finishPickerArguments == [false])
            h.stop(); passed += 1
        }
        do {
            let (h, a, _) = fixture(pin: "1111"); h.tap(a)
            let original = h.pinTarget!
            h.nativeSync.accountReconnectRequired = true
            h.unlock(original); await drain()
            precondition(h.pinTarget == nil && h.store.selected.isEmpty && !h.store.pickedThisLaunch)
            h.stop(); passed += 1
        }
        do {
            let (h, a, _) = fixture(); h.core.certified = false; h.nativeSync.nativeCheckpointStatus = "not_started"
            h.tap(a); await until("prepare starts") { h.nativeSync.continuation != nil }
            precondition(h.nativeSync.preparations == 1 && h.pinTarget == nil && h.store.selected.isEmpty)
            var fresh = a; fresh.pin = "2222"; h.store.profiles[0] = fresh
            ready(h); h.nativeSync.complete(true)
            await until("fresh PIN after mount") { h.pinTarget?.pin == "2222" }
            precondition(h.store.selected.isEmpty && h.deferredSelection.profileID == nil)
            h.unlock(h.pinTarget!); await until("fresh PIN accepted") { !h.profileAction.isRunning }
            precondition(h.store.selected == [a.id]); h.stop(); passed += 1
        }
        do {
            let (h, a, b) = fixture(); busy(h); h.tap(a); h.tap(b)
            precondition(h.nativeSync.preparations == 0 && h.deferredSelection.profileID == b.id)
            ready(h); await until("last choice opens") { h.store.selected == [b.id] && !h.profileAction.isRunning }
            await drain(); precondition(h.store.selected == [b.id]); h.stop(); passed += 1
        }
        for change in ["owner", "deleted", "disappear", "edit", "add", "account"] {
            let (h, a, _) = fixture(); busy(h); h.tap(a)
            switch change {
            case "owner": CredentialScopeRegistry.shared.change(); h.credentialChanged()
            case "deleted": h.store.profiles.removeAll { $0.id == a.id }
            case "disappear": h.disappear()
            case "edit": h.edit()
            case "add": h.add()
            case "account": h.recoverAccount()
            default: preconditionFailure()
            }
            ready(h); await drain()
            precondition(h.store.selected.isEmpty && h.deferredSelection.profileID == nil, change)
            h.stop(); passed += 1
        }
        for modal in ["pin", "editor", "signin", "account", "edit"] {
            let (h, a, b) = fixture(); busy(h); h.tap(a)
            switch modal {
            case "pin": h.pinTarget = b
            case "editor": h.editorProfile = b
            case "signin": h.signInNeeded = true
            case "account": h.accountHelpNeeded = true
            case "edit": h.isEditing = true
            default: preconditionFailure()
            }
            ready(h); await drain(); precondition(h.store.selected.isEmpty, modal)
            h.stop(); passed += 1
        }
        do {
            let (h, a, _) = fixture()
            h.nativeSync.accountRestoreState = .restoring; h.tap(a)
            precondition(h.core.certified && h.deferredSelection.profileID == a.id)
            h.nativeSync.accountRestoreState = .failed
            // A scene/error/checkpoint resume may arrive before the failure observer.
            // Production routing must not depend on SwiftUI modifier callback ordering.
            h.resume()
            await drain()
            precondition(h.store.selected.isEmpty && h.deferredSelection.profileID == nil)
            h.stop(); passed += 1
        }
        for afterPreparation in [false, true] {
            let (h, a, _) = fixture(); h.store.selectResult = false
            if afterPreparation { h.core.certified = false; h.nativeSync.nativeCheckpointStatus = "not_started" }
            h.tap(a)
            if afterPreparation {
                await until("before failed mutation preparation") { h.nativeSync.continuation != nil }
                ready(h); h.nativeSync.complete(true)
            }
            await until("one failed real mutation") { h.profileAction.errorMessage != nil }
            await drain(100)
            precondition(h.store.selected == [a.id] && h.deferredSelection.profileID == nil && h.account.reloads == 0)
            precondition(!h.store.pickedThisLaunch)
            h.stop(); passed += 1
        }
        do {
            let (h, a, _) = fixture(pin: "1111"); h.tap(a); let oldPrompt = h.pinTarget!
            busy(h); h.unlock(oldPrompt)
            precondition(h.pinTarget == nil && h.store.selected.isEmpty && h.deferredSelection.profileID == a.id)
            var fresh = a; fresh.pin = "2222"; h.store.profiles[0] = fresh; ready(h)
            await until("new PIN following late restore") { h.pinTarget?.pin == "2222" }
            precondition(h.store.selected.isEmpty)
            h.unlock(h.pinTarget!); await until("late restore PIN accepted") { !h.profileAction.isRunning }
            precondition(h.store.selected == [a.id]); h.stop(); passed += 1
        }
        do {
            let (h, a, _) = fixture(pin: "1111"); h.tap(a); let oldPrompt = h.pinTarget!
            var fresh = a; fresh.pin = "2222"; h.store.profiles[0] = fresh
            h.unlock(oldPrompt)
            precondition(h.pinTarget?.pin == "2222" && h.store.selected.isEmpty)
            h.stop(); passed += 1
        }
        for change in ["owner", "deleted"] {
            let (h, a, _) = fixture(pin: "1111"); h.tap(a); let oldPrompt = h.pinTarget!
            if change == "owner" { CredentialScopeRegistry.shared.change() }
            else { h.store.profiles.removeAll { $0.id == a.id } }
            h.unlock(oldPrompt)
            precondition(h.pinTarget == nil && h.pinCredential == nil && h.store.selected.isEmpty)
            h.stop(); passed += 1
        }
        do {
            let (h, a, _) = fixture(); h.core.certified = false; h.nativeSync.nativeCheckpointStatus = "not_started"
            h.tap(a); await until("cancelled preparation starts") { h.nativeSync.continuation != nil }
            h.disappear(); ready(h); h.nativeSync.complete(true); await drain()
            precondition(h.store.selected.isEmpty && h.pinTarget == nil && h.deferredSelection.profileID == nil)
            h.stop(); passed += 1
        }
        do {
            let (h, a, _) = fixture(); busy(h); h.tap(a); h.scenePhase = .background
            ready(h); await drain(); precondition(h.store.selected.isEmpty)
            h.foreground(); await until("foreground resume") { !h.profileAction.isRunning }
            precondition(h.store.selected == [a.id]); h.stop(); passed += 1
        }
        do {
            let (h, a, _) = fixture(); h.nativeSync.accountRestoreState = .failed
            await drain() // Old failure is not a new failure of the next explicit attempt.
            h.core.certified = false; h.nativeSync.nativeCheckpointStatus = "not_started"; h.tap(a)
            await until("retry from old failed status") { h.nativeSync.continuation != nil }
            ready(h); h.nativeSync.complete(true)
            await until("old failure manual retry succeeds") { h.store.selected == [a.id] && !h.profileAction.isRunning }
            h.stop(); passed += 1
        }
        for outcome in ["cancel", "failure", "owner", "profile", "uncertified", "signed-out", "wrong-mode", "success", "covered-success"] {
            let (h, a, b) = fixture(); h.core.modes[b.id] = "pending_own"
            h.tap(b); await until("pending own child auth") { !h.profileAction.isRunning }
            precondition(h.store.selected == [b.id] && h.store.finishPickerArguments == [false])
            precondition(h.signInNeeded && !h.store.pickedThisLaunch && h.signInProfileID == b.id)
            if outcome == "covered-success" {
                h.disappear() // A full-screen child hides its presenter without retiring its identity.
                precondition(h.signInCredential != nil && h.signInProfileID == b.id)
            }
            if outcome != "cancel" { h.core.modes[b.id] = "own" }
            switch outcome {
            case "failure": h.account.signInError = "Synthetic unconfirmed connection"
            case "owner": CredentialScopeRegistry.shared.change(); h.credentialChanged()
            case "profile": h.store.activeID = a.id
            case "uncertified": h.core.certified = false
            case "signed-out": h.account.isSignedIn = false
            case "wrong-mode": h.core.modes[b.id] = "shared"
            default: break
            }
            h.dismissAuth()
            precondition(h.store.pickedThisLaunch == (outcome == "success" || outcome == "covered-success"), outcome)
            precondition(h.signInCredential == nil && h.signInProfileID == nil)
            h.stop(); passed += 1
        }
        for change in ["owner", "profile", "certification"] {
            let (h, a, b) = fixture()
            h.store.afterSelection = {
                if change == "owner" { CredentialScopeRegistry.shared.change() }
                if change == "profile" { h.store.activeID = b.id }
                if change == "certification" { h.core.certified = false }
            }
            h.tap(a); await until("selection completion fence") { !h.profileAction.isRunning }
            precondition(h.store.selected == [a.id] && !h.store.pickedThisLaunch && !h.signInNeeded && h.account.reloads == 0, change)
            h.stop(); passed += 1
        }
        print("PASS: \(passed) production-extracted picker event journeys; real presentation task/cancellation; no app, account, Keychain or storage operations.")
    }
}
