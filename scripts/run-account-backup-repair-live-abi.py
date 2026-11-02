#!/usr/bin/env python3
"""Synthetic file-repair generic ABI gate; never builds the app or private SDK.

Use VORTX_FFI_HEADER + VORTX_FFI_LIBRARY together, or the existing
VORTX_NATIVE_TEST_SDK_SLICE convention (default: packaged macos-arm64 slice).
SDK/source provenance belongs to the owning protected workflow, not this test.
"""
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


def require_same(path, expected):
    if digest(path) != expected:
        raise SystemExit('Consumed input changed: ' + str(path))


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
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        raise SystemExit('This protected fixture requires an arm64 macOS runner')
    if not Path('/usr/bin/sandbox-exec').is_file():
        raise SystemExit('Runtime sandbox unavailable; an unrestricted fallback is not permitted')
    header_arg, library_arg = os.environ.get('VORTX_FFI_HEADER'), os.environ.get('VORTX_FFI_LIBRARY')
    if bool(header_arg) != bool(library_arg):
        raise SystemExit('Supply VORTX_FFI_HEADER and VORTX_FFI_LIBRARY together')
    if header_arg:
        header, library = Path(header_arg).resolve(), Path(library_arg).resolve()
    else:
        sdk = Path(os.environ.get('VORTX_NATIVE_TEST_SDK_SLICE',
                                  ROOT / 'app/Vendor/VortxEngine.xcframework/macos-arm64')).resolve()
        header, library = sdk / 'Headers/vortx/vortx_ffi.h', sdk / 'libvortx_ffi.a'
    header_bytes = header.read_bytes()
    if not library.read_bytes().startswith(b'!<arch>\n'):
        raise SystemExit('Supply the real static macOS SDK archive; no dylib/stub fallback')
    for symbol in [b'vortx_init_runtime', b'vortx_init_from_state_json', b'vortx_dispatch_json',
                   b'vortx_get_state_json', b'vortx_engine_free', b'vortx_owner_history_canonicalize_evidence_json']:
        if symbol not in header_bytes:
            raise SystemExit('The current production C ABI requires a missing header declaration')
    subprocess.run(['/usr/bin/lipo', '-verify_arch', 'arm64', str(library)], check=True)
    build = ROOT / 'app/build'
    build.mkdir(parents=True, exist_ok=True)
    if ROOT not in build.resolve().parents:
        raise SystemExit('app/build escaped the repository')
    output = Path(tempfile.mkdtemp(prefix='account-backup-repair-abi.', dir=build)).resolve()
    print('Retained synthetic backup-repair ABI output: ' + str(output), flush=True)
    scripts = [Path(__file__).resolve(), ROOT / 'scripts/test-account-backup-repair-live-abi.sh',
               ROOT / 'test/account-backup-repair-inputs.cjs', ROOT / 'test/xperience-harness-inputs.cjs']
    controls = {str(path): digest(path) for path in scripts}
    sdk_hashes = {str(header): digest(header), str(library): digest(library)}
    subprocess.run(['node', str(ROOT / 'test/account-backup-repair-inputs.cjs'), str(ROOT), str(output)], check=True)
    input_file = output / 'inputs.json'
    inputs = json.loads(input_file.read_text())
    (output / 'vortx_ffi.h').write_bytes(header_bytes)
    (output / 'module.modulemap').write_text('module VortxEngine { header "vortx_ffi.h" export * }\n')
    compiler_inputs = inputs['compilerInputs']
    compiled_hashes = {path: digest(Path(path)) for path in compiler_inputs}
    metadata_hashes = {str(path): digest(path) for path in
                       [input_file, output / 'vortx_ffi.h', output / 'module.modulemap']}
    compiler_sdk = subprocess.check_output(['/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    compiler = ['/usr/bin/nice', '-n', '15', '/usr/bin/time', '-l', '/usr/bin/xcrun', 'swiftc',
                '-parse-as-library', '-swift-version', '6', '-strict-concurrency=complete', '-warnings-as-errors',
                '-j', '1', '-num-threads', '1', '-whole-module-optimization', '-Onone',
                '-target', 'arm64-apple-macosx14.0', '-sdk', compiler_sdk,
                '-module-cache-path', str(output / 'module-cache'), '-I', str(output)]
    compiler += compiler_inputs + [str(library), '-framework', 'Security', '-framework', 'SystemConfiguration',
                                  '-framework', 'CoreFoundation', '-lresolv', '-liconv', '-lz',
                                  '-o', str(output / 'backup-repair-abi')]
    receipt = {
        'scope': 'synthetic generic native schemas 1-5 cold conversion/replay only',
        'sdkProvenance': 'not certified by this harness; owning protected workflow must validate source/artifact provenance',
        'limitations': ['no schema6/owner-history proof; unused owner type traps',
                        'no account/UI/file-save/full-restore-adoption proof'],
        'sourceHEAD': subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse', 'HEAD'], text=True).strip(),
        'sdkHashes': sdk_hashes, 'controlHashes': controls, 'metadataHashes': metadata_hashes,
        'sourceHashes': inputs['sourceHashes'], 'declarations': inputs['declarations'],
        'compiledInputHashes': compiled_hashes, 'compilerArgv': compiler,
        'status': 'PREPARED',
    }
    receipt_path = output / 'receipt.json'
    def save():
        receipt_path.write_text(json.dumps(receipt, indent=2) + '\n')
    def unchanged():
        for mapping in [sdk_hashes, controls, metadata_hashes, compiled_hashes]:
            for path, expected in mapping.items():
                require_same(Path(path), expected)
        for relative, expected in inputs['sourceHashes'].items():
            require_same(ROOT / relative, expected)
    environment = dict(os.environ)
    environment.update({'OMP_NUM_THREADS': '1', 'RAYON_NUM_THREADS': '1', 'VECLIB_MAXIMUM_THREADS': '1'})
    save()
    receipt['compiler'] = bounded(compiler, output / 'compiler.log', 240, ROOT, environment)
    receipt['status'] = 'COMPILE_FAILED_OR_TIMED_OUT'
    save()
    unchanged()
    if receipt['compiler']['exitCode'] != 0:
        raise SystemExit('Compile did not pass; retained compiler.log is authoritative')
    test_log = output / 'test.log'
    policy = '(version 1) (allow default) (deny network*) (deny file-write*) (allow file-write* (literal ' + json.dumps(str(test_log)) + '))'
    runtime = ['/usr/bin/nice', '-n', '15', '/usr/bin/time', '-l', '/usr/bin/sandbox-exec', '-p', policy,
               str(output / 'backup-repair-abi')]
    receipt['runtimeArgv'] = runtime
    receipt['runtime'] = bounded(runtime, test_log, 60, output, environment)
    unchanged()
    log = test_log.read_bytes()
    count = sum(line.startswith(b'PASS: ') for line in log.splitlines())
    # This floor protects the initial 269-check producer/negative/output packet. It
    # supplements actual preconditions and the terminal marker, never replaces them.
    passed = (receipt['runtime']['exitCode'] == 0 and count >= 269 and
              b'All synthetic backup repair checks passed with the linked native ABI;' in log)
    receipt['passLines'] = count
    receipt['postRunInputsUnchanged'] = True
    receipt['testLogSHA256'] = hashlib.sha256(log).hexdigest()
    receipt['status'] = 'ABI_COMPATIBILITY_PASS' if passed else 'RUNTIME_FAILED_OR_TIMED_OUT'
    save()
    print(log.decode('utf8', errors='replace'), end='')
    print(receipt['status'] + ': ' + str(receipt_path))
    if not passed:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
