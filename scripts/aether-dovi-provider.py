#!/usr/bin/env python3
"""DRAFT: inspect a genuine x86_64 tvOS provider and extend an owned resolved package.

No toolchain/install/download behavior. Run only in the parent-authorized build lane.
"""
import argparse
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import struct
import subprocess
import tempfile

PACKAGE = '0d7cce1d6836a30d13a3a2326e50a153af53f014'
SOURCE = 'd1abe0e27ff2c7ab3339614d06db9f8a058af6b2'
SOURCE_TREE = 'b2183f7cc3d62918ad43b346835a2dab7d2ad875'
LOCK = '5c9f344b8a49f684e409af8304e4e175618098c9b24ed8acafc5f1a469088814'
HEADER = '772414183763c6ab234789f38fd6850168faf6b288a1763b6bb19370b14af7be'
ARM = '001a7890e3455d38a180becad09ebdd273e0c73433e8a26eea7485d5ed7010c7'
OLD = 'tvos-arm64-simulator'
NEW = 'tvos-arm64_x86_64-simulator'


def need(ok, message):
    if not ok:
        raise ValueError(message)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def read(path):
    need(path.is_file() and not path.is_symlink(), 'unsafe or missing file: '+str(path))
    return path.read_bytes()


def run(args):
    return subprocess.check_output([str(x) for x in args], text=True).strip()


def tokens(data):
    value = re.sub(r'/\*.*?\*/|//[^\n]*', '', data.decode(), flags=re.S)
    return re.findall(r'[A-Za-z_]\w*|\d+|[^\s]', value)


def owned(path, root, *, fresh=False):
    need(root.is_absolute() and root.is_dir() and root == root.resolve(), 'owned root must be a real absolute directory')
    need(path.is_absolute() and '..' not in path.parts and path != root, 'noncanonical owned child path')
    need(root in path.parents, 'path escapes owned build root: '+str(path))
    for node in [path, *path.parents]:
        need(not node.is_symlink(), 'symlink in owned path: '+str(node))
    need('/Library/Caches/' not in str(path) and '/.cache/' not in str(path), 'shared cache is never an owned package output')
    if fresh:
        need(not os.path.lexists(path), 'fresh output required: '+str(path))



@contextmanager
def writable_staged_directory(directory, work):
    # copytree preserves upstream read-only modes. Change only this owned staging
    # directory, and restore its exact mode even when replacement fails.
    owned(directory, work)
    need(directory.is_dir(), 'missing staging directory: '+str(directory))
    mode = stat.S_IMODE(directory.stat().st_mode)
    try:
        directory.chmod(mode | stat.S_IWUSR | stat.S_IXUSR)
        yield
    finally:
        directory.chmod(mode)


def replace_staged_file(path, body, work):
    owned(path, work)
    need(path.is_file(), 'missing staging file: '+str(path))
    mode = stat.S_IMODE(path.stat().st_mode)
    # A sibling rename replaces a read-only inode without opening it for writing.
    # Keep its original mode, and never chmod or overwrite the source/cache inode.
    with writable_staged_directory(path.parent, work):
        descriptor, temporary = tempfile.mkstemp(prefix='.dovi-replace-', dir=path.parent)
        temporary = Path(temporary)
        try:
            with os.fdopen(descriptor, 'wb') as stream:
                stream.write(body)
                stream.flush()
                os.fchmod(stream.fileno(), mode)
            owned(path, work)
            os.replace(temporary, path)
        finally:
            if os.path.lexists(temporary):
                temporary.unlink()


def source_clean(source):
    need(run(['git','-C',source,'rev-parse','HEAD']) == SOURCE, 'source commit differs')
    need(run(['git','-C',source,'rev-parse','HEAD^{tree}']) == SOURCE_TREE, 'source tree differs')
    need(not run(['git','-C',source,'status','--porcelain','--untracked-files=all']), 'dirty library source')
    need(not run(['git','-C',source,'ls-files','--others','--ignored','--exclude-standard']), 'ignored source inputs are forbidden')
    need(sha(read(source/'dolby_vision/Cargo.lock')) == LOCK, 'library lock changed')
    for directory in [source/'dolby_vision', source, *source.parents]:
        for name in ('config', 'config.toml'):
            need(not os.path.lexists(directory/'.cargo'/name), 'ambient ancestor Cargo configuration: '+str(directory))


