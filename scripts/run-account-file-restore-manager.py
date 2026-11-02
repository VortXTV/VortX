#!/usr/bin/env python3
"""Unchanged-source manager orchestration with declared synthetic collaborators. No native SDK linked."""
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


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def bounded(argv, log, seconds, cwd, environment):
    started = time.monotonic()
    with log.open('wb') as stream:
        process = subprocess.Popen(argv, cwd=cwd, stdout=stream, stderr=subprocess.STDOUT,
                                   env=environment, start_new_session=True)
        try:
            code = process.wait(timeout=seconds)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            return {'exitCode': None, 'timedOut': True, 'elapsedSeconds': time.monotonic() - started}
    return {'exitCode': code, 'timedOut': False, 'elapsedSeconds': time.monotonic() - started}


def main():
    if platform.system() != 'Darwin' or platform.machine() not in ('arm64', 'x86_64'):
        raise SystemExit('This fixture requires an arm64 or x86_64 macOS runner')
    if not Path('/usr/bin/sandbox-exec').is_file():
        raise SystemExit('Runtime sandbox unavailable; no unrestricted fallback')
    build = ROOT / 'app/build'
    build.mkdir(parents=True, exist_ok=True)
    if ROOT not in build.resolve().parents:
        raise SystemExit('app/build escaped the repository')
    output = Path(tempfile.mkdtemp(prefix='account-file-restore-manager.', dir=build)).resolve()
    print('Retained synthetic restore-manager output: ' + str(output), flush=True)
    controls = {str(p): digest(p) for p in [Path(__file__).resolve(),
        ROOT / 'scripts/test-account-file-restore-manager.sh',
        ROOT / 'test/account-file-restore-manager-inputs.cjs', ROOT / 'test/xperience-harness-inputs.cjs']}
    receipt = {'scope': 'unchanged-source dedicated account-file restore manager orchestration',
               'nativeSDK': 'NOT_LINKED; explicit synthetic preparation/absence/journal/transport collaborators',
               'controlHashes': controls, 'status': 'EXTRACTING'}
    receipt_path = output / 'receipt.json'

    def save():
        receipt_path.write_text(json.dumps(receipt, indent=2) + '\n')

    save()
    environment = dict(os.environ)
    environment.update({'OMP_NUM_THREADS': '1', 'RAYON_NUM_THREADS': '1', 'VECLIB_MAXIMUM_THREADS': '1'})
    selector = ['node', str(ROOT / 'test/account-file-restore-manager-inputs.cjs'), str(ROOT), str(output)]
    receipt['extraction'] = bounded(selector, output / 'extraction.log', 30, ROOT, environment)
    save()
    if receipt['extraction']['exitCode'] != 0:
        receipt['status'] = 'EXTRACTION_FAILED_OR_TIMED_OUT'
        save()
        raise SystemExit('Extraction failed before compilation; retained extraction.log is authoritative')
    input_file = output / 'inputs.json'
    inputs = json.loads(input_file.read_text())
    compiler_inputs = inputs['compilerInputs']
    compiled_hashes = {p: digest(Path(p)) for p in compiler_inputs}
    metadata_hashes = {str(input_file): digest(input_file)}
    sdk = subprocess.check_output(['/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True, timeout=30).strip()
    compiler = ['/usr/bin/nice', '-n', '15', '/usr/bin/time', '-l', '/usr/bin/xcrun', 'swiftc',
                '-parse-as-library', '-swift-version', '6', '-strict-concurrency=complete', '-warnings-as-errors',
                '-j', '1', '-num-threads', '1', '-whole-module-optimization', '-Onone',
                '-target', platform.machine() + '-apple-macosx14.0', '-sdk', sdk,
                '-module-cache-path', str(output / 'module-cache')]
    compiler += compiler_inputs + ['-framework', 'Security', '-framework', 'CoreFoundation',
                                   '-o', str(output / 'restore-manager')]
    receipt.update({'sourceHEAD': subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse', 'HEAD'], text=True, timeout=30).strip(),
                    'sourceHashes': inputs['sourceHashes'], 'declarations': inputs['declarations'],
                    'productionManagerBlockSHA256': inputs['productionManagerBlockSHA256'],
                    'compiledInputHashes': compiled_hashes, 'metadataHashes': metadata_hashes,
                    'compilerArgv': compiler, 'limitations': inputs['limitations'], 'status': 'PREPARED'})

    def unchanged():
        for mapping in [controls, metadata_hashes, compiled_hashes]:
            for name, expected in mapping.items():
                if digest(Path(name)) != expected:
                    raise SystemExit('Consumed fixture input changed: ' + name)
        for relative, expected in inputs['sourceHashes'].items():
            if digest(ROOT / relative) != expected:
                raise SystemExit('Consumed source changed: ' + relative)

    save()
    receipt['compiler'] = bounded(compiler, output / 'compiler.log', 240, ROOT, environment)
    receipt['status'] = 'COMPILE_FAILED_OR_TIMED_OUT'
    save()
    unchanged()
    if receipt['compiler']['exitCode'] != 0:
        raise SystemExit('Compile did not pass; retained compiler.log is authoritative')
    executable = output / 'restore-manager'
    receipt['executableSHA256'] = digest(executable)
    test_log = output / 'test.log'
    policy = '(version 1) (allow default) (deny network*) (deny file-write*) (allow file-write* (literal ' + json.dumps(str(test_log)) + '))'
    runtime = ['/usr/bin/nice', '-n', '15', '/usr/bin/time', '-l', '/usr/bin/sandbox-exec', '-p', policy, str(executable)]
    receipt['runtimeArgv'] = runtime
    receipt['runtime'] = bounded(runtime, test_log, 60, output, environment)
    unchanged()
    if digest(executable) != receipt['executableSHA256']:
        raise SystemExit('Compiled fixture executable changed')
    log = test_log.read_bytes()
    count = sum(line.startswith(b'PASS: ') for line in log.splitlines())
    passed = receipt['runtime']['exitCode'] == 0 and count >= 150 and (
        b'All unchanged-source account file restore manager orchestration checks passed with explicit synthetic collaborators.' in log)
    receipt.update({'passLines': count, 'postRunInputsUnchanged': True,
                    'testLogSHA256': hashlib.sha256(log).hexdigest(),
                    'status': 'MANAGER_ORCHESTRATION_PASS' if passed else 'RUNTIME_FAILED_OR_TIMED_OUT'})
    save()
    print(log.decode('utf8', errors='replace'), end='')
    print(receipt['status'] + ': ' + str(receipt_path))
    if not passed:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
