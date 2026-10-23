import Foundation
import CryptoKit

/// Real producer/archive implementations with synthetic, source-bound metadata. The focused
/// external-CW mode also uses a retained disposable checkpoint directory; never real accounts,
/// system keychain, app launch or network access.
@main enum VortxNativeWatchedArchiveTests {
    typealias Object = [String: Any]
    actor FetchCounter {
        private var value = 0
        func next() -> Int { value += 1; return value }
    }
    static let owner = UUID(uuidString: "90000000-0000-0000-0000-000000000009")!
    static let scope = VortxAccountScope(account: "archive.fixture", ownerProfileID: owner.uuidString)
    static func check(_ value: Bool, _ message: String, line: UInt = #line) {
        guard value else {
            FileHandle.standardError.write(Data("FAIL: watched archive \(message), line \(line)\n".utf8))
            exit(1)
        }
    }
    static func encode(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    static func object(_ data: Data) throws -> Object { try JSONSerialization.jsonObject(with: data) as! Object }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func rejected(_ message: String, _ operation: () throws -> Void) throws {
        do { try operation() } catch { return }
        preconditionFailure("Accepted \(message)")
    }
    static func metadata(_ request: LegacyWatchedBitfieldMigrationEvidence.MetadataRequest) throws -> LegacyWatchedBitfieldMigrationEvidence.MetadataResponse {
        let value: Object = ["meta": ["id": request.metaID, "type": "series", "videos": (1...5).map {
            ["id": "\(request.metaID):1:\($0)", "season": 1, "episode": $0,
             "released": "2020-01-0\($0)T00:00:00.000Z"] as Object
        }]]
        return .init(request: request, raw: try encode(value))
    }
    static func processingLimited(_ message: String, _ operation: () throws -> Void) throws {
        do { try operation() }
        catch VortxNativeWatchedArchive.Failure.processingLimit { return }
        catch { preconditionFailure("Wrong error before budget admission for \(message): \(error)") }
        preconditionFailure("Accepted over-budget \(message)")
    }
    static func prepare(_ source: Data, archived: [Data] = [], available: Bool = true,
                        lookup: VortxLegacyWatchedMigration.ArchivedEvidenceLookup? = nil) async throws -> VortxLegacyWatchedMigration.Preparation {
        try await VortxLegacyWatchedMigration.prepare(accountID: scope.account, ownerProfileID: owner,
            document: source, profileIDs: [owner], archivedEvidence: archived, archivedEvidenceLookup: lookup,
            isCurrent: { true }, fetch: { request in
                guard available else { throw URLError(.notConnectedToInternet) }
                return try metadata(request)
            })
    }
    static func source(bytes: Int = 1_050_720, count: Int = 24) throws -> Data {
        let rows: [Object] = (0..<count).map { index in
            let id = "tt\(2934286 + index)"
            return ["id": id, "type": "series", "watched": "\(id):1:5:5:eJyTZwAAAEAAIA=="]
        }
        let addon: Object = ["transportUrl": "https://original.invalid/manifest.json", "manifest": [
            "id": "original", "name": "Original", "version": "1.0.0", "resources": ["meta"], "types": ["series"]]]
        var value: Object = ["vortx": ["library": rows, "addons": [addon]], "padding": ""]
        value["padding"] = String(repeating: "x", count: bytes - (try encode(value)).count)
        let result = try encode(value)
        check(result.count == bytes, "exact large source size")
        return result
    }
    static func main() async throws {
        if CommandLine.arguments.contains("--external-cw-host") {
            try await VortxNativeExternalCWHostTests.run(directory: URL(fileURLWithPath: CommandLine.arguments[1])); return
        }
        let source = try source()
        let complete = try await prepare(source)
        check(complete.rows.count == 24 && complete.archives.count == 24 && complete.unresolved.isEmpty,
              "24 legitimate source-bound watched rows captured")
        let repeatedBytes = complete.archives.reduce(0) { $0 + $1.count }
        check(repeatedBytes > 32 * 1_024 * 1_024, "fixture crosses old repeated-source cap")
        let empty = try VortxNativeBootstrapArchive.encode(document: encode(["ownAccountSources": Object()]))
        let archive = try VortxNativeWatchedArchive.retaining(empty, evidence: complete.archives, scope: scope)
        try VortxNativeBootstrapArchive.validate(archive)
        try VortxNativeWatchedArchive.validate(archive, scope: scope)
        let host = try object(archive)["hostDocument"] as! Object
        let pool = host["nativeWatchedMigrationSources"] as! [String: String]
        check(pool == [digest(source): source.base64EncodedString()], "one byte-exact source for all 24 receipts")
        check(archive.count < 2 * 1_024 * 1_024, "compact archive is below 2 MiB, without lifting 32 MiB cap")
        let restored = try VortxNativeWatchedArchive.entries(archive, key: VortxNativeWatchedArchive.evidenceKey)
        check(Set(restored) == Set(complete.archives), "exact original receipt bytes reconstruct")
        let cold = try await prepare(source, archived: restored, available: false)
        check(cold.rows.count == 24 && cold.unresolved.isEmpty, "all 24 compact receipts replay without provider access")
        check(try VortxNativeWatchedArchive.retaining(archive, prior: archive, scope: scope) == archive,
              "retention is byte-idempotent")
        print("Watched source pool: source=\(source.count), old repeated receipts=\(repeatedBytes), compact archive=\(archive.count), exact offline rows=24")

        // Pending receipts keep the exact original source and reason even after successful retry.
        let unavailable = try await prepare(source, available: false)
        let originals = try unavailable.pendingArchives
        let draft = try VortxNativeWatchedArchive.retaining(empty, pending: originals, scope: scope)
        check(try VortxNativeWatchedArchive.pendingProfileIDs(draft) == [owner], "unresolved rows remain visibly pending")
        let resolved = try VortxNativeWatchedArchive.retaining(archive, prior: draft, scope: scope)
        check(try VortxNativeWatchedArchive.pendingProfileIDs(resolved).isEmpty, "matching evidence clears only pending display")
        check(Set(try VortxNativeWatchedArchive.entries(resolved, key: VortxNativeWatchedArchive.pendingKey)) == Set(originals),
              "all original pending receipts survive successful completion")
        let retried = try await VortxNativeWatchedArchive.retryHistorical(resolved, scope: scope, isCurrent: { true }, fetch: { _ in
            preconditionFailure("Resolved historical retry made a network request")
        })!
        check(retried == resolved, "retry and reread preserve the complete compact journal")
        let lazy = try VortxNativeWatchedArchive.evidenceLookup(archive, scope: scope)
        let lazyReplay = try await prepare(source, available: false, lookup: lazy)
        check(lazyReplay.rows.count == 24 && Set(lazyReplay.archives) == Set(complete.archives),
              "production-style lazy lookup replays exact receipts without provider access")
        let requested = try LegacyWatchedBitfieldMigrationEvidence.Scope(accountID: scope.account,
            profileID: owner, ownerProfileID: owner)
        check(try lazy(requested, digest(source), .authenticatedOwnerLibrary(index: 0)).count == 1,
              "lookup returns only the exact current tuple")
        let foreign = try LegacyWatchedBitfieldMigrationEvidence.Scope(accountID: "foreign", profileID: owner, ownerProfileID: owner)
        try rejected("foreign lazy lookup") { _ = try lazy(foreign, digest(source), .authenticatedOwnerLibrary(index: 0)) }
        let captured = try await VortxNativeWatchedArchive.retryHistorical(draft, scope: scope,
            isCurrent: { true }, fetch: { try metadata($0) })!
        check(try VortxNativeWatchedArchive.pendingProfileIDs(captured).isEmpty,
              "streamed retry resolves all 24 historical pending tuples")
        check(Set(try VortxNativeWatchedArchive.entries(captured, key: VortxNativeWatchedArchive.pendingKey)) == Set(originals),
              "streamed retry never drops original pending receipts")
        check(Set(try VortxNativeWatchedArchive.entries(captured, key: VortxNativeWatchedArchive.evidenceKey)) == Set(complete.archives),
              "streamed retry compacts each exact new receipt")
        let reread = try await VortxNativeWatchedArchive.retryHistorical(captured, scope: scope,
            isCurrent: { true }, fetch: { _ in preconditionFailure("Completed streamed retry fetched again") })!
        check(reread == captured, "streamed retry reread preserves archive bytes")
        var alternate = try object(originals[0])
        alternate["reason"] = "episode_inventory_ambiguous"
        let alternateBytes = try encode(alternate)
        let reasonVariants = try VortxNativeWatchedArchive.retaining(empty, pending: [originals[0], alternateBytes], scope: scope)
        let variantFetches = FetchCounter()
        let repairedVariants = try await VortxNativeWatchedArchive.retryHistorical(reasonVariants, scope: scope,
            isCurrent: { true }, fetch: { request in
                check(await variantFetches.next() == 1, "one exact tuple must never be captured twice for different pending reasons")
                return try metadata(request)
            })!
        check(Set(try VortxNativeWatchedArchive.entries(repairedVariants, key: VortxNativeWatchedArchive.pendingKey)) == Set([originals[0], alternateBytes]),
              "retry conserves both original pending reasons byte-for-byte")
        check(try VortxNativeWatchedArchive.entries(repairedVariants, key: VortxNativeWatchedArchive.evidenceKey).count == 1,
              "reason variants produce only one authoritative receipt")

        // Older inline receipts may use arbitrary JSON whitespace. Retain that spelling exactly.
        let noncanonical = Data(" \n".utf8) + complete.archives[0] + Data("\n".utf8)
        let legacy = try VortxNativeBootstrapArchive.encode(document: encode([
            VortxNativeWatchedArchive.evidenceKey: [noncanonical.base64EncodedString()]]))
        check(try VortxNativeWatchedArchive.entries(legacy, key: VortxNativeWatchedArchive.evidenceKey) == [noncanonical],
              "old inline representation is still readable")
        let mixed = try VortxNativeWatchedArchive.retaining(archive, prior: legacy, scope: scope)
        check(Set(try VortxNativeWatchedArchive.entries(mixed, key: VortxNativeWatchedArchive.evidenceKey)) == Set(complete.archives + [noncanonical]),
              "mixed old/new journal conserves even noncanonical receipt bytes")
        let ambiguousLookup = try VortxNativeWatchedArchive.evidenceLookup(mixed, scope: scope)
        let ambiguousPending = try VortxNativeWatchedArchive.retaining(mixed, pending: [originals[0]], scope: scope)
        check(try VortxNativeWatchedArchive.pendingProfileIDs(ambiguousPending) == [owner],
              "ambiguous evidence cannot hide the unresolved original pending tuple")
        let firstRow = try object(complete.archives[0])["row"] as! Object
        try rejected("two exact-tuple receipts must not be overwritten in the lazy index") {
            _ = try ambiguousLookup(requested, digest(source), .authenticatedOwnerLibrary(index: firstRow["index"] as! Int))
        }
        try rejected("foreign account reuse") {
            try VortxNativeWatchedArchive.validate(archive, scope: .init(account: "other", ownerProfileID: owner.uuidString))
        }
        try rejected("foreign owner reuse") {
            try VortxNativeWatchedArchive.validate(archive, scope: .init(account: scope.account, ownerProfileID: UUID().uuidString))
        }

        // Every surrounding bootstrap field must survive a watched-journal update.
        let enclosing = try VortxNativeBootstrapArchive.encode(document: encode(["future": ["keep": 0.125], "token": "excluded-fixture"]),
            material: encode(["schemaVersion": 1, "retained": 123.125]),
            authenticatedSourceArchive: VortxNativeBootstrapArchive.encode(document: encode(["original": "unchanged"])))
        let retained = try VortxNativeWatchedArchive.retaining(enclosing, evidence: [complete.archives[0]], scope: scope)
        let before = try JSONDecoder().decode(VortxJSON.self, from: enclosing)
        let after = try JSONDecoder().decode(VortxJSON.self, from: retained)
        for key in ["schemaVersion", "excludedCredentialPaths", "legacyImportMaterial", "authenticatedSourceArchive"] {
            check(before[key] == after[key], "wrapper \(key) retained")
        }
        check(before["hostDocument"]?["future"] == after["hostDocument"]?["future"], "unknown host values retained")
        let quarantine = try VortxNativeUnattributedOverlayArchive.retaining(enclosing, prior: nil,
            document: source, profileIDs: [], scope: scope)
        let removal: Object = ["profileId": owner.uuidString, "kind": "library_removal", "identity": "tt123",
            "sourceField": "/vortx/deletedLibrary", "receipt": ["deletedLibrary": ["tt123"]],
            "sourceDocumentSha256": digest(source)]
        let membership = try VortxLegacyMembershipReceiptArchive.appending(encode([removal]), to: enclosing,
            scope: scope.account, ownerProfileID: scope.ownerProfileID, sourceDocumentSHA256: digest(source))
        for updated in [quarantine, membership] {
            let value = try JSONDecoder().decode(VortxJSON.self, from: updated)
            for key in ["schemaVersion", "excludedCredentialPaths", "legacyImportMaterial", "authenticatedSourceArchive"] {
                check(before[key] == value[key], "adjacent journal retains wrapper \(key)")
            }
            check(before["hostDocument"]?["future"] == value["hostDocument"]?["future"], "adjacent journal retains unknown host fields")
        }

        func damaged(_ mutate: (inout Object) throws -> Void) throws -> Data {
            var envelope = try object(archive)
            var host = envelope["hostDocument"] as! Object
            try mutate(&host)
            envelope["hostDocument"] = host
            return try encode(envelope) // Deliberately bypass capture sanitization for negative tests.
        }
        let wrongSource = try damaged { host in
            host["nativeWatchedMigrationSources"] = [digest(source): Data("{}".utf8).base64EncodedString()]
        }
        let missingSource = try damaged { $0["nativeWatchedMigrationSources"] = [String: String]() }
        let orphan = try damaged { host in
            var sources = pool; let extra = Data("{}".utf8); sources[digest(extra)] = extra.base64EncodedString()
            host["nativeWatchedMigrationSources"] = sources
        }
        let forgedReceipt = try damaged { host in
            var records = host[VortxNativeWatchedArchive.evidenceKey] as! [Object]
            records[0]["sourceDocumentSha256"] = String(repeating: "a", count: 64)
            host[VortxNativeWatchedArchive.evidenceKey] = records
        }
        let excessive = try damaged { host in
            let records = host[VortxNativeWatchedArchive.evidenceKey] as! [Object]
            host[VortxNativeWatchedArchive.evidenceKey] = Array(repeating: records[0], count: 10_001)
        }
        for (label, candidate) in [("digest/source conflict", wrongSource), ("missing pooled source", missingSource),
                                   ("unreferenced source", orphan), ("forged reference", forgedReceipt), ("too many rows", excessive)] {
            try rejected(label) { try VortxNativeWatchedArchive.validate(candidate, scope: scope) }
        }
        let credential = try damaged { host in
            var poisoned = try object(source); poisoned["token"] = "fixture-credential"
            let poison = try encode(poisoned), poisonDigest = digest(poison)
            host["nativeWatchedMigrationSources"] = [poisonDigest: poison.base64EncodedString()]
            var records = host[VortxNativeWatchedArchive.evidenceKey] as! [Object]
            for index in records.indices {
                var receipt = try object(Data(base64Encoded: records[index]["receiptBase64"] as! String)!)
                receipt["sourceDocumentSha256"] = poisonDigest
                records[index]["sourceDocumentSha256"] = poisonDigest
                records[index]["receiptBase64"] = try encode(receipt).base64EncodedString()
            }
            host[VortxNativeWatchedArchive.evidenceKey] = records
        }
        try rejected("credential inside a correctly hashed pooled source") { try VortxNativeBootstrapArchive.validate(credential) }
        try rejected("credential at watched admission") { try VortxNativeWatchedArchive.validate(credential, scope: scope) }
        let carrierCredential = try damaged { host in
            var records = host[VortxNativeWatchedArchive.evidenceKey] as! [Object]
            var receipt = try object(Data(base64Encoded: records[0]["receiptBase64"] as! String)!)
            receipt["future"] = ["password": "fixture-credential"]
            records[0]["receiptBase64"] = try encode(receipt).base64EncodedString()
            host[VortxNativeWatchedArchive.evidenceKey] = records
        }
        try rejected("credential inside compact receipt") { try VortxNativeBootstrapArchive.validate(carrierCredential) }

        // Compatibility arrays remain bounded even though production streams larger journals.
        let compactRecord = (host[VortxNativeWatchedArchive.evidenceKey] as! [Object])[0]
        let fullSize = restored[0].count
        let budget = 96 * 1_024 * 1_024
        let fitting = budget / fullSize
        check(fitting > 48 && fitting < 100, "fixture exercises useful 24+24 admission and bounded larger work")
        func budgetArchive(_ evidence: [Any], _ pending: [Any]) throws -> Data {
            try damaged { value in
                value[VortxNativeWatchedArchive.evidenceKey] = evidence
                value[VortxNativeWatchedArchive.pendingKey] = pending
            }
        }
        let nearBudget = try budgetArchive(Array(repeating: compactRecord, count: fitting), [])
        // Arrays share immutable fixture Data storage; this proves admission arithmetic without
        // creating a source-per-row allocation or attempting an OOM experiment.
        let repeatedInput = Array(repeating: restored[0], count: fitting)
        do {
            _ = try await VortxLegacyWatchedMigration.retryArchivedPending(repeatedInput,
                accountID: scope.account, ownerProfileID: owner, archivedEvidence: [restored[0]],
                isCurrent: { true }, fetch: { _ in preconditionFailure("Eager over-budget retry fetched metadata") })
            preconditionFailure("Combined eager retry exceeded byte policy")
        } catch VortxLegacyWatchedMigration.Failure.processingLimit {}
        check(repeatedInput[0] == restored[0], "eager preflight preserves exact original input")
        check(try VortxNativeWatchedArchive.pendingProfileIDs(nearBudget).isEmpty,
              "exact canonical expanded-size accounting admits the last whole receipt below budget")
        let combined = try budgetArchive(Array(repeating: compactRecord, count: fitting / 2),
            Array(repeating: compactRecord, count: fitting - fitting / 2 + 1))
        check(combined.count < 3 * 1_024 * 1_024, "adversarial compact journal is small on disk")
        try rejected("evidence carrier is not a pending receipt") { try VortxNativeWatchedArchive.validate(combined, scope: scope) }
        try processingLimited("eager compatibility entries") {
            _ = try VortxNativeWatchedArchive.entries(combined, key: VortxNativeWatchedArchive.evidenceKey)
        }
        try rejected("malformed pending display") { _ = try VortxNativeWatchedArchive.pendingProfileIDs(combined) }
        try rejected("malformed lazy preparation") { _ = try VortxNativeWatchedArchive.evidenceLookup(combined, scope: scope) }
        do {
            _ = try await VortxNativeWatchedArchive.retryHistorical(combined, scope: scope,
                isCurrent: { true }, fetch: { _ in preconditionFailure("Malformed historical retry fetched") })
            preconditionFailure("Malformed retry proceeded")
        } catch {}
        let inlineContribution = try budgetArchive(Array(repeating: compactRecord, count: fitting),
            [restored[0].base64EncodedString()])
        try processingLimited("legacy inline bytes count toward the same total") {
            _ = try VortxNativeWatchedArchive.entries(inlineContribution, key: VortxNativeWatchedArchive.evidenceKey)
        }
        var brokenRecord = compactRecord
        var brokenFields = try object(Data(base64Encoded: brokenRecord["receiptBase64"] as! String)!)
        brokenFields["metadataResponseSha256"] = String(repeating: "0", count: 64)
        // Noncanonical compact header spelling must be counted after reconstruction, not ignored.
        brokenRecord["receiptBase64"] = (Data(" \n".utf8) + (try encode(brokenFields))).base64EncodedString()
        let malformedOverBudget = try budgetArchive(Array(repeating: brokenRecord, count: fitting + 1), [])
        try rejected("malformed metadata is still rejected without the total work fence") {
            try VortxNativeWatchedArchive.validate(malformedOverBudget, scope: scope)
        }
        var preferences = try VortxNativeHostPreferences(scope: scope, actor: UUID().uuidString.lowercased())
        try preferences.retainAuthenticatedSourceArchive(archive)
        let saved = preferences.local.authenticatedSourceArchive
        try rejected("malformed host retention") { try preferences.retainAuthenticatedSourceArchive(combined) }
        check(preferences.local.authenticatedSourceArchive == saved, "budget rejection leaves authenticated recovery bytes unchanged")
        check(VortxNativeWatchedArchive.Failure.processingLimit.localizedDescription.contains("contact support or update"),
              "preserved-data error provides actionable recovery guidance")
        print("Watched eager compatibility budget: last admitted receipt count=\(fitting), combined compact bytes=\(combined.count); malformed consumers retain original data")
        // A small compact pending journal with many exact duplicates may exceed aggregate
        // expansion, but a streaming retry must fetch only its two distinct unresolved tuples.
        let smallSource = try Self.source(bytes: 65_536)
        let smallPreparation = try await prepare(smallSource, available: false)
        let smallPending = try smallPreparation.pendingArchives
        let smallDraft = try VortxNativeWatchedArchive.retaining(empty, pending: smallPending, scope: scope)
        var captureEnvelope = try object(smallDraft)
        var captureHost = captureEnvelope["hostDocument"] as! Object
        let smallRecords = captureHost[VortxNativeWatchedArchive.pendingKey] as! [Object]
        let pendingCount = (budget - 1_000_000) / smallPending.map(\.count).max()!
        check(pendingCount > 2 && pendingCount < 10_000, "bounded small-source amplification fixture")
        captureHost[VortxNativeWatchedArchive.pendingKey] = [smallRecords[0], smallRecords[1]]
            + Array(repeating: smallRecords[0], count: pendingCount - 2)
        captureEnvelope["hostDocument"] = captureHost
        let captureDraft = try encode(captureEnvelope)
        check(captureDraft.count < 2 * 1_024 * 1_024, "fresh metadata budget fixture remains small on disk")
        let counter = FetchCounter()
        let captureResult = try await VortxNativeWatchedArchive.retryHistorical(captureDraft, scope: scope,
                isCurrent: { true }, fetch: { request in
                    check(await counter.next() <= 2, "duplicates must not trigger extra provider fetches")
                    var payload = try object(metadata(request).raw)
                    payload["padding"] = String(repeating: "m", count: 1_200_000)
                    return .init(request: request, raw: try encode(payload))
                })!
        check(await counter.next() == 3, "exactly two distinct tuples were fetched")
        check(try VortxNativeWatchedArchive.pendingProfileIDs(captureResult).isEmpty,
              "both large metadata captures remain available in the compact result")
        check(try VortxNativeWatchedArchive.pendingProfileIDs(captureDraft) == [owner],
              "original pending journal remains readable after fresh result rejection")
        print("Watched streamed capture: \(pendingCount) duplicate pending entries, two unique large metadata results retained")
        try await VortxNativeWatchedStreamTests.run()

        // Distinct exact sources still consume space: deduplication is not a cap exemption.
        // Full HostPreferences retention, not only helper appenders, conserves opaque host
        // values, outer material/source witnesses and both exclusion receipts through reopen.
        let wrappedBase = try VortxNativeBootstrapArchive.encode(document: encode([
            "ownAccountSources": Object(), "unknown": ["exact": " \\u0061 ", "clock": 123.125],
            "explicitNull": NSNull(), "token": "fixture-only"]), material: encode(["schemaVersion": 1, "held": 123.125]),
            authenticatedSourceArchive: VortxNativeBootstrapArchive.encode(document: encode(["original": "exact"])))
        let wrapped = try VortxNativeWatchedArchive.retaining(wrappedBase,
            evidence: [complete.archives[0]], pending: [originals[0]], scope: scope)
        var conservative = try VortxNativeHostPreferences(scope: scope, actor: UUID().uuidString.lowercased())
        try conservative.retainAuthenticatedSourceArchive(wrapped)
        let updatedBase = try VortxNativeBootstrapArchive.encode(document: encode(["ownAccountSources": Object(),
            "additional": ["safe": true], "password": "second-fixture-only"]))
        let updated = try VortxNativeWatchedArchive.retaining(updatedBase,
            evidence: [complete.archives[1]], pending: [originals[1]], scope: scope)
        try conservative.retainAuthenticatedSourceArchive(updated)
        let conserved = conservative.local.authenticatedSourceArchive!
        let values = try object(conserved), originalValues = try object(wrapped)
        for key in ["legacyImportMaterial", "authenticatedSourceArchive"] {
            check(try encode(values[key]!) == encode(originalValues[key]!), "host persistence retains outer \(key)")
        }
        let conservedHost = values["hostDocument"] as! Object
        check(Set(try VortxNativeWatchedArchive.entries(conserved, key: VortxNativeWatchedArchive.evidenceKey))
              == Set(complete.archives.prefix(2)), "host persistence unions old and incoming watched evidence")
        check(Set(try VortxNativeWatchedArchive.entries(conserved, key: VortxNativeWatchedArchive.pendingKey))
              == Set(originals.prefix(2)), "host persistence unions old and incoming exact pending receipts")
        check(conservedHost[VortxNativeWatchedArchive.sourcesKey] as? [String: String] == pool,
              "host persistence retains the shared exact source pool beside unknown/outer fields")
        check(try encode(conservedHost["unknown"]!) == encode((originalValues["hostDocument"] as! Object)["unknown"]!),
              "host persistence retains unknown field values exactly")
        check(conservedHost["explicitNull"] is NSNull && conservedHost["additional"] != nil,
              "absence does not remove explicit null or disjoint unknown fields")
        check(Set(values["excludedCredentialPaths"] as! [String]) == ["/token", "/password"], "exclusion receipts union")
        let reopened = try VortxNativeHostPreferences(scope: scope, actor: UUID().uuidString.lowercased(), sealed: conservative.encoded())
        check(reopened.local.authenticatedSourceArchive == conserved, "sealed host reopen retains exact recovery bytes")
        var forgedLocal = conservative.local
        var foreignRecord = try object(complete.archives[0])
        foreignRecord["accountId"] = "foreign.fixture"
        let foreignArchive = try VortxNativeBootstrapArchive.encode(document: encode(["ownAccountSources": Object(),
            VortxNativeWatchedArchive.evidenceKey: [try encode(foreignRecord).base64EncodedString()]]))
        forgedLocal.authenticatedSourceArchive = foreignArchive
        try rejected("cold host preferences must bind retained watched evidence to the expected account") {
            _ = try VortxNativeHostPreferences(scope: scope, actor: UUID().uuidString.lowercased(), sealed: JSONEncoder().encode(forgedLocal))
        }
        try conservative.retainAuthenticatedSourceArchive(updated)
        check(conservative.local.authenticatedSourceArchive == conserved, "identical repeated envelope is idempotent")
        let collisions = [try VortxNativeBootstrapArchive.encode(document: encode(["ownAccountSources": Object(), "explicitNull": "changed"])),
            try VortxNativeBootstrapArchive.encode(document: encode(["ownAccountSources": Object()]), material: encode(["schemaVersion": 1, "held": 999]))]
        for collision in collisions {
            do { try conservative.retainAuthenticatedSourceArchive(collision); preconditionFailure("Recovery conflict silently replaced evidence") }
            catch is VortxNativeBootstrapArchive.RecoveryConflict {}
            check(conservative.local.authenticatedSourceArchive == conserved, "recovery conflict leaves previous exact bytes unchanged")
        }
        let inherited = try VortxNativeWatchedArchive.retaining(empty, prior: wrapped, scope: scope)
        check(try object(inherited)["legacyImportMaterial"] != nil, "watched prior union preserves enclosing material")
        let inheritedQuarantine = try VortxNativeUnattributedOverlayArchive.retaining(empty, prior: wrapped,
            document: source, profileIDs: [], scope: scope)
        check(try object(inheritedQuarantine)["authenticatedSourceArchive"] != nil, "quarantine prior union preserves enclosing source")
        print("Recovery envelopes: unknown/null values, immutable outer fields, exclusion unions, idempotence, conflict atomicity and sealed reopen passed")

        var distinct = [Data]()
        for index in 0..<25 {
            var value = try object(source); value["distinct"] = index
            let bytes = try encode(value)
            var receipt = try object(complete.archives[0])
            receipt["sourceDocumentBase64"] = bytes.base64EncodedString()
            receipt["sourceDocumentSha256"] = digest(bytes)
            distinct.append(try encode(receipt))
        }
        try rejected("encoded journal over 32 MiB") {
            _ = try VortxNativeWatchedArchive.retaining(empty, evidence: distinct, scope: scope)
        }
        print("Watched archive: exact-source dedup, dual reads, immutable retry, scope/digest/credential/count/cap fences and enclosing recovery fields passed")
    }
}
