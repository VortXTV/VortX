#!/usr/bin/env python3
"""Candidate evidence only. No publication, device execution or runtime-security verdict."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import zipfile


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def run(*args):
    return subprocess.check_output(args, text=True, timeout=60)


def save(path, data):
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + '\n')


def relro_16k_safe(row, loads):
    # Android also permits an unaligned RELRO end when it occupies its entire LOAD,
    # with no other LOAD data inside the page-rounded protection range. Do not
    # mistake NDK/LLD's isolated RELRO layout for writable data sharing that page.
    # https://developer.android.com/guide/practices/page-sizes (Check the RELRO security flag)
    offset, start, file_size, memory_size = (int(row[i], 16) for i in (1, 2, 4, 5))
    end = start + memory_size
    if end % 16384 == 0:
        return True
    if memory_size <= 0:
        return False
    owners = [index for index, load in enumerate(loads)
              if tuple(int(load[i], 16) for i in (1, 2, 4, 5)) ==
              (offset, start, file_size, memory_size)]
    if len(owners) != 1:
        return False
    protected_start = start // 16384 * 16384
    protected_end = (end + 16383) // 16384 * 16384
    for index, load in enumerate(loads):
        if index == owners[0]:
            continue
        other_start, other_size = int(load[2], 16), int(load[5], 16)
        if other_size and other_start < protected_end and other_start + other_size > protected_start:
            return False
    return True


def android(out, upstream, sdk, *, readelf=None):
    inspection = None
    if readelf is None:
        # The original hosted producer toolchain remains unchanged.
        readelf = sdk / 'ndk/30.0.16248370/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-readelf'
    else:
        if not readelf.is_absolute():
            raise ValueError('explicit inspection reader must be an absolute path')
        requested_reader = readelf
        resolved_reader = readelf.resolve(strict=True)
        if not resolved_reader.is_file():
            raise ValueError('explicit inspection reader is not a regular executable file')
        # Keep the llvm-readelf invocation name: LLVM's llvm-readobj symlink target
        # selects a different output style when invoked directly by its real basename.
        version = run(str(readelf), '--version').strip()
        if not version or len(version) > 4096:
            raise ValueError('unexpected inspection reader version output')
        inspection = {'mode': 'explicit-read-only-inspector',
                      'requestedReader': str(requested_reader), 'resolvedReader': str(resolved_reader),
                      'readerSHA256': digest(resolved_reader), 'readerVersion': version,
                      'validatorSHA256': digest(Path(__file__))}
    aar = out / 'libmpv-release-candidate.aar'
    machines = {'arm64-v8a': ('ELF64', 'AArch64'), 'armeabi-v7a': ('ELF32', 'ARM'),
                'x86_64': ('ELF64', 'Advanced Micro Devices X86-64')}
    required = {'libmpv.so', 'libplayer.so', 'libc++_shared.so', 'libavcodec.so', 'libavformat.so',
                'libavutil.so', 'libavfilter.so', 'libavdevice.so', 'libswresample.so', 'libswscale.so'}
    source_header = (out / 'tls_mbedtls_vortx_distrust.h').read_text()
    keys = [bytes(int(x, 16) for x in re.findall(r'0x([0-9a-f]{2})', line))
            for line in source_header.splitlines() if '}, /* EM' in line]
    if len(keys) != 8 or any(len(key) != 32 for key in keys):
        raise ValueError('unexpected reviewed distrust table')
    records = []
    with zipfile.ZipFile(aar) as archive, tempfile.TemporaryDirectory(dir=out) as temporary:
        names = archive.namelist()
        if len(names) != len(set(names)):
            raise ValueError('duplicate AAR entries')
        libraries = [name for name in names if name.startswith('jni/') and name.endswith('.so')]
        if {name.split('/')[1] for name in libraries} != set(machines):
            raise ValueError('AAR must contain exactly three admitted native ABIs')
        for abi, (elf_class, machine) in machines.items():
            present = {name.split('/')[-1] for name in libraries if name.startswith(f'jni/{abi}/')}
            if not required <= present:
                raise ValueError(f'missing packaged media library: {abi}: {sorted(required - present)}')
            for name in sorted(n for n in libraries if n.startswith(f'jni/{abi}/')):
                if len(name.split('/')) != 3 or archive.getinfo(name).file_size > 512 * 1024**2:
                    raise ValueError('unexpected native entry shape/size')
                data = archive.read(name)
                target = Path(temporary) / 'library.so'
                target.write_bytes(data)
                header = run(str(readelf), '-h', str(target))
                if (not re.search(r'Class:\s+' + elf_class + r'\b', header) or not re.search(
                        r'Machine:\s+' + re.escape(machine) + r'\s*$', header, re.M)
                        or not re.search(r'Type:\s+DYN\b', header) or 'little endian' not in header):
                    raise ValueError(f'wrong native ELF identity: {name}')
                segments = run(str(readelf), '-W', '-l', str(target)).splitlines()
                loads = [line.split() for line in segments if line.strip().startswith('LOAD ')]
                relro = [line.split() for line in segments if line.strip().startswith('GNU_RELRO ')]
                if not loads or (elf_class == 'ELF64' and (not relro or any(
                        int(row[-1], 16) < 16384 or (int(row[2], 16) - int(row[1], 16)) % 16384
                        for row in loads) or any(not relro_16k_safe(row, loads) for row in relro))):
                    raise ValueError(f'not 16 KiB compatible: {name}')
                if name.endswith('/libavformat.so'):
                    if any(flag not in data for flag in (b'--enable-mbedtls', b'--enable-gpl', b'--enable-version3')):
                        raise ValueError(f'expected TLS/GPL configuration missing: {name}')
                    if any(key not in data for key in keys):
                        raise ValueError(f'distrust-key constants missing: {name}')
                records.append({'entry': name, 'sha256': hashlib.sha256(data).hexdigest(),
                                'bytes': len(data), 'elfIdentityChecked': True,
                                'loadAlignments': [int(row[-1], 16) for row in loads],
                                'page16KiBChecked': elf_class == 'ELF64'})
    evidence = {
        'aarSHA256': digest(aar), 'libraries': records, 'runtimeSecurityTested': False,
        'appAndSeamBindingChanged': False, 'promotionEligible': False}
    if inspection is not None:
        # This describes only the inspection host/tool, never the original producer's NDK.
        evidence['inspection'] = inspection
    save(out / 'android-artifact-evidence.json', evidence)


def receipt(lane, out, upstream, exit_code):
    roots = [upstream]
    for directory in (upstream / 'dist', upstream / 'buildscripts/deps'):
        if directory.is_dir():
            roots.extend(path for path in directory.iterdir() if (path / '.git').exists())
    sources = []
    for index, path in enumerate(roots):
        patch = out / f'source-{index}.patch'
        patch.write_text(run('git', '-C', str(path), 'diff', '--binary'))
        sources.append({'directory': path.name, 'commit': run('git', '-C', str(path), 'rev-parse', 'HEAD').strip(),
                        'trackedDiffSHA256': digest(patch)})
    save(out / 'result.json', {'schema': 1, 'lane': lane, 'buildExit': exit_code,
         'appSourceCommit': os.environ['GITHUB_SHA'], 'workflowRef': os.environ.get('GITHUB_WORKFLOW_REF'),
         'runId': os.environ['GITHUB_RUN_ID'], 'attempt': os.environ['GITHUB_RUN_ATTEMPT'],
         'sources': sources, 'runtimeSecurityTested': False, 'promotionEligible': False})
    # build.log is still owned by the workflow's tee process until this shell exits.
    files = {str(path.relative_to(out)): digest(path) for path in sorted(out.iterdir())
             if path.is_file() and path.suffix != '.log'}
    save(out / 'artifact-sha256.json', files)


if __name__ == '__main__':
    if sys.argv[1] == 'android':
        if len(sys.argv) not in (5, 7) or (len(sys.argv) == 7 and sys.argv[5] != '--readelf'):
            raise SystemExit('android OUT UPSTREAM SDK [--readelf /absolute/path/to/llvm-readelf]')
        android(*(Path(value) for value in sys.argv[2:5]),
                readelf=Path(sys.argv[6]) if len(sys.argv) == 7 else None)
    elif sys.argv[1] == 'receipt':
        receipt(sys.argv[2], Path(sys.argv[3]), Path(sys.argv[4]), int(sys.argv[5]))
    else:
        raise SystemExit('unknown evidence mode')
