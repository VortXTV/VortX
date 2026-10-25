'use strict';

// SDK-FREE pure declaration lane. No Facade, Session, native module/library,
// engine symbol, account, app or device is compiled or invoked by this runner.
// RECOVERY PROPOSAL ONLY; no Node/extraction/compiler/test job has run here.
const fs = require('node:fs'), path = require('node:path'), crypto = require('node:crypto');
const { fork } = require('node:child_process');
const root = path.resolve(__dirname, '..');
const captured = new Map(), copies = new Map(), generated = new Map();
let directory, active, interrupted = 0, phase = 'preflight', compile = 'not-run', runtime = 'not-run';
const hash = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
function fail(message, code = 78) { const error = new Error(message); error.exitCode = code; throw error; }
function sendControl(child, message) {
    if (!child?.connected) return;
    try { child.send(message, error => { if (error && child.connected) child.disconnect(); }); }
    catch { if (child.connected) child.disconnect(); }
}
function interrupt(code) { interrupted = code; process.exitCode = code; sendControl(active, { type: 'cancel', exit: code }); }
process.on('SIGINT', () => interrupt(130));
process.on('SIGTERM', () => interrupt(143));
function ownPath(relative) {
    const file = path.resolve(root, relative);
    if (!file.startsWith(root + path.sep) || !fs.realpathSync(file).startsWith(fs.realpathSync(root) + path.sep))
        fail('Input escaped the actual repository', 2);
    return file;
}
function write(relative, bytes) {
    const file = path.join(directory, relative);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, bytes, { flag: 'wx' });
    return file;
}
function capture(relative) {
    if (!captured.has(relative)) {
        const bytes = fs.readFileSync(ownPath(relative));
        captured.set(relative, bytes); copies.set(relative, write(`inputs/${relative}`, bytes));
    }
    return captured.get(relative);
}
function generate(relative, bytes) {
    const file = write(relative, bytes); generated.set(file, hash(fs.readFileSync(file))); return file;
}
function verify(label) {
    for (const [relative, bytes] of captured) {
        if (hash(fs.readFileSync(ownPath(relative))) !== hash(bytes)
            || hash(fs.readFileSync(copies.get(relative))) !== hash(bytes)) fail(`Source/snapshot changed: ${relative}`, 3);
    }
    for (const [file, expected] of generated) {
        if (hash(fs.readFileSync(file)) !== expected) fail(`Generated input changed: ${path.basename(file)}`, 3);
    }
    write(`${label}.json`, JSON.stringify({ sourceInputs: captured.size, dependencyFiles: 0,
        generatedFiles: generated.size, conserved: true }, null, 2) + '\n');
}

