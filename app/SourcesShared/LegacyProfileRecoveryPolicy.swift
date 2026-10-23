import Foundation
import CoreFoundation

/// Legacy datastore writes have no compare-and-swap against the exact observed payload.
/// Retaining a local copy alone is therefore not authority to erase a remote repair source.
enum LegacyProfileRecoveryPolicy {
    static let recoveryNotice = "Older Stremio history needs a safe recovery. Its original records have not been changed. Keep this account connected and contact support for an export before repairing it."
    static let mirrorNotice = "The Stremio history mirror is paused because the complete history exceeds its 120-title limit. No local or remote history was removed. Keep using VortX, or contact support to export the complete history."
    enum Failure: Error { case mirrorCapacity }
    enum MirrorResult: Sendable { case unavailable, capacity, offered }
    /// At most one live binding and two independent warning kinds, never a growing history.
    /// Changing authority retires status only; it is not a recovery/data acknowledgement.
    struct Notices<Owner: Equatable & Sendable>: Sendable {
        private var owner: Owner?
        private var recovery: String?
        private var capacity: String?
        private mutating func bind(_ current: Owner) {
            guard owner != current else { return }
            owner = current; recovery = nil; capacity = nil
        }
        mutating func inspected(_ result: Recovery, owner: Owner) {
            bind(owner)
            recovery = LegacyProfileRecoveryPolicy.notice(after: result, previous: recovery)
        }
        mutating func mirrored(_ result: MirrorResult, owner: Owner) {
            bind(owner)
            switch result {
            case .unavailable: break
            case .capacity: capacity = mirrorNotice
            case .offered: capacity = nil
            }
        }
        func visible(for current: Owner?) -> String? {
            guard let current else { return nil }
            return visible(matching: { $0 == current })
        }
        func visible(matching isCurrent: (Owner) -> Bool) -> String? {
            // No ownership work at all when there is no warning to present.
            guard let notice = recovery ?? capacity, let owner, isCurrent(owner) else { return nil }
            return notice
        }
    }
    /// DatastorePut uses APIResult<SuccessResponse>: one result tag, whose success is a
    /// JSON Boolean true (not NSNumber 1, a string, or an empty collection). This recognizes
    /// the response contract only; it is not readback or durable remote adoption evidence.
    static func mirrorOfferCompleted(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["result"], let result = object["result"] as? [String: Any],
              let success = result["success"] as? NSNumber,
              CFGetTypeID(success) == CFBooleanGetTypeID() else { return false }
        return success.boolValue
    }
    static func completeMirrorPayload<Row: Encodable>(_ watch: [String: Row]) throws -> Data {
        guard watch.count <= 120 else { throw Failure.mirrorCapacity }
        return try JSONEncoder().encode(watch)
    }
    struct Recovery: Sendable {
        let salvaged: [String: String]
        let requiresSafeRepair: Bool
        let inspectionSucceeded: Bool
        init(salvaged: [String: String], requiresSafeRepair: Bool, inspectionSucceeded: Bool = true) {
            self.salvaged = salvaged; self.requiresSafeRepair = requiresSafeRepair
            self.inspectionSucceeded = inspectionSucceeded
        }
        static let unavailable = Recovery(salvaged: [:], requiresSafeRepair: false, inspectionSucceeded: false)
    }
    static func inspection(_ data: Data?) -> Recovery {
        guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["error"] == nil || object["error"] is NSNull,
              let items = object["result"] as? [[String: Any]],
              items.allSatisfy({ ($0["_id"] as? String)?.isEmpty == false }) else { return .unavailable }
        return recovery(items)
    }
    static func notice(after recovery: Recovery, previous: String?) -> String? {
        guard recovery.inspectionSucceeded else { return previous }
        if recovery.requiresSafeRepair { return recoveryNotice }
        return previous == recoveryNotice ? nil : previous
    }
    static func recovery(_ items: [[String: Any]]) -> Recovery {
        var exact: [String: String] = [:]
        var ambiguous = Set<String>()
        var requiresRepair = false
        for item in items {
            guard let id = item["_id"] as? String, id.hasPrefix("stremiox:") else { continue }
            guard let watched = (item["state"] as? [String: Any])?["watched"] as? String else {
                requiresRepair = true; continue
            }
            guard !watched.isEmpty else { continue }
            requiresRepair = true
            // An ambiguous same-ID source is not a reason to choose one spelling. All originals
            // stay remote; no conflicting spelling may be selected by an export/recovery caller.
            guard !ambiguous.contains(id) else { continue }
            if let previous = exact[id], Data(previous.utf8) != Data(watched.utf8) {
                exact.removeValue(forKey: id); ambiguous.insert(id)
            } else { exact[id] = watched }
        }
        return Recovery(salvaged: exact, requiresSafeRepair: requiresRepair)
    }
}