def package_owned(package, root):
    owned(package, root)
    gitdir = Path(run(['git','-C',package,'rev-parse','--path-format=absolute','--git-common-dir']))
    owned(gitdir, root)


def archive(body, symbols, expected_sdk):
    need(body.startswith(b'!<arch>\n'), 'not a thin static archive')
    position = 8
    members = []
    owners = {name: 0 for name in symbols}
    while position < len(body):
        need(position+60 <= len(body), 'archive header out of range')
        header = body[position:position+60]
        need(header[58:] == b'`\n', 'invalid archive member trailer')
        size = int(header[48:58].strip())
        name = header[:16].decode().strip()
        begin, end = position+60, position+60+size
        need(size >= 0 and end <= len(body), 'archive member out of range')
        raw = body[begin:end]
        if name.startswith('#1/'):
            length = int(name[3:])
            need(0 < length <= len(raw), 'invalid extended archive name')
            name, raw = raw[:length].rstrip(b'\0').decode(), raw[length:]
        name = name.rstrip('/')
        position = end+(size & 1)
        if name in ('__.SYMDEF', '__.SYMDEF SORTED', '__.SYMDEF_64', '__.SYMDEF_64 SORTED'):
            continue
        need(len(raw) >= 32 and raw[:4] == b'\xcf\xfa\xed\xfe', 'not a real Mach-O object: '+name)
        cpu, subtype, kind, count, command_bytes = struct.unpack_from('<5I', raw, 4)
        need(cpu == 0x1000007 and subtype & 0xffffff == 3 and kind == 1, 'wrong CPU/subtype/kind: '+name)
        need(count <= 8192 and 32+command_bytes <= len(raw), 'invalid load commands')
        cursor, versions, symtab, sections = 32, [], None, []
        for _ in range(count):
            need(cursor+8 <= 32+command_bytes, 'truncated load command')
            command, length = struct.unpack_from('<2I', raw, cursor)
            need(length >= 8 and cursor+length <= 32+command_bytes, 'invalid load command size')
            if command == 0x32:
                need(length >= 24, 'short build-version command')
                versions.append(struct.unpack_from('<3I', raw, cursor+8))
            need(command not in (0x24, 0x25, 0x2f, 0x30), 'ambiguous legacy platform stamp')
            if command == 2:
                need(length == 24 and symtab is None, 'invalid symbol table command')
                symtab = struct.unpack_from('<4I', raw, cursor+8)
            if command == 0x19:
                need(length >= 72, 'short segment command')
                nsects = struct.unpack_from('<I', raw, cursor+64)[0]
                need(length == 72+80*nsects, 'invalid segment section count')
                for idx in range(nsects):
                    base = cursor+72+80*idx
                    address, extent, offset = struct.unpack_from('<QQI', raw, base+32)
                    flags = struct.unpack_from('<I', raw, base+64)[0]
                    if flags & (0x80000000 | 0x400) and extent:
                        need(offset > 0 and offset+extent <= len(raw), 'instruction section file extent')
                    sections.append((raw[base:base+16].split(b'\0')[0], flags, address, extent))
            cursor += length
        need(cursor == 32+command_bytes and len(versions) == 1, 'missing/duplicate platform version: '+name)
        platform, minimum, sdk = versions[0]
        need(platform == 8 and minimum == 17 << 16, 'not tvOS Simulator 17.0: '+name)
        need(sdk == expected_sdk or (sdk == 0 and name.endswith('.rcgu.o')), 'object SDK differs from selected SDK: '+name)
        if symtab:
            start, number, strings, string_bytes = symtab
            need(start+16*number <= len(raw) and strings+string_bytes <= len(raw), 'symbol table bounds')
            for idx in range(number):
                offset, ntype, nsect, desc, value = struct.unpack_from('<IBBHQ', raw, start+16*idx)
                if not ntype & 0xe0 and ntype & 1 and ntype & 0xe == 0xe and nsect:
                    need(offset < string_bytes, 'symbol name bounds')
                    terminator = raw.find(b'\0', strings+offset, strings+string_bytes)
                    need(terminator >= 0, 'unterminated symbol')
                    symbol = raw[strings+offset:terminator].decode().removeprefix('_')
                    if symbol in owners:
                        need(0 < nsect <= len(sections), 'function section bounds')
                        section, flags, address, extent = sections[nsect-1]
                        need(section == b'__text' and flags & (0x80000000 | 0x400) and not desc & 0x80, 'API is not a strong function: '+symbol)
                        need(address <= value < address+extent, 'API symbol points outside real code: '+symbol)
                        owners[symbol] += 1
        members.append({'name': name, 'bytes': len(raw), 'sha256': sha(raw), 'platform': platform, 'minimum': minimum, 'sdk': sdk})
    need(position == len(body) and members and all(count == 1 for count in owners.values()), 'incomplete archive or missing/duplicate C API')
    return {'members': members, 'requiredSymbolOwners': owners}


