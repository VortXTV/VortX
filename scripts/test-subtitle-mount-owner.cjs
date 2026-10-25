'use strict';
// Actual owner/renderer coordinator, one bounded extraction and serial compiler/runtime.
const fs = require('node:fs'), path = require('node:path'), crypto = require('node:crypto');
const {fork} = require('node:child_process');
const os = require('node:os');
const root = fs.realpathSync(path.resolve(__dirname, '..'));
const need = (ok, message) => { if (!ok) throw Error(message); };
const shaFile = file => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
need(process.platform === 'darwin' && process.argv.length === 2, 'Run on macOS without arguments');
const architecture = process.arch === 'x64' ? 'x86_64' : process.arch;
need(['arm64', 'x86_64'].includes(architecture), 'Unsupported host architecture');
if (os.getPriority(0) < 15) os.setPriority(0, 15);
need(os.getPriority(0) >= 15, 'Low priority not applied');

const sourceNames = [
  'app/SourcesShared/CredentialScope.swift', 'app/SourcesShared/CoreBridge.swift',
  'app/SourcesShared/VortxNativeCoreFacade.swift', 'app/SourcesShared/LegacyWatchOwnership.swift',
  'app/Tests/SubtitleMountOwnerTests.swift', 'app/Tests/SubtitleRendererLifetimeTests.swift',
  'test/subtitle-mount-owner-fixture.cjs', 'scripts/test-subtitle-mount-owner.sh',
  'scripts/test-subtitle-mount-owner.cjs', 'scripts/native-migration-supervisor.cjs'
];
const sourceSnapshot = () => sourceNames.map(name => [name, shaFile(path.join(root, name))]);
const before = sourceSnapshot();
const supervisor = path.join(root, 'scripts/native-migration-supervisor.cjs');
const supervisorSHA = '8564725ba74e292810a1512ca7723966578e126f2ac4f6aa66312de1ef9657fe';
need(shaFile(supervisor) === supervisorSHA, 'Supervisor changed; review before repinning');
const build = fs.realpathSync(path.join(root, 'app/build'));
const buildRelative = path.relative(root, build);
need(buildRelative && buildRelative !== '..' && !buildRelative.startsWith('..' + path.sep)
  && !path.isAbsolute(buildRelative), 'Real app/build must remain inside this repository');
const sdk = fs.realpathSync('/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk');
const sdkSettings = path.join(sdk, 'SDKSettings.json');
const sdkSHA = shaFile(sdkSettings);
const slot = path.join(build, '.subtitle-mount-owner.slot');
fs.mkdirSync(slot); // An occupied slot is never removed or reused by a new invocation.
let out, active, interruptedExit = 0, generatedBefore;

function sendControl(anchor, message) {
  if (!anchor?.connected) return;
  try {
    anchor.send(message, error => {
      if (error && anchor.connected) anchor.disconnect();
    });
  } catch {
    if (anchor.connected) anchor.disconnect();
  }
}
for (const [signal, exit] of [['SIGINT', 130], ['SIGTERM', 143]]) process.on(signal, () => {
  if (!interruptedExit) interruptedExit = exit;
  sendControl(active, {type: 'cancel', exit: interruptedExit});
});
const save = (name, value) => fs.writeFileSync(path.join(out, name), JSON.stringify(value, null, 2) + '\n', {flag: 'wx', mode: 0o600});
const unchanged = () => JSON.stringify(sourceSnapshot()) === JSON.stringify(before)
  && shaFile(sdkSettings) === sdkSHA;
const generatedSnapshot = () => [
  'extracted/ActualSubtitleOwnerFixture.swift', 'extracted/ActualLegacyWatchOwnership.swift',
  'extracted/ActualFIFOAdmission.swift.txt', 'extracted/extraction.json'
].map(name => [name, shaFile(path.join(out, name))]);

