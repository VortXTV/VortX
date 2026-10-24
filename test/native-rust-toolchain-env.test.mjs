import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';

const root = fileURLToPath(new URL('../', import.meta.url));
const helper = path.join(root, 'scripts/native-rust-toolchain-env.sh');
const build = path.join(root, 'app/build');
fs.mkdirSync(build, {recursive:true});
const run = fs.mkdtempSync(path.join(build, 'native-rust-llvm-contract.'));
let fixtureID = 0;

// These controlled version-command doubles test environment/failure propagation,
// not native compilation or LLVM functionality. Genuine strip acceptance is separate.
function invoke(options = {}) {
  const dir = path.join(run, String(++fixtureID));
  const bin = path.join(dir, 'bin');
  const sysroot = path.join(dir, 'pinned toolchain');
  const host = options.host ?? 'aarch64-apple-darwin';
  const objcopy = path.join(sysroot, 'lib/rustlib', host, 'bin/rust-objcopy');
  fs.mkdirSync(bin, {recursive:true});
  if (!options.missingLibraries) fs.mkdirSync(path.dirname(objcopy), {recursive:true});
  fs.writeFileSync(path.join(bin, 'rustup'), `#!/bin/bash
[[ "$1" == run && "$2" == nightly-2026-07-19 && "$3" == rustc ]] || exit 19
[[ "\${FAKE_RUSTUP_EXIT:-0}" == 0 ]] || exit "$FAKE_RUSTUP_EXIT"
if [[ "$4" == --print && "$5" == sysroot ]]; then
  printf '%s\\n' "$FAKE_SYSROOT"
elif [[ "$4" == -vV ]]; then
  printf 'host: %s\\n' "$FAKE_HOST"
else
  exit 20
fi
`, {mode:0o755});
  if (!options.missingLibraries && !options.missingObjcopy) {
    // A /bin/bash shebang would itself discard DYLD_* under macOS SIP, unlike
    // the real bundled native tool. Use this existing non-system Node runtime.
    fs.writeFileSync(objcopy, `#!${process.execPath}
const fs = require('node:fs');
if (process.argv.length !== 3 || process.argv[2] !== '--version') process.exit(21);
fs.writeFileSync(process.env.FAKE_RECORD, process.env.DYLD_LIBRARY_PATH ?? '');
process.exit(Number(process.env.FAKE_OBJCOPY_EXIT ?? 0));
`, {mode:0o755});
  }
  const env = {...process.env, PATH:bin + ':' + process.env.PATH,
    FAKE_SYSROOT:options.relativeSysroot ? 'relative/toolchain' : sysroot,
    FAKE_HOST:host, FAKE_RECORD:path.join(dir, 'lookup'),
    FAKE_RUSTUP_EXIT:String(options.rustupExit ?? 0),
    FAKE_OBJCOPY_EXIT:String(options.objcopyExit ?? 0),
    FAKE_HAS_AMBIENT:options.ambient === undefined ? '0' : '1',
    FAKE_AMBIENT:options.ambient ?? ''};
  delete env.DYLD_LIBRARY_PATH;
  const child = spawnSync('/bin/bash', ['-e', '-u', '-o', 'pipefail', '-c', `
if [[ "$FAKE_HAS_AMBIENT" == 1 ]]; then
  export DYLD_LIBRARY_PATH="$FAKE_AMBIENT"
else
  unset DYLD_LIBRARY_PATH
fi
source "$1"
value="$(native_rust_llvm_library_path nightly-2026-07-19)"
printf 'LOOKUP=%s\\nAMBIENT=%s\\n' "$value" "\${DYLD_LIBRARY_PATH-unset}"
`, 'native-rust-contract', helper], {cwd:root, env, encoding:'utf8', timeout:5000});
  assert.equal(child.error, undefined);
  return {...child, expected:path.join(sysroot, 'lib'), record:env.FAKE_RECORD};
}

test('pinned lookup handles spaces, preflights objcopy and leaves ambient unset', () => {
  const r = invoke();
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.stdout, `LOOKUP=${r.expected}\nAMBIENT=unset\n`);
  assert.equal(fs.readFileSync(r.record, 'utf8'), r.expected);
});

