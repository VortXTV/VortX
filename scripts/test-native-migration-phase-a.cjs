'use strict';

// Source-unit harness only: one explicitly selected stage, no app/SDK/dependency
// build, and no packaged engine. Source copies below are retained compiler-input
// evidence, not a checkout/worktree (no Git metadata or workspace mutation).
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { fork } = require('node:child_process');
const xperienceInputs = require('../test/xperience-harness-inputs.cjs');
const { extractDeclaration } = xperienceInputs;
const root = path.resolve(__dirname, '..');
let interrupted = 0;
let active;
let directory;
const captured = new Map();

function sendControl(child, message) {
    if (!child?.connected) return;
    try {
        child.send(message, error => {
            if (error && child.connected) child.disconnect();
        });
    } catch {
        if (child.connected) child.disconnect();
    }
}
function interrupt(code) {
    interrupted = code;
    process.exitCode = code;
    sendControl(active, { type: 'cancel', exit: code });
}
// Handlers exist before any fork. JavaScript callback execution cannot interrupt
// the synchronous fork/handle assignment; ready/start also checks the cancel flag.
process.on('SIGINT', () => interrupt(130));
process.on('SIGTERM', () => interrupt(143));

function digest(bytes) { return crypto.createHash('sha256').update(bytes).digest('hex'); }
function sourcePath(relative) {
    const resolved = path.resolve(root, relative);
    if (!resolved.startsWith(root + path.sep)) throw new Error('Input escaped the repository');
    return resolved;
}
function capture(relative) {
    if (!captured.has(relative)) captured.set(relative, fs.readFileSync(sourcePath(relative)));
    return captured.get(relative);
}
function write(relative, contents) {
    const target = path.join(directory, relative);
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.writeFileSync(target, contents, { flag: 'wx' });
    return target;
}
function sourceManifest(current = false) {
    return [...captured.keys()].sort().map(file => {
        const bytes = current ? fs.readFileSync(sourcePath(file)) : captured.get(file);
        return `${digest(bytes)}  ${file}\n`;
    }).join('');
}
function verifySources(label) {
    const current = sourceManifest(true);
    write(`${label}.sha256`, current);
    if (current !== sourceManifest()) throw new Error(`Owning source changed at ${label}`);
}
function sharedInputs() {
    // Parse only the current explicit data-only shell array. Do not execute or
    // source a mutable script before pinning its owning bytes.
    const lines = capture('scripts/native-watched-swift-inputs.sh').toString('utf8').split(/\r?\n/)
        .map(line => line.trim()).filter(line => line && !line.startsWith('#'));
    if (lines.shift() !== 'native_watched_swift_inputs=(' || lines.pop() !== ')') {
        throw new Error('Unreviewed shared-input declaration');
    }
    const sources = [], links = [];
    for (const line of lines) {
        if (/^app\/[A-Za-z0-9_/-]+\.swift$/.test(line) && !line.includes('..')) sources.push(line);
        else if (line === '-lz') links.push(line);
        else throw new Error('Unreviewed shared compiler input');
    }
    return { sources, links };
}
function publicationConsumers() {
    const fixture = capture('app/Tests/CoreBridgePublicationFenceContractTests.swift').toString('utf8');
    const declaration = /^private func source\(_ relativePath: String\) -> String \{$/gm;
    if ([...fixture.matchAll(declaration)].length !== 1) throw new Error('Publication source reader changed');
    const body = fixture.replace(declaration, '');
    const literal = /\bsource\s*\(\s*"([^"\r\n]*)"\s*\)/g;
    const consumers = [...body.matchAll(literal)].map(match => match[1]);
    // This exact fixture uses literal source() reads only. Fail closed if a new
    // dynamic/multiform call appears rather than inspecting an uncaptured owner.
    if (!consumers.length || /\bsource\s*\(/.test(body.replace(literal, ''))) {
        throw new Error('Uncaptured publication source consumer');
    }
    return [...new Set(consumers)].map(relative => {
        if (!/^Sources[A-Za-z]*\/[A-Za-z0-9_/-]+\.swift$/.test(relative) || relative.includes('..')) {
            throw new Error('Unreviewed publication source path');
        }
        return `app/${relative}`;
    });
}
function extractSettingsBackupEncoder() {
    // Compile the owning pure serializer, not a lookalike test envelope. No defaults,
    // restore hooks, Keychain, app model, or UI dependency is included in this fixture.
    const bytes = captured.get('app/SourcesShared/SettingsBackup.swift').toString('utf8');
    function one(expression, label) {
        const matches = [...bytes.matchAll(expression)];
        if (matches.length !== 1) throw new Error(`Settings backup ${label} extraction boundary changed`);
        return matches[0][0];
    }
    const schema = one(/^    static let schema = .+$/gm, 'schema');
    const format = one(/^    static let formatTag = .+$/gm, 'format');
    const envelope = one(/^    struct Envelope: Codable \{[\s\S]*?^    \}/gm, 'envelope');
    const encode = one(/^    static func encode\(domain: \[String: Any\][\s\S]*?^    \}/gm, 'encode');
    return `import Foundation\nenum SettingsBackup {\n${schema}\n${format}\n${envelope}\n${encode}\n}\n`;
}
function extractProfile() {
    const bytes = captured.get('app/SourcesShared/Profiles.swift').toString('utf8');
    const marker = /^\/\/\/ The profile roster and the active selection\./m.exec(bytes);
    if (!marker) throw new Error('Profile extraction boundary missing');
    return bytes.slice(0, marker.index);
}
function extractDiscovery() {
    const bytes = captured.get('app/SourcesShared/ProfileDiscoveryPreferences.swift').toString('utf8');
    const matches = [...bytes.matchAll(/^struct ProfileDiscoveryPreferences: [\s\S]*?^}\r?$/gm)];
    if (matches.length !== 1) throw new Error('Discovery extraction boundary changed');
    return `import Foundation\n${matches[0][0]}\n`;
}

