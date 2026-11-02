#!/usr/bin/env python3
"""Run all three maintained gates against the already verified packaged static SDK.

Emit allowlisted metadata/hashes only. Never upload raw logs, headers, sources,
compiled binaries or credentials. SDK provenance comes from preceding CI gates.
"""
import hashlib
import json
import math
import os
from pathlib import Path
import re
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
SPECS = (
    ('converter', 'scripts/test-account-backup-repair-live-abi.sh', 'account-backup-repair-abi.',
     'ABI_COMPATIBILITY_PASS', 269, 'backup-repair-abi'),
    ('service', 'scripts/test-account-file-repair-service-live-abi.sh', 'account-file-repair-service-abi.',
     'SERVICE_BOUNDARY_ABI_PASS', 35, 'backup-repair-abi'),
    ('restore', 'scripts/test-account-file-restore-live-abi.sh', 'account-file-restore-abi.',
     'RESTORE_ADMISSION_JOURNAL_ABI_PASS', 63, 'account-file-restore-abi'),
)


def digest(path):
    with path.open('rb') as stream:
        result = hashlib.sha256()
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def write(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')


def source_hashes(mapping):
    if not isinstance(mapping, dict) or not mapping:
        raise ValueError('missing source hashes')
    result = {}
    for name, expected in mapping.items():
        path = Path(name)
        if not path.is_absolute():
            path = ROOT / path
        path = path.resolve(strict=True)
        relative = path.relative_to(ROOT).as_posix()
        if not relative.startswith(('app/SourcesShared/', 'app/Tests/', 'app/build/', 'scripts/', 'test/')):
            raise ValueError('unexpected source domain')
        if not re.fullmatch(r'[0-9a-f]{64}', expected) or digest(path) != expected:
            raise ValueError('source changed')
        result[relative] = expected
    return result


def process_summary(value):
    if value is None:
        return None
    code, timeout, elapsed = value['exitCode'], value['timedOut'], value['elapsedSeconds']
    if not (code is None or type(code) is int) or type(timeout) is not bool:
        raise ValueError('invalid process result')
    if type(elapsed) not in (int, float) or not math.isfinite(elapsed) or elapsed < 0:
        raise ValueError('invalid process duration')
    return {'exitCode': code, 'timedOut': timeout, 'elapsedSeconds': elapsed}


def main():
    evidence = Path(os.environ['RUNNER_TEMP']) / 'account-backup-abi-evidence'
    evidence.mkdir(exist_ok=True)
    metadata = {'schemaVersion': 1, 'status': 'PREPARING', 'fixtures': {}}
    status = 1
    try:
        source = os.environ['BUILD_SOURCE_SHA']
        revision = os.environ['EXPECTED_NATIVE_REVISION']
        workflow = os.environ['GITHUB_SHA']
        if not all(re.fullmatch(r'[0-9a-f]{40}', value) for value in [source, revision, workflow]):
            raise ValueError('invalid revision')
        actual = subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse', 'HEAD'], text=True).strip()
        if actual != source or os.environ['VORTX_ENGINE_SOURCE_REVISION'] != revision:
            raise ValueError('source revision mismatch')
        metadata.update(sourceCommit=source, workflowCommit=workflow, nativeSourceRevision=revision,
                        runID=os.environ['GITHUB_RUN_ID'], attempt=os.environ['GITHUB_RUN_ATTEMPT'],
                        coordinatorSHA256=digest(Path(__file__)))
        sdk = ROOT / 'app/Vendor/VortxEngine.xcframework/macos-arm64'
        header = sdk / 'Headers/vortx/vortx_ffi.h'
        library = sdk / 'libvortx_ffi.a'
        with library.open('rb') as stream:
            if stream.read(8) != b'!<arch>\n':
                raise ValueError('not static SDK')
        sdk_before = {'headerSHA256': digest(header), 'librarySHA256': digest(library)}
        metadata['sdkBefore'] = sdk_before
        environment = dict(os.environ)
        # Explicit packaged inputs override any prior full-ABI dylib variables.
        environment['VORTX_FFI_HEADER'] = str(header)
        environment['VORTX_FFI_LIBRARY'] = str(library)
        build = ROOT / 'app/build'
        build.mkdir(exist_ok=True)
        private = Path(tempfile.mkdtemp(prefix='account-backup-abi-private.', dir=os.environ['RUNNER_TEMP']))
        passed = True
        for label, entry, prefix, expected_status, minimum, binary in SPECS:
            result = {'status': 'NOT_STARTED'}
            metadata['fixtures'][label] = result
            before = set(build.glob(prefix + '*'))
            driver = private / (label + '-driver.log')
            try:
                with driver.open('wb') as stream:
                    code = subprocess.run(['bash', str(ROOT / entry)], cwd=ROOT, env=environment,
                                          stdout=stream, stderr=subprocess.STDOUT).returncode
                result['entryExitCode'] = code
                result['driverLogSHA256'] = digest(driver)
                directories = set(build.glob(prefix + '*')) - before
                if len(directories) != 1:
                    raise ValueError('missing or ambiguous fresh fixture directory')
                directory = directories.pop().resolve(strict=True)
                if directory.parent != build.resolve() or not directory.is_dir():
                    raise ValueError('fixture containment')
                result['outputHashes'] = {}
                for name in ['receipt.json', 'inputs.json', 'compiler.log', 'test.log', binary]:
                    path = directory / name
                    if path.is_file() and not path.is_symlink():
                        result['outputHashes'][name] = digest(path)
                receipt = json.loads((directory / 'receipt.json').read_text())
                admitted_statuses = ('PREPARED', 'COMPILE_FAILED_OR_TIMED_OUT',
                                     'RUNTIME_FAILED_OR_TIMED_OUT', expected_status)
                if receipt.get('status') not in admitted_statuses:
                    raise ValueError('unknown receipt status')
                result['receiptStatus'] = receipt['status']
                result['compiler'] = process_summary(receipt.get('compiler'))
                result['runtime'] = process_summary(receipt.get('runtime'))
                count = receipt.get('passLines')
                if count is not None and (type(count) is not int or count < 0):
                    raise ValueError('invalid assertion count')
                result['passLines'] = count
                result['postRunInputsUnchanged'] = receipt.get('postRunInputsUnchanged') is True
                # Emit only verified hashes, never declaration text or raw argv/logs.
                result['sourceHashes'] = source_hashes(receipt['sourceHashes'])
                result['controlHashes'] = source_hashes(receipt['controlHashes'])
                result['compiledInputHashes'] = source_hashes(receipt['compiledInputHashes'])
                result['metadataHashes'] = source_hashes(receipt['metadataHashes'])
                sdk_expected = {str(header): sdk_before['headerSHA256'], str(library): sdk_before['librarySHA256']}
                actual_log = (directory / 'test.log').read_bytes() if (directory / 'test.log').is_file() else b''
                actual_passes = sum(line.startswith(b'PASS: ') for line in actual_log.splitlines())
                valid = (code == 0 and receipt.get('status') == expected_status and
                         receipt.get('sourceHEAD') == source and receipt.get('sdkHashes') == sdk_expected and
                         receipt.get('compiler', {}).get('exitCode') == 0 and
                         receipt.get('compiler', {}).get('timedOut') is False and
                         receipt.get('runtime', {}).get('exitCode') == 0 and
                         receipt.get('runtime', {}).get('timedOut') is False and
                         receipt.get('postRunInputsUnchanged') is True and
                         actual_passes >= minimum and receipt.get('passLines') == actual_passes and
                         receipt.get('testLogSHA256') == hashlib.sha256(actual_log).hexdigest())
                result['status'] = 'PASS' if valid else 'FAILED'
                passed = passed and valid
            except Exception:
                # Fixed code only: exceptions can contain paths or source content.
                result['status'] = 'EVIDENCE_OR_EXECUTION_FAILED'
                if driver.is_file():
                    result['driverLogSHA256'] = digest(driver)
                passed = False
            write(evidence / (label + '.json'), result)
        # All gates must still describe the same retained source bytes at exit.
        for result in metadata['fixtures'].values():
            for key in ('sourceHashes', 'controlHashes', 'compiledInputHashes', 'metadataHashes'):
                if key in result:
                    source_hashes(result[key])
        if (digest(Path(__file__)) != metadata['coordinatorSHA256'] or
                subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse', 'HEAD'], text=True).strip() != source):
            raise ValueError('source changed after fixture execution')
        metadata['sdkAfter'] = {'headerSHA256': digest(header), 'librarySHA256': digest(library)}
        metadata['sdkUnchanged'] = metadata['sdkAfter'] == sdk_before
        status = 0 if passed and metadata['sdkUnchanged'] else 1
        metadata['status'] = 'PASS' if status == 0 else 'FAILED'
    except Exception:
        metadata['status'] = 'SETUP_OR_EVIDENCE_FAILED'
    finally:
        write(evidence / 'gate.json', metadata)
    print('Account backup packaged-SDK gate: ' + metadata['status'])
    raise SystemExit(status)


if __name__ == '__main__':
    main()
