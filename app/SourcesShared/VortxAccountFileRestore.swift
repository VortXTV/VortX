import Foundation
import CryptoKit
import Darwin

enum VortxAccountFileRestoreFailure: String, Error, Sendable, LocalizedError {
    case accountChanged, cancelled, busy, currentNativeState, localStateUnverifiable
    case pendingLocalChanges, unsupportedFile, unsupportedAccountSource, invalidHostData
    case unavailable, noCloudBackup, modernAccount, staleHead, revisionUnavailable, recoveryUnavailable
    var errorDescription: String? {
        switch self {
        case .accountChanged: return "Your account changed before the restore could be submitted."
        case .cancelled: return "Restore was cancelled before submission."
        case .busy: return "Account work is still in progress. Wait for it to finish before restoring."
        case .currentNativeState: return "This account already has saved app data on this device. This version can restore only an older cloud backup before this device has loaded that account."
        case .localStateUnverifiable: return "The existing account recovery state could not be verified. It has been kept unchanged."
        case .pendingLocalChanges: return "This account has pending local changes or recovery work. Finish that work before restoring a backup."
        case .unsupportedFile: return "This file could not be fully validated for this restore version. It has been kept unchanged."
        case .unsupportedAccountSource: return "This file contains a profile with its own streaming account or account history this restore version cannot handle. It has been kept unchanged."
        case .invalidHostData: return "This backup contains settings or credentials that could not be admitted safely. It has been kept unchanged."
        case .unavailable: return "The current account backup could not be read. Check your connection and sign-in."
        case .noCloudBackup: return "This version needs an existing older cloud backup for the signed-in account before it can restore a file. This account has no cloud backup yet."
        case .modernAccount: return "This account already has newer or pending cloud data. This version restores files only to an older cloud backup before the account is loaded on this device."
        case .staleHead: return "The account changed while the file was being prepared. No restore was submitted."
        case .revisionUnavailable: return "The current account revision cannot accept this restore."
        case .recoveryUnavailable: return "A complete encrypted recovery copy could not be retained. No new restore was submitted."
        }
    }
}

enum VortxAccountFileRestoreResult: Sendable {
    case notSubmitted(VortxAccountFileRestoreFailure)
    case conflict(UUID)
    case deliveryUnconfirmed(UUID)
    case uploadAccepted(UUID)
    case serverConfirmed(UUID, revision: Int)
    // None of these cases claims a native checkpoint, provider apply, or profile mount.
}

/// Transport confirmation and historical local adoption are distinct facts.
enum VortxAccountFileRestoreStatus: Sendable {
    case available([VortxAccountFileRestore.OperationStatus])
    case accountChanged, recoveryUnavailable
}
enum VortxAccountFileRestoreLocalResult: Sendable {
    case localAdoptionRecorded(UUID, revision: Int)
    case pending(UUID, reason: VortxAccountFileRestore.LocalPendingReason), accountChanged, recoveryUnavailable
}

