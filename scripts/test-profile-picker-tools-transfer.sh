#!/usr/bin/env bash
# PROPOSED maintained runner v2. Recovery execution requires the owner's execution slot.
# Actual policy/page + fixtures only. All receipts are unique and retained under app/build.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import datetime, hashlib, json, os, pathlib, signal, subprocess, sys, time, traceback, uuid

root = pathlib.Path.cwd().resolve()
build = root / 'app/build'
if build.resolve() != build:
    raise SystemExit('Refusing symlinked app/build receipt root')
receipts = build / 'profile-picker-tools-transfer/receipts'
if not receipts.resolve().is_relative_to(build):
    raise SystemExit('Receipt root must remain inside this app/build')
receipts.mkdir(parents=True, exist_ok=True)
stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S.%fZ')
out = receipts / ('run-' + stamp + '-' + uuid.uuid4().hex)
out.mkdir(mode=0o700, exist_ok=False)  # No reused directory, binary or previous PASS log.
print('Transfer policy receipt directory: ' + str(out), flush=True)

sources = ['app/SourcesShared/ProfilePickerToolsTransferPolicy.swift',
           'app/SourcesShared/ProfilePickerToolsTransferPhonePage.swift',
           'app/Tests/ProfilePickerToolsTransferPolicyTests.swift']
runner = root / 'scripts/test-profile-picker-tools-transfer.sh'
verifier = out / 'verify-compiled-page-csp.py'
binary = out / 'checks'

# Persist the exact independently executed verifier as an invocation-owned input.
# Explicit conditions (not assert) continue to fail closed under PYTHONOPTIMIZE.
verifier.write_text(r'''import base64, hashlib, json, pathlib, sys
log = pathlib.Path(sys.argv[1]).read_text()
lines = log.splitlines()
def one(prefix):
    values = [line[len(prefix):] for line in lines if line.startswith(prefix)]
    if len(values) != 1:
        raise ValueError('Expected exactly one compiled page field: ' + prefix)
    return values[0]
csp = one('PAGE_CSP=')
hashes = {}
for field, directive in [('SCRIPT', 'script-src'), ('STYLE', 'style-src')]:
    encoded = one('PAGE_' + field + '_BASE64=')
    digest = base64.b64encode(hashlib.sha256(base64.b64decode(encoded, validate=True)).digest()).decode()
    if directive + " 'sha256-" + digest + "'" not in csp:
        raise ValueError('Compiled page CSP digest mismatch: ' + field)
    hashes[field.lower()] = digest
if "'unsafe-inline'" in csp or "'unsafe-eval'" in csp:
    raise ValueError('Unsafe inline/eval CSP policy')
pathlib.Path(sys.argv[2]).write_text(json.dumps(hashes, indent=2) + '\n')
print('PASS compiled page script/style CSP digests')
''')

base_inputs = [root / source for source in sources] + [runner, verifier]
commands = {
    'compile': ['nice', '-n', '15', 'swiftc', '-swift-version', '6',
                '-strict-concurrency=complete', '-warnings-as-errors', '-j', '1',
                '-num-threads', '1', '-parse-as-library', *sources, '-o', str(binary)],
    'runtime': ['nice', '-n', '15', str(binary)],
    'csp': [sys.executable, str(verifier), str(out / 'runtime/stdout.bin'),
            str(out / 'compiled-page-csp.json')],
}
inputs = {'compile': base_inputs,
          'runtime': base_inputs + [binary],
          'csp': base_inputs + [binary, out / 'runtime/stdout.bin', out / 'runtime/stderr.bin']}
timeouts = {'compile': 90, 'runtime': 45, 'csp': 15}

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

