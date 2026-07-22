// Standalone production-wiring and mutation gate for the debrid credential ordering contract.
//
//   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc \
//     -parse-as-library app/Tests/DebridCredentialCallerGateTests.swift \
//     -o /tmp/debrid-credential-callers && /tmp/debrid-credential-callers
//
// This supplements the behavioral state suite by reading the exact production consumers. Every rule also
// runs against one focused reverted fixture, so a rule that cannot detect its named regression fails here.

import Foundation

private struct SourceFile: Sendable {
    let path: String
    let text: String

    var code: String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}

private struct Rule: Sendable {
    let name: String
    let files: [String]
    let violations: @Sendable ([String: SourceFile]) -> [String]
    let reverted: [String: String]
}

private struct Mutation: Sendable {
    let name: String
    let rule: String
    let path: String
    let find: String
    let replacement: String
}

private func load(root: String, path: String) -> SourceFile? {
    let absolute = root + "/" + path
    guard let text = try? String(contentsOfFile: absolute, encoding: .utf8) else { return nil }
    return SourceFile(path: path, text: text)
}

private func require(_ file: SourceFile, _ needle: String, _ reason: String) -> [String] {
    file.code.contains(needle) ? [] : ["\(file.path): missing \(reason) (`\(needle)`)"]
}

private func forbid(_ file: SourceFile, _ needle: String, _ reason: String) -> [String] {
    file.code.contains(needle) ? ["\(file.path): \(reason) (`\(needle)`)"] : []
}

private func section(_ file: SourceFile, start: String, end: String) -> SourceFile? {
    guard let startRange = file.code.range(of: start),
          let endRange = file.code.range(of: end, range: startRange.upperBound..<file.code.endIndex) else {
        return nil
    }
    return SourceFile(path: file.path, text: String(file.code[startRange.lowerBound..<endRange.lowerBound]))
}

private func occurrenceCount(_ needle: String, in text: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    return text.components(separatedBy: needle).count - 1
}

private func ordered(_ file: SourceFile, start: String, end: String,
                     required: String, before mutation: String, reason: String) -> [String] {
    guard let startRange = file.code.range(of: start),
          let endRange = file.code.range(of: end, range: startRange.upperBound..<file.code.endIndex) else {
        return ["\(file.path): cannot isolate \(reason) function"]
    }
    let block = String(file.code[startRange.lowerBound..<endRange.lowerBound])
    guard let gate = block.range(of: required), let write = block.range(of: mutation),
          gate.lowerBound < write.lowerBound else {
        return ["\(file.path): \(reason) does not validate before mutation"]
    }
    return []
}

