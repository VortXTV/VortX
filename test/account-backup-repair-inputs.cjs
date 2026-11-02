#!/usr/bin/env node
'use strict';
// Actual declarations only. There is no source/body normalization or fake native success.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const { extractDeclaration } = require('./xperience-harness-inputs.cjs');
const recipe = {
  "wholeFiles": [
    "app/SourcesShared/VortxNativeRuntime.swift",
    "app/SourcesShared/VortXSyncCrypto.swift",
    "app/SourcesShared/VortxAccountBackupFile.swift",
    "app/SourcesShared/VortxProfileOverlayWitness.swift",
    "app/SourcesShared/LegacyWatchedBitfieldDecoder.swift",
    "app/SourcesShared/LegacyWatchedBitfieldMigrationEvidence.swift",
    "app/SourcesShared/VortxLegacyBootstrapMaterial.swift",
    "app/SourcesShared/OwnerHistoryExactJSON.swift",
    "app/SourcesShared/ProfileAddonPreferences.swift",
    "app/SourcesShared/ProfileRosterSyncPolicy.swift",
    "app/SourcesShared/XperienceExportObservation.swift",
    "app/SourcesShared/VortxAccountBackupRepair.swift",
    "app/Tests/VortxAccountBackupRepairTests.swift",
    "app/Tests/BackupRepairUnusedOwnerHistoryStub.swift"
  ],
  "outputs": [
    {
      "name": "ActualModels.swift",
      "parts": [
        {
          "literal": "import Foundation\nimport CoreFoundation\nimport CryptoKit\n"
        },
        {
          "source": "app/SourcesShared/Profiles.swift",
          "kind": "declaration",
          "header": "struct UserProfile: Codable, Identifiable, Equatable, Sendable {"
        },
        {
          "source": "app/SourcesShared/ProfileDiscoveryPreferences.swift",
          "kind": "declaration",
          "header": "struct ProfileDiscoveryPreferences: Codable, Equatable, Sendable {"
        },
        {
          "source": "app/SourcesShared/VortxResourceBridge.swift",
          "kind": "declaration",
          "header": "indirect enum VortxJSON: Codable, Equatable, Sendable {"
        },
        {
          "source": "app/SourcesShared/CredentialScope.swift",
          "kind": "declaration",
          "header": "enum CredentialScope: Equatable, Hashable, Sendable {"
        },
        {
          "literal": "final class CredentialScopeRegistry: @unchecked Sendable {\n"
        },
        {
          "source": "app/SourcesShared/CredentialScope.swift",
          "kind": "declaration",
          "header": "    struct Capture: Equatable, Hashable, Sendable {"
        },
        {
          "literal": "}\n"
        }
      ]
    },
    {
      "name": "ActualSettingsEnvelope.swift",
      "parts": [
        {
          "literal": "import Foundation\nimport CoreFoundation\nimport CryptoKit\n"
        },
        {
          "literal": "enum SettingsBackup {\n"
        },
        {
          "source": "app/SourcesShared/SettingsBackup.swift",
          "kind": "between",
          "start": "    static let schema = 1\n",
          "end": "    /// Framework/OS keys"
        },
        {
          "source": "app/SourcesShared/SettingsBackup.swift",
          "kind": "declaration",
          "header": "    struct Envelope: Codable {"
        },
        {
          "source": "app/SourcesShared/SettingsBackup.swift",
          "kind": "body",
          "header": "    static func encode(domain: [String: Any], bundleID: String, app: String, now: Date = Date()) throws -> Data {"
        },
        {
          "literal": "}\n"
        }
      ]
    },
    {
      "name": "ActualAccountRawParser.swift",
      "parts": [
        {
          "literal": "import Foundation\nimport CoreFoundation\nimport CryptoKit\n"
        },
        {
          "literal": "enum VortxNativeBootstrapArchive {\n"
        },
        {
          "source": "app/SourcesShared/VortxNativeBootstrapArchive.swift",
          "kind": "declaration",
          "header": "    enum Failure: Error { case malformed, ambiguousCredentialCarrier, opaquePreference }"
        },
        {
          "source": "app/SourcesShared/VortxNativeBootstrapArchive.swift",
          "kind": "body",
          "header": "    private static func jsonUTF8View(_ data: Data) throws -> Data {"
        },
        {
          "source": "app/SourcesShared/VortxNativeBootstrapArchive.swift",
          "kind": "body",
          "header": "    private static func decodeJSON(with data: Data, options: JSONSerialization.ReadingOptions = []) throws -> Any {"
        },
        {
          "source": "app/SourcesShared/VortxNativeBootstrapArchive.swift",
          "kind": "body",
          "header": "    static func requireUnambiguousJSON(_ data: Data) throws {"
        },
        {
          "source": "app/SourcesShared/VortxNativeBootstrapArchive.swift",
          "kind": "declaration",
          "header": "    struct RawJSONMember: Sendable {"
        },
        {
          "source": "app/SourcesShared/VortxNativeBootstrapArchive.swift",
          "kind": "body",
          "header": "    static func rawJSONObjectMembers(_ data: Data, maximumBytes: Int, maximumMembers: Int = 512) throws -> [RawJSONMember] {"
        },
        {
          "source": "app/SourcesShared/VortxNativeBootstrapArchive.swift",
          "kind": "body",
          "header": "    static func rawJSONArrayValues(_ data: Data, maximumBytes: Int, maximumValues: Int = 400) throws -> [Data] {"
        },
        {
          "source": "app/SourcesShared/VortxNativeBootstrapArchive.swift",
          "kind": "body",
          "header": "    private static func rawJSONBytes(_ data: Data, maximumBytes: Int) throws -> [UInt8] {"
        },
        {
          "source": "app/SourcesShared/VortxNativeBootstrapArchive.swift",
          "kind": "declaration",
          "header": "    private struct JSONMemberScanner {"
        },
        {
          "literal": "}\n"
        }
      ]
    },
    {
      "name": "ActualAccountExport.swift",
      "parts": [
        {
          "literal": "import Foundation\nimport CoreFoundation\nimport CryptoKit\n"
        },
        {
          "source": "app/SourcesShared/OwnerHistoryAccountExport.swift",
          "kind": "between",
          "start": "struct OwnerHistoryAccountExport: Sendable {\n",
          "end": "    init(completeAccountPlaintext:"
        },
        {
          "source": "app/SourcesShared/OwnerHistoryAccountExport.swift",
          "kind": "body",
          "header": "    init(completeAccountPlaintext: Data) throws {"
        },
        {
          "source": "app/SourcesShared/OwnerHistoryAccountExport.swift",
          "kind": "body",
          "header": "    private init(fields: Exact.Object) {"
        },
        {
          "source": "app/SourcesShared/OwnerHistoryAccountExport.swift",
          "kind": "body",
          "header": "    func raw(_ key: String) -> Data? {"
        },
        {
          "source": "app/SourcesShared/OwnerHistoryAccountExport.swift",
          "kind": "body",
          "header": "    func encoded() throws -> Data {"
        },
        {
          "source": "app/SourcesShared/OwnerHistoryAccountExport.swift",
          "kind": "body",
          "header": "    func replacingOwned(_ replacements: [String: Data]) throws -> Self {"
        },
        {
          "source": "app/SourcesShared/OwnerHistoryAccountExport.swift",
          "kind": "body",
          "header": "    func validatedPlaintext(writeV2: Bool) throws -> Data {"
        },
        {
          "literal": "}\nstruct XperienceExportBudget {\n"
        },
        {
          "source": "app/SourcesShared/XperienceNativePersistence.swift",
          "kind": "body",
          "header": "    static func sealedByteCount(plaintextCount: Int, writeV2: Bool) throws -> Int {"
        },
        {
          "literal": "}\n"
        }
      ]
    },
    {
      "name": "ActualWatchedRows.swift",
      "parts": [
        {
          "literal": "import Foundation\nimport CoreFoundation\nimport CryptoKit\n"
        },
        {
          "literal": "enum VortxLegacyWatchedMigration {\n    typealias Evidence = LegacyWatchedBitfieldMigrationEvidence\n"
        },
        {
          "source": "app/SourcesShared/VortxLegacyWatchedMigration.swift",
          "kind": "declaration",
          "header": "    enum Failure: Error, Equatable {"
        },
        {
          "source": "app/SourcesShared/VortxLegacyWatchedMigration.swift",
          "kind": "declaration",
          "header": "    struct ValidatedRow: Sendable {"
        },
        {
          "source": "app/SourcesShared/VortxLegacyWatchedMigration.swift",
          "kind": "body",
          "header": "    private static func exact(_ a: String, _ b: String) -> Bool {"
        },
        {
          "source": "app/SourcesShared/VortxLegacyWatchedMigration.swift",
          "kind": "body",
          "header": "    private static func optionalExact(_ a: String?, _ b: String?) -> Bool {"
        },
        {
          "literal": "}\n"
        }
      ]
    },
    {
      "name": "ActualColdSession.swift",
      "parts": [
        {
          "literal": "import Foundation\nimport CoreFoundation\nimport CryptoKit\n"
        },
        {
          "source": "app/SourcesShared/VortxNativeSession.swift",
          "kind": "declaration",
          "header": "struct VortxAccountScope: Codable, Hashable, Sendable {"
        },
        {
          "source": "app/SourcesShared/VortxNativeSession.swift",
          "kind": "declaration",
          "header": "enum VortxLegacyDeltaSummary {"
        },
        {
          "literal": "actor VortxNativeSession {\n"
        },
        {
          "source": "app/SourcesShared/VortxNativeSession.swift",
          "kind": "declaration",
          "header": "    private enum NativeCandidate {"
        },
        {
          "source": "app/SourcesShared/VortxNativeSession.swift",
          "kind": "body",
          "header": "    private static func bind(_ runtime: VortxNativeRuntime, scope: VortxAccountScope) throws {"
        },
        {
          "source": "app/SourcesShared/VortxNativeSession.swift",
          "kind": "body",
          "header": "    private static func apply(_ runtime: VortxNativeRuntime, action: String) throws {"
        },
        {
          "source": "app/SourcesShared/VortxNativeSession.swift",
          "kind": "body",
          "header": "    nonisolated static func detachedLegacySync(scope: VortxAccountScope, ownerName: String, material: Data,\n                                               abi: any VortxRuntimeABI) throws -> VortxJSON {"
        },
        {
          "source": "app/SourcesShared/VortxNativeSession.swift",
          "kind": "declaration",
          "header": "    enum LegacyCompatibilityStage: String {"
        },
        {
          "source": "app/SourcesShared/VortxNativeSession.swift",
          "kind": "declaration",
          "header": "    enum LegacyReconciliation: Equatable, Sendable {"
        },
        {
          "source": "app/SourcesShared/VortxNativeSession.swift",
          "kind": "body",
          "header": "    @discardableResult\n    nonisolated static func validateLegacyCompatibility(scope: VortxAccountScope, ownerName: String,\n                                                        snapshot: String?, nativeSync: VortxJSON?, material: Data,\n                                                        abi: any VortxRuntimeABI, baselineMaterial: Data? = nil,\n                                                        onStage: (LegacyCompatibilityStage) -> Void = { _ in }) throws -> LegacyReconciliation {"
        },
        {
          "source": "app/SourcesShared/VortxNativeSession.swift",
          "kind": "body",
          "header": "    @discardableResult\n    private static func validateLegacyReceipt(_ candidate: VortxNativeRuntime, scope: VortxAccountScope, material: Data, baselineMaterial: Data?,\n        abi: any VortxRuntimeABI, onStage: (LegacyCompatibilityStage) -> Void = { _ in }) throws -> LegacyReconciliation {"
        },
        {
          "source": "app/SourcesShared/VortxNativeSession.swift",
          "kind": "body",
          "header": "    private static func validateLegacyReceipt(_ candidate: NativeCandidate, scope: VortxAccountScope, material: Data, baselineMaterial: Data?,\n                                             abi: any VortxRuntimeABI,\n                                             onStage: (LegacyCompatibilityStage) -> Void = { _ in }) throws -> LegacyReconciliation {"
        },
        {
          "source": "app/SourcesShared/VortxNativeSession.swift",
          "kind": "body",
          "header": "    private static func canonicalLegacyMaterial(_ material: Data, scope: VortxAccountScope, abi: any VortxRuntimeABI) -> VortxJSON? {"
        },
        {
          "source": "app/SourcesShared/VortxNativeSession.swift",
          "kind": "body",
          "header": "    nonisolated static func legacyRejectionCode(_ error: VortxJSON?) -> String {"
        },
        {
          "source": "app/SourcesShared/VortxNativeSession.swift",
          "kind": "body",
          "header": "    private static func strictJSONObject(_ data: Data) throws -> VortxJSON {"
        },
        {
          "source": "app/SourcesShared/VortxNativeSession.swift",
          "kind": "body",
          "header": "    private static func legacyImportSchema(_ value: VortxJSON?) -> Int? {"
        },
        {
          "literal": "}\n"
        }
      ]
    }
  ]
};