function extractTraktNextInputs() {
    // Same exact session-prefix and formatter-donor policy as the existing watched runner.
    // No OAuth/Keychain runtime, whole CoreModels graph, formatter rewrite or source stub.
    const policy = captured.get('app/SourcesShared/TraktScrobbleProgressPolicy.swift').toString('utf8');
    const marker = '/// FIFO for Trakt';
    const end = policy.indexOf(marker);
    if (end < 0 || policy.indexOf(marker, end + marker.length) >= 0) throw new Error('Trakt session boundary changed');
    const boundary = policy.slice(0, end);
    if ([...boundary.matchAll(/^struct TraktSessionID:/gm)].length !== 1
        || [...boundary.matchAll(/^enum TraktAuthBoundary/gm)].length !== 1) throw new Error('Trakt session declarations changed');
    const actual = extractDeclaration(captured.get('app/SourcesShared/CoreModels.swift').toString('utf8'),
        'extension ISO8601DateFormatter {') + '\n';
    const donor = extractDeclaration(captured.get('app/Tests/TraktOAuthBrokerContractTests.swift').toString('utf8'),
        'extension ISO8601DateFormatter {') + '\n';
    const formatter = 'import Foundation\n\n' + donor;
    const recipe = captured.get('scripts/test-trakt-watched-snapshot.sh').toString('utf8');
    const expected = [
        ['CoreModelsEPGFormatter.actual.swift', actual, '5002dda6ea34769312bc0d85566f13a28595e9f011c818aa380987277d540a93'],
        ['TraktEPGFormatter.donor.swift', donor, '6de164e822df8c8feebf9ac67d2d2ceeb6f6fceac414401ed8fb735afbe5d38a'],
        ['TraktEPGFormatter.swift', formatter, 'ee82aaf6c2f5758e3efa73ad1141ba85eeb57feb3179b95c54a6a7dd706506bb']
    ];
    for (const [name, bytes, sha256] of expected) {
        if (digest(Buffer.from(bytes)) !== sha256 || !recipe.includes(sha256)) throw new Error('Original Trakt formatter policy changed: ' + name);
        write('generated/' + name, bytes);
    }
    write('trakt-next-extraction.json', JSON.stringify({
        sessionOwner: 'app/SourcesShared/TraktScrobbleProgressPolicy.swift',
        sessionOwnerSHA256: digest(captured.get('app/SourcesShared/TraktScrobbleProgressPolicy.swift')),
        sessionBoundarySHA256: digest(Buffer.from(boundary)),
        formatterPolicyOwner: 'scripts/test-trakt-watched-snapshot.sh',
        formatterPolicySHA256: digest(captured.get('scripts/test-trakt-watched-snapshot.sh')),
        formatterArtifacts: expected.map(([name, , sha256]) => ({ name, sha256 })),
        declarationTransformations: [], excludes: ['OAuth/transport/persistence', 'CoreModels shared-formatter cache concurrency', 'Home/SwiftUI/native adapter']
    }, null, 2) + '\n');
    return [write('generated/TraktSessionBoundary.swift', boundary),
        path.join(directory, 'generated/TraktEPGFormatter.swift')];
}

