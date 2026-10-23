import Foundation

/// Exact JSON value slices. Native source numbers never pass through NSNumber/Double/Int64.
/// Parsing is cold/source-transition work; a retained ownerHistory slice is reused verbatim.
enum OwnerHistoryExactJSON {
    enum Failure: Error { case malformed, excessive, missing, contradictory }
    static let maximumBytes = 32 * 1024 * 1024
    struct Object: Sendable {
        private(set) var fields: [String: Data]
        init(_ bytes: Data) throws {
            var parser = Parser(bytes)
            fields = try parser.objectFields()
            try parser.end()
        }
        fileprivate init(fields: [String: Data]) { self.fields = fields }
        subscript(_ key: String) -> Data? { fields[key] }
        mutating func set(_ key: String, _ value: Data) { fields[key] = value }
        mutating func remove(_ key: String) { fields.removeValue(forKey: key) }
        func required(_ key: String) throws -> Data {
            guard let bytes = fields[key] else { throw Failure.missing }; return bytes
        }
        func text(_ key: String) throws -> String {
            try JSONDecoder().decode(String.self, from: required(key))
        }
        func encoded() throws -> Data {
            var result = Data([123])
            for (offset, key) in fields.keys.sorted().enumerated() {
                if offset != 0 { result.append(44) }
                result.append(try JSONEncoder().encode(key)); result.append(58)
                result.append(fields[key]!)
            }
            result.append(125)
            guard result.count <= maximumBytes else { throw Failure.excessive }
            return result
        }
    }
    static func array(_ bytes: Data) throws -> [Data] {
        var p = Parser(bytes); let values = try p.arrayValues(); try p.end(); return values
    }
    static func string(_ value: String) throws -> Data { try JSONEncoder().encode(value) }
    static func sameText(_ a: String, _ b: String) -> Bool { Data(a.utf8) == Data(b.utf8) }
    /// Structural comparison without decoding numeric payloads. Use only for small leases or
    /// cold snapshots: this intentionally walks its input. Number tokens, including -0.0, stay
    /// exact; keys/strings are decoded and emitted deterministically, arrays keep order.
    static func canonical(_ bytes: Data) throws -> Data {
        var parser = Parser(bytes)
        parser.whitespace(); let start = parser.at
        try parser.value(); let end = parser.at; try parser.end()
        let value = Data(parser.bytes[start..<end])
        switch value.first {
        case 123:
            var object = try Object(value)
            for (key, field) in object.fields { object.set(key, try canonical(field)) }
            return try object.encoded()
        case 91:
            var result = Data([91])
            for (i, item) in try array(value).enumerated() {
                if i != 0 { result.append(44) }; result.append(try canonical(item))
            }
            result.append(93); return result
        case 34: return try string(JSONDecoder().decode(String.self, from: value))
        default: return value
        }
    }

    /// Complete native ENGINE output only, never a standalone delta or a peer merge.
    /// Unmentioned unknown native siblings survive; explicit raw unknown upserts keep the
    /// donor contract. No recursive merge/preservation inside a replaced typed field is claimed.
    struct Snapshot: Sendable {
        let bytes: Data
        private let root: Object
        private let roster: Object
        private let profiles: Object
        private let libraries: Object
        private let native: Object
        private let source: Data?
        let witnessID: String
        let fence: Data
        /// Reuse the already encoded native field; no full snapshot/source parse on reads.
        var nativeSyncBytes: Data { get throws { try root.required("nativeSync") } }

        // ee37c942 NativeSyncDocument serde-owned fields, EXCLUDING ownerHistory. Known
        // fields are replaced/cleared by complete native output. Unknown omissions are NOT
        // clears. ownerHistory is separately supplied only by witness reuse or a cold state.
        private static let nativeSerdeOwned: Set<String> = [
            "websiteAddonReceipts", "accountSlots", "legacyProfileEditReceipts", "legacyImport",
            "schemaVersion", "scope", "ownerProfileId", "profiles", "addons", "libraries", "watches"
        ]