private let rules: [Rule] = [
    Rule(
        name: "snapshot publication and coordinator acceptance are strictly monotonic",
        files: ["app/SourcesShared/DebridCredentialState.swift"],
        violations: { files in
            guard let file = files.values.first else { return ["missing credential state"] }
            return require(file, "guard snapshot.revision > value.revision else { return false }",
                           "strictly newer snapshot publication")
                + require(file, "snapshot.revision <= appliedRevision",
                          "equal and older coordinator rejection")
        },
        reverted: [
            "app/SourcesShared/DebridCredentialState.swift":
                "guard snapshot.revision >= value.revision else { return false }\n"
                + "if snapshot.revision < appliedRevision { return false }",
        ]
    ),
    Rule(
        name: "canonical owners keep account and device storage disjoint",
        files: ["app/SourcesShared/DebridCredentialState.swift"],
        violations: { files in
            guard let file = files.values.first else { return ["missing credential state"] }
            let canonical =
                "static func canonicalAccount(_ raw: String) -> DebridOwnerScope? {\n"
                + "        guard let uuid = UUID(uuidString: raw), "
                + "uuid.uuidString.lowercased() == raw else { return nil }\n"
                + "        return .account(uuid)\n"
                + "    }"
            return require(file, canonical, "fail-closed canonical account parser")
                + require(file,
                          "return \"vortx.debrid.v2.\" + rawValue + \".account.\" + "
                          + "uuid.uuidString.lowercased()",
                          "disjoint versioned account namespace")
                + require(file, "return \"vortx.debrid.\" + rawValue + \".local\"",
                          "permanent signed-out device namespace")
        },
        reverted: [
            "app/SourcesShared/DebridCredentialState.swift":
                "static func canonicalAccount(_ raw: String) -> DebridOwnerScope? {\n"
                + "if raw.isEmpty { return .signedOutDevice }; return .account(UUID())\n}\n"
                + "case signedOutDevice: return \"vortx.debrid.key.local\"\n"
                + "case account: return \"vortx.debrid.key.local\"",
        ]
    ),
    Rule(
        name: "typed main-actor owner publishes immutable snapshots",
        files: ["app/SourcesShared/DebridKeys.swift"],
        violations: { files in
            guard let file = files.values.first else { return ["missing DebridKeys"] }
            return require(file, "@MainActor\nfinal class DebridKeys", "one main-actor mutable owner")
                + require(file, "DebridOwnerScope", "typed owner scope")
                + require(file, "DebridCredentialSnapshotStore.shared.publish", "synchronous snapshot publication")
                + forbid(file, "func bind(owner newOwner: String)", "raw String owner bind remains")
        },
        reverted: ["app/SourcesShared/DebridKeys.swift": "final class DebridKeys { func bind(owner newOwner: String) {} }"]
    ),
    Rule(
        name: "remote apply is one atomic no-echo mutation",
        files: ["app/SourcesShared/DebridKeys.swift", "app/SourcesShared/VortXSyncManager.swift"],
        violations: { files in
            guard let keys = files["app/SourcesShared/DebridKeys.swift"],
                  let sync = files["app/SourcesShared/VortXSyncManager.swift"] else { return ["missing remote files"] }
            guard let remoteApply = section(keys, start: "func applyRemoteKeys",
                                            end: "private func publish") else {
                return ["\(keys.path): cannot isolate remote apply function"]
            }
            return require(keys, "func applyRemoteKeys", "dedicated remote mutation")
                + require(sync, "debrid.applyRemoteKeys", "one remote apply call")
                + forbid(sync, "debrid.setKey(", "remote sync still fans out through setKey")
                + forbid(sync, "reload(keys:", "remote sync retains a raw fifth reload")
                + forbid(remoteApply, "requestSyncSoon()", "remote apply schedules a sync echo")
        },
        reverted: [
            "app/SourcesShared/DebridKeys.swift": "func setKey() {}",
            "app/SourcesShared/VortXSyncManager.swift": "debrid.setKey(v, for: .torBox)\nreload(keys: raw)",
        ]
    ),
    Rule(
        name: "coordinator accepts only typed newer snapshots",
        files: ["app/SourcesShared/DebridResolver.swift"],
        violations: { files in
            guard let file = files.values.first else { return ["missing resolver"] }
            return require(file, "func reload(snapshot: DebridCredentialSnapshot)", "typed reload API")
                + require(file, "guard revisionFence.accept(snapshot) else { return false }",
                          "load-bearing equal and older revision rejection")
                + require(file, "ensureCurrentSnapshot()", "pre-operation catch-up")
                + require(
                    file,
                    "func resolve(service: DebridService? = nil, infoHash: String, magnet: String,\n"
                    + "                 fileIdx: Int?, episode: DebridEpisode?) async throws -> URL {\n"
                    + "        let revision = ensureCurrentSnapshot().revision",
                    "snapshot-store catch-up before resolve"
                )
                + forbid(file, "reload(keys:", "raw reload API remains")
                + forbid(file, "didWarm", "lazy warm retains an independent authority flag")
        },
        reverted: ["app/SourcesShared/DebridResolver.swift": "var didWarm = false\nfunc reload(keys: [String: String]) {}"]
    ),
    Rule(
        name: "credential use and result publication are revision fenced",
        files: ["app/SourcesShared/DebridResolver.swift"],
        violations: { files in
            guard let file = files.values.first else { return ["missing resolver"] }
            guard let wrapper = section(file, start: "private func withCurrentCredential",
                                        end: "var hasUsenetResolver: Bool") else {
                return ["\(file.path): cannot isolate credential-use wrapper"]
            }
            return require(wrapper,
                           "guard credentialStore.isCurrent(revision: revision) "
                           + "else { throw DebridError.credentialsChanged }",
                           "credential-use revision check")
                + require(wrapper,
                          "guard credentialStore.resultIsCurrent(revision: revision) "
                          + "else { throw DebridError.credentialsChanged }",
                          "post-await result revision check")
        },
        reverted: [
            "app/SourcesShared/DebridResolver.swift":
                "func withCurrentCredential() async { let result = await provider.call(); publish(result) }",
        ]
    ),
    Rule(
        name: "detached configured-service reads use the immutable store",
        files: ["app/SourcesShared/CoreModels.swift"],
        violations: { files in
            guard let file = files.values.first else { return ["missing CoreModels"] }
            return require(file, "DebridCredentialSnapshotStore.shared.isConfigured(.torBox)",
                           "detached immutable configured-service query")
                + forbid(file, "DebridKeys.shared.isConfigured(.torBox)",
                         "detached code still reads the mutable owner")
        },
        reverted: ["app/SourcesShared/CoreModels.swift": "if DebridKeys.shared.isConfigured(.torBox) {}"]
    ),
    Rule(
        name: "restore and adopt validate canonical account owners before mutation",
        files: ["app/SourcesShared/VortXSyncManager.swift"],
        violations: { files in
            guard let file = files.values.first else { return ["missing sync manager"] }
            return ordered(file, start: "private func restore()", end: "func signOut()",
                           required: "DebridOwnerScope.canonicalAccount(p.account.id)",
                           before: "SourceIndexLifecycleScope.shared.sessionWillMutate()",
                           reason: "restore")
                + ordered(file, start: "private func adopt(", end: "enum AuthResult",
                          required: "DebridOwnerScope.canonicalAccount(accountID)",
                          before: "SourceIndexLifecycleScope.shared.sessionWillMutate()",
                          reason: "adopt")
                + forbid(file, "DebridKeys.shared.bind(owner: p.account.id)",
                         "restore still binds a raw account id")
        },
        reverted: [
            "app/SourcesShared/VortXSyncManager.swift":
                "func restore() { token = p.token; DebridKeys.shared.bind(owner: p.account.id) }\n"
                + "func adopt() { self.token = token; self.dataKey = dataKey; self.account = Account() }",
        ]
    ),
    Rule(
        name: "migration has typed disjoint names and verified persistence",
        files: ["app/SourcesShared/DebridCredentialState.swift", "app/SourcesShared/Keychain.swift"],
        violations: { files in
            guard let state = files["app/SourcesShared/DebridCredentialState.swift"],
                  let keychain = files["app/SourcesShared/Keychain.swift"] else { return ["missing migration files"] }
            return require(state, "uuid.uuidString.lowercased() == raw", "exact lowercase UUID round-trip")
                + require(state, "legacyRawAccountKeychainAccount", "per-account raw migration source")
                + require(state, "read(target) == value", "exact migration readback")
                + require(keychain, "@discardableResult", "persistence result")
                + require(keychain, "static func set(_ value: String?, for account: String) -> Bool",
                          "Boolean persistence result")
                + require(keychain, "guard save(store) else { return false }",
                          "failed macOS persistence rejection")
                + require(keychain, "return load()[account] == value",
                          "macOS exact persistence readback")
                + require(keychain, "return string(account) == value",
                          "iOS and tvOS exact persistence readback")
        },
        reverted: [
            "app/SourcesShared/DebridCredentialState.swift":
                "if UUID(uuidString: raw) != nil { migrate() }\nwrite(value, target)\ndelete(source)",
            "app/SourcesShared/Keychain.swift": "static func set(_ value: String?, for account: String) {}",
        ]
    ),
]

