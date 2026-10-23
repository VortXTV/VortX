'use strict';
// Metered source-unit regression only. No app, live preferences, engine, account or media.
if (process.platform !== 'darwin') throw Error('This source unit requires macOS and Xcode');
require('node:os').setPriority(0, 15);
const fs = require('node:fs'), path = require('node:path'), crypto = require('node:crypto');
const {fork} = require('node:child_process');
const actual = fs.realpathSync(path.resolve(__dirname, '..'));
const fixturePath = actual + '/app/Tests/Fixtures/TVUpNextPrecheckBaseline.swift.txt';
const mode = process.argv[2];
if (!['baseline', 'current'].includes(mode)) throw Error('Expected baseline, or current <retained-baseline-stage>');
const sha = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const entries = [
  [actual + '/app/SourcesTV/TVPlayerView.swift', null],
  [actual + '/app/SourcesShared/CoreModels.swift', null],
  [actual + '/app/SourcesShared/ManualEpisodeNavigationPolicy.swift', null],
  [fixturePath, 'd249cc8a1fe7603a4b536606f7e660b0c92fd7575b756f5e062d0736ed77261d'],
  [actual + '/scripts/native-migration-supervisor.cjs', '8564725ba74e292810a1512ca7723966578e126f2ac4f6aa66312de1ef9657fe'],
];
const captured = entries.map(([file, expected]) => {
  const bytes = fs.readFileSync(file);
  const digest = sha(bytes);
  if (!fs.lstatSync(file).isFile() || (expected !== null && digest !== expected)) throw Error('Input drift: ' + file);
  return {file, sha256: digest, bytes};
});
function one(text, needle) {
  const at = text.indexOf(needle);
  if (at < 0 || text.indexOf(needle, at + needle.length) >= 0) throw Error('Missing/ambiguous source anchor');
  return at;
}
function member(text, marker) {
  const start = one(text, marker), open = text.indexOf('{', start);
  let depth = 0;
  for (let i = open; i < text.length; i++) {
    if (text[i] === '{') depth++;
    if (text[i] === '}' && --depth === 0) return text.slice(start, i + 1);
  }
  throw Error('Unclosed fixed source member');
}
const tv = captured[0].bytes.toString(), models = captured[1].bytes.toString(), nav = captured[2].bytes.toString();
let fixture = captured[3].bytes.toString();
const markers = ['navigationEpisodeSource', 'allEpisodes', 'manualEpisodeNavigationInventory',
  'episodeIndex', 'hasNextEpisode', 'upNextRemaining', 'isCreditsUpNext'].map(name => '    private var ' + name + ':');
for (const marker of markers.slice(0, 5)) if (member(tv, marker) !== member(fixture, marker)) throw Error('TV extraction differs: ' + marker);
for (const [source, marker] of [[models, '    var orderedBySeasonEpisode:'], [nav, '    static func currentIndex(']]) {
  if (member(source, marker) !== member(fixture, marker)) throw Error('Dependency extraction differs');
}
fs.mkdirSync(actual + '/app/_build', {recursive: true});
const parent = fs.realpathSync(actual + '/app/_build');
if (parent !== actual + '/app/_build') throw Error('Unexpected build-directory symlink');
let baseline;
if (mode === 'current') {
  const baselineStage = fs.realpathSync(process.argv[3]);
  if (!baselineStage.startsWith(parent + '/tv-upnext-precheck-20261019.')) throw Error('Wrong retained baseline');
  baseline = JSON.parse(fs.readFileSync(baselineStage + '/result.json'));
  if (!baseline.accepted || baseline.mode !== 'baseline' || baseline.inputs.length !== captured.length || baseline.inputs.some((x, i) => x.sha256 !== captured[i]?.sha256)) throw Error('Unaccepted baseline');
  // Only these two source members differ from the historical baseline. Compile ACTUAL bodies.
  for (const marker of markers.slice(5)) fixture = fixture.replace(member(fixture, marker), member(tv, marker));
}
const stage = fs.mkdtempSync(parent + '/tv-upnext-precheck-20261019.');
for (const folder of ['home', 'tmp', 'cache']) fs.mkdirSync(stage + '/' + folder);
for (let i = 0; i < captured.length; i++) fs.writeFileSync(stage + '/input-' + i, captured[i].bytes, {flag: 'wx', mode: 0o444});
fs.writeFileSync(stage + '/Fixture.swift', fixture, {flag: 'wx', mode: 0o444});
fs.writeFileSync(stage + '/supervisor.cjs', captured[4].bytes, {flag: 'wx', mode: 0o444});
const env = {PATH: '/usr/bin:/bin:/usr/sbin:/sbin', LANG: 'en_US.UTF-8', HOME: stage + '/home',
  CFFIXED_USER_HOME: stage + '/home', TMPDIR: stage + '/tmp'};
const policy = '(version 1)(allow default)(deny network*)(deny file-write*)' +
  '(allow file-write* (subpath ' + JSON.stringify(stage) + ') (literal "/dev/null"))' +
  '(deny file-read* (subpath ' + JSON.stringify(require('node:os').homedir()) + '))' +
  '(allow file-read* (subpath ' + JSON.stringify(stage) + '))' +
  '(deny mach-lookup (global-name "com.apple.cfprefsd.agent") (global-name "com.apple.cfprefsd.daemon"))';
