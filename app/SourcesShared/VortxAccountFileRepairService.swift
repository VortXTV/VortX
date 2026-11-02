import Foundation
import CryptoKit

/// File preparation only. Inputs here are immutable values, not authentication capabilities.
/// Only VortXSyncManager establishes the actual HTTP/account witness and releases export bytes.
/// No cloud writer, filesystem, checkpoint, provider, settings or session writer is available here.
enum VortxAccountFileRepairService {
    typealias Exact = OwnerHistoryExactJSON
    static let lifetimeNanoseconds: UInt64 = 300_000_000_000

    enum Failure: Error, Sendable, LocalizedError {
        case busy, accountChanged, expired, unavailable, ownerUnavailable, currentAccountUnsupported
        case invalidFile, repairedCopyChanged, alreadyRepaired
        case conversion(VortxAccountBackupRepair.Failure)

        var errorDescription: String? {
            switch self {
            case .busy: return "Another backup file is being prepared. Finish or cancel it before continuing."
            case .accountChanged: return "Your account changed. Open Tools again before continuing."
            case .expired: return "This file preparation expired. Choose the file again."
            case .unavailable: return "The account backup could not be read. Check your connection and sign-in, then try again."
            case .ownerUnavailable: return "The current account backup cannot establish a complete owner profile. Your file is unchanged."
            case .currentAccountUnsupported: return "This account already uses native or pending recovery data. This repair tool currently requires a complete legacy account backup. Your file is unchanged."
            case .invalidFile: return "This backup could not be read safely. Your file is unchanged."
            case .repairedCopyChanged: return "This repaired copy does not match its retained original. Both files are unchanged."
            case .alreadyRepaired: return "This file already contains native account data and needs no new conversion. Your file is unchanged."
            case .conversion(let reason):
                switch reason {
                case .tooLarge: return "This backup is too large for this repair tool. Your file is unchanged."
                case .matchingAccountRequired, .cannotAuthenticate, .ownerMismatch:
                    return "This backup could not be verified for the signed-in account. Your file is unchanged."
                case .existingNativeRequiresTypedValidation:
                    return "This file contains native or pending recovery data that this repair tool cannot convert. Your file is unchanged."
                case .independentAccountUnsupported:
                    return "This backup includes a profile with its own streaming account. It needs account-source recovery before conversion. Your file is unchanged."
                case .queuedEditsRequireLiveReconciliation, .heldSourceUnits, .pendingSourceEvidence, .sourceRequiresReconciliation:
                    return "This backup has unresolved saved data that needs account recovery before conversion. Your file is unchanged."
                case .superseded: return "File preparation was cancelled or your account changed."
                default: return "This backup could not be converted safely. Your file is unchanged."
                }
            }
        }
    }

    struct Input: Sendable {
        let accountID: String
        let capture: CredentialScopeRegistry.Capture
        let dataKey: Data
        let requiresVersionBoundHead: Bool
    }
    struct Output: Sendable {
        let file: Data
        let fileSHA256: String
        let sourceSHA256: String
        let ownerWitnessSHA256: String
        let headVersion: Int
        let headWasVersionBound: Bool
        let profileCount: Int
        let nativeSchema: Int
    }
    struct Preview: Identifiable, Sendable {
        let id: UUID
        let profileCount: Int
        let nativeSchema: Int
        let fileBytes: Int
    }

    /// All mutable state is protected by lock. No closure into MainActor is called by the worker.
    /// Revocation/expiry cannot interrupt a synchronous ABI call, but forbids its eventual output.
    final class Fence: @unchecked Sendable {
        private let lock = NSLock()
        private var revoked = false
        private let capture: CredentialScopeRegistry.Capture
        private let registry: CredentialScopeRegistry
        private let now: @Sendable () -> UInt64
        private let deadline: UInt64
        // Internal registry/clock seams permit isolated synthetic lifetime tests. The manager
        // always uses the real shared registry and monotonic clock through these defaults.
        init(capture: CredentialScopeRegistry.Capture, registry: CredentialScopeRegistry = .shared,
             now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
            self.capture = capture; self.registry = registry; self.now = now
            let start = now()
            let limit = start.addingReportingOverflow(lifetimeNanoseconds)
            deadline = limit.overflow ? start : limit.partialValue
        }
        func revoke() { lock.lock(); revoked = true; lock.unlock() }
        func isActive() -> Bool {
            lock.lock(); let active = !revoked; lock.unlock()
            return active && now() < deadline && registry.isMigrationEligible(capture)
        }
        func check() throws {
            guard !Task.isCancelled else { throw CancellationError() }
            guard now() < deadline else { throw Failure.expired }
            guard isActive() else { throw Failure.accountChanged }
        }
    }

