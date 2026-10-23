import Foundation

// UNRUN. Intended main.swift beside production VortxJSON, ForYouInterests, host field mutation,
// CurationCollection, CurationDocument and CurationEdit sources (the same model-harness technique
// as test-for-you-model.sh). This file is not a claim of successful compilation or execution.
var failures = 0
@MainActor func expect(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    if !condition() { failures += 1; print("FAIL \(line): \(message)") }
}
func throwsError(_ body: () throws -> Void) -> Bool {
    do { try body(); return false } catch { return true }
}
func json(_ value: String) -> VortxJSON {
    try! JSONDecoder().decode(VortxJSON.self, from: Data(value.utf8))
}
let legacyRaw = json("""
{"id":"0f8fad5b-d9cb-469f-a165-70867728950e","name":"Films","createdAt":123.5,"home":true,
 "futureEnvelope":{"keep":[1,2]},"rules":{"genres":["drama"],"type":"futureType","sort":"futureSort",
 "hideWatched":true,"futureRule":{"value":42}}}
""")
let legacy = try legacyRaw.decode(SmartCollection.self)
let document = try CurationDocument.make(for: legacy, legacyValue: legacyRaw)
expect(document.id == legacy.id, "existing UUID retained")
let initialProjection = try document.project()
expect(initialProjection.folders[0].sources[0].kind == .legacyRules(collectionID: legacy.id),
       "legacy rule stays a real source")

var renamed = legacy
renamed.name = "Renamed"
let patched = try CurationLegacyPatch.applying(renamed, to: legacyRaw)
expect(patched["futureEnvelope"] == legacyRaw["futureEnvelope"], "legacy rename preserves future envelope")
expect(patched["rules"] == legacyRaw["rules"], "legacy rename preserves unknown type/sort/rule")
renamed.rules.hideWatched = false
let editedRule = try CurationLegacyPatch.applying(renamed, to: legacyRaw)
expect(editedRule["rules"]?["type"] == .string("futureType"), "unmodified unknown type is not coerced")
expect(editedRule["rules"]?["sort"] == .string("futureSort"), "unmodified unknown sort is not coerced")
expect(editedRule["rules"]?["futureRule"] == legacyRaw["rules"]?["futureRule"], "future rule survives")
expect(editedRule["rules"]?["hideWatched"] == .bool(false), "requested known rule changes")

var future = try document.raw.decode([String: VortxJSON].self)
future["futureEnvelope"] = .object(["value": .string("keep")])
var base = try future["base"]!.decode([String: VortxJSON].self)
base["futureBase"] = .bool(true)
future["base"] = .object(base)
future["origin"] = .object(["provider": .string("xperience"), "sourceID": .string("public-definition"),
    "revision": .string("sha256:one"), "futureOrigin": .string("keep")])
let imported = try CurationDocument(raw: .object(future))
let grouped = try imported.addingFolder(name: "More", id: "mine")
    .addingSource(.init(id: "editorial", kind: .curated(collectionID: "group.genres")), folderID: "mine")
    .addingSource(.init(id: "history", kind: .history), folderID: "mine")
    .removingSource("rules", folderID: "rules")
    .orderingFolders(["mine", "rules"])
    .orderingSources(["history", "editorial"], folderID: "mine")
    .settingPinned(true)
var newPresentation = CurationPresentation()
newPresentation.layout = .tabs; newPresentation.tileShape = .square; newPresentation.showAll = false
let styled = try grouped.settingPresentation(newPresentation, comparedTo: .init())
    .settingArtwork(.init(cover: "https://images.example.org/cover.jpg"), comparedTo: .init(), folderID: "mine")
expect(styled.raw["futureEnvelope"] == future["futureEnvelope"], "editing preserves unknown top-level data")
expect(styled.raw["base"] == imported.raw["base"], "local edits never rewrite upstream base")
let projected = try styled.project()
expect(projected.folders.map(\.id) == ["mine", "rules"], "folder ordering is exact")
expect(projected.folders[0].sources.map(\.id) == ["history", "editorial"], "source ordering is exact")
expect(projected.folders[1].sources.isEmpty, "explicit source removal hides original")
expect(projected.pinned && projected.presentation == newPresentation, "presentation overrides apply")

