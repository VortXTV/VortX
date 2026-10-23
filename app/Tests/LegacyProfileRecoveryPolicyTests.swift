import Foundation

@main enum LegacyProfileRecoveryPolicyTests {
    static func check(_ condition: Bool, _ message: String) { precondition(condition, message) }
    static func main() async throws {
        let a = "  {\"unknown-profile\":{\"exact\":\"\\u0061\"}}\n"
        let b = "{\"different\":true}"
        func item(_ id: String, _ payload: Any) -> [String: Any] { ["_id": id, "state": ["watched": payload]] }
        let id = "stremiox:watch:90000000-0000-0000-0000-000000000009"
        let original = LegacyProfileRecoveryPolicy.recovery([item(id, a)])
        check(original.requiresSafeRepair && original.salvaged[id].map { Data($0.utf8) } == Data(a.utf8), "exact unknown original preserved for export, not interpreted or rewritten")
        let ambiguous = LegacyProfileRecoveryPolicy.recovery([item(id, a), item(id, b), item(id, a)])
        check(ambiguous.requiresSafeRepair && ambiguous.salvaged[id] == nil, "ambiguous duplicate cannot reappear after a third record")
        let invalid = LegacyProfileRecoveryPolicy.recovery([item(id, 123)])
        check(invalid.requiresSafeRepair && invalid.salvaged.isEmpty, "unreadable watched payload is not falsely certified clean")
        let clean = LegacyProfileRecoveryPolicy.recovery([item(id, ""), item("tt123", "unchanged")])
        check(!clean.requiresSafeRepair && clean.salvaged.isEmpty, "already-clean records remain a positive control")
        let fitting = Dictionary(uniqueKeysWithValues: (0..<120).map { ("title-\($0)", $0) })
        let encoded = try LegacyProfileRecoveryPolicy.completeMirrorPayload(fitting)
        check(try JSONDecoder().decode([String: Int].self, from: encoded) == fitting, "all120 titles survive complete mirror encoding")
        var excess = fitting; excess["oldest-title"] = -1
        do { _ = try LegacyProfileRecoveryPolicy.completeMirrorPayload(excess); preconditionFailure("oversized mirror silently truncated") }
        catch LegacyProfileRecoveryPolicy.Failure.mirrorCapacity {}
        check(excess.count == 121 && excess["oldest-title"] == -1, "capacity rejection leaves complete original snapshot intact")
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let sync = try String(contentsOf: root.appendingPathComponent("app/SourcesShared/ProfileSync.swift"), encoding: .utf8)
        check(!sync.contains("await putLibraryItem("), "legacy inspection has no destructive datastore scrub call")
        check(!sync.contains(".prefix(120)"), "legacy mirror never truncates by count")
        check(sync.contains("LegacyProfileRecoveryPolicy.completeMirrorPayload(watch)"), "actual mirror call site uses complete policy before transport")
        let profiles = try String(contentsOf: root.appendingPathComponent("app/SourcesShared/Profiles.swift"), encoding: .utf8)
        let start = profiles.range(of: "func bootstrapSync()")!.lowerBound
        let end = profiles.range(of: "private func importProfilesFromStremio", range: start..<profiles.endIndex)!.lowerBound
        let bootstrap = profiles[start..<end]
        check(bootstrap.contains("Task { @MainActor [weak self] in"), "actual post-await inspection notice publication stays on the UI actor")
        check(!bootstrap.contains("migrateSalvagedWatch("), "UUID-only poison payload cannot auto-adopt into current roster")
        check(bootstrap.contains("legacyHistoryNoticeState.inspected") && bootstrap.contains("Data(key.utf8)"), "recovery notice remains fenced to the captured credential")
        let view = try String(contentsOf: root.appendingPathComponent("app/SourcesShared/ProfilesView.swift"), encoding: .utf8)
        try await LegacyWatchOwnershipTests.run(root: root)
        try await LegacyProfileLifecycleTests.run(root: root)
        check(view.contains("if let notice = store.legacyHistoryRecoveryNotice { return notice }"), "legacy recovery notice reaches actual profile picker error surface")
        print("Legacy recovery: original remote data never scrubbed, ambiguous/unknown records not auto-adopted, 120-row full mirror positive control and121-row no-write capacity guard passed; callsite contracts verified")
    }
}