summary = {'schema': 2, 'receiptDirectory': str(out), 'cwd': str(root),
           'startedAtUTC': utc(), 'completed': False, 'status': 'RUNNING', 'phases': {}}
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
              'resultExitCode': None, 'timedOut': False,
              'inputHashesBefore': before, 'inputHashesAfter': None,
              'matchesExpectedInputsBefore': matches_expected(before),
              'stdout': {'path': str(stdout_path)}, 'stderr': {'path': str(stderr_path)}}
    write_json(phase / 'receipt.start.json', record)
    process = None
    result_code = 0
    with stdout_path.open('xb') as stdout, stderr_path.open('xb') as stderr:
        try:
            if blocked_by is not None:
                result_code = 125
                record['status'] = 'NOT_RUN_PREREQUISITE_FAILED'
                stderr.write(('Not run: prerequisite ' + blocked_by + ' failed.\n').encode())
            elif not matches_expected(before):
                result_code = 125
                record['status'] = 'NOT_RUN_INPUT_HASH_FAILED_OR_CHANGED'
                stderr.write(b'Not run: required input could not be hashed or differs from this invocation/prior successful phase.\n')
            else:
                # One owned process group; a timeout/cancel kills ONLY this invocation's phase.
                process = subprocess.Popen(commands[name], cwd=root, stdout=stdout, stderr=stderr,
                                           start_new_session=True)
                record['processStarted'] = True
                record['processID'] = process.pid
                record['processGroupID'] = process.pid
                try:
                    process.wait(timeout=timeouts[name])
                    result_code = process.returncode
                    record['status'] = 'SUCCEEDED' if result_code == 0 else 'FAILED_COMMAND'
                except subprocess.TimeoutExpired:
                    record['timedOut'] = True
                    result_code = 124
                    record['status'] = 'FAILED_TIMEOUT'
                    stderr.write(b'Runner timeout: terminating only the owned process group.\n')
        except KeyboardInterrupt:
            result_code = 130
            record['status'] = 'FAILED_INTERRUPTED'
            stderr.write(b'Runner interrupted.\n')
        except Exception:
            result_code = 127
            record['status'] = 'FAILED_RUNNER_EXCEPTION'
            stderr.write(traceback.format_exc().encode())
        finally:
            if process is not None:
                # Probe only the session/group created above; never target shared processes.
                def group_present():
                    try:
                        os.killpg(process.pid, 0)
                        return True
                    except ProcessLookupError:
                        return False
                if group_present():
                    record['processGroupKillRequested'] = True
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                drain_deadline = time.monotonic() + record['drainTimeoutSeconds']
                try:
                    process.wait(timeout=max(0.001, drain_deadline - time.monotonic()))
                except subprocess.TimeoutExpired:
                    pass
                while group_present() and time.monotonic() < drain_deadline:
                    time.sleep(0.02)
                record['exitCode'] = process.returncode
                record['processLeaderReaped'] = process.returncode is not None
                record['ownedProcessGroupAbsent'] = not group_present()
                if not record['processLeaderReaped'] or not record['ownedProcessGroupAbsent']:
                    result_code = 125
                    record['status'] = 'FAILED_OWNED_PROCESS_DRAIN_UNVERIFIED'
                    stderr.write(b'Owned process drain remains unverified; downstream commands will not run.\n')
    # Failure stdout/stderr are already retained directly, including timed-out partial output.
    after = hashes(inputs[name])
    stable = matches_expected(before) and matches_expected(after) and before == after
    record['inputHashesAfter'] = after
    record['matchesExpectedInputsAfter'] = matches_expected(after)
    record['inputsUnchanged'] = stable
    if result_code == 0 and not stable:
        result_code = 125
        record['status'] = 'FAILED_INPUT_CHANGED'
    record['stdout'] = file_evidence(stdout_path)
    record['stderr'] = file_evidence(stderr_path)
    artifacts = [binary] if name == 'compile' else ([out / 'compiled-page-csp.json'] if name == 'csp' else [])
    record['outputArtifacts'] = {str(path): hashes([path])[str(path)] for path in artifacts}
    if result_code == 0:
        # Bind later phase inputs to this exact compile/runtime's retained output bytes.
        for path in [stdout_path, stderr_path] + artifacts:
            expected_inputs[str(path)] = hashes([path])[str(path)]
    record['completed'] = True
    record['finishedAtUTC'] = utc()
    record['resultExitCode'] = result_code
    write_json(phase / 'receipt.json', record)
    summary['phases'][name] = {'receipt': str(phase / 'receipt.json'),
                               'status': record['status'], 'exitCode': record['exitCode'],
                               'resultExitCode': result_code, 'timedOut': record['timedOut']}
    write_json(out / 'summary.json', summary)
    return result_code

first_failure = None
final_code = 0
try:
    for name in ['compile', 'runtime', 'csp']:
        code = run_phase(name, blocked_by=first_failure)
        if code != 0 and first_failure is None:
            first_failure, final_code = name, code
    summary['completed'] = True
    summary['status'] = 'SUCCEEDED' if first_failure is None else 'FAILED'
except BaseException:
    # A runner-level failure cannot leave a success marker. This may be incomplete if the
    # filesystem fails; the initial completed=false receipt remains non-passing evidence.
    summary['status'] = 'FAILED_RUNNER_EXCEPTION'
    summary['runnerException'] = traceback.format_exc()
    final_code = final_code or 127
finally:
    summary['finishedAtUTC'] = utc()
    summary['resultExitCode'] = final_code
    write_json(out / 'summary.json', summary)

if summary['completed'] and summary['status'] == 'SUCCEEDED' and final_code == 0:
    # Only replay actual child output after ALL phases and their freshness checks passed.
    for name in ['runtime', 'csp']:
        for line in (out / name / 'stdout.bin').read_text().splitlines():
            if line.startswith(('PASS ', 'UNPROVED:')):
                print(line)
else:
    print('Transfer policy checks FAILED; retained receipt: ' + str(out / 'summary.json'), file=sys.stderr)
sys.exit(final_code if final_code >= 0 else 128 - final_code)
PY