function extractRestoreAdmission() {
    const manager = captured.get('app/SourcesShared/VortXSyncManager.swift').toString('utf8');
    const observation = xperienceInputs.observationProperty(manager);
    const keychain = captured.get('app/SourcesShared/Keychain.swift').toString('utf8');
    const credential = captured.get('app/SourcesShared/CredentialScope.swift').toString('utf8');
    const methods = [
        '    private func nativeBackupHistory(', '    private func rememberNativeBackup(',
        '    private func nativeEmptyAccountDocument(', '    private enum NativeRestoreAdmissionFailure:',
        '    private struct NativeRestoreDocument {', '    private func nativeRestoreDocument(',
        '    private enum VersionedPull {', '    private func pullDocVersionedResult('
    ].map(signature => ({ signature, bytes: extractDeclaration(manager, signature) }));
    const propertiesStart = manager.indexOf('    private static let nativeObservedBackupAccountLimit =');
    const propertiesEnd = manager.indexOf('    private func nativeBackupHistory(', propertiesStart);
    if (propertiesStart < 0 || propertiesEnd <= propertiesStart) throw new Error('Missing denial-floor properties');
    const properties = manager.slice(propertiesStart, propertiesEnd);
    const secure = [extractDeclaration(credential, 'enum CredentialMutationResult:'),
        extractDeclaration(credential, 'enum CredentialDurableReadResult:'),
        extractDeclaration(keychain, 'final class KeychainFailureClosedStore:')].join('\n\n');
    const template = captured.get('app/Tests/NativeRestoreAdmissionTests.swift').toString('utf8');
    for (const marker of ['/* PRODUCTION_SECURE_BOUNDARY */', '/* PRODUCTION_DECLARATIONS */']) {
        if (template.split(marker).length !== 2) throw new Error('Ambiguous fixture insertion');
    }
    write('restore-extraction.json', JSON.stringify({
        methods: methods.map(({signature, bytes}) => ({ signature, sha256: digest(Buffer.from(bytes)) })),
        propertiesSHA256: digest(Buffer.from(properties)), secureBoundarySHA256: digest(Buffer.from(secure)),
        observationPropertySHA256: observation ? digest(Buffer.from(observation)) : null,
        methodTransformations: [],
        apertures: ['inert encrypted-store/key/storage', 'fake secure backend', 'HTTP/crypto', 'roster decoder', 'detached seed'],
        exclusions: ['full native mount', 'OS Keychain/entitlements', 'device login', 'HTTP absence contract']
    }, null, 2) + '\n');
    // Outer-task diagnostics are source wiring checks, not a second implemented restore algorithm.
    const restore = extractDeclaration(manager, '    func restoreNativeCheckpoint(');
    for (const required of ['restore result=joined reason=in_flight', 'restore result=joined_complete',
        'restore result=not_started reason=backoff', 'restore result=not_started reason=superseded',
        'stage=offline_restore reason=checkpoint_unavailable', 'self.nativeRestoreDocument(pulled,',
        'self.nativeCheckpointGeneration == generation', 'failure.stage', 'failure.rawValue']) {
        if (!restore.includes(required)) throw new Error('Missing restore outcome wiring: ' + required);
    }
    if (restore.includes('try? self.nativeEmptyAccountDocument') || restore.includes('try? await self.publishDetachedNativeSeed')) {
        throw new Error('Silent empty-seed error folding returned');
    }
    return template.replace('/* PRODUCTION_SECURE_BOUNDARY */', secure)
        .replace('/* PRODUCTION_DECLARATIONS */', observation + '\n' + properties + '\n' + methods.map(item => item.bytes).join('\n\n'));
}

