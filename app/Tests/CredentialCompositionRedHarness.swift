import Foundation

/// Historical RED-baseline validation for the four Apple credential lanes.
///
/// This file intentionally retains its separate lane inputs and fixed pre-composition failures as
/// historical evidence. It is not the integrated-root gate; use CredentialCompositionGreenHarness
/// for the composed project source.
///
/// This deliberately operates on the real, independently-owned lane files. It does not declare replacement
/// credential types or production adapters. The second compiler stage removes only the duplicate result-type
/// declarations from a byte-for-byte Keychain diagnostic copy so that Swift can reveal the next incompatible
/// real call sites.
///
/// Run from any directory:
/// `swiftc -parse-as-library app/Tests/CredentialCompositionRedHarness.swift -o /tmp/credential-composition-red && /tmp/credential-composition-red --expect-red`
///
/// Without `--expect-red`, the executable exits nonzero while the known composition and behavior gates remain
/// red. That makes it suitable as the final gate after the agreed composition protocol is implemented.
@main
struct CredentialCompositionRedHarness {
    private struct LanePaths {
        let root: URL
        let auth: URL
        let apiKeys: URL
        let debrid: URL
        let oauth: URL

        init() throws {
            root = URL(fileURLWithPath: ProcessInfo.processInfo.environment[
                "VORTX_CREDENTIAL_COMPOSITION_LANES_ROOT"
            ] ?? "/Users/daksh", isDirectory: true)
            auth = root.appendingPathComponent("vortx-alpha-apple-credential-integrity-r1", isDirectory: true)
            apiKeys = root.appendingPathComponent("vortx-alpha-apple-apikeys-integrity-r1", isDirectory: true)
            debrid = root.appendingPathComponent("vortx-alpha-apple-debrid-integrity-r1", isDirectory: true)
            oauth = root.appendingPathComponent("vortx-oauth-r1", isDirectory: true)

            for lane in [auth, apiKeys, debrid, oauth] where !FileManager.default.fileExists(atPath: lane.path) {
                throw HarnessError.missingLane(lane.path)
            }
        }

        func source(_ lane: URL, _ relativePath: String) -> URL {
            lane.appendingPathComponent(relativePath)
        }
    }

    private struct CompilerResult {
        let status: Int32
        let output: String
    }

    private enum HarnessError: LocalizedError {
        case missingLane(String)
        case missingSource(String)
        case malformedSource(String)
        case compilerLaunch(String)

        var errorDescription: String? {
            switch self {
            case let .missingLane(path): return "missing required lane: \(path)"
            case let .missingSource(path): return "missing required source: \(path)"
            case let .malformedSource(detail): return "cannot construct diagnostic source copy: \(detail)"
            case let .compilerLaunch(detail): return "could not launch Swift compiler: \(detail)"
            }
        }
    }

    private struct Check {
        let id: String
        let name: String
        let passed: Bool
        let detail: String
    }

    private struct BehaviorProbe {
        let id: String
        let sourceValid: Bool
        let isRed: Bool
        let detail: String
    }

    private struct InventorySelfTest {
        let name: String
        let passed: Bool
    }

    private static let requiredCompilerEvidenceIDs = [
        "COMPILER-01-DUPLICATE-RESULT-TYPES",
        "COMPILER-02-APIKEYS-CLAIM-SIGNATURE",
        "COMPILER-03-DEBRID-TYPED-READ",
        "COMPILER-04-TRAKT-OVERLAY",
    ]

    private static let requiredBehaviorRedIDs = [
        "BEHAVIOR-01-POINTER-BEFORE-OUTBOX",
        "BEHAVIOR-02-DEVICE-ACK-ROLLBACK",
        "BEHAVIOR-03-REFRESH-DELIVERY-ACK",
        "BEHAVIOR-04-SYNC-ADOPTION-SETTLEMENT",
        "BEHAVIOR-05-INVALIDATION-MARKER-SPLIT",
        "BEHAVIOR-06-NONCE-BEFORE-ADMISSION",
    ]

