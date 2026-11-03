#!/usr/bin/env python3
"""Whole actual Tools SwiftUI branches; V4 record-only signal/wait/drain lifecycle, no app/link/launch."""
import datetime,hashlib,json,os,platform,signal,subprocess,sys,time,traceback,uuid
from pathlib import Path
STOP_SIGNAL = None


def request_stop(signum, _frame):
    global STOP_SIGNAL
    # Never raise asynchronously: a signal may arrive at any cleanup instruction.
    # The bounded leader wait polls this recorded request; cleanup remains uninterrupted.
    STOP_SIGNAL = signum


ROOT = Path(__file__).resolve().parents[1]
WHOLE = [
    'app/SourcesShared/' + name + '.swift' for name in (
        'ProfilePickerToolsAccess', 'ProfilePickerToolsController', 'ProfilePickerToolsView',
        'ProfilePickerToolsServices', 'ProfilePickerToolsRestoreAction', 'DiagnosticLogExportButton',
        'VortxAccountFileAccess', 'ChipButtonStyle', 'ReducedMotion', 'VisualEffects',
        'ValueChangeObservation', 'ProfilePickerToolsTransferPolicy', 'ProfilePickerToolsTransferPhonePage',
        'ProfilePickerToolsTVTransfer', 'ProfilePickerToolsTVTransferLive', 'ProfilePickerToolsLANTransfer')
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
    ('app/SourcesShared/VXDiagExport.swift', '    typealias DeliveryAuthorization = @MainActor @Sendable () -> Bool', 'line', 'diagnostic'),
    ('app/SourcesShared/VXDiagExport.swift', '    static func makeSession(deliveryAuthorization: DeliveryAuthorization? = nil) -> VXDiagExport {', 'header', 'diagnostic'),
    ('app/SourcesShared/VXDiagExport.swift', '    func startAsync() async -> (url: String, qr: Image)? {', 'header', 'diagnostic'),
    ('app/SourcesShared/VXDiagExport.swift', '    func stopOwnedSession() {', 'header', 'diagnostic'),
    ('app/SourcesShared/VortxAccountBackupFile.swift', 'enum VortxAccountBackupFile {', 'guard', ''),
    ('app/SourcesShared/VortxAccountBackupFile.swift', '    struct Inspection: Sendable {', 'declaration', 'backup'),
    ('app/SourcesShared/VortxAccountBackupFile.swift', '    static func inspect(_ source: Data) throws -> Inspection {', 'header', 'backup'),
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
 repair:'enum VortxAccountFileRepairService {\n',restore:'enum VortxAccountFileRestore {\n',diagnostic:'final class VXDiagExport: @unchecked Sendable {\n',backup:'enum VortxAccountBackupFile {\n'};
let generated='import SwiftUI\nimport Foundation\n\n';
for(const [group,parts] of groups)generated+=(group?wrap[group]:'')+parts.join('\n\n')+'\n'+(group?'}\n':'');
fs.writeFileSync(output,generated,{flag:'wx'});
process.stdout.write(JSON.stringify({sourceHashes:sources,selections,viewBodyCopies:0,declarationTransformations:[]}));
'''


if platform.system() != 'Darwin' or platform.machine() not in ('arm64', 'x86_64'):
    raise SystemExit('Requires macOS and real SwiftUI Apple SDKs')
mode = sys.argv[1] if len(sys.argv) == 2 else '--macos'
if mode not in ('--macos', '--tvos-full', '--tvos-lite') or len(sys.argv) > 2:
    raise SystemExit('Expected --macos, --tvos-full or --tvos-lite')
tvos = mode != '--macos'
if tvos:
    WHOLE.append('app/Sources/Player/PerformanceMode.swift')
root = ROOT
build = root / 'app/build'
if build.resolve() != build:
    raise SystemExit('Refusing symlinked app/build receipt root')
receipts = build / 'profile-picker-tools-typecheck/receipts'
if not receipts.resolve().is_relative_to(build):
    raise SystemExit('Receipt root escaped app/build')
receipts.mkdir(parents=True, exist_ok=True)
stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S.%fZ')
out = receipts / ('run-' + mode[2:] + '-' + stamp + '-' + uuid.uuid4().hex)
out.mkdir(mode=0o700, exist_ok=False)
print('Tools whole SwiftUI ' + mode[2:] + ' receipt: ' + str(out), flush=True)
generated = out / 'ActualToolsTypecheckDeclarations.swift'
recipe_path = out / 'recipe.json'
recipe_path.write_text(json.dumps(RECIPE, indent=2) + '\n')
extractor = out / 'extract-whole-ui-dependencies.cjs'
extractor.write_text(NODE.replace("const [root,output]=process.argv.slice(1), recipe=JSON.parse(fs.readFileSync(0,'utf8'));",
    "const [root,output,recipeFile]=process.argv.slice(2), recipe=JSON.parse(fs.readFileSync(recipeFile,'utf8'));"
).replace("path.join(process.argv[1],", "path.join(process.argv[2],"))
compile_driver = out / 'typecheck-with-retained-sdk.py'
compile_driver.write_text(r'''import json,os,pathlib,sys
mode,sdk_output,argv_output,module_cache,*sources=sys.argv[1:]
with pathlib.Path(sdk_output).open('rb') as stream: raw=stream.read(16_385)
if len(raw)>16_384: raise ValueError('SDK output exceeded bound')
sdk=raw.decode().strip()
if not sdk.startswith('/') or len(sdk)>4096 or any(c in sdk for c in ('\n','\r','\0')) or not pathlib.Path(sdk).is_dir():
    raise ValueError('Invalid retained SDK path')