        /// Native normalization may omit unknown siblings, not alter admitted known data or
        /// source proof. Returned unknown upserts are not authority to rewrite a peer field.
        static func requireColdNativeConservation(original: Data, candidate: Data) throws {
            let before = try Object(original), after = try Object(candidate)
            let known = nativeSerdeOwned.union(["ownerHistory"])
            for key in known {
                switch (before[key], after[key]) {
                case (nil, nil): break
                case let (.some(a), .some(b)):
                    guard try canonical(a) == canonical(b) else { throw Failure.contradictory }
                default: throw Failure.contradictory
                }
            }
            for (key, value) in after.fields where !known.contains(key) {
                guard let original = before[key], try canonical(original) == canonical(value) else {
                    throw Failure.contradictory
                }
            }
        }

        /// First peer mount preserves the original native unknown bytes before composing
        /// normalized engine output. It does not validate a source or mint native authority.
        static func conservingColdNativeState(originalNative: Data, normalizedState: Data,
                                              witnessID: String, fence: Data) throws -> Self {
            var original = try Object(normalizedState)
            try requireColdNativeConservation(original: originalNative,
                candidate: original.required("nativeSync"))
            original.set("nativeSync", originalNative)
            let base = try Self(bytes: original.encoded(), witnessID: witnessID, fence: fence)
            return try base.replacingNativeState(normalizedState, witnessID: witnessID, fence: fence)
        }

        init(bytes: Data, witnessID: String, fence: Data) throws {
            let root = try Object(bytes)
            let roster = try Object(root.required("roster"))
            self.profiles = try Object(roster.required("profiles"))
            self.libraries = try Object(root.required("libraries"))
            let native = try Object(root.required("nativeSync"))
            self.bytes = bytes; self.root = root; self.roster = roster; self.native = native
            self.source = native["ownerHistory"]; self.witnessID = witnessID; self.fence = fence
        }
        private init(bytes: Data, root: Object, roster: Object, profiles: Object, libraries: Object,
                     native: Object, source: Data?, witnessID: String, fence: Data) {
            self.bytes = bytes; self.root = root; self.roster = roster; self.profiles = profiles
            self.libraries = libraries; self.native = native; self.source = source
            self.witnessID = witnessID; self.fence = fence
        }

        /// Disposable app presentation only. Never expose full ownerHistory/source archives,
        /// unknown raw account/native siblings or persistence bytes through VortxJSON.
        var presentationBytes: Data {
            get throws {
                var visible = try Object(Data("{}".utf8)), visibleNative = try Object(Data("{}".utf8))
                for key in ["roster", "libraries", "activeProfileId", "accountLibraryArchives", "projectedAccountSlots"] {
                    if let value = root[key] { visible.set(key, value) }
                }
                for key in Self.nativeSerdeOwned {
                    if let value = native[key] { visibleNative.set(key, value) }
                }
                visible.set("nativeSync", try visibleNative.encoded())
                return try visible.encoded()
            }
        }

        /// Only a native capture under a freshly checked accepted target supplies this fence.
        /// Target/binding may change; the runtime generation, witness and account may not.
        /// This copies metadata only: no source parsing, normalization, or checkpoint write.
        func retargeting(fence nextFence: Data) throws -> Self {
            var old = try Object(fence), next = try Object(nextFence)
            for key in ["profileId", "verifiedStreamingUid", "binding"] {
                _ = try old.required(key); _ = try next.required(key)
                old.remove(key); next.remove(key)
            }
            guard try canonical(old.encoded()) == canonical(next.encoded()),
                  try sameText(Object(nextFence).text("sourceSetWitnessId"), witnessID) else {
                throw Failure.contradictory
            }
            return Self(bytes: bytes, root: root, roster: roster, profiles: profiles,
                libraries: libraries, native: native, source: source, witnessID: witnessID, fence: nextFence)
        }

        /// Replaces only pinned serde-owned leaves plus explicit raw unknown upserts. The
        /// retained Object shares immutable Data slices; omitted large/unknown/source values
        /// are not decoded or canonicalized again. No native schema validity is minted here.
        private func replacingNativeFields(_ incoming: Object, source nextSource: Data?) -> Object {
            var result = native
            for key in Self.nativeSerdeOwned { result.remove(key) }
            for (key, value) in incoming.fields where key != "ownerHistory" { result.set(key, value) }
            if let nextSource { result.set("ownerHistory", nextSource) }
            else { result.remove("ownerHistory") }
            return result
        }