// Exact existing native-migration live-anchor protocol. The captured physical
// supervisor, not this driver, owns deadlines, process group and TERM/KILL cleanup.
async function run(label, command, timeout, helper) {
    if (interrupted || active) fail('Interrupted or overlapping owned stage', interrupted || 2);
    const nonce = crypto.randomBytes(16).toString('hex');
    const specification = { nonce, command, timeout, cwd: directory,
        log: path.join(directory, `${label}.log`), result: path.join(directory, `${label}.supervisor-result.json`) };
    write(`${label}.command.json`, JSON.stringify({ command, timeout, cwd: directory }, null, 2) + '\n');
    const controlLog = fs.openSync(path.join(directory, `${label}.supervisor.log`), 'wx');
    const environment = Object.fromEntries(Object.entries(process.env)
        .filter(([key]) => !key.startsWith('DYLD_') && !key.startsWith('GIT_') && key !== 'NODE_OPTIONS'));
    environment.NODE_OPTIONS = ''; environment.GIT_NO_LAZY_FETCH = '1'; environment.GIT_NO_REPLACE_OBJECTS = '1';
    environment.GIT_CONFIG_NOSYSTEM = '1'; environment.GIT_CONFIG_GLOBAL = '/dev/null'; environment.GIT_CONFIG_SYSTEM = '/dev/null';
    let anchor;
    try {
        anchor = fork(helper, [], { cwd: root, detached: true, execArgv: [], env: environment,
            stdio: ['ignore', controlLog, controlLog, 'ipc'] });
        active = anchor;
    } finally { fs.closeSync(controlLog); }
    let spawnFailure;
    await new Promise(resolve => {
        anchor.once('error', error => { spawnFailure = error; });
        anchor.on('message', message => {
            if (message?.type === 'ready') sendControl(anchor, interrupted
                ? { type: 'cancel', exit: interrupted } : { type: 'start', specification });
        });
        anchor.once('close', (code, signal) => {
            active = undefined;
            write(`${label}.anchor-exit.json`, JSON.stringify({ code, signal }) + '\n');
            if (signal !== 'SIGKILL' && !spawnFailure) spawnFailure = new Error('Anchor exited outside owned cleanup');
            resolve();
        });
    });
    if (interrupted) fail('Interrupted; owned anchor cleanup finished', interrupted);
    if (spawnFailure) throw spawnFailure;
    const result = JSON.parse(fs.readFileSync(specification.result, 'utf8'));
    if (result.nonce !== nonce || !Number.isInteger(result.exit) || result.reason !== 'command-exit')
        fail(`Invalid/abnormal supervised result: ${label}`, result.exit || 1);
    write(`${label}.exit`, `${result.exit}\n`);
    if (result.exit !== 0) fail(`${label} failed; inspect retained ${label}.log`, result.exit);
    return fs.readFileSync(specification.log, 'utf8');
}