def manifest(root):
    need(root.is_dir() and not root.is_symlink(), 'unsafe XCFramework root')
    result = {}
    for path in sorted(root.rglob('*')):
        need(not path.is_symlink(), 'symlink in XCFramework')
        if path.is_file():
            result[str(path.relative_to(root))] = sha(read(path))
        else:
            need(path.is_dir(), 'nonregular XCFramework entry')
    return result


def verify_provider(package, provider):
    need(run(['git', '-C', package, 'rev-parse', 'HEAD']) == PACKAGE, 'upstream package revision changed')
    original = read(package/'Dovi.xcframework'/OLD/'Headers/dovi.h')
    need(sha(original) == HEADER, 'upstream header changed')
    generated = read(provider/'install/include/libdovi/rpu_parser.h')
    need(tokens(original) == tokens(generated), 'complete generated C API differs from consumed upstream header')
    pc = read(provider/'install/lib/pkgconfig/dovi.pc').decode()
    need(re.search(r'^Version:\s*3\.4\.0\s*$', pc, re.M), 'library version differs')
    without_comments = re.sub(rb'/\*.*?\*/', b'', original, flags=re.S)
    symbols = sorted(set(x.decode() for x in re.findall(rb'\b(dovi_[a-z0-9_]+)\s*\(', without_comments)))
    need(len(symbols) == 24, 'pinned API roster changed')
    body = read(provider/'install/lib/libdovi.a')
    build = json.loads(read(provider/'build-receipt.json'))
    need(build['schema'] == 1 and build['sourceCommit'] == SOURCE and build['sourceTree'] == SOURCE_TREE and build['packageCommit'] == PACKAGE, 'unbound producer source/package')
    need(build['sourceFiles']['dolby_vision/Cargo.lock'] == LOCK and build['toolchain'] == 'nightly-2026-07-19' and build['cargoCVersion'] == '0.10.26+cargo-0.100.0', 'producer tool/source pins changed')
    need(build['compiled'] is True and build['apiLinked'] is True and build['runtimeTested'] is False, 'producer completion flags')
    required_outputs = {'install/lib/libdovi.a','install/include/libdovi/rpu_parser.h','install/lib/pkgconfig/dovi.pc',
        'LICENSE-libdovi.txt','LICENSE-packaging.txt','build-command.txt','build-environment.txt','build.log',
        'cargo-c-version.txt','cargo-version.txt','rustc-version.txt','xcode-version.txt','sdk-version.txt','sdk-build-version.txt',
        'probe.c','probe.o','probe.dylib','probe-link-command.json','probe-symbols.txt'}
    need(set(build['outputs']) == required_outputs, 'producer output receipt is incomplete')
    for path, digest in build['outputs'].items():
        need(sha(read(provider/path)) == digest, 'producer output changed: '+path)
    need(set(build['tools']) == {'rustc','cargo','cargo-cinstall','clang','ar'}, 'tool receipt incomplete')
    for name, tool in build['tools'].items():
        need(Path(tool['path']).is_absolute() and re.fullmatch('[0-9a-f]{64}',tool['sha256']), 'invalid tool receipt: '+name)
    sdk_parts = read(provider/'sdk-version.txt').decode().strip().split('.')
    need(1 <= len(sdk_parts) <= 3 and all(part.isdecimal() and int(part) < 256 for part in sdk_parts), 'invalid selected SDK')
    sdk_values = list(map(int,sdk_parts))+[0,0]
    sdk = sdk_values[0] << 16 | sdk_values[1] << 8 | sdk_values[2]
    evidence = archive(body, symbols, sdk)
    receipt = {'schema': 1, 'packageCommit': PACKAGE, 'sourceCommit': SOURCE, 'libraryVersion': '3.4.0',
               'rustTarget': 'x86_64-apple-tvos', 'consumedHeaderSHA256': HEADER, 'generatedHeaderSHA256': sha(generated),
               'archiveSHA256': sha(body), 'archiveBytes': len(body), 'inspection': evidence,
               'buildReceiptSHA256': sha(read(provider/'build-receipt.json')),
               'runtimeTested': False, 'cApiLinkTested': True, 'applicationLinkTested': False}
    (provider/'provider-inspection.json').write_text(json.dumps(receipt, indent=2)+'\n')
    return receipt