enum VortxAccountFileRestore {
    typealias Exact = OwnerHistoryExactJSON
    struct Prepared: Sendable {
        let selectedFile: Data
        let candidateFile: Data
        let plaintext: Data
        let headResponse: Data
        let headDocument: String
        let baseRevision: Int
        let scope: VortxAccountScope
    }
    struct Intent: Codable, Sendable {
        let format: String
        let sourceKind: String
        let operationID: UUID
        let accountID: String
        let ownerProfileID: String
        let selectedFile: Data
        let candidateFile: Data
        let replacedHeadResponse: Data
        let plaintextSHA256: String
        let baseRevision: Int
        let revision: Int
        let submittedDocument: String
    }
    enum Verdict: String, Codable, Sendable { case notSubmitted, conflict, deliveryUnconfirmed, uploadAccepted, serverConfirmed }
    struct Receipt: Codable, Sendable {
        let operationID: UUID
        let verdict: Verdict
        let revision: Int
    }
    enum LocalState: String, Sendable {
        case notSubmitted, conflict, deliveryUnconfirmed, uploadAccepted, serverConfirmed, localAdoptionRecorded
        var unresolved: Bool { self != .notSubmitted && self != .conflict && self != .localAdoptionRecorded }
    }
    enum LocalPendingReason: Equatable, Sendable { case receivePending, legacyProviderSettlementUnavailable }
    struct OperationStatus: Sendable, Equatable {
        let operationID: UUID
        let revision: Int
        let state: LocalState
        var pendingReason: LocalPendingReason = .receivePending
    }
    /// Existing-only status identifies source carriers still awaiting a full receive receipt.
    /// Presence does not disable Finish: only actual checked store settlement can complete them.
    static func hasUnacknowledgedProviderCarrier(_ plaintext: Data) -> Bool {
        guard let raw = try? OwnerHistoryExactJSON.Object(plaintext) else { return true }
        guard let keys = raw["apiKeys"] else { return false }
        guard let fields = try? OwnerHistoryExactJSON.Object(keys) else { return true }
        return fields["vortx.mediaServers"] != nil || fields["vortx.iptv"] != nil
    }
    /// Historical record only; never a replay, native checkpoint or current-session capability.
    struct LocalAdoption: Codable, Sendable {
        let format: String
        let operationID: UUID
        let accountID: String
        let scope: VortxAccountScope
        let revision: Int
        let plaintextSHA256: String
        let sealedIntentSHA256: String
        let observation: UUID
    }
    static func digest(_ data: Data) -> String { VortxAccountFileRepairService.digest(data) }
    static func head(_ response: Data) throws -> VortxAccountBackupFile.Inspection {
        try VortxAccountBackupFile.inspect(VortxAccountBackupFile.encodeServerResponse(response,
            username: "", now: Date(timeIntervalSince1970: 0)))
    }
    static func acceptedVerdict(status: Int, body: Data) -> Bool? {
        guard status == 200, body.count <= AuthenticatedHTTPTransport.controlResponseLimit,
              let raw = try? Exact.Object(body), let accepted = raw["accepted"] else { return nil }
        if accepted == Data("true".utf8) { return true }
        if accepted == Data("false".utf8) { return false }
        return nil // Duplicates, missing, string/number/null and transport failures are ambiguous.
    }
    static func confirms(_ response: Data, intent: Intent, key: Data) -> Bool {
        guard let stored = try? head(response), stored.version == intent.revision,
              let plaintext = VortXSyncCrypto.openDocument(dataKey: key, stored: stored.document,
                accountId: intent.accountID, version: stored.version),
              digest(plaintext) == intent.plaintextSHA256 else { return false }
        return true
    }
    static func prepare(file: Data, response: Data, input: VortxAccountFileRepairService.Input,
                        fence: VortxAccountFileRepairService.Fence, abi: any VortxRuntimeABI) throws -> Prepared {
        try fence.check()
        // The mode permits an actually validated reimport; it never regenerates selected native history.
        let repaired = try VortxAccountFileRepairService.prepare(file: file,
            authenticatedHeadResponse: response, input: input, fence: fence, abi: abi,
            permitValidatedReimport: true)
        let current = try head(response)
        guard let headPlaintext = VortXSyncCrypto.openDocument(dataKey: input.dataKey,
            stored: current.document, accountId: input.accountID, version: current.version) else {
            throw VortxAccountFileRestoreFailure.unavailable
        }
        let owner = try VortxAccountBackupRepair.legacyOwnerID(in: headPlaintext)
        let scope = VortxAccountScope(account: input.capture.namespace, ownerProfileID: owner.uuidString)
        let candidate = try VortxAccountBackupFile.inspect(repaired.file)
        guard let plaintext = VortXSyncCrypto.openDocument(dataKey: input.dataKey,
            stored: candidate.document, accountId: input.accountID, version: candidate.version) else {
            throw VortxAccountFileRestoreFailure.unsupportedFile
        }
        // Service.prepare invokes the shared complete admission before releasing this output.
        try fence.check()
        return Prepared(selectedFile: file, candidateFile: repaired.file, plaintext: plaintext,
            headResponse: response, headDocument: current.document, baseRevision: current.version, scope: scope)
    }
    /// Pure common gate: both Repair export and Restore use this exact full candidate admission.
    /// Owner comes from the independently authenticated GET, never from the selected file.
    @discardableResult
    static func admitCandidate(file: Data, input: VortxAccountFileRepairService.Input, owner: UUID,
                               fence: VortxAccountFileRepairService.Fence, abi: any VortxRuntimeABI) throws -> Data {
        try fence.check()
        let scope = VortxAccountScope(account: input.capture.namespace, ownerProfileID: owner.uuidString)
        let candidate = try VortxAccountBackupFile.inspect(file)
        guard let plaintext = VortXSyncCrypto.openDocument(dataKey: input.dataKey,
            stored: candidate.document, accountId: input.accountID, version: candidate.version) else {
            throw VortxAccountFileRestoreFailure.unsupportedFile
        }
        let raw = try Exact.Object(plaintext)
        _ = try VortxProfileOverlayWitness.decodeObject(json: plaintext)
        let nativeBytes = try raw.required("nativeSync")
        let native = try JSONDecoder().decode(VortxJSON.self, from: nativeBytes)
        // Input history survives byte-for-byte, including permitted later native edits. The cold
        // kernel validates the full candidate, then source-dependent bindings are checked in BOTH
        // input and normalized state so normalization cannot hide a dormant unsupported source.
        let state = try VortxNativeSession.detachedFileRestoreState(scope: scope,
            nativeSync: native, abi: abi)
        try requireSharedAccountSources(native, owner: scope.ownerProfileID)
        try requireSharedAccountSources(state, owner: scope.ownerProfileID)
        // Complete host inspection is deliberately strict. This is ephemeral validation, not an
        // authenticated bootstrap/source receipt. The journal retains the full original credentials.
        do { _ = try VortxNativeBootstrapArchive.encode(document: plaintext) }
        catch { throw VortxAccountFileRestoreFailure.invalidHostData }
        if let keys = raw["apiKeys"] {
            let object = try Exact.Object(keys)
            for (name, value) in object.fields {
                if name == "metadata" {
                    let metadata = try Exact.Object(value)
                    guard metadata.fields.values.allSatisfy({ (try? JSONDecoder().decode(String.self, from: $0)) != nil }) else {
                        throw VortxAccountFileRestoreFailure.invalidHostData
                    }
                } else if (try? JSONDecoder().decode(String.self, from: value)) == nil {
                    throw VortxAccountFileRestoreFailure.invalidHostData
                }
            }
        }
        _ = try OwnerHistoryAccountExport(completeAccountPlaintext: plaintext).validatedPlaintext(writeV2: true)
        try fence.check()
        return plaintext
    }
    /// This v1 has no independent streaming-account source admission. Inspect all account bindings
    /// in the complete known native carriers, including dormant slots/history, before publication.
    /// Unknown fields are retained, but unsupported recognized source carriers cannot be ignored.
    private static func requireSharedAccountSources(_ value: VortxJSON, owner: String, profileID: String? = nil, depth: Int = 0) throws {
        guard depth <= 64 else { throw VortxAccountFileRestoreFailure.unsupportedAccountSource }
        switch value {
        case .object(let fields):
            for key in ["ownerHistory", "nativeOwnerHistorySources", "nativeProviderCredentials", "authenticatedSourceArchive", "verifiedStreamingUid", "sourceDocumentBase64",
                        "ownAccountOverlayPending", "ownAccountOverlayQuarantine", "nativeLegacyMembershipPending",
                        "nativeWatchedMigrationEvidence", "nativeWatchedMigrationPending", "nativeWatchedMigrationSources"] where fields[key] != nil {
                throw VortxAccountFileRestoreFailure.unsupportedAccountSource
            }
            for key in ["ownAccountSources", "ownAccountSourceHistory"] {
                if let source = fields[key], source != .object([:]) { throw VortxAccountFileRestoreFailure.unsupportedAccountSource }
            }
            if let account = fields["account"] {
                if case .object(let binding) = account, let kind = binding["kind"] {
                    let ownerRecord = profileID == owner || (fields["id"] == .string(owner) && fields["owner"] == .bool(true))
                    let shared = kind == .string("shared") && (binding["value"] == nil || binding["value"] == .string(owner))
                    // The actual legacy producer uses local_only for the PRIMARY OWNER.
                    // It is not an independent streaming account or a missing-own fallback.
                    let primary = ownerRecord && kind == .string("local_only") && binding["value"] == nil
                    guard shared || primary else { throw VortxAccountFileRestoreFailure.unsupportedAccountSource }
                } else if case .string(let kind) = account,
                          ["own", "pending_own"].contains(kind) || (kind == "local_only" && profileID != owner) {
                    throw VortxAccountFileRestoreFailure.unsupportedAccountSource
                }
            }
            for (key, nested) in fields {
                let nestedProfile = UUID(uuidString: key)?.uuidString == key ? key : profileID
                try requireSharedAccountSources(nested, owner: owner, profileID: nestedProfile, depth: depth + 1)
            }
        case .array(let rows):
            for row in rows { try requireSharedAccountSources(row, owner: owner, profileID: profileID, depth: depth + 1) }
        default: break
        }
    }
}