private let mutations: [Mutation] = [
    Mutation(
        name: "M01 allow equal snapshot publication",
        rule: "snapshot publication and coordinator acceptance are strictly monotonic",
        path: "app/SourcesShared/DebridCredentialState.swift",
        find: "guard snapshot.revision > value.revision else { return false }",
        replacement: "guard snapshot.revision >= value.revision else { return false }"
    ),
    Mutation(
        name: "M02 remove coordinator revision rejection",
        rule: "coordinator accepts only typed newer snapshots",
        path: "app/SourcesShared/DebridResolver.swift",
        find: "guard revisionFence.accept(snapshot) else { return false }",
        replacement: "_ = revisionFence.accept(snapshot)"
    ),
    Mutation(
        name: "M03 restore raw reload API",
        rule: "coordinator accepts only typed newer snapshots",
        path: "app/SourcesShared/DebridResolver.swift",
        find: "func reload(snapshot: DebridCredentialSnapshot) -> Bool {",
        replacement: "func reload(keys: [String: String]) {}\n\n"
            + "    func reload(snapshot: DebridCredentialSnapshot) -> Bool {"
    ),
    Mutation(
        name: "M04 bypass snapshot store before resolve",
        rule: "coordinator accepts only typed newer snapshots",
        path: "app/SourcesShared/DebridResolver.swift",
        find: "func resolve(service: DebridService? = nil, infoHash: String, magnet: String,\n"
            + "                 fileIdx: Int?, episode: DebridEpisode?) async throws -> URL {\n"
            + "        let revision = ensureCurrentSnapshot().revision",
        replacement: "func resolve(service: DebridService? = nil, infoHash: String, magnet: String,\n"
            + "                 fileIdx: Int?, episode: DebridEpisode?) async throws -> URL {\n"
            + "        let revision = appliedSnapshot?.revision ?? 0"
    ),
    Mutation(
        name: "M05 remove post-await revision check",
        rule: "credential use and result publication are revision fenced",
        path: "app/SourcesShared/DebridResolver.swift",
        find: "guard credentialStore.resultIsCurrent(revision: revision) "
            + "else { throw DebridError.credentialsChanged }",
        replacement: "_ = result"
    ),
    Mutation(
        name: "M06 restore remote setKey fan-out",
        rule: "remote apply is one atomic no-echo mutation",
        path: "app/SourcesShared/VortXSyncManager.swift",
        find: "debrid.applyRemoteKeys(remoteDebrid)",
        replacement: "if let v = keys[\"realDebrid\"] { debrid.setKey(v, for: .realDebrid) }\n"
            + "            if let v = keys[\"allDebrid\"] { debrid.setKey(v, for: .allDebrid) }\n"
            + "            if let v = keys[\"premiumize\"] { debrid.setKey(v, for: .premiumize) }\n"
            + "            if let v = keys[\"torBox\"] { debrid.setKey(v, for: .torBox) }"
    ),
    Mutation(
        name: "M07 let remote apply schedule sync",
        rule: "remote apply is one atomic no-echo mutation",
        path: "app/SourcesShared/DebridKeys.swift",
        find: "guard let snapshot = state.applyRemoteKeys(normalized) else { return }\n"
            + "        publish(snapshot)\n"
            + "    }",
        replacement: "guard let snapshot = state.applyRemoteKeys(normalized) else { return }\n"
            + "        publish(snapshot)\n"
            + "        Task { @MainActor in VortXSyncManager.shared.requestSyncSoon() }\n"
            + "    }"
    ),
    Mutation(
        name: "M08 remove DebridKeys main-actor isolation",
        rule: "typed main-actor owner publishes immutable snapshots",
        path: "app/SourcesShared/DebridKeys.swift",
        find: "@MainActor\nfinal class DebridKeys",
        replacement: "final class DebridKeys"
    ),
    Mutation(
        name: "M09 restore detached mutable-owner read",
        rule: "detached configured-service reads use the immutable store",
        path: "app/SourcesShared/CoreModels.swift",
        find: "DebridCredentialSnapshotStore.shared.isConfigured(.torBox)",
        replacement: "DebridKeys.shared.isConfigured(.torBox)"
    ),
    Mutation(
        name: "M10 delete migration readback condition",
        rule: "migration has typed disjoint names and verified persistence",
        path: "app/SourcesShared/DebridCredentialState.swift",
        find: "guard read(target) == value else { return .readbackMismatch }",
        replacement: "_ = read(target)"
    ),
    Mutation(
        name: "M11 map empty account ID to signed out",
        rule: "canonical owners keep account and device storage disjoint",
        path: "app/SourcesShared/DebridCredentialState.swift",
        find: "static func canonicalAccount(_ raw: String) -> DebridOwnerScope? {\n"
            + "        guard let uuid = UUID(uuidString: raw), "
            + "uuid.uuidString.lowercased() == raw else { return nil }",
        replacement: "static func canonicalAccount(_ raw: String) -> DebridOwnerScope? {\n"
            + "        if raw.isEmpty { return .signedOutDevice }\n"
            + "        guard let uuid = UUID(uuidString: raw), "
            + "uuid.uuidString.lowercased() == raw else { return nil }"
    ),
    Mutation(
        name: "M12 collapse account storage onto device local",
        rule: "canonical owners keep account and device storage disjoint",
        path: "app/SourcesShared/DebridCredentialState.swift",
        find: "return \"vortx.debrid.v2.\" + rawValue + \".account.\" "
            + "+ uuid.uuidString.lowercased()",
        replacement: "return \"vortx.debrid.\" + rawValue + \".local\""
    ),
    Mutation(
        name: "M13 report Keychain success after failed write",
        rule: "migration has typed disjoint names and verified persistence",
        path: "app/SourcesShared/Keychain.swift",
        find: "guard save(store) else { return false }\n"
            + "            return load()[account] == value",
        replacement: "_ = save(store)\n"
            + "            return true"
    ),
    Mutation(
        name: "M14 remove credential-use check only",
        rule: "credential use and result publication are revision fenced",
        path: "app/SourcesShared/DebridResolver.swift",
        find: "guard credentialStore.isCurrent(revision: revision) "
            + "else { throw DebridError.credentialsChanged }",
        replacement: "_ = revision"
    ),
]