def extend(package, provider, work):
    need(not os.path.lexists(work) and work.is_absolute(), 'fresh absolute extension work directory required')
    need(package not in work.parents and provider not in work.parents,
         'extension work must be outside package and provider inputs')
    need(not run(['git', '-C', package, 'status', '--porcelain', '--untracked-files=all']), 'package must be pristine before extension')
    receipt = verify_provider(package, provider)
    xc = package/'Dovi.xcframework'
    before = manifest(xc)
    arm = xc/OLD/'libdovi.a'
    need(sha(read(arm)) == ARM, 'original arm64 simulator provider changed')
    work.mkdir(parents=True)
    staged = work/'Dovi.xcframework'
    shutil.copytree(xc, staged)
    old = staged/OLD
    new = staged/NEW
    with writable_staged_directory(staged, work):
        old.rename(new)
    combined = work/'combined.a'
    run(['xcrun', 'lipo', '-create', arm, provider/'install/lib/libdovi.a', '-output', combined])
    need(set(run(['xcrun', 'lipo', '-archs', combined]).split()) == {'arm64', 'x86_64'}, 'unexpected combined architectures')
    for arch, expected in [('arm64', ARM), ('x86_64', receipt['archiveSHA256'])]:
        leaf = work/(arch+'.a')
        run(['xcrun', 'lipo', combined, '-thin', arch, '-output', leaf])
        need(sha(read(leaf)) == expected, 'combined archive changed input architecture bytes')
    replace_staged_file(new/'libdovi.a', read(combined), work)
    info = plistlib.loads(read(staged/'Info.plist'))
    selected = [row for row in info['AvailableLibraries'] if row['LibraryIdentifier'] == OLD]
    need(len(selected) == 1 and selected[0]['SupportedPlatform'] == 'tvos' and selected[0].get('SupportedPlatformVariant') == 'simulator' and selected[0]['SupportedArchitectures'] == ['arm64'], 'unexpected upstream slice row')
    selected[0]['LibraryIdentifier'] = NEW
    selected[0]['SupportedArchitectures'] = ['arm64', 'x86_64']
    replace_staged_file(staged/'Info.plist', plistlib.dumps(info), work)
    after = manifest(staged)
    expected_paths = {name.replace(OLD+'/', NEW+'/', 1) if name.startswith(OLD+'/') else name for name in before}
    need(set(after) == expected_paths, 'unreviewed XCFramework file set change')
    for path, digest in before.items():
        if path in ('Info.plist', OLD+'/libdovi.a'):
            continue
        moved = path.replace(OLD+'/', NEW+'/', 1) if path.startswith(OLD+'/') else path
        need(after[moved] == digest, 'unrelated slice/header changed: '+path)
    # Caller supplies an owned resolved-package checkout, never the shared SwiftPM cache.
    backup = work/'original-Dovi.xcframework'
    shutil.move(str(xc), backup)
    try:
        shutil.move(str(staged), xc)
        need(manifest(xc) == after, 'installed XCFramework readback differs')
        result = {'schema': 1, 'packageCommit': PACKAGE, 'provider': receipt, 'before': before, 'after': after}
        (work/'extension-receipt.json').write_text(json.dumps(result, indent=2)+'\n')
    except BaseException:
        if xc.exists():
            shutil.move(str(xc), work/'rejected-Dovi.xcframework')
        shutil.move(str(backup), xc)
        raise


