'use strict';
// Actual QR/auth methods, inert effects, one serial supervised compiler/runtime.
const fs = require('node:fs'), path = require('node:path'), crypto = require('node:crypto');
const {fork} = require('node:child_process');
const os = require('node:os');
const root = path.resolve(__dirname, '..');
const sha = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const need = (ok, why) => { if (!ok) throw Error(why); };
need(process.platform === 'darwin' && process.argv.length === 2, 'Run on macOS without arguments');
if (os.getPriority(0) < 15) os.setPriority(0, 15);
const sources = ['app/SourcesShared/VortXSyncManager.swift', 'app/SourcesShared/VortXAccountJoinerView.swift',
  'app/SourcesTV/BackupExportView.swift', 'app/Tests/NativeQRJoinOwnershipTests.swift',
  'scripts/test-native-qr-join.cjs', 'scripts/native-migration-supervisor.cjs'];
const read = name => fs.readFileSync(path.join(root, name), 'utf8');
const inputs = new Map(sources.map(name => [name, sha(fs.readFileSync(path.join(root, name)))]));
const manager = read(sources[0]);
function between(text, first, end) {
  const start = text.indexOf(first), last = text.indexOf(end, start + first.length);
  need(start >= 0 && start === text.lastIndexOf(first) && last > start && last === text.lastIndexOf(end), 'Missing/duplicate extraction boundary');
  return text.slice(start, last);
}
function method(text, marker) {
  const first = text.indexOf(marker), open = text.indexOf('{', first);
  need(first >= 0 && first === text.lastIndexOf(marker) && open > first, 'Missing/duplicate caller method');
  let depth = 1, last = open + 1;
  for (; depth && last < text.length; last++) {
    if (text[last] === '{') depth++;
    if (text[last] === '}') depth--;
  }
  need(depth === 0, 'Unbalanced caller method');
  return text.slice(first, last);
}
const declarations = {
  PRODUCTION_AUTH_CAPTURE: between(manager, '    private struct AuthOperationCapture: Sendable, Equatable {', '    private var credentialOwnerRetryTask:'),
  PRODUCTION_AUTH_GENERATION: between(manager, '    private func currentCredentialOwnerIntent() -> AuthOperationCapture {', '    private func logCredentialOwnerAcquisitionDenied('),
  PRODUCTION_QR: between(manager, '    struct QrJoinSession {', '    /// HOLDER (a signed-in device, and the shared shape the web holder mirrors):')
};
let fixture = read(sources[3]);
for (const [name, actual] of Object.entries(declarations)) {
  const marker = '/* ' + name + ' */';
  need(fixture.indexOf(marker) >= 0 && fixture.indexOf(marker) === fixture.lastIndexOf(marker), 'Missing/duplicate fixture marker');
  fixture = fixture.replace(marker, actual);
}
need(!fixture.includes('/* PRODUCTION_'), 'Unfilled fixture');
for (const name of sources.slice(1, 3)) {
  const text = read(name);
  for (const token of ['.onDisappear { stop() }', 'let generation = pollGeneration',
    'guard !Task.isCancelled, pollGeneration == generation else {',
    'if let result { VortXSyncManager.shared.qrCancel(result) }',
    'pollGeneration = UUID()', 'poller?.cancel(); poller = nil',
    'if let session { VortXSyncManager.shared.qrCancel(session) }',
    'session = nil; qrImage = nil', 'await pollLoop(s, generation: generation)'])
    need(text.includes(token), 'QR caller contract missing ' + token + ' in ' + name);
  const loop = method(text, '    private func pollLoop(');
  need((loop.match(/if Task.isCancelled \|\| pollGeneration != generation \{ return \}/g) || []).length === 2,
    'Both poll suspension boundaries must reject old presentation in ' + name);
}
fs.mkdirSync(path.join(root, 'app/build'), {recursive:true});
const out = fs.mkdtempSync(path.join(root, 'app/build/native-qr-join.'));
const sdk = fs.realpathSync('/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk');
const architecture = process.arch === 'x64' ? 'x86_64' : process.arch;
const save = (name, value) => fs.writeFileSync(path.join(out, name), JSON.stringify(value, null, 2) + '\n', {flag:'wx'});
fs.mkdirSync(path.join(out, 'module-cache'));
fs.writeFileSync(path.join(out, 'ActualQR.swift'), fixture, {flag:'wx'});
const generatedSHA256 = sha(Buffer.from(fixture));
save('before.json', {root, sdk, architecture, inputs:[...inputs], generatedSHA256,
  boundaries:'Actual complete QR/auth methods. Inert HTTP/crypto/durability/time; caller source contracts only.'});
