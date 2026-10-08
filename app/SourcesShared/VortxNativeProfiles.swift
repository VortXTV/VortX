import Foundation

/// Presentation conversion only. Private-kernel profile fields always override the host baseline.
enum VortxNativeProfiles {
    private static let nativeKeys: Set<String> = ["id", "name", "isOwner", "pin", "isKids", "familyEdit", "accentID", "oled", "textScale", "disabledAddons", "usesOwnAccount"]

    /// The account-binding compare-and-swap receipt exported by nativeSync 4.  It is intentionally
    /// distinct from `UserProfile`: a UI boolean has neither an authenticated own-account carrier
    /// nor the causal revision needed to select an account slot.
    struct ExpectedAccountBinding: Sendable, Equatable {
        let account: VortxJSON
        let revision: VortxJSON
        let transactionID: String?

        fileprivate init(account: VortxJSON, revision: VortxJSON, transactionID: String?) throws {
            try validateAccount(account)
            guard let revisionValue = try? revision.decode(UInt64.self), revisionValue <= 9_007_199_254_740_991 else {
                throw VortxNativeError.invalidSnapshot
            }
            if let transactionID { try validateTransactionID(transactionID) }
            // Revision zero denotes the pre-transaction fallback only. Native receipts always
            // carry the transaction that produced every positive revision, so accepting either
            // mismatched form would manufacture a CAS parent that the kernel will reject.
            guard (revisionValue == 0) == (transactionID == nil) else { throw VortxNativeError.invalidSnapshot }
            self.account = account
            self.revision = revision
            self.transactionID = transactionID
        }

        var document: VortxJSON {
            .object(["account": account, "revision": revision,
                     "transactionId": transactionID.map(VortxJSON.string) ?? .null])
        }
    }

    /// Complete token-free carrier for a proven own-account rebind.  The authenticated host has
    /// already fenced its credential generation and exact raw source before constructing this.
    struct OwnAccountTarget: Sendable, Equatable {
        let verifiedStreamingUID: String
        let sourceDocumentSHA256: String
        let profileOverlaySHA256: String?
        let addons: VortxJSON
        let library: VortxJSON
        let watches: VortxJSON
        let identityLinks: VortxJSON

        init(verifiedStreamingUID: String, sourceDocumentSHA256: String, profileOverlaySHA256: String? = nil,
             addons: VortxJSON, library: VortxJSON, watches: VortxJSON, identityLinks: VortxJSON) throws {
            guard validUID(verifiedStreamingUID), sourceDocumentSHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                  profileOverlaySHA256 == nil || profileOverlaySHA256!.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                  exactObjectKeys(addons, ["items", "order", "intents"]), exactObjectKeys(library, ["items", "intents"]),
                  watches.array != nil, identityLinks.array != nil else { throw VortxNativeError.invalidSnapshot }
            self.verifiedStreamingUID = verifiedStreamingUID
            self.sourceDocumentSHA256 = sourceDocumentSHA256
            self.profileOverlaySHA256 = profileOverlaySHA256
            self.addons = addons; self.library = library; self.watches = watches; self.identityLinks = identityLinks
        }

        var document: VortxJSON {
            var source: [String: VortxJSON] = ["verifiedStreamingUid": .string(verifiedStreamingUID),
                                               "sourceDocumentSha256": .string(sourceDocumentSHA256)]
            if let profileOverlaySHA256 { source["profileOverlaySha256"] = .string(profileOverlaySHA256) }
            return .object(["kind": .string("own"), "carrier": .object([
                "source": .object(source),
                "addons": addons, "library": library, "watches": watches, "identityLinks": identityLinks
            ])])
        }
    }

    enum AccountRebindTarget: Sendable, Equatable {
        case pendingOwn
        case shared
        case own(OwnAccountTarget)

        var document: VortxJSON {
            switch self {
            case .pendingOwn: return .object(["kind": .string("pending_own")])
            case .shared: return .object(["kind": .string("shared")])
            case .own(let target): return target.document
            }
        }

        fileprivate var usesOwnAccount: Bool {
            switch self { case .shared: return false; case .pendingOwn, .own: return true }
        }
    }

    /// Caller-owned account-selection intent.  It must be captured before authentication/source
    /// work starts and reused for retry; this helper never manufactures a revision or transaction.
    struct AccountRebindRequest: Sendable, Equatable {
        let scope: String
        let ownerProfileID: String
        let transactionID: String
        let expected: ExpectedAccountBinding
        let target: AccountRebindTarget

