#!/usr/bin/env python3
"""Focused real-SwiftUI macOS typecheck, never an app build, link, launch or auth/file call."""
import hashlib
import json
import os
from pathlib import Path
import platform
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
WHOLE = [
    'app/SourcesShared/' + name + '.swift' for name in (
        'ProfilePickerToolsAccess', 'ProfilePickerToolsController', 'ProfilePickerToolsView',
        'ProfilePickerToolsServices', 'ProfilePickerToolsRestoreAction', 'DiagnosticLogExportButton',
        'VortxAccountFileAccess', 'ChipButtonStyle', 'ReducedMotion', 'VisualEffects')
] + ['app/Tests/ProfilePickerToolsUITypecheckFixture.swift']
# Exact non-View declaration/header seams from actual source, not mirrored API types.
RECIPE = [
    ('app/SourcesShared/Theme.swift', 'enum Theme {', 'declaration', ''),
    ('app/SourcesShared/CredentialScope.swift', 'final class CredentialScopeRegistry: @unchecked Sendable {', 'guard', ''),
    ('app/SourcesShared/VortXSyncManager.swift', '@MainActor\nfinal class VortXSyncManager: ObservableObject {', 'guard', ''),
    ('app/SourcesShared/VXDiagExport.swift', 'final class VXDiagExport: @unchecked Sendable {', 'guard', ''),
    ('app/SourcesShared/CredentialScope.swift', 'enum CredentialScope: Equatable, Hashable, Sendable {', 'declaration', ''),
    ('app/SourcesShared/CredentialScope.swift', '    struct Capture: Equatable, Hashable, Sendable {', 'declaration', 'registry'),
    ('app/SourcesShared/CredentialScope.swift', '    func capture() -> Capture {', 'header', 'registry'),
    ('app/SourcesShared/CredentialScope.swift', '    func isCurrent(_ capture: Capture) -> Bool {', 'header', 'registry'),
    ('app/SourcesShared/VortXSyncManager.swift', '    struct Account: Codable, Equatable, Sendable {', 'declaration', 'manager'),
    ('app/SourcesShared/VortXSyncManager.swift', '    static let shared = VortXSyncManager()', 'line', 'manager'),
    ('app/SourcesShared/VortXSyncManager.swift', '    @Published private(set) var account: Account?', 'line', 'manager'),
    ('app/SourcesShared/VortXSyncManager.swift', '    @Published private(set) var isSignedIn = false', 'line', 'manager'),
    ('app/SourcesShared/VortXSyncManager.swift', '    static let credentialScopeDidChangeNote = Notification.Name("vortx.credentialScopeDidChange")', 'line', 'manager'),
    ('app/SourcesShared/VortXSyncManager.swift', '    func downloadAccountBackupFile() async throws -> Data {', 'header', 'manager'),
    ('app/SourcesShared/VortXSyncManager.swift', '    func prepareAccountBackupRepair(_ selectedFile: Data) async throws -> VortxAccountFileRepairService.Preview {', 'header', 'manager'),
    ('app/SourcesShared/VortXSyncManager.swift', '    func takeAccountBackupRepairExport(_ id: UUID) throws -> Data {', 'header', 'manager'),
    ('app/SourcesShared/VortXSyncManager.swift', '    func cancelAccountBackupRepair(_ id: UUID) {', 'header', 'manager'),
    ('app/SourcesShared/VortXSyncManager.swift', '    func restoreAccountBackupFile(_ selectedFile: Data) async -> VortxAccountFileRestoreResult {', 'header', 'manager'),
    ('app/SourcesShared/VortXSyncManager.swift', '    func verifyAccountBackupFileRestore(_ operationID: UUID) async -> VortxAccountFileRestoreResult {', 'header', 'manager'),
    ('app/SourcesShared/VortXSyncManager.swift', '    func accountBackupFileRestoreStatus() async -> VortxAccountFileRestoreStatus {', 'header', 'manager'),
    ('app/SourcesShared/VortXSyncManager.swift', '    func finishAccountBackupFileRestore(_ operationID: UUID) async -> VortxAccountFileRestoreLocalResult {', 'header', 'manager'),
    ('app/SourcesShared/VortxAccountFileRestore.swift', 'enum VortxAccountFileRestoreStatus: Sendable {', 'declaration', ''),
    ('app/SourcesShared/VortxAccountFileRestore.swift', 'enum VortxAccountFileRestoreLocalResult: Sendable {', 'declaration', ''),
    ('app/SourcesShared/VortxAccountFileRestore.swift', '    enum LocalState: String, Sendable {', 'declaration', 'restore'),
    ('app/SourcesShared/VortxAccountFileRestore.swift', '    enum LocalPendingReason: Equatable, Sendable {', 'declaration', 'restore'),
    ('app/SourcesShared/VortxAccountFileRestore.swift', '    struct OperationStatus: Sendable, Equatable {', 'declaration', 'restore'),
    ('app/SourcesShared/VortxAccountBackupRepair.swift', '    enum Failure: String, Error, Sendable {', 'declaration', 'converter'),
    ('app/SourcesShared/VortxAccountFileRepairService.swift', '    enum Failure: Error, Sendable, LocalizedError {', 'declaration', 'repair'),
    ('app/SourcesShared/VortxAccountFileRepairService.swift', '    struct Preview: Identifiable, Sendable {', 'declaration', 'repair'),
    ('app/SourcesShared/VortxAccountFileRestore.swift', 'enum VortxAccountFileRestoreFailure: String, Error, Sendable, LocalizedError {', 'declaration', ''),
    ('app/SourcesShared/VortxAccountFileRestore.swift', 'enum VortxAccountFileRestoreResult: Sendable {', 'declaration', ''),
    ('app/SourcesShared/VXDiagExport.swift', '    static func exportBody() -> Data {', 'header', 'diagnostic'),
]
NODE = r'''
const fs=require('node:fs'), path=require('node:path'), crypto=require('node:crypto');
const {extractDeclaration}=require(path.join(process.argv[1],'test/xperience-harness-inputs.cjs'));
const [root,output]=process.argv.slice(1), recipe=JSON.parse(fs.readFileSync(0,'utf8'));
const groups=new Map(), cache=new Map(), sources={}, selections=[];
for(const [file,anchor,kind,group] of recipe){
 if(!cache.has(file))cache.set(file,fs.readFileSync(path.join(root,file)));
 const bytes=cache.get(file), source=bytes.toString('utf8');
 sources[file]=crypto.createHash('sha256').update(bytes).digest('hex');
 const at=source.indexOf(anchor);
 if(at<0||source.indexOf(anchor,at+anchor.length)>=0)throw Error('missing/ambiguous UI typecheck seam: '+file);
 const previous=source.slice(0,at).trimEnd().split('\n').pop();
 if(kind!=='line' && /^\s*@/.test(previous))throw Error('unselected attribute before API seam: '+file);
 if(kind==='line' && !['\n','\r',''].includes(source.slice(at+anchor.length,at+anchor.length+1)))throw Error('changed API declaration line: '+file);
 let selected=kind==='declaration'?extractDeclaration(source,anchor):anchor;
 if(source.slice(at,at+selected.length)!==selected)throw Error('source seam transformed');
 selections.push({file,kind,anchor,sha256:crypto.createHash('sha256').update(selected).digest('hex')});
 if(kind==='guard')continue;
 // Only non-View declarations and method HEADERS are copied. No production View body is extracted.
 if(kind==='header')selected+=' preconditionFailure("typecheck-only app collaborator") }';
 if(!groups.has(group))groups.set(group,[]); groups.get(group).push(selected);
}
const wrap={registry:'final class CredentialScopeRegistry: @unchecked Sendable {\n    static let shared = CredentialScopeRegistry()\n',
 manager:'@MainActor final class VortXSyncManager: ObservableObject {\n',converter:'enum VortxAccountBackupRepair {\n',
 repair:'enum VortxAccountFileRepairService {\n',restore:'enum VortxAccountFileRestore {\n',diagnostic:'enum VXDiagExport {\n'};
let generated='import SwiftUI\nimport Foundation\n\n';
for(const [group,parts] of groups)generated+=(group?wrap[group]:'')+parts.join('\n\n')+'\n'+(group?'}\n':'');
fs.writeFileSync(output,generated,{flag:'wx'});
process.stdout.write(JSON.stringify({sourceHashes:sources,selections,viewBodyCopies:0,declarationTransformations:[]}));
'''


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    if platform.system() != 'Darwin' or platform.machine() not in ('arm64', 'x86_64'):
        raise SystemExit('This focused gate requires macOS with the real SwiftUI SDK')
    build = ROOT / 'app/build'
    build.mkdir(exist_ok=True)
    if ROOT not in build.resolve().parents:
        raise SystemExit('app/build escaped the repository')
    output = Path(tempfile.mkdtemp(prefix='profile-picker-tools-typecheck.', dir=build)).resolve()
    generated = output / 'ActualToolsTypecheckDeclarations.swift'
    controls = {str(Path(__file__).resolve().relative_to(ROOT)): digest(Path(__file__)),
                'test/xperience-harness-inputs.cjs': digest(ROOT / 'test/xperience-harness-inputs.cjs')}
    manifest = json.loads(subprocess.check_output(['node', '-e', NODE, str(ROOT), str(generated)],
        input=json.dumps(RECIPE), text=True, timeout=15))
    inputs = [ROOT / name for name in WHOLE] + [generated]
    hashes = {str(path.relative_to(ROOT)): digest(path) for path in inputs}
    hashes.update(manifest['sourceHashes'])
    hashes.update(controls)
    sdk = subprocess.check_output(['/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True, timeout=15).strip()
    argv = ['/usr/bin/nice', '-n', '15', '/usr/bin/xcrun', 'swiftc', '-parse-as-library', '-typecheck',
            '-swift-version', '6', '-strict-concurrency=complete', '-warnings-as-errors', '-j', '1',
            '-num-threads', '1', '-target', platform.machine() + '-apple-macosx14.0', '-sdk', sdk,
            '-module-cache-path', str(output / 'module-cache')] + [str(path) for path in inputs]
    receipt = {'scope': 'focused macOS real-SwiftUI Tools typecheck only; no full app, render, account or file execution',
               'sourceHashes': hashes, 'selections': manifest['selections'], 'viewBodyCopies': 0, 'argv': argv,
               'status': 'PREPARED'}
    receipt_path = output / 'receipt.json'
    receipt_path.write_text(json.dumps(receipt, indent=2) + '\n')
    started = time.monotonic()
    with (output / 'compiler.log').open('wb') as log:
        process = subprocess.Popen(argv, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = process.wait(timeout=90)
            timed_out = False
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL); process.wait()
            code, timed_out = None, True
    try:
        unchanged = all(digest(ROOT / name) == expected for name, expected in hashes.items())
    except OSError:
        unchanged = False
    passed = code == 0 and not timed_out and unchanged
    receipt.update(status='TYPECHECK_PASS' if passed else 'TYPECHECK_FAILED', exitCode=code, timedOut=timed_out,
                   elapsedSeconds=time.monotonic()-started, inputsUnchanged=unchanged,
                   compilerLogSHA256=digest(output / 'compiler.log'))
    receipt_path.write_text(json.dumps(receipt, indent=2) + '\n')
    print(receipt['status'] + ': ' + str(receipt_path))
    raise SystemExit(0 if passed else 1)


if __name__ == '__main__':
    main()