async function run(label, command, timeout, helper, cwd = root) {
    if (interrupted) throw new Error('Interrupted before stage launch');
    if (active) throw new Error('Another owned command is active');
    const nonce = crypto.randomBytes(16).toString('hex');
    const specification = {
        nonce, command, timeout, cwd,
        log: path.join(directory, `${label}.log`), result: path.join(directory, `${label}.supervisor-result.json`)
    };
    write(`${label}.command.json`, JSON.stringify({ command, timeout, cwd }, null, 2) + '\n');
    const controlLog = fs.openSync(path.join(directory, `${label}.supervisor.log`), 'wx');
    let anchor;
    try {
        // This is the sole location establishing group ownership. The parent never
        // signals a PID/group; the live anchor owns all command/deadline cleanup.
        anchor = fork(helper, [], {
            cwd: root, detached: true, execArgv: [], env: { ...process.env, NODE_OPTIONS: '' },
            stdio: ['ignore', controlLog, controlLog, 'ipc']
        });
        active = anchor;
    } finally {
        fs.closeSync(controlLog);
    }
    let spawnFailure;
    await new Promise(resolve => {
        anchor.once('error', error => { spawnFailure = error; });
        anchor.on('message', message => {
            if (message?.type !== 'ready') return;
            if (interrupted) sendControl(anchor, { type: 'cancel', exit: interrupted });
            else sendControl(anchor, { type: 'start', specification });
        });
        anchor.once('close', (code, signal) => {
            active = undefined;
            write(`${label}.anchor-exit.json`, JSON.stringify({ code, signal }) + '\n');
            if (signal !== 'SIGKILL' && !spawnFailure) spawnFailure = new Error('Anchor exited outside its owned cleanup');
            resolve();
        });
    });
    if (interrupted) throw new Error('Interrupted; owned anchor cleanup completed');
    if (spawnFailure) throw spawnFailure;
    const result = JSON.parse(fs.readFileSync(specification.result, 'utf8'));
    if (result.nonce !== nonce || !Number.isInteger(result.exit)) throw new Error('Invalid supervisor receipt');
    write(`${label}.exit`, `${result.exit}\n`);
    if (fs.existsSync(specification.log)) process.stdout.write(fs.readFileSync(specification.log));
    if (result.exit !== 0) {
        const error = new Error(`${label}: ${result.reason} (exit ${result.exit})`);
        error.exitCode = result.exit;
        throw error;
    }
}