test('an explicit ambient lookup is retained only in the child command', () => {
  const ambient = '/owner/extra library';
  const r = invoke({ambient});
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.stdout, `LOOKUP=${r.expected}:${ambient}\nAMBIENT=${ambient}\n`);
  assert.equal(fs.readFileSync(r.record, 'utf8'), `${r.expected}:${ambient}`);
});

test('an empty ambient lookup does not add an empty search-path component', () => {
  const r = invoke({ambient:''});
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.stdout, `LOOKUP=${r.expected}\nAMBIENT=\n`);
});

test('the Intel Apple host uses its own pinned stripping tool', () => {
  const r = invoke({host:'x86_64-apple-darwin'});
  assert.equal(r.status, 0, r.stderr);
  assert.equal(fs.readFileSync(r.record, 'utf8'), r.expected);
});

for (const [name, options, message] of [
  ['relative sysroot', {relativeSysroot:true}, /Missing native Rust toolchain/],
  ['missing library directory', {missingLibraries:true}, /Missing native Rust toolchain/],
  ['unsupported host', {host:'aarch64-unknown-linux-gnu'}, /Unsupported native Rust/],
  ['missing objcopy', {missingObjcopy:true}, /Missing native Rust stripping tool/],
  ['unloadable objcopy', {objcopyExit:23}, /cannot load its pinned LLVM library/],
  ['unavailable pinned Rust', {rustupExit:24}, null]
]) {
  test(`${name} fails before any native build`, () => {
    const r = invoke(options);
    assert.notEqual(r.status, 0);
    assert.equal(r.stdout, '');
    if (message) assert.match(r.stderr, message);
  });
}

test('the actual producer scopes lookup to Cargo and hashes the helper in its cache key', () => {
  const source = fs.readFileSync(path.join(root, 'scripts/build-ffi-xcframework.sh'), 'utf8');
  assert.match(source, /source "\$REPO_ROOT\/scripts\/native-rust-toolchain-env\.sh"/);
  assert.match(source, /NATIVE_RUST_LLVM_PATH="\$\(native_rust_llvm_library_path nightly-2026-07-19\)"/);
  assert.ok(source.indexOf('NATIVE_RUST_LLVM_PATH=') < source.indexOf('rustup +nightly-2026-07-19 target add'));
  assert.match(source, /CARGO_PROFILE_RELEASE_PANIC=abort \\\n\s+DYLD_LIBRARY_PATH="\$NATIVE_RUST_LLVM_PATH" \\\n\s+SDKROOT=/);
  assert.doesNotMatch(source, /export DYLD_LIBRARY_PATH/);
  const workflow = fs.readFileSync(path.join(root, '.github/workflows/release-tvos.yml'), 'utf8');
  const key = workflow.split('\n').find(line => line.includes('key: vortx-ffi-resource-host-v1-'));
  assert.ok(key?.includes("'scripts/native-rust-toolchain-env.sh'"));
});

test('the later hosted ABI Cargo build preflights and scopes the same lookup on cache hits', () => {
  const workflow = fs.readFileSync(path.join(root, '.github/workflows/release-tvos.yml'), 'utf8');
  const step = workflow.split('      - name: Verify native account and episode ABI against the reviewed engine\n')[1]
    ?.split('\n      # The self-built player stack.')[0];
  assert.ok(step);
  assert.match(step, /source "\$PWD\/scripts\/native-rust-toolchain-env\.sh"/);
  assert.match(step, /NATIVE_RUST_LLVM_PATH="\$\(native_rust_llvm_library_path nightly-2026-07-19\)"/);
  assert.match(step, /DYLD_LIBRARY_PATH="\$NATIVE_RUST_LLVM_PATH" \\\n\s+MACOSX_DEPLOYMENT_TARGET=14\.0 \\\n\s+cargo \+nightly-2026-07-19 build --locked/);
  assert.match(step, /--no-default-features --features resource-host --release --target aarch64-apple-darwin/);
  assert.match(step, /bash scripts\/test-native-cutover-live-abi\.sh/);
  assert.doesNotMatch(step, /export DYLD_LIBRARY_PATH|CARGO_PROFILE_RELEASE_PANIC|RUSTFLAGS|cache-hit/);
});