let refreshed = try styled.refreshing(base: imported.raw["base"]!, provider: "xperience",
    sourceID: "public-definition", expectedRevision: "sha256:one", revision: "sha256:two")
expect(refreshed.raw["overrides"] == styled.raw["overrides"], "refresh preserves exact overrides")
let refreshedProjection = try refreshed.project()
expect(refreshedProjection.folders[1].sources.isEmpty, "upstream refresh cannot revive removed source")
expect(refreshed.raw["origin"]?["futureOrigin"] == .string("keep"), "refresh preserves future origin fields")
expect(throwsError {
    _ = try refreshed.refreshing(base: imported.raw["base"]!, provider: "xperience",
        sourceID: "public-definition", expectedRevision: "sha256:one", revision: "sha256:three")
}, "old revision cannot replace a later base")

let register = VortxJSON.object(["clock": .integer(4), "actor": .string("actor"), "value": legacyRaw])
let companion = VortxJSON.object(["clock": .integer(5), "actor": .string("actor"), "value": styled.raw])
let fields = [legacy.field: register, styled.field: companion]
expect(CurationDocument.read(registers: fields, legacy: legacy) != nil, "live legacy exposes companion")
expect(CurationDocument.read(registers: [styled.field: companion], legacy: legacy) == nil,
       "missing legacy cannot resurrect companion")
expect(CurationDocument.read(registers: [legacy.field: .object(["value": .null]), styled.field: companion],
    legacy: legacy) == nil, "old client tombstone hides companion")
var recreatedRaw = try legacyRaw.decode([String: VortxJSON].self)
recreatedRaw["createdAt"] = .number(124)
let recreated = try VortxJSON.object(recreatedRaw).decode(SmartCollection.self)
expect(!styled.matches(recreated), "same UUID with different creation identity rejects stale companion")
let edit = CurationNativeEdit(document: styled, expectedRegister: companion, legacyRegister: register)
try edit.validateAdmission(fields)
expect(throwsError {
    try edit.validateAdmission([legacy.field: .object(["clock": .integer(6), "actor": .string("actor"), "value": legacyRaw])])
}, "same legacy value with a newer event requires a fresh gesture")
expect(!edit.nativeEdit.baselineMatches(.object(["clock": .integer(6), "actor": .string("actor"), "value": styled.raw])),
       "companion event CAS prevents lost updates")

var unsupported = try document.raw.decode([String: VortxJSON].self)
unsupported["base"] = json("""
{"folders":[{"id":"future","name":"Future","sources":[{"id":"u","type":"futureProvider","opaque":{"x":1}}]}]}
""")
let unsupportedDocument = try CurationDocument(raw: .object(unsupported))
let unsupportedProjection = try unsupportedDocument.project()
expect(unsupportedProjection.folders[0].sources[0].kind == .unsupported(type: "futureProvider"),
       "unknown source remains explicitly unsupported")
let unsupportedPinned = try unsupportedDocument.settingPinned(true)
expect(unsupportedPinned.raw["base"] == unsupported["base"],
       "unrelated edit retains unknown provider bytes")
var unknownLayout = unsupported
unknownLayout["base"] = json("""
{"presentation":{"layout":"futureLayout"},"folders":[]}
""")
let retainedLayout = try CurationDocument(raw: .object(unknownLayout))
expect(throwsError { _ = try retainedLayout.project() }, "unsupported layout is not coerced into runnable layout")
let retainedPinned = try retainedLayout.settingPinned(true)
expect(retainedPinned.raw["base"] == unknownLayout["base"],
       "unrelated edit keeps unsupported layout")

var tooLarge = future
tooLarge["padding"] = .array((0..<5).map { _ in .string(String(repeating: "x", count: 4_000)) })
expect(throwsError { _ = try CurationDocument(raw: .object(tooLarge)) }, "total bytes bounded")
var invalidNumber = future
invalidNumber["unknownNumber"] = .unsigned(9_007_199_254_740_992)
expect(throwsError { _ = try CurationDocument(raw: .object(invalidNumber)) }, "future unsafe integer rejected")
invalidNumber["unknownNumber"] = .number(.nan)
expect(throwsError { _ = try CurationDocument(raw: .object(invalidNumber)) }, "nonfinite future number rejected")
expect(throwsError { _ = try styled.addingFolder(name: "Duplicate", id: "mine") }, "duplicate folder rejected")
expect(throwsError { _ = try styled.orderingFolders(["mine", "mine"]) }, "ambiguous order rejected")
expect(throwsError {
    _ = try styled.settingArtwork(.init(cover: "https://images.example.org/a.jpg?key=secret"), comparedTo: .init())
}, "credential-bearing artwork reference rejected")