async function main() {
    const stage = process.argv[2];
    if (process.platform !== 'darwin' || process.argv.length !== 3 || !['watched', 'session', 'bootstrap', 'restore', 'publication', 'parse', 'owner-source', 'owner-prepare', 'owner-json', 'fifo', 'owner-raw', 'owner-cold', 'trakt-next-progress', 'trakt-next-consumer', 'mpv-tls', 'player-metadata'].includes(stage)) {
        throw new Error('Usage on macOS: bash scripts/test-native-migration-phase-a.sh watched|session|bootstrap|restore|publication|parse|owner-source|owner-prepare|owner-json|fifo|owner-raw|owner-cold|trakt-next-progress|trakt-next-consumer|mpv-tls|player-metadata');
    }
    const ownerSource = stage === 'owner-source' || stage === 'owner-prepare';
    const fifo = stage === 'fifo';
    const ownerJSON = stage === 'owner-json';
    const ownerRaw = stage === 'owner-raw', ownerCold = stage === 'owner-cold';
    const traktNext = stage === 'trakt-next-progress' || stage === 'trakt-next-consumer';
    const mpvTLS = stage === 'mpv-tls';
    const playerMetadata = stage === 'player-metadata';
    if (process.env.VORTX_NATIVE_PERSISTENCE_SDK) throw new Error('Unset VORTX_NATIVE_PERSISTENCE_SDK; this fixture never consumes a packaged SDK');
    const scripts = ['scripts/test-native-migration-phase-a.sh', 'scripts/test-native-migration-phase-a.cjs',
        'scripts/native-migration-supervisor.cjs', 'scripts/test-native-watched-archive.sh'];
    scripts.forEach(capture);
    let sources, consumers = [], links = [];
    if (playerMetadata) {
        sources = ['app/Sources/Player/PlaybackMetadataFacts.swift',
            'app/Tests/PlaybackMetadataFactsTests.swift', 'app/Tests/PlaybackMetadataFactsMain.swift'];
    } else if (mpvTLS) {
        sources = ['app/Sources/Player/MPVTLSOptions.swift', 'app/Sources/Player/MPVInitializationFailureState.swift',
            'app/Tests/MPVTLSOptionsTests.swift'];
        ['test/xperience-harness-inputs.cjs', 'app/Sources/Player/MPVMetalViewController.swift'].forEach(capture);
    } else if (traktNext) {
        capture('test/xperience-harness-inputs.cjs');
        sources = ['app/SourcesShared/TraktNextEpisodeProgress.swift', 'app/SourcesShared/TraktModels.swift',
            'app/SourcesShared/VortxNativeBootstrapArchive.swift', 'app/SourcesShared/WatchedFold.swift'];
        if (stage === 'trakt-next-progress') sources.push('app/Tests/TraktNextEpisodeProgressTests.swift');
        else sources.push('app/SourcesShared/TraktNextEpisodeConsumer.swift',
            'app/SourcesShared/TraktWatchedSnapshotReader.swift', 'app/Tests/TraktNextEpisodeConsumerTests.swift');
        ['app/SourcesShared/TraktScrobbleProgressPolicy.swift', 'app/SourcesShared/CoreModels.swift',
            'app/Tests/TraktOAuthBrokerContractTests.swift', 'scripts/test-trakt-watched-snapshot.sh'].forEach(capture);
    } else if (ownerJSON) {
        sources = ['app/SourcesShared/OwnerHistoryExactJSON.swift',
            'app/Tests/OwnerHistorySnapshotConservationTests.swift', 'app/Tests/OwnerHistorySnapshotConservationMain.swift'];
    } else if (fifo) {
        sources = ['app/SourcesShared/VortxNativeRuntime.swift', 'app/SourcesShared/VortxResourceBridge.swift',
            'app/SourcesShared/VortxNativeHostFieldMutation.swift', 'app/SourcesShared/VortxNativeFIFOAdmission.swift',
            'app/Tests/VortxNativeFIFOAdmissionTests.swift', 'app/Tests/VortxNativeFIFOAdmissionMain.swift'];
    } else if (stage === 'publication') {
        sources = ['app/Tests/CoreBridgePublicationFenceContractTests.swift'];
        consumers = publicationConsumers();
        consumers.forEach(capture);
    } else if (stage === 'parse') {
        sources = ['app/SourcesShared/CoreBridge.swift', 'app/SourcesShared/VortXSyncManager.swift',
            'app/SourcesShared/VortxLegacyWatchedMigration.swift', 'app/SourcesShared/VortxNativeCoreFacade.swift',
            'app/SourcesShared/VortxNativeHostPreferences.swift', 'app/SourcesShared/VortxNativeSession.swift',
            'app/SourcesShared/VortxNativeWatchedArchive.swift', 'app/SourcesShared/VortxNativeBootstrapArchive.swift'];
    } else if (stage === 'restore') {
        capture('test/xperience-harness-inputs.cjs');
        sources = xperienceInputs.observationInputs(capture(xperienceInputs.observationInputList).toString('utf8'));
        sources.push('app/SourcesShared/OwnerHistoryExactJSON.swift', 'app/SourcesShared/VortxNativeOwnerHistoryIngress.swift');
        ['app/SourcesShared/VortXSyncManager.swift', 'app/SourcesShared/Keychain.swift',
            'app/SourcesShared/CredentialScope.swift', 'app/Tests/NativeRestoreAdmissionTests.swift'].forEach(capture);
    } else if (stage === 'bootstrap') {
        sources = ['app/SourcesShared/VortxNativeBootstrapArchive.swift', 'app/Tests/VortxNativeBootstrapArchiveTests.swift'];
        capture('app/SourcesShared/SettingsBackup.swift');
    } else {
        const shared = sharedInputs();
        capture('test/xperience-harness-inputs.cjs');
        const ownerInputs = xperienceInputs.ownerHistoryInputs(capture(xperienceInputs.ownerHistoryInputList).toString('utf8'));
        capture('app/SourcesShared/VortXSyncManager.swift');
        links = shared.links;
        sources = ['app/SourcesShared/VortxNativeRuntime.swift', 'app/SourcesShared/VortxResourceBridge.swift',
            'app/SourcesShared/VortxResourceProjection.swift', 'app/SourcesShared/VortxNativeBootstrapArchive.swift',
            'app/SourcesShared/VortxNativeHostPreferences.swift', 'app/SourcesShared/VortxNativeSession.swift',
            'app/SourcesShared/ProfileAddonPreferences.swift', 'app/SourcesShared/VortxProfileOverlayWitness.swift',
            'app/SourcesShared/VortxNativeProfileEditHost.swift', ...shared.sources, ...ownerInputs];
        capture('app/SourcesShared/Profiles.swift');
        capture('app/SourcesShared/ProfileDiscoveryPreferences.swift');
        if (ownerSource) {
            sources.push('app/SourcesShared/VortxNativeProfiles.swift',
                'app/SourcesShared/AuthenticatedHTTPTransport.swift', 'app/SourcesShared/LinkAuthService.swift',
                'app/SourcesShared/VortxLegacyWatchedMetadataTransport.swift',
                'app/SourcesShared/VortxNativeOwnerHistorySource.swift',
                'app/SourcesShared/VortxNativeOwnerHistoryPreparation.swift',
                stage === 'owner-source' ? 'app/Tests/VortxNativeOwnerHistorySourceTests.swift'
                    : 'app/Tests/VortxNativeOwnerHistoryPreparationTests.swift');
        } else if (stage === 'watched') {
            sources.push('app/SourcesShared/SettingsDirtyKeys.swift', 'app/SourcesShared/HomeRailPreferences.swift',
                'app/Tests/VortxNativeWatchedArchiveTests.swift', 'app/Tests/VortxNativeWatchedStreamTests.swift');
            capture('app/SourcesShared/CoreBridge.swift');
            capture('app/SourcesShared/VortXSyncManager.swift');
        } else {
            sources.push('app/SourcesShared/VortxNativeCoreFacade.swift', 'app/SourcesShared/VortxNativePreviouslyWatched.swift',
                'app/SourcesShared/VortxNativeProviderCredentials.swift');
            if (ownerRaw) sources.push('app/Tests/OwnerHistoryRawAccountPreparationTests.swift');
            else if (ownerCold) sources.push('app/Tests/OwnerHistoryColdCoordinatorTests.swift',
                'app/Tests/OwnerHistoryColdCoordinatorMain.swift');
            else sources.push('app/Tests/VortxNativeSessionTests.swift');
        }
    }
    // The explicit owner closure overlaps existing per-stage real inputs. Compile each
    // exact source once; no old test entry or production input is removed.
    sources = [...new Set(sources)];
    sources.forEach(capture);
    fs.mkdirSync(path.join(root, 'app/build'), { recursive: true });
    directory = fs.mkdtempSync(path.join(root, `app/build/native-migration-${stage}.`));
    process.stdout.write(`Retained ${stage} source-unit receipts: ${directory}\n`);
    write('invocation.json', JSON.stringify({ stage, root, node: process.version, nodeExecutable: process.execPath }, null, 2) + '\n');
    // All owning bytes are captured before any extraction. The before manifest is
    // those bytes, not a later reread; all compilation/source-contract inspection
    // uses these immutable retained copies. Verify owners before compile and exit.
    write('source-before.sha256', sourceManifest());
    const copies = new Map();
    for (const [file, bytes] of captured) copies.set(file, write(`source-evidence/${file}`, bytes));
    const inputs = sources.map(file => copies.get(file));
    if (mpvTLS) {
        const controller = captured.get('app/Sources/Player/MPVMetalViewController.swift').toString('utf8');
        const declarations = ['    private func applyRequiredTLSPolicy() -> Bool',
            '    private func configureLiveMode(_ live: Bool)'].map(signature => ({
                signature, bytes: extractDeclaration(controller, signature)
            }));
        inputs.push(write('generated/MPVTLSControllerFixture.swift',
            "import Foundation\n@MainActor\nfinal class ExtractedMPVTLSController {\n    var mpv: OpaquePointer?\n    var initializationFailure = MPVInitializationFailureState<Int>()\n    var configuredLiveMode = false\n    var errors: [Int32] = []\n    init(handle: OpaquePointer?) { mpv = handle }\n    func checkError(_ status: Int32) { if status < 0 { errors.append(status) } }\n    func applyTLS() -> Bool { applyRequiredTLSPolicy() }\n    func configure(_ live: Bool) { configureLiveMode(live) }\n" + declarations.map(item => item.bytes).join('\n\n') + '\n}\n'));
        write('mpv-tls-extraction.json', JSON.stringify({
            owner: 'app/Sources/Player/MPVMetalViewController.swift',
            ownerSHA256: digest(captured.get('app/Sources/Player/MPVMetalViewController.swift')),
            declarations: declarations.map(({ signature, bytes }) => ({ signature, sha256: digest(Buffer.from(bytes)) })),
            declarationTransformations: [], nativeBoundary: 'inert test setters/retirement, no Libmpv'
        }, null, 2) + '\n');
    } else if (stage === 'restore') {
        inputs.push(write('generated/NativeRestoreAdmission.swift', extractRestoreAdmission()));
    } else if (stage === 'bootstrap') {
        inputs.push(write('generated/SettingsBackup.swift', extractSettingsBackupEncoder()));
    } else if (traktNext) {
        inputs.push(...extractTraktNextInputs());
    } else if (stage === 'watched' || stage === 'session' || ownerSource || ownerRaw || ownerCold) {
        inputs.push(write('generated/UserProfile.swift', extractProfile()), write('generated/Discovery.swift', extractDiscovery()));
        const carriers = xperienceInputs.ownerHistoryCarriers(captured.get('app/SourcesShared/VortXSyncManager.swift').toString('utf8'));
        inputs.push(write('generated/OwnerHistoryFixtureCarriers.swift', carriers.source));
        write('owner-history-carriers.json', JSON.stringify({
            owner: 'app/SourcesShared/VortXSyncManager.swift',
            ownerSHA256: digest(captured.get('app/SourcesShared/VortXSyncManager.swift')),
            declarations: carriers.declarations.map(({ signature, bytes }) => ({ signature, sha256: digest(Buffer.from(bytes)) })),
            declarationTransformations: [], factoryExtraction: false
        }, null, 2) + '\n');
    }
    write('compiler-inputs.sha256', inputs.map(file => `${digest(fs.readFileSync(file))}  ${path.relative(directory, file)}\n`).join(''));
    verifySources('source-precompile');
    const executable = path.join(directory, 'fixture');
    const helper = copies.get('scripts/native-migration-supervisor.cjs');
    const evidenceRoot = path.join(directory, 'source-evidence');
    if (stage === 'parse') {
        // Direct -frontend -parse has no driver job scheduler (-j is a driver
        // option). One awaited frontend with one thread per variant; no emit,
        // typecheck, module build, link, packaged SDK, or production execution.
        const parseFlags = ['-frontend', '-parse', '-num-threads', '1', '-swift-version', '5',
            '-module-cache-path', path.join(directory, 'module-cache')];
        for (const native of [false, true]) {
            const label = native ? 'parse-native' : 'parse-legacy';
            verifySources(`source-pre-${label}`);
            const conditions = native ? ['-D', 'VORTX_NATIVE_DATA_ENGINE', '-D', 'VORTX_ENGINE_STATE_BRIDGE',
                '-D', 'VORTX_ENGINE_RESOURCE_HOST'] : [];
            await run(label, ['/usr/bin/nice', '-n', '15', '/usr/bin/xcrun', 'swiftc',
                ...parseFlags, ...conditions, ...inputs], 120_000, helper, evidenceRoot);
        }
        return;
    }
    if (stage === 'publication') {
        write('publication-consumers.json', JSON.stringify(consumers, null, 2) + '\n');
        // Keep the existing standalone fixture's Swift 5/default language and
        // warnings-as-errors semantics; do not impose Swift 6 strict concurrency
        // or parse-as-library on its top-level checks. All assertions are intact.
        const publicationFlags = ['-whole-module-optimization', '-j', '1', '-num-threads', '1',
            '-swift-version', '5', '-warnings-as-errors', '-module-cache-path', path.join(directory, 'module-cache')];
        await run('compile', ['/usr/bin/nice', '-n', '15', '/usr/bin/xcrun', 'swiftc',
            ...publicationFlags, ...inputs, '-o', executable], 600_000, helper, evidenceRoot);
        write('executable.sha256', `${digest(fs.readFileSync(executable))}  fixture\n`);
        verifySources('source-pretest');
        await run('test', ['/usr/bin/nice', '-n', '15', executable], 120_000, helper, evidenceRoot);
        return;
    }
    const flags = ['-O', '-whole-module-optimization', '-j', '1', '-num-threads', '1', '-swift-version', '6',
        '-parse-as-library', '-strict-concurrency=complete', '-warnings-as-errors', '-module-cache-path', path.join(directory, 'module-cache')];
    if (ownerSource || ownerJSON || fifo || stage === 'session' || stage === 'bootstrap' || ownerRaw || ownerCold || traktNext || mpvTLS || playerMetadata) {
        // Host-beta OS versions must not invent an unavailable standard-library target.
        // Use the same explicit macOS 14 fixture floor as the existing native test lanes.
        await run('sdk-path', ['/usr/bin/nice', '-n', '15', '/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-path'], 30_000, helper);
        const sdk = fs.readFileSync(path.join(directory, 'sdk-path.log'), 'utf8').trim();
        if (!path.isAbsolute(sdk) || !fs.statSync(sdk).isDirectory() || /[\r\n]/.test(sdk)) throw new Error('Invalid actual macOS SDK');
        if (!['arm64', 'x64'].includes(process.arch)) throw new Error('Unsupported fixture host');
        flags.push('-sdk', sdk, '-target', `${process.arch === 'arm64' ? 'arm64' : 'x86_64'}-apple-macosx14.0`);
    }
    if (fifo || ownerJSON || ownerCold || playerMetadata) {
        await run('sdk-platform', ['/usr/bin/nice', '-n', '15', '/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-platform-path'], 30_000, helper);
        const platform = fs.readFileSync(path.join(directory, 'sdk-platform.log'), 'utf8').trim();
        const frameworks = path.join(platform, 'Developer/Library/Frameworks');
        const swiftLibraries = path.join(platform, 'Developer/usr/lib');
        if (!path.isAbsolute(platform) || /[\r\n]/.test(platform)
            || !fs.statSync(path.join(frameworks, 'XCTest.framework')).isDirectory()
            || !fs.statSync(path.join(swiftLibraries, 'libXCTestSwiftSupport.dylib')).isFile()) throw new Error('Invalid actual XCTest platform');
        flags.push('-F', frameworks, '-framework', 'XCTest', '-I', swiftLibraries, '-L', swiftLibraries,
            '-lXCTestSwiftSupport', '-Xlinker', '-rpath', '-Xlinker', frameworks,
            '-Xlinker', '-rpath', '-Xlinker', swiftLibraries);
    }
    if (stage === 'restore') flags.push('-D', 'VORTX_NATIVE_DATA_ENGINE');
    // Exactly one compiler then one fixture, at nice 15. Deadlines are hang guards,
    // never throughput/RSS/UI-latency acceptance thresholds or device evidence.
    await run('compile', ['/usr/bin/nice', '-n', '15', '/usr/bin/xcrun', 'swiftc', ...flags, ...inputs, ...links, '-o', executable], mpvTLS ? 120_000 : 600_000, helper);
    write('executable.sha256', `${digest(fs.readFileSync(executable))}  fixture\n`);
    const args = stage === 'watched' ? [path.join(evidenceRoot, 'app/build/synthetic-drafts'), evidenceRoot]
        : stage === 'session' ? [directory] : mpvTLS ? [evidenceRoot] : [];
    await run('test', ['/usr/bin/nice', '-n', '15', executable, ...args], 120_000, helper);
}

(async () => {
    let status = 0;
    try { await main(); }
    catch (error) { status = interrupted || error.exitCode || 1; process.stderr.write(`${error.message}\n`); }
    finally {
        status = interrupted || status;
        if (directory) {
            try { verifySources('source-after'); }
            catch (error) { status = status || 1; process.stderr.write(`${error.message}\n`); }
            write('result.json', JSON.stringify({ stage: process.argv[2], exit: status, interrupted }) + '\n');
            process.stdout.write(`Retained receipts: ${directory} (exit ${status})\n`);
        }
        process.exitCode = status;
    }
})();