@main
private enum DebridCredentialCallerGateRunner {
    static func main() {
        let root = CommandLine.arguments.dropFirst().first
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().path
        var failures: [String] = []
        var checks = 0

        for rule in rules {
            checks += 1
            var production: [String: SourceFile] = [:]
            for path in rule.files {
                guard let file = load(root: root, path: path) else {
                    failures.append("\(rule.name): missing production file \(path)")
                    continue
                }
                production[path] = file
            }
            let live = rule.violations(production)
            if live.isEmpty { print("PASS  \(rule.name)") }
            else {
                failures.append(contentsOf: live.map { "\(rule.name): \($0)" })
                print("FAIL  \(rule.name)")
            }

            checks += 1
            let fixture = rule.reverted.mapValues { SourceFile(path: "fixture", text: $0) }
            let detected = rule.violations(fixture)
            if detected.isEmpty {
                failures.append("\(rule.name): reverted fixture survived")
                print("FAIL  \(rule.name) mutation detection")
            } else {
                print("PASS  \(rule.name) mutation detection")
            }
        }

        for mutation in mutations {
            checks += 1
            guard let rule = rules.first(where: { $0.name == mutation.rule }) else {
                failures.append("\(mutation.name): missing named rule \(mutation.rule)")
                print("FAIL  \(mutation.name)")
                continue
            }
            var mutated: [String: SourceFile] = [:]
            for path in rule.files {
                guard let file = load(root: root, path: path) else {
                    failures.append("\(mutation.name): missing production file \(path)")
                    continue
                }
                mutated[path] = file
            }
            guard let target = mutated[mutation.path] else {
                failures.append("\(mutation.name): target is outside named rule")
                print("FAIL  \(mutation.name)")
                continue
            }
            let matches = occurrenceCount(mutation.find, in: target.text)
            guard matches == 1 else {
                failures.append("\(mutation.name): expected one live mutation target, found \(matches)")
                print("FAIL  \(mutation.name)")
                continue
            }
            mutated[mutation.path] = SourceFile(
                path: target.path,
                text: target.text.replacingOccurrences(of: mutation.find, with: mutation.replacement)
            )
            if rule.violations(mutated).isEmpty {
                failures.append("\(mutation.name): live-source mutation survived")
                print("FAIL  \(mutation.name)")
            } else {
                print("PASS  \(mutation.name)")
            }
        }

        if failures.isEmpty {
            print("ALL PASS (\(checks) checks)")
        } else {
            print("FAILED \(failures.count) finding(s) across \(checks) checks")
            for failure in failures { print(" - \(failure)") }
            exit(1)
        }
    }
}
