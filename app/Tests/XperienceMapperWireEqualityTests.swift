// Wire-equality and credential-carrier regressions for the actual production mapper.
// Invoked by the portable connector contract test entry point.
import Foundation

@MainActor enum XperienceMapperWireEqualityTests {
    private static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        try XperienceExportConnectorTests.require(value(), message)
    }

    private static func document(createdAt: VortxJSON, timestamp: Double) throws -> CurationDocument {
        let id = "44444444-4444-4444-8444-444444444444"
        let legacy = SmartCollection(id: id, name: "Legacy rules", rules: .init(), home: true,
                                     createdAt: timestamp)
        let original = try CurationDocument.make(for: legacy, legacyValue: .object([
            "id": .string(id), "createdAt": createdAt
        ]))
        guard case .object(var raw) = original.raw else {
            throw XperienceExportConnectorTests.Failure.assertion("wire fixture document")
        }
        raw["futureLeaf"] = .object([
            "integral": .number(1), "fraction": .number(1.25), "flag": .bool(true),
            "opaque": .string("preserve this exact value")
        ])
        return try CurationDocument(raw: .object(raw)).removingFolder("rules")
    }

    private static func mapped(_ current: CurationDocument) throws -> CurationDocument {
        try XperienceCurationExportMapper.map(XperienceExportConnectorTests.mappedProjection(),
            upstreamCollectionID: "22222222-2222-4222-8222-222222222222",
            sourceID: "33333333-3333-4333-8333-333333333333", into: current,
            installed: [XperienceExportConnectorTests.candidate()])
    }

    static func run() throws {
        // All are admitted numeric representations; do not fix the failure by narrowing fixtures
        // to integer-only values. The mapper must preserve the caller's actual raw representation.
        let variants: [(String, VortxJSON, Double)] = [
            ("integral Double", .number(1), 1),
            ("signed integer", .integer(1), 1),
            ("unsigned integer", .unsigned(1), 1),
            ("fractional Double", .number(1.25), 1.25),
            ("safe integer boundary", .integer(9_007_199_254_740_991), 9_007_199_254_740_991)
        ]
        for (label, numeric, timestamp) in variants {
            let current = try document(createdAt: numeric, timestamp: timestamp)
            let linked = try mapped(current)
            try require(linked.raw["legacyCreatedAt"] == numeric,
                        "mapper preserves original raw timestamp representation: \(label)")
            try require(linked.raw["futureLeaf"] == current.raw["futureLeaf"],
                        "mapper preserves unknown numeric/bool/text leaves: \(label)")
            try require(linked.raw["overrides"] == current.raw["overrides"],
                        "wire comparison preserves complete local overrides and tombstones: \(label)")
            let refreshed = try mapped(linked)
            try require(refreshed.raw["futureLeaf"] == current.raw["futureLeaf"] &&
                        refreshed.raw["legacyCreatedAt"] == numeric &&
                        refreshed.raw["overrides"] == current.raw["overrides"],
                        "refresh retains original raw values after the same wire gate: \(label)")
        }

        let boolBytes = try XperienceCollections.canonicalData(.bool(true))
        let integerBytes = try XperienceCollections.canonicalData(.integer(1))
        let distinctBytes = try XperienceCollections.canonicalData(.integer(2))
        try require(boolBytes != integerBytes && integerBytes != distinctBytes,
                    "canonical comparison distinguishes booleans and changed numeric values")

        let nestedCredential = "{\"token\":\"synthetic-private-value\"}"
        let unsafe: [(String, String, VortxJSON)] = [
            ("explicit credential key", "apiKey", .string("synthetic-private-value")),
            ("nested credential key", "futureCarrier", .object(["password": .string("synthetic-private-value")])),
            ("structured credential string", "futureCarrier", .string(nestedCredential)),
            ("encoded credential string", "futureCarrier", .string(Data(nestedCredential.utf8).base64EncodedString())),
            ("ambiguous credential carrier", "futureSecret", .string("synthetic-private-value"))
        ]
        for (label, key, value) in unsafe {
            let safe = try document(createdAt: .integer(1), timestamp: 1)
            guard case .object(var raw) = safe.raw else {
                throw XperienceExportConnectorTests.Failure.assertion("privacy fixture document")
            }
            raw[key] = value
            let current = try CurationDocument(raw: .object(raw))
            do {
                _ = try mapped(current)
                throw XperienceExportConnectorTests.Failure.assertion("mapper admitted \(label)")
            } catch let failure as XperienceExportFailure {
                try require(failure == .unsafeContent, "unchanged privacy guard rejects \(label)")
            }
            try require(current.raw == .object(raw), "rejected candidate remains untouched: \(label)")
        }
    }
}