async function run(name, command, timeout) {
  need(!active && !interruptedExit, 'Serial execution lane unavailable');
  need(shaFile(supervisor) === supervisorSHA, 'Supervisor changed before launch');
  const nonce = crypto.randomBytes(24).toString('hex');
  const log = path.join(out, name + '.log'), result = path.join(out, name + '.command.json');
  const anchorLog = path.join(out, name + '.anchor.log');
  const fd = fs.openSync(anchorLog, 'wx', 0o600);
  let anchor;
  try {
    anchor = fork(supervisor, [], {cwd: root, detached: true, execArgv: [],
      stdio: ['ignore', fd, fd, 'ipc'], env: {PATH: '/usr/bin:/bin:/usr/sbin:/sbin',
        OMP_NUM_THREADS: '1', OPENBLAS_NUM_THREADS: '1', VECLIB_MAXIMUM_THREADS: '1',
        SWIFTPM_MAXIMUM_CONCURRENT_OPERATIONS: '1', SWIFT_FRONTEND_THREADS: '1',
        TMPDIR: path.join(out, 'tmp') + '/',
        DEVELOPER_DIR: '/Applications/Xcode.app/Contents/Developer'}});
    active = anchor;
  } finally { fs.closeSync(fd); }
  const events = {};
  const terminal = await new Promise(resolve => {
    let started = false;
    anchor.once('error', error => { events.spawnError = error.message; });
    anchor.on('message', message => {
      if (message?.type !== 'ready' || started || interruptedExit) {
        events.handshakeError = 'Unexpected/duplicate/interrupted readiness';
        sendControl(anchor, {type: 'cancel', exit: interruptedExit || 143});
        return;
      }
      started = true;
      sendControl(anchor, {type: 'start', specification: {nonce, command, timeout,
        cwd: root, log, result}});
    });
    anchor.once('close', (code, signal) => resolve({code, signal}));
  });
  let outcome;
  try { outcome = JSON.parse(fs.readFileSync(result, 'utf8')); }
  catch (error) { events.outcomeError = error.message; }
  save(name + '.result.json', {command, timeout, nonce, terminal, outcome, events,
    anchorLog, log, sourceConserved: unchanged()});
  // This is the live ANCHOR's final group cleanup, not direct compiler-child exit.
  // An absent/abnormal receipt retains the slot for explicit root reconciliation.
  need(terminal.signal === 'SIGKILL' && !events.spawnError && !events.handshakeError
    && !events.outcomeError && outcome.nonce === nonce && outcome.reason === 'command-exit',
    'Abnormal command or owned group cleanup; inspect ' + out);
  active = undefined;
  need(outcome.exit === 0 && !interruptedExit, name + ' failed; inspect ' + log);
  need(unchanged(), 'Source or SDK metadata changed during ' + name);
}

(async () => {
  let error, conserved = false, generatedConserved = false, after;
  try {
    out = fs.mkdtempSync(path.join(build, 'subtitle-mount-owner.'));
    fs.mkdirSync(path.join(out, 'module-cache')); fs.mkdirSync(path.join(out, 'tmp'));
    save('before.json', {root, before, sdk, sdkSHA, architecture, node: process.execPath,
      nice: os.getPriority(0), supervisorSHA,
      limits: 'Actual C/E/proof/retirement/F-lock extraction; synthetic native cleanup and host storage/session boundaries. Not whole app/native/VO/device acceptance.'});
    console.log('Retained subtitle owner evidence: ' + out);
    await run('extract', [process.execPath, path.join(root, 'test/subtitle-mount-owner-fixture.cjs'),
      root, path.join(out, 'extracted')], 30000);
    generatedBefore = generatedSnapshot();
    save('generated-before.json', generatedBefore);
    const executable = path.join(out, 'subtitle-mount-owner-tests');
    await run('compile', ['/usr/bin/xcrun', '--toolchain', 'com.apple.dt.toolchain.XcodeDefault',
      '--sdk', 'macosx', 'swiftc', '-parse-as-library', '-swift-version', '6',
      '-strict-concurrency=complete', '-warnings-as-errors', '-whole-module-optimization',
      '-j', '1', '-num-threads', '1', '-sdk', sdk, '-target', architecture + '-apple-macosx14.0',
      '-module-cache-path', path.join(out, 'module-cache'),
      path.join(out, 'extracted/ActualSubtitleOwnerFixture.swift'),
      path.join(out, 'extracted/ActualLegacyWatchOwnership.swift'),
      path.join(root, 'app/Tests/SubtitleMountOwnerTests.swift'),
      path.join(root, 'app/Tests/SubtitleRendererLifetimeTests.swift'), '-o', executable], 240000);
    need(JSON.stringify(generatedSnapshot()) === JSON.stringify(generatedBefore), 'Generated compiler inputs changed');
    await run('runtime', [executable], 60000);
    const runtime = fs.readFileSync(path.join(out, 'runtime.log'));
    need(runtime.length <= 8 * 1024 * 1024 && /^ALL PASS [1-9][0-9]*$/m.test(runtime.toString('utf8')),
      'Missing completed assertion ledger or oversized runtime log');
    save('binary.json', {path: executable, sha256: shaFile(executable)});
  } catch (failure) { error = String(failure); }
  try {
    after = sourceSnapshot();
    conserved = JSON.stringify(after) === JSON.stringify(before) && shaFile(sdkSettings) === sdkSHA;
    generatedConserved = !generatedBefore || JSON.stringify(generatedSnapshot()) === JSON.stringify(generatedBefore);
  } catch (failure) { error = (error ? error + '; ' : '') + 'Readback: ' + String(failure); }
  if (out) save('result.json', {exit: interruptedExit || (error || !conserved || !generatedConserved ? 1 : 0),
    error, conserved, generatedConserved, before, after, generatedBefore,
    slotRetained: Boolean(active), interruptedExit});
  if (!active) fs.rmdirSync(slot);
  else console.error('SERIAL SLOT RETAINED: inspect ' + out);
  if (interruptedExit || error || !conserved || !generatedConserved) {
    console.error(error || 'Interrupted or inputs changed');
    process.exitCode = interruptedExit || 1;
  } else process.stdout.write(fs.readFileSync(path.join(out, 'runtime.log')));
})();
