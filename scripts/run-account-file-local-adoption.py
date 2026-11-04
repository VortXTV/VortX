#!/usr/bin/env python3
"""Whole-source orchestration and actual journal; bounded owned phases, no native SDK linked.

Lifecycle/evidence pattern adapted from reviewed Slice1 runner SHA-256
c60d5257e0d199a88b4752cd59acda0422d3cd758cfe3f7ef4439d7f1253e60f.
Local-adoption limits remain extraction30/SDK30/Git30/compiler240/runtime60 seconds.
SIGINT/SIGTERM are handled; no promise is made for uncatchable SIGKILL/SIGSTOP.
"""
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import signal
import subprocess
import sys
import tempfile
import time
import traceback

ROOT = Path(__file__).resolve().parents[1]
STOP_SIGNAL = None


def request_stop(signum, _frame):
    global STOP_SIGNAL
    # Never raise asynchronously: a signal may arrive at any cleanup instruction.
    # The bounded leader wait polls this recorded request; cleanup remains uninterrupted.
    STOP_SIGNAL = signum


def utc():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def hashes(paths):
    result = {}
    for path in paths:
        path = Path(path)
        try:
            data = path.read_bytes()
            result[str(path)] = {'sha256': hashlib.sha256(data).hexdigest(), 'bytes': len(data)}
        except Exception as error:
            result[str(path)] = {'sha256': None, 'errorType': type(error).__name__, 'error': str(error)}
    return result


def write_json(path, value):
    temporary = path.with_name(path.name + '.writing')
    temporary.write_text(json.dumps(value, indent=2) + '\n')
    temporary.replace(path)