        /// Cold replacement retains unknown host AND native siblings. Complete engine-owned
        /// root/native fields still obey their replacement/omission semantics. Source may
        /// change/disappear only on this cold path under its caller's full native validation.
        func replacingNativeState(_ state: Data, witnessID: String, fence: Data) throws -> Self {
            let stateRoot = try Object(state)
            let managed: Set<String> = ["roster", "libraries", "accountLibraryArchives",
                "projectedAccountSlots", "nativeSync", "activeProfileId"]
            guard Set(stateRoot.fields.keys).isSubset(of: managed),
                  stateRoot["roster"] != nil, stateRoot["libraries"] != nil,
                  stateRoot["nativeSync"] != nil else { throw Failure.contradictory }
            let nextRoster = try Object(stateRoot.required("roster"))
            let nextProfiles = try Object(nextRoster.required("profiles"))
            let nextLibraries = try Object(stateRoot.required("libraries"))
            let incoming = try Object(stateRoot.required("nativeSync"))
            let nextSource = incoming["ownerHistory"]
            let nextNative = replacingNativeFields(incoming, source: nextSource)
            var complete = root
            for key in managed where key != "nativeSync" {
                if let value = stateRoot[key] { complete.set(key, value) }
                else { complete.remove(key) }
            }
            complete.set("nativeSync", try nextNative.encoded())
            // Reuse the parsed objects above, rather than reparsing a new full Snapshot.
            return try Self(bytes: complete.encoded(), root: complete, roster: nextRoster,
                profiles: nextProfiles, libraries: nextLibraries, native: nextNative, source: nextSource,
                witnessID: witnessID, fence: fence)
        }

        func applying(checkpoint: Data) throws -> Self {
            let reply = try Object(checkpoint)
            guard try reply.text("kind") == "checkpoint_delta",
                  try reply.required("durableAck") == Data("false".utf8),
                  try reply.required("requiresCompleteArchiveEnvelope") == Data("true".utf8),
                  try sameText(reply.text("reuseExactOwnerHistoryFromWitness"), witnessID),
                  try canonical(reply.required("preparedAgainst")) == canonical(fence) else {
                throw Failure.contradictory
            }
            let delta = try Object(reply.required("delta"))
            let allowed: Set<String> = ["accountLibraryArchives", "projectedAccountSlots", "nativeSync",
                                       "activeProfileId", "profiles", "libraries"]
            guard Set(delta.fields.keys).isSubset(of: allowed) else { throw Failure.contradictory }
            var next = root, nextRoster = roster, nextProfiles = profiles, nextLibraries = libraries
            var nextNative = native
            if let rows = delta["profiles"] {
                for row in try array(rows) {
                    let profile = try Object(row); let id = try profile.text("id")
                    guard !id.isEmpty else { throw Failure.malformed }
                    nextProfiles.set(id, row)
                }
                nextRoster.set("profiles", try nextProfiles.encoded())
                next.set("roster", try nextRoster.encoded())
            }
            if let buckets = delta["libraries"] {
                for (key, value) in try Object(buckets).fields { nextLibraries.set(key, value) }
                next.set("libraries", try nextLibraries.encoded())
            }
            for key in ["accountLibraryArchives", "projectedAccountSlots", "activeProfileId"] {
                if let value = delta[key] { next.set(key, value) }
            }
            if let nativeBytes = delta["nativeSync"] {
                let incoming = try Object(nativeBytes)
                guard incoming["ownerHistory"] == nil else { throw Failure.contradictory }
                nextNative = replacingNativeFields(incoming, source: source)
                next.set("nativeSync", try nextNative.encoded())
            }
            let currentFence = try reply.required("fence")
            let current = try Object(currentFence)
            guard try sameText(current.text("sourceSetWitnessId"), witnessID) else { throw Failure.contradictory }
            // Never parse a new full Snapshot on a delta. Retain original source/unknown
            // slices plus the parsed native Object; only actual incoming delta fields parse.
            return try Self(bytes: next.encoded(), root: next, roster: nextRoster,
                profiles: nextProfiles, libraries: nextLibraries, native: nextNative, source: source,
                witnessID: witnessID, fence: currentFence)
        }
    }