    /// Called only on the dedicated worker actor below. It performs no I/O.
    static func prepare(file: Data, authenticatedHeadResponse: Data, input: Input,
                        fence: Fence, abi: any VortxRuntimeABI) throws -> Output {
        try fence.check()
        guard file.count <= VortxAccountBackupFile.maximumFileBytes,
              authenticatedHeadResponse.count <= AuthenticatedHTTPTransport.snapshotResponseLimit else {
            throw Failure.conversion(.tooLarge)
        }
        guard let account = UUID(uuidString: input.accountID),
              input.accountID == account.uuidString.lowercased(),
              input.capture.scope == .account(account), input.dataKey.count == 32 else {
            throw Failure.accountChanged
        }
        let head: VortxAccountBackupFile.Inspection
        do {
            // Use the exact raw-response duplicate/revision/framing checks. This wrapper is
            // an interpretation only, never a new source receipt or user download.
            let envelope = try VortxAccountBackupFile.encodeServerResponse(authenticatedHeadResponse,
                username: "", now: Date(timeIntervalSince1970: 0))
            head = try VortxAccountBackupFile.inspect(envelope)
        } catch { throw Failure.ownerUnavailable }
        guard !input.requiresVersionBoundHead || head.usesVersionBoundEncryption,
              let headPlaintext = VortXSyncCrypto.openDocument(dataKey: input.dataKey,
                stored: head.document, accountId: input.accountID, version: head.version) else {
            throw Failure.ownerUnavailable
        }
        let owner: UUID
        do { owner = try VortxAccountBackupRepair.legacyOwnerID(in: headPlaintext) }
        catch VortxAccountBackupRepair.Failure.existingNativeRequiresTypedValidation {
            throw Failure.currentAccountUnsupported
        } catch { throw Failure.ownerUnavailable }
        try fence.check()
        let context = VortxAccountBackupRepair.Context(accountID: input.accountID,
            credentialCapture: input.capture, dataKey: input.dataKey, expectedOwnerProfileID: owner,
            ownerReceiptSHA256: digest(authenticatedHeadResponse))
        do {
            let raw = try Exact.Object(file)
            if raw[VortxAccountBackupRepair.repairKey] != nil {
                try validateReimport(file, context: context, fence: fence, abi: abi)
                // A compatible native candidate may contain further native history. Never
                // discard it by regenerating a file from the original, or call the metadata
                // proof that the candidate is exclusively a pristine cold conversion.
                throw Failure.alreadyRepaired
            }
            let candidate = try VortxAccountBackupRepair.convert(file, context: context,
                abi: abi, isCurrent: { fence.isActive() })
            try fence.check()
            return Output(file: candidate.file, fileSHA256: digest(candidate.file),
                sourceSHA256: candidate.sourceSHA256, ownerWitnessSHA256: context.ownerReceiptSHA256,
                headVersion: head.version, headWasVersionBound: head.usesVersionBoundEncryption,
                profileCount: candidate.profileCount, nativeSchema: candidate.nativeSchema)
        } catch let failure as Failure { throw failure }
        catch let failure as VortxAccountBackupRepair.Failure {
            try fence.check()
            throw Failure.conversion(failure)
        } catch is CancellationError { throw CancellationError() }
        catch { throw Failure.invalidFile }
    }