def link_probe(package, provider, clang, sdk):
    header = read(package/'Dovi.xcframework'/OLD/'Headers/dovi.h')
    need(sha(header) == HEADER, 'consumed header changed')
    need(tokens(header) == tokens(read(provider/'install/include/libdovi/rpu_parser.h')), 'generated ABI header differs')
    text = re.sub(r'/\*.*?\*/|//[^\n]*', '', header.decode(), flags=re.S)
    symbols = sorted(set(re.findall(r'\b(dovi_[a-z0-9_]+)\s*\(', text)))
    need(len(symbols) == 24, 'C API probe roster changed')
    values = []
    for fields, name in re.findall(r'typedef\s+struct\s*\{(.*?)\}\s*(Dovi\w+)\s*;', text, re.S):
        values += ['sizeof('+name+')', '_Alignof('+name+')']
        for field in fields.split(';'):
            if field.strip():
                match = re.search(r'([A-Za-z_]\w*)\s*(?:\[[^\]]*\]\s*)*$', field)
                need(match is not None, 'unsupported C ABI field syntax')
                values.append('offsetof('+name+', '+match.group(1)+')')
    need(values, 'no public struct layout probes')
    probe = '#include "dovi.h"\n#include <stddef.h>\n#include <stdint.h>\ntypedef void (*DoviProbeFn)(void);\n'
    probe += '__attribute__((used,visibility("default"))) DoviProbeFn volatile vortx_dovi_api[] = {\n'
    probe += ',\n'.join('(DoviProbeFn)&'+name for name in symbols)+'\n};\n'
    probe += '__attribute__((used,visibility("default"))) const uint64_t vortx_dovi_abi[] = {'+', '.join(values)+'};\n'
    (provider/'probe.c').write_text(probe)
    base = [str(clang), '-target', 'x86_64-apple-tvos17.0-simulator', '-isysroot', str(sdk), '-std=c11', '-Werror', '-fno-common']
    compile_command = base+['-I'+str(package/'Dovi.xcframework'/OLD/'Headers'), '-c', str(provider/'probe.c'), '-o', str(provider/'probe.o')]
    link_command = base+['-dynamiclib', str(provider/'probe.o'), str(provider/'install/lib/libdovi.a'), '-Wl,-undefined,error', '-o', str(provider/'probe.dylib')]
    subprocess.run(compile_command, check=True)
    subprocess.run(link_command, check=True)
    defined = run(['xcrun','nm','-gU',provider/'probe.dylib'])
    for name in symbols:
        need(re.search(r'\bT\s+_'+re.escape(name)+r'$', defined, re.M), 'C API did not survive real link: '+name)
    (provider/'probe-symbols.txt').write_text(defined+'\n')
    (provider/'probe-link-command.json').write_text(json.dumps({'compile':compile_command,'link':link_command},indent=2)+'\n')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('mode', choices=['preflight', 'link-probe', 'verify-provider', 'extend', 'verify-installed'])
    parser.add_argument('--package', required=True, type=Path)
    parser.add_argument('--provider', type=Path)
    parser.add_argument('--work', type=Path)
    parser.add_argument('--owned-root', required=True, type=Path)
    parser.add_argument('--source', type=Path)
    parser.add_argument('--clang', type=Path)
    parser.add_argument('--sdk', type=Path)
    args = parser.parse_args()
    package = args.package
    package_owned(package, args.owned_root)
    if args.mode == 'preflight':
        need(args.source is not None and args.provider is not None, 'source/provider required')
        owned(args.provider,args.owned_root,fresh=True)
        source_clean(args.source)
        need(run(['git','-C',package,'rev-parse','HEAD']) == PACKAGE, 'package commit differs')
        need(not run(['git','-C',package,'status','--porcelain','--untracked-files=all']), 'dirty package')
    elif args.mode == 'verify-installed':
        need(args.work is not None, '--work required')
        owned(args.work,args.owned_root)
        receipt = json.loads(read(args.work/'extension-receipt.json'))
        need(run(['git', '-C', package, 'rev-parse', 'HEAD']) == PACKAGE == receipt['packageCommit'], 'upstream revision changed after extension')
        need(manifest(package/'Dovi.xcframework') == receipt['after'], 'installed extension changed')
    else:
        need(args.provider is not None, '--provider required')
        owned(args.provider,args.owned_root)
        provider = args.provider
        if args.mode == 'link-probe':
            need(args.clang is not None and args.sdk is not None, 'clang/sdk required')
            link_probe(package,provider,args.clang,args.sdk)
        elif args.mode == 'verify-provider':
            verify_provider(package, provider)
        else:
            need(args.work is not None, '--work required')
            owned(args.work,args.owned_root,fresh=True)
            extend(package, provider, args.work)
    print('ok: '+args.mode)


if __name__ == '__main__':
    main()