// V2 review regression: removed upstream folders retain local additions, which still count.
@MainActor func orphanDocument(_ count: Int) throws -> CurationDocument {
    var raw = try document.raw.decode([String: VortxJSON].self)
    raw["base"] = .object(["folders": .array([])])
    var patches: [String: VortxJSON] = [:]
    for index in 0..<count {
        let folder = "orphan-\(index / 8)"
        var additions = patches[folder]?["addedSources"]?.array ?? []
        additions.append(.object(["id": .string("source-\(index)"), "type": .string("history")]))
        patches[folder] = .object(["addedSources": .array(additions)])
    }
    raw["overrides"] = .object(["folders": .object(patches)])
    return try CurationDocument(raw: .object(raw))
}
let retained64 = try orphanDocument(64)
expect(retained64.raw["overrides"]?["folders"]?["orphan-7"]?["addedSources"]?.array?.count == 8,
       "64 retained orphan sources accepted without truncation")
expect(throwsError { _ = try orphanDocument(65) }, "65 retained orphan sources rejected")
expect(throwsError { _ = try orphanDocument(128) }, "review's 128 orphan source payload rejected")
let sevenMore = try (0..<7).reduce(document) { current, index in
    try current.addingSource(.init(id: "extra-\(index)", kind: .history), folderID: "rules")
}
let eightLiveSources = try sevenMore.project().folders[0].sources
expect(eightLiveSources.count == 8, "live added sources count once")
expect(throwsError {
    _ = try sevenMore.addingSource(.init(id: "ninth", kind: .history), folderID: "rules")
}, "per-folder limit retained")
let legacyUpdate = try CurationLegacyEdit.update(renamed, original: legacy, expectedRegister: register)
expect(legacyUpdate.baselineMatches(register), "legacy update owns original register")
expect(!legacyUpdate.baselineMatches(.object(["clock": .integer(6), "actor": .string("actor"), "value": legacyRaw])),
       "newer same-value legacy event cannot be overwritten")
let legacyDelete = try CurationLegacyEdit.deletion(legacy, expectedRegister: register)
expect(legacyDelete.value == .null && legacyDelete.baselineMatches(register), "delete retains exact original CAS")
expect(throwsError { _ = try CurationLegacyEdit.deletion(legacy, expectedRegister: nil) },
       "never delete a new/absent legacy collection")
let newCollection = SmartCollection.make(name: "New", rules: .init(), home: false)
let newEdit = try CurationLegacyEdit.update(newCollection, original: newCollection, expectedRegister: nil)
expect(newEdit.baselineMatches(nil) && !newEdit.baselineMatches(.object(["value": .null])),
       "new collection expects true absence, never revives a tombstone")
let publicBase = json("""
{"folders":[{"id":"acclaimed","name":"Acclaimed","sources":[
{"id":"acclaimed","type":"curated","collectionID":"acclaimed"}]}],"presentation":{"layout":"rows"}}
""")
let publicProjection = try CurationDocument.projectPublicBase(publicBase)
expect(publicProjection.folders.first?.sources.first?.kind == .curated(collectionID: "acclaimed"),
       "public defaults use same bounded projection without profile identity")
expect(throwsError { _ = try CurationDocument.projectPublicBase(document.raw["base"]!) },
       "public defaults cannot nominate a profile legacy-rules source")
var malformedPublic = try publicBase.decode([String: VortxJSON].self)
malformedPublic["futureNumber"] = .number(.infinity)
expect(throwsError { _ = try CurationDocument.projectPublicBase(.object(malformedPublic)) },
       "public defaults share raw future-number bound")

if failures != 0 { fatalError("\(failures) curation checks failed") }
print("PASS: strict6 actual curation models and exact legacy field/CAS witnesses")
