import Foundation

/// Application notifications arrive after their Bridge/facade/source locks are released. The
/// posting call cannot finish while the original read token remains active. No queued delivery.
enum CurationReadContextDelivery {
    nonisolated static func perform(_ operation: @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { operation() }
        } else {
            DispatchQueue.main.sync { operation() }
        }
    }
}

/// A single pre-await capture. The closures retain only that original authority; observation can
/// compare or retire it but cannot obtain a replacement target. Injection supports lifecycle tests
/// against this production owner without a live account, native install or credential-store write.
@MainActor struct CurationReadAuthority {
    let profileID: UUID
    let importRegisters: [String: VortxJSON]
    let isCurrent: @MainActor () -> Bool
    let currentImportRegisters: @MainActor () throws -> [String: VortxJSON]
    let retire: @MainActor () -> Void

    static func capture() throws -> Self {
        guard let profileID = ProfileStore.shared.activeID else { throw CurationFailure.staleContext }
        let credential = CredentialScopeRegistry.shared.capture()
        let signedIn = VortXSyncManager.shared.isSignedIn
        let accountIsCurrent: @MainActor () -> Bool = {
            ProfileStore.shared.activeID == profileID
                && VortXSyncManager.shared.isSignedIn == signedIn
                && CredentialScopeRegistry.shared.isCurrent(credential)
        }
        if !signedIn {
            return .init(profileID: profileID, importRegisters: [:], isCurrent: accountIsCurrent,
                         currentImportRegisters: { [:] }, retire: {})
        }
        let core = CoreBridge.shared
        let target = try core.captureNativeXperienceTarget()
        do {
            let original = try core.nativeXperienceSnapshot(target: target).registers
            guard accountIsCurrent(), core.nativeXperienceTargetIsCurrent(target) else {
                throw CurationFailure.staleContext
            }
            return .init(profileID: profileID, importRegisters: original,
                isCurrent: { accountIsCurrent() && core.nativeXperienceTargetIsCurrent(target) },
                currentImportRegisters: { try core.nativeXperienceSnapshot(target: target).registers },
                retire: { core.retireNativeXperienceTarget(target) })
        } catch {
            core.retireNativeXperienceTarget(target)
            throw error
        }
    }
}

/// Select only registers from the original snapshot. Full raw evidence includes the binding map,
/// deletion value and register metadata, not only the imported collection-document fingerprint.
enum CurationImportReadEvidence {
    static func binding(fingerprints: [String: String], original: [String: VortxJSON],
                        retaining pinned: [String: VortxJSON]) throws -> [String: VortxJSON] {
        var result = pinned
        for (importID, fingerprint) in fingerprints {
            guard let namespace = UUID(uuidString: importID), namespace.uuidString.lowercased() == importID else {
                throw CurationFailure.staleContext
            }
            let field = XperienceImportNamespace.field(namespace)
            guard let register = original[field] else { throw CurationFailure.staleContext }
            let saved = try XperienceSavedNamespace.read(field: field, register: register)
            guard saved.document.fingerprint == fingerprint else { throw CurationFailure.staleRevision }
            if let previous = result[field], !VortxNativeHostFieldEvidence.json(previous, register) {
                throw CurationFailure.staleRevision
            }
            result[field] = register
        }
        return result
    }

    static func matches(pinned: [String: VortxJSON], current: [String: VortxJSON]) -> Bool {
        pinned.allSatisfy { field, original in
            VortxNativeHostFieldEvidence.json(original, current[field])
        }
    }
}