actor VortxAccountFileRestoreWorker {
    static let shared = VortxAccountFileRestoreWorker()
    func prepare(file: Data, response: Data, input: VortxAccountFileRepairService.Input,
                 fence: VortxAccountFileRepairService.Fence) throws -> VortxAccountFileRestore.Prepared {
        try VortxAccountFileRestore.prepare(file: file, response: response, input: input, fence: fence, abi: VortxCABI())
    }
    func requireLocalAbsence(scope: VortxAccountScope, key: Data) throws {
        let root = try VortxNativeStorage.root(create: false)
        for parent in [root, root.appendingPathComponent("VortX")] {
            var info = stat()
            if Darwin.lstat(parent.path, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(), info.st_mode & mode_t(0o022) == 0 else {
                    throw VortxAccountFileRestoreFailure.localStateUnverifiable
                }
            } else if errno != ENOENT { throw VortxAccountFileRestoreFailure.localStateUnverifiable }
        }
        let directory = root.appendingPathComponent("VortX/native-engine-v1")
        let plainProbe = try VortxEncryptedCheckpointStore(directory: directory, key: SymmetricKey(data: key))
        do { try plainProbe.requireFileRestoreAbsence(scope: scope) }
        catch VortxEncryptedCheckpointStore.FileRestoreRefusal.currentNativeState {
            throw VortxAccountFileRestoreFailure.currentNativeState
        } catch {
            // An empty/missing inventory needs no installation-key access. Only existing other
            // account files need their already-published installation proofs to distinguish them.
            do {
                guard let existingKey = try VortxNativeInstallationKey.readExisting() else {
                    throw VortxAccountFileRestoreFailure.localStateUnverifiable
                }
                let indexedProbe = try VortxEncryptedCheckpointStore(directory: directory,
                    key: SymmetricKey(data: key), installationKey: existingKey)
                try indexedProbe.requireFileRestoreAbsence(scope: scope)
            } catch VortxEncryptedCheckpointStore.FileRestoreRefusal.currentNativeState {
                throw VortxAccountFileRestoreFailure.currentNativeState
            } catch { throw VortxAccountFileRestoreFailure.localStateUnverifiable }
        }
        do {
            try NativePreferenceIntentStore(directoryURL: root.appendingPathComponent("VortX/native-preference-intents"),
                key: key, namespace: scope.account).requireFileRestoreAbsence()
        } catch NativePreferenceIntentStore.FileRestoreRefusal.pending {
            throw VortxAccountFileRestoreFailure.pendingLocalChanges
        } catch { throw VortxAccountFileRestoreFailure.localStateUnverifiable }
    }
}
