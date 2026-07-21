// Standalone executable gate over the PRODUCTION SOURCES of the title-identity path.
//
//   xcrun swiftc -o /tmp/identity-caller-gate app/Tests/IdentityCallerGateTests.swift \
//     && /tmp/identity-caller-gate
//
// Run from the repo root, or pass the repo root as the single argument. This file has NO dependencies on
// purpose: it must keep working when the app targets do not build.
//
// WHY THIS EXISTS, stated exactly.
//
// Identity resolution had no FORCED ENTRY POINT. Round after round corrected the shared helper, and round
// after round a reviewer found more callers that never consumed it: the two detail screens, then TorBox, then
// `movieStreamId`, then tvOS rendering, then both direct-resume paths, then the batch coordinator. Patching
// callers cannot converge, because nothing fails when a NEW caller derives identity on its own.
//
// The behavioural suite (SourceIndexTorrentContractTests) cannot close that, and previously CLAIMED to. Its
// comment said reverting either view turned the suite red. It did not: that suite compiles the shared module,
// not the views, so a view could be reverted to its inline copy with every assertion still green (mutation
// survivor N22 -- reverting tvOS DetailView.swift's identity read left every suite passing). This file reads
// the view sources themselves, so a view-only revert is a FAILURE here.
//
// WHAT IT DOES NOT CLAIM. It is a source-text gate, not a compiler. It proves that the forbidden shapes are
// absent and the required shapes are present in the named files; it does not prove the surrounding code is
// correct. It also governs the SOURCE-INDEX / TorBox identity path only. Unrelated reads of the shared meta
// slot outside the two fenced detail screens (for example the watchlist chip, which has no page id to fence
// against) are OUT OF SCOPE and are not asserted here.
//
// EVERY RULE PROVES IT CAN FAIL. Phase 2 re-runs each rule against a synthetic fixture carrying the exact
// pre-fix shape, and a rule that does not report a violation there is itself a failure. A gate that cannot go
// red is decoration.

import Foundation

// MARK: - Bounded run

/// A stall must FAIL, not hang. Every phase runs under this watchdog, so a pathological input (an enormous
/// file, a runaway scan) exits non-zero instead of sitting in CI forever.
private let watchdogSeconds = 60.0
private let watchdog = Thread {
    Thread.sleep(forTimeInterval: watchdogSeconds)
    FileHandle.standardError.write(
        Data("FAIL  gate exceeded its \(Int(watchdogSeconds))s bound (a hang is a failure, not a pass)\n".utf8))
    exit(2)
}

// MARK: - Harness

private final class Results {
    var passed = 0
    var failed = 0

    func expect(_ condition: Bool, _ what: String) {
        if condition {
            passed += 1
            print("PASS  \(what)")
        } else {
            failed += 1
            print("FAIL  \(what)")
        }
    }
}

private let results = Results()

// MARK: - Source model

private struct SourceFile {
    let path: String
    let lines: [String]