function extract(root, directory) {
  root = fs.realpathSync(root);
  directory = fs.realpathSync(directory);
  const build = fs.realpathSync(path.join(root, 'app/build'));
  function descendant(child, parent) {
    const relative = path.relative(parent, child);
    return relative && relative !== '..' && !relative.startsWith('..' + path.sep) && !path.isAbsolute(relative);
  }
  assert(descendant(build, root) && descendant(directory, build), 'output escaped real app/build');
  const hash = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
  const sources = new Map();
  function read(relative) {
    assert(/^(app\/(SourcesShared|Tests)|test)\/[A-Za-z0-9_.-]+$/.test(relative), 'unexpected source path');
    if (!sources.has(relative)) sources.set(relative, fs.readFileSync(path.join(root, relative)));
    return sources.get(relative).toString('utf8');
  }
  function unique(source, anchor) {
    const at = source.indexOf(anchor);
    assert(at >= 0 && source.indexOf(anchor, at + anchor.length) < 0, 'missing/ambiguous declaration anchor: ' + anchor);
    return at;
  }
  const declarations = [];
  function select(item) {
    const source = read(item.source);
    let text, begin;
    if (item.kind === 'between') {
      begin = unique(source, item.start);
      const end = unique(source, item.end);
      assert(end > begin, 'reversed field block');
      text = source.slice(begin, end);
    } else if (item.kind === 'declaration') {
      begin = unique(source, item.header);
      text = extractDeclaration(source, item.header);
    } else {
      // The shared scanner starts at the first brace. Default callback arguments
      // also contain braces: require the COMPLETE unchanged header, then scan only
      // its final body-opening brace and return the original contiguous bytes.
      assert(item.kind === 'body' && item.header.endsWith('{'), 'unsupported selector');
      begin = unique(source, item.header);
      const bodyAt = begin + item.header.length - 1;
      const marker = '@@backup-repair-production-body@@';
      assert(!source.includes(marker), 'reserved extraction marker in source');
      const selected = extractDeclaration(marker + source.slice(bodyAt), marker).slice(marker.length);
      text = source.slice(begin, bodyAt) + selected;
    }
    assert(source.slice(begin, begin + text.length) === text, 'production declaration was transformed');
    assert(/^(?:\s|$)/.test(source.slice(begin + text.length, begin + text.length + 1)), 'declaration ended inside a token');
    declarations.push({source: item.source, selector: item, startLine: source.slice(0, begin).split('\n').length,
      sha256: hash(Buffer.from(text)), declarationTransformations: []});
    return text + '\n';
  }
  const compilerInputs = [];
  for (const relative of recipe.wholeFiles) { read(relative); compilerInputs.push(path.join(root, relative)); }
  const generated = [];
  for (const output of recipe.outputs) {
    const text = output.parts.map(part => Object.hasOwn(part, 'literal') ? part.literal : select(part)).join('\n');
    const destination = path.join(directory, output.name);
    fs.writeFileSync(destination, text, {flag: 'wx'});
    generated.push({name: output.name, sha256: hash(Buffer.from(text))});
    compilerInputs.push(destination);
  }
  read('test/xperience-harness-inputs.cjs');
  read('test/account-backup-repair-inputs.cjs');
  const sourceHashes = Object.fromEntries([...sources].map(([relative, bytes]) => [relative, hash(bytes)]));
  const manifest = {wholeFiles: recipe.wholeFiles, sourceHashes, declarations, generated, compilerInputs,
    scope: 'generic native schemas 1-5; unused owner-history type methods trap; no live session, network or store'};
  fs.writeFileSync(path.join(directory, 'inputs.json'), JSON.stringify(manifest, null, 2) + '\n', {flag: 'wx'});
  return manifest;
}
module.exports = { recipe, extract };
if (require.main === module) {
  assert(process.argv.length === 4, 'usage: node test/account-backup-repair-inputs.cjs ROOT EXISTING_BUILD_DIRECTORY');
  const manifest = extract(process.argv[2], process.argv[3]);
  process.stdout.write(JSON.stringify({wholeFiles: manifest.wholeFiles.length, declarations: manifest.declarations.length,
    scope: manifest.scope}) + '\n');
}