console.log('Receipt: ' + out);
const supervisor = path.join(root, 'scripts/native-migration-supervisor.cjs');
need(inputs.get('scripts/native-migration-supervisor.cjs') === '8564725ba74e292810a1512ca7723966578e126f2ac4f6aa66312de1ef9657fe', 'Supervisor changed');
let active, interrupted = false;
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => {
  interrupted = true;
  if (active?.connected) active.send({type:'cancel', exit:143});
});
async function run(name, command, timeout) {
  need(!active && !interrupted, 'Serial lane unavailable');
  const nonce = crypto.randomBytes(24).toString('hex');
  const log = path.join(out, name + '.log'), result = path.join(out, name + '.command.json');
  const fd = fs.openSync(path.join(out, name + '.anchor.log'), 'wx');
  const child = fork(supervisor, [], {cwd:root, detached:true, execArgv:[],
    stdio:['ignore', fd, fd, 'ipc'], env:{PATH:'/usr/bin:/bin:/usr/sbin:/sbin', OMP_NUM_THREADS:'1',
      SWIFTPM_MAXIMUM_CONCURRENT_OPERATIONS:'1', SWIFT_FRONTEND_THREADS:'1',
      OPENBLAS_NUM_THREADS:'1', VECLIB_MAXIMUM_THREADS:'1',
      DEVELOPER_DIR:'/Applications/Xcode.app/Contents/Developer'}});
  fs.closeSync(fd); active = child;
  const terminal = await new Promise((resolve, reject) => {
    let started = false;
    child.once('error', reject);
    child.on('message', message => {
      if (message?.type !== 'ready' || started || interrupted) {
        child.send({type:'cancel', exit:143}); return;
      }
      started = true;
      child.send({type:'start', specification:{nonce, command, timeout, cwd:root, log, result}});
    });
    child.once('close', (code, signal) => resolve({code, signal}));
  });
  const outcome = JSON.parse(fs.readFileSync(result, 'utf8'));
  save(name + '.result.json', {command, timeout, nonce, terminal, outcome});
  need(terminal.signal === 'SIGKILL' && outcome.nonce === nonce && outcome.reason === 'command-exit', 'Abnormal command/cleanup');
  active = undefined;
  need(outcome.exit === 0 && !interrupted, name + ' failed; inspect ' + log);
}
(async () => {
  let error;
  try {
    await run('compile', ['/usr/bin/xcrun', '--toolchain', 'com.apple.dt.toolchain.XcodeDefault', '--sdk', 'macosx', 'swiftc',
      '-target', architecture + '-apple-macosx14.0', '-sdk', sdk,
      '-swift-version', '6', '-strict-concurrency=complete', '-warnings-as-errors', '-j', '1', '-num-threads', '1',
      '-whole-module-optimization', '-parse-as-library', '-module-cache-path', path.join(out, 'module-cache'),
      path.join(out, 'ActualQR.swift'), '-o', path.join(out, 'qr-tests')], 180000);
    await run('runtime', [path.join(out, 'qr-tests')], 30000);
  } catch (failure) { error = String(failure); }
  const after = sources.map(name => [name, sha(fs.readFileSync(path.join(root, name)))]);
  const conserved = JSON.stringify(after) === JSON.stringify([...inputs]) && sha(fs.readFileSync(path.join(out, 'ActualQR.swift'))) === generatedSHA256;
  save('result.json', {exit:error || !conserved ? 1 : 0, error, conserved, after, generatedSHA256});
  if (error || !conserved) { console.error(error || 'Inputs changed'); process.exitCode = 1; }
  else process.stdout.write(fs.readFileSync(path.join(out, 'runtime.log')));
})();