        init(scope: String, ownerProfileID: String, transactionID: String,
             expected: ExpectedAccountBinding, target: AccountRebindTarget) throws {
            guard !scope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  UUID(uuidString: ownerProfileID)?.uuidString == ownerProfileID else { throw VortxNativeError.invalidSnapshot }
            try validateTransactionID(transactionID)
            self.scope = scope; self.ownerProfileID = ownerProfileID; self.transactionID = transactionID
            self.expected = expected; self.target = target
        }

        /// A new profile does not exist in the state read used to begin its staged candidate.  The
        /// engine defines its post-add binding exactly as local_only/revision-0/no transaction.
        static func initial(scope: String, ownerProfileID: String, transactionID: String,
                            target: AccountRebindTarget) throws -> AccountRebindRequest {
            try .init(scope: scope, ownerProfileID: ownerProfileID, transactionID: transactionID,
                      expected: .init(account: .object(["kind": .string("local_only")]), revision: .integer(0), transactionID: nil),
                      target: target)
        }
    }

    /// Reads the account CAS receipt without borrowing clocks from profile fields.  NativeSync 4
    /// is authoritative when it has an active slot; historical states use the exact roster account
    /// with the contract's revision-0/null fallback.
    static func expectedBinding(state: VortxJSON, profileID: UUID) throws -> ExpectedAccountBinding {
        let id = profileID.uuidString
        if let binding = state["nativeSync"]?["accountSlots"]?[id]?["activeBinding"] {
            guard case .object(let object) = binding, Set(object.keys) == ["account", "revision", "transactionId"],
                  let account = object["account"], let revision = object["revision"] else { throw VortxNativeError.invalidSnapshot }
            let transactionID: String?
            switch object["transactionId"] {
            case .null?: transactionID = nil
            case .string(let value)?: transactionID = value
            default: throw VortxNativeError.invalidSnapshot
            }
            return try .init(account: account, revision: revision, transactionID: transactionID)
        }
        guard let account = state["roster"]?["profiles"]?[id]?["account"] else { throw VortxNativeError.invalidSnapshot }
        return try .init(account: account, revision: .integer(0), transactionID: nil)
    }

    /// Extracts a complete material-2 source tuple for the exact profile.  It deliberately does
    /// not accept a root/global bucket or infer a proof from a UID.
    static func ownTarget(material: VortxJSON, profileID: UUID) throws -> OwnAccountTarget {
        let id = profileID.uuidString
        guard material["schemaVersion"] == .integer(2) || material["schemaVersion"] == .unsigned(2),
              let source = material["ownAccountSources"]?[id],
              case .object(let sourceObject) = source,
              Set(sourceObject.keys) == ["verifiedStreamingUid", "sourceDocumentSha256"]
                || Set(sourceObject.keys) == ["verifiedStreamingUid", "sourceDocumentSha256", "profileOverlaySha256"],
              case .string(let uid)? = sourceObject["verifiedStreamingUid"],
              case .string(let digest)? = sourceObject["sourceDocumentSha256"],
              let addons = material["addons"]?[id], let library = material["libraries"]?[id],
              let watches = material["watches"]?[id], let links = material["identityLinks"]?[id] else {
            throw VortxNativeError.invalidSnapshot
        }
        let witness: String?
        switch sourceObject["profileOverlaySha256"] {
        case nil: witness = nil
        case .string(let value)?: witness = value
        default: throw VortxNativeError.invalidSnapshot
        }
        return try .init(verifiedStreamingUID: uid, sourceDocumentSHA256: digest, profileOverlaySHA256: witness, addons: addons,
                         library: library, watches: watches, identityLinks: links)
    }

