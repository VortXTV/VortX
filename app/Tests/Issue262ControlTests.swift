import Foundation

// Inert collaborators for byte-for-byte production QR/auth/override methods. The script supplies
// these methods and records their hashes. No Keychain, defaults, account, engine, UI or network.
@MainActor private final class Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    func wait() async { if !released { await withCheckedContinuation { waiters.append($0) } } }
    func release() { released = true; let all = waiters; waiters = []; for waiter in all { waiter.resume() } }
}
@MainActor private final class ProfileStore {
    struct Profile { let id: UUID }
    static let shared = ProfileStore()
    var active: Profile? = .init(id: UUID())
    var activeKeychainAccount: String { active?.id.uuidString ?? "owner" }
}
@MainActor private final class CredentialScopeRegistry {
    struct Capture: Equatable { let generation: Int }
    static let shared = CredentialScopeRegistry()
    var generation = 1
    func capture() -> Capture { .init(generation: generation) }
    func isCurrent(_ capture: Capture) -> Bool { capture.generation == generation }
}
private enum VortxNativeError: Error { case closed }
private enum VortxNativeOwnerAddonImport { struct Incomplete: Error {} }
// Inert error carrier matching the actual typed outcome; production catch/reload code is extracted unchanged.
private enum OwnerHistoryLoginPreparation {
    struct Incomplete: Error {
        enum Reason: Sendable { case pendingMetadata, importUnavailable }
        let reason: Reason
    }
}
private enum VortxNativeAccountCredentials { struct OwnerPublicationUncertain: Error {} }
private enum VortxNativeOwnAccountProducer {
    static func invalidate(slot: String) {}
    static func invalidateContext() {}
}
// Watch-epoch locking/notification is outside this control-only fixture. The extracted
// methods retain their actual call; this inert collaborator performs no session work.
private enum LegacyWatchOwnership {
    static func invalidateSession() {}
}
@MainActor private enum Keychain {
    static var token: String?
    static func string(_ slot: String) -> String? { token }
}
private struct Log { func info(_ message: String) {} }
@MainActor private final class CoreBridge {
    static let shared = CoreBridge()
    var gate: Gate?
    var error: (any Error)?
    var admission = true
    var installs = 0
    var handoffs = 0
    func signedInWithLegacyAuthKey() { handoffs += 1 }
    func awaitAddonsHydrated() async {}
    func captureNativeAccountLogin(importOwnerAddons: Bool) throws -> Int? { admission ? 1 : nil }
    func authenticateNativeOwnAccount(token: String, target: Int) async throws {
        installs += 1
        if let gate { await gate.wait() }
        if let error {
            if error is VortxNativeOwnerAddonImport.Incomplete || error is VortxNativeAccountCredentials.OwnerPublicationUncertain
                || error is OwnerHistoryLoginPreparation.Incomplete {
                Keychain.token = "persisted-fixture-only"
            }
            throw error
        }
        Keychain.token = "persisted-fixture-only"
    }
    func reset() { gate = nil; error = nil; admission = true; installs = 0; handoffs = 0 }
}
@MainActor private final class StremioAccount {
    var signInError: String?
    var publicationWarnings: [String?] = []
    var isSignedIn = false { didSet { if isSignedIn { publicationWarnings.append(signInError) } } }
    var streamSources: [String] = []
    var addons: [String] = []
    var email: String?
    var credentialBoundaryGeneration: UInt64 = 0
    private var authOperationGeneration: UInt64 = 0
    private var tokenKey: String { ProfileStore.shared.activeKeychainAccount }
    private let log = Log()
    var backfillGate: Gate?
    var publications = 0
    var addonReads = 0
    static var storedTokens: [String] = []
    static func storeAuthKey(_ token: String, account: String) { storedTokens.append(token); Keychain.token = token }
    static func displayEmail() -> String? { nil }
    func publishCredentialBoundary(wasSignedIn: Bool) { publications += 1; credentialBoundaryGeneration &+= 1 }
    private func backfillEmail(for context: AuthOperationContext) async { if let backfillGate { await backfillGate.wait() } }
    private func loadAddons(for context: AuthOperationContext) async { addonReads += 1 }
    /* PRODUCTION_ACCOUNT */
}
@MainActor private enum LinkAuthService {
    struct LinkCode { let code: String; let link: String }
    enum ReadResult { case pending, authKey(String) }
    struct Failure: LocalizedError { let errorDescription: String? }
    static var createGate: Gate?
    static var readGate: Gate?
    static var validationGate: Gate?
    static var validationError: (any Error)?
    static var createCount = 0
    static var readError: (any Error)?
    static var validationCount = 0
    static func create() async throws -> LinkCode {
        createCount += 1; let number = createCount
        if let createGate { await createGate.wait() }
        return .init(code: "code-\(number)", link: "https://fixture.invalid/\(number)")
    }
    static func read(code: String) async throws -> ReadResult {
        if let readGate { await readGate.wait() }
        if let readError { throw readError }
        return .authKey("fixture-only")
    }
    @discardableResult static func validate(authKey: String) async throws -> String? {
        validationCount += 1
        if let validationGate { await validationGate.wait() }
        if let validationError { throw validationError }
        return nil
    }
    static func reset() {
        createGate = nil; readGate = nil; validationGate = nil; validationError = nil
        createCount = 0; readError = nil; validationCount = 0
    }
}
@MainActor private final class QRFixture {
    let account: StremioAccount
    var busy = false
    var code: LinkAuthService.LinkCode?
    var qrImage: String?
    var status = ""
    var errorMessage: String?
    var pollTask: Task<Void, Never>?
    var pollGeneration = UUID()
    var signingIn = false
    static let pollInterval: Duration = .nanoseconds(1) // inert accelerated clock aperture
    static var timeout: TimeInterval = 300
    static let maxConsecutiveFailures = 5
    init(_ account: StremioAccount) { self.account = account }
    static func makeQRCodeImage(_ link: String) -> String? { link }
    func run() { start() }
    func cancel() { stop() }
    /* PRODUCTION_QR */
}
@MainActor private final class VortXSyncManager {
    static let shared = VortXSyncManager()
    func snapshotOwnedFromEngine() async {}
    struct Account { let id: String }
    struct AddonOrderIntent: Equatable { let accountID: String; let order: [String] }
    var account: Account? = .init(id: "fixture")
    var hasAppliedAccountDoc = false
    var pendingAddonOrderIntent: AddonOrderIntent?
    var uploadCalls = 0
    var lastOverride: Bool?
    static func currentAddonOrder() -> [String] { ["existing"] }
    func withRemoteApplySuppressed(_ action: () -> Void) { action() }
    func syncUp(afterUserChoseThisDevice: Bool) async -> Bool {
        uploadCalls += 1; lastOverride = afterUserChoseThisDevice; return true
    }
    /* PRODUCTION_OVERRIDE */
}
@MainActor private class HandoffFixture {
    let account: StremioAccount
    let core = CoreBridge.shared
    var didHandleSignIn = false
    var connecting = true
    var dismissals = 0
    init(_ account: StremioAccount) { self.account = account }
    func dismiss() { dismissals += 1 }
    func run(_ signedIn: Bool) { fatalError("subclass must exercise production helper") }
}
@MainActor private final class TVHandoffFixture: HandoffFixture {
    override func run(_ signedIn: Bool) { handleStremioSignIn(signedIn: signedIn) }
    /* PRODUCTION_TV */
}
@MainActor private final class IOSHandoffFixture: HandoffFixture {
    override func run(_ signedIn: Bool) { handleStremioSignIn(signedIn: signedIn) }
    /* PRODUCTION_IOS */
}
@MainActor private final class CardHandoffFixture: HandoffFixture {
    override func run(_ signedIn: Bool) { handleStremioSignIn(signedIn: signedIn) }
    /* PRODUCTION_CARD */
}
@main private enum Issue262ControlTests {
    @MainActor private static var checks = 0
    @MainActor private static func check(_ condition: Bool, _ name: String) {
        checks += 1
        guard condition else { print("FAIL \(name)"); exit(1) }
        print("PASS \(name)")
    }
    @MainActor private static func drain() async { for _ in 0..<150 { await Task.yield() } }
    @MainActor private static func reset() {
        CoreBridge.shared.reset(); LinkAuthService.reset(); QRFixture.timeout = 300
        ProfileStore.shared.active = .init(id: UUID()); CredentialScopeRegistry.shared.generation += 1
        StremioAccount.storedTokens = []
        Keychain.token = nil
    }
    @MainActor static func main() async {
        reset()
        let success = StremioAccount(), qrSuccess = QRFixture(success)
        qrSuccess.run(); await qrSuccess.pollTask?.value
        check(success.isSignedIn && qrSuccess.status.isEmpty && qrSuccess.errorMessage == nil,
              "successful production QR control clears Signing in")
        check(!qrSuccess.busy && !qrSuccess.signingIn, "successful completion retires busy state")

        #if VORTX_NATIVE_DATA_ENGINE
        for error in [VortxNativeError.closed as any Error, VortxNativeOwnerAddonImport.Incomplete(),
                      VortxNativeAccountCredentials.OwnerPublicationUncertain(),
                      OwnerHistoryLoginPreparation.Incomplete(reason: .pendingMetadata),
                      OwnerHistoryLoginPreparation.Incomplete(reason: .importUnavailable)] {
            reset(); CoreBridge.shared.error = error
            let account = StremioAccount(), qr = QRFixture(account)
            qr.run(); await qr.pollTask?.value
            check(qr.status.isEmpty && qr.errorMessage == account.signInError && qr.errorMessage != nil,
                  "native admission/import/publication failure leaves a terminal retry message")
            check(!qr.busy && !qr.signingIn, "failed native connection retires busy state")
            if error is VortxNativeError {
                check(!account.isSignedIn, "rejected native connection never reports signed in")
            } else {
                check(account.isSignedIn && account.publicationWarnings.last! == account.signInError,
                      "partial saved credential publishes warning before signed-in truth")
                if let incomplete = error as? OwnerHistoryLoginPreparation.Incomplete {
                    let expected: String
                    switch incomplete.reason {
                    case .pendingMetadata:
                        expected = "The connection and add-ons were saved. Library and history import is waiting for episode metadata. Refresh and retry the import."
                    case .importUnavailable:
                        expected = "The connection and add-ons were saved, but the library and history import could not be confirmed. Refresh and retry the import."
                    }
                    check(account.signInError == expected && qr.errorMessage == expected,
                          "typed incomplete retains exact pending-versus-unconfirmed reason")
                    check(account.publications == 0 && account.credentialBoundaryGeneration == 0,
                          "typed incomplete does not fabricate a completed import boundary")
                    check(CoreBridge.shared.installs == 1 && LinkAuthService.createCount == 1,
                          "typed incomplete never automatically retries login or the native import")
                }
                for fixture in [TVHandoffFixture(account), IOSHandoffFixture(account), CardHandoffFixture(account)] as [HandoffFixture] {
                    let prior = CoreBridge.shared.handoffs
                    fixture.run(true)
                    check(CoreBridge.shared.handoffs == prior && !fixture.didHandleSignIn,
                          "partial connection cannot trigger sheet/card success")
                    CoreBridge.shared.error = nil
                    let priorRevision = account.credentialBoundaryGeneration
                    // Clearing a warning at retry start is NOT a success event. The production UI
                    // observes the revision (checked by the script), not the warning property.
                    let retry = QRFixture(account); retry.run(); await retry.pollTask?.value
                    check(account.credentialBoundaryGeneration == priorRevision + 1 && retry.errorMessage == nil,
                          "successful retry emits an authenticated boundary with signedIn already true")
                    fixture.run(account.isSignedIn); fixture.run(account.isSignedIn)
                    check(CoreBridge.shared.handoffs == prior + 1 && fixture.didHandleSignIn,
                          "TV/iOS/card successful retry handoff is exactly once")
                    account.signInError = "fixture partial warning"
                }
            }
        }
        for reason in [OwnerHistoryLoginPreparation.Incomplete.Reason.pendingMetadata, .importUnavailable] {
            for retired in ["profileABA", "credentialABA"] {
                reset(); let gate = Gate(), account = StremioAccount()
                CoreBridge.shared.gate = gate
                CoreBridge.shared.error = OwnerHistoryLoginPreparation.Incomplete(reason: reason)
                let task = Task { await account.signInWithAuthKey("fixture-only") }
                await drain()
                if retired == "profileABA" {
                    let originalID = ProfileStore.shared.active!.id
                    ProfileStore.shared.active = .init(id: UUID()); account.reloadForActiveProfile()
                    ProfileStore.shared.active = .init(id: originalID); account.reloadForActiveProfile()
                } else { CredentialScopeRegistry.shared.generation += 2 }
                let priorWarnings = account.publicationWarnings.count
                gate.release()
                check(await task.value == .superseded,
                      "typed incomplete from retired original authority is superseded after \(retired)")
                check(account.signInError == nil && account.publicationWarnings.count == priorWarnings && account.publications == 0,
                      "stale typed incomplete cannot repaint or republish after \(retired)")
            }
        }
        #endif

        reset(); LinkAuthService.validationError = LinkAuthService.Failure(errorDescription: "Fixture rejected")
        let rejected = QRFixture(StremioAccount()); rejected.run(); await rejected.pollTask?.value
        check(rejected.errorMessage == "Fixture rejected" && rejected.status.isEmpty,
              "rejected link token remains retryable")
        check(CoreBridge.shared.installs == 0 && StremioAccount.storedTokens.isEmpty,
              "link rejection cannot reach credential installation")

        // All three delayed boundaries deliberately ignore cancellation, like an already-delivered reply.
        for stage in ["create", "read", "validate"] {
            for change in ["cancel", "refresh", "profileABA", "accountABA"] {
                reset(); let gate = Gate(), account = StremioAccount(), qr = QRFixture(account)
                switch stage {
                case "create": LinkAuthService.createGate = gate
                case "read": LinkAuthService.readGate = gate
                default: LinkAuthService.validationGate = gate
                }
                qr.run(); let oldTask = qr.pollTask; await drain()
                let oldID = ProfileStore.shared.active!.id
                if change == "cancel" { qr.cancel() }
                if change == "refresh" {
                    LinkAuthService.createGate = nil; LinkAuthService.readGate = nil; LinkAuthService.validationGate = nil
                    qr.run(); await qr.pollTask?.value
                }
                if change == "profileABA" {
                    ProfileStore.shared.active = .init(id: UUID()); account.reloadForActiveProfile()
                    ProfileStore.shared.active = .init(id: oldID); account.reloadForActiveProfile()
                }
                if change == "accountABA" { CredentialScopeRegistry.shared.generation += 2 }
                let priorStatus = qr.status, priorError = qr.errorMessage
                let priorInstalls = CoreBridge.shared.installs, priorStores = StremioAccount.storedTokens.count
                gate.release(); await oldTask?.value
                if change == "profileABA" {
                    check(qr.status.isEmpty && qr.errorMessage?.contains("interrupted") == true,
                          "\(stage) same-viewer ABA exposes retry instead of hanging")
                } else {
                    check(qr.status == priorStatus && qr.errorMessage == priorError,
                          "\(stage) late reply cannot repaint after \(change)")
                }
                check(CoreBridge.shared.installs == priorInstalls && StremioAccount.storedTokens.count == priorStores,
                      "\(stage) late reply cannot install credentials after \(change)")
                qr.cancel()
            }
        }

        reset(); let hold = Gate(); CoreBridge.shared.gate = hold
        let superseded = StremioAccount()
        #if VORTX_NATIVE_DATA_ENGINE
        let connection = Task { await superseded.signInWithAuthKey("fixture") }
        await drain(); superseded.reloadForActiveProfile(); hold.release()
        check(await connection.value == .superseded, "native auth completion reports superseded, not stale failure/success")
        check(superseded.publications == 0 && !superseded.isSignedIn, "superseded native auth cannot publish")
        #endif

        reset(); let emailHold = Gate(), suspended = StremioAccount(); suspended.backfillGate = emailHold
        let suspendedTask = Task { await suspended.signInWithAuthKey("fixture") }
        await drain(); suspended.reloadForActiveProfile()
        let afterReload = suspended.isSignedIn, publishedAfterReload = suspended.publicationWarnings.count
        emailHold.release()
        check(await suspendedTask.value == .superseded && suspended.isSignedIn == afterReload
                  && suspended.publicationWarnings.count == publishedAfterReload,
              "superseded email reply cannot change freshly reloaded credential truth")

        reset(); QRFixture.timeout = -1
        let expired = QRFixture(StremioAccount()); expired.run(); await expired.pollTask?.value
        check(expired.status.isEmpty && expired.errorMessage?.contains("expired") == true,
              "expired code remains a terminal retry state")

        let manager = VortXSyncManager()
        let accepted = await manager.keepThisDeviceOverridingAccount()
        #if VORTX_NATIVE_DATA_ENGINE
        check(!accepted && !manager.hasAppliedAccountDoc && manager.pendingAddonOrderIntent == nil,
              "native unsupported override has zero restore/order side effects")
        check(manager.uploadCalls == 0, "native override cannot start an upload")
        manager.hasAppliedAccountDoc = true
        let retained = VortXSyncManager.AddonOrderIntent(accountID: "prior", order: ["prior"])
        manager.pendingAddonOrderIntent = retained
        _ = await manager.keepThisDeviceOverridingAccount()
        check(manager.hasAppliedAccountDoc && manager.pendingAddonOrderIntent == retained,
              "native prevention preserves existing acknowledgement and legacy intent")
        #else
        check(accepted && manager.hasAppliedAccountDoc && manager.uploadCalls == 1 && manager.lastOverride == true,
              "legacy explicit override retains its authorized behavior")
        check(manager.pendingAddonOrderIntent?.order == ["existing"], "legacy order intent unchanged")
        #endif
        print("PASS \(checks) exact-source #262 control checks")
    }
}