const result = {mode, stage, inputs: captured.map(({file, sha256}) => ({file, sha256})),
  fixtureSHA256: sha(Buffer.from(fixture)), accepted: false, runtime: []};
let active, interrupted = false;
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => {
  interrupted = true; if (active?.connected) active.send({type: 'cancel', exit: 130}, () => {});
});
async function run(name, command, timeout) {
  if (interrupted) throw Error('Interrupted before launch');
  const nonce = crypto.randomBytes(16).toString('hex');
  const specification = {nonce, command: ['/usr/bin/sandbox-exec', '-p', policy, ...command], timeout,
    cwd: stage, log: stage + '/' + name + '.log', result: stage + '/' + name + '-supervisor-result.json'};
  fs.writeFileSync(stage + '/' + name + '-command.json', JSON.stringify({specification, env}, null, 2) + '\n', {flag: 'wx'});
  const log = fs.openSync(stage + '/' + name + '-anchor.log', 'wx');
  let ready = false, anchorExit;
  try { active = fork(stage + '/supervisor.cjs', [], {cwd: stage, env, detached: true,
    execArgv: ['--max-old-space-size=128', '--single-threaded'], stdio: ['ignore', log, log, 'ipc']}); }
  finally { fs.closeSync(log); }
  await new Promise((resolve, reject) => {
    active.once('error', reject);
    active.on('message', message => { if (message?.type === 'ready' && !ready) {
      ready = true;
      if (interrupted) active.send({type: 'cancel', exit: 130}, () => {});
      else active.send({type: 'start', specification}, error => { if (error && active?.connected) active.disconnect(); });
    }});
    active.once('close', (code, signal) => { anchorExit = {code, signal}; active = undefined; resolve(); });
  });
  const outcome = JSON.parse(fs.readFileSync(specification.result));
  if (outcome.nonce !== nonce || outcome.exit !== 0 || outcome.reason !== 'command-exit' || !ready || interrupted || anchorExit.signal !== 'SIGKILL') throw Error('Command failed: ' + name);
  const output = fs.readFileSync(specification.log, 'utf8');
  if (Buffer.byteLength(output) > 65536 || fs.statSync(stage + '/' + name + '-anchor.log').size) throw Error('Unexpected command output');
  return {...outcome, anchorExit, output};
}
function unchanged() { return captured.every((x, i) => sha(fs.readFileSync(x.file)) === x.sha256 &&
  sha(fs.readFileSync(stage + '/input-' + i)) === x.sha256) &&
  sha(fs.readFileSync(stage + '/supervisor.cjs')) === captured[4].sha256 &&
  sha(fs.readFileSync(stage + '/Fixture.swift')) === result.fixtureSHA256; }
function ledgers(output) {
  const lines = output.trimEnd().split('\n');
  if (lines.pop() !== 'TV Up Next precheck: 111 cases passed' || lines.length !== 111) throw Error('Incomplete fixture');
  const seen = new Set();
  return lines.map(line => {
    const m = /^(PASS \d+\/[^ ]+ r=.* c=(?:true|false) hidden=(?:true|false)) sources=(\d+) fields=(\d+) meta=(\d+)$/.exec(line);
    if (!m) throw Error('Bad case ledger');
    const name = m[1].split(' r=')[0];
    if (seen.has(name)) throw Error('Duplicate case');
    seen.add(name);
    return {value: m[1], cost: m.slice(2).map(Number)};
  });
}
(async () => {
  try {
    const compiler = '/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc';
    result.compile = await run('compile', [compiler, '-target', 'arm64-apple-macosx14.0', '-sdk',
      '/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk',
      '-swift-version', '6', '-strict-concurrency=complete', '-warnings-as-errors', '-O', '-whole-module-optimization',
      '-j', '1', '-num-threads', '1', '-parse-as-library', '-module-cache-path', stage + '/cache',
      stage + '/Fixture.swift', '-o', stage + '/fixture'], 180000);
    if (result.compile.output !== '' || !unchanged()) throw Error('Compiler/input gate');
    result.binarySHA256 = sha(fs.readFileSync(stage + '/fixture'));
    for (let i = 0; i < 2; i++) result.runtime.push(await run('runtime-' + i, [stage + '/fixture'], 30000));
    if (result.runtime[0].output !== result.runtime[1].output) throw Error('Non-repeatable ledger');
    result.ledgers = ledgers(result.runtime[0].output);
    if (mode === 'current') for (let i = 0; i < 111; i++) {
      const current = result.ledgers[i], prior = baseline.ledgers[i];
      if (current.value !== prior.value || current.cost.some((n, j) => n > prior.cost[j])) throw Error('Result/cost regression');
      if (/\/(far|suppressed|short60) /.test(current.value) &&
          (current.cost.some(n => n !== 0) || !prior.cost.some(n => n > 0))) throw Error('Required work reduction absent');
      if (/\/final20 /.test(current.value) &&
          current.cost.some((n, j) => n <= 0 || n !== prior.cost[j])) throw Error('Required eligible lookup changed');
    }
    result.accepted = unchanged() && !interrupted;
  } catch (error) { result.failure = String(error); }
  fs.writeFileSync(stage + '/result.json', JSON.stringify(result, null, 2) + '\n', {flag: 'wx'});
  console.log(JSON.stringify({stage, mode, accepted: result.accepted, failure: result.failure || null}));
  process.exitCode = result.accepted ? 0 : 1;
})();