    /// Builds the only native action permitted to move an account binding.  The caller supplies a
    /// captured CAS receipt and proven target; no profile field is used as account authority.
    static func rebindAction(profileID: UUID, request: AccountRebindRequest) throws -> VortxJSON {
        return .object(["type": .string("rebind_profile_account"), "scope": .string(request.scope),
                        "ownerProfileId": .string(request.ownerProfileID), "profileId": .string(profileID.uuidString),
                        "transactionId": .string(request.transactionID), "expectedBinding": request.expected.document,
                        "target": request.target.document])
    }
    static func project(state: VortxJSON, host: VortxJSON, baseline: [UserProfile]) throws -> [UserProfile] {
        guard case .object(let records) = state["roster"]?["profiles"] else { throw VortxNativeError.invalidSnapshot }
        let prior = Dictionary(uniqueKeysWithValues: baseline.map { ($0.id.uuidString, $0) })
        let order = baseline.map { $0.id.uuidString } + records.keys.filter { prior[$0] == nil }.sorted()
        return try order.compactMap { id in
            guard let record = records[id], record["deleted"] != .bool(true) else { return nil }
            guard let uuid = UUID(uuidString: id), case .string(let name) = record["name"],
                  case .bool(let owner) = record["owner"] else { throw VortxNativeError.invalidSnapshot }
            let usesOwnAccount = try accountUsesOwn(record: record, isOwner: owner)
            let base = prior[id] ?? UserProfile(id: uuid, name: name, avatar: "🍿", isOwner: owner)
            guard case .object(var object) = try JSONDecoder().decode(VortxJSON.self, from: JSONEncoder().encode(base)) else { throw VortxNativeError.invalidSnapshot }
            if case .object(let registers) = host["profiles"]?[id]?["fields"] {
                for (key, register) in registers where !nativeKeys.contains(key) {
                    // Unknown safe fields are retained in the carrier, never applied to the UI.
                    guard ["avatar", "email", "playback", "discovery", "addonPreferences"].contains(key), let value = register["value"] else { continue }
                    if value == .null {
                        if key == "avatar" { object[key] = .string("🍿") } else { object.removeValue(forKey: key) }
                    } else { object[key] = value }
                }
            }
            object["id"] = .string(id); object["name"] = .string(name); object["isOwner"] = .bool(owner)
            object["usesOwnAccount"] = .bool(usesOwnAccount)
            object["pin"] = record["pin"] ?? .null
            object["isKids"] = record["parental"]?["kids"] ?? .bool(false)
            object["familyEdit"] = record["parental"]?["familyEdit"] ?? .bool(false)
            object["accentID"] = record["settings"]?["accent"] ?? .string("ember")
            if object["accentID"] == .null { object["accentID"] = .string("ember") }
            object["oled"] = record["settings"]?["oled"] ?? .bool(false)
            let scale = try record["settings"]?["textScale"]?.decode(UInt32.self) ?? 1000
            object["textScale"] = .number(Double(scale) / 1000)
            object["disabledAddons"] = record["settings"]?["disabledAddons"] ?? .array([])
            return try VortxJSON.object(object).decode(UserProfile.self)
        }
    }

