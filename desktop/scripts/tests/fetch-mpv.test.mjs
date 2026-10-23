import assert from 'node:assert/strict';
import { chmodSync, cpSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { dirname, join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

// Runs the real desktop/scripts/fetch-mpv.sh in a sandbox: stub curl/7z/uname on PATH and fixture
// archives. Only the pinned archive digests are swapped for the fixtures'; nothing is downloaded and no
// player is executed. Covers fresh staging, idempotent reuse, tamper and symlink refusal, and a bad digest.
const repo = dirname(dirname(dirname(dirname(fileURLToPath(import.meta.url)))));
const script = readFileSync(join(repo, 'desktop/scripts/fetch-mpv.sh'), 'utf8');
const root = mkdtempSync(join(repo, '_build-fetch-mpv-test.'));
const put = (path, text, mode) => { mkdirSync(dirname(path), { recursive: true }); writeFileSync(path, text, mode ? { mode } : undefined); };
const sha = (path) => createHash('sha256').update(readFileSync(path)).digest('hex');

// Fixture payloads and archives.
const bundle = join(root, 'input/mpv.app');
put(join(bundle, 'Contents/MacOS/mpv'), 'fixture executable', 0o755);
put(join(bundle, 'Contents/Frameworks/libfixture.dylib'), 'fixture dylib');
symlinkSync('libfixture.dylib', join(bundle, 'Contents/Frameworks/libfixture-current.dylib'));
const macArchive = join(root, 'mac.tar.gz');
assert.equal(spawnSync('/usr/bin/tar', ['-czf', macArchive, '-C', dirname(bundle), 'mpv.app']).status, 0);
const winArchive = join(root, 'win.7z');
const winExe = join(root, 'mpv.exe');
put(winArchive, 'fixture archive bytes');
put(winExe, 'fixture exe bytes', 0o755);

function project(platform, archiveDigest) {
  const dir = mkdtempSync(join(root, `${platform}.`));
  const fixed = script
    .replace(/MPV_MAC_SHA256="[0-9a-f]{64}"/, `MPV_MAC_SHA256="${platform === 'mac' ? archiveDigest : '0'.repeat(64)}"`)
    .replace(/MPV_WIN_SHA256="[0-9a-f]{64}"/, `MPV_WIN_SHA256="${platform === 'win' ? archiveDigest : '0'.repeat(64)}"`);
  put(join(dir, 'desktop/scripts/fetch-mpv.sh'), fixed, 0o755);
  const bin = join(dir, 'bin');
  put(join(bin, 'curl'), '#!/bin/bash\nprintf "called\\n" >> "$FIXTURE_CURL_LOG"\ncp "$FIXTURE_ARCHIVE" "${@: -1}"\n', 0o755);
  put(join(bin, '7z'), '#!/bin/bash\ncp "$FIXTURE_EXE" mpv.exe\nchmod +x mpv.exe\n', 0o755);
  put(join(bin, 'uname'), `#!/bin/bash\n[ "$1" = "-s" ] && echo "${platform === 'mac' ? 'Darwin' : 'MINGW64_NT-10.0'}" || echo "${platform === 'mac' ? 'arm64' : 'x86_64'}"\n`, 0o755);
  return dir;
}

function run(dir, archive) {
  const log = join(dir, 'curl.log');
  const result = spawnSync('/bin/bash', [join(dir, 'desktop/scripts/fetch-mpv.sh')], {
    encoding: 'utf8',
    env: { ...process.env, PATH: `${join(dir, 'bin')}:${process.env.PATH}`, FIXTURE_ARCHIVE: archive, FIXTURE_EXE: winExe, FIXTURE_CURL_LOG: log },
  });
  return { ...result, curlCalls: existsSync(log) ? readFileSync(log, 'utf8').split('\n').filter(Boolean).length : 0 };
}

try {
  const resources = (dir) => join(dir, 'desktop/src-tauri/resources');

  // macOS: fresh stage, idempotent reuse with no download, tamper refusal, symlink refusal.
  const mac = project('mac', sha(macArchive));
  let result = run(mac, macArchive);
  assert.equal(result.status, 0, result.stderr);
  const staged = join(resources(mac), 'mpv-darwin-arm64.app');
  assert.equal(readFileSync(join(staged, 'Contents/MacOS/mpv'), 'utf8'), 'fixture executable');
  assert.ok(lstatSync(join(staged, 'Contents/Frameworks/libfixture-current.dylib')).isSymbolicLink());
  result = run(mac, macArchive);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.curlCalls, 1, 'a verified cached archive is reused without another download');
  writeFileSync(join(staged, 'Contents/Frameworks/libfixture.dylib'), 'tampered');
  result = run(mac, macArchive);
  assert.notEqual(result.status, 0, 'a tampered staged bundle must be refused');
  assert.match(result.stderr, /differs from its pinned archive/);
  rmSync(staged, { recursive: true });
  cpSync(bundle, join(root, 'elsewhere.app'), { recursive: true, verbatimSymlinks: true });
  symlinkSync(join(root, 'elsewhere.app'), staged);
  assert.notEqual(run(mac, macArchive).status, 0, 'a symlinked staged bundle must be refused');
  console.log('PASS macOS: fresh stage, cached reuse, tamper and symlink refusal');

  // macOS: an archive whose digest does not match stages nothing.
  const wrong = project('mac', '1'.repeat(64));
  result = run(wrong, macArchive);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /checksum mismatch/);
  assert.ok(!existsSync(join(resources(wrong), 'mpv-darwin-arm64.app')), 'nothing is staged after a digest mismatch');
  console.log('PASS macOS: digest mismatch stages nothing');

  // Windows: fresh stage of the single executable, then tamper refusal.
  const win = project('win', sha(winArchive));
  result = run(win, winArchive);
  assert.equal(result.status, 0, result.stderr);
  const exe = join(resources(win), 'mpv-win-x64.exe');
  assert.equal(readFileSync(exe, 'utf8'), 'fixture exe bytes');
  writeFileSync(exe, 'tampered');
  assert.notEqual(run(win, winArchive).status, 0, 'a tampered staged executable must be refused');
  console.log('PASS Windows: fresh stage and tamper refusal');
} finally {
  rmSync(root, { recursive: true, force: true });
}