    static func main() {
        let expectRed = CommandLine.arguments.contains("--expect-red")
        let selfTestOnly = CommandLine.arguments.contains("--self-test")
        let selfTests = inventorySelfTests()
        for test in selfTests {
            print("\(test.passed ? "SELF_PASS" : "SELF_FAIL") \(test.name)")
        }
        guard selfTests.allSatisfy(\.passed) else {
            Foundation.exit(2)
        }
        if selfTestOnly {
            print("SELF_TEST_GREEN fixed credential composition inventory")
            Foundation.exit(0)
        }

        do {
            let lanes = try LanePaths()
            let result = try run(lanes: lanes)
            let inventoryFailures = validateInventory(checks: result.checks, probes: result.behaviorProbes)

            for check in result.checks {
                let status = check.passed ? "PASS" : "FAIL"
                print("\(status) \(check.id) \(check.name): \(check.detail)")
            }
            for probe in result.behaviorProbes {
                let status = !probe.sourceValid ? "INVALID" : (probe.isRed ? "RED" : "PASS")
                print("\(status) \(probe.id): \(probe.detail)")
            }

            if !inventoryFailures.isEmpty {
                for failure in inventoryFailures {
                    print("INVENTORY_FAIL \(failure)")
                }
                Foundation.exit(2)
            }
            let redProbes = result.behaviorProbes.filter(\.isRed)
            if expectRed {
                if canExitExpectedRed(checks: result.checks, probes: result.behaviorProbes) {
                    print("EXPECTED_RED compiler=4 behavior=6 fixed inventory demonstrated")
                    Foundation.exit(0)
                }
                print("EXPECTED_RED_REJECTED exact fixed inventory was not fully red")
                Foundation.exit(2)
            }
            if redProbes.isEmpty {
                print("GREEN credential composition gate")
                Foundation.exit(0)
            }
            Foundation.exit(1)
        } catch {
            print("HARNESS_ERROR \(error.localizedDescription)")
            Foundation.exit(2)
        }
    }