async function main() {
    if (process.platform !== 'darwin' || process.arch !== 'arm64') fail('This pure lane is arm64 macOS only', 2);
    const args = process.argv.slice(2);
    if (args.some(arg => !['--prepare-only', '--typecheck-only'].includes(arg)) || new Set(args).size !== args.length)
        fail('Only distinct --prepare-only / --typecheck-only options are supported', 2);
    fs.mkdirSync(path.join(root, 'app/build'), { recursive: true });
    directory = fs.mkdtempSync(path.join(root, 'app/build/native-admission-primitives.'));
    process.stdout.write(`Retained SDK-free admission primitive lane: ${directory}\n`);
    write('invocation.json', JSON.stringify({ root, node: process.version, nodeExecutable: process.execPath,
        prepareOnly: args.includes('--prepare-only'), typecheckOnly: args.includes('--typecheck-only'),
        nativeSDK: false, scope: 'Exact production F/W declarations + disclosed RAM surroundings only' }, null, 2) + '\n');
    ['scripts/test-native-admission-primitives.cjs', 'scripts/native-migration-supervisor.cjs',
        'test/xperience-harness-inputs.cjs', 'test/native-admission-primitive-inputs.cjs',
        'app/SourcesShared/VortxNativeCoreFacade.swift', 'app/Tests/VortxNativeAdmissionPrimitiveTests.swift'].forEach(capture);
    const { extractDeclaration } = require(copies.get('test/xperience-harness-inputs.cjs'));
    const { admissionPrimitivePeer } = require(copies.get('test/native-admission-primitive-inputs.cjs'));
    const peer = admissionPrimitivePeer(capture('app/SourcesShared/VortxNativeCoreFacade.swift').toString('utf8'), extractDeclaration);
    const fixture = generate('generated/NativeAdmissionPrimitiveFixture.swift', peer.source + '\n\n'
        + capture('app/Tests/VortxNativeAdmissionPrimitiveTests.swift').toString('utf8')
        + '\n\n@main enum AdmissionPrimitiveMain { static func main() async { _ = await VortxNativeAdmissionPrimitiveTests.run() } }\n');
    write('extraction.json', JSON.stringify({ extracted: peer.declarations.map(item => ({ owner: item.owner,
        ownerSHA256: hash(capture(item.owner)), signature: item.signature, declarationSHA256: hash(Buffer.from(item.bytes)) })),
        validationOnly: peer.validationOnly.map(item => ({ owner: item.owner, ownerSHA256: hash(capture(item.owner)),
            signature: item.signature, declarationSHA256: item.sha256, emitted: false })),
        declarationTransformations: peer.declarationTransformations, sourceOnly: peer.sourceOnly,
        syntheticOnly: peer.syntheticOnly, excluded: peer.excluded,
        compilerInputs: ['generated/NativeAdmissionPrimitiveFixture.swift'], nativeSDK: false }, null, 2) + '\n');
    write('inputs.json', JSON.stringify({ sources: [...captured].map(([file, bytes]) => ({ file, bytes: bytes.length, sha256: hash(bytes) })),
        dependencies: [], generated: [...generated].map(([file, sha256]) => ({ file: path.relative(directory, file), sha256 })) }, null, 2) + '\n');
    verify('conservation-preflight');
    if (args.includes('--prepare-only')) { phase = 'prepared-not-tested'; return; }
    const helper = copies.get('scripts/native-migration-supervisor.cjs');
    phase = 'macos-sdk';
    const sdkPath = (await run('macos-sdk', ['/usr/bin/nice', '-n', '15', '/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-path'], 30_000, helper)).trim();
    if (!path.isAbsolute(sdkPath) || /[\r\n]/.test(sdkPath) || !fs.statSync(sdkPath).isDirectory()) fail('Actual macOS SDK unavailable');
    fs.mkdirSync(path.join(directory, 'module-cache'));
    const executable = path.join(directory, 'native-admission-primitives');
    const checking = args.includes('--typecheck-only');
    verify('conservation-precompile'); phase = checking ? 'typecheck' : 'compile'; compile = 'running';
    await run(phase, ['/usr/bin/nice', '-n', '15', '/usr/bin/xcrun', 'swiftc',
        ...(checking ? ['-typecheck'] : []), '-swift-version', '6', '-strict-concurrency=complete', '-warnings-as-errors',
        '-whole-module-optimization', '-parse-as-library', '-j', '1', '-num-threads', '1', '-sdk', sdkPath,
        '-target', 'arm64-apple-macosx14.0', '-module-cache-path', path.join(directory, 'module-cache'), fixture,
        ...(checking ? [] : ['-o', executable])], 120_000, helper);
    compile = checking ? 'typecheck-normal0' : 'normal0';
    if (checking) { phase = 'typecheck-complete'; return; }
    generated.set(executable, hash(fs.readFileSync(executable)));
    write('executable.sha256', `${generated.get(executable)}  native-admission-primitives\n`);
    verify('conservation-preruntime'); phase = 'runtime'; runtime = 'running';
    const log = await run('runtime', ['/usr/bin/nice', '-n', '15', executable], 30_000, helper);
    if (!/^Native admission primitives v3: [1-9][0-9]* checks PASS;/m.test(log)) fail('Missing explicit primitive assertion receipt', 1);
    runtime = 'normal0'; phase = 'complete';
    process.stdout.write(log.split(/\r?\n/).filter(line => line.startsWith('Native admission primitives v3:')).join('\n') + '\n');
}
(async () => {
    let status = 0;
    try { await main(); }
    catch (error) { status = interrupted || error.exitCode || 1; process.stderr.write(`${error.message}\n`); }
    finally {
        if (directory) {
            try { verify('conservation-final'); } catch (error) { status = interrupted || 3; process.stderr.write(`${error.message}\n`); }
            write('final-inputs.json', JSON.stringify({ sources: [...captured].map(([file, bytes]) => ({ file, sha256: hash(bytes) })),
                dependencies: [], generated: [...generated].map(([file, sha256]) => ({ file: path.relative(directory, file), sha256 })) }, null, 2) + '\n');
            write('result.json', JSON.stringify({ exit: status, phase, compile, runtime, interrupted, nativeSDK: false,
                scope: 'Exact production F/W declarations and explicit RAM B/M/task surroundings; no production dispatch/begin/Session/native C/receiver/app proof' }, null, 2) + '\n');
            process.stdout.write(`Retained primitive result: ${directory}/result.json\n`);
        }
        process.exitCode = interrupted || status;
    }
})();