    /// This validates preserved source bytes and complete generic native compatibility, not
    /// historical provenance or an exclusive conversion-only native state. No output is minted.
    private static func validateReimport(_ file: Data, context: VortxAccountBackupRepair.Context,
                                        fence: Fence, abi: any VortxRuntimeABI) throws {
        try fence.check()
        let inspection = try VortxAccountBackupFile.inspect(file)
        let envelope = try Exact.Object(file)
        let manifest = try Exact.Object(envelope.required(VortxAccountBackupRepair.repairKey))
        let originalDocument = try manifest.text("originalFileDocument")
        guard inspection.usesVersionBoundEncryption, originalDocument.hasPrefix(VortXSyncCrypto.docV2Prefix),
              manifest["schemaVersion"] == Data("1".utf8),
              try manifest.text("sourceKind") == "user_selected_file",
              try manifest.text("conversion") == "legacy_to_native_cold_v1",
              let original = VortXSyncCrypto.openDocument(dataKey: context.dataKey,
                stored: originalDocument,
                accountId: VortxAccountBackupRepair.sourceArchiveDomain + context.accountID,
                version: inspection.version),
              original.count <= VortxAccountBackupFile.maximumFileBytes,
              try manifest.text("sourceSHA256") == digest(original) else { throw Failure.repairedCopyChanged }
        let originalInspection = try VortxAccountBackupFile.inspect(original)
        let originalEnvelope = try Exact.Object(original)
        guard originalEnvelope[VortxAccountBackupRepair.repairKey] == nil,
              originalInspection.version == inspection.version,
              Set(envelope.fields.keys) == Set(originalEnvelope.fields.keys).union([VortxAccountBackupRepair.repairKey]),
              originalEnvelope.fields.allSatisfy({ $0.key == "document" || envelope[$0.key] == $0.value }),
              let originalPlaintext = VortXSyncCrypto.openDocument(dataKey: context.dataKey,
                stored: originalInspection.document, accountId: context.accountID, version: originalInspection.version),
              let plaintext = VortXSyncCrypto.openDocument(dataKey: context.dataKey,
                stored: inspection.document, accountId: context.accountID, version: inspection.version),
              try manifest.text("candidatePlaintextSHA256") == digest(plaintext) else { throw Failure.repairedCopyChanged }
        _ = try VortxProfileOverlayWitness.decodeObject(json: plaintext)
        try VortxAccountBackupRepair.requireConservation(original: Exact.Object(originalPlaintext),
                                                        candidate: Exact.Object(plaintext))
        try fence.check()
        // Reuse ALL converter admission (roster, queued/held/pending/refused carriers and ABI).
        // The regenerated file is disposable. Its native clocks are NOT compared with the input.
        let regenerated = try VortxAccountBackupRepair.convert(original, context: context,
            abi: abi, isCurrent: { fence.isActive() })
        let rebuilt = try VortxAccountBackupFile.inspect(regenerated.file)
        guard let rebuiltPlaintext = VortXSyncCrypto.openDocument(dataKey: context.dataKey,
            stored: rebuilt.document, accountId: context.accountID, version: rebuilt.version) else {
            throw Failure.repairedCopyChanged
        }
        let regeneratedNative = try Exact.Object(Exact.Object(rebuiltPlaintext).required("nativeSync"))
        let sourceReceipt = try Exact.Object(regeneratedNative.required("legacyImport"))
        let material = try sourceReceipt.required("baseline")
        let nativeBytes = try Exact.Object(plaintext).required("nativeSync")
        let nativeRaw = try Exact.Object(nativeBytes)
        let schema = try JSONDecoder().decode(Int.self, from: nativeRaw.required("schemaVersion"))
        guard (1...5).contains(schema), nativeRaw["ownerHistory"] == nil,
              manifest["nativeSchema"] == nativeRaw["schemaVersion"],
              try nativeRaw.text("scope") == context.credentialCapture.namespace,
              try nativeRaw.text("ownerProfileId") == context.expectedOwnerProfileID.uuidString else {
            throw Failure.repairedCopyChanged
        }
        // Require the same admitted canonical source baseline before compatibility, so a
        // successful causal reconciliation of some DIFFERENT legacy source is insufficient.
        let candidateReceipt = try Exact.Object(nativeRaw.required("legacyImport"))
        guard try Exact.canonical(candidateReceipt.required("baseline")) == Exact.canonical(material) else {
            throw Failure.repairedCopyChanged
        }
        let native = try JSONDecoder().decode(VortxJSON.self, from: nativeBytes)
        let outcome = try VortxNativeSession.validateLegacyCompatibility(scope: .init(
            account: context.credentialCapture.namespace, ownerProfileID: context.expectedOwnerProfileID.uuidString),
            ownerName: "Owner", snapshot: nil, nativeSync: native, material: material, abi: abi)
        guard outcome == .accepted else { throw Failure.repairedCopyChanged }
        _ = try OwnerHistoryAccountExport(completeAccountPlaintext: plaintext).validatedPlaintext(writeV2: true)
        try fence.check()
    }

    static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

/// Serial actor-owned cold ABI work. Never instantiate the runtime on MainActor or pass a live handle.
actor VortxAccountFileRepairWorker {
    static let shared = VortxAccountFileRepairWorker()
    func prepare(file: Data, authenticatedHeadResponse: Data, input: VortxAccountFileRepairService.Input,
                 fence: VortxAccountFileRepairService.Fence) throws -> VortxAccountFileRepairService.Output {
        try VortxAccountFileRepairService.prepare(file: file, authenticatedHeadResponse: authenticatedHeadResponse,
            input: input, fence: fence, abi: VortxCABI())
    }
}