    private static func run(lanes: LanePaths) throws -> (checks: [Check], behaviorProbes: [BehaviorProbe]) {
        let credentialScope = try read(lanes.source(lanes.auth, "app/SourcesShared/CredentialScope.swift"))
        let keychain = try read(lanes.source(lanes.apiKeys, "app/SourcesShared/Keychain.swift"))
        let apiKeys = try read(lanes.source(lanes.apiKeys, "app/SourcesShared/ApiKeys.swift"))
        let debridKeys = try read(lanes.source(lanes.debrid, "app/SourcesShared/DebridKeys.swift"))
        let authTrakt = try read(lanes.source(lanes.auth, "app/SourcesShared/TraktAuth.swift"))
        let oauthTrakt = try read(lanes.source(lanes.oauth, "app/SourcesShared/TraktAuth.swift"))
        let syncManager = try read(lanes.source(lanes.auth, "app/SourcesShared/VortXSyncManager.swift"))
        let edgeAuth = try read(lanes.source(lanes.oauth, "cloudflare/oauth/src/edge_auth.ts"))
        let oauthWorker = try read(lanes.source(lanes.oauth, "cloudflare/oauth/src/index.ts"))

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("vortx-credential-composition-red-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let authScopePath = lanes.source(lanes.auth, "app/SourcesShared/CredentialScope.swift")
        let apiKeychainPath = lanes.source(lanes.apiKeys, "app/SourcesShared/Keychain.swift")
        let apiKeysPath = lanes.source(lanes.apiKeys, "app/SourcesShared/ApiKeys.swift")
        let debridPath = lanes.source(lanes.debrid, "app/SourcesShared/DebridKeys.swift")
        let authTraktPath = lanes.source(lanes.auth, "app/SourcesShared/TraktAuth.swift")
        let oauthTraktPath = lanes.source(lanes.oauth, "app/SourcesShared/TraktAuth.swift")

        let rawDuplicate = try typecheck([authScopePath, apiKeychainPath])

        let diagnosticKeychain = scratch.appendingPathComponent("KeychainWithoutDuplicateResults.swift")
        try strippedKeychainResultTypes(from: keychain).write(to: diagnosticKeychain, atomically: true, encoding: .utf8)

        let staleApiKeys = try typecheck([authScopePath, diagnosticKeychain, apiKeysPath])
        let staleDebrid = try typecheck([authScopePath, diagnosticKeychain, debridPath])

        let renamedOAuthTrakt = scratch.appendingPathComponent("OAuthTraktAuth.swift")
        try FileManager.default.copyItem(at: oauthTraktPath, to: renamedOAuthTrakt)
        let rawAuthOverlay = try typecheck([authTraktPath, renamedOAuthTrakt])

        let checks = [
            Check(
                id: "COMPILER-01-DUPLICATE-RESULT-TYPES",
                name: "real-source duplicate credential result declarations",
                passed: rawDuplicate.status != 0
                    && rawDuplicate.output.contains("invalid redeclaration of 'CredentialMutationResult'")
                    && rawDuplicate.output.contains("invalid redeclaration of 'CredentialDurableReadResult'"),
                detail: "CredentialScope.swift + Keychain.swift compile against their real lane bodies"
            ),
            Check(
                id: "COMPILER-02-APIKEYS-CLAIM-SIGNATURE",
                name: "real-source stale ApiKeys claim closure",
                passed: staleApiKeys.status != 0
                    && staleApiKeys.output.contains("extra argument 'read' in call")
                    && staleApiKeys.output.contains("missing argument for parameter 'durableRead' in call"),
                detail: "ApiKeys still calls the old claim label after duplicate-only diagnostic removal"
            ),
            Check(
                id: "COMPILER-03-DEBRID-TYPED-READ",
                name: "real-source typed debrid storage incompatibility",
                passed: staleDebrid.status != 0
                    && staleDebrid.output.contains("cannot convert return expression of type 'CredentialDurableReadResult' to return type 'String'")
                    && staleDebrid.output.contains("missing argument for parameter 'durableRead' in call"),
                detail: "Debrid still treats Keychain.confirmedString as String? and uses the old claim label"
            ),
            Check(
                id: "COMPILER-04-TRAKT-OVERLAY",
                name: "real-source auth broker overlay incompatibility",
                passed: rawAuthOverlay.status != 0
                    && rawAuthOverlay.output.contains("invalid redeclaration of 'TraktAuth'")
                    && rawAuthOverlay.output.contains("extra argument 'clientSecret' in call")
                    && rawAuthOverlay.output.contains("missing argument for parameter 'brokerBase' in call"),
                detail: "the security and broker TraktAuth bodies cannot be overlaid mechanically"
            ),
        ]

        var behaviorProbes: [BehaviorProbe] = []

        // Behavior RED 1: transition can durably select B before an outbox intent is durable. The follow-on
        // implementation must decide the exact recovery protocol; this harness intentionally does not choose it.
        let activationWindow = sourceSlice(
            credentialScope,
            from: "var activePointerWon = true",
            to: "return .activated(active)"
        )
        behaviorProbes.append(BehaviorProbe(
            id: "BEHAVIOR-01-POINTER-BEFORE-OUTBOX",
            sourceValid: activationWindow != nil,
            isRed: activationWindow.map {
                occursInOrder($0, ["account: activePointer", "CredentialPublicationOutbox.prepare("])
            } ?? false,
            detail: "pointer-before-outbox crash boundary: a durable active pointer precedes outbox preparation"
        ))

        // Behavior RED 2: a delivery ACK can be accepted remotely, then a cancellation/error path rolls local
        // activation back. The required durable delivery protocol is intentionally left to the pending consensus.
        let authorizedPoll = sourceSlice(
            oauthTrakt,
            from: "private func completeAuthorizedPoll(",
            to: "/// Run the full polling loop"
        )
        behaviorProbes.append(BehaviorProbe(
            id: "BEHAVIOR-02-DEVICE-ACK-ROLLBACK",
            sourceValid: authorizedPoll != nil,
            isRed: authorizedPoll.map {
                occursInOrder($0, [
                    "try await acknowledgeDelivery(session: session, deliveryID: deliveryID)",
                    "catch {",
                    "rollbackCredentialActivation(activation)",
                ])
            } ?? false,
            detail: "device-delivery ACK/cancellation ambiguity: acknowledged delivery can enter local rollback"
        ))

        // Behavior RED 3: refresh rotates a broker token but carries no durable delivery/retry identity distinct
        // from the in-memory single-flight task.
        let refreshWindow = sourceSlice(
            oauthTrakt,
            from: "private struct BrokerRefreshResponse",
            to: "/// A refresh POST got a 401"
        )
        let refreshSuccess = refreshWindow.flatMap {
            sourceSlice(
                $0,
                from: "if response.status == \"ok\" {",
                to: "guard response.status == \"invalid_grant\" else {"
            )
        }
        let refreshSourceValid = refreshWindow != nil && refreshSuccess != nil
        let refreshResponseDecoded = refreshWindow?.contains(
            "let response = try decode(BrokerRefreshResponse.self, from: data)"
        ) == true
        let immediateRefreshDeliveryGap = refreshSuccess.map(refreshSuccessHasDeliveryGap) ?? false
        behaviorProbes.append(BehaviorProbe(
            id: "BEHAVIOR-03-REFRESH-DELIVERY-ACK",
            sourceValid: refreshSourceValid,
            isRed: refreshResponseDecoded && immediateRefreshDeliveryGap,
            detail: "refresh response stores and returns the rotated token without an awaited durable delivery/ACK settlement"
        ))

        // Behavior RED 4: sync launches provider adoption as detached Tasks and commits the document version in
        // the enclosing synchronous apply. A provider failure therefore has no durable per-field replay gate.
        let syncDown = sourceSlice(
            syncManager,
            from: "func syncDown(",
            to: "/// Hydrate the engine from the VortX account's OWNED add-ons"
        )
        let traktAdoption = syncDown.flatMap {
            sourceSlice(
                $0,
                from: "if let a = keys[\"traktAccess\"]",
                to: "if let a = keys[\"simklAccess\"]"
            )
        }
        let simklAdoption = syncDown.flatMap {
            sourceSlice(
                $0,
                from: "if let a = keys[\"simklAccess\"]",
                to: "// Media servers (lane E):"
            )
        }
        let versionStamp = "lastSyncedVersion = max(lastSyncedVersion, pulled.version)"
        let syncSourceValid = syncDown != nil
            && traktAdoption != nil
            && simklAdoption != nil
            && syncDown?.contains(versionStamp) == true
        let providersPrecedeVersion = syncDown.map {
            occursInOrder($0, [
                "await TraktAuth.shared.adoptTokens",
                "await SIMKLAuth.shared.adoptTokens",
                versionStamp,
            ])
        } ?? false
        let detachedTrakt = traktAdoption.map {
            unstructuredTaskWrapsAwait($0, call: "await TraktAuth.shared.adoptTokens")
        } ?? false
        let detachedSIMKL = simklAdoption.map {
            unstructuredTaskWrapsAwait($0, call: "await SIMKLAuth.shared.adoptTokens")
        } ?? false
        behaviorProbes.append(BehaviorProbe(
            id: "BEHAVIOR-04-SYNC-ADOPTION-SETTLEMENT",
            sourceValid: syncSourceValid,
            isRed: providersPrecedeVersion && (detachedTrakt || detachedSIMKL),
            detail: "provider adoption runs in unstructured Tasks before the pull version is stamped"
        ))

        // Behavior RED 5: invalidation lives in UserDefaults, independently of the secure/file backend that
        // stores the actual credential. A marker loss can make a stale value visible again after restart.
        behaviorProbes.append(BehaviorProbe(
            id: "BEHAVIOR-05-INVALIDATION-MARKER-SPLIT",
            sourceValid: true,
            isRed: keychain.contains("UserDefaults.standard.set(true, forKey: invalidationKey(account))")
                && keychain.contains("UserDefaults.standard.removeObject(forKey: invalidationKey(account))"),
            detail: "invalidation-marker durability split: marker state is outside the credential backend"
        ))

        // Behavior RED 6: edge verification claims a nonce before the request dispatcher applies rate admission.
        // An extracted signing key can therefore consume nonce capacity before provider admission rejects it.
        behaviorProbes.append(BehaviorProbe(
            id: "BEHAVIOR-06-NONCE-BEFORE-ADMISSION",
            sourceValid: true,
            isRed: edgeAuth.contains("const claim = await claimNonce(env, nonce)")
                && occursInOrder(oauthWorker, [
                    "const verified = await verifyOAuthV2",
                    "const admission = await admitBeforeProvider",
                ]),
            detail: "nonce admission ordering: valid HMAC requests claim nonce capacity before rate admission"
        ))

        // Keep the source inputs live in this compiler harness. These reads make accidental lane substitution
        // visible to the source-contract stage even if a compiler diagnostic happens to change wording.
        _ = apiKeys
        _ = debridKeys
        _ = authTrakt

        return (checks, behaviorProbes)
    }

    private static func validateInventory(checks: [Check], probes: [BehaviorProbe]) -> [String] {
        var failures: [String] = []
        let compilerIDs = checks.map(\.id)
        let behaviorIDs = probes.map(\.id)

        if compilerIDs.count != requiredCompilerEvidenceIDs.count
            || Set(compilerIDs) != Set(requiredCompilerEvidenceIDs) {
            failures.append(
                "compiler IDs must be exactly \(requiredCompilerEvidenceIDs.sorted()); got \(compilerIDs.sorted())"
            )
        }
        if Set(compilerIDs).count != compilerIDs.count {
            failures.append("compiler IDs contain a duplicate")
        }
        for check in checks where !check.passed {
            failures.append("compiler evidence did not pass: \(check.id)")
        }

        if behaviorIDs.count != requiredBehaviorRedIDs.count
            || Set(behaviorIDs) != Set(requiredBehaviorRedIDs) {
            failures.append(
                "behavior IDs must be exactly \(requiredBehaviorRedIDs.sorted()); got \(behaviorIDs.sorted())"
            )
        }
        if Set(behaviorIDs).count != behaviorIDs.count {
            failures.append("behavior IDs contain a duplicate")
        }
        for probe in probes where !probe.sourceValid {
            failures.append("behavior source anchors are invalid: \(probe.id)")
        }
        return failures
    }

    private static func canExitExpectedRed(checks: [Check], probes: [BehaviorProbe]) -> Bool {
        validateInventory(checks: checks, probes: probes).isEmpty
            && Set(probes.filter(\.isRed).map(\.id)) == Set(requiredBehaviorRedIDs)
            && probes.count == requiredBehaviorRedIDs.count
    }

    private static func inventorySelfTests() -> [InventorySelfTest] {
        let checks = requiredCompilerEvidenceIDs.map {
            Check(id: $0, name: "self-test", passed: true, detail: "self-test")
        }
        let probes = requiredBehaviorRedIDs.map {
            BehaviorProbe(id: $0, sourceValid: true, isRed: true, detail: "self-test")
        }

        var renamedChecks = checks
        renamedChecks[0] = Check(
            id: "COMPILER-RENAMED",
            name: renamedChecks[0].name,
            passed: renamedChecks[0].passed,
            detail: renamedChecks[0].detail
        )
        var renamedProbes = probes
        renamedProbes[0] = BehaviorProbe(
            id: "BEHAVIOR-RENAMED",
            sourceValid: renamedProbes[0].sourceValid,
            isRed: renamedProbes[0].isRed,
            detail: renamedProbes[0].detail
        )
        var failedChecks = checks
        failedChecks[0] = Check(
            id: failedChecks[0].id,
            name: failedChecks[0].name,
            passed: false,
            detail: failedChecks[0].detail
        )
        var invalidProbes = probes
        invalidProbes[0] = BehaviorProbe(
            id: invalidProbes[0].id,
            sourceValid: false,
            isRed: invalidProbes[0].isRed,
            detail: invalidProbes[0].detail
        )
        var nonRedProbes = probes
        nonRedProbes[0] = BehaviorProbe(
            id: nonRedProbes[0].id,
            sourceValid: nonRedProbes[0].sourceValid,
            isRed: false,
            detail: nonRedProbes[0].detail
        )

        return [
            InventorySelfTest(
                name: "exact fixed inventory accepts EXPECTED_RED",
                passed: canExitExpectedRed(checks: checks, probes: probes)
            ),
            InventorySelfTest(
                name: "removed compiler evidence is rejected",
                passed: !canExitExpectedRed(checks: Array(checks.dropLast()), probes: probes)
            ),
            InventorySelfTest(
                name: "renamed compiler evidence is rejected",
                passed: !canExitExpectedRed(checks: renamedChecks, probes: probes)
            ),
            InventorySelfTest(
                name: "removed behavior probe is rejected",
                passed: !canExitExpectedRed(checks: checks, probes: Array(probes.dropLast()))
            ),
            InventorySelfTest(
                name: "renamed behavior probe is rejected",
                passed: !canExitExpectedRed(checks: checks, probes: renamedProbes)
            ),
            InventorySelfTest(
                name: "failed compiler evidence is rejected",
                passed: !canExitExpectedRed(checks: failedChecks, probes: probes)
            ),
            InventorySelfTest(
                name: "invalid behavior source anchors are rejected",
                passed: !canExitExpectedRed(checks: checks, probes: invalidProbes)
            ),
            InventorySelfTest(
                name: "unobserved behavior RED is rejected",
                passed: !canExitExpectedRed(checks: checks, probes: nonRedProbes)
            ),
            InventorySelfTest(
                name: "refresh probe detects immediate store and return",
                passed: refreshSuccessHasDeliveryGap(
                    """
                    guard let token = response.token else {
                        throw Error.invalid
                    }
                    guard storeRefreshedToken(token) else {
                        throw Error.persistence
                    }
                    return token
                    """
                )
            ),
            InventorySelfTest(
                name: "refresh probe accepts a direct awaited settlement",
                passed: !refreshSuccessHasDeliveryGap(
                    """
                    guard let token = response.token else {
                        throw Error.invalid
                    }
                    try await settle(response)
                    guard storeRefreshedToken(token) else {
                        throw Error.persistence
                    }
                    return token
                    """
                )
            ),
            InventorySelfTest(
                name: "refresh probe ignores an unrelated earlier await",
                passed: refreshSuccessHasDeliveryGap(
                    """
                    await unrelatedWork()
                    guard let token = response.token else {
                        throw Error.invalid
                    }
                    guard storeRefreshedToken(token) else {
                        throw Error.persistence
                    }
                    return token
                    """
                )
            ),
            InventorySelfTest(
                name: "refresh probe ignores await text in a comment",
                passed: refreshSuccessHasDeliveryGap(
                    """
                    guard let token = response.token else {
                        throw Error.invalid
                    }
                    // await settlement is not implemented
                    guard storeRefreshedToken(token) else {
                        throw Error.persistence
                    }
                    return token
                    """
                )
            ),
            InventorySelfTest(
                name: "sync probe detects an unstructured Task await",
                passed: unstructuredTaskWrapsAwait(
                    "Task { await Provider.adopt() }",
                    call: "await Provider.adopt()"
                )
            ),
            InventorySelfTest(
                name: "sync probe accepts a direct await",
                passed: !unstructuredTaskWrapsAwait(
                    "await Provider.adopt()",
                    call: "await Provider.adopt()"
                )
            ),
            InventorySelfTest(
                name: "sync probe ignores an unrelated completed Task before direct await",
                passed: !unstructuredTaskWrapsAwait(
                    "Task { await Other.work() }\nawait Provider.adopt()",
                    call: "await Provider.adopt()"
                )
            ),
            InventorySelfTest(
                name: "sourceSlice returns its bounded region",
                passed: sourceSlice("prefix START body END suffix", from: "START", to: "END") == "START body END"
            ),
            InventorySelfTest(
                name: "sourceSlice rejects a missing start anchor",
                passed: sourceSlice("prefix body END suffix", from: "START", to: "END") == nil
            ),
            InventorySelfTest(
                name: "sourceSlice rejects a missing end anchor",
                passed: sourceSlice("prefix START body suffix", from: "START", to: "END") == nil
            ),
        ]
    }

    private static func read(_ url: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { throw HarnessError.missingSource(url.path) }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func typecheck(_ sources: [URL]) throws -> CompilerResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["swiftc", "-typecheck"] + sources.map(\.path)
        let diagnostics = FileManager.default.temporaryDirectory
            .appendingPathComponent("vortx-credential-composition-diagnostics-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: diagnostics.path, contents: nil)
        let handle = try FileHandle(forWritingTo: diagnostics)
        process.standardOutput = handle
        process.standardError = handle
        do {
            try process.run()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: diagnostics)
            throw HarnessError.compilerLaunch(error.localizedDescription)
        }
        process.waitUntilExit()
        try handle.close()
        let output = (try? String(contentsOf: diagnostics, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(at: diagnostics)
        return CompilerResult(status: process.terminationStatus, output: output)
    }

    private static func strippedKeychainResultTypes(from source: String) throws -> String {
        var result = source
        for name in ["CredentialDurableReadResult", "CredentialMutationResult"] {
            let marker = "enum \(name):"
            guard let declaration = result.range(of: marker),
                  let openingBrace = result.range(of: "{", range: declaration.lowerBound..<result.endIndex)
            else {
                throw HarnessError.malformedSource("missing \(marker)")
            }
            var depth = 0
            var cursor = openingBrace.lowerBound
            var end: String.Index?
            while cursor < result.endIndex {
                let character = result[cursor]
                if character == "{" {
                    depth += 1
                } else if character == "}" {
                    depth -= 1
                    if depth == 0 {
                        end = result.index(after: cursor)
                        break
                    }
                }
                cursor = result.index(after: cursor)
            }
            guard var removalEnd = end else {
                throw HarnessError.malformedSource("unbalanced braces in \(marker)")
            }
            while removalEnd < result.endIndex, result[removalEnd].isWhitespace {
                removalEnd = result.index(after: removalEnd)
            }
            result.removeSubrange(declaration.lowerBound..<removalEnd)
        }
        return result
    }

    private static func occursInOrder(_ source: String, _ snippets: [String]) -> Bool {
        var cursor = source.startIndex
        for snippet in snippets {
            guard let range = source.range(of: snippet, range: cursor..<source.endIndex) else { return false }
            cursor = range.upperBound
        }
        return true
    }

    private static func refreshSuccessHasDeliveryGap(_ source: String) -> Bool {
        guard let token = source.range(of: "guard let token = response.token") else { return false }
        guard let tokenGuardEnd = closingBraceForGuard(in: source, startingAt: token.lowerBound) else { return false }
        let afterTokenGuard = source.index(after: tokenGuardEnd)
        guard let store = source.range(
            of: "guard storeRefreshedToken(token)",
            range: afterTokenGuard..<source.endIndex
        ) else { return false }
        guard containsOnlyWhitespaceAndComments(source[afterTokenGuard..<store.lowerBound]) else { return false }
        guard let storeGuardEnd = closingBraceForGuard(in: source, startingAt: store.lowerBound) else { return false }
        let afterStoreGuard = source.index(after: storeGuardEnd)
        guard let returned = source.range(
            of: "return token",
            range: afterStoreGuard..<source.endIndex
        ) else { return false }
        return containsOnlyWhitespaceAndComments(source[afterStoreGuard..<returned.lowerBound])
    }

    private static func unstructuredTaskWrapsAwait(_ source: String, call: String) -> Bool {
        var cursor = source.startIndex
        while cursor < source.endIndex,
              let task = source.range(of: "Task {", range: cursor..<source.endIndex) {
            let openingBrace = source.index(before: task.upperBound)
            guard let closingBrace = matchingClosingBrace(in: source, openingBrace: openingBrace) else {
                return false
            }
            let body = task.upperBound..<closingBrace
            if source.range(of: call, range: body) != nil {
                return true
            }
            cursor = source.index(after: closingBrace)
        }
        return false
    }

    private static func matchingClosingBrace(in source: String, openingBrace: String.Index) -> String.Index? {
        var depth = 0
        var cursor = openingBrace
        while cursor < source.endIndex {
            switch source[cursor] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return cursor }
            default: break
            }
            cursor = source.index(after: cursor)
        }
        return nil
    }

    private static func closingBraceForGuard(in source: String, startingAt start: String.Index) -> String.Index? {
        guard let elseClause = source.range(of: "else {", range: start..<source.endIndex) else { return nil }
        let openingBrace = source.index(before: elseClause.upperBound)
        return matchingClosingBrace(in: source, openingBrace: openingBrace)
    }

    private static func containsOnlyWhitespaceAndComments(_ source: Substring) -> Bool {
        removingSwiftComments(String(source)).allSatisfy(\.isWhitespace)
    }

    private static func removingSwiftComments(_ source: String) -> String {
        var result = ""
        var cursor = source.startIndex
        var blockDepth = 0

        while cursor < source.endIndex {
            let next = source.index(after: cursor)
            let hasNext = next < source.endIndex
            let character = source[cursor]
            let nextCharacter = hasNext ? source[next] : "\0"

            if blockDepth > 0 {
                if character == "/", nextCharacter == "*" {
                    blockDepth += 1
                    cursor = source.index(after: next)
                } else if character == "*", nextCharacter == "/" {
                    blockDepth -= 1
                    cursor = source.index(after: next)
                } else {
                    cursor = next
                }
                continue
            }

            if character == "/", nextCharacter == "/" {
                cursor = source.index(after: next)
                while cursor < source.endIndex, source[cursor] != "\n" {
                    cursor = source.index(after: cursor)
                }
                if cursor < source.endIndex {
                    result.append("\n")
                    cursor = source.index(after: cursor)
                }
                continue
            }
            if character == "/", nextCharacter == "*" {
                blockDepth = 1
                cursor = source.index(after: next)
                continue
            }

            result.append(character)
            cursor = next
        }
        return result
    }

    private static func sourceSlice(_ source: String, from start: String, to end: String) -> String? {
        guard let startRange = source.range(of: start) else { return nil }
        guard let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex) else { return nil }
        return String(source[startRange.lowerBound..<endRange.upperBound])
    }
}
