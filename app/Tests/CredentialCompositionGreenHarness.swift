import Foundation

/// Integrated-root GREEN harness for the Apple credential composition.
///
/// This harness has one source of truth: the project root supplied with --root, or the
/// deterministic current directory when it already contains this project's source manifest.
/// It never discovers or reads another project root. The historical RED harness remains a
/// separate baseline contract.
///
/// Run from the project root:
/// swiftc -parse-as-library app/Tests/CredentialCompositionGreenHarness.swift -o /tmp/credential-composition-green
/// /tmp/credential-composition-green --self-test
/// /tmp/credential-composition-green --root "$PWD"
///
/// A normal project run exits zero only when every fixed GREEN gate passes. --expect-red
/// acknowledges only the current, known runtime-recovery composition RED and still fails closed
/// for source, inventory, compiler, and root-integrity failures.
@main
struct CredentialCompositionGreenHarness {
    private static let rootEnvironment = "VORTX_CREDENTIAL_COMPOSITION_ROOT"
    private static let harnessRelativePath = "app/Tests/CredentialCompositionGreenHarness.swift"

    private struct SourceSpec {
        let path: String
        let anchors: [String]
    }

    private static let sourceManifest: [SourceSpec] = [
        SourceSpec(
            path: "app/SourcesShared/CredentialScope.swift",
            anchors: [
                "enum CredentialScope",
                "final class CredentialScopeRegistry",
                "func capture()",
                "func isCurrent("
            ]
        ),
        SourceSpec(
            path: "app/SourcesShared/Keychain.swift",
            anchors: [
                "static func confirmedString(",
                "static func durableString(",
                "static func set("
            ]
        ),
        SourceSpec(
            path: "app/SourcesShared/ApiKeys.swift",
            anchors: [
                "final class ApiKeys",
                "func bind(owner",
                "CredentialScopeRegistry.shared",
                "Keychain.confirmedString("
            ]
        ),
        SourceSpec(
            path: "app/SourcesShared/DebridKeys.swift",
            anchors: [
                "final class DebridKeys",
                "func bind(owner",
                "CredentialScopeRegistry.shared",
                "CredentialDurableReadResult"
            ]
        ),
        SourceSpec(
            path: "app/SourcesShared/TraktAuth.swift",
            anchors: [
                "actor TraktAuth",
                "func ownerCapture()",
                "func signOut()",
                "CredentialScopeRegistry.shared"
            ]
        ),
        SourceSpec(
            path: "app/SourcesShared/VortXSyncManager.swift",
            anchors: [
                "final class VortXSyncManager",
                "credentialAuthority",
                "private func bindCredentialOwner(",
                "private func restore()"
            ]
        ),
        SourceSpec(
            path: "app/SourcesShared/AuthenticatedHTTPTransport.swift",
            anchors: [
                "final class AuthenticatedHTTPTransport",
                "func send(",
                "static func decodeJSON<"
            ]
        )
    ]

    private static let fixedGateIDs = [
        "GREEN-01-SOURCE-MANIFEST",
        "GREEN-02-SINGLE-RESULT-DEFINITIONS",
        "GREEN-03-INTEGRATED-CREDENTIAL-COMPILER",
        "GREEN-04-DURABLE-CREDENTIAL-BOUNDARY",
        "GREEN-05-OWNER-AUTHORITY-FENCES",
        "GREEN-06-AUTHENTICATED-MIGRATION-FENCE",
        "GREEN-07-RUNTIME-RECOVERY-AUTHORITY",
        "GREEN-08-SINGLE-ROOT-INTEGRITY"
    ]

    private static let expectedRedGate = "GREEN-07-RUNTIME-RECOVERY-AUTHORITY"
    private static let requiredResultNames = [
        "CredentialMutationResult",
        "CredentialDurableReadResult"
    ]

    private struct Gate {
        let id: String
        let passed: Bool
        let detail: String
    }

    private struct SelfTest {
        let name: String
        let passed: Bool
    }

    private struct CompilerResult {
        let status: Int32
        let output: String
    }

    private struct HarnessProcessResult {
        let status: Int32
        let output: String
    }

    private struct ScopedFunction {
        let name: String
        let owner: String?
        let source: String
        let rawSource: String
    }

    private struct ReferenceBinding {
        let name: String
        let target: String
    }

    private struct ProductionMigrationClaim {
        let callee: String
        let bindingName: String
        let expectedArguments: [(label: String, expression: String)]
        let expectedSlots: [(source: String, destination: String)]?
        let provenanceTag: String
    }

    private struct ValidatedProductionMigrationClaim {
        let callRange: Range<String.Index>
        let sourceReadMemberRange: Range<String.Index>
    }

    private struct SourceSet {
        let requiredText: [String: String]
        let requiredMissing: [String]
        let requiredExternal: [String]
        let anchorFailures: [String]
        let inventoryFiles: [URL]
        let inventoryExternal: [String]
    }

    private struct Evaluation {
        let root: URL
        let sourceSet: SourceSet
        let declarations: [String: Int]
        let compiler: (parse: CompilerResult, typecheck: CompilerResult)
        let gates: [Gate]
        let inventoryFailures: [String]

        var allGreen: Bool {
            inventoryFailures.isEmpty && gates.allSatisfy(\.passed)
        }
    }

    private enum EvaluationMode {
        case production
        case fixture
    }

    private struct Options {
        let rootArgument: String?
        let selfTest: Bool
        let expectRed: Bool

        init(arguments: [String]) throws {
            var rootArgument: String?
            var selfTest = false
            var expectRed = false
            var index = 1

            while index < arguments.count {
                switch arguments[index] {
                case "--self-test":
                    guard !selfTest else { throw HarnessError.invalidArguments("duplicate --self-test") }
                    selfTest = true
                case "--expect-red":
                    guard !expectRed else { throw HarnessError.invalidArguments("duplicate --expect-red") }
                    expectRed = true
                case "--root":
                    guard index + 1 < arguments.count else {
                        throw HarnessError.invalidArguments("--root requires exactly one path")
                    }
                    guard rootArgument == nil else {
                        throw HarnessError.invalidArguments("only one explicit --root is permitted")
                    }
                    index += 1
                    rootArgument = arguments[index]
                default:
                    if arguments[index].hasPrefix("--root=") {
                        guard rootArgument == nil else {
                            throw HarnessError.invalidArguments("only one explicit --root is permitted")
                        }
                        rootArgument = String(arguments[index].dropFirst("--root=".count))
                        guard !rootArgument!.isEmpty else {
                            throw HarnessError.invalidArguments("--root requires exactly one path")
                        }
                    } else {
                        throw HarnessError.invalidArguments("unknown argument \(arguments[index])")
                    }
                }
                index += 1
            }

            guard !(selfTest && (rootArgument != nil || expectRed)) else {
                throw HarnessError.invalidArguments("--self-test cannot be combined with --root or --expect-red")
            }
            self.rootArgument = rootArgument
            self.selfTest = selfTest
            self.expectRed = expectRed
        }
    }

    private enum HarnessError: LocalizedError {
        case invalidArguments(String)
        case root(String)
        case missingSwiftc
        case compilerLaunch(String)
        case fixture(String)

        var errorDescription: String? {
            switch self {
            case let .invalidArguments(detail):
                return "invalid arguments: \(detail)"
            case let .root(detail):
                return "invalid project root: \(detail)"
            case .missingSwiftc:
                return "swiftc was not found at /usr/bin/swiftc"
            case let .compilerLaunch(detail):
                return "could not launch swiftc: \(detail)"
            case let .fixture(detail):
                return "self-test fixture error: \(detail)"
            }
        }
    }

    static func main() {
        do {
            let options = try Options(arguments: CommandLine.arguments)
            if options.selfTest {
                let tests = try runSelfTests()
                for test in tests {
                    print("\(test.passed ? "SELF_PASS" : "SELF_FAIL") \(test.name)")
                }
                guard tests.allSatisfy(\.passed) else {
                    print("SELF_TEST_RED fixed green harness contract")
                    Foundation.exit(2)
                }
                print("SELF_TEST_GREEN hostile temporary fixture contract")
                Foundation.exit(0)
            }

            let root = try resolveRoot(argument: options.rootArgument)
            let evaluation = try evaluate(root: root)
            printReport(evaluation)

            if evaluation.allGreen {
                print("GREEN credential composition gates=\(fixedGateIDs.count)")
                Foundation.exit(0)
            }

            if options.expectRed, isExpectedRedReceipt(evaluation) {
                print("EXPECTED_RED current composition missing=\(missingGateIDs(evaluation).joined(separator: ","))")
                Foundation.exit(0)
            }

            Foundation.exit(1)
        } catch {
            print("HARNESS_FAIL \(error.localizedDescription)")
            Foundation.exit(2)
        }
    }

    private static func resolveRoot(argument: String?) throws -> URL {
        let environmentRoot = ProcessInfo.processInfo.environment[rootEnvironment]
        guard !(argument != nil && environmentRoot != nil) else {
            throw HarnessError.root("provide --root or \(rootEnvironment), not both")
        }

        let suppliedPath: String
        let isExplicit = argument != nil || environmentRoot != nil
        if let argument {
            suppliedPath = argument
        } else if let environmentRoot {
            suppliedPath = environmentRoot
        } else {
            suppliedPath = FileManager.default.currentDirectoryPath
        }

        if isExplicit {
            guard !suppliedPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw HarnessError.root("explicit project root must not be empty or whitespace")
            }
        }