import platform
arch=platform.machine()
target='arm64-apple-tvos18.0' if mode!='--macos' else arch+'-apple-macosx14.0'
argv=['/usr/bin/nice','-n','15','/usr/bin/xcrun','swiftc','-parse-as-library','-typecheck',
      '-swift-version','6','-strict-concurrency=complete','-warnings-as-errors','-j','1','-num-threads','1',
      '-target',target,'-sdk',sdk,'-module-cache-path',module_cache]
if mode!='--macos': argv+=['-D','VORTX_AETHER_ENGINE','-D','VORTX_NO_EMBEDDED_SERVER' if mode=='--tvos-lite' else 'VORTX_ENGINE_SERVER']
argv+=sources
with pathlib.Path(argv_output).open('x') as output: json.dump({'argv':argv,'targetMode':mode},output,indent=2);output.write('\n')
os.execv(argv[0],argv)
''')
verifier = out / 'verify-whole-ui-source-receipt.py'
verifier.write_text(r'''import hashlib,json,pathlib,sys
root,extract,argv_path,result_path,mode=sys.argv[1:]
manifest=json.loads(pathlib.Path(extract).read_text())
if manifest.get('viewBodyCopies')!=0 or manifest.get('declarationTransformations')!=[]:
    raise ValueError('Production View bodies must be whole inputs, with zero transformations')
for name,expected in manifest['sourceHashes'].items():
    if hashlib.sha256((pathlib.Path(root)/name).read_bytes()).hexdigest()!=expected: raise ValueError('Seam source changed')
argv=json.loads(pathlib.Path(argv_path).read_text())
if argv.get('targetMode')!=mode: raise ValueError('Wrong target branch')
pathlib.Path(result_path).write_text(json.dumps({'status':'TOOLS_WHOLE_SWIFTUI_TYPECHECK_PASS','targetMode':mode,
    'viewBodyCopies':0,'selections':manifest['selections'],'sourceHashes':manifest['sourceHashes'],
    'scope':'Focused whole Tools View and actual Network bridge API compile; no app/link/render/device/account action.'},indent=2)+'\n')
