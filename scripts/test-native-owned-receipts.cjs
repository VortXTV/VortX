'use strict';

// LOCAL existing-artifact lane. Never builds/downloads/installs an engine or SDK.
// Whole actual Facade/Session/Runtime/resource inputs; real native C module+lib.
// Runtime ABI/store/transport are the existing exact RAM Session fixture types.
const fs = require('node:fs'), path = require('node:path'), crypto = require('node:crypto');
const { fork, spawnSync } = require('node:child_process');
const root = path.resolve(__dirname, '..');
const captured = new Map(), copies = new Map(), dependencies = new Map(), generated = new Map();
let directory, active, interrupted = 0, phase = 'preflight', compile = 'not-run', runtime = 'not-run', scopeMode = 'unselected';
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
    if (!file.startsWith(root + path.sep)) fail('Source path escaped repository', 2);
    return file;
}
function capture(relative) {
    if (!captured.has(relative)) {
        const bytes = fs.readFileSync(ownPath(relative));
        captured.set(relative, bytes);
        copies.set(relative, write(`inputs/${relative}`, bytes));
    }
    return captured.get(relative);
}
function write(relative, bytes) {
    const file = path.join(directory, relative);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, bytes, { flag: 'wx' });
    return file;
}
function generate(relative, bytes) { const file = write(relative, bytes); generated.set(file, hash(fs.readFileSync(file))); return file; }
function verify(label) {
    for (const [relative, bytes] of captured) {
        if (hash(fs.readFileSync(ownPath(relative))) !== hash(bytes)
            || hash(fs.readFileSync(copies.get(relative))) !== hash(bytes)) fail(`Source/snapshot changed: ${relative}`, 3);
    }
    for (const [file, expected] of dependencies) {
        if (!fs.statSync(file).isFile() || hash(fs.readFileSync(file)) !== expected) fail(`Pinned dependency changed: ${file}`, 3);
    }
    for (const [file, expected] of generated) {
        if (hash(fs.readFileSync(file)) !== expected) fail(`Generated input changed: ${path.basename(file)}`, 3);
    }
    write(`${label}.json`, JSON.stringify({ sourceInputs: captured.size, dependencyFiles: dependencies.size,
        generatedFiles: generated.size, conserved: true }, null, 2) + '\n');
}
function declarationList(relative, name) {
    const lines = capture(relative).toString('utf8').split(/\r?\n/).map(line => line.trim()).filter(line => line && !line.startsWith('#'));
    if (lines.shift() !== `${name}=(` || lines.pop() !== ')') fail(`Unreviewed input array: ${relative}`, 2);
    const files = [], links = [];
    for (const line of lines) {
        if (/^app\/[A-Za-z0-9_/-]+\.swift$/.test(line) && !line.includes('..')) files.push(line);
        else if (line === '-lz') links.push(line);
        else fail(`Unreviewed array member in ${relative}`, 2);
    }
    if (!files.length || new Set(files).size !== files.length) fail(`Empty/duplicate array: ${relative}`, 2);
    return { files, links };
}
// Same live-anchor IPC protocol as the existing native-migration lane. The
// unchanged captured supervisor owns its group, deadlines, TERM/KILL and cleanup.
async function run(label, command, timeout, helper, cwd = directory, showLog = false) {
    if (interrupted || active) fail('Interrupted or overlapping owned stage', interrupted || 2);
    const nonce = crypto.randomBytes(16).toString('hex');
    const specification = { nonce, command, timeout, cwd,
        log: path.join(directory, `${label}.log`), result: path.join(directory, `${label}.supervisor-result.json`) };
    write(`${label}.command.json`, JSON.stringify({ command, timeout, cwd }, null, 2) + '\n');
    const controlLog = fs.openSync(path.join(directory, `${label}.supervisor.log`), 'wx');
    // No inherited loader injection, image suffix, alternate root or redirected
    // dyld log may bypass the explicit runtime library/path evidence below.
    const environment = Object.fromEntries(Object.entries(process.env)
        .filter(([key]) => !key.startsWith('DYLD_') && !key.startsWith('GIT_') && key !== 'NODE_OPTIONS'));
    environment.NODE_OPTIONS = '';
    environment.GIT_NO_LAZY_FETCH = '1';
    environment.GIT_NO_REPLACE_OBJECTS = '1';
    environment.GIT_CONFIG_NOSYSTEM = '1';
    environment.GIT_CONFIG_GLOBAL = '/dev/null';
    environment.GIT_CONFIG_SYSTEM = '/dev/null';
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
            if (message?.type !== 'ready') return;
            sendControl(anchor, interrupted ? { type: 'cancel', exit: interrupted } : { type: 'start', specification });
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
    if (showLog) process.stdout.write(fs.readFileSync(specification.log));
    if (result.exit !== 0) fail(`${label} failed; inspect retained ${label}.log`, result.exit);
    return fs.readFileSync(specification.log, 'utf8');
}
function options() {
    const result = { prepareOnly: false, typecheckOnly: false };
    for (let index = 2; index < process.argv.length; index++) {
        const argument = process.argv[index];
        if (argument === '--prepare-only' && !result.prepareOnly) result.prepareOnly = true;
        else if (argument === '--typecheck-only' && !result.typecheckOnly) result.typecheckOnly = true;
        else if (argument === '--sdk-manifest' && result.manifest === undefined) result.manifest = process.argv[++index];
        else if (argument === '--sdk-manifest-sha256' && result.manifestSHA === undefined) result.manifestSHA = process.argv[++index];
        else if (argument === '--header-manifest' && result.headerManifest === undefined) result.headerManifest = process.argv[++index];
        else if (argument === '--header-manifest-sha256' && result.headerManifestSHA === undefined) result.headerManifestSHA = process.argv[++index];
        else fail('Unknown, repeated or positional option', 2);
    }
    if (result.typecheckOnly) {
        if (result.manifest !== undefined || result.manifestSHA !== undefined
            || !path.isAbsolute(result.headerManifest || '') || !/^[a-f0-9]{64}$/.test(result.headerManifestSHA || ''))
            fail('Typecheck only requires --header-manifest absolutePath --header-manifest-sha256 trustedHash; no SDK binary options', 2);
    } else if (result.headerManifest !== undefined || result.headerManifestSHA !== undefined
        || !path.isAbsolute(result.manifest || '') || !/^[a-f0-9]{64}$/.test(result.manifestSHA || '')) {
        fail('Runtime requires --sdk-manifest absolutePath --sdk-manifest-sha256 trustedHash [--prepare-only]', 2);
    }
    return result;
}
function pinSDK(settings) {
    if (!fs.existsSync(settings.manifest) || !fs.statSync(settings.manifest).isFile()) fail('Explicit local SDK manifest is absent');
    const manifestBytes = fs.readFileSync(settings.manifest);
    if (hash(manifestBytes) !== settings.manifestSHA) fail('Explicit local SDK manifest does not match trusted SHA256');
    dependencies.set(settings.manifest, settings.manifestSHA);
    // Preserve EXACT trusted bytes, not only the parsed/reformatted policy.
    generate('sdk-manifest.input.json', manifestBytes);
    const policy = JSON.parse(manifestBytes);
    if (typeof policy.workspace !== 'string' || !path.isAbsolute(policy.workspace)
        || policy.workspace === path.parse(policy.workspace).root || !fs.statSync(policy.workspace).isDirectory())
        fail('Local manifest must declare a narrow absolute existing workspace boundary');
    const workspace = fs.realpathSync(policy.workspace);
    if (!fs.realpathSync(root).startsWith(workspace + path.sep)
        || !fs.realpathSync(settings.manifest).startsWith(workspace + path.sep))
        fail('Repository or local manifest lies outside the explicit workspace boundary');
    if (policy.schema !== 1 || policy.target !== 'aarch64-apple-darwin' || process.arch !== 'arm64')
        fail('Pinned existing SDK is arm64 macOS only; no substitute/build is permitted');
    for (const role of ['library', 'cacheHeader', 'header', 'moduleMap', 'provenance', 'sourceFreeze']) {
        const file = policy[role], expected = policy.sha256?.[role];
        if (typeof file !== 'string' || !path.isAbsolute(file) || !/^[a-f0-9]{64}$/.test(expected || ''))
            fail(`Invalid pinned SDK role: ${role}`);
        if (!fs.existsSync(file) || !fs.statSync(file).isFile()) fail(`Missing pinned existing SDK input: ${file}`);
        const real = fs.realpathSync(file);
        if (!real.startsWith(workspace + path.sep) || hash(fs.readFileSync(file)) !== expected)
            fail(`Existing SDK input/provenance hash mismatch: ${role}`);
        dependencies.set(file, expected);
    }
    const provenance = JSON.parse(fs.readFileSync(policy.provenance));
    if (provenance.privateCommit !== policy.privateCommit || provenance.build?.target !== policy.target
        || provenance.build?.exitCode !== 0 || provenance.files?.['libvortx_ffi.dylib'] !== policy.sha256.library
        || provenance.files?.['include/vortx_ffi.h'] !== policy.sha256.cacheHeader
        || provenance.independentReview?.sourceManifestSha256 !== policy.sha256.sourceFreeze
        || policy.sha256.header !== policy.sha256.cacheHeader)
        fail('Existing dylib/header/source-freeze provenance relationship changed');
    if (path.dirname(policy.header) !== path.dirname(policy.moduleMap)) fail('Existing module/header are not adjacent');
    const module = fs.readFileSync(policy.moduleMap, 'utf8');
    if (!/^module VortxEngine\s*\{\s*header "vortx_ffi\.h"\s*export \*\s*\}\s*$/.test(module))
        fail('Existing C module map changed; no generated SDK fallback');
    write('sdk-policy.json', JSON.stringify(policy, null, 2) + '\n');
    write('sdk-provenance.json', fs.readFileSync(policy.provenance));
    write('sdk-source-freeze.sha256', fs.readFileSync(policy.sourceFreeze));
    return policy;
}
// A separate source-interface/typecheck lane, NEVER an SDK or runtime fallback.
// The module map is integration metadata copied from the real app build script;
// every C declaration comes byte-for-byte from the real committed source header.
function pinCurrentHeader(settings) {
    if (!fs.existsSync(settings.headerManifest) || !fs.statSync(settings.headerManifest).isFile())
        fail('Explicit current-header manifest is absent');
    const manifest = fs.readFileSync(settings.headerManifest);
    if (hash(manifest) !== settings.headerManifestSHA) fail('Current-header manifest trusted hash mismatch');
    dependencies.set(settings.headerManifest, settings.headerManifestSHA);
    generate('header-manifest.input.json', manifest);
    const policy = JSON.parse(manifest);
    if (policy.schema !== 1 || policy.typecheckOnly !== true || typeof policy.workspace !== 'string'
        || !path.isAbsolute(policy.workspace) || policy.workspace === path.parse(policy.workspace).root
        || !fs.existsSync(policy.workspace) || !fs.statSync(policy.workspace).isDirectory())
        fail('Current-header manifest must declare a narrow existing workspace and typecheck-only scope');
    const workspace = fs.realpathSync(policy.workspace);
    for (const file of [root, settings.headerManifest, policy.sourceRepository, policy.header]) {
        if (typeof file !== 'string' || !path.isAbsolute(file) || !fs.existsSync(file)
            || !fs.realpathSync(file).startsWith(workspace + path.sep))
            fail('Current-header input lies outside trusted local workspace');
    }
    if (!/^[a-f0-9]{40}$/.test(policy.sourceCommit || '') || !/^[a-f0-9]{40}$/.test(policy.headerBlob || '')
        || !/^[a-f0-9]{64}$/.test(policy.headerSHA256 || '')
        || !/^[A-Za-z0-9_/-]+\.h$/.test(policy.headerRelative || '') || policy.headerRelative.includes('..')
        || fs.realpathSync(path.join(policy.sourceRepository, policy.headerRelative)) !== fs.realpathSync(policy.header))
        fail('Current-header source commit/blob/relative path identity is invalid');
    const header = fs.readFileSync(policy.header);
    const blob = crypto.createHash('sha1').update(Buffer.from(`blob ${header.length}\0`)).update(header).digest('hex');
    if (hash(header) !== policy.headerSHA256 || blob !== policy.headerBlob) fail('Current real header hash/blob mismatch');
    dependencies.set(policy.header, policy.headerSHA256);
    // Reject unclosed private include dependencies, rather than fabricate them.
    if (/^\s*#\s*include\s*"/m.test(header.toString('utf8'))) fail('Current header gained a relative include; pin that real dependency first');
    const map = policy.moduleMapTemplate;
    if (!map || typeof map.owner !== 'string' || !/^scripts\/[A-Za-z0-9_/-]+\.sh$/.test(map.owner)
        || map.owner.includes('..') || !/^[a-f0-9]{64}$/.test(map.sha256 || '') || typeof map.text !== 'string'
        || !/^module VortxEngine\s*\{\s*header "vortx_ffi\.h"\s*export \*\s*\}\s*$/.test(map.text))
        fail('Real module-map build-template identity is invalid');
    const owner = capture(map.owner);
    if (hash(owner) !== map.sha256 || !owner.toString('utf8').includes(map.text))
        fail('Module-map template does not match its pinned actual build script');
    const includeRoot = path.join(directory, 'generated/current-native-header');
    generate('generated/current-native-header/vortx_ffi.h', header);
    generate('generated/current-native-header/module.modulemap', map.text);
    write('current-header-policy.json', JSON.stringify(policy, null, 2) + '\n');
    return { ...policy, includeRoot };
}
async function main() {
    if (process.platform !== 'darwin') fail('This existing native artifact lane requires macOS', 2);
    const settings = options();
    scopeMode = settings.typecheckOnly ? 'typecheck-only' : 'runtime';
    fs.mkdirSync(path.join(root, 'app/build'), { recursive: true });
    directory = fs.mkdtempSync(path.join(root, 'app/build/native-owned-receipts.'));
    process.stdout.write(`Retained native owned-receipt lane: ${directory}\n`);
    write('invocation.json', JSON.stringify({ root, node: process.version, nodeExecutable: process.execPath,
        sdkManifest: settings.manifest, sdkManifestSHA256: settings.manifestSHA,
        typecheckOnly: settings.typecheckOnly, headerManifest: settings.headerManifest,
        headerManifestSHA256: settings.headerManifestSHA,
        prepareOnly: settings.prepareOnly }, null, 2) + '\n');
    ['scripts/test-native-owned-receipts.sh', 'scripts/test-native-owned-receipts.cjs',
        'scripts/native-migration-supervisor.cjs',
        'test/xperience-harness-inputs.cjs', 'app/Tests/VortxNativeOwnedReceiptTests.swift',
        'test/native-metadata-dispatch-inputs.cjs', 'app/Tests/VortxNativeMetadataDispatchTests.swift',
        'app/SourcesShared/CoreBridge.swift', 'scripts/extract-subtitle-proof-hosts.cjs', 'app/SourcesShared/PlaybackMutationOwnershipPolicy.swift',
        'app/SourcesShared/LegacyWatchOwnership.swift',
        'app/SourcesShared/BatchMetaSlotPolicy.swift',
        'app/Tests/VortxNativeSessionTests.swift', 'app/SourcesShared/Profiles.swift',
        'app/SourcesShared/ProfileDiscoveryPreferences.swift', 'app/SourcesShared/VortXSyncManager.swift'].forEach(capture);
    const sdk = settings.typecheckOnly ? pinCurrentHeader(settings) : pinSDK(settings);
    const watched = declarationList('scripts/native-watched-swift-inputs.sh', 'native_watched_swift_inputs');
    const history = declarationList('scripts/native-owner-history-fixture-inputs.sh', 'native_owner_history_fixture_swift_inputs');
    const sources = [...new Set(['app/SourcesShared/VortxNativeRuntime.swift', 'app/SourcesShared/VortxResourceBridge.swift',
        'app/SourcesShared/VortxResourceProjection.swift', 'app/SourcesShared/VortxNativeBootstrapArchive.swift',
        'app/SourcesShared/VortxNativeHostPreferences.swift', 'app/SourcesShared/VortxNativeSession.swift',
        'app/SourcesShared/VortxNativeCoreFacade.swift', 'app/SourcesShared/VortxNativePreviouslyWatched.swift',
        'app/SourcesShared/ProfileAddonPreferences.swift', 'app/SourcesShared/VortxProfileOverlayWitness.swift',
        'app/SourcesShared/PlaybackMutationOwnershipPolicy.swift', 'app/SourcesShared/BatchMetaSlotPolicy.swift',
        'app/SourcesShared/VortxNativeProfileEditHost.swift', ...watched.files, ...history.files])];
    sources.forEach(capture);
    const facade = capture('app/SourcesShared/VortxNativeCoreFacade.swift').toString('utf8');
    for (const marker of ['struct ChangeReceipt: Sendable {', 'func captureHostChange(', 'func acceptsChange(',
        'func dispatchMetadata(', 'func metadataSnapshot(', 'func metadataSelectionIsCurrent(']) {
        if (!facade.includes(marker)) fail(`Owned API prerequisite not placed: ${marker}`, 2);
    }
    // Load the captured helper, never a subsequently mutable original helper.
    const { extractDeclaration, ownerHistoryCarriers } = require(copies.get('test/xperience-harness-inputs.cjs'));
    const extracted = [];
    function exact(owner, signature) {
        const bytes = extractDeclaration(capture(owner).toString('utf8'), signature);
        extracted.push({ owner, ownerSHA256: hash(capture(owner)), signature, declarationSHA256: hash(Buffer.from(bytes)) });
        return bytes;
    }
    const { metadataDispatchPeer } = require(copies.get('test/native-metadata-dispatch-inputs.cjs'));
    const metadataPeer = metadataDispatchPeer(
        capture('app/SourcesShared/CoreBridge.swift').toString('utf8'),
        capture('app/SourcesShared/Profiles.swift').toString('utf8'),
        capture('app/SourcesShared/VortxNativeCoreFacade.swift').toString('utf8'),
        extractDeclaration);
    for (const item of metadataPeer.declarations) extracted.push({
        owner: item.owner, ownerSHA256: hash(capture(item.owner)), signature: item.signature,
        declarationSHA256: hash(Buffer.from(item.bytes))
    });
    const fixture = generate('generated/OwnedReceiptFixture.swift', 'import Foundation\nimport CryptoKit\nimport os\n\n'
        + ['private final class SessionABI:', 'private final class SessionStore:', 'private final class SessionTransport:']
            .map(marker => exact('app/Tests/VortxNativeSessionTests.swift', marker)).join('\n\n')
        + '\n\n' + metadataPeer.source
        + '\n\n' + capture('app/Tests/VortxNativeMetadataDispatchTests.swift').toString('utf8')
        + '\n\n' + capture('app/Tests/VortxNativeOwnedReceiptTests.swift').toString('utf8'));
    const profiles = generate('generated/UserProfile.swift', 'import Foundation\nimport CryptoKit\n'
        + exact('app/SourcesShared/Profiles.swift', 'struct UserProfile:'));
    const discovery = generate('generated/Discovery.swift', 'import Foundation\n'
        + exact('app/SourcesShared/ProfileDiscoveryPreferences.swift', 'struct ProfileDiscoveryPreferences:'));
    const carriers = ownerHistoryCarriers(capture('app/SourcesShared/VortXSyncManager.swift').toString('utf8'));
    const ownerCarriers = generate('generated/OwnerHistoryFixtureCarriers.swift', carriers.source);
    const proofHost = path.join(directory, 'generated/NativeSubtitleProofHosts.swift');
    fs.mkdirSync(path.dirname(proofHost), { recursive: true });
    const proofRun = spawnSync(process.execPath, [copies.get('scripts/extract-subtitle-proof-hosts.cjs'),
        root, 'bridge-extension', proofHost], { cwd: root, encoding: 'utf8' });
    if (proofRun.error || proofRun.status !== 0) fail('Actual subtitle proof extraction failed: ' + (proofRun.stderr || proofRun.error));
    const proofReceipt = JSON.parse(proofRun.stdout);
    generated.set(proofHost, hash(fs.readFileSync(proofHost)));
    for (const item of carriers.declarations) extracted.push({ owner: 'app/SourcesShared/VortXSyncManager.swift',
        ownerSHA256: hash(capture('app/SourcesShared/VortXSyncManager.swift')), signature: item.signature,
        declarationSHA256: hash(Buffer.from(item.bytes)) });
    write('extraction.json', JSON.stringify({ extracted, subtitleOwnerProofHosts: proofReceipt, declarationTransformations: [],
        metadataDispatch: { fullDispatchDeclaration: true,
            productionDeclarationTransformations: metadataPeer.declarationTransformations,
            shellOnly: metadataPeer.shellOnly, excluded: metadataPeer.excluded },
        scope: 'Whole actual Facade/FIFO/Session/Runtime/resource and exact extracted dispatch/helpers in RAM Bridge storage peer; genuine committed header or explicitly gated existing module/lib; no actual CoreBridge lifecycle/Manager/UI or native symbol mocks' }, null, 2) + '\n');
    write('inputs.json', JSON.stringify({ sources: [...captured].map(([file, bytes]) => ({ file, bytes: bytes.length, sha256: hash(bytes) })),
        dependencies: [...dependencies].map(([file, sha256]) => ({ file, sha256 })),
        generated: [...generated].map(([file, sha256]) => ({ file: path.relative(directory, file), sha256 })) }, null, 2) + '\n');
    verify('conservation-preflight');
    if (settings.prepareOnly) { phase = 'prepared-not-tested'; return; }
    const helper = copies.get('scripts/native-migration-supervisor.cjs');
    if (settings.typecheckOnly) {
        phase = 'current-header-provenance';
        // Read-only local object lookup, no fetch/build/index operation. Compare
        // the exact committed header bytes to the retained compiler header.
        await run('header-at-commit', ['/usr/bin/nice', '-n', '15', '/usr/bin/git', '--no-lazy-fetch',
            '--no-replace-objects', '-C', sdk.sourceRepository,
            'cat-file', 'blob', `${sdk.sourceCommit}:${sdk.headerRelative}`], 30_000, helper);
        if (hash(fs.readFileSync(path.join(directory, 'header-at-commit.log'))) !== sdk.headerSHA256)
            fail('Pinned commit does not contain the exact current real header');
        const sdkPath = (await run('typecheck-macos-sdk', ['/usr/bin/nice', '-n', '15', '/usr/bin/xcrun',
            '--sdk', 'macosx', '--show-sdk-path'], 30_000, helper)).trim();
        if (!path.isAbsolute(sdkPath) || /[\r\n]/.test(sdkPath) || !fs.statSync(sdkPath).isDirectory())
            fail('Actual macOS SDK unavailable for current-header typecheck');
        fs.mkdirSync(path.join(directory, 'module-cache'));
        verify('conservation-pretypecheck');
        phase = 'typecheck'; compile = 'typechecking';
        await run('typecheck', ['/usr/bin/nice', '-n', '15', '/usr/bin/xcrun', 'swiftc', '-typecheck',
            '-swift-version', '6', '-strict-concurrency=complete', '-warnings-as-errors', '-parse-as-library',
            '-whole-module-optimization', '-j', '1', '-num-threads', '1', '-sdk', sdkPath,
            '-target', 'arm64-apple-macosx14.0', '-module-cache-path', path.join(directory, 'module-cache'),
            '-I', sdk.includeRoot, '-D', 'VORTX_ENGINE_STATE_BRIDGE', '-D', 'VORTX_ENGINE_RESOURCE_HOST',
            '-D', 'VORTX_NATIVE_DATA_ENGINE', ...sources.map(file => copies.get(file)), fixture, profiles,
            discovery, ownerCarriers, proofHost], 600_000, helper, directory);
        compile = 'typecheck-normal0'; runtime = 'not-run'; phase = 'typecheck-complete';
        process.stdout.write('Whole actual Facade/Session/FIFO strict6 typecheck completed with real committed header; NO link/runtime/SDK/app/Manager-adapter proof\n');
        return;
    }
    phase = 'native-preflight';
    const arch = await run('native-architecture', ['/usr/bin/nice', '-n', '15', '/usr/bin/file', '-b', sdk.library], 30_000, helper);
    if (!arch.includes('Mach-O') || !arch.includes('arm64') || arch.includes('x86_64')) fail('Existing library architecture does not match pinned arm64 host');
    const exports = await run('native-exports', ['/usr/bin/nice', '-n', '15', '/usr/bin/nm', '-gU', sdk.library], 30_000, helper);
    const required = ['vortx_init_runtime', 'vortx_init_from_state_json', 'vortx_dispatch_json', 'vortx_resolve_json',
        'vortx_get_state_json', 'vortx_get_state_delta_json', 'vortx_string_free', 'vortx_engine_free',
        'vortx_resource_host_abi_version', 'vortx_resource_host_new', 'vortx_resource_host_load_json', 'vortx_resource_host_free',
        'vortx_cancel_new', 'vortx_cancel_cancel', 'vortx_cancel_free', 'vortx_owner_history_canonicalize_evidence_json',
        'vortx_owner_history_session_open', 'vortx_owner_history_session_fork', 'vortx_owner_history_session_json', 'vortx_owner_history_session_free'];
    const exported = new Set(exports.split(/\r?\n/).map(line => line.trim().split(/\s+/).pop()));
    const missing = required.filter(symbol => !exported.has(`_${symbol}`));
    write('required-native-symbols.json', JSON.stringify({ required, missing, allPresent: !missing.length }, null, 2) + '\n');
    if (missing.length) fail(`Existing genuine library lacks required current ABI: ${missing.join(', ')}; no build or fake-symbol fallback`);
    const install = await run('native-install-name', ['/usr/bin/nice', '-n', '15', '/usr/bin/otool', '-D', sdk.library], 30_000, helper);
    const installName = install.split(/\r?\n/).slice(1).map(line => line.trim()).filter(Boolean);
    if (installName.length !== 1 || ![sdk.library, '@rpath/libvortx_ffi.dylib', 'libvortx_ffi.dylib'].includes(installName[0]))
        fail('Existing dylib install name is not pinned/resolvable without mutation; no install_name_tool or alternate library permitted');
    const loader = await run('native-loader-dependencies', ['/usr/bin/nice', '-n', '15', '/usr/bin/otool', '-L', sdk.library], 30_000, helper);
    const loaderPaths = loader.split(/\r?\n/).slice(1).map(line => line.trim()).filter(Boolean)
        .map(line => line.split(/\s+\(compatibility version /)[0]);
    const unpinnedLoaderPaths = loaderPaths.filter(file => file !== installName[0]
        && !file.startsWith('/usr/lib/') && !file.startsWith('/System/Library/'));
    write('native-loader-policy.json', JSON.stringify({ installName: installName[0], loaderPaths,
        unpinnedLoaderPaths, systemOnlyApartFromPinnedLibrary: !unpinnedLoaderPaths.length }, null, 2) + '\n');
    if (unpinnedLoaderPaths.length) fail('Existing native library has unpinned non-system dependencies; no loader fallback');
    const sdkPath = (await run('macos-sdk', ['/usr/bin/nice', '-n', '15', '/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-path'], 30_000, helper)).trim();
    if (!path.isAbsolute(sdkPath) || /[\r\n]/.test(sdkPath) || !fs.statSync(sdkPath).isDirectory()) fail('Actual macOS SDK unavailable');
    const inputs = [...sources.map(file => copies.get(file)), fixture, profiles, discovery, ownerCarriers, proofHost];
    const executable = path.join(directory, 'native-owned-receipts');
    fs.mkdirSync(path.join(directory, 'module-cache'));
    const libraryDirectory = path.dirname(sdk.library);
    verify('conservation-precompile');
    phase = 'compile'; compile = 'running';
    await run('compile', ['/usr/bin/nice', '-n', '15', '/usr/bin/xcrun', 'swiftc', '-swift-version', '6',
        '-strict-concurrency=complete', '-warnings-as-errors', '-whole-module-optimization', '-parse-as-library',
        '-j', '1', '-num-threads', '1', '-sdk', sdkPath, '-target', 'arm64-apple-macosx14.0',
        '-module-cache-path', path.join(directory, 'module-cache'), '-I', path.dirname(sdk.moduleMap),
        '-D', 'VORTX_ENGINE_STATE_BRIDGE', '-D', 'VORTX_ENGINE_RESOURCE_HOST', '-D', 'VORTX_NATIVE_DATA_ENGINE',
        ...inputs, ...new Set([...watched.links, ...history.links]), sdk.library,
        '-framework', 'Security', '-framework', 'SystemConfiguration', '-Xlinker', '-rpath', '-Xlinker', libraryDirectory,
        '-o', executable], 600_000, helper, directory);
    compile = 'normal0';
    write('executable.sha256', `${hash(fs.readFileSync(executable))}  native-owned-receipts\n`);
    verify('conservation-preruntime');
    phase = 'runtime'; runtime = 'running';
    const log = await run('runtime', ['/usr/bin/nice', '-n', '15', '/usr/bin/env', 'DYLD_INSERT_LIBRARIES=',
        `DYLD_LIBRARY_PATH=${libraryDirectory}`, 'DYLD_FALLBACK_LIBRARY_PATH=', 'DYLD_FRAMEWORK_PATH=', 'DYLD_PRINT_LIBRARIES=1',
        executable], 120_000, helper, directory);
    if (!/Native owned receipts: [1-9][0-9]* checks PASS;/.test(log)) fail('Runtime lacks explicit completed assertion receipt', 1);
    if (!/Native metadata dispatch: [1-9][0-9]* checks PASS;/.test(log))
        fail('Runtime lacks explicit completed metadata-dispatch assertion receipt', 1);
    const nativeLoads = log.split(/\r?\n/).filter(line => line.startsWith('dyld[') && line.includes('libvortx_ffi.dylib'));
    const loadedPaths = nativeLoads.map(line => /^dyld\[[0-9]+\]:\s+(?:<[^>\r\n]+>\s+)?(\/[^\r\n]+)$/.exec(line)?.[1]);
    const pinnedRealPath = fs.realpathSync(sdk.library);
    if (!loadedPaths.length || loadedPaths.some(file => !file || !fs.existsSync(file)
        || fs.realpathSync(file) !== pinnedRealPath || hash(fs.readFileSync(file)) !== sdk.sha256.library))
        fail('Runtime did not prove exact canonical path/hash of the pinned native dylib; no alternate accepted', 1);
    write('loaded-native-library.json', JSON.stringify({ observedPaths: loadedPaths, canonicalPath: pinnedRealPath, path: sdk.library,
        sha256: hash(fs.readFileSync(sdk.library)), pinned: true }, null, 2) + '\n');
    runtime = 'normal0'; phase = 'complete';
    process.stdout.write(log.split(/\r?\n/).filter(line => line.startsWith('Native owned receipts:')
        || line.startsWith('Native metadata dispatch:')).join('\n') + '\n');
}
(async () => {
    let status = 0;
    try { await main(); }
    catch (error) { status = interrupted || error.exitCode || 1; process.stderr.write(`${error.message}\n`); }
    finally {
        if (directory) {
            try { verify('conservation-final'); } catch (error) { status = interrupted || 3; process.stderr.write(`${error.message}\n`); }
            write('final-inputs.json', JSON.stringify({ sources: [...captured].map(([file, bytes]) => ({ file, sha256: hash(bytes) })),
                dependencies: [...dependencies].map(([file, sha256]) => ({ file, sha256 })),
                generated: [...generated].map(([file, sha256]) => ({ file: path.relative(directory, file), sha256 })) }, null, 2) + '\n');
            write('result.json', JSON.stringify({ exit: status, phase, compile, runtime, interrupted,
                mode: scopeMode, scope: scopeMode === 'typecheck-only'
                    ? 'Whole current Facade/Session/FIFO typecheck with exact committed C header and actual modulemap template; NO linking/runtime/SDK/Manager-adapter/whole-app proof'
                    : 'Whole current Facade/Session/FIFO + genuine pinned native module/link; RAM synthetic ABI/store/transport; no native C execution, UI/actor, SDK build or full-app proof' }, null, 2) + '\n');
            process.stdout.write(`Retained result: ${directory}/result.json\n`);
        }
        process.exitCode = interrupted || status;
    }
})();