        let root = try canonicalDirectory(URL(fileURLWithPath: suppliedPath, relativeTo: URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )))

        if !isExplicit {
            let marker = root.appendingPathComponent(harnessRelativePath)
            guard FileManager.default.fileExists(atPath: marker.path) else {
                throw HarnessError.root(
                    "current directory is not a deterministic project root; pass --root <path>"
                )
            }
        }
        return root
    }

    private static func evaluate(root: URL) throws -> Evaluation {
        try evaluate(root: root, mode: .production)
    }

    private static func evaluateFixture(root: URL) throws -> Evaluation {
        try evaluate(root: root, mode: .fixture)
    }

    private static func evaluate(root: URL, mode: EvaluationMode) throws -> Evaluation {
        let sourceSet = try loadSources(root: root)
        let declarations = declarationCounts(sourceSet: sourceSet)
        let compiler = try compilerChecks(root: root, sourceSet: sourceSet)
        let gates = makeGates(
            root: root,
            sourceSet: sourceSet,
            declarations: declarations,
            compiler: compiler,
            mode: mode
        )
        let inventoryFailures = validateGateInventory(gates)
        return Evaluation(
            root: root,
            sourceSet: sourceSet,
            declarations: declarations,
            compiler: compiler,
            gates: gates,
            inventoryFailures: inventoryFailures
        )
    }

    private static func loadSources(root: URL) throws -> SourceSet {
        let fileManager = FileManager.default
        var requiredText: [String: String] = [:]
        var requiredMissing: [String] = []
        var requiredExternal: [String] = []
        var anchorFailures: [String] = []

        for spec in sourceManifest {
            let url = root.appendingPathComponent(spec.path)
            guard fileManager.fileExists(atPath: url.path) else {
                requiredMissing.append(spec.path)
                continue
            }

            let canonical = url.resolvingSymlinksInPath().standardizedFileURL
            guard canonical.path == url.standardizedFileURL.path,
                  isInside(canonical, root: root) else {
                requiredExternal.append(spec.path)
                continue
            }

            guard let text = try? String(contentsOf: canonical, encoding: .utf8) else {
                requiredMissing.append("\(spec.path) (not UTF-8)")
                continue
            }
            requiredText[spec.path] = text
            for anchor in spec.anchors where !text.contains(anchor) {
                anchorFailures.append("\(spec.path) missing anchor \(anchor)")
            }
        }

        let sourceDirectory = root.appendingPathComponent("app/SourcesShared", isDirectory: true)
        var inventoryFiles: [URL] = []
        var inventoryExternal: [String] = []
        if fileManager.fileExists(atPath: sourceDirectory.path) {
            let directoryCanonical = sourceDirectory.resolvingSymlinksInPath().standardizedFileURL
            if directoryCanonical.path != sourceDirectory.standardizedFileURL.path
                || !isInside(directoryCanonical, root: root) {
                inventoryExternal.append(sourceDirectory.path)
            } else if let enumerator = fileManager.enumerator(
                at: sourceDirectory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) {
                for case let url as URL in enumerator where url.pathExtension == "swift" {
                    let canonical = url.resolvingSymlinksInPath().standardizedFileURL
                    if canonical.path != url.standardizedFileURL.path
                        || !isInside(canonical, root: root) {
                        inventoryExternal.append(url.path)
                    } else {
                        inventoryFiles.append(canonical)
                    }
                }
            }
        } else {
            inventoryExternal.append(sourceDirectory.path)
        }

        inventoryFiles.sort { $0.path < $1.path }
        return SourceSet(
            requiredText: requiredText,
            requiredMissing: requiredMissing,
            requiredExternal: requiredExternal,
            anchorFailures: anchorFailures,
            inventoryFiles: inventoryFiles,
            inventoryExternal: inventoryExternal
        )
    }

    private static func compilerChecks(
        root: URL,
        sourceSet: SourceSet
    ) throws -> (parse: CompilerResult, typecheck: CompilerResult) {
        guard sourceSet.requiredMissing.isEmpty,
              sourceSet.requiredExternal.isEmpty,
              sourceSet.inventoryExternal.isEmpty else {
            let detail = [
                sourceSet.requiredMissing,
                sourceSet.requiredExternal,
                sourceSet.inventoryExternal
            ]
            .flatMap { $0 }
            .joined(separator: ", ")
            let skipped = CompilerResult(status: 2, output: "compiler skipped: \(detail)")
            return (skipped, skipped)
        }

        let parse = try runCompiler(
            arguments: ["-frontend", "-parse"] + sourceSet.inventoryFiles.map(\.path)
        )

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("vortx-credential-green-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let stubs = scratch.appendingPathComponent("CredentialCompositionCompilerStubs.swift")
        let probe = scratch.appendingPathComponent("CredentialCompositionCompilerProbe.swift")
        let stubsSource = """
        import SwiftUI
        import CryptoKit

        actor DebridCoordinator {
            static let shared = DebridCoordinator()
            func reload<T>(snapshot: T) async {}
        }

        struct TraktToken: Codable, Sendable, Equatable {
            let accessToken: String
            let refreshToken: String
            let expiresIn: Int
            let tokenType: String
            let scope: String?
            let createdAt: Int

            init(
                accessToken: String,
                refreshToken: String,
                expiresIn: Int,
                tokenType: String = "bearer",
                scope: String? = nil,
                createdAt: Int = Int(Date().timeIntervalSince1970)
            ) {
                self.accessToken = accessToken
                self.refreshToken = refreshToken
                self.expiresIn = expiresIn
                self.tokenType = tokenType
                self.scope = scope
                self.createdAt = createdAt
            }

            var expiresAt: Date {
                Date(timeIntervalSince1970: TimeInterval(createdAt + expiresIn))
            }

            func isExpired(leeway: TimeInterval? = nil) -> Bool { false }
        }

        struct TraktSessionID: RawRepresentable, Codable, Hashable, Sendable {
            let rawValue: String

            init(rawValue: String) {
                self.rawValue = rawValue
            }

            static func random() -> TraktSessionID {
                TraktSessionID(rawValue: UUID().uuidString)
            }
        }

        struct TraktDeviceCode: Codable, Sendable, Equatable {
            let session: String
            let userCode: String
            let verificationURL: String
            let expiresIn: Int
            let interval: Int
        }

        enum VortXEdgeAuth {
            static var canSignOAuthV2: Bool { false }

            @discardableResult
            static func signOAuthV2(_ request: inout URLRequest, body: Data) -> Bool { false }
        }

        enum TraktAuthBoundary {
            static func publish(_ sessionID: TraktSessionID?) {}
        }

        enum DiagnosticsLog {
            static func log(_ category: String, _ message: String) {}
        }

        struct UserProfile: Codable, Identifiable, Equatable {
            let id: UUID
            var name: String = ""
            var avatar: String = ""
            var accentID: String = ""
            var oled = false
            var textScale = 1.0
            var pin: String?
            var isOwner = false
            var familyEdit = false
            var disabledAddons: [String]?
            var isKids = false
            var playback: PlaybackPrefs?

            struct PlaybackPrefs: Codable, Equatable {
                var audioLang = ""
                var subtitleLang = ""
                var forcedPolicy = ""
                var subFont = ""
                var subSize = ""
                var subColor = ""
                var subBackground = ""
                var subSizeScale: Double?
                var subBrightness: String?
                var sourceTypeOrder: [String]?
                var useAddonOrder: Bool?
                var safetyMode: String?
                var instantOnly: Bool?
                var hideDeadTorrents: Bool?
                var hdrOnly: Bool?
                var excludeAV1: Bool?
                var excludeKeywords: [String]?
                var includeKeywords: [String]?
                var keywordsAreRegex: Bool?
                var maxResolution: String?
                var maxFileSizeGB: Double?
                var minResolution: String?
                var hideUnknownResolution: Bool?
                var preferredAudioOnly: Bool?
            }

            static let ownerID = UUID()

            static func normalizeID(_ value: String) -> String {
                value.uppercased()
            }
        }

        struct VortXOwnedAddon {
            let transportUrl: String

            init?(json: [String: Any]) {
                guard let transportUrl = json["transportUrl"] as? String else { return nil }
                self.transportUrl = transportUrl
            }
        }

        struct WatchEntry {
            let videoId: String?
            let timeOffsetMs: Int
            let durationMs: Int
            let lastWatched: String
            let name: String
            let type: String
            let poster: String?
            var watchedVideoIds: [String] = []
        }

        final class ProfileStore {
            static let shared = ProfileStore()
            var profiles: [UserProfile] = []
            var activeID: UUID?
            var deletedProfileIDs: Set<String> = []
            func mergeInRoster(_ roster: [UserProfile]) {}
            func reloadFromDefaults() {}
            func applyLocalTombstones() {}
            func mergeDeletedTombstones(_ ids: [String]) -> Bool { false }
            func watchEntries(for profileID: UUID) -> [String: WatchEntry] { [:] }
            func applyRemoteOverlay(profileID: UUID, entries: [String: WatchEntry]) {}
            func applyProfileEdits(_ edits: [String: Any]) {}
            func rosterDiffers(from roster: [UserProfile]) -> Bool { false }
        }

        struct CorePlaybackState {
            var timeOffset: Double = 0
            var duration: Double = 0
            var videoId: String?
        }

        struct CoreCatalogItem {
            var id = ""
            var name = ""
            var type = "movie"
            var poster: String?
            var removed: Bool?
            var temp: Bool?
            var state = CorePlaybackState()
        }

        struct CoreLibrary {
            var catalog: [CoreCatalogItem] = []
        }

        struct CoreAddon {
            var transportUrl = ""
            var isOfficial = false
            var isProtected = false
        }

        final class CoreBridge {
            static let shared = CoreBridge()
            var library: CoreLibrary?
            var addons: [CoreAddon] = []
            func isLoggedIn() -> Bool { false }
            func rawAddonDescriptorsOrdered() -> [[String: Any]] { [] }
            func uninstallAddon(_ addon: CoreAddon, tombstone: Bool) {}
            func hydrateAddonsFromAccount(_ owned: [VortXOwnedAddon]) {}
            func rebuildContinueWatching() {}
            func addCatalogItemToAccount(id: String, type: String, stampIntent: Bool) async {}
            func loadLibraryAndAwait() async {}
        }

        enum MirrorSettings {
            static let mirrorLibrary = false
            static let mirrorAddons = false

            struct CWPosition {
                let t: Double
                let d: Double
                let v: String?
            }

            static func stremioMayReplaceContinueWatching(stremioSessionLive: Bool) -> Bool {
                false
            }

            static func resolveContinueWatching(
                engine: CWPosition,
                owned: CWPosition,
                mayReplace: Bool,
                locallyRewound: Bool
            ) -> CWPosition {
                engine
            }
        }

        enum LocalRewindLog {
            static func all() -> Set<String> { [] }
            static func contains(_ id: String) -> Bool { false }
            static func forget(_ id: String) {}
        }

        enum LibraryTombstones {
            static func all() -> Set<String> { [] }
            static func normalize(_ value: String) -> String { value }
            static func timestampsForSync() -> [String: Any] { [:] }
            static func merge(legacyIDs: [String], stampsRaw: [String: Any]) -> Bool { false }
        }

        enum AddonTombstones {
            static func normalize(_ value: String) -> String { value }
            static func all() -> Set<String> { [] }
            static func timestampsForSync() -> [String: Any] { [:] }
            static func merge(
                legacyIDs: [String],
                stampsRaw: [String: Any],
                webIDs: [String] = []
            ) -> Bool { false }
            static func baselineInstalled(_ values: [String]) {}
        }

        enum SettingsBackup {
            static func isSyncable(_ key: String) -> Bool { true }
            static func decodeDomain(from data: Data) throws -> [String: Any] { [:] }
            static func mergedSyncBlob(onto value: Any?, appliedBaseline: Set<String>) -> Data? { nil }
            static func restore(from data: Data, skipping: Set<String>) throws -> Int { 0 }
            static func appliedKeys(from data: Data) -> Set<String> { [] }
            static func reloadLiveStores() {}
        }

        enum SettingsDirtyKeys {
            static func changedSyncableKeys(
                from: [String: Any],
                to: [String: Any],
                isSyncable: (String) -> Bool
            ) -> Set<String> { [] }

            static func mark(
                _ keys: Set<String>,
                at timestamp: Double,
                into dirty: inout [String: Double]
            ) {}

            static func clearPushed(
                _ snapshot: [String: Double],
                from dirty: inout [String: Double]
            ) {}
        }

        final class SourceIndexLifecycleScope {
            static let shared = SourceIndexLifecycleScope()
            func sessionWillMutate() {}
        }

        enum VortXSecureEntropy {
            static func randomBytes(_ count: Int) -> Data? { Data(repeating: 0, count: count) }
            static func makeRecoveryCode() -> String? { "recovery" }
        }

        enum VortXSyncCrypto {
            static let defaultIters = 210_000
            static let minIters = 100_000
            static let docV2Prefix = "v2."
            static func masterKey(password: String, kdfSalt: Data, iters: Int) -> Data { kdfSalt }
            static func recoveryKey(recoveryCode: String, kdfSalt: Data, iters: Int) -> Data { kdfSalt }
            static func seal(key: Data, _ plaintext: Data) -> String? { plaintext.base64EncodedString() }
            static func open(key: Data, _ base64Ciphertext: String) -> Data? { Data(base64Encoded: base64Ciphertext) }
            static func authVerifier(masterKey: Data, password: String) -> String { "verifier" }
            static func recVerifier(recoveryKey: Data, recoveryCode: String) -> String { "verifier" }
            static func openDocument(dataKey: Data, stored: String, accountId: String, version: Int) -> Data? {
                Data(base64Encoded: stored.replacingOccurrences(of: docV2Prefix, with: ""))
            }
            static func sealDocument(
                dataKey: Data,
                plaintext: Data,
                accountId: String,
                version: Int,
                writeV2: Bool
            ) -> String? {
                (writeV2 ? docV2Prefix : "") + plaintext.base64EncodedString()
            }
        }

        enum PairingCrypto {
            struct Ephemeral {
                let publicKeyBase64URL: String
                let privateKey: Curve25519.KeyAgreement.PrivateKey
            }

            static func newEphemeral() -> Ephemeral {
                let privateKey = Curve25519.KeyAgreement.PrivateKey()
                return Ephemeral(publicKeyBase64URL: "public", privateKey: privateKey)
            }

            static func unwrapDataKey(
                wrapped: String,
                holderPublicKey: String,
                using privateKey: Curve25519.KeyAgreement.PrivateKey
            ) -> Data? { Data() }

            static func wrapDataKey(
                _ dataKey: Data,
                toJoinerPublicKey: String
            ) -> (String, String)? { ("claim", "wrapped") }
        }

        enum SIMKLTokenSlots {
            static func claimLegacyGlobal(
                owner: CredentialScope,
                capture: CredentialScopeRegistry.Capture
            ) -> CredentialLegacyClaim.Result { .noSource }
        }

        struct SIMKLSyncableTokens {
            let access: String
            let expiryUnix: Int
        }

        actor SIMKLAuth {
            static let shared = SIMKLAuth()
            func syncableTokens(ownerNamespace: String) async -> SIMKLSyncableTokens? { nil }
            func adoptTokens<Capture>(
                access: String,
                expiryUnix: Int,
                ownerCapture: Capture
            ) async -> CredentialMutationResult { .failure }
            func finalizeLegacyMigration(
                ownerCapture capture: CredentialScopeRegistry.Capture
            ) async -> CredentialMutationResult { .failure }
        }

        final class MediaServerStore {
            static let shared = MediaServerStore()
            func syncBlob() -> String? { nil }
            func applySyncBlob(_ blob: String) {}
        }

        final class IPTVPlaylistStore {
            static let shared = IPTVPlaylistStore()
            func syncBlob() -> String? { nil }
            func applySyncBlob(_ blob: String) {}
        }

        enum SearchHistoryStore {
            static func allTerms(for profileID: UUID?) -> [String] { [] }
            static func merge(_ terms: [String], for profileID: UUID?) {}
        }

        enum LastStreamStore {
            static func invalidateCache() {}
        }

        enum ProfileSync {
            static func libraryImportedFromStremio(authKey: String) -> Bool { false }
            static func markLibraryImportedFromStremio(authKey: String) {}
        }

        enum OwnerResumeStore {
            static func merge(_ entries: [(id: String, t: Double, d: Double, v: String?)]) {}
        }

        enum Theme {
            enum Space {
                static let lg: CGFloat = 1
                static let md: CGFloat = 1
                static let sm: CGFloat = 1
                static let xl: CGFloat = 1
                static let screenInset: CGFloat = 1
            }
            enum Typography {
                static let body: Font = .body
                static let cardTitle: Font = .body
                static let label: Font = .body
            }
            enum Palette {
                static let accent: Color = .accentColor
                static let canvas: Color = .clear
                static let textPrimary: Color = .primary
                static let textSecondary: Color = .secondary
                static let textTertiary: Color = .secondary
            }
        }

        extension View {
            func screenTitleStyle() -> some View { self }
            func vortxSettingsCard() -> some View { self }
        }
        """
        try stubsSource.write(to: stubs, atomically: true, encoding: .utf8)
        let probeSource = """
        import Foundation

        private func credentialCompositionCompilerProbe(
            read: CredentialDurableReadResult,
            mutation: CredentialMutationResult,
            scope: CredentialScope.Type,
            apiKeys: ApiKeys.Type,
            debridKeys: DebridKeys.Type,
            traktAuth: TraktAuth.Type,
            syncManager: VortXSyncManager.Type
        ) -> Bool {
            _ = scope
            _ = apiKeys
            _ = debridKeys
            _ = traktAuth
            _ = syncManager
            switch read {
            case .value:
                return mutation == .success
            case .missing, .failure:
                return mutation == .success || mutation == .failure
            }
        }
        """
        try probeSource.write(to: probe, atomically: true, encoding: .utf8)

        let scope = root.appendingPathComponent("app/SourcesShared/CredentialScope.swift")
        let keychain = root.appendingPathComponent("app/SourcesShared/Keychain.swift")
        let apiKeys = root.appendingPathComponent("app/SourcesShared/ApiKeys.swift")
        let debridKeys = root.appendingPathComponent("app/SourcesShared/DebridKeys.swift")
        let traktAuth = root.appendingPathComponent("app/SourcesShared/TraktAuth.swift")
        let authenticatedHTTPTransport = root.appendingPathComponent(
            "app/SourcesShared/AuthenticatedHTTPTransport.swift"
        )
        let syncManager = root.appendingPathComponent("app/SourcesShared/VortXSyncManager.swift")
        let typecheck = try runCompiler(arguments: [
            "-parse-as-library",
            "-swift-version",
            "5",
            "-Xfrontend",
            "-strict-concurrency=minimal",
            "-suppress-warnings",
            "-typecheck",
            stubs.path,
            scope.path,
            keychain.path,
            apiKeys.path,
            debridKeys.path,
            traktAuth.path,
            authenticatedHTTPTransport.path,
            syncManager.path,
            probe.path
        ])
        return (parse, typecheck)
    }

    private static func runCompiler(arguments: [String]) throws -> CompilerResult {
        let swiftc = URL(fileURLWithPath: "/usr/bin/swiftc")
        guard FileManager.default.fileExists(atPath: swiftc.path) else {
            throw HarnessError.missingSwiftc
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vortx-credential-green-compiler-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        defer {
            try? outputHandle.close()
            try? FileManager.default.removeItem(at: outputURL)
        }

        let process = Process()
        process.executableURL = swiftc
        process.arguments = arguments
        process.standardOutput = outputHandle
        process.standardError = outputHandle
        do {
            try process.run()
        } catch {
            throw HarnessError.compilerLaunch(error.localizedDescription)
        }
        process.waitUntilExit()
        try outputHandle.close()
        let output = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
        return CompilerResult(status: process.terminationStatus, output: output)
    }

    private static func runHarnessProcess(
        arguments: [String],
        environmentRoot: String?
    ) throws -> HarnessProcessResult {
        guard let executableArgument = CommandLine.arguments.first,
              !executableArgument.isEmpty else {
            throw HarnessError.fixture("self-test executable path is unavailable")
        }
        let currentDirectory = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        let executable = URL(
            fileURLWithPath: executableArgument,
            relativeTo: currentDirectory
        ).standardizedFileURL
        guard FileManager.default.fileExists(atPath: executable.path) else {
            throw HarnessError.fixture("self-test executable does not exist at (executable.path)")
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: rootEnvironment)
        if let environmentRoot {
            environment[rootEnvironment] = environmentRoot
        }
        process.environment = environment

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        do {
            try process.run()
        } catch {
            throw HarnessError.fixture("could not launch self-test executable: (error.localizedDescription)")
        }
        process.waitUntilExit()
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        return HarnessProcessResult(
            status: process.terminationStatus,
            output: String(data: outputData, encoding: .utf8) ?? ""
        )
    }

    private static func isFailClosedRootProcess(_ result: HarnessProcessResult) -> Bool {
        let evaluationMarkers = [
            "GREEN_MANIFEST",
            "GATES_FIXED",
            "PASS GREEN-",
            "FAIL GREEN-",
            "INVENTORY_FAIL",
            "COMPOSITION_RED",
            "EXPECTED_RED"
        ]
        return result.status == 2
            && result.output.contains("HARNESS_FAIL")
            && evaluationMarkers.allSatisfy { !result.output.contains($0) }
    }

    private static func makeGates(
        root: URL,
        sourceSet: SourceSet,
        declarations: [String: Int],
        compiler: (parse: CompilerResult, typecheck: CompilerResult),
        mode: EvaluationMode
    ) -> [Gate] {
        let scope = sourceSet.requiredText["app/SourcesShared/CredentialScope.swift"] ?? ""
        let keychain = sourceSet.requiredText["app/SourcesShared/Keychain.swift"] ?? ""
        let apiKeys = sourceSet.requiredText["app/SourcesShared/ApiKeys.swift"] ?? ""
        let debrid = sourceSet.requiredText["app/SourcesShared/DebridKeys.swift"] ?? ""
        let trakt = sourceSet.requiredText["app/SourcesShared/TraktAuth.swift"] ?? ""
        let sync = sourceSet.requiredText["app/SourcesShared/VortXSyncManager.swift"] ?? ""

        let manifestPassed = sourceSet.requiredMissing.isEmpty
            && sourceSet.requiredExternal.isEmpty
            && sourceSet.anchorFailures.isEmpty
            && !sourceSet.inventoryFiles.isEmpty
        let resultDefinitionsPassed = requiredResultNames.allSatisfy {
            declarations[$0] == 1
        }
        let compilerPassed = compiler.parse.status == 0 && compiler.typecheck.status == 0

        let keychainConfirmed = functionRegion(keychain, startingAt: "static func confirmedString(") ?? ""
        let keychainDurable = functionRegion(keychain, startingAt: "static func durableString(") ?? ""
        let keychainSet = functionRegion(keychain, startingAt: "static func set(") ?? ""
        let apiPersist = functionRegion(apiKeys, startingAt: "private func persist(") ?? ""
        let apiConfirmed = functionRegion(apiKeys, startingAt: "private nonisolated static func confirmedValue(") ?? ""
        let debridRead = functionRegion(debrid, startingAt: "private func readScope(for scopedOwner:") ?? ""
        let debridSet = functionRegion(debrid, startingAt: "func setKey(") ?? ""
        let durablePassed = [
            occursInOrder(keychainConfirmed, ["secureStore.confirmedString("]),
            occursInOrder(keychainDurable, ["secureStore.durableString("]),
            occursInOrder(keychainSet, ["secureStore.set("]),
            occursInOrder(apiConfirmed, [
                "var result = Keychain.confirmedString(",
                "if result == .failure",
                "result = Keychain.confirmedString(",
                "return result"
            ]),
            occursInOrder(apiPersist, [
                "guard let boundCapture",
                "CredentialScopeRegistry.shared.isCurrent(boundCapture)",
                "result = Keychain.set(",
                "if result == CredentialMutationResult.success",
                "guard result == .success",
                "VortXSyncManager.shared.requestSyncSoon()"
            ])
                && occursInOrderWithoutIntervening(
                    apiPersist,
                    first: "result = Keychain.set(",
                    second: "if result == CredentialMutationResult.success",
                    forbidden: "guard result == .success"
                ),
            occursInOrder(debridRead, [
                "switch storage.confirmedRead(",
                "return next"
            ]),
            occursInOrder(debridSet, [
                "storage.mutate(expected, for: account) == .success",
                "switch storage.confirmedRead(account)",
                "if certified",
                "guard certified",
                "keys[service.rawValue]"
            ])
        ].allSatisfy { $0 }

        let scopeRegistry = scopedRegion(scope, startingAt: "final class CredentialScopeRegistry") ?? ""
        let apiBind = functionRegion(apiKeys, startingAt: "func bind(owner newOwner: CredentialScope)") ?? ""
        let apiScopedValue = functionRegion(apiKeys, startingAt: "private nonisolated static func scopedValue(") ?? ""
        let debridBind = functionRegion(
            debrid,
            startingAt: "func bind(owner newOwner: CredentialScope, capture: CredentialScopeRegistry.Capture)"
        ) ?? ""
        let traktSession = scopedRegion(trakt, startingAt: "nonisolated static var storedSessionID:") ?? ""
        let rawTraktSession = rawScopedRegion(
            trakt,
            startingAt: "nonisolated static var storedSessionID:"
        ) ?? ""
        let traktFunctions = functionRegions(trakt)
        let traktReferenceScopes = [
            scopedRegion(trakt, startingAt: "enum TraktTokenSlots") ?? "",
            scopedRegion(trakt, startingAt: "actor TraktAuth") ?? ""
        ]
        let productionStoredSessionRoot = "__productionStoredSessionID"
        let productionStoredSessionFunctions = traktFunctions + [
            ScopedFunction(
                name: productionStoredSessionRoot,
                owner: "TraktAuth",
                source: traktSession,
                rawSource: rawTraktSession
            )
        ]
        let storedSessionHasRawReader = containsRawReaderInReachableFunctions(
            startingAt: productionStoredSessionRoot,
            rootSource: traktSession,
            rootRawSource: rawTraktSession,
            functions: productionStoredSessionFunctions,
            referenceScopes: traktReferenceScopes,
            startingOwner: "TraktAuth"
        )
        let syncBind = functionRegion(sync, startingAt: "private func bindCredentialOwner(") ?? ""
        let finalSyncBind = occursInOrder(syncBind, [
            "guard let capture = credentialAuthority.tryBind(scope) else { return nil }",
            "cancelProviderLegacyMigration(except: capture)",
            "ApiKeys.shared.bind(owner: scope)",
            "DebridKeys.shared.bind(owner: scope)",
            "return capture"
        ])
        let fixtureSyncBind = occursInOrder(syncBind, [
            "let capture = credentialAuthority.bind(scope)",
            "ApiKeys.shared.bind(owner: scope)",
            "DebridKeys.shared.bind(owner: scope, capture: capture)"
        ])
        let finalTraktSession = occursInOrder(traktSession, [
            "let authority = CredentialScopeRegistry.shared",
            "let capture = authority.capture()",
            "CredentialTupleTransaction.readAuthority(",
            "certifiedRead: Keychain.confirmedString",
            "guard authority.isCurrent(capture)"
        ]) && !storedSessionHasRawReader
        let fixtureTraktSession = occursInOrder(traktSession, [
            "let authority = CredentialScopeRegistry.shared",
            "let capture = authority.capture()",
            "guard Keychain.string(",
            "guard authority.isCurrent(capture)"
        ])
        let modeSyncBind: Bool
        let modeTraktSession: Bool
        switch mode {
        case .production:
            modeSyncBind = finalSyncBind
            modeTraktSession = finalTraktSession
        case .fixture:
            modeSyncBind = fixtureSyncBind
            modeTraktSession = fixtureTraktSession
        }
        let authorityPassed = [
            scopeRegistry.contains("func capture()") && scopeRegistry.contains("func isCurrent("),
            occursInOrder(apiBind, [
                "let capture = CredentialScopeRegistry.shared.capture()",
                "guard capture.scope == newOwner",
                "boundCapture = capture",
                "loadScope()"
            ]),
            occursInOrder(apiScopedValue, [
                "let authority = CredentialScopeRegistry.shared",
                "let capture = authority.capture()",
                "let result = confirmedValue(",
                "guard authority.isCurrent(capture)",
                "guard case let .value(value) = result"
            ]),
            occursInOrder(debridBind, [
                "guard capture.scope == newOwner",
                "CredentialScopeRegistry.shared.isCurrent(capture)",
                "let loaded = readScope(for: newOwner)",
                "guard CredentialScopeRegistry.shared.isCurrent(capture)",
                "owner = newOwner"
            ]),
            modeSyncBind,
            modeTraktSession
        ].allSatisfy { $0 }

        let apiMigration = functionRegion(apiKeys, startingAt: "func migrateLegacyIfEligible(") ?? ""
        let debridMigration = functionRegion(debrid, startingAt: "func migrateLegacyIfEligible(") ?? ""
        let debridMigrationSlot = functionRegion(debrid, startingAt: "private func migrateLegacySlot(") ?? ""
        let traktMigration = functionRegion(trakt, startingAt: "static func claimLegacyGlobal(") ?? ""
        let establishOwner = functionRegion(sync, startingAt: "private func establishCredentialOwner(") ?? ""
        let providerMigration = functionRegion(sync, startingAt: "private func runProviderLegacyMigration(") ?? ""
        let rawEstablishOwner = rawScopedRegion(
            sync,
            startingAt: "private func establishCredentialOwner("
        ) ?? ""
        let finalApiMigration = occursInOrder(apiMigration, [
            "owner == expectedOwner",
            "CredentialScopeRegistry.shared.isMigrationEligible(capture)",
            "CredentialLegacyClaim.claimGlobalSlot(",
            "write:",
            "Keychain.set(",
            "durableRead:",
            "Keychain.confirmedString(",
            "sourceRead:",
            "Keychain.durableString("
        ]) && firstOccursInOrder(
            apiMigration,
            first: "CredentialScopeRegistry.shared.isMigrationEligible(capture)",
            second: "CredentialLegacyClaim.claimGlobalSlot("
        )
        let fixtureApiMigration = occursInOrder(apiMigration, [
                "owner == expectedOwner",
                "CredentialScopeRegistry.shared.isMigrationEligible(capture)",
                "CredentialLegacyClaim.claimGlobalSlotCertified(",
                "readCertified:",
                "Keychain.confirmedString(",
                "readDurableSource:",
                "Keychain.durableString(",
                "write:",
                "Keychain.set("
            ]) && firstOccursInOrder(
                apiMigration,
                first: "CredentialScopeRegistry.shared.isMigrationEligible(capture)",
                second: "CredentialLegacyClaim.claimGlobalSlotCertified("
            )
        let finalTraktMigration = occursInOrder(traktMigration, [
            "capture.scope == owner",
            "CredentialScopeRegistry.shared.isMigrationEligible(capture)",
            "guard primary == .migrated || primary == .targetPresent",
            "return primary"
        ])
        let fixtureTraktMigration = occursInOrder(traktMigration, [
            "capture.scope == owner",
            "CredentialScopeRegistry.shared.isMigrationEligible(capture)",
            "CredentialLegacyClaim.claimGlobalSlotSet(",
            "read: Keychain.string",
            "CredentialLegacyClaim.claimGlobalSlot("
        ]) && firstOccursInOrder(
            traktMigration,
            first: "CredentialScopeRegistry.shared.isMigrationEligible(capture)",
            second: "CredentialLegacyClaim.claimGlobalSlotSet("
        )
        let finalEstablishment = occursInOrder(establishOwner, [
            "guard let established = credentialAuthority.establishAuthenticatedOwner(capture)",
            "case .account = established.scope",
            "let owner = established.scope",
            "ApiKeys.shared.migrateLegacyIfEligible(",
            "DebridKeys.shared.migrateLegacyIfEligible(",
            "guard isCurrent(established) else { return false }",
            "scheduleProviderLegacyMigration(ownerCapture: established)",
            "return true"
        ]) && occursInOrder(providerMigration, [
            "CredentialRetryCoordinator.finalizeProviders(",
            "credentialAuthority.isMigrationEligible(capture)",
            "TraktTokenSlots.claimLegacyGlobal(",
            "TraktAuth.shared.finalizeLegacyMigration(",
            "SIMKLTokenSlots.claimLegacyGlobal(",
            "SIMKLAuth.shared.finalizeLegacyMigration("
        ])
        let fixtureEstablishment = occursInOrder(establishOwner, [
            "guard let established = credentialAuthority.establishAuthenticatedOwner(capture)",
            "let owner = established.scope",
            "ApiKeys.shared.migrateLegacyIfEligible(",
            "TraktTokenSlots.claimLegacyGlobal(",
            "DebridKeys.shared.migrateLegacyIfEligible("
        ])
        let modeApiMigration: Bool
        let modeTraktMigration: Bool
        let modeEstablishment: Bool
        switch mode {
        case .production:
            modeApiMigration = finalApiMigration
            let rawTraktMigration = rawScopedRegion(
                trakt,
                startingAt: "static func claimLegacyGlobal("
            ) ?? ""
            let migrationReaderProjection = productionTraktMigrationReaderProjection(
                traktMigration,
                rawSource: rawTraktMigration
            )
            let traktMigrationHasUnexpectedRawReader = containsRawReaderInReachableFunctions(
                startingAt: "claimLegacyGlobal",
                rootSource: migrationReaderProjection.remainder,
                rootRawSource: rawTraktMigration,
                functions: traktFunctions,
                referenceScopes: traktReferenceScopes,
                startingOwner: "TraktTokenSlots"
            )
            modeTraktMigration = finalTraktMigration
                && migrationReaderProjection.valid
                && !traktMigrationHasUnexpectedRawReader
            modeEstablishment = finalEstablishment
        case .fixture:
            modeApiMigration = fixtureApiMigration
            modeTraktMigration = fixtureTraktMigration
            modeEstablishment = fixtureEstablishment
        }
        let migrationPassed = [
            modeApiMigration,
            occursInOrder(debridMigration, [
                "owner == expectedOwner",
                "CredentialScopeRegistry.shared.isMigrationEligible(capture)",
                "migrateLegacySlot(service:",
                "guard safe",
                "readScope()"
            ])
                && firstOccursInOrder(
                    debridMigration,
                    first: "CredentialScopeRegistry.shared.isMigrationEligible(capture)",
                    second: "migrateLegacySlot(service:"
                ),
            occursInOrder(debridMigrationSlot, [
                "owner == self.owner",
                "CredentialScopeRegistry.shared.isCurrent(capture)",
                "storage.durableRead(markerAccount)",
                "storage.durableRead(sourceAccount)",
                "certifyMutation(encoded",
                "storage.durableRead(destinationAccount)",
                "certifyMutation(source",
                "certifyMutation(nil"
            ]),
            modeTraktMigration,
            modeEstablishment
        ].allSatisfy { $0 }

        let restoreBody = functionRegion(sync, startingAt: "private func restore()") ?? ""
        let rawRestoreBody = rawScopedRegion(sync, startingAt: "private func restore()") ?? ""
        let closureFunctions = sourceManifest.reduce(into: [ScopedFunction]()) { functions, spec in
            guard let source = sourceSet.requiredText[spec.path] else { return }
            functions.append(contentsOf: functionRegions(source))
        }
        let recoveryReferenceScopes = [
            scopedRegion(sync, startingAt: "final class VortXSyncManager") ?? ""
        ]
        let establishmentCall = callExpressionRange(
            in: restoreBody,
            callee: "establishCredentialOwner"
        )
        let recoveryBeforeEstablishmentRegion: String
        if let establishmentCall {
            recoveryBeforeEstablishmentRegion = String(restoreBody[..<establishmentCall.lowerBound])
        } else {
            recoveryBeforeEstablishmentRegion = restoreBody
        }
        let establishmentGuardRegion = authenticationGuardRegion(establishOwner)
        let hasRawRecoveryReaderBeforeEstablishment = containsRawReaderInReachableFunctions(
            startingAt: "restore",
            rootSource: recoveryBeforeEstablishmentRegion,
            rootRawSource: rawRestoreBody,
            functions: closureFunctions,
            referenceScopes: recoveryReferenceScopes,
            startingOwner: "VortXSyncManager"
        )
        let hasRawRecoveryReaderDuringEstablishment = containsRawReaderInReachableFunctions(
            startingAt: "establishCredentialOwner",
            rootSource: establishmentGuardRegion,
            rootRawSource: rawEstablishOwner,
            functions: closureFunctions,
            referenceScopes: recoveryReferenceScopes,
            startingOwner: "VortXSyncManager"
        )
        let establishmentFailure = establishmentFailureRegion(in: restoreBody)
        let hasRawRecoveryReaderInEstablishmentFailure: Bool
        if let establishmentFailure {
            hasRawRecoveryReaderInEstablishmentFailure = containsRawReaderInReachableFunctions(
                startingAt: "restore",
                rootSource: establishmentFailure,
                rootRawSource: rawRestoreBody,
                functions: closureFunctions,
                referenceScopes: recoveryReferenceScopes,
                startingOwner: "VortXSyncManager"
            )
        } else {
            hasRawRecoveryReaderInEstablishmentFailure = false
        }
        let hasRawRecoveryReader = hasRawRecoveryReaderBeforeEstablishment
            || hasRawRecoveryReaderDuringEstablishment
            || hasRawRecoveryReaderInEstablishmentFailure
        let hasCertifiedRecoveryReader = restoreBody.contains("Keychain.confirmedString(")
        let directRuntimeRecoveryPassed = !restoreBody.isEmpty
            && !rawRestoreBody.isEmpty
            && !containsSwiftInterpolationMarker(in: rawRestoreBody)
            && hasCertifiedRecoveryReader
            && !hasRawRecoveryReader
            && certifiedReadIsGuarded(restoreBody)
            && establishmentCall != nil
            && establishmentFailure != nil
            && occursInOrder(restoreBody, [
                "Keychain.confirmedString(",
                "bindCredentialOwner(scope)",
                "establishCredentialOwner("
            ])
        let completeRestoredSession = functionRegion(
            sync,
            startingAt: "private func completeRestoredSession("
        ) ?? ""
        let scheduleRestoreRetry = functionRegion(
            sync,
            startingAt: "private func scheduleRestoreCredentialOwnerRetry("
        ) ?? ""
        let restorePreEstablishmentFunctions = closureFunctions.filter {
            !($0.owner == "VortXSyncManager"
                && ($0.name == "completeRestoredSession" || $0.name == "establishCredentialOwner"))
        }
        let completeEstablishmentCall = callExpressionRange(
            in: completeRestoredSession,
            callee: "establishCredentialOwner"
        )
        let completeBeforeEstablishment = completeEstablishmentCall.map {
            String(completeRestoredSession[..<$0.lowerBound])
        } ?? completeRestoredSession
        let completionPreEstablishmentFunctions = closureFunctions.filter {
            !($0.owner == "VortXSyncManager" && $0.name == "establishCredentialOwner")
        }
        let indirectHasRawRecoveryReader = containsRawReaderInReachableFunctions(
            startingAt: "restore",
            rootSource: restoreBody,
            rootRawSource: rawRestoreBody,
            functions: restorePreEstablishmentFunctions,
            referenceScopes: recoveryReferenceScopes,
            startingOwner: "VortXSyncManager"
        ) || containsRawReaderInReachableFunctions(
            startingAt: "completeRestoredSession",
            rootSource: completeBeforeEstablishment,
            rootRawSource: completeBeforeEstablishment,
            functions: completionPreEstablishmentFunctions,
            referenceScopes: recoveryReferenceScopes,
            startingOwner: "VortXSyncManager"
        )
        let indirectRuntimeRecoveryPassed = !restoreBody.isEmpty
            && !rawRestoreBody.isEmpty
            && !containsSwiftInterpolationMarker(in: rawRestoreBody)
            && !indirectHasRawRecoveryReader
            && occursInOrder(restoreBody, [
                "switch Keychain.confirmedString(kcAccount)",
                "case .failure:",
                "return",
                "case .missing:",
                "return",
                "case let .value(value):",
                "persisted = value",
                "logCredentialOwnerAcquisitionDenied(",
                "scheduleRestoreCredentialOwnerRetry("
            ])
            && restoreCompletionDominatesPublication(completeRestoredSession)
            && restoreCallersPropagateFailure(restore: restoreBody, retry: scheduleRestoreRetry)
        let adoptBody = functionRegion(sync, startingAt: "private func adopt(") ?? ""
        let interactiveAdoptPassed = !completeRestoredSession.isEmpty
            && !adoptBody.isEmpty
            && adoptEstablishmentDominatesPublication(adoptBody)
            && allAdoptCallersPropagateFailure(sync)
        let runtimeRecoveryPassed: Bool
        switch mode {
        case .production:
            runtimeRecoveryPassed = indirectRuntimeRecoveryPassed && interactiveAdoptPassed
        case .fixture:
            runtimeRecoveryPassed = directRuntimeRecoveryPassed
        }
        let singleRootPassed = sourceSet.requiredExternal.isEmpty
            && sourceSet.inventoryExternal.isEmpty
            && sourceSet.inventoryFiles.allSatisfy { isInside($0, root: root) }

        return [
            Gate(
                id: "GREEN-01-SOURCE-MANIFEST",
                passed: manifestPassed,
                detail: manifestPassed
                    ? "all seven credential sources and every declared anchor are present"
                    : manifestFailureDetail(sourceSet)
            ),
            Gate(
                id: "GREEN-02-SINGLE-RESULT-DEFINITIONS",
                passed: resultDefinitionsPassed,
                detail: resultDefinitionsPassed
                    ? "each typed result has exactly one production declaration in SourcesShared"
                    : "\(requiredResultNames.map { "\($0)=\(declarations[$0, default: 0])" }.joined(separator: ", "))"
            ),
            Gate(
                id: "GREEN-03-INTEGRATED-CREDENTIAL-COMPILER",
                passed: compilerPassed,
                detail: compilerPassed
                    ? "all seven credential sources typecheck together with the standalone closure stubs and driver"
                    : compilerFailureDetail(compiler)
            ),
            Gate(
                id: "GREEN-04-DURABLE-CREDENTIAL-BOUNDARY",
                passed: durablePassed,
                detail: durablePassed
                    ? "secure reads, durable reads, and typed mutations remain certified boundaries"
                    : "a required typed readback or mutation anchor is missing"
            ),
            Gate(
                id: "GREEN-05-OWNER-AUTHORITY-FENCES",
                passed: authorityPassed,
                detail: authorityPassed
                    ? "runtime credential consumers check the shared owner capture"
                    : "one or more credential consumers lack the shared owner authority fence"
            ),
            Gate(
                id: "GREEN-06-AUTHENTICATED-MIGRATION-FENCE",
                passed: migrationPassed,
                detail: migrationPassed
                    ? "legacy claims are reachable only through authenticated owner establishment"
                    : "one or more legacy-claim paths lack the authenticated owner boundary"
            ),
            Gate(
                id: "GREEN-07-RUNTIME-RECOVERY-AUTHORITY",
                passed: runtimeRecoveryPassed,
                detail: runtimeRecoveryPassed
                    ? "runtime restore uses the certified reader and requires successful owner establishment"
                    : "runtime restore lacks a certified reader or a fail-closed owner-establishment guard"
            ),
            Gate(
                id: "GREEN-08-SINGLE-ROOT-INTEGRITY",
                passed: singleRootPassed,
                detail: singleRootPassed
                    ? "every inspected production source resolves inside the selected root"
                    : "a production source resolves outside the selected root"
            )
        ]
    }

    private static func validateGateInventory(_ gates: [Gate]) -> [String] {
        let ids = gates.map(\.id)
        var failures: [String] = []
        if ids.count != fixedGateIDs.count || Set(ids) != Set(fixedGateIDs) {
            failures.append(
                "gate IDs must be exactly \(fixedGateIDs.joined(separator: ", "))"
            )
        }
        if Set(ids).count != ids.count {
            failures.append("gate IDs contain a duplicate")
        }
        for gate in gates where gate.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            failures.append("gate \(gate.id) has no diagnostic detail")
        }
        return failures
    }

    private static func declarationCounts(sourceSet: SourceSet) -> [String: Int] {
        var counts = Dictionary(uniqueKeysWithValues: requiredResultNames.map { ($0, 0) })
        for url in sourceSet.inventoryFiles {
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let code = lexicalCode(source)
            for name in requiredResultNames {
                counts[name, default: 0] += declarationCount(name: name, in: code)
            }
        }
        return counts
    }

    private static func declarationCount(name: String, in source: String) -> Int {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        let pattern = #"\b(?:enum|struct|class|actor|protocol|typealias)[ \t\r\n]+\#(escapedName)\b"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return 0 }
        return expression.numberOfMatches(
            in: source,
            range: NSRange(source.startIndex..<source.endIndex, in: source)
        )
    }

    private static func lexicalCode(_ source: String) -> String {
        swiftLexicalScan(source).code
    }

    private static func swiftLexicalScan(
        _ source: String
    ) -> (code: String, hasExecutableInterpolation: Bool) {
        let characters = Array(source)
        let count = characters.count
        var result = Array(repeating: Character(" "), count: count)
        var hasExecutableInterpolation = false
        var index = 0

        func mask(_ index: Int) {
            guard index < result.count else { return }
            result[index] = characters[index] == "\n" ? "\n" : " "
        }

        func mask(_ range: Range<Int>) {
            for position in range where position < result.count {
                mask(position)
            }
        }

        func matches(_ character: Character, count required: Int, at start: Int) -> Bool {
            guard required >= 0, start >= 0, start + required <= count else { return false }
            return (start..<(start + required)).allSatisfy { characters[$0] == character }
        }

        while index < count {
            if matches("/", count: 2, at: index) {
                while index < count {
                    mask(index)
                    let isEnd = characters[index] == "\n"
                    index += 1
                    if isEnd { break }
                }
                continue
            }
            if index + 1 < count,
               characters[index] == "/",
               characters[index + 1] == "*" {
                var depth = 1
                mask(index..<(index + 2))
                index += 2
                while index < count, depth > 0 {
                    if index + 1 < count,
                       characters[index] == "/",
                       characters[index + 1] == "*" {
                        depth += 1
                        mask(index..<(index + 2))
                        index += 2
                    } else if index + 1 < count,
                              characters[index] == "*",
                              characters[index + 1] == "/" {
                        depth -= 1
                        mask(index..<(index + 2))
                        index += 2
                    } else {
                        mask(index)
                        index += 1
                    }
                }
                continue
            }

            var hashCount = 0
            var quoteStart = index
            while quoteStart < count, characters[quoteStart] == "#" {
                hashCount += 1
                quoteStart += 1
            }
            guard quoteStart < count, characters[quoteStart] == "\"" else {
                result[index] = characters[index]
                index += 1
                continue
            }

            let quoteCount = matches("\"", count: 3, at: quoteStart) ? 3 : 1
            mask(index..<(quoteStart + quoteCount))
            index = quoteStart + quoteCount
            while index < count {
                if hashCount == 0, characters[index] == "\\" {
                    var slashEnd = index
                    while slashEnd < count, characters[slashEnd] == "\\" {
                        slashEnd += 1
                    }
                    let slashCount = slashEnd - index
                    mask(index..<slashEnd)
                    if slashCount % 2 == 1,
                       slashEnd < count,
                       characters[slashEnd] == "(" {
                        hasExecutableInterpolation = true
                    }
                    if slashCount % 2 == 1, slashEnd < count {
                        mask(slashEnd)
                        index = slashEnd + 1
                    } else {
                        index = slashEnd
                    }
                    continue
                }

                if hashCount > 0, characters[index] == "\\" {
                    var markerEnd = index + 1
                    var markerHashes = 0
                    while markerEnd < count, characters[markerEnd] == "#" {
                        markerHashes += 1
                        markerEnd += 1
                    }
                    if markerHashes == hashCount,
                       markerEnd < count,
                       characters[markerEnd] == "(" {
                        hasExecutableInterpolation = true
                    }
                }

                if matches("\"", count: quoteCount, at: index),
                   matches("#", count: hashCount, at: index + quoteCount) {
                    mask(index..<(index + quoteCount + hashCount))
                    index += quoteCount + hashCount
                    break
                }
                mask(index)
                index += 1
            }
        }
        return (code: String(result), hasExecutableInterpolation: hasExecutableInterpolation)
    }

    private static func scopedRegion(_ source: String, startingAt marker: String) -> String? {
        let code = lexicalCode(source)
        guard let markerRange = code.range(of: marker),
              let openingBrace = code.range(of: "{", range: markerRange.upperBound..<code.endIndex)
        else { return nil }
        guard let closingBrace = matchingClosingBrace(in: code, openingBrace: openingBrace.lowerBound) else {
            return nil
        }
        return String(code[markerRange.lowerBound...closingBrace])
    }

    private static func rawScopedRegion(_ source: String, startingAt marker: String) -> String? {
        let code = lexicalCode(source)
        guard let markerRange = code.range(of: marker),
              let openingBrace = code.range(
                  of: "{",
                  range: markerRange.upperBound..<code.endIndex
              ),
              let closingBrace = matchingClosingBrace(
                  in: code,
                  openingBrace: openingBrace.lowerBound
        )
        else { return nil }
        return rawSourceSlice(
            source,
            matching: markerRange.lowerBound..<code.index(after: closingBrace),
            in: code
        )
    }

    private static func rawSourceSlice(
        _ source: String,
        matching range: Range<String.Index>,
        in lexicalSource: String
    ) -> String? {
        let lowerOffset = lexicalSource.distance(
            from: lexicalSource.startIndex,
            to: range.lowerBound
        )
        let upperOffset = lexicalSource.distance(
            from: lexicalSource.startIndex,
            to: range.upperBound
        )
        guard let lowerBound = source.index(
                  source.startIndex,
                  offsetBy: lowerOffset,
                  limitedBy: source.endIndex
              ),
              let upperBound = source.index(
                  source.startIndex,
                  offsetBy: upperOffset,
                  limitedBy: source.endIndex
              )
        else { return nil }
        return String(source[lowerBound..<upperBound])
    }

    private static func functionRegion(_ source: String, startingAt marker: String) -> String? {
        scopedRegion(source, startingAt: marker)
    }

    private static func functionRegions(_ source: String) -> [ScopedFunction] {
        let code = lexicalCode(source)
        guard let expression = try? NSRegularExpression(
            pattern: #"\bfunc[ \t\r\n]+([A-Za-z_][A-Za-z0-9_]*)[ \t\r\n]*\("#
        ) else { return [] }

        let fullRange = NSRange(code.startIndex..<code.endIndex, in: code)
        return expression.matches(in: code, range: fullRange).compactMap { match -> ScopedFunction? in
            guard let matchRange = Range(match.range, in: code),
                  let nameRange = Range(match.range(at: 1), in: code),
                  let openingBrace = code.range(of: "{", range: matchRange.upperBound..<code.endIndex),
                  let closingBrace = matchingClosingBrace(in: code, openingBrace: openingBrace.lowerBound),
                  !code[matchRange.upperBound..<openingBrace.lowerBound].contains("func"),
                  let rawSource = rawSourceSlice(
                      source,
                      matching: matchRange.lowerBound..<code.index(after: closingBrace),
                      in: code
                  )
            else { return nil }
            return ScopedFunction(
                name: String(code[nameRange]),
                owner: lexicalOwner(
                    in: code,
                    functionRange: matchRange.lowerBound..<code.index(after: closingBrace)
                ),
                source: String(code[matchRange.lowerBound...closingBrace]),
                rawSource: rawSource
            )
        }
    }

    private static func lexicalOwner(
        in code: String,
        functionRange: Range<String.Index>
    ) -> String? {
        guard let expression = try? NSRegularExpression(
            pattern: #"\b(?:class|struct|enum|actor|protocol|extension)[ \t\r\n]+([A-Za-z_][A-Za-z0-9_]*(?:[ \t\r\n]*\.[A-Za-z_][A-Za-z0-9_]*)*)"#
        ) else { return nil }

        let prefix = code.startIndex..<functionRange.lowerBound
        let matches = expression.matches(in: code, range: NSRange(prefix, in: code))
        var selected: (start: String.Index, name: String)?
        for match in matches {
            guard let matchRange = Range(match.range, in: code),
                  let nameRange = Range(match.range(at: 1), in: code),
                  let openingBrace = code.range(
                      of: "{",
                      range: matchRange.upperBound..<functionRange.upperBound
                  ),
                  let closingBrace = matchingClosingBrace(in: code, openingBrace: openingBrace.lowerBound),
                  functionRange.lowerBound > openingBrace.lowerBound,
                  functionRange.upperBound <= code.index(after: closingBrace)
            else { continue }

            if selected == nil || matchRange.lowerBound > selected!.start {
                selected = (matchRange.lowerBound, String(code[nameRange]).filter { !isWhitespace($0) })
            }
        }
        return selected?.name
    }

    private static func authenticationGuardRegion(_ source: String) -> String {
        let code = lexicalCode(source)
        guard let authenticationRange = code.range(
            of: "credentialAuthority.establishAuthenticatedOwner(capture)"
        ),
        let elseRange = code.range(
            of: "else",
            range: authenticationRange.upperBound..<code.endIndex
        ),
        let openingBrace = code.range(
            of: "{",
            range: elseRange.upperBound..<code.endIndex
        ),
        let closingBrace = matchingClosingBrace(in: code, openingBrace: openingBrace.lowerBound)
        else {
            return source
        }
        return String(code[code.startIndex...closingBrace])
    }

    private static func callExpressionRange(in source: String, callee: String) -> Range<String.Index>? {
        callExpressionRanges(in: source, callee: callee).first
    }

    private static func callExpressionRanges(
        in source: String,
        callee: String
    ) -> [Range<String.Index>] {
        let code = lexicalCode(source)
        var searchStart = code.startIndex
        var ranges: [Range<String.Index>] = []
        while searchStart < code.endIndex {
            guard let calleeRange = code.range(
                of: callee,
                range: searchStart..<code.endIndex
            ) else { return ranges }

            let previous = calleeRange.lowerBound > code.startIndex
                ? code[code.index(before: calleeRange.lowerBound)]
                : nil
            let next = calleeRange.upperBound < code.endIndex
                ? code[calleeRange.upperBound]
                : nil
            let previousIsIdentifier = previous.map { isIdentifierCharacter($0) } ?? false
            let nextIsIdentifier = next.map { isIdentifierCharacter($0) } ?? false
            let hasIdentifierBoundary = !previousIsIdentifier && !nextIsIdentifier
            if hasIdentifierBoundary {
                var openingParenthesis = calleeRange.upperBound
                while openingParenthesis < code.endIndex,
                      isWhitespace(code[openingParenthesis]) {
                    openingParenthesis = code.index(after: openingParenthesis)
                }
                if openingParenthesis < code.endIndex,
                   code[openingParenthesis] == "(",
                   let closingParenthesis = matchingClosingDelimiter(
                       in: code,
                       opening: openingParenthesis,
                       openingCharacter: "(",
                       closingCharacter: ")"
                   ) {
                    let range = calleeRange.lowerBound..<code.index(after: closingParenthesis)
                    ranges.append(range)
                    searchStart = range.upperBound
                    continue
                }
            }

            searchStart = code.index(after: calleeRange.lowerBound)
        }
        return ranges
    }

    private static func trimmedWhitespaceRange(
        in source: String,
        range: Range<String.Index>
    ) -> Range<String.Index>? {
        var lowerBound = range.lowerBound
        var upperBound = range.upperBound
        while lowerBound < upperBound, isWhitespace(source[lowerBound]) {
            lowerBound = source.index(after: lowerBound)
        }
        while lowerBound < upperBound {
            let previous = source.index(before: upperBound)
            guard isWhitespace(source[previous]) else { break }
            upperBound = previous
        }
        return lowerBound < upperBound ? lowerBound..<upperBound : nil
    }

    private static func topLevelSegments(
        in source: String,
        range: Range<String.Index>
    ) -> [Range<String.Index>]? {
        var parenthesisDepth = 0
        var bracketDepth = 0
        var braceDepth = 0
        var segments: [Range<String.Index>] = []
        var segmentStart = range.lowerBound
        var cursor = range.lowerBound

        func nonEmptySegment(_ segment: Range<String.Index>) -> Range<String.Index>? {
            var lowerBound = segment.lowerBound
            while lowerBound < segment.upperBound, isWhitespace(source[lowerBound]) {
                lowerBound = source.index(after: lowerBound)
            }
            return lowerBound < segment.upperBound ? lowerBound..<segment.upperBound : nil
        }

        while cursor < range.upperBound {
            let character = source[cursor]
            switch character {
            case "(":
                parenthesisDepth += 1
            case ")":
                guard parenthesisDepth > 0 else { return nil }
                parenthesisDepth -= 1
            case "[":
                bracketDepth += 1
            case "]":
                guard bracketDepth > 0 else { return nil }
                bracketDepth -= 1
            case "{":
                braceDepth += 1
            case "}":
                guard braceDepth > 0 else { return nil }
                braceDepth -= 1
            case "," where parenthesisDepth == 0 && bracketDepth == 0 && braceDepth == 0:
                guard let segment = nonEmptySegment(segmentStart..<cursor) else { return nil }
                segments.append(segment)
                segmentStart = source.index(after: cursor)
            default:
                break
            }
            cursor = source.index(after: cursor)
        }

        guard parenthesisDepth == 0, bracketDepth == 0, braceDepth == 0 else { return nil }
        if let segment = nonEmptySegment(segmentStart..<range.upperBound) {
            segments.append(segment)
        }
        return segments
    }

    private static func topLevelColon(
        in source: String,
        range: Range<String.Index>
    ) -> String.Index? {
        var parenthesisDepth = 0
        var bracketDepth = 0
        var braceDepth = 0
        var cursor = range.lowerBound

        while cursor < range.upperBound {
            let character = source[cursor]
            switch character {
            case "(":
                parenthesisDepth += 1
            case ")":
                guard parenthesisDepth > 0 else { return nil }
                parenthesisDepth -= 1
            case "[":
                bracketDepth += 1
            case "]":
                guard bracketDepth > 0 else { return nil }
                bracketDepth -= 1
            case "{":
                braceDepth += 1
            case "}":
                guard braceDepth > 0 else { return nil }
                braceDepth -= 1
            case ":" where parenthesisDepth == 0 && bracketDepth == 0 && braceDepth == 0:
                return cursor
            default:
                break
            }
            cursor = source.index(after: cursor)
        }
        return nil
    }

    private static func isSwiftIdentifier(_ value: String) -> Bool {
        guard let first = value.first,
              first == "_" || first.isLetter else { return false }
        return value.allSatisfy(isIdentifierCharacter)
    }

    private static func topLevelLabeledArgumentRanges(
        in source: String,
        callRange: Range<String.Index>
    ) -> [String: Range<String.Index>]? {
        guard let openingParenthesis = source.range(of: "(", range: callRange)?.lowerBound,
              openingParenthesis < callRange.upperBound
        else { return nil }
        let closingParenthesis = source.index(before: callRange.upperBound)
        guard source[closingParenthesis] == ")" else { return nil }

        guard let segments = topLevelSegments(
            in: source,
            range: source.index(after: openingParenthesis)..<closingParenthesis
        ) else { return nil }

        var arguments: [String: Range<String.Index>] = [:]
        for segment in segments {
            guard let colon = topLevelColon(in: source, range: segment),
                  let labelRange = trimmedWhitespaceRange(
                      in: source,
                      range: segment.lowerBound..<colon
                  )
            else { return nil }

            let valueRange = source.index(after: colon)..<segment.upperBound
            let label = String(source[labelRange])
            guard valueRange.lowerBound < valueRange.upperBound,
                  isSwiftIdentifier(label),
                  arguments[label] == nil
            else { return nil }
            arguments[label] = valueRange
        }
        return arguments
    }

    private static func functionBodyRange(in source: String) -> Range<String.Index>? {
        guard let openingBrace = source.firstIndex(of: "{"),
              let closingBrace = matchingClosingBrace(in: source, openingBrace: openingBrace)
        else { return nil }
        return source.index(after: openingBrace)..<closingBrace
    }

    private static func isTopLevelCall(
        _ callRange: Range<String.Index>,
        in source: String,
        functionBody: Range<String.Index>
    ) -> Bool {
        guard functionBody.lowerBound <= callRange.lowerBound,
              callRange.upperBound <= functionBody.upperBound else { return false }

        var parenthesisDepth = 0
        var bracketDepth = 0
        var braceDepth = 0
        var cursor = functionBody.lowerBound
        while cursor < callRange.lowerBound {
            switch source[cursor] {
            case "(":
                parenthesisDepth += 1
            case ")":
                guard parenthesisDepth > 0 else { return false }
                parenthesisDepth -= 1
            case "[":
                bracketDepth += 1
            case "]":
                guard bracketDepth > 0 else { return false }
                bracketDepth -= 1
            case "{":
                braceDepth += 1
            case "}":
                guard braceDepth > 0 else { return false }
                braceDepth -= 1
            default:
                break
            }
            cursor = source.index(after: cursor)
        }
        return parenthesisDepth == 0 && bracketDepth == 0 && braceDepth == 0
    }

    private static func directLetBindingName(
        before callRange: Range<String.Index>,
        in source: String,
        functionBody: Range<String.Index>
    ) -> String? {
        guard isTopLevelCall(callRange, in: source, functionBody: functionBody) else { return nil }
        let prefix = String(source[functionBody.lowerBound..<callRange.lowerBound])
        let pattern = #"\blet[ \t\r\n]+([A-Za-z_][A-Za-z0-9_]*)[ \t\r\n]*=[ \t\r\n]*"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(prefix.startIndex..<prefix.endIndex, in: prefix)
        guard let match = expression.matches(in: prefix, range: range).last,
              NSMaxRange(match.range) == range.length,
              let nameRange = Range(match.range(at: 1), in: prefix)
        else { return nil }
        return String(prefix[nameRange])
    }

    private static func isExactCallRHS(
        _ callRange: Range<String.Index>,
        in source: String,
        functionBody: Range<String.Index>
    ) -> Bool {
        var cursor = callRange.upperBound
        while cursor < functionBody.upperBound {
            let character = source[cursor]
            if character == "\n" || character == ";" { return true }
            guard isWhitespace(character) else { return false }
            cursor = source.index(after: cursor)
        }
        return true
    }

    private static func normalizedExpression(
        in source: String,
        range: Range<String.Index>
    ) -> String {
        String(source[range].filter { !isWhitespace($0) })
    }

    private static func tupleArgumentMatches(
        _ expected: [(source: String, destination: String)],
        source: String,
        valueRange: Range<String.Index>
    ) -> Bool {
        guard let trimmedValue = trimmedWhitespaceRange(in: source, range: valueRange),
              source[trimmedValue.lowerBound] == "[",
              let closingBracket = matchingClosingDelimiter(
                  in: source,
                  opening: trimmedValue.lowerBound,
                  openingCharacter: "[",
                  closingCharacter: "]"
              ),
              source.index(after: closingBracket) == trimmedValue.upperBound,
              let tuples = topLevelSegments(
                  in: source,
                  range: source.index(after: trimmedValue.lowerBound)..<closingBracket
              ),
              tuples.count == expected.count
        else { return false }

        for (tupleRange, expectedTuple) in zip(tuples, expected) {
            guard let trimmedTuple = trimmedWhitespaceRange(in: source, range: tupleRange),
                  source[trimmedTuple.lowerBound] == "(",
                  let closingParenthesis = matchingClosingDelimiter(
                      in: source,
                      opening: trimmedTuple.lowerBound,
                      openingCharacter: "(",
                      closingCharacter: ")"
                  ),
                  source.index(after: closingParenthesis) == trimmedTuple.upperBound,
                  let elements = topLevelSegments(
                      in: source,
                      range: source.index(after: trimmedTuple.lowerBound)..<closingParenthesis
                  ),
                  elements.count == 2,
                  normalizedExpression(in: source, range: elements[0]) == expectedTuple.source,
                  normalizedExpression(in: source, range: elements[1]) == expectedTuple.destination
            else { return false }
        }
        return true
    }

    private static func exactProvenanceLiteral(
        _ expected: String,
        rawSource: String,
        matching valueRange: Range<String.Index>,
        in lexicalSource: String
    ) -> Bool {
        guard let rawValue = rawSourceSlice(
            rawSource,
            matching: valueRange,
            in: lexicalSource
        ),
        lexicalCode(rawValue).allSatisfy(isWhitespace)
        else { return false }
        return rawValue.trimmingCharacters(in: .whitespacesAndNewlines) == "\"\(expected)\""
    }

    private static func memberReferenceRange(
        in source: String,
        valueRange: Range<String.Index>,
        owner: String,
        member: String
    ) -> Range<String.Index>? {
        let escapedOwner = NSRegularExpression.escapedPattern(for: owner)
        let escapedMember = NSRegularExpression.escapedPattern(for: member)
        let pattern = #"[ \t\r\n]*(\#(escapedOwner)[ \t\r\n]*\.[ \t\r\n]*\#(escapedMember)\b)[ \t\r\n]*"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let requestedRange = NSRange(valueRange, in: source)
        guard let match = expression.firstMatch(in: source, range: requestedRange),
              match.range == requestedRange,
              let memberRange = Range(match.range(at: 1), in: source)
        else { return nil }
        return memberRange
    }

    private static func validatedProductionMigrationClaim(
        in source: String,
        rawSource: String,
        functionBody: Range<String.Index>,
        claim: ProductionMigrationClaim
    ) -> ValidatedProductionMigrationClaim? {
        let callRanges = callExpressionRanges(
            in: source,
            callee: claim.callee
        )
        var matches: [ValidatedProductionMigrationClaim] = []
        for callRange in callRanges {
            guard directLetBindingName(
                before: callRange,
                in: source,
                functionBody: functionBody
            ) == claim.bindingName,
            isExactCallRHS(
                callRange,
                in: source,
                functionBody: functionBody
            ) else { continue }
            guard let arguments = topLevelLabeledArgumentRanges(in: source, callRange: callRange) else {
                continue
            }
            let expectedArgumentsMatch = claim.expectedArguments.allSatisfy { expected in
                guard let valueRange = arguments[expected.label] else { return false }
                return normalizedExpression(in: source, range: valueRange) == expected.expression
            }
            guard expectedArgumentsMatch else { continue }
            guard let provenanceRange = arguments["provenanceTag"],
                  exactProvenanceLiteral(
                      claim.provenanceTag,
                      rawSource: rawSource,
                      matching: provenanceRange,
                      in: source
                  )
            else { continue }
            guard let sourceReadRange = arguments["sourceRead"],
                  let memberRange = memberReferenceRange(
                      in: source,
                      valueRange: sourceReadRange,
                      owner: "Keychain",
                      member: "durableString"
                  )
            else { continue }
            if let expectedSlots = claim.expectedSlots {
                guard let slotsRange = arguments["slots"],
                      tupleArgumentMatches(expectedSlots, source: source, valueRange: slotsRange)
                else { continue }
            }
            matches.append(
                ValidatedProductionMigrationClaim(
                    callRange: callRange,
                    sourceReadMemberRange: memberRange
                )
            )
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    private static func masking(
        _ ranges: [Range<String.Index>],
        in source: String
    ) -> String {
        let offsets: [(lower: Int, upper: Int)] = ranges.map { range in
            (
                lower: source.distance(from: source.startIndex, to: range.lowerBound),
                upper: source.distance(from: source.startIndex, to: range.upperBound)
            )
        }.sorted { $0.lower > $1.lower }
        var result = source
        for offset in offsets {
            let lower = result.index(result.startIndex, offsetBy: offset.lower)
            let upper = result.index(result.startIndex, offsetBy: offset.upper)
            let replacement = String(result[lower..<upper].map { character in
                character == "\n" ? "\n" : " "
            })
            result.replaceSubrange(lower..<upper, with: replacement)
        }
        return result
    }

    private static func productionTraktMigrationReaderProjection(
        _ source: String,
        rawSource: String
    ) -> (valid: Bool, remainder: String) {
        let claims: [ProductionMigrationClaim] = [
            ProductionMigrationClaim(
                callee: "CredentialLegacyClaim.claimGlobalSlotSet",
                bindingName: "primary",
                expectedArguments: [],
                expectedSlots: [
                    (source: "legacyAccess", destination: "access(ns)"),
                    (source: "legacyRefresh", destination: "refresh(ns)"),
                    (source: "legacyExpiry", destination: "expiry(ns)")
                ],
                provenanceTag: "trakt-token-set"
            ),
            ProductionMigrationClaim(
                callee: "CredentialLegacyClaim.claimGlobalSlot",
                bindingName: "createdAtResult",
                expectedArguments: [
                    (label: "sourceAccount", expression: "legacyCreatedAt"),
                    (label: "destinationAccount", expression: "createdAt(ns)")
                ],
                expectedSlots: nil,
                provenanceTag: "trakt-created-at"
            ),
            ProductionMigrationClaim(
                callee: "CredentialLegacyClaim.claimGlobalSlot",
                bindingName: "sessionResult",
                expectedArguments: [
                    (label: "sourceAccount", expression: "legacySession"),
                    (label: "destinationAccount", expression: "session(ns)")
                ],
                expectedSlots: nil,
                provenanceTag: "trakt-session"
            )
        ]
        let claimCallees = [
            "CredentialLegacyClaim.claimGlobalSlotSet",
            "CredentialLegacyClaim.claimGlobalSlot"
        ]
        guard let functionBody = functionBodyRange(in: source),
              !containsConditionalCompilationDirective(in: source[source.startIndex..<source.endIndex])
        else {
            return (valid: false, remainder: source)
        }
        let allClaimRanges = claimCallees.flatMap {
            callExpressionRanges(in: source, callee: $0)
        }
        guard allClaimRanges.count == claims.count else {
            return (valid: false, remainder: source)
        }

        var validatedClaims: [ValidatedProductionMigrationClaim] = []
        for claim in claims {
            guard let validatedClaim = validatedProductionMigrationClaim(
                in: source,
                rawSource: rawSource,
                functionBody: functionBody,
                claim: claim
            ) else {
                return (valid: false, remainder: source)
            }
            validatedClaims.append(validatedClaim)
        }
        guard allClaimRanges.allSatisfy({ range in
            validatedClaims.contains { $0.callRange == range }
        }) else {
            return (valid: false, remainder: source)
        }

        let intendedRanges = validatedClaims.map(\.sourceReadMemberRange)
        let intendedOffsets = Set(intendedRanges.map {
            source.distance(from: source.startIndex, to: $0.lowerBound)
        })
        guard intendedRanges.count == claims.count,
              intendedOffsets.count == claims.count
        else {
            return (valid: false, remainder: source)
        }
        return (
            valid: true,
            remainder: masking(intendedRanges, in: source)
        )
    }

    private static func establishmentFailureRegion(in source: String) -> String? {
        let code = lexicalCode(source)
        guard let establishmentCall = callExpressionRange(
            in: code,
            callee: "establishCredentialOwner"
        ) else { return nil }
        guard let restoreBodyOpeningBrace = code.firstIndex(of: "{") else { return nil }
        var restoreBodyDepth = 0
        var restoreCursor = code.index(after: restoreBodyOpeningBrace)
        while restoreCursor < establishmentCall.lowerBound {
            if code[restoreCursor] == "{" {
                restoreBodyDepth += 1
            } else if code[restoreCursor] == "}" {
                guard restoreBodyDepth > 0 else { return nil }
                restoreBodyDepth -= 1
            }
            restoreCursor = code.index(after: restoreCursor)
        }
        guard restoreBodyDepth == 0 else { return nil }

        let prefix = code[..<establishmentCall.lowerBound]
        guard let guardRange = prefix.range(of: "guard", options: .backwards) else { return nil }
        let before = guardRange.lowerBound > code.startIndex
            ? code[code.index(before: guardRange.lowerBound)]
            : nil
        let after = guardRange.upperBound < code.endIndex ? code[guardRange.upperBound] : nil
        guard !(before.map(isIdentifierCharacter) ?? false),
              !(after.map(isIdentifierCharacter) ?? false),
              prefix[guardRange.upperBound..<prefix.endIndex].allSatisfy(isWhitespace),
              conditionalCompilationDepth(
                  in: code[code.index(after: restoreBodyOpeningBrace)..<guardRange.lowerBound]
              ) == 0
        else { return nil }

        var cursor = establishmentCall.upperBound
        while cursor < code.endIndex, isWhitespace(code[cursor]) {
            cursor = code.index(after: cursor)
        }
        guard let elseRange = code.range(of: "else", range: cursor..<code.endIndex),
              elseRange.lowerBound == cursor,
              !(elseRange.upperBound < code.endIndex
                    && isIdentifierCharacter(code[elseRange.upperBound]))
        else { return nil }

        cursor = elseRange.upperBound
        while cursor < code.endIndex, isWhitespace(code[cursor]) {
            cursor = code.index(after: cursor)
        }
        guard cursor < code.endIndex,
              code[cursor] == "{",
              let closingBrace = matchingClosingBrace(in: code, openingBrace: cursor)
        else { return nil }

        let guardAndFailure = code[guardRange.lowerBound...closingBrace]
        guard !containsConditionalCompilationDirective(in: guardAndFailure) else { return nil }
        let failureBody = code[code.index(after: cursor)..<closingBrace]
            .filter { !isWhitespace($0) }
        guard failureBody == "return" else { return nil }
        return String(code[cursor...closingBrace])
    }

    private static func conditionalCompilationDepth(in source: Substring) -> Int? {
        var depth = 0
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop(while: isWhitespace)
            if trimmed.hasPrefix("#if") {
                depth += 1
            } else if trimmed.hasPrefix("#elseif") || trimmed.hasPrefix("#else") {
                guard depth > 0 else { return nil }
            } else if trimmed.hasPrefix("#endif") {
                guard depth > 0 else { return nil }
                depth -= 1
            }
        }
        return depth
    }

    private static func containsConditionalCompilationDirective(in source: Substring) -> Bool {
        source.split(separator: "\n", omittingEmptySubsequences: false).contains { line in
            let trimmed = line.drop(while: isWhitespace)
            return trimmed.hasPrefix("#if")
                || trimmed.hasPrefix("#elseif")
                || trimmed.hasPrefix("#else")
                || trimmed.hasPrefix("#endif")
        }
    }

    private static func isIdentifierCharacter(_ character: Character) -> Bool {
        character == "_" || character.isLetter || character.isNumber
    }

    private static func isWhitespace(_ character: Character) -> Bool {
        character == " " || character == "\t" || character == "\r" || character == "\n"
    }

    private static func containsSwiftInterpolationMarker(in source: String) -> Bool {
        swiftLexicalScan(source).hasExecutableInterpolation
    }

    private static func containsRawReaderInReachableFunctions(
        startingAt startName: String,
        rootSource: String,
        rootRawSource: String,
        functions: [ScopedFunction],
        referenceScopes: [String],
        startingOwner: String?
    ) -> Bool {
        let rawReaders = ["Keychain.string", "Keychain.durableString"]
        let scopedBindings = referenceScopes.flatMap(topLevelReferenceBindings)
        var queue: [(index: Int, source: String, rawSource: String)] = functions.indices
            .filter {
                functions[$0].name == startName
                    && functions[$0].owner == startingOwner
            }
            .map { (index: $0, source: rootSource, rawSource: rootRawSource) }
        var visited: Set<Int> = []

        while let next = queue.first {
            queue.removeFirst()
            let index = next.index
            guard visited.insert(index).inserted else { continue }
            let source = next.source

            if containsSwiftInterpolationMarker(in: next.rawSource)
                || containsRawReaderLexically(in: source, referenceScopes: referenceScopes) {
                return true
            }

            let localBindings = referenceBindings(in: source)

            for binding in scopedBindings where containsIdentifier(binding.name, in: source) {
                if rawReaders.contains(binding.target) {
                    return true
                }
                for candidate in functions.indices where !visited.contains(candidate) {
                    guard candidate != index,
                          candidate < functions.count,
                          functionTargetReaches(
                              binding.target,
                              candidate: functions[candidate],
                              currentOwner: functions[index].owner
                          )
                    else { continue }
                    queue.append((
                        index: candidate,
                        source: functions[candidate].source,
                        rawSource: functions[candidate].rawSource
                    ))
                }
            }

            for candidateIndex in functions.indices where !visited.contains(candidateIndex) {
                guard candidateIndex != index else { continue }
                let candidate = functions[candidateIndex]
                let localAliasReaches = localBindings.contains {
                    functionTargetReaches(
                        $0.target,
                        candidate: candidate,
                        currentOwner: functions[index].owner
                    ) && containsIdentifier($0.name, in: source)
                }
                guard functionCallReaches(
                    source,
                    candidate: candidate,
                    currentOwner: functions[index].owner
                ) || localAliasReaches
                else { continue }
                queue.append((
                    index: candidateIndex,
                    source: candidate.source,
                    rawSource: candidate.rawSource
                ))
            }
        }
        return false
    }

    private static func functionTargetReaches(
        _ target: String,
        candidate: ScopedFunction,
        currentOwner: String?
    ) -> Bool {
        let components = target.split(separator: ".", omittingEmptySubsequences: true)
        guard components.last.map(String.init) == candidate.name else { return false }
        switch components.count {
        case 1:
            return candidate.owner == nil || candidate.owner == currentOwner
        case 2:
            let qualifier = String(components[0])
            if qualifier == "self" {
                return candidate.owner == currentOwner
            }
            return candidate.owner == qualifier
        default:
            return false
        }
    }

    private static func functionCallReaches(
        _ source: String,
        candidate: ScopedFunction,
        currentOwner: String?
    ) -> Bool {
        let ownerMatchesUnqualified = candidate.owner == nil || candidate.owner == currentOwner
        if ownerMatchesUnqualified,
           hasUnqualifiedCall(in: source, callee: candidate.name) {
            return true
        }
        guard let owner = candidate.owner else { return false }
        return hasQualifiedCall(in: source, owner: owner, callee: candidate.name)
            || (currentOwner == owner && hasQualifiedCall(in: source, owner: "self", callee: candidate.name))
    }

    private static func hasUnqualifiedCall(in source: String, callee: String) -> Bool {
        let code = lexicalCode(source)
        for range in callExpressionRanges(in: code, callee: callee) {
            var cursor = range.lowerBound
            while cursor > code.startIndex {
                let previousIndex = code.index(before: cursor)
                let previous = code[previousIndex]
                if isWhitespace(previous) {
                    cursor = previousIndex
                    continue
                }
                if previous != "." { return true }
                break
            }
            if cursor == code.startIndex { return true }
        }
        return false
    }

    private static func hasQualifiedCall(
        in source: String,
        owner: String,
        callee: String
    ) -> Bool {
        let escapedOwner = NSRegularExpression.escapedPattern(for: owner)
        let escapedCallee = NSRegularExpression.escapedPattern(for: callee)
        let pattern = "\\b\(escapedOwner)[ \\t\\r\\n]*\\.[ \\t\\r\\n]*\(escapedCallee)[ \\t\\r\\n]*\\("
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return false }
        let code = lexicalCode(source)
        return expression.firstMatch(
            in: code,
            range: NSRange(code.startIndex..<code.endIndex, in: code)
        ) != nil
    }

    private static func containsRawReaderLexically(
        in source: String,
        referenceScopes: [String]
    ) -> Bool {
        let rawReaders = ["Keychain.string", "Keychain.durableString"]
        if rawReaders.contains(where: { containsIdentifier($0, in: source) }) {
            return true
        }
        let scopedBindings = referenceScopes.flatMap(topLevelReferenceBindings)
        return scopedBindings.contains { binding in
            containsIdentifier(binding.name, in: source)
                && rawReaders.contains(binding.target)
        }
    }

    private static func topLevelReferenceBindings(in region: String) -> [ReferenceBinding] {
        let code = lexicalCode(region)
        guard let openingBrace = code.firstIndex(of: "{"),
              let closingBrace = matchingClosingBrace(in: code, openingBrace: openingBrace)
        else { return [] }

        var depth = 0
        var topLevel = ""
        var cursor = code.index(after: openingBrace)
        while cursor < closingBrace {
            let character = code[cursor]
            if character == "{" {
                depth += 1
                topLevel.append("\n")
            } else if character == "}" {
                depth = max(0, depth - 1)
                topLevel.append("\n")
            } else if depth == 0 {
                topLevel.append(character)
            } else {
                topLevel.append(" ")
            }
            cursor = code.index(after: cursor)
        }
        return referenceBindings(in: topLevel)
    }

    private static func referenceBindings(in source: String) -> [ReferenceBinding] {
        let code = lexicalCode(source)
        let pattern = #"\b(?:let|var)[ \t\r\n]+([A-Za-z_][A-Za-z0-9_]*)[^=\n;{}]*=[ \t\r\n]*([A-Za-z_][A-Za-z0-9_]*(?:[ \t\r\n]*\.[ \t\r\n]*[A-Za-z_][A-Za-z0-9_]*)?)\b"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(code.startIndex..<code.endIndex, in: code)
        return expression.matches(in: code, range: range).compactMap { match in
            guard let nameRange = Range(match.range(at: 1), in: code),
                  let targetRange = Range(match.range(at: 2), in: code) else { return nil }
            return ReferenceBinding(
                name: String(code[nameRange]),
                target: String(code[targetRange]).filter { !isWhitespace($0) }
            )
        }
    }

    private static func containsIdentifier(_ identifier: String, in source: String) -> Bool {
        let components = identifier.split(separator: ".", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty }) else { return false }
        let escaped = components
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: #"[ \t\r\n]*\.[ \t\r\n]*"#)
        guard let expression = try? NSRegularExpression(
            pattern: #"\b\#(escaped)\b"#
        ) else { return false }
        return expression.firstMatch(
            in: lexicalCode(source),
            range: NSRange(source.startIndex..<source.endIndex, in: source)
        ) != nil
    }

    private static func certifiedReadIsGuarded(_ region: String) -> Bool {
        let code = lexicalCode(region)
        guard let readRange = code.range(of: "Keychain.confirmedString(") else { return false }
        let prefix = code[..<readRange.lowerBound]
        guard let guardRange = prefix.range(of: "guard", options: .backwards) else { return false }
        let guardStatement = code[guardRange.lowerBound...]
        guard let openingBrace = guardStatement.firstIndex(of: "{") else { return false }
        let condition = guardStatement[..<openingBrace]
        return condition.contains("Keychain.confirmedString(") && condition.contains("else")
    }

    private static func restoreCompletionDominatesPublication(_ region: String) -> Bool {
        let code = lexicalCode(region)
        let establishmentGuard = "guard establishCredentialOwner(capture) else { return false }"
        guard let guardRange = code.range(of: establishmentGuard) else { return false }
        let prefix = code[..<guardRange.lowerBound]
        let publications = [
            "SourceIndexLifecycleScope.shared.sessionWillMutate()",
            "token = intent.persisted.token",
            "account = intent.persisted.account",
            "dataKey = intent.dataKey",
            "isSignedIn = true",
            "scheduleProviderLegacyMigration("
        ]
        guard publications.allSatisfy({ !prefix.contains($0) }) else { return false }
        return occursInOrder(code, [
            "guard fence.generation == authOperationGeneration",
            "capture.scope == intent.scope",
            "isCurrent(capture) else { return false }",
            establishmentGuard,
            "SourceIndexLifecycleScope.shared.sessionWillMutate()",
            "token = intent.persisted.token",
            "account = intent.persisted.account",
            "dataKey = intent.dataKey",
            "isSignedIn = true",
            "reloadLastSyncStamp()",
            "startRealtime()",
            "return true"
        ])
    }

    private static func restoreCallersPropagateFailure(restore: String, retry: String) -> Bool {
        occursInOrder(restore, [
            "if let boundCapture = bindCredentialOwner(scope),",
            "completeRestoredSession(intent, capture: boundCapture, fence: fence)",
            "return",
            "logCredentialOwnerAcquisitionDenied(",
            "scheduleRestoreCredentialOwnerRetry("
        ]) && occursInOrder(retry, [
            "guard self.credentialOwnerRetryFence == fence else { return }",
            "guard self.completeRestoredSession(",
            "else {",
            "self.finishCredentialOwnerRetry(fence)",
            "return",
            "self.finishCredentialOwnerRetry(fence)"
        ])
    }

    private static func adoptEstablishmentDominatesPublication(_ region: String) -> Bool {
        let code = lexicalCode(region)
        let establishmentGuard = "guard establishCredentialOwner(adoptedCapture) else { return false }"
        guard let guardRange = code.range(of: establishmentGuard) else { return false }
        let prefix = code[..<guardRange.lowerBound]
        let publications = [
            "SourceIndexLifecycleScope.shared.sessionWillMutate()",
            "self.token = token",
            "self.dataKey = dataKey",
            "self.account = candidateAccount",
            "self.isSignedIn = true",
            "reloadLastSyncStamp()",
            "startRealtime()",
            "restoreAccountDocIfNeeded("
        ]
        guard publications.allSatisfy({ !prefix.contains($0) }) else { return false }
        return occursInOrder(code, [
            "let candidateAccount = Account(",
            "guard let adoptedCapture = await acquireCredentialOwner(",
            "fence: operation,",
            "certifying: {",
            "self.persist(token: token, account: candidateAccount, dataKey: dataKey)",
            "guard operation.generation == authOperationGeneration",
            "isCurrent(adoptedCapture) else { return false }",
            establishmentGuard,
            "SourceIndexLifecycleScope.shared.sessionWillMutate()",
            "self.token = token",
            "self.dataKey = dataKey",
            "self.account = candidateAccount",
            "self.isSignedIn = true",
            "reloadLastSyncStamp()",
            "startRealtime()",
            "restoreAccountDocIfNeeded(",
            "return true"
        ])
    }

    private static func allAdoptCallersPropagateFailure(_ source: String) -> Bool {
        let code = lexicalCode(source)
        return occurrenceCount("await adopt(", in: code) == 4
            && occurrenceCount("guard await adopt(", in: code) == 4
    }

    private static func occurrenceCount(_ needle: String, in source: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        return source.components(separatedBy: needle).count - 1
    }

    private static func matchingClosingDelimiter(
        in source: String,
        opening: String.Index,
        openingCharacter: Character,
        closingCharacter: Character
    ) -> String.Index? {
        var depth = 0
        var cursor = opening
        while cursor < source.endIndex {
            let character = source[cursor]
            if character == openingCharacter {
                depth += 1
            } else if character == closingCharacter {
                depth -= 1
                if depth == 0 { return cursor }
                if depth < 0 { return nil }
            }
            cursor = source.index(after: cursor)
        }
        return nil
    }

    private static func matchingClosingBrace(in source: String, openingBrace: String.Index) -> String.Index? {
        var depth = 0
        var cursor = openingBrace
        var blockCommentDepth = 0
        var inLineComment = false
        var inString = false
        var escaped = false

        while cursor < source.endIndex {
            let next = source.index(after: cursor)
            let character = source[cursor]
            let nextCharacter = next < source.endIndex ? source[next] : Character("\0")

            if blockCommentDepth > 0 {
                if character == "/" && nextCharacter == "*" {
                    blockCommentDepth += 1
                    cursor = source.index(after: next)
                } else if character == "*" && nextCharacter == "/" {
                    blockCommentDepth -= 1
                    cursor = source.index(after: next)
                } else {
                    cursor = next
                }
                continue
            }
            if inLineComment {
                inLineComment = character != "\n"
                cursor = next
                continue
            }
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                cursor = next
                continue
            }
            if character == "/" && nextCharacter == "/" {
                inLineComment = true
                cursor = source.index(after: next)
            } else if character == "/" && nextCharacter == "*" {
                blockCommentDepth = 1
                cursor = source.index(after: next)
            } else if character == "\"" {
                inString = true
                cursor = next
            } else if character == "{" {
                depth += 1
                cursor = next
            } else if character == "}" {
                depth -= 1
                if depth == 0 { return cursor }
                cursor = next
            } else {
                cursor = next
            }
        }
        return nil
    }

    private static func occursInOrder(_ source: String, _ snippets: [String]) -> Bool {
        var cursor = source.startIndex
        for snippet in snippets {
            guard let range = source.range(of: snippet, range: cursor..<source.endIndex) else {
                return false
            }
            cursor = range.upperBound
        }
        return true
    }

    private static func firstOccursInOrder(
        _ source: String,
        first: String,
        second: String
    ) -> Bool {
        guard let firstRange = source.range(of: first),
              let secondRange = source.range(of: second) else { return false }
        return firstRange.lowerBound < secondRange.lowerBound
    }

    private static func occursInOrderWithoutIntervening(
        _ source: String,
        first: String,
        second: String,
        forbidden: String
    ) -> Bool {
        guard let firstRange = source.range(of: first),
              let secondRange = source.range(of: second, range: firstRange.upperBound..<source.endIndex)
        else { return false }
        let intervening = source[firstRange.upperBound..<secondRange.lowerBound]
        return !intervening.contains(forbidden)
    }

    private static func isInside(_ child: URL, root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let childPath = child.standardizedFileURL.path
        return childPath == rootPath || childPath.hasPrefix(rootPath + "/")
    }

    private static func canonicalDirectory(_ url: URL) throws -> URL {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: canonical.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw HarnessError.root("\(url.path) is not an existing directory")
        }
        return canonical
    }

    private static func manifestFailureDetail(_ sourceSet: SourceSet) -> String {
        let failures = sourceSet.requiredMissing
            + sourceSet.requiredExternal
            + sourceSet.anchorFailures
            + sourceSet.inventoryExternal
        return failures.isEmpty ? "required source inventory is empty" : failures.joined(separator: "; ")
    }

    private static func compilerFailureDetail(
        _ compiler: (parse: CompilerResult, typecheck: CompilerResult)
    ) -> String {
        let parse = compactCompilerOutput(compiler.parse.output)
        let typecheck = compactCompilerOutput(compiler.typecheck.output)
        return "parse=\(compiler.parse.status), typecheck=\(compiler.typecheck.status)"
            + (parse.isEmpty ? "" : " parse-output=\(parse)")
            + (typecheck.isEmpty ? "" : " typecheck-output=\(typecheck)")
    }

    private static func compactCompilerOutput(_ output: String) -> String {
        let compact = output
            .split(whereSeparator: \.isNewline)
            .prefix(5)
            .joined(separator: " | ")
        if compact.count <= 1200 { return compact }
        return String(compact.prefix(1200)) + "..."
    }

    private static func missingGateIDs(_ evaluation: Evaluation) -> [String] {
        evaluation.gates.filter { !$0.passed }.map(\.id)
    }

    private static func isExpectedRedReceipt(_ evaluation: Evaluation) -> Bool {
        evaluation.inventoryFailures.isEmpty
            && evaluation.gates.filter { $0.id != expectedRedGate }.allSatisfy(\.passed)
            && evaluation.gates.contains { $0.id == expectedRedGate && !$0.passed }
    }

    private static func printReport(_ evaluation: Evaluation) {
        print("GREEN_MANIFEST version=1 root=\(evaluation.root.path)")
        for spec in sourceManifest {
            print("SOURCE \(spec.path)")
        }
        print("GATES_FIXED count=\(fixedGateIDs.count) ids=\(fixedGateIDs.joined(separator: ","))")
        for gate in evaluation.gates {
            print("\(gate.passed ? "PASS" : "FAIL") \(gate.id): \(gate.detail)")
        }
        for failure in evaluation.inventoryFailures {
            print("INVENTORY_FAIL \(failure)")
        }
        if !evaluation.allGreen {
            print("COMPOSITION_RED missing=\(missingGateIDs(evaluation).joined(separator: ","))")
        }
    }

    private static func runSelfTests() throws -> [SelfTest] {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("vortx-credential-green-self-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let validRoot = try makeFixture(base: base, name: "valid")
        let valid = try evaluateFixture(root: validRoot)

        let duplicateRoot = try makeFixture(base: base, name: "duplicate")
        try append(
            "\nenum CredentialMutationResult { case duplicate }\n",
            to: duplicateRoot.appendingPathComponent("app/SourcesShared/Keychain.swift")
        )
        let duplicate = try evaluateFixture(root: duplicateRoot)

        let attributedDuplicateRoot = try makeFixture(base: base, name: "attributed-duplicate")
        try append(
            "\n@available(*, deprecated) enum CredentialMutationResult { case attributedDuplicate }\n",
            to: attributedDuplicateRoot.appendingPathComponent("app/SourcesShared/ApiKeys.swift")
        )
        let attributedDuplicate = try evaluateFixture(root: attributedDuplicateRoot)

        let missingPathRoot = try makeFixture(base: base, name: "missing-path")
        try FileManager.default.removeItem(
            at: missingPathRoot.appendingPathComponent("app/SourcesShared/ApiKeys.swift")
        )
        let missingPath = try evaluateFixture(root: missingPathRoot)

        let missingAnchorRoot = try makeFixture(base: base, name: "missing-anchor")
        try replace(
            "final class CredentialScopeRegistry",
            with: "final class RenamedCredentialScopeRegistry",
            in: missingAnchorRoot.appendingPathComponent("app/SourcesShared/CredentialScope.swift")
        )
        let missingAnchor = try evaluateFixture(root: missingAnchorRoot)

        let compilerRoot = try makeFixture(base: base, name: "compiler-failure")
        try append(
            "\nfunc broken( {\n",
            to: compilerRoot.appendingPathComponent("app/SourcesShared/Keychain.swift")
        )
        let compilerFailure = try evaluateFixture(root: compilerRoot)

        let semanticFailureRoot = try makeFixture(base: base, name: "semantic-failure-outside-keychain")
        try append(
            "\nfunc semanticFailureOutsideKeychain() { let _: Int = \"not-an-int\" }\n",
            to: semanticFailureRoot.appendingPathComponent("app/SourcesShared/ApiKeys.swift")
        )
        let semanticFailure = try evaluateFixture(root: semanticFailureRoot)

        let durableReorderedRoot = try makeFixture(base: base, name: "durable-reordered")
        try replace(
            """
                    for _ in 0..<2 {
                        result = Keychain.set(storedValue, for: account)
                        if result == CredentialMutationResult.success { break }
                    }
                    guard result == .success else {
            """,
            with: """
                    for _ in 0..<2 {
                        result = Keychain.set(storedValue, for: account)
                        guard result == .success else { return }
                        if result == CredentialMutationResult.success { break }
                    }
                    guard result == .success else {
            """,
            in: durableReorderedRoot.appendingPathComponent("app/SourcesShared/ApiKeys.swift")
        )
        let durableReordered = try evaluateFixture(root: durableReorderedRoot)

        let durableAliasRoot = try makeFixture(base: base, name: "durable-alias")
        try replace(
            "result = Keychain.set(storedValue, for: account)",
            with: "let writer: (String?, String) -> CredentialMutationResult = Keychain.set\n                        result = writer(storedValue, account)",
            in: durableAliasRoot.appendingPathComponent("app/SourcesShared/ApiKeys.swift")
        )
        let durableAlias = try evaluateFixture(root: durableAliasRoot)

        let ownerAliasRoot = try makeFixture(base: base, name: "owner-alias")
        try replace(
            "CredentialScopeRegistry.shared.isCurrent(capture) else { return }",
            with: "let current = CredentialScopeRegistry.shared.isCurrent\n                          guard current(capture) else { return }",
            in: ownerAliasRoot.appendingPathComponent("app/SourcesShared/DebridKeys.swift")
        )
        let ownerAlias = try evaluateFixture(root: ownerAliasRoot)

        let migrationReorderedRoot = try makeFixture(base: base, name: "migration-reordered")
        try replace(
            """
                    guard capture.scope == owner,
                          CredentialScopeRegistry.shared.isMigrationEligible(capture) else { return .noSource }
                    let primary = CredentialLegacyClaim.claimGlobalSlotSet(
            """,
            with: """
                    guard capture.scope == owner else { return .noSource }
                    let primary = CredentialLegacyClaim.claimGlobalSlotSet(
                        slots: [(\"source\", \"destination\")],
                        claimMarkerAccount: \"marker\",
                        ownerNamespace: \"owner\",
                        read: Keychain.string,
                        write: { value, account in _ = Keychain.set(value, for: account) },
                        provenanceTag: \"trakt\")
                    guard CredentialScopeRegistry.shared.isMigrationEligible(capture) else { return .noSource }
                    let unreachable = primary
                    _ = unreachable
                    if false { return .noSource }
                    let primaryAgain = primary
                    _ = primaryAgain
                    let _ = CredentialLegacyClaim.claimGlobalSlotSet(
            """,
            in: migrationReorderedRoot.appendingPathComponent("app/SourcesShared/TraktAuth.swift")
        )
        let migrationReordered = try evaluateFixture(root: migrationReorderedRoot)

        let migrationAliasRoot = try makeFixture(base: base, name: "migration-alias")
        try replace(
            "read: Keychain.string,",
            with: "read: legacyRead,",
            in: migrationAliasRoot.appendingPathComponent("app/SourcesShared/TraktAuth.swift")
        )
        try append(
            "\nprivate func legacyRead(_ account: String) -> String? { Keychain.string(account) }\n",
            to: migrationAliasRoot.appendingPathComponent("app/SourcesShared/TraktAuth.swift")
        )
        let migrationAlias = try evaluateFixture(root: migrationAliasRoot)

        let recoveryDirectAliasRoot = try makeFixture(base: base, name: "recovery-direct-raw-alias")
        try replace(
            "guard case .missing = Keychain.confirmedString(\"session\") else { return }",
            with: "let reader: (String) -> String? = Keychain.string\n                    guard case .missing = Keychain.confirmedString(\"session\") else { return }\n                    _ = reader(\"session\")",
            in: recoveryDirectAliasRoot.appendingPathComponent("app/SourcesShared/VortXSyncManager.swift")
        )
        let recoveryDirectAlias = try evaluateFixture(root: recoveryDirectAliasRoot)

        let recoveryScopedAliasRoot = try makeFixture(base: base, name: "recovery-scoped-raw-alias")
        try replace(
            "private func restore()",
            with: "private let recoveryReader: (String) -> String? = Keychain.string\n\n                private func restore()",
            in: recoveryScopedAliasRoot.appendingPathComponent("app/SourcesShared/VortXSyncManager.swift")
        )
        try replace(
            "guard case .missing = Keychain.confirmedString(\"session\") else { return }",
            with: "guard case .missing = Keychain.confirmedString(\"session\") else { return }\n                    _ = recoveryReader(\"session\")",
            in: recoveryScopedAliasRoot.appendingPathComponent("app/SourcesShared/VortXSyncManager.swift")
        )
        let recoveryScopedAlias = try evaluateFixture(root: recoveryScopedAliasRoot)

        let recoveryIndirectRoot = try makeFixture(base: base, name: "recovery-indirect-raw")
        try replace(
            "guard case .missing = Keychain.confirmedString(\"session\") else { return }",
            with: "guard case .missing = Keychain.confirmedString(\"session\") else { return }\n                    _ = readRecovery(\"session\")",
            in: recoveryIndirectRoot.appendingPathComponent("app/SourcesShared/VortXSyncManager.swift")
        )
        try append(
            """

            private func readRecovery(_ account: String) -> CredentialDurableReadResult {
                let reader: (String) -> String? = Keychain.string
                return reader(account).map { .value($0) } ?? .missing
            }
            """,
            to: recoveryIndirectRoot.appendingPathComponent("app/SourcesShared/VortXSyncManager.swift")
        )
        let recoveryIndirect = try evaluateFixture(root: recoveryIndirectRoot)

        let recoveryElsewhereRoot = try makeFixture(base: base, name: "recovery-certified-elsewhere")
        try replace(
            "Keychain.confirmedString(\"session\")",
            with: "Keychain.string(\"session\")",
            in: recoveryElsewhereRoot.appendingPathComponent("app/SourcesShared/VortXSyncManager.swift")
        )
        try append(
            "\nprivate func certifiedReadElsewhere(_ account: String) -> CredentialDurableReadResult { Keychain.confirmedString(account) }\n",
            to: recoveryElsewhereRoot.appendingPathComponent("app/SourcesShared/VortXSyncManager.swift")
        )
        let recoveryElsewhere = try evaluateFixture(root: recoveryElsewhereRoot)

        let recoveryDurableRoot = try makeFixture(base: base, name: "recovery-durable-raw")
        try replace(
            "Keychain.confirmedString(\"session\")",
            with: "Keychain.durableString(\"session\")",
            in: recoveryDurableRoot.appendingPathComponent("app/SourcesShared/VortXSyncManager.swift")
        )
        let recoveryDurable = try evaluateFixture(root: recoveryDurableRoot)

        let recoveryReorderedRoot = try makeFixture(base: base, name: "recovery-reordered")
        try replace(
            """
                    guard case .missing = Keychain.confirmedString(\"session\") else { return }
                    let scope: CredentialScope = .signedOutDevice
                    let capture = bindCredentialOwner(scope)
            """,
            with: """
                    let scope: CredentialScope = .signedOutDevice
                    let capture = bindCredentialOwner(scope)
                    guard case .missing = Keychain.confirmedString(\"session\") else { return }
            """,
            in: recoveryReorderedRoot.appendingPathComponent("app/SourcesShared/VortXSyncManager.swift")
        )
        let recoveryReordered = try evaluateFixture(root: recoveryReorderedRoot)

        let recoveryUnguardedRoot = try makeFixture(base: base, name: "recovery-unguarded")
        try replace(
            "guard case .missing = Keychain.confirmedString(\"session\") else { return }",
            with: "let recovered = Keychain.confirmedString(\"session\")\n                    guard case .missing = recovered else { return }",
            in: recoveryUnguardedRoot.appendingPathComponent("app/SourcesShared/VortXSyncManager.swift")
        )
        let recoveryUnguarded = try evaluateFixture(root: recoveryUnguardedRoot)

        let recoveryPostBindRoot = try makeFixture(base: base, name: "recovery-post-bind-raw")
        try replace(
            "guard establishCredentialOwner(capture) else { return }",
            with: "_ = postBindRawRecovery(\"session\")\n                    guard establishCredentialOwner(capture) else { return }",
            in: recoveryPostBindRoot.appendingPathComponent("app/SourcesShared/VortXSyncManager.swift")
        )
        try append(
            "\nprivate func postBindRawRecovery(_ account: String) -> String? { Keychain.string(account) }\n",
            to: recoveryPostBindRoot.appendingPathComponent("app/SourcesShared/VortXSyncManager.swift")
        )
        let recoveryPostBind = try evaluateFixture(root: recoveryPostBindRoot)

        let recoveryAuthenticatedMigrationRoot = try makeFixture(
            base: base,
            name: "recovery-authenticated-migration-raw"
        )
        try replace(
            """
                    guard capture.scope == owner,
                          CredentialScopeRegistry.shared.isMigrationEligible(capture) else { return .noSource }
                    let primary = CredentialLegacyClaim.claimGlobalSlotSet(
            """,
            with: """
                    guard capture.scope == owner,
                          CredentialScopeRegistry.shared.isMigrationEligible(capture) else { return .noSource }
                    let reader: (String) -> String? = Keychain.string
                    _ = reader("authenticated-migration")
                    let primary = CredentialLegacyClaim.claimGlobalSlotSet(
            """,
            in: recoveryAuthenticatedMigrationRoot.appendingPathComponent("app/SourcesShared/TraktAuth.swift")
        )
        let recoveryAuthenticatedMigration = try evaluateFixture(root: recoveryAuthenticatedMigrationRoot)

        let recoveryBoundCaptureRoot = try makeFixture(base: base, name: "recovery-bound-capture")
        try replace(
            """
                    let scope: CredentialScope = .signedOutDevice
                    let capture = bindCredentialOwner(scope)
                    guard establishCredentialOwner(capture) else { return }
            """,
            with: """
                    let scope: CredentialScope = .signedOutDevice
                    let boundCapture = bindCredentialOwner(scope)
                    guard establishCredentialOwner(
                        boundCapture
                    ) else { return }
            """,
            in: recoveryBoundCaptureRoot.appendingPathComponent("app/SourcesShared/VortXSyncManager.swift")
        )
        let recoveryBoundCapture = try evaluateFixture(root: recoveryBoundCaptureRoot)

        let recoveryBoundCaptureRawRoot = try makeFixture(
            base: base,
            name: "recovery-bound-capture-pre-auth-raw"
        )
        try replace(
            """
                    let scope: CredentialScope = .signedOutDevice
                    let capture = bindCredentialOwner(scope)
                    guard establishCredentialOwner(capture) else { return }
            """,
            with: """
                    let scope: CredentialScope = .signedOutDevice
                    let boundCapture = bindCredentialOwner(scope)
                    let reader: (String) -> String? = Keychain.string
                    _ = reader("before-authentication")
                    guard establishCredentialOwner(
                        boundCapture
                    ) else { return }
            """,
            in: recoveryBoundCaptureRawRoot.appendingPathComponent("app/SourcesShared/VortXSyncManager.swift")
        )
        let recoveryBoundCaptureRaw = try evaluateFixture(root: recoveryBoundCaptureRawRoot)

        let decoyCallSource = """
        private func restore() {
            // establishCredentialOwner(capture)
            let text = "establishCredentialOwner(capture)"
            let similarlyNamed = establishCredentialOwnerExtra(boundCapture)
            _ = similarlyNamed
        }
        """
        let decoyCallIsIgnored = callExpressionRange(
            in: decoyCallSource,
            callee: "establishCredentialOwner"
        ) == nil

        let realCertifiedRoot = try makeRealRootFixture(base: base, name: "real-root-certified-restore")
        let realCertified = try evaluate(root: realCertifiedRoot)

        let transportCompilerFailureRoot = try makeRealRootFixture(
            base: base,
            name: "real-root-transport-compiler-failure"
        )
        try append(
            """

            extension AuthenticatedHTTPTransport {
                private func transportCompilerFailure() {
                    let _: Int = "typecheck-only failure"
                }
            }
            """,
            to: transportCompilerFailureRoot.appendingPathComponent(
                "app/SourcesShared/AuthenticatedHTTPTransport.swift"
            )
        )
        let transportCompilerFailure = try evaluate(root: transportCompilerFailureRoot)

        let ownerCollisionRoot = try makeRealRootFixture(
            base: base,
            name: "real-root-unrelated-owner-collision"
        )
        try append(
            """

            extension AuthenticatedHTTPTransport {
                fileprivate func establishCredentialOwner(
                    _ capture: CredentialScopeRegistry.Capture
                ) -> Bool {
                    _ = capture
                    _ = Keychain.string("unrelated-owner")
                    return true
                }
            }
            """,
            to: ownerCollisionRoot.appendingPathComponent(
                "app/SourcesShared/AuthenticatedHTTPTransport.swift"
            )
        )
        let ownerCollision = try evaluate(root: ownerCollisionRoot)

        let sameOwnerRawReaderRoot = try makeRealRootFixture(
            base: base,
            name: "real-root-same-owner-reachable-raw-reader"
        )
        try replace(
            "guard establishCredentialOwner(capture) else { return false }",
            with: "_ = sameOwnerRawRecovery(\"same-owner\")\n        guard establishCredentialOwner(capture) else { return false }",
            in: sameOwnerRawReaderRoot.appendingPathComponent(
                "app/SourcesShared/VortXSyncManager.swift"
            )
        )
        try append(
            """

            extension VortXSyncManager {
                fileprivate func sameOwnerRawRecovery(_ account: String) -> String? {
                    Keychain.string(account)
                }
            }
            """,
            to: sameOwnerRawReaderRoot.appendingPathComponent(
                "app/SourcesShared/VortXSyncManager.swift"
            )
        )
        let sameOwnerRawReader = try evaluate(root: sameOwnerRawReaderRoot)

        let realRawStoredSessionRoot = try makeRealRootFixture(
            base: base,
            name: "real-root-raw-stored-session"
        )
        try replace(
            """
                    let capture = authority.capture()
                    let namespace = capture.namespace
            """,
            with: """
                    let capture = authority.capture()
                    _ = Keychain.string(TraktTokenSlots.session(capture.namespace))
                    let namespace = capture.namespace
            """,
            in: realRawStoredSessionRoot.appendingPathComponent("app/SourcesShared/TraktAuth.swift")
        )
        let realRawStoredSession = try evaluate(root: realRawStoredSessionRoot)

        let realAliasedStoredSessionRoot = try makeRealRootFixture(
            base: base,
            name: "real-root-aliased-stored-session"
        )
        try replace(
            "let capture = authority.capture()",
            with: """
                    let capture = authority.capture()
                    let hostileReader: (String) -> String? = Keychain.string
                    _ = hostileReader(TraktTokenSlots.session(capture.namespace))
            """,
            in: realAliasedStoredSessionRoot.appendingPathComponent("app/SourcesShared/TraktAuth.swift")
        )
        let realAliasedStoredSession = try evaluate(root: realAliasedStoredSessionRoot)

        let realHelperStoredSessionRoot = try makeRealRootFixture(
            base: base,
            name: "real-root-helper-stored-session"
        )
        try replace(
            "let capture = authority.capture()",
            with: """
                    let capture = authority.capture()
                    _ = hostileStoredSessionRead(TraktTokenSlots.session(capture.namespace))
            """,
            in: realHelperStoredSessionRoot.appendingPathComponent("app/SourcesShared/TraktAuth.swift")
        )
        try append(
            """

            private func hostileStoredSessionRead(_ account: String) -> String? {
                Keychain.string(account)
            }
            """,
            to: realHelperStoredSessionRoot.appendingPathComponent("app/SourcesShared/TraktAuth.swift")
        )
        let realHelperStoredSession = try evaluate(root: realHelperStoredSessionRoot)

        let realSplitStoredSessionRoot = try makeRealRootFixture(
            base: base,
            name: "real-root-split-stored-session"
        )
        try replace(
            "let capture = authority.capture()",
            with: """
                    let capture = authority.capture()
                    _ = Keychain /* hostile split */ .string(
                        TraktTokenSlots.session(capture.namespace)
                    )
            """,
            in: realSplitStoredSessionRoot.appendingPathComponent("app/SourcesShared/TraktAuth.swift")
        )
        let realSplitStoredSession = try evaluate(root: realSplitStoredSessionRoot)

        let realRawDurableStoredSessionRoot = try makeRealRootFixture(
            base: base,
            name: "real-root-raw-durable-stored-session"
        )
        try replace(
            "let capture = authority.capture()",
            with: """
                    let capture = authority.capture()
                    _ = Keychain.durableString(TraktTokenSlots.session(capture.namespace))
            """,
            in: realRawDurableStoredSessionRoot.appendingPathComponent("app/SourcesShared/TraktAuth.swift")
        )
        let realRawDurableStoredSession = try evaluate(root: realRawDurableStoredSessionRoot)

        let realAliasedDurableStoredSessionRoot = try makeRealRootFixture(
            base: base,
            name: "real-root-aliased-durable-stored-session"
        )
        try replace(
            "let capture = authority.capture()",
            with: """
                    let capture = authority.capture()
                    let hostileReader: (String) -> CredentialDurableReadResult = Keychain.durableString
                    _ = hostileReader(TraktTokenSlots.session(capture.namespace))
            """,
            in: realAliasedDurableStoredSessionRoot.appendingPathComponent(
                "app/SourcesShared/TraktAuth.swift"
            )
        )
        let realAliasedDurableStoredSession = try evaluate(root: realAliasedDurableStoredSessionRoot)

        let realHelperDurableStoredSessionRoot = try makeRealRootFixture(
            base: base,
            name: "real-root-helper-durable-stored-session"
        )
        try replace(
            "let capture = authority.capture()",
            with: """
                    let capture = authority.capture()
                    _ = hostileDurableStoredSessionRead(TraktTokenSlots.session(capture.namespace))
            """,
            in: realHelperDurableStoredSessionRoot.appendingPathComponent(
                "app/SourcesShared/TraktAuth.swift"
            )
        )
        try append(
            """

            private func hostileDurableStoredSessionRead(
                _ account: String
            ) -> CredentialDurableReadResult {
                Keychain.durableString(account)
            }
            """,
            to: realHelperDurableStoredSessionRoot.appendingPathComponent(
                "app/SourcesShared/TraktAuth.swift"
            )
        )
        let realHelperDurableStoredSession = try evaluate(root: realHelperDurableStoredSessionRoot)

        let realSplitDurableStoredSessionRoot = try makeRealRootFixture(
            base: base,
            name: "real-root-split-durable-stored-session"
        )
        try replace(
            "let capture = authority.capture()",
            with: """
                    let capture = authority.capture()
                    _ = Keychain /* hostile split */ .durableString(
                        TraktTokenSlots.session(capture.namespace)
                    )
            """,
            in: realSplitDurableStoredSessionRoot.appendingPathComponent(
                "app/SourcesShared/TraktAuth.swift"
            )
        )
        let realSplitDurableStoredSession = try evaluate(root: realSplitDurableStoredSessionRoot)

        let realRawTraktMigrationRoot = try makeRealRootFixture(
            base: base,
            name: "real-root-raw-trakt-migration"
        )
        try replace(
            """
                    let ns = owner.storageNamespace
                    let primary = CredentialLegacyClaim.claimGlobalSlotSet(
            """,
            with: """
                    let ns = owner.storageNamespace
                    _ = Keychain.string(legacyAccess)
                    let primary = CredentialLegacyClaim.claimGlobalSlotSet(
            """,
            in: realRawTraktMigrationRoot.appendingPathComponent("app/SourcesShared/TraktAuth.swift")
        )
        let realRawTraktMigration = try evaluate(root: realRawTraktMigrationRoot)

        let realRawDurableTraktMigrationRoot = try makeRealRootFixture(
            base: base,
            name: "real-root-raw-durable-trakt-migration"
        )
        try replace(
            "let ns = owner.storageNamespace",
            with: """
                    let ns = owner.storageNamespace
                    _ = Keychain.durableString(legacyAccess)
            """,
            in: realRawDurableTraktMigrationRoot.appendingPathComponent(
                "app/SourcesShared/TraktAuth.swift"
            )
        )
        let realRawDurableTraktMigration = try evaluate(root: realRawDurableTraktMigrationRoot)

        let realRelocatedDurableTraktMigrationRoot = try makeRealRootFixture(
            base: base,
            name: "real-root-relocated-durable-trakt-migration"
        )
        try replace(
            """
                    let ns = owner.storageNamespace
                    let primary = CredentialLegacyClaim.claimGlobalSlotSet(
            """,
            with: """
                    let ns = owner.storageNamespace
                    DurableReadSink.consume(sourceRead: Keychain.durableString)
                    let primary = CredentialLegacyClaim.claimGlobalSlotSet(
            """,
            in: realRelocatedDurableTraktMigrationRoot.appendingPathComponent(
                "app/SourcesShared/TraktAuth.swift"
            )
        )
        try replace(
            "sourceRead: Keychain.durableString,\n            provenanceTag: \"trakt-token-set\"",
            with: "sourceRead: Keychain.confirmedString,\n            provenanceTag: \"trakt-token-set\"",
            in: realRelocatedDurableTraktMigrationRoot.appendingPathComponent(
                "app/SourcesShared/TraktAuth.swift"
            )
        )
        try append(
            """

            private enum DurableReadSink {
                static func consume(
                    sourceRead: (String) -> CredentialDurableReadResult
                ) {
                    _ = sourceRead
                }
            }
            """,
            to: realRelocatedDurableTraktMigrationRoot.appendingPathComponent(
                "app/SourcesShared/TraktAuth.swift"
            )
        )
        let realRelocatedDurableTraktMigration = try evaluate(
            root: realRelocatedDurableTraktMigrationRoot
        )

        let realCommentDecoyTraktMigrationRoot = try makeRealRootFixture(
            base: base,
            name: "real-root-comment-decoy-trakt-migration"
        )
        try replace(
            """
                    let ns = owner.storageNamespace
                    let primary = CredentialLegacyClaim.claimGlobalSlotSet(
            """,
            with: """
                    let ns = owner.storageNamespace
                    _ = CredentialLegacyClaim.claimGlobalSlotSet(
                        slots: [
                            // (legacyAccess, access(ns))
                            // (legacyRefresh, refresh(ns))
                            // (legacyExpiry, expiry(ns))
                        ],
                        claimMarkerAccount: claimMarker + ".decoy",
                        ownerNamespace: ns,
                        write: { value, account in Keychain.set(value, for: account) },
                        durableRead: Keychain.confirmedString,
                        sourceRead: Keychain.durableString,
                        // provenanceTag: "trakt-token-set"
                        provenanceTag: "decoy"
                    )
                    let primary = CredentialLegacyClaim.claimGlobalSlotSet(
            """,
            in: realCommentDecoyTraktMigrationRoot.appendingPathComponent(
                "app/SourcesShared/TraktAuth.swift"
            )
        )
        try replace(
            "(legacyAccess, access(ns)),",
            with: "(legacyRefresh, access(ns)),",
            in: realCommentDecoyTraktMigrationRoot.appendingPathComponent(
                "app/SourcesShared/TraktAuth.swift"
            )
        )
        try replace(
            "sourceRead: Keychain.durableString,\n            provenanceTag: \"trakt-token-set\"",
            with: "sourceRead: Keychain.confirmedString,\n            provenanceTag: \"hostile-primary\"",
            in: realCommentDecoyTraktMigrationRoot.appendingPathComponent(
                "app/SourcesShared/TraktAuth.swift"
            )
        )
        let realCommentDecoyTraktMigration = try evaluate(
            root: realCommentDecoyTraktMigrationRoot
        )

        let realCopiedValidPrimaryDecoyRoot = try makeRealRootFixture(
            base: base,
            name: "real-root-copied-valid-primary-decoy"
        )
        let realCopiedValidPrimaryDecoyTrakt = realCopiedValidPrimaryDecoyRoot.appendingPathComponent(
            "app/SourcesShared/TraktAuth.swift"
        )
        try replace(
            "sourceRead: Keychain.durableString,\n            provenanceTag: \"trakt-token-set\"",
            with: "sourceRead: Keychain.confirmedString,\n            provenanceTag: \"trakt-token-set\"",
            in: realCopiedValidPrimaryDecoyTrakt
        )
        try replace(
            """
                    let ns = owner.storageNamespace
                    let primary = CredentialLegacyClaim.claimGlobalSlotSet(
            """,
            with: """
                    let ns = owner.storageNamespace
                    let copiedPrimaryDecoy = CredentialLegacyClaim.claimGlobalSlotSet(
                        slots: [
                            (legacyAccess, access(ns)),
                            (legacyRefresh, refresh(ns)),
                            (legacyExpiry, expiry(ns)),
                        ],
                        claimMarkerAccount: claimMarker + ".copiedPrimaryDecoy",
                        ownerNamespace: ns,
                        write: { value, account in Keychain.set(value, for: account) },
                        durableRead: Keychain.confirmedString,
                        sourceRead: Keychain.durableString,
                        provenanceTag: "trakt-token-set"
                    )
                    _ = copiedPrimaryDecoy
                    let primary = CredentialLegacyClaim.claimGlobalSlotSet(
            """,
            in: realCopiedValidPrimaryDecoyTrakt
        )
        let realCopiedValidPrimaryDecoy = try evaluate(root: realCopiedValidPrimaryDecoyRoot)

        let realNestedPrimarySourceReadRoot = try makeRealRootFixture(
            base: base,
            name: "real-root-nested-primary-source-read"
        )
        try replace(
            """
                        write: { value, account in Keychain.set(value, for: account) },
                        durableRead: Keychain.confirmedString,
                        sourceRead: Keychain.durableString,
                        provenanceTag: "trakt-token-set"
            """,
            with: """
                        write: { value, account in
                            DurableReadSink.consume(sourceRead: Keychain.durableString)
                            // sourceRead: Keychain.durableString
                            return Keychain.set(value, for: account)
                        },
                        durableRead: Keychain.confirmedString,
                        sourceRead: Keychain.confirmedString,
                        provenanceTag: "trakt-token-set"
            """,
            in: realNestedPrimarySourceReadRoot.appendingPathComponent(
                "app/SourcesShared/TraktAuth.swift"
            )
        )
        try append(
            """

            private enum DurableReadSink {
                static func consume(
                    sourceRead: (String) -> CredentialDurableReadResult
                ) {
                    _ = sourceRead
                }
            }
            """,
            to: realNestedPrimarySourceReadRoot.appendingPathComponent(
                "app/SourcesShared/TraktAuth.swift"
            )
        )
        let realNestedPrimarySourceRead = try evaluate(root: realNestedPrimarySourceReadRoot)

        let realNestedCreatedAtSourceReadRoot = try makeRealRootFixture(
            base: base,
            name: "real-root-nested-created-at-source-read"
        )
        try replace(
            """
                        claimMarkerAccount: claimMarker + ".createdAt",
                        ownerNamespace: ns,
                        write: { value, account in Keychain.set(value, for: account) },
                        durableRead: Keychain.confirmedString,
                        sourceRead: Keychain.durableString,
                        provenanceTag: "trakt-created-at"
            """,
            with: """
                        claimMarkerAccount: claimMarker + ".createdAt",
                        ownerNamespace: ns,
                        write: { value, account in
                            DurableReadSink.consume(sourceRead: Keychain.durableString)
                            // sourceRead: Keychain.durableString
                            return Keychain.set(value, for: account)
                        },
                        durableRead: Keychain.confirmedString,
                        sourceRead: Keychain.confirmedString,
                        provenanceTag: "trakt-created-at"
            """,
            in: realNestedCreatedAtSourceReadRoot.appendingPathComponent(
                "app/SourcesShared/TraktAuth.swift"
            )
        )
        try append(
            """

            private enum DurableReadSink {
                static func consume(
                    sourceRead: (String) -> CredentialDurableReadResult
                ) {
                    _ = sourceRead
                }
            }
            """,
            to: realNestedCreatedAtSourceReadRoot.appendingPathComponent(
                "app/SourcesShared/TraktAuth.swift"
            )
        )
        let realNestedCreatedAtSourceRead = try evaluate(root: realNestedCreatedAtSourceReadRoot)

        let realNestedSessionSourceReadRoot = try makeRealRootFixture(
            base: base,
            name: "real-root-nested-session-source-read"
        )
        try replace(
            """
                        claimMarkerAccount: claimMarker + ".session",
                        ownerNamespace: ns,
                        write: { value, account in Keychain.set(value, for: account) },
                        durableRead: Keychain.confirmedString,
                        sourceRead: Keychain.durableString,
                        provenanceTag: "trakt-session"
            """,
            with: """
                        claimMarkerAccount: claimMarker + ".session",
                        ownerNamespace: ns,
                        write: { value, account in
                            DurableReadSink.consume(sourceRead: Keychain.durableString)
                            // sourceRead: Keychain.durableString
                            return Keychain.set(value, for: account)
                        },
                        durableRead: Keychain.confirmedString,
                        sourceRead: Keychain.confirmedString,
                        provenanceTag: "trakt-session"
            """,
            in: realNestedSessionSourceReadRoot.appendingPathComponent(
                "app/SourcesShared/TraktAuth.swift"
            )
        )
        try append(
            """

            private enum DurableReadSink {
                static func consume(
                    sourceRead: (String) -> CredentialDurableReadResult
                ) {
                    _ = sourceRead
                }
            }
            """,
            to: realNestedSessionSourceReadRoot.appendingPathComponent(
                "app/SourcesShared/TraktAuth.swift"
            )
        )
        let realNestedSessionSourceRead = try evaluate(root: realNestedSessionSourceReadRoot)

        let realAliasedTraktMigrationRoot = try makeRealRootFixture(
            base: base,
            name: "real-root-aliased-trakt-migration"
        )
        try replace(
            "let ns = owner.storageNamespace",
            with: """
                    let ns = owner.storageNamespace
                    let hostileReader: (String) -> String? = Keychain.string
                    _ = hostileReader(legacyAccess)
            """,
            in: realAliasedTraktMigrationRoot.appendingPathComponent("app/SourcesShared/TraktAuth.swift")
        )
        let realAliasedTraktMigration = try evaluate(root: realAliasedTraktMigrationRoot)

        let realHelperTraktMigrationRoot = try makeRealRootFixture(
            base: base,
            name: "real-root-helper-trakt-migration"
        )
        try replace(
            "let ns = owner.storageNamespace",
            with: """
                    let ns = owner.storageNamespace
                    _ = hostileTraktMigrationRead(legacyAccess)
            """,
            in: realHelperTraktMigrationRoot.appendingPathComponent("app/SourcesShared/TraktAuth.swift")
        )
        try append(
            """

            private func hostileTraktMigrationRead(_ account: String) -> String? {
                Keychain.string(account)
            }
            """,
            to: realHelperTraktMigrationRoot.appendingPathComponent("app/SourcesShared/TraktAuth.swift")
        )
        let realHelperTraktMigration = try evaluate(root: realHelperTraktMigrationRoot)

        let realSplitTraktMigrationRoot = try makeRealRootFixture(
            base: base,
            name: "real-root-split-trakt-migration"
        )
        try replace(
            "let ns = owner.storageNamespace",
            with: """
                    let ns = owner.storageNamespace
                    _ = Keychain /* hostile split */ .string(legacyAccess)
            """,
            in: realSplitTraktMigrationRoot.appendingPathComponent("app/SourcesShared/TraktAuth.swift")
        )
        let realSplitTraktMigration = try evaluate(root: realSplitTraktMigrationRoot)

        let realIgnoredRestoreEstablishmentRoot = try makeRealRootFixture(
            base: base,
            name: "real-root-ignored-restore-establishment"
        )
        try replace(
            "guard establishCredentialOwner(capture) else { return false }",
            with: "_ = establishCredentialOwner(capture)",
            in: realIgnoredRestoreEstablishmentRoot.appendingPathComponent(
                "app/SourcesShared/VortXSyncManager.swift"
            )
        )
        let realIgnoredRestoreEstablishment = try evaluate(root: realIgnoredRestoreEstablishmentRoot)

        let realLateRestoreEstablishmentRoot = try makeRealRootFixture(
            base: base,
            name: "real-root-late-restore-establishment"
        )
        try replace(
            """
                    guard establishCredentialOwner(capture) else { return false }
                    SourceIndexLifecycleScope.shared.sessionWillMutate()
            """,
            with: """
                    SourceIndexLifecycleScope.shared.sessionWillMutate()
                    guard establishCredentialOwner(capture) else { return false }
            """,
            in: realLateRestoreEstablishmentRoot.appendingPathComponent(
                "app/SourcesShared/VortXSyncManager.swift"
            )
        )
        let realLateRestoreEstablishment = try evaluate(root: realLateRestoreEstablishmentRoot)

        let realIgnoredAdoptEstablishmentRoot = try makeRealRootFixture(
            base: base,
            name: "real-root-ignored-adopt-establishment"
        )
        try replace(
            "guard establishCredentialOwner(adoptedCapture) else { return false }",
            with: "_ = establishCredentialOwner(adoptedCapture)",
            in: realIgnoredAdoptEstablishmentRoot.appendingPathComponent(
                "app/SourcesShared/VortXSyncManager.swift"
            )
        )
        let realIgnoredAdoptEstablishment = try evaluate(root: realIgnoredAdoptEstablishmentRoot)

        let realLateAdoptEstablishmentRoot = try makeRealRootFixture(
            base: base,
            name: "real-root-late-adopt-establishment"
        )
        try replace(
            """
                    guard establishCredentialOwner(adoptedCapture) else { return false }
                    SourceIndexLifecycleScope.shared.sessionWillMutate()
            """,
            with: """
                    SourceIndexLifecycleScope.shared.sessionWillMutate()
                    guard establishCredentialOwner(adoptedCapture) else { return false }
            """,
            in: realLateAdoptEstablishmentRoot.appendingPathComponent(
                "app/SourcesShared/VortXSyncManager.swift"
            )
        )
        let realLateAdoptEstablishment = try evaluate(root: realLateAdoptEstablishmentRoot)

        let realAdoptWithoutCertificationRoot = try makeRealRootFixture(
            base: base,
            name: "real-root-adopt-without-certification"
        )
        try replace(
            """
                        fence: operation,
                        certifying: {
                            self.persist(token: token, account: candidateAccount, dataKey: dataKey)
                        }
            """,
            with: """
                        fence: operation
            """,
            in: realAdoptWithoutCertificationRoot.appendingPathComponent(
                "app/SourcesShared/VortXSyncManager.swift"
            )
        )
        let realAdoptWithoutCertification = try evaluate(root: realAdoptWithoutCertificationRoot)

        let realAdoptNilAccountPublicationRoot = try makeRealRootFixture(
            base: base,
            name: "real-root-adopt-nil-account-publication"
        )
        try replace(
            "self.account = candidateAccount",
            with: "self.account = nil",
            in: realAdoptNilAccountPublicationRoot.appendingPathComponent(
                "app/SourcesShared/VortXSyncManager.swift"
            )
        )
        let realAdoptNilAccountPublication = try evaluate(root: realAdoptNilAccountPublicationRoot)

        let guardedCompletionSource = """
        private func completeRestoredSession(
            _ intent: RestoredSessionIntent,
            capture: CredentialScopeRegistry.Capture,
            fence: AuthOperationCapture
        ) -> Bool {
            guard fence.generation == authOperationGeneration,
                  capture.scope == intent.scope,
                  isCurrent(capture) else { return false }
            guard establishCredentialOwner(capture) else { return false }
            SourceIndexLifecycleScope.shared.sessionWillMutate()
            token = intent.persisted.token
            account = intent.persisted.account
            dataKey = intent.dataKey
            isSignedIn = true
            reloadLastSyncStamp()
            Task { startRealtime() }
            return true
        }
        """
        let ignoredEstablishmentCompletion = guardedCompletionSource.replacingOccurrences(
            of: "guard establishCredentialOwner(capture) else { return false }",
            with: "_ = establishCredentialOwner(capture)"
        )
        let lateEstablishmentCompletion = guardedCompletionSource.replacingOccurrences(
            of: "guard establishCredentialOwner(capture) else { return false }\n    SourceIndexLifecycleScope.shared.sessionWillMutate()",
            with: "SourceIndexLifecycleScope.shared.sessionWillMutate()\n    guard establishCredentialOwner(capture) else { return false }"
        )
        let guardedCallersSource = """
        private func scheduleRestoreCredentialOwnerRetry(
            _ intent: RestoredSessionIntent,
            fence: AuthOperationCapture,
            startingAt firstAttempt: Int
        ) {
            guard self.credentialOwnerRetryFence == fence else { return }
            guard self.completeRestoredSession(intent, capture: capture, fence: fence) else {
                self.finishCredentialOwnerRetry(fence)
                return
            }
            self.finishCredentialOwnerRetry(fence)
        }

        private func restore() {
            switch Keychain.confirmedString(kcAccount) {
            case .failure: return
            case .missing: return
            case let .value(value): persisted = value
            }
            if let boundCapture = bindCredentialOwner(scope),
               completeRestoredSession(intent, capture: boundCapture, fence: fence) {
                return
            }
            logCredentialOwnerAcquisitionDenied("restore", attempt: 1)
            scheduleRestoreCredentialOwnerRetry(intent, fence: fence, startingAt: 2)
        }
        """
        let guardedRestoreCaller = functionRegion(
            guardedCallersSource,
            startingAt: "private func restore()"
        ) ?? ""
        let guardedRetryCaller = functionRegion(
            guardedCallersSource,
            startingAt: "private func scheduleRestoreCredentialOwnerRetry("
        ) ?? ""
        let ignoredImmediateCallerSource = guardedCallersSource.replacingOccurrences(
            of: "completeRestoredSession(intent, capture: boundCapture, fence: fence)",
            with: "true"
        )
        let ignoredRetryCallerSource = guardedCallersSource.replacingOccurrences(
            of: "guard self.completeRestoredSession(intent, capture: capture, fence: fence) else {",
            with: "if !self.completeRestoredSession(intent, capture: capture, fence: fence) {"
        )
        let guardedAdoptSource = """
        private func adopt(
            token: String,
            account acct: [String: Any],
            dataKey: Data
        ) async -> Bool {
            let candidateAccount = Account(id: id)
            guard let adoptedCapture = await acquireCredentialOwner(
                scope: scope,
                operation: "adopt",
                fence: operation,
                certifying: {
                    self.persist(token: token, account: candidateAccount, dataKey: dataKey)
                }
            ) else { return false }
            guard operation.generation == authOperationGeneration,
                  isCurrent(adoptedCapture) else { return false }
            guard establishCredentialOwner(adoptedCapture) else { return false }
            SourceIndexLifecycleScope.shared.sessionWillMutate()
            self.token = token
            self.dataKey = dataKey
            self.account = candidateAccount
            self.isSignedIn = true
            reloadLastSyncStamp()
            startRealtime()
            Task { _ = await restoreAccountDocIfNeeded(credentialCapture: adoptedCapture) }
            return true
        }
        """
        let ignoredAdoptEstablishment = guardedAdoptSource.replacingOccurrences(
            of: "guard establishCredentialOwner(adoptedCapture) else { return false }",
            with: "_ = establishCredentialOwner(adoptedCapture)"
        )
        let lateAdoptEstablishment = guardedAdoptSource.replacingOccurrences(
            of: "guard establishCredentialOwner(adoptedCapture) else { return false }\n    SourceIndexLifecycleScope.shared.sessionWillMutate()",
            with: "SourceIndexLifecycleScope.shared.sessionWillMutate()\n    guard establishCredentialOwner(adoptedCapture) else { return false }"
        )
        let guardedAdoptCallers = """
        guard await adopt(token: token, account: acct, dataKey: dataKey) else { return failure }
        guard await adopt(token: token, account: acct, dataKey: dataKey) else { return failure }
        guard await adopt(token: token, account: acct, dataKey: dataKey) else { return failure }
        guard await adopt(token: token, account: acct, dataKey: dataKey) else { return failure }
        """
        let ignoredAdoptCallers = guardedAdoptCallers.replacingOccurrences(
            of: "guard await adopt(",
            with: "_ = await adopt("
        )

        let recoveryUnguardedEstablishmentRoot = try makeFixture(
            base: base,
            name: "recovery-unguarded-establishment-no-raw-suffix"
        )
        try replace(
            "guard establishCredentialOwner(capture) else { return }",
            with: "_ = establishCredentialOwner(capture)",
            in: recoveryUnguardedEstablishmentRoot.appendingPathComponent("app/SourcesShared/VortXSyncManager.swift")
        )
        let recoveryUnguardedEstablishment = try evaluateFixture(root: recoveryUnguardedEstablishmentRoot)

        let recoveryPreAuthenticationInterpolationRoot = try makeFixture(
            base: base,
            name: "recovery-pre-authentication-interpolation"
        )
        try replace(
            "let scope: CredentialScope = .signedOutDevice",
            with: #"""
                    let interpolated = "\(Keychain.string("pre-auth-interpolation") ?? "")"
                    _ = interpolated
                    let scope: CredentialScope = .signedOutDevice
            """#,
            in: recoveryPreAuthenticationInterpolationRoot.appendingPathComponent("app/SourcesShared/VortXSyncManager.swift")
        )
        let recoveryPreAuthenticationInterpolation = try evaluateFixture(
            root: recoveryPreAuthenticationInterpolationRoot
        )

        let recoveryHelperInterpolationRoot = try makeFixture(
            base: base,
            name: "recovery-pre-authentication-helper-interpolation"
        )
        try replace(
            "let scope: CredentialScope = .signedOutDevice",
            with: "_ = preAuthenticationInterpolationHelper(\"pre-auth-helper\")\n                    let scope: CredentialScope = .signedOutDevice",
            in: recoveryHelperInterpolationRoot.appendingPathComponent("app/SourcesShared/VortXSyncManager.swift")
        )
        try append(
            ###"""

            private func preAuthenticationInterpolationHelper(_ account: String) -> String {
                "\(Keychain.string(account) ?? "")"
            }
            """###,
            to: recoveryHelperInterpolationRoot.appendingPathComponent("app/SourcesShared/VortXSyncManager.swift")
        )
        let recoveryHelperInterpolation = try evaluateFixture(root: recoveryHelperInterpolationRoot)

        let recoveryRawQuotedBraceInterpolationRoot = try makeFixture(
            base: base,
            name: "recovery-raw-quoted-brace-helper-interpolation"
        )
        try replace(
            "let scope: CredentialScope = .signedOutDevice",
            with: "_ = rawQuotedBraceInterpolationHelper(\"raw-quoted-brace\")\n                    let scope: CredentialScope = .signedOutDevice",
            in: recoveryRawQuotedBraceInterpolationRoot.appendingPathComponent("app/SourcesShared/VortXSyncManager.swift")
        )
        try append(
            ###"""

            private func rawQuotedBraceInterpolationHelper(_ account: String) -> String {
                #"prefix " } \#(Keychain.string(account) ?? "")"#
            }
            """###,
            to: recoveryRawQuotedBraceInterpolationRoot.appendingPathComponent("app/SourcesShared/VortXSyncManager.swift")
        )
        let recoveryRawQuotedBraceInterpolation = try evaluateFixture(
            root: recoveryRawQuotedBraceInterpolationRoot
        )

        let recoveryAliasHelperInterpolationRoot = try makeFixture(
            base: base,
            name: "recovery-pre-authentication-alias-helper-interpolation"
        )
        try replace(
            "let scope: CredentialScope = .signedOutDevice",
            with: "let interpolationReader: (String) -> String = aliasInterpolationHelperA\n                    _ = interpolationReader(\"pre-auth-alias-helper\")\n                    let scope: CredentialScope = .signedOutDevice",
            in: recoveryAliasHelperInterpolationRoot.appendingPathComponent("app/SourcesShared/VortXSyncManager.swift")
        )
        try append(
            ###"""

            private func aliasInterpolationHelperA(_ account: String) -> String {
                aliasInterpolationHelperB(account)
            }

            private func aliasInterpolationHelperB(_ account: String) -> String {
                "\(Keychain.string(account) ?? "")"
            }
            """###,
            to: recoveryAliasHelperInterpolationRoot.appendingPathComponent("app/SourcesShared/VortXSyncManager.swift")
        )
        let recoveryAliasHelperInterpolation = try evaluateFixture(
            root: recoveryAliasHelperInterpolationRoot
        )

        let recoverySafeInterpolationDecoysRoot = try makeFixture(
            base: base,
            name: "recovery-safe-interpolation-decoys"
        )
        try replace(
            "let scope: CredentialScope = .signedOutDevice",
            with: "_ = safeInterpolationDecoys(\"safe-decoys\")\n                    let scope: CredentialScope = .signedOutDevice",
            in: recoverySafeInterpolationDecoysRoot.appendingPathComponent("app/SourcesShared/VortXSyncManager.swift")
        )
        try append(
            ###"""

            private func safeInterpolationDecoys(_ account: String) -> String {
                // "\(Keychain.string(account) ?? "")"
                /*
                 "\(Keychain.durableString(account) ?? "")"
                 /* "\#(Keychain.string(account) ?? "")" */
                 */
                let escaped = "\\\\("
                let mismatchedRaw = ##"\#(Keychain.string(account) ?? "")"##
                return escaped + mismatchedRaw + account
            }
            """###,
            to: recoverySafeInterpolationDecoysRoot.appendingPathComponent("app/SourcesShared/VortXSyncManager.swift")
        )
        let recoverySafeInterpolationDecoys = try evaluateFixture(root: recoverySafeInterpolationDecoysRoot)

        let recoveryFailureContinuesRoot = try makeFixture(
            base: base,
            name: "recovery-establishment-failure-continues"
        )
        try replace(
            "guard establishCredentialOwner(capture) else { return }",
            with: "if !establishCredentialOwner(capture) {\n                        requestSyncSoon()\n                    }",
            in: recoveryFailureContinuesRoot.appendingPathComponent("app/SourcesShared/VortXSyncManager.swift")
        )
        let recoveryFailureContinues = try evaluateFixture(root: recoveryFailureContinuesRoot)

        let recoveryNestedEstablishmentGuardRoot = try makeFixture(
            base: base,
            name: "recovery-nested-establishment-guard"
        )
        try replace(
            "guard establishCredentialOwner(capture) else { return }",
            with: "if isCurrent(capture) {\n                        if !establishCredentialOwner(capture) {\n                            return\n                        }\n                    }",
            in: recoveryNestedEstablishmentGuardRoot.appendingPathComponent("app/SourcesShared/VortXSyncManager.swift")
        )
        let recoveryNestedEstablishmentGuard = try evaluateFixture(root: recoveryNestedEstablishmentGuardRoot)

        let recoveryClosureEstablishmentGuardRoot = try makeFixture(
            base: base,
            name: "recovery-closure-establishment-guard"
        )
        try replace(
            "guard establishCredentialOwner(capture) else { return }",
            with: "let establishInsideClosure = {\n                        guard establishCredentialOwner(capture) else { return }\n                    }\n                    establishInsideClosure()",
            in: recoveryClosureEstablishmentGuardRoot.appendingPathComponent("app/SourcesShared/VortXSyncManager.swift")
        )
        let recoveryClosureEstablishmentGuard = try evaluateFixture(root: recoveryClosureEstablishmentGuardRoot)

        let recoveryIfFailureReturnRoot = try makeFixture(
            base: base,
            name: "recovery-if-failure-return"
        )
        try replace(
            "guard establishCredentialOwner(capture) else { return }",
            with: "if !establishCredentialOwner(capture) {\n                        return\n                    }",
            in: recoveryIfFailureReturnRoot.appendingPathComponent("app/SourcesShared/VortXSyncManager.swift")
        )
        let recoveryIfFailureReturn = try evaluateFixture(root: recoveryIfFailureReturnRoot)

        let recoveryConditionalCompilationGuardRoot = try makeFixture(
            base: base,
            name: "recovery-conditional-compilation-establishment-guard"
        )
        try replace(
            "guard establishCredentialOwner(capture) else { return }",
            with: "guard establishCredentialOwner(capture) else {\n                    #if DEBUG\n                        return\n                    #endif\n                        return\n                    }",
            in: recoveryConditionalCompilationGuardRoot.appendingPathComponent("app/SourcesShared/VortXSyncManager.swift")
        )
        let recoveryConditionalCompilationGuard = try evaluateFixture(
            root: recoveryConditionalCompilationGuardRoot
        )

        let recoveryFailureInterpolationRoot = try makeFixture(
            base: base,
            name: "recovery-establishment-failure-interpolation"
        )
        try replace(
            "guard establishCredentialOwner(capture) else { return }",
            with: #"""
                    guard establishCredentialOwner(capture) else {
                        let interpolated = "\(Keychain.string("failure-interpolation") ?? "")"
                        _ = interpolated
                        return
                    }
            """#,
            in: recoveryFailureInterpolationRoot.appendingPathComponent("app/SourcesShared/VortXSyncManager.swift")
        )
        let recoveryFailureInterpolation = try evaluateFixture(root: recoveryFailureInterpolationRoot)

        let recoveryGuardedCrossFileSuffixRoot = try makeFixture(
            base: base,
            name: "recovery-guarded-cross-file-suffix"
        )
        try replace(
            "guard establishCredentialOwner(capture) else { return }",
            with: "guard establishCredentialOwner(capture) else { return }\n                    _ = TraktTokenSlots.postEstablishmentExternalHelperA(\"after-establishment\")",
            in: recoveryGuardedCrossFileSuffixRoot.appendingPathComponent("app/SourcesShared/VortXSyncManager.swift")
        )
        try append(
            """

            extension TraktTokenSlots {
                static func postEstablishmentExternalHelperA(_ account: String) -> String? {
                    postEstablishmentExternalHelperB(account)
                }

                static func postEstablishmentExternalHelperB(_ account: String) -> String? {
                    Keychain.string(account)
                }
            }
            """,
            to: recoveryGuardedCrossFileSuffixRoot.appendingPathComponent("app/SourcesShared/TraktAuth.swift")
        )
        let recoveryGuardedCrossFileSuffix = try evaluateFixture(root: recoveryGuardedCrossFileSuffixRoot)

        let recoveryFailedEstablishmentDirectRoot = try makeFixture(
            base: base,
            name: "recovery-failed-establishment-direct"
        )
        try replace(
            "guard establishCredentialOwner(capture) else { return }",
            with: "guard establishCredentialOwner(capture) else {\n                        _ = Keychain.string(\"failed-establishment\")\n                        return\n                    }",
            in: recoveryFailedEstablishmentDirectRoot.appendingPathComponent("app/SourcesShared/VortXSyncManager.swift")
        )
        let recoveryFailedEstablishmentDirect = try evaluateFixture(root: recoveryFailedEstablishmentDirectRoot)

        let recoveryFailedEstablishmentAliasRoot = try makeFixture(
            base: base,
            name: "recovery-failed-establishment-alias"
        )
        try replace(
            "guard establishCredentialOwner(capture) else { return }",
            with: "guard establishCredentialOwner(capture) else {\n                        let reader: (String) -> String? = Keychain.string\n                        _ = reader(\"failed-establishment\")\n                        return\n                    }",
            in: recoveryFailedEstablishmentAliasRoot.appendingPathComponent("app/SourcesShared/VortXSyncManager.swift")
        )
        let recoveryFailedEstablishmentAlias = try evaluateFixture(root: recoveryFailedEstablishmentAliasRoot)

        let externalRoot = try makeFixture(base: base, name: "external-root")
        let outside = base.appendingPathComponent("outside-keychain.swift")
        try "enum CredentialMutationResult { case external }\n".write(
            to: outside,
            atomically: true,
            encoding: .utf8
        )
        let keychain = externalRoot.appendingPathComponent("app/SourcesShared/Keychain.swift")
        try FileManager.default.removeItem(at: keychain)
        try FileManager.default.createSymbolicLink(atPath: keychain.path, withDestinationPath: outside.path)
        let externalDependency = try evaluateFixture(root: externalRoot)

        var renamedGates = valid.gates
        renamedGates[0] = Gate(id: "GREEN-RENAMED", passed: true, detail: "self-test")
        var droppedGates = valid.gates
        droppedGates.removeLast()
        var redGate = valid.gates
        redGate[0] = Gate(id: redGate[0].id, passed: false, detail: "self-test red result")

        let invalidRootCases: [(name: String, arguments: [String], environmentRoot: String?)] = [
            ("empty --root argument fails before gate evaluation", ["--root", ""], nil),
            ("--root= fails before gate evaluation", ["--root="], nil),
            ("whitespace --root argument fails before gate evaluation", ["--root", " \t\n"], nil),
            ("empty --root with --expect-red fails before gate evaluation", ["--expect-red", "--root", ""], nil),
            ("--root= with --expect-red fails before gate evaluation", ["--expect-red", "--root="], nil),
            ("whitespace --root with --expect-red fails before gate evaluation", ["--expect-red", "--root", " \t\n"], nil),
            ("empty root environment fails before gate evaluation", [], ""),
            ("whitespace root environment fails before gate evaluation", [], " \t\n"),
            ("empty root environment with --expect-red fails before gate evaluation", ["--expect-red"], ""),
            ("whitespace root environment with --expect-red fails before gate evaluation", ["--expect-red"], " \t\n")
        ]
        let invalidRootSelfTests = try invalidRootCases.map { rootCase in
            let result = try runHarnessProcess(
                arguments: rootCase.arguments,
                environmentRoot: rootCase.environmentRoot
            )
            return SelfTest(
                name: rootCase.name,
                passed: isFailClosedRootProcess(result)
            )
        }

        return [
            SelfTest(
                name: "valid integrated fixture is GREEN",
                passed: valid.allGreen
            ),
            SelfTest(
                name: "duplicate typed result definition is rejected",
                passed: !duplicate.allGreen
                    && duplicate.gates.first(where: { $0.id == "GREEN-02-SINGLE-RESULT-DEFINITIONS" })?.passed == false
            ),
            SelfTest(
                name: "attributed duplicate typed result definition is rejected",
                passed: !attributedDuplicate.allGreen
                    && attributedDuplicate.gates.first(where: { $0.id == "GREEN-02-SINGLE-RESULT-DEFINITIONS" })?.passed == false
            ),
            SelfTest(
                name: "missing source path is rejected",
                passed: !missingPath.allGreen
                    && missingPath.gates.first(where: { $0.id == "GREEN-01-SOURCE-MANIFEST" })?.passed == false
            ),
            SelfTest(
                name: "missing source anchor is rejected",
                passed: !missingAnchor.allGreen
                    && missingAnchor.gates.first(where: { $0.id == "GREEN-01-SOURCE-MANIFEST" })?.passed == false
            ),
            SelfTest(
                name: "compiler failure is rejected",
                passed: !compilerFailure.allGreen
                    && compilerFailure.gates.first(where: { $0.id == "GREEN-03-INTEGRATED-CREDENTIAL-COMPILER" })?.passed == false
            ),
            SelfTest(
                name: "semantic failure in a non-Keychain closure source is rejected",
                passed: !semanticFailure.allGreen
                    && semanticFailure.gates.first(where: { $0.id == "GREEN-03-INTEGRATED-CREDENTIAL-COMPILER" })?.passed == false
            ),
            SelfTest(
                name: "durable mutation ordering is rejected when reordered",
                passed: !durableReordered.allGreen
                    && durableReordered.gates.first(where: { $0.id == "GREEN-04-DURABLE-CREDENTIAL-BOUNDARY" })?.passed == false
            ),
            SelfTest(
                name: "durable mutation method-reference alias is rejected",
                passed: !durableAlias.allGreen
                    && durableAlias.gates.first(where: { $0.id == "GREEN-04-DURABLE-CREDENTIAL-BOUNDARY" })?.passed == false
            ),
            SelfTest(
                name: "owner authority method-reference alias is rejected",
                passed: !ownerAlias.allGreen
                    && ownerAlias.gates.first(where: { $0.id == "GREEN-05-OWNER-AUTHORITY-FENCES" })?.passed == false
            ),
            SelfTest(
                name: "migration eligibility cannot be checked after a claim",
                passed: !migrationReordered.allGreen
                    && migrationReordered.gates.first(where: { $0.id == "GREEN-06-AUTHENTICATED-MIGRATION-FENCE" })?.passed == false
            ),
            SelfTest(
                name: "migration reader method-reference alias is rejected",
                passed: !migrationAlias.allGreen
                    && migrationAlias.gates.first(where: { $0.id == "GREEN-06-AUTHENTICATED-MIGRATION-FENCE" })?.passed == false
            ),
            SelfTest(
                name: "indirect raw recovery reader alias is rejected",
                passed: !recoveryIndirect.allGreen
                    && recoveryIndirect.gates.first(where: { $0.id == "GREEN-07-RUNTIME-RECOVERY-AUTHORITY" })?.passed == false
            ),
            SelfTest(
                name: "direct raw recovery method-reference alias is rejected",
                passed: !recoveryDirectAlias.allGreen
                    && recoveryDirectAlias.gates.first(where: { $0.id == "GREEN-07-RUNTIME-RECOVERY-AUTHORITY" })?.passed == false
            ),
            SelfTest(
                name: "pre-bind class-scoped raw recovery alias is rejected",
                passed: !recoveryScopedAlias.allGreen
                    && recoveryScopedAlias.gates.first(where: { $0.id == "GREEN-07-RUNTIME-RECOVERY-AUTHORITY" })?.passed == false
            ),
            SelfTest(
                name: "certified read in another operation cannot satisfy recovery",
                passed: !recoveryElsewhere.allGreen
                    && recoveryElsewhere.gates.first(where: { $0.id == "GREEN-07-RUNTIME-RECOVERY-AUTHORITY" })?.passed == false
            ),
            SelfTest(
                name: "migration-only durable recovery reader is rejected",
                passed: !recoveryDurable.allGreen
                    && recoveryDurable.gates.first(where: { $0.id == "GREEN-07-RUNTIME-RECOVERY-AUTHORITY" })?.passed == false
            ),
            SelfTest(
                name: "recovery validation cannot occur after owner binding",
                passed: !recoveryReordered.allGreen
                    && recoveryReordered.gates.first(where: { $0.id == "GREEN-07-RUNTIME-RECOVERY-AUTHORITY" })?.passed == false
            ),
            SelfTest(
                name: "unguarded certified recovery read is rejected",
                passed: !recoveryUnguarded.allGreen
                    && recoveryUnguarded.gates.first(where: { $0.id == "GREEN-07-RUNTIME-RECOVERY-AUTHORITY" })?.passed == false
            ),
            SelfTest(
                name: "raw recovery between namespace binding and authentication is rejected",
                passed: !recoveryPostBind.allGreen
                    && recoveryPostBind.gates.first(where: { $0.id == "GREEN-07-RUNTIME-RECOVERY-AUTHORITY" })?.passed == false
            ),
            SelfTest(
                name: "raw reader inside guarded authenticated migration remains GREEN",
                passed: recoveryAuthenticatedMigration.allGreen
                    && recoveryAuthenticatedMigration.gates.first(where: { $0.id == "GREEN-07-RUNTIME-RECOVERY-AUTHORITY" })?.passed == true
            ),
            SelfTest(
                name: "boundCapture multiline establishment boundary remains GREEN",
                passed: recoveryBoundCapture.allGreen
                    && recoveryBoundCapture.gates.first(where: { $0.id == "GREEN-07-RUNTIME-RECOVERY-AUTHORITY" })?.passed == true
            ),
            SelfTest(
                name: "boundCapture raw reader before authentication is rejected",
                passed: !recoveryBoundCaptureRaw.allGreen
                    && recoveryBoundCaptureRaw.gates.first(where: { $0.id == "GREEN-07-RUNTIME-RECOVERY-AUTHORITY" })?.passed == false
            ),
            SelfTest(
                name: "comments strings and similarly named callees do not create a boundary",
                passed: decoyCallIsIgnored
            ),
            SelfTest(
                name: "copied final integrated root passes every fixed GREEN gate",
                passed: realCertified.allGreen
                    && realCertified.gates.map(\.id) == fixedGateIDs
                    && realCertified.gates.allSatisfy(\.passed)
            ),
            SelfTest(
                name: "real AuthenticatedHTTPTransport dependency is compiler-integrated",
                passed: transportCompilerFailure.sourceSet.requiredMissing.isEmpty
                    && transportCompilerFailure.sourceSet.requiredExternal.isEmpty
                    && transportCompilerFailure.sourceSet.inventoryExternal.isEmpty
                    && transportCompilerFailure.compiler.parse.status == 0
                    && transportCompilerFailure.compiler.typecheck.status != 0
                    && !transportCompilerFailure.allGreen
                    && transportCompilerFailure.gates.first(
                        where: { $0.id == "GREEN-03-INTEGRATED-CREDENTIAL-COMPILER" }
                    )?.passed == false
            ),
            SelfTest(
                name: "unrelated same-name owner raw reader does not poison recovery",
                passed: ownerCollision.allGreen
                    && ownerCollision.gates.first(
                        where: { $0.id == "GREEN-07-RUNTIME-RECOVERY-AUTHORITY" }
                    )?.passed == true
            ),
            SelfTest(
                name: "same-owner reachable raw recovery reader remains rejected",
                passed: sameOwnerRawReader.sourceSet.requiredMissing.isEmpty
                    && sameOwnerRawReader.sourceSet.requiredExternal.isEmpty
                    && sameOwnerRawReader.sourceSet.inventoryExternal.isEmpty
                    && sameOwnerRawReader.compiler.parse.status == 0
                    && sameOwnerRawReader.compiler.typecheck.status == 0
                    && sameOwnerRawReader.gates.filter { !$0.passed }.map(\.id) == [expectedRedGate]
                    && !sameOwnerRawReader.allGreen
                    && sameOwnerRawReader.gates.first(
                        where: { $0.id == "GREEN-07-RUNTIME-RECOVERY-AUTHORITY" }
                    )?.passed == false
            ),
            SelfTest(
                name: "production rejects a raw Keychain string read in storedSessionID",
                passed: !realRawStoredSession.allGreen
                    && realRawStoredSession.gates.first(
                        where: { $0.id == "GREEN-03-INTEGRATED-CREDENTIAL-COMPILER" }
                    )?.passed == true
                    && realRawStoredSession.gates.first(
                        where: { $0.id == "GREEN-05-OWNER-AUTHORITY-FENCES" }
                    )?.passed == false
            ),
            SelfTest(
                name: "production rejects a storedSessionID Keychain string method reference",
                passed: !realAliasedStoredSession.allGreen
                    && realAliasedStoredSession.gates.first(
                        where: { $0.id == "GREEN-03-INTEGRATED-CREDENTIAL-COMPILER" }
                    )?.passed == true
                    && realAliasedStoredSession.gates.first(
                        where: { $0.id == "GREEN-05-OWNER-AUTHORITY-FENCES" }
                    )?.passed == false
            ),
            SelfTest(
                name: "production rejects a storedSessionID reachable Keychain string helper",
                passed: !realHelperStoredSession.allGreen
                    && realHelperStoredSession.gates.first(
                        where: { $0.id == "GREEN-03-INTEGRATED-CREDENTIAL-COMPILER" }
                    )?.passed == true
                    && realHelperStoredSession.gates.first(
                        where: { $0.id == "GREEN-05-OWNER-AUTHORITY-FENCES" }
                    )?.passed == false
            ),
            SelfTest(
                name: "production rejects a split storedSessionID Keychain string call",
                passed: !realSplitStoredSession.allGreen
                    && realSplitStoredSession.gates.first(
                        where: { $0.id == "GREEN-03-INTEGRATED-CREDENTIAL-COMPILER" }
                    )?.passed == true
                    && realSplitStoredSession.gates.first(
                        where: { $0.id == "GREEN-05-OWNER-AUTHORITY-FENCES" }
                    )?.passed == false
            ),
            SelfTest(
                name: "production rejects a raw Keychain durable read in storedSessionID",
                passed: !realRawDurableStoredSession.allGreen
                    && realRawDurableStoredSession.gates.first(
                        where: { $0.id == "GREEN-03-INTEGRATED-CREDENTIAL-COMPILER" }
                    )?.passed == true
                    && realRawDurableStoredSession.gates.first(
                        where: { $0.id == "GREEN-05-OWNER-AUTHORITY-FENCES" }
                    )?.passed == false
            ),
            SelfTest(
                name: "production rejects a storedSessionID durable-read method reference",
                passed: !realAliasedDurableStoredSession.allGreen
                    && realAliasedDurableStoredSession.gates.first(
                        where: { $0.id == "GREEN-03-INTEGRATED-CREDENTIAL-COMPILER" }
                    )?.passed == true
                    && realAliasedDurableStoredSession.gates.first(
                        where: { $0.id == "GREEN-05-OWNER-AUTHORITY-FENCES" }
                    )?.passed == false
            ),
            SelfTest(
                name: "production rejects a storedSessionID reachable durable-read helper",
                passed: !realHelperDurableStoredSession.allGreen
                    && realHelperDurableStoredSession.gates.first(
                        where: { $0.id == "GREEN-03-INTEGRATED-CREDENTIAL-COMPILER" }
                    )?.passed == true
                    && realHelperDurableStoredSession.gates.first(
                        where: { $0.id == "GREEN-05-OWNER-AUTHORITY-FENCES" }
                    )?.passed == false
            ),
            SelfTest(
                name: "production rejects a split storedSessionID durable-read call",
                passed: !realSplitDurableStoredSession.allGreen
                    && realSplitDurableStoredSession.gates.first(
                        where: { $0.id == "GREEN-03-INTEGRATED-CREDENTIAL-COMPILER" }
                    )?.passed == true
                    && realSplitDurableStoredSession.gates.first(
                        where: { $0.id == "GREEN-05-OWNER-AUTHORITY-FENCES" }
                    )?.passed == false
            ),
            SelfTest(
                name: "production rejects a raw Trakt migration source read",
                passed: !realRawTraktMigration.allGreen
                    && realRawTraktMigration.gates.first(
                        where: { $0.id == "GREEN-03-INTEGRATED-CREDENTIAL-COMPILER" }
                    )?.passed == true
                    && realRawTraktMigration.gates.first(
                        where: { $0.id == "GREEN-06-AUTHENTICATED-MIGRATION-FENCE" }
                    )?.passed == false
            ),
            SelfTest(
                name: "production rejects a Trakt durable read outside the sourceRead seam",
                passed: !realRawDurableTraktMigration.allGreen
                    && realRawDurableTraktMigration.gates.first(
                        where: { $0.id == "GREEN-03-INTEGRATED-CREDENTIAL-COMPILER" }
                    )?.passed == true
                    && realRawDurableTraktMigration.gates.first(
                        where: { $0.id == "GREEN-06-AUTHENTICATED-MIGRATION-FENCE" }
                    )?.passed == false
            ),
            SelfTest(
                name: "production rejects a durable sourceRead relocated out of its claim",
                passed: !realRelocatedDurableTraktMigration.allGreen
                    && realRelocatedDurableTraktMigration.gates.first(
                        where: { $0.id == "GREEN-03-INTEGRATED-CREDENTIAL-COMPILER" }
                    )?.passed == true
                    && realRelocatedDurableTraktMigration.gates.first(
                        where: { $0.id == "GREEN-06-AUTHENTICATED-MIGRATION-FENCE" }
                    )?.passed == false
            ),
            SelfTest(
                name: "production rejects comment-only anchors around a corrupted primary claim",
                passed: !realCommentDecoyTraktMigration.allGreen
                    && realCommentDecoyTraktMigration.gates.first(
                        where: { $0.id == "GREEN-03-INTEGRATED-CREDENTIAL-COMPILER" }
                    )?.passed == true
                    && realCommentDecoyTraktMigration.gates.first(
                        where: { $0.id == "GREEN-06-AUTHENTICATED-MIGRATION-FENCE" }
                    )?.passed == false
            ),
            SelfTest(
                name: "production rejects a copied valid primary claim that masks a corrupted binding",
                passed: !realCopiedValidPrimaryDecoy.allGreen
                    && realCopiedValidPrimaryDecoy.gates.first(
                        where: { $0.id == "GREEN-03-INTEGRATED-CREDENTIAL-COMPILER" }
                    )?.passed == true
                    && realCopiedValidPrimaryDecoy.gates.first(
                        where: { $0.id == "GREEN-06-AUTHENTICATED-MIGRATION-FENCE" }
                    )?.passed == false
            ),
            SelfTest(
                name: "production rejects nested and commented primary sourceRead decoys",
                passed: !realNestedPrimarySourceRead.allGreen
                    && realNestedPrimarySourceRead.gates.first(
                        where: { $0.id == "GREEN-03-INTEGRATED-CREDENTIAL-COMPILER" }
                    )?.passed == true
                    && realNestedPrimarySourceRead.gates.first(
                        where: { $0.id == "GREEN-06-AUTHENTICATED-MIGRATION-FENCE" }
                    )?.passed == false
            ),
            SelfTest(
                name: "production rejects nested and commented createdAt sourceRead decoys",
                passed: !realNestedCreatedAtSourceRead.allGreen
                    && realNestedCreatedAtSourceRead.gates.first(
                        where: { $0.id == "GREEN-03-INTEGRATED-CREDENTIAL-COMPILER" }
                    )?.passed == true
                    && realNestedCreatedAtSourceRead.gates.first(
                        where: { $0.id == "GREEN-06-AUTHENTICATED-MIGRATION-FENCE" }
                    )?.passed == false
            ),
            SelfTest(
                name: "production rejects nested and commented session sourceRead decoys",
                passed: !realNestedSessionSourceRead.allGreen
                    && realNestedSessionSourceRead.gates.first(
                        where: { $0.id == "GREEN-03-INTEGRATED-CREDENTIAL-COMPILER" }
                    )?.passed == true
                    && realNestedSessionSourceRead.gates.first(
                        where: { $0.id == "GREEN-06-AUTHENTICATED-MIGRATION-FENCE" }
                    )?.passed == false
            ),
            SelfTest(
                name: "production rejects a Trakt migration Keychain string method reference",
                passed: !realAliasedTraktMigration.allGreen
                    && realAliasedTraktMigration.gates.first(
                        where: { $0.id == "GREEN-03-INTEGRATED-CREDENTIAL-COMPILER" }
                    )?.passed == true
                    && realAliasedTraktMigration.gates.first(
                        where: { $0.id == "GREEN-06-AUTHENTICATED-MIGRATION-FENCE" }
                    )?.passed == false
            ),
            SelfTest(
                name: "production rejects a reachable Trakt migration Keychain string helper",
                passed: !realHelperTraktMigration.allGreen
                    && realHelperTraktMigration.gates.first(
                        where: { $0.id == "GREEN-03-INTEGRATED-CREDENTIAL-COMPILER" }
                    )?.passed == true
                    && realHelperTraktMigration.gates.first(
                        where: { $0.id == "GREEN-06-AUTHENTICATED-MIGRATION-FENCE" }
                    )?.passed == false
            ),
            SelfTest(
                name: "production rejects a split Trakt migration Keychain string call",
                passed: !realSplitTraktMigration.allGreen
                    && realSplitTraktMigration.gates.first(
                        where: { $0.id == "GREEN-03-INTEGRATED-CREDENTIAL-COMPILER" }
                    )?.passed == true
                    && realSplitTraktMigration.gates.first(
                        where: { $0.id == "GREEN-06-AUTHENTICATED-MIGRATION-FENCE" }
                    )?.passed == false
            ),
            SelfTest(
                name: "production rejects restore with an ignored owner-establishment result",
                passed: !realIgnoredRestoreEstablishment.allGreen
                    && realIgnoredRestoreEstablishment.gates.first(
                        where: { $0.id == "GREEN-07-RUNTIME-RECOVERY-AUTHORITY" }
                    )?.passed == false
            ),
            SelfTest(
                name: "production rejects restore with owner establishment after publication",
                passed: !realLateRestoreEstablishment.allGreen
                    && realLateRestoreEstablishment.gates.first(
                        where: { $0.id == "GREEN-07-RUNTIME-RECOVERY-AUTHORITY" }
                    )?.passed == false
            ),
            SelfTest(
                name: "production rejects adopt with an ignored owner-establishment result",
                passed: !realIgnoredAdoptEstablishment.allGreen
                    && realIgnoredAdoptEstablishment.gates.first(
                        where: { $0.id == "GREEN-07-RUNTIME-RECOVERY-AUTHORITY" }
                    )?.passed == false
            ),
            SelfTest(
                name: "production rejects adopt with owner establishment after publication",
                passed: !realLateAdoptEstablishment.allGreen
                    && realLateAdoptEstablishment.gates.first(
                        where: { $0.id == "GREEN-07-RUNTIME-RECOVERY-AUTHORITY" }
                    )?.passed == false
            ),
            SelfTest(
                name: "production rejects adopt without its certifying persistence closure",
                passed: realAdoptWithoutCertification.sourceSet.requiredMissing.isEmpty
                    && realAdoptWithoutCertification.sourceSet.requiredExternal.isEmpty
                    && realAdoptWithoutCertification.sourceSet.inventoryExternal.isEmpty
                    && realAdoptWithoutCertification.compiler.parse.status == 0
                    && realAdoptWithoutCertification.compiler.typecheck.status == 0
                    && realAdoptWithoutCertification.gates.filter { !$0.passed }.map(\.id)
                        == [expectedRedGate]
                    && !realAdoptWithoutCertification.allGreen
                    && realAdoptWithoutCertification.gates.first(
                        where: { $0.id == expectedRedGate }
                    )?.passed == false
            ),
            SelfTest(
                name: "production rejects adopt that publishes a nil account",
                passed: realAdoptNilAccountPublication.sourceSet.requiredMissing.isEmpty
                    && realAdoptNilAccountPublication.sourceSet.requiredExternal.isEmpty
                    && realAdoptNilAccountPublication.sourceSet.inventoryExternal.isEmpty
                    && realAdoptNilAccountPublication.compiler.parse.status == 0
                    && realAdoptNilAccountPublication.compiler.typecheck.status == 0
                    && realAdoptNilAccountPublication.gates.filter { !$0.passed }.map(\.id)
                        == [expectedRedGate]
                    && !realAdoptNilAccountPublication.allGreen
                    && realAdoptNilAccountPublication.gates.first(
                        where: { $0.id == expectedRedGate }
                    )?.passed == false
            ),
            SelfTest(
                name: "restore completion requires owner establishment before every live publication",
                passed: restoreCompletionDominatesPublication(guardedCompletionSource)
            ),
            SelfTest(
                name: "restore completion rejects an ignored owner-establishment result",
                passed: !restoreCompletionDominatesPublication(ignoredEstablishmentCompletion)
            ),
            SelfTest(
                name: "restore completion rejects owner establishment after source-index publication",
                passed: !restoreCompletionDominatesPublication(lateEstablishmentCompletion)
            ),
            SelfTest(
                name: "restore callers propagate completion failure",
                passed: restoreCallersPropagateFailure(
                    restore: guardedRestoreCaller,
                    retry: guardedRetryCaller
                )
            ),
            SelfTest(
                name: "restore rejects an immediate caller that ignores completion failure",
                passed: !restoreCallersPropagateFailure(
                    restore: functionRegion(
                        ignoredImmediateCallerSource,
                        startingAt: "private func restore()"
                    ) ?? "",
                    retry: guardedRetryCaller
                )
            ),
            SelfTest(
                name: "restore rejects a retry caller that weakens completion failure handling",
                passed: !restoreCallersPropagateFailure(
                    restore: guardedRestoreCaller,
                    retry: functionRegion(
                        ignoredRetryCallerSource,
                        startingAt: "private func scheduleRestoreCredentialOwnerRetry("
                    ) ?? ""
                )
            ),
            SelfTest(
                name: "interactive adopt requires owner establishment before every live publication",
                passed: adoptEstablishmentDominatesPublication(guardedAdoptSource)
            ),
            SelfTest(
                name: "interactive adopt rejects an ignored owner-establishment result",
                passed: !adoptEstablishmentDominatesPublication(ignoredAdoptEstablishment)
            ),
            SelfTest(
                name: "interactive adopt rejects owner establishment after source-index publication",
                passed: !adoptEstablishmentDominatesPublication(lateAdoptEstablishment)
            ),
            SelfTest(
                name: "all interactive adopt callers propagate failure",
                passed: allAdoptCallersPropagateFailure(guardedAdoptCallers)
                    && !allAdoptCallersPropagateFailure(ignoredAdoptCallers)
            ),
            SelfTest(
                name: "unguarded establishment without a raw suffix is rejected",
                passed: !recoveryUnguardedEstablishment.allGreen
                    && recoveryUnguardedEstablishment.gates.first(where: { $0.id == "GREEN-07-RUNTIME-RECOVERY-AUTHORITY" })?.passed == false
            ),
            SelfTest(
                name: "pre-authentication string interpolation raw reader is rejected",
                passed: !recoveryPreAuthenticationInterpolation.allGreen
                    && recoveryPreAuthenticationInterpolation.gates.first(where: { $0.id == "GREEN-03-INTEGRATED-CREDENTIAL-COMPILER" })?.passed == true
                    && recoveryPreAuthenticationInterpolation.gates.first(where: { $0.id == "GREEN-07-RUNTIME-RECOVERY-AUTHORITY" })?.passed == false
            ),
            SelfTest(
                name: "pre-authentication helper string interpolation raw reader is rejected",
                passed: !recoveryHelperInterpolation.allGreen
                    && recoveryHelperInterpolation.gates.first(where: { $0.id == "GREEN-03-INTEGRATED-CREDENTIAL-COMPILER" })?.passed == true
                    && recoveryHelperInterpolation.gates.first(where: { $0.id == "GREEN-07-RUNTIME-RECOVERY-AUTHORITY" })?.passed == false
            ),
            SelfTest(
                name: "raw quoted-brace helper string interpolation is rejected",
                passed: !recoveryRawQuotedBraceInterpolation.allGreen
                    && recoveryRawQuotedBraceInterpolation.gates.first(where: { $0.id == "GREEN-03-INTEGRATED-CREDENTIAL-COMPILER" })?.passed == true
                    && recoveryRawQuotedBraceInterpolation.gates.first(where: { $0.id == "GREEN-07-RUNTIME-RECOVERY-AUTHORITY" })?.passed == false
            ),
            SelfTest(
                name: "alias helper chain string interpolation raw reader is rejected",
                passed: !recoveryAliasHelperInterpolation.allGreen
                    && recoveryAliasHelperInterpolation.gates.first(where: { $0.id == "GREEN-03-INTEGRATED-CREDENTIAL-COMPILER" })?.passed == true
                    && recoveryAliasHelperInterpolation.gates.first(where: { $0.id == "GREEN-07-RUNTIME-RECOVERY-AUTHORITY" })?.passed == false
            ),
            SelfTest(
                name: "comments and literal interpolation markers remain GREEN",
                passed: recoverySafeInterpolationDecoys.allGreen
                    && recoverySafeInterpolationDecoys.gates.first(where: { $0.id == "GREEN-07-RUNTIME-RECOVERY-AUTHORITY" })?.passed == true
            ),
            SelfTest(
                name: "establishment failure branch that continues is rejected",
                passed: !recoveryFailureContinues.allGreen
                    && recoveryFailureContinues.gates.first(where: { $0.id == "GREEN-07-RUNTIME-RECOVERY-AUTHORITY" })?.passed == false
            ),
            SelfTest(
                name: "nested conditional establishment guard is rejected",
                passed: !recoveryNestedEstablishmentGuard.allGreen
                    && recoveryNestedEstablishmentGuard.gates.first(where: { $0.id == "GREEN-07-RUNTIME-RECOVERY-AUTHORITY" })?.passed == false
            ),
            SelfTest(
                name: "closure-local establishment guard is rejected",
                passed: !recoveryClosureEstablishmentGuard.allGreen
                    && recoveryClosureEstablishmentGuard.gates.first(where: { $0.id == "GREEN-07-RUNTIME-RECOVERY-AUTHORITY" })?.passed == false
            ),
            SelfTest(
                name: "top-level if-failure-return establishment is rejected",
                passed: !recoveryIfFailureReturn.allGreen
                    && recoveryIfFailureReturn.gates.first(where: { $0.id == "GREEN-07-RUNTIME-RECOVERY-AUTHORITY" })?.passed == false
            ),
            SelfTest(
                name: "conditional compilation in establishment failure is rejected",
                passed: !recoveryConditionalCompilationGuard.allGreen
                    && recoveryConditionalCompilationGuard.gates.first(where: { $0.id == "GREEN-03-INTEGRATED-CREDENTIAL-COMPILER" })?.passed == true
                    && recoveryConditionalCompilationGuard.gates.first(where: { $0.id == "GREEN-07-RUNTIME-RECOVERY-AUTHORITY" })?.passed == false
            ),
            SelfTest(
                name: "establishment failure string interpolation raw reader is rejected",
                passed: !recoveryFailureInterpolation.allGreen
                    && recoveryFailureInterpolation.gates.first(where: { $0.id == "GREEN-03-INTEGRATED-CREDENTIAL-COMPILER" })?.passed == true
                    && recoveryFailureInterpolation.gates.first(where: { $0.id == "GREEN-07-RUNTIME-RECOVERY-AUTHORITY" })?.passed == false
            ),
            SelfTest(
                name: "successful establishment guard permits arbitrary cross-file suffix",
                passed: recoveryGuardedCrossFileSuffix.allGreen
                    && recoveryGuardedCrossFileSuffix.gates.first(where: { $0.id == "GREEN-06-AUTHENTICATED-MIGRATION-FENCE" })?.passed == true
                    && recoveryGuardedCrossFileSuffix.gates.first(where: { $0.id == "GREEN-07-RUNTIME-RECOVERY-AUTHORITY" })?.passed == true
            ),
            SelfTest(
                name: "raw direct reader in establishment failure branch is rejected",
                passed: !recoveryFailedEstablishmentDirect.allGreen
                    && recoveryFailedEstablishmentDirect.gates.first(where: { $0.id == "GREEN-07-RUNTIME-RECOVERY-AUTHORITY" })?.passed == false
            ),
            SelfTest(
                name: "raw alias in establishment failure branch is rejected",
                passed: !recoveryFailedEstablishmentAlias.allGreen
                    && recoveryFailedEstablishmentAlias.gates.first(where: { $0.id == "GREEN-07-RUNTIME-RECOVERY-AUTHORITY" })?.passed == false
            ),
            SelfTest(
                name: "external source symlink is rejected",
                passed: !externalDependency.allGreen
                    && externalDependency.gates.first(where: { $0.id == "GREEN-08-SINGLE-ROOT-INTEGRITY" })?.passed == false
            ),
            SelfTest(
                name: "renamed fixed gate is rejected",
                passed: !validateGateInventory(renamedGates).isEmpty
            ),
            SelfTest(
                name: "dropped fixed gate is rejected",
                passed: !validateGateInventory(droppedGates).isEmpty
            ),
            SelfTest(
                name: "red gate result is rejected",
                passed: !redGate.allSatisfy(\.passed)
            ),
            SelfTest(
                name: "expected RED accepts only the named composition gate",
                passed: isExpectedRedReceipt(
                    Evaluation(
                        root: valid.root,
                        sourceSet: valid.sourceSet,
                        declarations: valid.declarations,
                        compiler: valid.compiler,
                        gates: valid.gates.map {
                            $0.id == expectedRedGate
                                ? Gate(id: $0.id, passed: false, detail: "self-test")
                                : $0
                        },
                        inventoryFailures: []
                    )
                )
            ),
            SelfTest(
                name: "expected RED rejects a compiler failure",
                passed: !isExpectedRedReceipt(
                    Evaluation(
                        root: valid.root,
                        sourceSet: valid.sourceSet,
                        declarations: valid.declarations,
                        compiler: valid.compiler,
                        gates: valid.gates.map {
                            $0.id == "GREEN-03-INTEGRATED-CREDENTIAL-COMPILER"
                                ? Gate(id: $0.id, passed: false, detail: "self-test")
                                : $0
                        },
                        inventoryFailures: []
                    )
                )
            )
        ] + invalidRootSelfTests
    }

    private static func makeFixture(base: URL, name: String) throws -> URL {
        let root = base.appendingPathComponent(name, isDirectory: true)
        let directory = root.appendingPathComponent("app/SourcesShared", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let files: [String: String] = [
            "CredentialScope.swift": """
            import Foundation
            enum CredentialScope: Equatable { case signedOutDevice }
            final class CredentialScopeRegistry {
                struct Capture: Equatable {
                    let scope: CredentialScope
                    let generation: Int
                }
                static let shared = CredentialScopeRegistry()
                func capture() -> Capture {
                    Capture(scope: .signedOutDevice, generation: 0)
                }
                func isCurrent(_ capture: Capture) -> Bool { true }
                func isMigrationEligible(_ capture: Capture) -> Bool { true }
                func establishAuthenticatedOwner(_ capture: Capture) -> Capture? { capture }
                func bind(_ scope: CredentialScope) -> Capture { capture() }
            }
            """,
            "Keychain.swift": """
            import Foundation
            enum CredentialDurableReadResult: Equatable {
                case value(String)
                case missing
                case failure
            }
            enum CredentialMutationResult: Equatable {
                case success
                case failure
            }

            private struct CredentialStore {
                func confirmedString(_ account: String) -> CredentialDurableReadResult { .missing }
                func durableString(_ account: String) -> CredentialDurableReadResult { .missing }
                func set(_ value: String?, for account: String) -> CredentialMutationResult { .success }
            }

            enum Keychain {
                private static let secureStore = CredentialStore()
                static func string(_ account: String) -> String? { nil }
                static func confirmedString(_ account: String) -> CredentialDurableReadResult {
                    secureStore.confirmedString(account)
                }
                static func durableString(_ account: String) -> CredentialDurableReadResult {
                    secureStore.durableString(account)
                }
                static func set(_ value: String?, for account: String) -> CredentialMutationResult {
                    secureStore.set(value, for: account)
                }
            }
            """,
            "ApiKeys.swift": """
            import Foundation
            final class ApiKeys {
                static let shared = ApiKeys()
                private(set) var owner: CredentialScope = .signedOutDevice
                private var boundCapture: CredentialScopeRegistry.Capture?
                private var loadingScope = false

                func bind(owner newOwner: CredentialScope) {
                    let capture = CredentialScopeRegistry.shared.capture()
                    guard capture.scope == newOwner else { return }
                    self.owner = newOwner
                    boundCapture = capture
                    loadScope()
                }

                func migrateLegacyIfEligible(
                    owner expectedOwner: CredentialScope,
                    capture: CredentialScopeRegistry.Capture
                ) -> Bool {
                    guard owner == expectedOwner,
                          capture.scope == expectedOwner,
                          CredentialScopeRegistry.shared.isMigrationEligible(capture) else { return false }
                    let result = CredentialLegacyClaim.claimGlobalSlotCertified(
                        readCertified: { account in CredentialLegacyClaim.read(Keychain.confirmedString(account)) },
                        readDurableSource: { account in CredentialLegacyClaim.read(Keychain.durableString(account)) },
                        write: { value, account in _ = Keychain.set(value, for: account) })
                    switch result {
                    case .migrated, .targetPresent:
                        return true
                    case .noSource:
                        return true
                    }
                }

                private func persist(
                    _ value: String,
                    previous: String,
                    account: String,
                    restore: () -> Void
                ) {
                    guard let boundCapture,
                          CredentialScopeRegistry.shared.isCurrent(boundCapture) else { return }
                    let storedValue: String? = value.isEmpty ? nil : value
                    var result = CredentialMutationResult.failure
                    for _ in 0..<2 {
                        result = Keychain.set(storedValue, for: account)
                        if result == CredentialMutationResult.success { break }
                    }
                    guard result == .success else {
                        restore()
                        return
                    }
                    VortXSyncManager.shared.requestSyncSoon()
                }

                private func loadScope() {}

                private nonisolated static func confirmedValue(_ account: String) -> CredentialDurableReadResult {
                    var result = Keychain.confirmedString(account)
                    if result == .failure {
                        result = Keychain.confirmedString(account)
                    }
                    return result
                }

                private nonisolated static func scopedValue(_ account: String) -> String? {
                    let authority = CredentialScopeRegistry.shared
                    let capture = authority.capture()
                    let result = confirmedValue(account)
                    guard authority.isCurrent(capture) else { return nil }
                    guard case let .value(value) = result else { return nil }
                    return value
                }
            }
            """,
            "DebridKeys.swift": """
            import Foundation
            enum DebridService: CaseIterable {
                case primary
                var rawValue: String { "primary" }
            }

            enum DebridLegacyMigrationResult { case noSource, targetPresent, migrated, retryableFailure }

            private struct DebridStorage {
                func confirmedRead(_ account: String) -> CredentialDurableReadResult { .missing }
                func durableRead(_ account: String) -> CredentialDurableReadResult { .missing }
                func mutate(_ value: String?, for account: String) -> CredentialMutationResult { .success }
            }

            final class DebridKeys {
                static let shared = DebridKeys()
                private(set) var owner: CredentialScope = .signedOutDevice
                private var keys: [String: String] = [:]
                private let storage = DebridStorage()

                func bind(owner newOwner: CredentialScope) {
                    let capture = CredentialScopeRegistry.shared.capture()
                    bind(owner: newOwner, capture: capture)
                }

                func bind(owner newOwner: CredentialScope, capture: CredentialScopeRegistry.Capture) {
                    guard capture.scope == newOwner,
                          CredentialScopeRegistry.shared.isCurrent(capture) else { return }
                    let loaded = readScope(for: newOwner)
                    guard CredentialScopeRegistry.shared.isCurrent(capture) else { return }
                    owner = newOwner
                    keys = loaded ?? [:]
                }

                func migrateLegacyIfEligible(
                    owner expectedOwner: CredentialScope,
                    capture: CredentialScopeRegistry.Capture
                ) -> Bool {
                    guard owner == expectedOwner,
                          capture.scope == expectedOwner,
                          CredentialScopeRegistry.shared.isMigrationEligible(capture) else { return false }
                    var safe = true
                    for service in DebridService.allCases {
                        let result = migrateLegacySlot(service: service, owner: expectedOwner, capture: capture)
                        if case .retryableFailure = result { safe = false }
                    }
                    guard safe else { return false }
                    guard let loaded = readScope() else { return false }
                    keys = loaded
                    return true
                }

                private func migrateLegacySlot(
                    service: DebridService,
                    owner: CredentialScope,
                    capture: CredentialScopeRegistry.Capture
                ) -> DebridLegacyMigrationResult {
                    guard owner == self.owner,
                          capture.scope == owner,
                          CredentialScopeRegistry.shared.isCurrent(capture) else { return .retryableFailure }
                    let markerAccount = "marker"
                    let sourceAccount = "source"
                    let destinationAccount = "destination"
                    _ = storage.durableRead(markerAccount)
                    _ = storage.durableRead(sourceAccount)
                    let encoded: String? = "encoded"
                    _ = certifyMutation(encoded, account: markerAccount, durable: true)
                    _ = storage.durableRead(destinationAccount)
                    let source = "source"
                    _ = certifyMutation(source, account: destinationAccount, durable: true)
                    _ = certifyMutation(nil, account: sourceAccount, durable: true)
                    return .migrated
                }

                private func certifyMutation(_ value: String?, account: String, durable: Bool) -> Bool {
                    storage.mutate(value, for: account) == .success
                }

                private func readScope(for scopedOwner: CredentialScope) -> [String: String]? {
                    var next: [String: String] = [:]
                    switch storage.confirmedRead("debrid") {
                    case let .value(value): next["primary"] = value
                    case .missing: break
                    case .failure: return nil
                    }
                    return next
                }

                private func readScope() -> [String: String]? {
                    readScope(for: owner)
                }

                func setKey(_ value: String, for service: DebridService) -> Bool {
                    let account = service.rawValue
                    let expected: String? = value.isEmpty ? nil : value
                    var certified = false
                    guard storage.mutate(expected, for: account) == .success else { return false }
                    switch storage.confirmedRead(account) {
                    case let .value(actual) where expected == actual:
                        certified = true
                    case .missing where expected == nil:
                        certified = true
                    case .value, .missing, .failure:
                        certified = false
                    }
                    if certified { keys[service.rawValue] = value }
                    guard certified else { return false }
                    keys[service.rawValue] = value
                    return true
                }
            }
            """,
            "TraktAuth.swift": """
            import Foundation
            enum CredentialLegacyClaim {
                enum ReadResult { case value(String), missing, failure }
                enum Result: Equatable { case noSource, targetPresent, migrated }

                static func read(_ result: CredentialDurableReadResult) -> ReadResult {
                    switch result {
                    case let .value(value): return .value(value)
                    case .missing: return .missing
                    case .failure: return .failure
                    }
                }

                static func claimGlobalSlotCertified(
                    readCertified: (String) -> ReadResult,
                    readDurableSource: (String) -> ReadResult,
                    write: (String?, String) -> Void
                ) -> Result {
                    _ = readCertified("source")
                    _ = readDurableSource("source")
                    _ = write("value", "destination")
                    return .migrated
                }

                static func claimGlobalSlotSet(
                    slots: [(String, String)],
                    claimMarkerAccount: String,
                    ownerNamespace: String,
                    read: (String) -> String?,
                    write: (String?, String) -> Void,
                    provenanceTag: String
                ) -> Result { .migrated }

                static func claimGlobalSlot(
                    sourceAccount: String,
                    destinationAccount: String,
                    claimMarkerAccount: String,
                    ownerNamespace: String,
                    read: (String) -> String?,
                    write: (String?, String) -> Void,
                    provenanceTag: String
                ) -> Result { .migrated }
            }

            enum TraktTokenSlots {
                static let legacyAccess = "access"

                @discardableResult
                static func claimLegacyGlobal(
                    owner: CredentialScope,
                    capture: CredentialScopeRegistry.Capture
                ) -> CredentialLegacyClaim.Result {
                    guard capture.scope == owner,
                          CredentialScopeRegistry.shared.isMigrationEligible(capture) else { return .noSource }
                    let primary = CredentialLegacyClaim.claimGlobalSlotSet(
                        slots: [("source", "destination")],
                        claimMarkerAccount: "marker",
                        ownerNamespace: "owner",
                        read: Keychain.string,
                        write: { value, account in _ = Keychain.set(value, for: account) },
                        provenanceTag: "trakt")
                    guard primary == .migrated || primary == .targetPresent else { return primary }
                    _ = CredentialLegacyClaim.claimGlobalSlot(
                        sourceAccount: "optional-source",
                        destinationAccount: "optional-destination",
                        claimMarkerAccount: "optional-marker",
                        ownerNamespace: "owner",
                        read: Keychain.string,
                        write: { value, account in _ = Keychain.set(value, for: account) },
                        provenanceTag: "optional")
                    return primary
                }
            }

            actor TraktAuth {
                private nonisolated func ownerCapture() -> CredentialScopeRegistry.Capture {
                    CredentialScopeRegistry.shared.capture()
                }

                nonisolated static var storedSessionID: String? {
                    let authority = CredentialScopeRegistry.shared
                    let capture = authority.capture()
                    guard Keychain.string("trakt") != nil else { return nil }
                    guard authority.isCurrent(capture) else { return nil }
                    return "session"
                }

                func signOut() async {
                    let capture = ownerCapture()
                    guard CredentialScopeRegistry.shared.isCurrent(capture) else { return }
                }
            }
            """,
            "VortXSyncManager.swift": """
            import Foundation
            final class VortXSyncManager {
                static let shared = VortXSyncManager()
                private let credentialAuthority = CredentialScopeRegistry.shared

                private func bindCredentialOwner(_ scope: CredentialScope) -> CredentialScopeRegistry.Capture {
                    let capture = credentialAuthority.bind(scope)
                    ApiKeys.shared.bind(owner: scope)
                    DebridKeys.shared.bind(owner: scope, capture: capture)
                    return capture
                }

                private func establishCredentialOwner(_ capture: CredentialScopeRegistry.Capture) -> Bool {
                    guard let established = credentialAuthority.establishAuthenticatedOwner(capture) else {
                        return false
                    }
                    let owner = established.scope
                    _ = ApiKeys.shared.migrateLegacyIfEligible(owner: owner, capture: established)
                    _ = TraktTokenSlots.claimLegacyGlobal(owner: owner, capture: established)
                    _ = DebridKeys.shared.migrateLegacyIfEligible(owner: owner, capture: established)
                    return true
                }

                private func restore() {
                    guard case .missing = Keychain.confirmedString("session") else { return }
                    let scope: CredentialScope = .signedOutDevice
                    let capture = bindCredentialOwner(scope)
                    guard establishCredentialOwner(capture) else { return }
                }

                func requestSyncSoon() {}
                func isCurrent(_ capture: CredentialScopeRegistry.Capture) -> Bool {
                    credentialAuthority.isCurrent(capture)
                }
            }
            """,
            "AuthenticatedHTTPTransport.swift": """
            import Foundation
            final class AuthenticatedHTTPTransport {
                static let snapshotResponseLimit = 1

                func send() {}

                static func decodeJSON<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
                    fatalError()
                }
            }
            """
        ]
        for (filename, text) in files {
            try text.write(
                to: directory.appendingPathComponent(filename),
                atomically: true,
                encoding: .utf8
            )
        }
        return root
    }

    private static func makeRealRootFixture(base: URL, name: String) throws -> URL {
        let root = base.appendingPathComponent(name, isDirectory: true)
        let currentRoot = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        for spec in sourceManifest {
            let source = currentRoot.appendingPathComponent(spec.path)
            guard FileManager.default.fileExists(atPath: source.path) else {
                throw HarnessError.fixture("real-root source is absent at (source.path)")
            }
            let destination = root.appendingPathComponent(spec.path)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: source, to: destination)
        }
        return root
    }

    private static func append(_ text: String, to url: URL) throws {
        guard let handle = try? FileHandle(forWritingTo: url) else {
            throw HarnessError.fixture("cannot append to \(url.path)")
        }
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private static func replace(_ old: String, with new: String, in url: URL) throws {
        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            throw HarnessError.fixture("cannot read \(url.path)")
        }
        guard source.contains(old) else {
            throw HarnessError.fixture("fixture anchor \(old) is absent")
        }
        try source.replacingOccurrences(of: old, with: new).write(
            to: url,
            atomically: true,
            encoding: .utf8
        )
    }
}
