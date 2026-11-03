#!/usr/bin/env bash
# PROPOSED LAN adapter runner v3. Record-only signal/wait/drain pattern from reviewed local-adoption V4.
# Whole actual adapter/policy/page + inert collaborators. No real listener/account work.
set -euo pipefail
cd "$(dirname "$0")/.."
exec python3 - <<'PY'
import datetime, hashlib, json, os, pathlib, signal, subprocess, sys, time, traceback, uuid

STOP_SIGNAL = None


def request_stop(signum, _frame):
    global STOP_SIGNAL
    # Never raise asynchronously: a signal may arrive at any cleanup instruction.
    # The bounded leader wait polls this recorded request; cleanup remains uninterrupted.
    STOP_SIGNAL = signum


root = pathlib.Path.cwd().resolve()
build = root / 'app/build'
if build.resolve() != build:
    raise SystemExit('Refusing symlinked app/build receipt root')
receipts = build / 'profile-picker-tools-lan-adapter/receipts'
if not receipts.resolve().is_relative_to(build):
    raise SystemExit('Receipt root must remain inside this app/build')
receipts.mkdir(parents=True, exist_ok=True)
stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S.%fZ')
out = receipts / ('run-' + stamp + '-' + uuid.uuid4().hex)
out.mkdir(mode=0o700, exist_ok=False)  # No reused directory, binary or previous PASS log.
print('LAN adapter receipt directory: ' + str(out), flush=True)

sources = ['app/SourcesShared/ProfilePickerToolsTransferPolicy.swift',
           'app/SourcesShared/ProfilePickerToolsTransferPhonePage.swift',
           'app/SourcesShared/ProfilePickerToolsLANTransfer.swift',
           'app/SourcesShared/VXLocalLANAddress.swift',
           'app/Tests/ProfilePickerToolsLANTransferTests.swift',
           'app/Tests/VXLocalLANAddressTests.swift']
runner = root / 'scripts/test-profile-picker-tools-lan-adapter.sh'
verifier = out / 'verify-lan-adapter-result.py'
compile_driver = out / 'compile-with-retained-sdk.py'
binary = out / 'checks'

# Persist the exact independently executed verifier as an invocation-owned input.
# Explicit conditions (not assert) continue to fail closed under PYTHONOPTIMIZE.
verifier.write_text(r'''import json, pathlib, sys
log = pathlib.Path(sys.argv[1]).read_text()
lines = log.splitlines()
values = [line.removeprefix('LAN_ADAPTER_ASSERTIONS=') for line in lines if line.startswith('LAN_ADAPTER_ASSERTIONS=')]
if len(values) != 1 or not values[0].isdigit() or int(values[0]) < 32:
    raise ValueError('Missing exact authored assertion floor')
if lines.count('LAN_ADAPTER_CALLBACKS_PASS') != 1:
    raise ValueError('Missing unique actual adapter completion')
pathlib.Path(sys.argv[2]).write_text(json.dumps({'status':'LAN_ADAPTER_CALLBACKS_PASS',
    'assertions':int(values[0]), 'bodyCopies':0,
    'boundary':'Whole actual adapter/policy/page with inert drivers; no real Network/account/ABI/file operation.'},indent=2)+'\n')
print('PASS exact whole-adapter completion and 32-assertion floor')
''')
# SDK discovery is a separate retained/drained phase. Parse its bounded output INSIDE
# the owned compile phase, then exec the exact compiler in that same owned group.
compile_driver.write_text(r'''import json, os, pathlib, sys
sdk_stdout, argv_receipt, binary, bridge, *sources = sys.argv[1:]
with pathlib.Path(sdk_stdout).open('rb') as stream:
    raw = stream.read(16_385)
if len(raw) > 16_384:
    raise ValueError('SDK lookup output exceeded fixed bound')
sdk = raw.decode('utf-8').strip()
if not sdk.startswith('/') or len(sdk) > 4096 or any(c in sdk for c in ('\n','\r','\0')) or not pathlib.Path(sdk).is_dir():
    raise ValueError('SDK lookup did not return one actual absolute SDK directory')
argv = ['/usr/bin/nice','-n','15','/usr/bin/xcrun','swiftc','-swift-version','6',
    '-strict-concurrency=complete','-warnings-as-errors','-j','1','-num-threads','1',
    '-parse-as-library','-sdk',sdk,'-module-cache-path',str(pathlib.Path(binary).parent/'module-cache'),
    '-import-objc-header',bridge,*sources,'-o',binary]
with pathlib.Path(argv_receipt).open('x') as output:
    json.dump({'argv':argv,'sdk':sdk},output,indent=2); output.write('\n')
os.execv(argv[0],argv)
''')

bridge = root / 'app/SourcesShared/VXLocalLANInterface.h'
base_inputs = [root / source for source in sources] + [runner, verifier, compile_driver, bridge]
sdk_stdout, sdk_stderr = out / 'sdk/stdout.bin', out / 'sdk/stderr.bin'
compile_argv = out / 'compile-argv.json'
commands = {
    'sdk': ['/usr/bin/nice','-n','15','/usr/bin/xcrun','--sdk','macosx','--show-sdk-path'],
    'compile': [sys.executable,str(compile_driver),str(sdk_stdout),str(compile_argv),str(binary),str(bridge),*sources],
    'runtime': ['nice','-n','15',str(binary)],
    'result': [sys.executable,str(verifier),str(out / 'runtime/stdout.bin'),str(out / 'adapter-result.json')],
}
inputs = {'sdk':base_inputs,
          'compile':base_inputs + [sdk_stdout,sdk_stderr],
          'runtime':base_inputs + [sdk_stdout,sdk_stderr,binary,compile_argv],
          'result':base_inputs + [sdk_stdout,sdk_stderr,binary,compile_argv,out / 'runtime/stdout.bin',out / 'runtime/stderr.bin']}
outputs = {'sdk':[], 'compile':[binary,compile_argv], 'runtime':[], 'result':[out / 'adapter-result.json']}
timeouts = {'sdk':15,'compile':90,'runtime':45,'result':15}

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
        # Bind later phase inputs to this exact compile/runtime's retained output bytes.
        for path in [stdout_path, stderr_path] + artifacts:
            expected_inputs[str(path)] = hashes([path])[str(path)]
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
    for name in ['sdk', 'compile', 'runtime', 'result']:
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
    # Only replay actual child output after ALL phases and their freshness checks passed.
    for name in ['runtime', 'result']:
        for line in (out / name / 'stdout.bin').read_text().splitlines():
            if line.startswith(('PASS ', 'UNPROVED:')):
                print(line)
    print('LAN_ADAPTER_CALLBACKS_PASS: ' + str(out / 'summary.json'))
else:
    print('LAN adapter checks FAILED; retained receipt: ' + str(out / 'summary.json'), file=sys.stderr)
sys.exit(final_code if final_code >= 0 else 128 - final_code)
PY