    /// Line numbers (1-based) whose text contains `needle`, ignoring lines that are pure `//` comments so a
    /// rule's own explanatory prose cannot trip it.
    func lines(containing needle: String, in range: ClosedRange<Int>? = nil) -> [Int] {
        var hits: [Int] = []
        for (index, line) in lines.enumerated() {
            let number = index + 1
            if let range, !range.contains(number) { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") { continue }
            if line.contains(needle) { hits.append(number) }
        }
        return hits
    }

    /// The 1-based line range of a TOP-LEVEL type declaration, from its `struct X`/`enum X`/`class X` line to
    /// the line before the next top-level declaration (or end of file). Top-level declarations in this project
    /// start at column zero, which is what makes this reliable without parsing Swift.
    func topLevelType(_ name: String) -> ClosedRange<Int>? {
        var start: Int?
        for (index, line) in lines.enumerated() {
            let number = index + 1
            guard let declared = topLevelTypeName(line) else { continue }
            if declared == name, start == nil { start = number; continue }
            if start != nil { return start!...(number - 1) }
        }
        if let start { return start...lines.count }
        return nil
    }

    private func topLevelTypeName(_ line: String) -> String? {
        guard line.first?.isWhitespace == false else { return nil }
        var rest = Substring(line)
        for modifier in ["public ", "internal ", "private ", "fileprivate ", "final "] where rest.hasPrefix(modifier) {
            rest = rest.dropFirst(modifier.count)
        }
        for keyword in ["struct ", "enum ", "class ", "actor ", "extension "] where rest.hasPrefix(keyword) {
            let tail = rest.dropFirst(keyword.count)
            let name = tail.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            return name.isEmpty ? nil : String(name)
        }
        return nil
    }
}

private func load(_ root: String, _ relative: String) -> SourceFile? {
    let path = root + "/" + relative
    guard let text = try? String(contentsOfFile: path, encoding: .utf8), !text.isEmpty else { return nil }
    return SourceFile(path: relative, lines: text.components(separatedBy: "\n"))
}

private func synthetic(_ path: String, _ text: String) -> SourceFile {
    SourceFile(path: path, lines: text.components(separatedBy: "\n"))
}

// MARK: - Rules

/// One rule: a name, the production files it governs, and a check that returns human-readable violations.
private struct Rule {
    let name: String
    /// Repo-relative paths this rule reads. Every one must exist; a missing file FAILS the gate rather than
    /// skipping the rule, because a rule that silently covers nothing is the defect this file exists to stop.
    let files: [String]
    let check: ([String: SourceFile]) -> [String]
    /// A synthetic stand-in for each governed file carrying the exact PRE-FIX shape. Phase 2 asserts the rule
    /// reports at least one violation against these, which is what proves the rule can go red.
    let revertedFixture: [String: String]
}

private let viewLayerFiles = [
    "app/SourcesTV/DetailView.swift",
    "app/SourcesTV/HomeView.swift",
    "app/SourcesiOS/iOSDetailView.swift",
    "app/SourcesiOS/iOSRootView.swift",
    "app/SourcesiOS/iOSBatchDownloadCoordinator.swift",
]

private func violations(_ file: SourceFile, forbidding needle: String, why: String,
                        in range: ClosedRange<Int>? = nil) -> [String] {
    file.lines(containing: needle, in: range).map { "\(file.path):\($0) \(why) (`\(needle)`)" }
}

private func requiring(_ file: SourceFile, _ needle: String, why: String) -> [String] {
    file.lines(containing: needle).isEmpty ? ["\(file.path) \(why) (missing `\(needle)`)"] : []
}

private func requiring(_ file: SourceFile, _ needle: String, count: Int, why: String) -> [String] {
    let actual = file.lines(containing: needle).count
    return actual == count ? [] : ["\(file.path) \(why) (expected \(count), found \(actual): `\(needle)`)"]
}

private func replacingOccurrence(_ file: SourceFile, needle: String, occurrence: Int,
                                 with replacement: String) -> SourceFile? {
    var lines = file.lines
    var seen = 0
    for index in lines.indices where lines[index].contains(needle) {
        let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") { continue }
        if seen == occurrence {
            lines[index] = lines[index].replacingOccurrences(of: needle, with: replacement)
            return SourceFile(path: file.path, lines: lines)
        }
        seen += 1
    }
    return nil
}

private func targetBoundaryViolations(_ files: [String: SourceFile]) -> [String] {
    var found: [String] = []
    if let tv = files["app/SourcesTV/DetailView.swift"] {
        found += requiring(tv, "SourceIndexIdentity.publicationTarget(", count: 1,
                           why: "tvOS must derive its one auxiliary target through the forced entry point")
        found += requiring(tv, "torboxSearch.refresh(target: auxiliaryTarget)", count: 2,
                           why: "tvOS TorBox refreshes must consume the typed target")
        found += requiring(tv, "sourceIndex.refresh(target: auxiliaryTarget,", count: 1,
                           why: "tvOS SourceIndex refresh must consume the same typed target")
        found += requiring(tv, "for: auxiliaryTarget", count: 3,
                           why: "tvOS manual merges must validate the exact selected target")
    }
    if let ios = files["app/SourcesiOS/iOSDetailView.swift"] {
        found += requiring(ios, "SourceIndexIdentity.publicationTarget(", count: 2,
                           why: "iOS movie and episode producers must each use the forced entry point")
        found += requiring(ios, "torboxSearch.refresh(target: auxiliaryTarget)", count: 2,
                           why: "iOS movie TorBox refreshes must consume the typed target")
        found += requiring(ios, "torboxSearch.refresh(target: episodeAuxiliaryTarget)", count: 2,
                           why: "iOS episode TorBox refreshes must consume the typed target")
        found += requiring(ios, "sourceIndex.refresh(target: auxiliaryTarget,", count: 1,
                           why: "iOS movie SourceIndex refresh must consume the same typed target")
        found += requiring(ios, "sourceIndex.refresh(target: episodeAuxiliaryTarget,", count: 1,
                           why: "iOS episode SourceIndex refresh must consume the same typed target")
        found += requiring(ios, "for: auxiliaryTarget", count: 5,
                           why: "iOS movie merges must validate the exact selected target")
        found += requiring(ios, "for: episodeAuxiliaryTarget", count: 5,
                           why: "iOS episode merges must validate the exact selected target")
    }
    if let batch = files["app/SourcesiOS/iOSBatchDownloadCoordinator.swift"] {
        found += requiring(batch, "SourceIndexIdentity.publicationTarget(", count: 1,
                           why: "batch must derive one target for the selected job")
        found += requiring(batch, "resolveAndQueue(job, auxiliaryTarget: target)", count: 1,
                           why: "batch must carry the same target into rank and download assembly")
        found += requiring(batch, "torboxSearch.refresh(target: target)", count: 1,
                           why: "batch TorBox refresh must consume the job target")
        found += requiring(batch, "sourceIndex.refresh(target: target,", count: 1,
                           why: "batch SourceIndex refresh must consume the job target")
        found += requiring(batch, "for: auxiliaryTarget", count: 2,
                           why: "batch merges must validate the exact job target")
    }
    for file in files.values {
        found += violations(file, forbidding: "SourceIndexClient.contentID(roles:",
                            why: "bypasses the forced typed publication target")
        found += violations(file, forbidding: "torboxSearch.refresh(imdbId:",
                            why: "lets a caller give TorBox a separately derived identity")
        found += violations(file, forbidding: "sourceIndex.refresh(contentID:",
                            why: "lets a caller give SourceIndex a separately derived identity")
    }
    return found
}

private let rules: [Rule] = [

    // R1. Key construction is centralized. A screen states ROLES; it never assembles a pool key from a bare
    // string, and it never reaches into the contract's canonicalizers. Those are the shapes every previous
    // round's stray caller had.
    Rule(
        name: "R1 no view or coordinator builds a pool key from a bare identifier",
        files: viewLayerFiles,
        check: { files in
            files.values.flatMap { file -> [String] in
                violations(file, forbidding: "SourceIndexClient.contentID(imdbId:",
                           why: "builds a pool key from a bare id; state roles via publicationTarget(_:)")
                + violations(file, forbidding: "SourceIndexContract.canonicalTitleID(",
                             why: "canonicalizes identity independently of the shared resolver")
                + violations(file, forbidding: "SourceIndexContract.canonicalContentID(",
                             why: "applies the pool key gate independently of the shared resolver")
                + violations(file, forbidding: "SourceIndexIdentity.contentKey(",
                             why: "composes a key directly; go through publicationTarget(_:) or resumeContentID")
            }
        },
        revertedFixture: [
            "app/SourcesiOS/iOSDetailView.swift":
                "    private var sourceContentID: String? {\n"
                + "        SourceIndexClient.contentID(imdbId: titleIdentity.indexID)\n    }\n",
        ]
    ),

    // R2. The authority-free ordered-array resolver is GONE, not merely unused. Order silently encoded
    // authority and encoded it wrongly, so its reappearance anywhere is a regression by itself.
    Rule(
        name: "R2 the ordered-candidate resolver cannot come back",
        files: viewLayerFiles + [
            "app/SourcesShared/SourceIndexIdentity.swift",
            "app/SourcesShared/SourceIndexClient.swift",
            "app/SourcesShared/TorBoxSearchSource.swift",
        ],
        check: { files in
            files.values.flatMap {
                violations($0, forbidding: "SourceIndexIdentity.preferred(",
                           why: "the ordered-candidate resolver is removed; use resolve(Roles)")
                + violations($0, forbidding: "preferred(candidates:",
                             why: "identity inputs are named ROLES, never an ordered array")
            }
        },
        revertedFixture: [
            "app/SourcesTV/DetailView.swift":
                "    private var sourceIndexIdentityID: String? {\n"
                + "        SourceIndexIdentity.preferred(candidates: [dv, id]).indexID\n    }\n",
        ]
    ),

    // R3. The id fence. This is mutation survivor N22: reverting tvOS DetailView's identity read to the raw
    // singleton shape left every suite green because no suite compiled or read that file.
    Rule(
        name: "R3 both detail screens read the shared meta slot ONLY through the id fence",
        files: ["app/SourcesTV/DetailView.swift", "app/SourcesiOS/iOSDetailView.swift"],
        check: { files in
            var found: [String] = []
            let fenced = [
                ("app/SourcesTV/DetailView.swift", "DetailView"),
                ("app/SourcesiOS/iOSDetailView.swift", "iOSDetailView"),
            ]
            for (path, type) in fenced {
                guard let file = files[path] else { continue }
                guard let range = file.topLevelType(type) else {
                    found.append("\(path) has no top-level type \(type); the fence rule covers nothing")
                    continue
                }
                for line in file.lines(containing: "core.metaDetails?.meta", in: range)
                where !file.lines[line - 1].contains("ResidentMeta.fenced(") {
                    found.append("\(path):\(line) reads the shared meta slot unfenced inside \(type)")
                }
                found += requiring(file, "ResidentMeta.fenced(",
                                   why: "must consume the shared id fence")
            }
            return found
        },
        revertedFixture: [
            "app/SourcesTV/DetailView.swift":
                "struct DetailView: View {\n"
                + "    var body: some View {\n"
                + "        if let meta = core.metaDetails?.meta {\n            hero(meta)\n        }\n    }\n}\n",
            "app/SourcesiOS/iOSDetailView.swift":
                "struct iOSDetailView: View {\n"
                + "    private var meta: CoreMetaItem? {\n"
                + "        let m = core.metaDetails?.meta\n        return m?.id == id ? m : nil\n    }\n}\n",
        ]
    ),

    // R4. No identity-bearing read of the shared slot anywhere in the view layers. This is the `movieStreamId`
    // defect: it read the singleton AROUND the residency guard, so title B could dispatch title A's default
    // video id even on the screen that did have a fence.
    Rule(
        name: "R4 no screen reads an identity out of the unfenced shared meta slot",
        files: viewLayerFiles,
        check: { files in
            files.values.flatMap {
                violations($0, forbidding: "metaDetails?.meta?.behaviorHints",
                           why: "reads an identity from the shared slot around the residency guard")
            }
        },
        revertedFixture: [
            "app/SourcesiOS/iOSDetailView.swift":
                "    private var movieStreamId: String {\n"
                + "        if let dv = core.metaDetails?.meta?.behaviorHints?.defaultVideoId, !dv.isEmpty,"
                + " dv != id { return dv }\n        return id\n    }\n",
        ]
    ),

    // R5. Both direct-resume paths. They have TWO independent ids and no page to arbitrate, so they take the
    // dedicated entry that compares canonical TITLE HEADS. The old guards compared episode NUMBERS, which
    // matched in the failure case and therefore caught nothing.
    Rule(
        name: "R5 both direct-resume paths key the pool through the resume identity fence",
        files: ["app/SourcesTV/HomeView.swift", "app/SourcesiOS/iOSRootView.swift"],
        check: { files in
            files.values.flatMap {
                requiring($0, "SourceIndexClient.resumeContentID(",
                          why: "a direct resume must key the pool through the resume identity fence")
                + violations($0, forbidding: "SourceIndexClient.contentID(",
                             why: "a direct resume must not build a key from the item id alone")
            }
        },
        revertedFixture: [
            "app/SourcesTV/HomeView.swift":
                "        if let cid = SourceIndexClient.contentID(imdbId: item.id, season: entry.season,"
                + " episode: entry.episode) {\n            hoard(cid)\n        }\n",
        ]
    ),

    // R6. REQ-260721-50: every governed producer consumes the ONE typed publication target, and every manual
    // merge validates the fetched owner's exact target. The check also mutates each REAL entry-point call in
    // memory and proves the rule turns red, so an unused helper or a substring parked in a comment cannot pass.
    Rule(
        name: "R6 every auxiliary producer consumes one typed target and exact merge fence",
        files: [
            "app/SourcesTV/DetailView.swift",
            "app/SourcesiOS/iOSDetailView.swift",
            "app/SourcesiOS/iOSBatchDownloadCoordinator.swift",
        ],
        check: { files in
            var found = targetBoundaryViolations(files)
            if found.isEmpty {
                let mutations = [
                    ("app/SourcesTV/DetailView.swift", 0),
                    ("app/SourcesiOS/iOSDetailView.swift", 0),
                    ("app/SourcesiOS/iOSDetailView.swift", 1),
                    ("app/SourcesiOS/iOSBatchDownloadCoordinator.swift", 0),
                ]
                for (path, occurrence) in mutations {
                    guard let file = files[path],
                          let mutant = replacingOccurrence(
                              file,
                              needle: "SourceIndexIdentity.publicationTarget(",
                              occurrence: occurrence,
                              with: "SourceIndexIdentity.resolve("
                          ) else {
                        found.append("\(path) could not mutate real publication-target call \(occurrence)")
                        continue
                    }
                    var mutated = files
                    mutated[path] = mutant
                    if targetBoundaryViolations(mutated).isEmpty {
                        found.append("\(path) real caller mutation \(occurrence) survived R6")
                    }
                }
            }
            return found
        },
        revertedFixture: [
            "app/SourcesiOS/iOSBatchDownloadCoordinator.swift":
                "        guard let season, season >= 0, let episode, episode > 0 else { return }\n"
                + "        torboxSearch.refresh(imdbId: job.seriesImdbId, season: season, episode: episode)\n",
        ]
    ),

    // R7. Every governed screen actually states roles. Without this, deleting an identity call site entirely
    // would satisfy every forbidding rule above by saying nothing at all.
    Rule(
        name: "R7 every governed screen states its identity ROLES",
        files: [
            "app/SourcesTV/DetailView.swift",
            "app/SourcesiOS/iOSDetailView.swift",
            "app/SourcesiOS/iOSBatchDownloadCoordinator.swift",
        ],
        check: { files in
            files.values.flatMap {
                requiring($0, "SourceIndexIdentity.Roles",
                          why: "must state named identity roles rather than pick an id")
            }
        },
        revertedFixture: [
            "app/SourcesTV/DetailView.swift": "struct DetailView: View {\n    var body: some View { EmptyView() }\n}\n",
        ]
    ),

    // R8. The shared module keeps the properties the screens now depend on: one IMDb-only key gate, and a
    // resolver whose inputs are roles. Stated positively so gutting the module is a failure here too.
    Rule(
        name: "R8 the shared identity module keeps its IMDb-only key gate and role-aware resolver",
        files: ["app/SourcesShared/SourceIndexContract.swift", "app/SourcesShared/SourceIndexIdentity.swift"],
        check: { files in
            var found: [String] = []
            if let contract = files["app/SourcesShared/SourceIndexContract.swift"] {
                found += requiring(contract, #"^tt[0-9]{6,10}(:[0-9]{1,4}:[0-9]{1,4})?$"#,
                                   why: "the pool key gate must stay IMDb-only")
            }
            if let identity = files["app/SourcesShared/SourceIndexIdentity.swift"] {
                found += requiring(identity, "static func resolve(_ roles: Roles)",
                                   why: "the role-aware resolver must exist")
                found += requiring(identity, "case mismatch",
                                   why: "conflicting valid heads must remain a typed result")
                found += requiring(identity, "static func publicationTarget(",
                                   why: "the forced publication-target entry point must exist")
                found += requiring(identity, "static func resumeKey(",
                                   why: "the resume identity fence must exist")
                found += requiring(identity, "enum ResidentMeta",
                                   why: "the id fence must exist")
            }
            return found
        },
        revertedFixture: [
            "app/SourcesShared/SourceIndexContract.swift":
                "    static func canonicalContentID(_ raw: String) -> String? {\n"
                + "        raw.range(of: #\"^(tt[0-9]{6,10}|tmdb:[0-9]{1,10})(:[0-9]{1,4}:[0-9]{1,4})?$\"#,\n"
                + "                  options: .regularExpression) != nil ? raw : nil\n    }\n",
        ]
    ),
]

// MARK: - Run

watchdog.start()

let arguments = CommandLine.arguments
let repoRoot = arguments.count > 1 ? arguments[1] : FileManager.default.currentDirectoryPath

// Phase 0: every governed file must be present and readable. A rule whose files vanished covers nothing, and
// a gate that quietly covers nothing is exactly the failure mode this file was written to end.
private var loaded: [String: SourceFile] = [:]
private var missing: [String] = []
for path in Set(rules.flatMap(\.files)).sorted() {
    if let file = load(repoRoot, path) {
        loaded[path] = file
    } else {
        missing.append(path)
    }
}
results.expect(missing.isEmpty,
               "GATE: every governed production source is present and readable"
               + (missing.isEmpty ? "" : " (missing: \(missing.joined(separator: ", ")))"))

// Phase 1: the real tree must be clean.
for rule in rules {
    let governed = loaded.filter { rule.files.contains($0.key) }
    let found = governed.isEmpty ? ["\(rule.name): no governed file loaded"] : rule.check(governed)
    if !found.isEmpty { for violation in found.sorted() { print("      \(violation)") } }
    results.expect(found.isEmpty, rule.name)
}

// Phase 2: every rule must REJECT the pre-fix shape it was written for. A rule that stays green against its
// own reverted fixture is a rule that cannot fail, which is worth less than no rule.
for rule in rules {
    var fixtures = loaded.filter { rule.files.contains($0.key) }
    for (path, text) in rule.revertedFixture { fixtures[path] = synthetic(path, text) }
    results.expect(!rule.check(fixtures).isEmpty,
                   "MUTANT: \(rule.name) goes RED against the reverted shape")
}

print("")
print(results.failed == 0
      ? "ALL PASS (\(results.passed) checks)"
      : "FAILURES: \(results.failed) of \(results.passed + results.failed) checks")
exit(results.failed == 0 ? 0 : 1)