    private struct Parser {
        let bytes: [UInt8]
        var at = 0
        var depth = 0
        init(_ input: Data) { bytes = Array(input) }
        mutating func whitespace() { while at < bytes.count && [9, 10, 13, 32].contains(bytes[at]) { at += 1 } }
        mutating func end() throws {
            whitespace()
            guard bytes.count <= maximumBytes, at == bytes.count else { throw Failure.malformed }
        }
        mutating func take(_ expected: UInt8) throws {
            whitespace(); guard at < bytes.count, bytes[at] == expected else { throw Failure.malformed }; at += 1
        }
        mutating func objectFields() throws -> [String: Data] {
            guard bytes.count <= maximumBytes, depth < 128 else { throw Failure.excessive }
            depth += 1; defer { depth -= 1 }; try take(123)
            var fields: [String: Data] = [:]
            whitespace()
            if at < bytes.count, bytes[at] == 125 { at += 1; return fields }
            while true {
                whitespace(); let begin = at; try quoted()
                let name = try JSONDecoder().decode(String.self, from: Data(bytes[begin..<at]))
                // Also rejects canonically equivalent duplicate Unicode keys; do not silently
                // collapse them through Swift Dictionary equality.
                guard fields[name] == nil else { throw Failure.malformed }
                try take(58); whitespace(); let valueBegin = at; try value()
                fields[name] = Data(bytes[valueBegin..<at])
                whitespace(); guard at < bytes.count else { throw Failure.malformed }
                if bytes[at] == 125 { at += 1; return fields }
                try take(44)
            }
        }
        mutating func arrayValues() throws -> [Data] {
            guard depth < 128 else { throw Failure.excessive }
            depth += 1; defer { depth -= 1 }; try take(91)
            var result: [Data] = []; whitespace()
            if at < bytes.count, bytes[at] == 93 { at += 1; return result }
            while true {
                whitespace(); let begin = at; try value(); result.append(Data(bytes[begin..<at]))
                whitespace(); guard at < bytes.count else { throw Failure.malformed }
                if bytes[at] == 93 { at += 1; return result }; try take(44)
            }
        }
        mutating func quoted() throws {
            try take(34); let start = at - 1
            while at < bytes.count {
                let byte = bytes[at]; at += 1
                if byte == 34 {
                    _ = try JSONDecoder().decode(String.self, from: Data(bytes[start..<at])); return
                }
                guard byte >= 32 else { throw Failure.malformed }
                if byte == 92 {
                    guard at < bytes.count else { throw Failure.malformed }
                    let escaped = bytes[at]; at += 1
                    if escaped == 117 {
                        guard at + 4 <= bytes.count, bytes[at..<(at + 4)].allSatisfy({
                            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
                        }) else { throw Failure.malformed }
                        at += 4
                    } else if ![34, 47, 92, 98, 102, 110, 114, 116].contains(escaped) { throw Failure.malformed }
                }
            }
            throw Failure.malformed
        }
        mutating func value() throws {
            whitespace(); guard at < bytes.count else { throw Failure.malformed }
            switch bytes[at] {
            case 123: _ = try objectFields()
            case 91: _ = try arrayValues()
            case 34: try quoted()
            case 116: try literal("true")
            case 102: try literal("false")
            case 110: try literal("null")
            default: try number()
            }
        }
        mutating func literal(_ text: String) throws {
            let expected = Array(text.utf8)
            guard at + expected.count <= bytes.count,
                  Array(bytes[at..<(at + expected.count)]) == expected else { throw Failure.malformed }
            at += expected.count
        }
        mutating func number() throws {
            if at < bytes.count, bytes[at] == 45 { at += 1 }
            guard at < bytes.count else { throw Failure.malformed }
            if bytes[at] == 48 { at += 1 }
            else {
                guard (49...57).contains(bytes[at]) else { throw Failure.malformed }
                while at < bytes.count, (48...57).contains(bytes[at]) { at += 1 }
            }
            if at < bytes.count, bytes[at] == 46 {
                at += 1; let start = at
                while at < bytes.count, (48...57).contains(bytes[at]) { at += 1 }
                guard at > start else { throw Failure.malformed }
            }
            if at < bytes.count, bytes[at] == 69 || bytes[at] == 101 {
                at += 1
                if at < bytes.count, bytes[at] == 43 || bytes[at] == 45 { at += 1 }
                let start = at
                while at < bytes.count, (48...57).contains(bytes[at]) { at += 1 }
                guard at > start else { throw Failure.malformed }
            }
        }
    }
}