    /// Native state is authoritative for the account binding. A host roster may retain display
    /// fields (including email), but it must never decide that a profile owns an independently
    /// authenticated streaming account or manufacture an `addons: own` bucket.
    private static func accountUsesOwn(record: VortxJSON, isOwner: Bool) throws -> Bool {
        guard case .object(let binding)? = record["account"], case .string(let kind)? = binding["kind"] else {
            // Schema-1/private-kernel account variants remain kernel-owned and are non-own to the
            // host. Do not reinterpret or reject a historical representation here.
            return false
        }
        switch kind {
        case "own":
            guard !isOwner, case .string(let uid) = binding["value"], validUID(uid),
                  record["addons"] == .string("own") || record["addons"] == .string("share_primary") else {
                throw VortxNativeError.invalidSnapshot
            }
            return true
        case "pending_own":
            // Pending-own has no UID by design.  It must never silently fall back to shared
            // add-ons, otherwise a profile awaiting first-open sign-in can observe another
            // person's resource membership.
            guard !isOwner, Set(binding.keys) == ["kind"], record["addons"] == .string("own") else {
                throw VortxNativeError.invalidSnapshot
            }
            return true
        default:
            return false
        }
    }
    static func mutation(_ desired: UserProfile, previous: UserProfile?, ownerID: String,
                         rebind: AccountRebindRequest? = nil) throws -> ([VortxJSON], VortxNativeHostPreferences.Edit) {
        guard desired.isOwner == (desired.id.uuidString == ownerID),
              desired.textScale.isFinite, desired.textScale > 0, desired.textScale <= 100,
              !desired.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw VortxNativeError.invalidSnapshot }
        if let rebind {
            guard !desired.isOwner, desired.usesOwnAccount == rebind.target.usesOwnAccount,
                  rebind.ownerProfileID == ownerID else { throw VortxNativeError.invalidSnapshot }
            if previous == nil {
                // The only valid initial CAS is the contract's post-add local-only binding.
                guard rebind.expected.account == .object(["kind": .string("local_only")]),
                      (try? rebind.expected.revision.decode(UInt64.self)) == 0, rebind.expected.transactionID == nil else {
                    throw VortxNativeError.invalidSnapshot
                }
            }
        } else {
            // An own-account bind/rebind is an authenticated, source-bound migration transaction.
            // Ordinary profile edits may preserve that binding, but may never create, clear, or move it.
            guard !desired.usesOwnAccount || (!desired.isOwner && previous?.usesOwnAccount == true),
                  previous.map({ $0.usesOwnAccount == desired.usesOwnAccount }) ?? !desired.usesOwnAccount else {
                throw VortxNativeError.invalidSnapshot
            }
        }
        if let pin = desired.pin, !pin.isEmpty {
            guard pin.range(of: "^sha256:[0-9a-fA-F]{64}$", options: .regularExpression) != nil else { throw VortxNativeError.invalidSnapshot }
        }
        var edits: [VortxJSON] = []
        func edit(_ field: String, _ value: VortxJSON, changed: Bool) { if changed { edits.append(.object(["field": .string(field), "value": value])) } }
        edit("name", .string(desired.name), changed: previous?.name != desired.name)
        edit("pin", desired.pin.flatMap { $0.isEmpty ? nil : .string($0) } ?? .null, changed: previous?.pin != desired.pin)
        edit("kids", .bool(desired.isKids), changed: previous?.isKids != desired.isKids)
        edit("familyEdit", .bool(desired.familyEdit), changed: previous?.familyEdit != desired.familyEdit)
        edit("accent", .string(desired.accentID), changed: previous?.accentID != desired.accentID)
        edit("oled", .bool(desired.oled), changed: previous?.oled != desired.oled)
        edit("textScale", .integer(Int64((desired.textScale * 1000).rounded())), changed: previous?.textScale != desired.textScale)
        let disabled = desired.addonPreferences?.disabledAddonURLsOverride ?? desired.disabledAddons ?? []
        let oldDisabled = previous?.addonPreferences?.disabledAddonURLsOverride ?? previous?.disabledAddons ?? []
        edit("disabledAddons", .array(disabled.map(VortxJSON.string)), changed: previous == nil || oldDisabled != disabled)
        var actions: [VortxJSON] = previous == nil ? [.object(["type": .string("add_profile"), "id": .string(desired.id.uuidString), "name": .string(desired.name)])] : []
        if !edits.isEmpty { actions.append(.object(["type": .string("patch_profile"), "id": .string(desired.id.uuidString), "edits": .array(edits)])) }
        if let rebind { actions.append(try rebindAction(profileID: desired.id, request: rebind)) }
        guard case .object(let next) = try JSONDecoder().decode(VortxJSON.self, from: JSONEncoder().encode(desired)) else { throw VortxNativeError.invalidSnapshot }
        let old = try previous.map { try JSONDecoder().decode(VortxJSON.self, from: JSONEncoder().encode($0)) }
        let oldKeys: [String] = if case .object(let object) = old { Array(object.keys) } else { [] }
        var host: [String: VortxJSON] = [:]
        for key in Set(next.keys).union(oldKeys).subtracting(nativeKeys) {
            if previous == nil || next[key] != old?[key] { host[key] = next[key] ?? .null }
        }
        return (actions, .init(profileID: desired.id.uuidString, fields: host))
    }

    private static func validUID(_ value: String) -> Bool {
        value == value.trimmingCharacters(in: .whitespacesAndNewlines) && !value.isEmpty && value.utf8.count <= 256 &&
            !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private static func validateTransactionID(_ value: String) throws {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty, value.utf8.count <= 128,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw VortxNativeError.invalidSnapshot }
    }

    private static func exactObjectKeys(_ value: VortxJSON, _ keys: Set<String>) -> Bool {
        guard case .object(let object) = value else { return false }
        return Set(object.keys) == keys
    }

    private static func validateAccount(_ value: VortxJSON) throws {
        guard case .object(let account) = value, case .string(let kind)? = account["kind"] else { throw VortxNativeError.invalidSnapshot }
        switch kind {
        case "local_only", "pending_own":
            guard Set(account.keys) == ["kind"] else { throw VortxNativeError.invalidSnapshot }
        case "own":
            guard Set(account.keys) == ["kind", "value"], case .string(let uid)? = account["value"], validUID(uid) else {
                throw VortxNativeError.invalidSnapshot
            }
        case "shared":
            guard Set(account.keys) == ["kind", "value"], case .string(let owner)? = account["value"],
                  UUID(uuidString: owner)?.uuidString == owner else { throw VortxNativeError.invalidSnapshot }
        default:
            throw VortxNativeError.invalidSnapshot
        }
    }
}