def main():
    if sys.argv[1:] not in ([], ['--f1-v1-journal']):
        raise SystemExit('Only --f1-v1-journal is supported; arbitrary source overrides are forbidden')
    f1_baseline = bool(sys.argv[1:])
    if platform.system() != 'Darwin' or platform.machine() not in ('arm64', 'x86_64'):
        raise SystemExit('This fixture requires an arm64 or x86_64 macOS runner')
    if not Path('/usr/bin/sandbox-exec').is_file():
        raise SystemExit('Runtime sandbox unavailable; no unrestricted fallback')
    build = ROOT / 'app/build'
    build.mkdir(parents=True, exist_ok=True)
    if ROOT not in build.resolve().parents:
        raise SystemExit('app/build escaped the repository')
    output = Path(tempfile.mkdtemp(prefix='account-file-local-adoption-f1-v1.' if f1_baseline
                                  else 'account-file-local-adoption.', dir=build)).resolve()
    print('Retained local-adoption output: ' + str(output), flush=True)
    receipt_path = output / 'receipt.json'
    controls = [Path(__file__).resolve(), ROOT / 'scripts/test-account-file-local-adoption.sh',
                ROOT / 'test/account-file-local-adoption-inputs.cjs', ROOT / 'test/xperience-harness-inputs.cjs']
    expected_inputs = hashes(controls)
    summary = {'schema': 3, 'scope': 'whole unchanged syncDown/finalizer/status/Finish and actual encrypted journal',
               'nativeSDK': 'NOT_LINKED; explicit synthetic native/provider/transport collaborators; real journal',
               'receiptDirectory': str(output), 'f1Baseline': f1_baseline, 'startedAtUTC': utc(),
               'completed': False, 'status': 'RUNNING', 'invocationInputHashes': dict(expected_inputs),
               'signalHandling': ['SIGINT', 'SIGTERM'], 'uncatchableSignalsNotHandled': ['SIGKILL', 'SIGSTOP'],
               'phases': {}, 'resultExitCode': None}
    write_json(receipt_path, summary)
    environment = dict(os.environ)
    environment.update({'OMP_NUM_THREADS': '1', 'RAYON_NUM_THREADS': '1', 'VECLIB_MAXIMUM_THREADS': '1'})
    state = {}
    phase_limits = {'extraction': 30, 'sdk': 30, 'git': 30, 'compiler': 240, 'runtime': 60}
    order = list(phase_limits)

    def matches_expected(value):
        return all(item.get('sha256') is not None and expected_inputs.get(path) == item
                   for path, item in value.items())

    def bind_input(path, expected_sha=None):
        evidence = hashes([path])[str(path)]
        if evidence.get('sha256') is None or (expected_sha is not None and evidence['sha256'] != expected_sha):
            raise ValueError('Required consumed input unavailable or changed: ' + str(path))
        existing = expected_inputs.get(str(path))
        if existing is not None and existing != evidence:
            raise ValueError('Earlier phase input changed: ' + str(path))
        expected_inputs[str(path)] = evidence

    def consume(name, record, stdout_path, stderr_path):
        if name == 'extraction':
            input_file = output / 'inputs.json'
            inputs = json.loads(input_file.read_text())
            if inputs['f1Baseline'] != f1_baseline:
                raise ValueError('Extraction selected the wrong journal lane')
            for relative, expected in inputs['sourceHashes'].items():
                bind_input(ROOT / relative, expected)
            for path, expected in inputs['frozenExternalInputs'].items():
                bind_input(Path(path), expected)
            for path in inputs['compilerInputs']:
                bind_input(Path(path))
            bind_input(input_file)
            state['inputs'] = inputs
            summary.update(sourceHashes=inputs['sourceHashes'], declarations=inputs['declarations'],
                           generated=inputs['generated'], journalSelection=inputs['journalSelection'],
                           frozenExternalInputs=inputs['frozenExternalInputs'], limitations=inputs['limitations'])
        elif name == 'sdk':
            lines = stdout_path.read_text().splitlines()
            if len(lines) != 1 or not lines[0] or not Path(lines[0]).is_dir():
                raise ValueError('SDK command did not return exactly one existing SDK directory')
            state['sdk'] = lines[0]
            summary['sdkPath'] = lines[0]
        elif name == 'git':
            head = stdout_path.read_text().strip()
            if not re.fullmatch(r'[0-9a-f]{40}|[0-9a-f]{64}', head):
                raise ValueError('Git command did not return one exact source HEAD')
            summary['sourceHEAD'] = head
        elif name == 'compiler':
            bind_input(output / 'local-adoption')
            summary['executableSHA256'] = expected_inputs[str(output / 'local-adoption')]['sha256']
        elif name == 'runtime':
            stdout = stdout_path.read_bytes()
            log = stdout + b'\n' + stderr_path.read_bytes()
            count = sum(line.startswith(b'PASS ') for line in stdout.splitlines())
            record['passLines'] = count
            summary['passLines'] = count
            if f1_baseline:
                expected = b'same-descriptor readback stranded current nonfirst intent'
                record['expectedRuntimeFailure'] = expected.decode('utf8')
                if record['exitCode'] in (None, 0) or record['timedOut'] or expected not in log:
                    raise ValueError('F1 V1 did not establish the exact expected runtime failure')
                return 'F1_V1_EXPECTED_RUNTIME_FAILURE'
            if record['exitCode'] != 0 or count < 70 or b'local-adoption synthetic orchestration and real journal checks:' not in log:
                raise ValueError('Normal runtime did not complete all required fixture checks')
        return 'SUCCEEDED'

    def command_for(name):
        if name == 'extraction':
            command = ['node', str(ROOT / 'test/account-file-local-adoption-inputs.cjs'), str(ROOT), str(output)]
            return command + (['--f1-v1-journal'] if f1_baseline else [])
        if name == 'sdk':
            return ['/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-path']
        if name == 'git':
            return ['git', '-C', str(ROOT), 'rev-parse', 'HEAD']
        if name == 'compiler':
            return ['/usr/bin/nice', '-n', '15', '/usr/bin/time', '-l', '/usr/bin/xcrun', 'swiftc',
                    '-parse-as-library', '-swift-version', '6', '-strict-concurrency=complete', '-warnings-as-errors',
                    '-j', '1', '-num-threads', '1', '-whole-module-optimization', '-Onone',
                    '-target', platform.machine() + '-apple-macosx14.0', '-sdk', state['sdk'],
                    '-module-cache-path', str(output / 'module-cache'), *state['inputs']['compilerInputs'],
                    '-framework', 'Security', '-framework', 'CoreFoundation', '-o', str(output / 'local-adoption')]
        policy = '(version 1) (allow default) (deny network*) (deny file-write*) (allow file-write* (subpath ' + json.dumps(str(output)) + '))'
        return ['/usr/bin/nice', '-n', '15', '/usr/bin/time', '-l', '/usr/bin/sandbox-exec', '-p', policy,
                str(output / 'local-adoption'), str(output)]

    def run_phase(name, blocked_by=None):
        phase = output / name
        phase.mkdir(exist_ok=False)
        stdout_path, stderr_path = phase / 'stdout.bin', phase / 'stderr.bin'
        input_paths = list(expected_inputs)
        before = hashes(input_paths)
        command = None if blocked_by else command_for(name)
        cwd = output if name == 'runtime' else ROOT
        record = {'phase': name, 'command': command, 'cwd': str(cwd), 'timeoutSeconds': phase_limits[name],
                  'startedAtUTC': utc(), 'completed': False, 'status': 'PREPARED', 'blockedBy': blocked_by,
                  'processStarted': False, 'processID': None, 'processGroupID': None,
                  'processGroupKillRequested': False, 'processLeaderReaped': None, 'ownedProcessGroupAbsent': None,
                  'drainTimeoutSeconds': 5, 'exitCode': None, 'resultExitCode': None, 'timedOut': False, 'stopped': False,
                  'stdout': {'path': str(stdout_path)}, 'stderr': {'path': str(stderr_path)},
                  'inputHashesBefore': before, 'matchesExpectedInputsBefore': matches_expected(before)}
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
                    process = subprocess.Popen(command, cwd=cwd, stdout=stdout, stderr=stderr,
                                               env=environment, start_new_session=True)
                    record.update(processStarted=True, processID=process.pid, processGroupID=process.pid)
                    phase_deadline = time.monotonic() + phase_limits[name]
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
            after = hashes(input_paths)
            stable = matches_expected(before) and matches_expected(after) and before == after
            record.update(inputHashesAfter=after, matchesExpectedInputsAfter=matches_expected(after), inputsUnchanged=stable)
            if result_code == 0 and not stable:
                result_code = 125
                record['status'] = 'FAILED_INPUT_CHANGED'
            expected_negative = (name == 'runtime' and f1_baseline and record['status'] == 'FAILED_COMMAND'
                                 and stable and record['processLeaderReaped'] and record['ownedProcessGroupAbsent'] is True)
            if result_code == 0 or expected_negative:
                try:
                    stdout.flush(); stderr.flush()
                    record['status'] = consume(name, record, stdout_path, stderr_path)
                    result_code = 0
                except BaseException:
                    result_code = 125
                    record['status'] = 'FAILED_PHASE_OUTPUT_OR_CHECKS'
                    note(traceback.format_exc())
            if STOP_SIGNAL is not None:
                record.update(stopped=True, receivedSignal=STOP_SIGNAL)
                if result_code == 0:
                    result_code = 128 + STOP_SIGNAL
                    record['status'] = 'FAILED_SIGNAL'
            if record.get('logWriteErrors') and result_code == 0:
                result_code = 125
                record['status'] = 'FAILED_LOG_WRITE'
        record['stdout'] = {'path': str(stdout_path), **hashes([stdout_path])[str(stdout_path)]}
        record['stderr'] = {'path': str(stderr_path), **hashes([stderr_path])[str(stderr_path)]}
        if result_code == 0:
            try:
                bind_input(stdout_path); bind_input(stderr_path)
            except Exception:
                result_code = 125
                record['status'] = 'FAILED_LOG_HASH'
                record['logHashException'] = traceback.format_exc()
        record.update(completed=True, finishedAtUTC=utc(), elapsedSeconds=time.monotonic() - started, resultExitCode=result_code)
        write_json(phase / 'receipt.json', record)
        summary['phases'][name] = {'receipt': str(phase / 'receipt.json'), 'status': record['status'],
                                  'exitCode': record['exitCode'], 'resultExitCode': result_code,
                                  'timedOut': record['timedOut'], 'stopped': record['stopped'],
                                  'ownedProcessGroupAbsent': record['ownedProcessGroupAbsent']}
        write_json(receipt_path, summary)
        return result_code

    previous_handlers = {sig: signal.signal(sig, request_stop) for sig in (signal.SIGINT, signal.SIGTERM)}
    first_failure = None
    final_code = 0
    try:
        for name in order:
            if STOP_SIGNAL is not None and first_failure is None:
                first_failure, final_code = 'signal-' + str(STOP_SIGNAL), 128 + STOP_SIGNAL
            try:
                code = run_phase(name, blocked_by=first_failure)
            except BaseException:
                # Owned cleanup has been attempted in run_phase's finally; do not claim that
                # an unverified drain established absence. Preserve a terminal failure and
                # still create explicit NOT_RUN receipts for remaining phases when storage permits.
                code = 127
                summary['phases'][name] = {'status': 'FAILED_RUNNER_EXCEPTION', 'resultExitCode': code,
                                          'error': traceback.format_exc()}
                phase = output / name
                phase.mkdir(exist_ok=True)
                (phase / 'runner-error.txt').write_text(traceback.format_exc())
                write_json(phase / 'receipt.json', {'phase': name, 'completed': True, **summary['phases'][name]})
            if code != 0 and first_failure is None:
                first_failure, final_code = name, code
        if STOP_SIGNAL is not None and first_failure is None:
            first_failure, final_code = 'signal-' + str(STOP_SIGNAL), 128 + STOP_SIGNAL
        summary['completed'] = True
        summary['status'] = ('F1_V1_EXPECTED_RUNTIME_FAILURE' if f1_baseline else 'LOCAL_ADOPTION_ORCHESTRATION_JOURNAL_PASS') if first_failure is None else 'FAILED'
    except BaseException:
        summary['status'] = 'FAILED_RUNNER_EXCEPTION'
        summary['runnerException'] = traceback.format_exc()
        final_code = final_code or 127
    finally:
        if STOP_SIGNAL is not None and final_code == 0:
            first_failure, final_code = 'signal-' + str(STOP_SIGNAL), 128 + STOP_SIGNAL
            summary['status'] = 'FAILED_SIGNAL'
        summary.update(finishedAtUTC=utc(), resultExitCode=final_code, firstFailedPhase=first_failure,
                       receivedSignal=STOP_SIGNAL, stopped=STOP_SIGNAL is not None, consumedInputHashes=expected_inputs)
        write_json(receipt_path, summary)
        for sig, handler in previous_handlers.items():
            signal.signal(sig, handler)
    print(summary['status'] + ': ' + str(receipt_path))
    if final_code:
        raise SystemExit(final_code if final_code >= 0 else 128 - final_code)


if __name__ == '__main__':
    main()