print('PASS whole SwiftUI Tools source/API typecheck '+mode)
''')
sources = sorted(set(WHOLE + [entry[0] for entry in RECIPE]))
runner = Path(__file__).resolve()
base_inputs = [root / source for source in sources] + [runner, root/'test/xperience-harness-inputs.cjs', recipe_path, extractor, compile_driver, verifier]
sdk_stdout,sdk_stderr=out/'sdk/stdout.bin',out/'sdk/stderr.bin'
extract_stdout,extract_stderr=out/'extract/stdout.bin',out/'extract/stderr.bin'
compile_argv=out/'compile-argv.json'
commands={
    'extract':['/usr/bin/nice','-n','15','node',str(extractor),str(root),str(generated),str(recipe_path)],
    'sdk':['/usr/bin/nice','-n','15','/usr/bin/xcrun','--sdk','appletvos' if tvos else 'macosx','--show-sdk-path'],
    'compile':[sys.executable,str(compile_driver),mode,str(sdk_stdout),str(compile_argv),str(out/'module-cache'),*[str(root/name) for name in WHOLE],str(generated)],
    'result':[sys.executable,str(verifier),str(root),str(extract_stdout),str(compile_argv),str(out/'typecheck-result.json'),mode],
}
inputs={'extract':base_inputs,'sdk':base_inputs+[generated,extract_stdout,extract_stderr],
    'compile':base_inputs+[generated,extract_stdout,extract_stderr,sdk_stdout,sdk_stderr],
    'result':base_inputs+[generated,extract_stdout,extract_stderr,sdk_stdout,sdk_stderr,compile_argv,out/'compile/stdout.bin',out/'compile/stderr.bin']}
outputs={'extract':[generated],'sdk':[],'compile':[compile_argv],'result':[out/'typecheck-result.json']}
timeouts={'extract':15,'sdk':15,'compile':90,'result':15}

def utc():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()

def write_json(path, value):
    # Exact invocation-owned paths only. No cleanup or mutation of previous receipts.
    temporary = path.with_name(path.name + '.writing')
    temporary.write_text(json.dumps(value, indent=2) + '\n')
    temporary.replace(path)

def hashes(paths):
    result = {}
    for path in paths:
        try:
            data = path.read_bytes()
            result[str(path)] = {'sha256': hashlib.sha256(data).hexdigest(), 'bytes': len(data)}
        except Exception as error:
            result[str(path)] = {'sha256': None, 'errorType': type(error).__name__, 'error': str(error)}
    return result

def valid_hashes(value):
    return all(item.get('sha256') is not None for item in value.values())

def file_evidence(path):
    return {'path': str(path), **hashes([path])[str(path)]}

summary = {'schema': 3, 'receiptDirectory': str(out), 'cwd': str(root),
           'startedAtUTC': utc(), 'completed': False, 'status': 'RUNNING',
           'signalHandling': ['SIGINT', 'SIGTERM'], 'uncatchableSignalsNotHandled': ['SIGKILL', 'SIGSTOP'],
           'stopped': False, 'receivedSignal': None, 'phases': {}}
expected_inputs = hashes(base_inputs)
summary['invocationInputHashes'] = dict(expected_inputs)
write_json(out / 'summary.json', summary)

def matches_expected(value):
    return valid_hashes(value) and all(expected_inputs.get(path) == item for path, item in value.items())

def bind_input(path):
    evidence = hashes([path])[str(path)]
    if evidence.get('sha256') is None:
        raise ValueError('Required consumed output unavailable: ' + str(path))
    existing = expected_inputs.get(str(path))
    if existing is not None and existing != evidence:
        raise ValueError('Earlier consumed output changed: ' + str(path))
    expected_inputs[str(path)] = evidence

def run_phase(name, *, blocked_by=None):
    phase = out / name
    phase.mkdir(exist_ok=False)
    stdout_path, stderr_path = phase / 'stdout.bin', phase / 'stderr.bin'
    before = hashes(inputs[name])
    record = {'phase': name, 'command': commands[name], 'cwd': str(root),
              'timeoutSeconds': timeouts[name], 'startedAtUTC': utc(),
              'completed': False, 'status': 'PREPARED', 'blockedBy': blocked_by,
              'processStarted': False, 'processID': None, 'processGroupID': None,
              'processGroupKillRequested': False, 'processLeaderReaped': None,
              'ownedProcessGroupAbsent': None, 'drainTimeoutSeconds': 5, 'exitCode': None,
              'resultExitCode': None, 'timedOut': False, 'stopped': False,
              'inputHashesBefore': before, 'inputHashesAfter': None,
              'matchesExpectedInputsBefore': matches_expected(before),
              'stdout': {'path': str(stdout_path)}, 'stderr': {'path': str(stderr_path)}}
    write_json(phase / 'receipt.start.json', record)
    process = None
    result_code = 0
    started = time.monotonic()
    with stdout_path.open('xb') as stdout, stderr_path.open('xb') as stderr:
        def note(message):
            try:
                stderr.write(message.encode()); stderr.flush()
            except Exception as error:
                record.setdefault('logWriteErrors', []).append(type(error).__name__)

        try:
            if blocked_by or STOP_SIGNAL is not None:
                result_code = 125
                record['status'] = 'NOT_RUN_PREREQUISITE_FAILED_OR_INTERRUPTED'
                note('Not run: ' + str(blocked_by or ('signal ' + str(STOP_SIGNAL))) + '\n')
            elif not matches_expected(before):
                result_code = 125
                record['status'] = 'NOT_RUN_INPUT_HASH_FAILED_OR_CHANGED'
                note('Not run: required input hash failed or differs from the consumed prior phase.\n')
            else:
                # Signals only record a stop request. Once Popen returns, this local
                # handle remains owned through the unconditional finally drain.
                process = subprocess.Popen(commands[name], cwd=root, stdout=stdout, stderr=stderr,
                                           start_new_session=True)
                record.update(processStarted=True, processID=process.pid, processGroupID=process.pid)
                phase_deadline = time.monotonic() + timeouts[name]
                while True:
                    if STOP_SIGNAL is not None:
                        result_code = 128 + STOP_SIGNAL
                        record.update(status='FAILED_SIGNAL', stopped=True, receivedSignal=STOP_SIGNAL)
                        note('Stop requested: terminating only this owned process group.\n')
                        break
                    remaining = phase_deadline - time.monotonic()
                    if remaining <= 0:
                        result_code = 124
                        record.update(status='FAILED_TIMEOUT', timedOut=True)
                        note('Phase timeout: terminating only this owned process group.\n')
                        break
                    try:
                        process.wait(timeout=min(0.1, remaining))
                    except subprocess.TimeoutExpired:
                        continue
                    result_code = process.returncode
                    record['status'] = 'SUCCEEDED' if result_code == 0 else 'FAILED_COMMAND'
                    break
        except BaseException as error:
            if isinstance(error, KeyboardInterrupt):
                result_code = 130
                record['status'] = 'FAILED_INTERRUPTED'
                record['stopped'] = True
            else:
                result_code = 127
                record['status'] = 'FAILED_RUNNER_EXCEPTION'
            note(traceback.format_exc())
        finally:
            record['commandStatusBeforeDrain'] = record['status']
            try:
                if process is not None:
                    def group_present():
                        try:
                            os.killpg(process.pid, 0)
                            return True
                        except ProcessLookupError:
                            return False
                        except OSError as error:
                            record.setdefault('groupProbeErrors', []).append(type(error).__name__)
                            return None

                    deadline = time.monotonic() + record['drainTimeoutSeconds']
                    if group_present() is not False:
                        record['processGroupKillRequested'] = True
                        try:
                            os.killpg(process.pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass  # Still reap the leader; lookup races must not bypass wait.
                        except OSError as error:
                            record['groupKillError'] = type(error).__name__
                    try:
                        process.wait(timeout=max(0.001, deadline - time.monotonic()))
                    except subprocess.TimeoutExpired:
                        pass
                    except BaseException as error:
                        record['leaderWaitError'] = type(error).__name__
                    while group_present() is not False and time.monotonic() < deadline:
                        time.sleep(0.02)
                        try:
                            process.poll()
                        except OSError as error:
                            record['leaderPollError'] = type(error).__name__
                    present = group_present()
                    record['exitCode'] = process.returncode  # Raw child exit, distinct from timeout/effective code.
                    record['processLeaderReaped'] = process.returncode is not None
                    record['ownedProcessGroupAbsent'] = None if present is None else not present
                    if not record['processLeaderReaped'] or record['ownedProcessGroupAbsent'] is not True:
                        result_code = 125
                        record['status'] = 'FAILED_OWNED_PROCESS_DRAIN_UNVERIFIED'
                        note('Owned process drain remains unverified; every downstream phase is NOT_RUN.\n')
            except BaseException:
                result_code = 125
                record['status'] = 'FAILED_OWNED_PROCESS_DRAIN_UNVERIFIED'
                record['drainException'] = traceback.format_exc()
                note(record['drainException'])
    # Failure stdout/stderr are already retained directly, including timed-out partial output.
    after = hashes(inputs[name])
    stable = matches_expected(before) and matches_expected(after) and before == after
    record['inputHashesAfter'] = after
    record['matchesExpectedInputsAfter'] = matches_expected(after)
    record['inputsUnchanged'] = stable
    if result_code == 0 and not stable:
        result_code = 125
        record['status'] = 'FAILED_INPUT_CHANGED'
    if STOP_SIGNAL is not None:
        record.update(stopped=True, receivedSignal=STOP_SIGNAL)
        if result_code == 0:
            result_code = 128 + STOP_SIGNAL
            record['status'] = 'FAILED_SIGNAL'
    if record.get('logWriteErrors') and result_code == 0:
        result_code = 125
        record['status'] = 'FAILED_LOG_WRITE'
    record['stdout'] = file_evidence(stdout_path)
    record['stderr'] = file_evidence(stderr_path)
    artifacts = outputs[name]
    record['outputArtifacts'] = {str(path): hashes([path])[str(path)] for path in artifacts}
    if result_code == 0:
        try:
            # Bind only available exact outputs; failed log/artifact hashes cannot pass.
            for path in [stdout_path, stderr_path] + artifacts:
                bind_input(path)
        except Exception:
            result_code = 125
            record['status'] = 'FAILED_LOG_OR_OUTPUT_HASH'
            record['outputHashException'] = traceback.format_exc()
    record['completed'] = True
    record['finishedAtUTC'] = utc()
    record['elapsedSeconds'] = time.monotonic() - started
    record['resultExitCode'] = result_code
    write_json(phase / 'receipt.json', record)
    summary['phases'][name] = {'receipt': str(phase / 'receipt.json'),
                               'status': record['status'], 'exitCode': record['exitCode'],
                               'resultExitCode': result_code, 'timedOut': record['timedOut'],
                               'stopped': record['stopped'], 'ownedProcessGroupAbsent': record['ownedProcessGroupAbsent']}
    write_json(out / 'summary.json', summary)
    return result_code

previous_handlers = {sig: signal.signal(sig, request_stop) for sig in (signal.SIGINT, signal.SIGTERM)}
first_failure = None
final_code = 0
try:
    for name in ['extract', 'sdk', 'compile', 'result']:
        if STOP_SIGNAL is not None and first_failure is None:
            first_failure, final_code = 'signal-' + str(STOP_SIGNAL), 128 + STOP_SIGNAL
        try:
            code = run_phase(name, blocked_by=first_failure)
        except BaseException:
            # Owned cleanup was attempted by run_phase's finally. Preserve failure and
            # still emit explicit downstream NOT_RUN receipts when storage permits.
            code = 127
            summary['phases'][name] = {'status': 'FAILED_RUNNER_EXCEPTION', 'resultExitCode': code,
                                      'error': traceback.format_exc()}
            phase = out / name
            phase.mkdir(exist_ok=True)
            (phase / 'runner-error.txt').write_text(traceback.format_exc())
            write_json(phase / 'receipt.json', {'phase': name, 'completed': True, **summary['phases'][name]})
        if code != 0 and first_failure is None:
            first_failure, final_code = name, code
    if STOP_SIGNAL is not None and first_failure is None:
        first_failure, final_code = 'signal-' + str(STOP_SIGNAL), 128 + STOP_SIGNAL
    summary['completed'] = True
    summary['status'] = 'SUCCEEDED' if first_failure is None else 'FAILED'
except BaseException:
    summary['status'] = 'FAILED_RUNNER_EXCEPTION'
    summary['runnerException'] = traceback.format_exc()
    final_code = final_code or 127
finally:
    if STOP_SIGNAL is not None and final_code == 0:
        first_failure, final_code = 'signal-' + str(STOP_SIGNAL), 128 + STOP_SIGNAL
        summary['status'] = 'FAILED_SIGNAL'
    summary.update(finishedAtUTC=utc(), resultExitCode=final_code, firstFailedPhase=first_failure,
                   receivedSignal=STOP_SIGNAL, stopped=STOP_SIGNAL is not None)
    write_json(out / 'summary.json', summary)
    for sig, handler in previous_handlers.items():
        signal.signal(sig, handler)

if summary['completed'] and summary['status'] == 'SUCCEEDED' and final_code == 0:
    print((out/'result/stdout.bin').read_text().strip())
else:
    print('Tools whole SwiftUI typecheck FAILED; retained receipt: '+str(out/'summary.json'),file=sys.stderr)
sys.exit(final_code if final_code >= 0 else 128 - final_code)
