import Foundation
import Combine

// Generated fixture executes the actual production picker methods and selected event callbacks.
// It does not instantiate SwiftUI, the app, Keychain, checkpoint storage, or any account client.
@propertyWrapper
struct Cell<Value> {
    final class Box { var value: Value; init(_ value: Value) { self.value = value } }
    let box: Box
    init(wrappedValue: Value) { box = Box(wrappedValue) }
    var wrappedValue: Value {
        get { box.value }
        nonmutating set { box.value = newValue }
    }
}

struct UserProfile: Equatable {
    var id = UUID()
    var name: String
    var avatar = "test"
    var accentID = "test"
    var pin: String?
    var hasPin: Bool { pin != nil }
}

@MainActor final class CredentialScopeRegistry {
    struct Capture: Equatable { let generation: Int }
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
    var pickedThisLaunch = false
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

@MainActor struct PickerHarness {
    let store: FakeStore
    let core: FakeCore
    let nativeSync = FakeSync()
    let account = FakeAccount()
    let theme = FakeTheme()
    let artwork = FakeArtwork()
    let profileAction = ProfileMutationPresentation()
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

    init(_ profiles: [UserProfile]) {
        CredentialScopeRegistry.shared.change()
        store = FakeStore(profiles)
        core = FakeCore(store)
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
    func unlock(_ prompt: UserProfile) { finishPIN(prompt) }
    func resume() { resumeDeferredSelection() }
    func foreground() { scenePhase = .active; resumeDeferredSelection() }
    func dismissAuth() { signInNeeded = false; signInChanged(false) }
    func signInChanged(_ presented: Bool) { /* ACTUAL_SIGNIN_EVENT */
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
        do {
            let (h, a, _) = fixture(); h.tap(a)
            await until("ready selection") { !h.profileAction.isRunning }
            precondition(h.store.selected == [a.id] && h.account.reloads == 1 && h.deferredSelection.profileID == nil)
            precondition(h.store.pickedThisLaunch && h.store.finishPickerArguments == [false])
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
