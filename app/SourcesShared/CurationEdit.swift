import Foundation

/// The exact raw legacy register is also a prerequisite at the native transaction boundary.
/// Concurrent old-device deletion, replacement, rule edit or rename requires a fresh editor.
struct CurationNativeEdit: Sendable {
    let document: CurationDocument
    let expectedRegister: VortxJSON?
    let legacyRegister: VortxJSON
    var nativeEdit: VortxNativeHostFieldEdit {
        .init(field: document.field, expectedRegister: expectedRegister, value: document.raw)
    }
    func validateAdmission(_ fields: [String: VortxJSON]) throws {
        let field = SmartCollection.fieldPrefix + document.id
        guard VortxNativeHostFieldEvidence.json(fields[field], legacyRegister),
              let live = fields[field]?["value"], live != .null,
              live["id"] == .string(document.id),
              VortxNativeHostFieldEvidence.json(live["createdAt"], document.raw["legacyCreatedAt"]) else {
            throw CurationFailure.staleCollection
        }
    }
}

/// Keeps future legacy keys/rules intact when a current app edits known fields. This protects new
/// clients; shipped old clients still reserialize their old DTO, hence the separate rich register.
enum CurationLegacyPatch {
    static func applying(_ edited: SmartCollection, to raw: VortxJSON) throws -> VortxJSON {
        let baseline = try raw.decode(SmartCollection.self)
        guard edited.id == baseline.id, edited.createdAt == baseline.createdAt,
              case .object(var fields) = raw else { throw CurationFailure.staleCollection }
        if edited.name != baseline.name { fields["name"] = .string(edited.name) }
        if edited.home != baseline.home { fields["home"] = .bool(edited.home) }
        let oldRules = try ForYouSync.value(baseline.rules)
        let newRules = try ForYouSync.value(edited.rules)
        guard case .object(let old) = oldRules, case .object(let next) = newRules else {
            throw CurationFailure.invalidDocument
        }
        var rules: [String: VortxJSON] = [:]
        if case .object(let current) = fields["rules"] { rules = current }
        for key in Set(old.keys).union(next.keys) where
            !VortxNativeHostFieldEvidence.json(old[key], next[key]) {
            // nil on an OPTIONAL known rule removes that leaf only; unknown rules remain.
            rules[key] = next[key]
        }
        if baseline.rules != edited.rules { fields["rules"] = .object(rules) }
        let result = VortxJSON.object(fields)
        try ForYouSync.validate(edited.field, value: result)
        return result
    }
}

struct CurationEditSession {
    let id = UUID()
    let profileID: UUID
    let collection: SmartCollection
    let document: CurationDocument
    let legacyRegister: VortxJSON
    let companionRegister: VortxJSON?
    let target: CoreBridge.NativeXperienceTarget?
}

/// The existing editor's name/rules/Home/delete gesture owns its original raw register too.
/// A new collection allocates UUID/createdAt once before capture, never again on Save.
struct CurationLegacyEditSession {
    let id = UUID()
    let profileID: UUID
    let collection: SmartCollection
    let isNew: Bool
    let expectedRegister: VortxJSON?
    let target: CoreBridge.NativeXperienceTarget?
}

enum CurationLegacyEdit {
    static func update(_ collection: SmartCollection, original: SmartCollection,
                       expectedRegister: VortxJSON?) throws -> VortxNativeHostFieldEdit {
        guard collection.id == original.id, collection.createdAt == original.createdAt else {
            throw CurationFailure.staleCollection
        }
        let value: VortxJSON
        if let expectedRegister {
            guard let raw = expectedRegister["value"], raw != .null,
                  try raw.decode(SmartCollection.self) == original else { throw CurationFailure.staleCollection }
            value = try CurationLegacyPatch.applying(collection, to: raw)
        } else { value = try ForYouSync.value(collection) }
        try ForYouSync.validate(collection.field, value: value)
        return .init(field: collection.field, expectedRegister: expectedRegister, value: value)
    }
    static func deletion(_ original: SmartCollection, expectedRegister: VortxJSON?) throws -> VortxNativeHostFieldEdit {
        guard let expectedRegister, let raw = expectedRegister["value"], raw != .null,
              try raw.decode(SmartCollection.self) == original else { throw CurationFailure.staleCollection }
        return .init(field: original.field, expectedRegister: expectedRegister, value: .null)
    }
}
