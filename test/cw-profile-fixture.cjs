'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { extractDeclaration } = require('./xperience-harness-inputs.cjs');
const sha256 = value => crypto.createHash('sha256').update(value).digest('hex');
function exact(profiles, marker) {
    const body = extractDeclaration(profiles, marker), start = profiles.indexOf(body);
    let first = profiles.lastIndexOf('\n', start - 1) + 1;
    while (first > 0) {
        const end = first - 1, previous = profiles.lastIndexOf('\n', end - 1) + 1;
        if (!profiles.slice(previous, end).trim().startsWith('@')) break;
        first = previous;
    }
    return profiles.slice(first, start) + body;
}
function materialize(profiles, fixture) {
    const namespace = exact(profiles, 'enum ProfileSelectionRead {');
    const projector = exact(profiles, 'private func selectionReadSnapshot()');
    const root = path.resolve(__dirname, '..');
    const core = fs.readFileSync(path.join(root, 'app/SourcesShared/CoreBridge.swift'), 'utf8');
    const facade = fs.readFileSync(path.join(root, 'app/SourcesShared/VortxNativeCoreFacade.swift'), 'utf8');
    const capability = exact(core, 'struct NativePlaybackReadCapability:');
    const bindings = ['struct RegistryBinding:', 'struct WatchlistBinding:']
        .map(marker => exact(facade, marker)).join('\n');
    let generated = fixture;
    for (const [marker, value] of [
        ['// PRODUCTION_HOME_PROFILE_SELECTION_READ', namespace],
        ['// PRODUCTION_HOME_PROFILE_SELECTION_PROJECTOR', projector],
        ['// PRODUCTION_HOME_NATIVE_READ_CAPABILITY', capability],
        ['// PRODUCTION_HOME_NATIVE_FACADE_BINDINGS', bindings],
    ]) {
        assert.equal(generated.split(marker).length, 2, 'unique actual scalar fixture marker');
        generated = generated.replace(marker, value);
    }
    for (const field of ['continueWatchingSource', 'continueWatchingWindow']) {
        assert(namespace.includes('let ' + field + ': String?'));
        assert(projector.includes('$0.discovery?.' + field));
    }
    return { source: generated, receipt: {
        profilesSHA256: sha256(profiles), fixtureInputSHA256: sha256(fixture),
        namespaceSHA256: sha256(namespace), projectorSHA256: sha256(projector),
        coreSHA256: sha256(core), facadeSHA256: sha256(facade),
        capabilitySHA256: sha256(capability), facadeBindingsSHA256: sha256(bindings),
        generatedSHA256: sha256(generated), declarationTransformations: [],
        scope: 'Same-file real scalar/projector, exact native read capability and Facade binding values; explicit RAM installation/epoch/Facade collaborators, not actual B/F capture or SDK; old broad lane language mode retained',
    } };
}
module.exports = { materialize };
if (require.main === module) {
    assert.equal(process.argv.length, 3);
    const root = path.resolve(__dirname, '..'), output = path.resolve(process.argv[2]);
    assert(output.startsWith(path.join(root, 'app/build') + path.sep), 'fixture output must stay under app/build');
    const profiles = fs.readFileSync(path.join(root, 'app/SourcesShared/Profiles.swift'), 'utf8');
    const fixture = fs.readFileSync(path.join(root, 'app/Tests/HomeContinueWatchingFixtureStubs.swift'), 'utf8');
    const generated = materialize(profiles, fixture);
    fs.writeFileSync(output, generated.source, { flag: 'wx' });
    fs.writeFileSync(output + '.binding.json', JSON.stringify(generated.receipt, null, 2) + '\n', { flag: 'wx' });
}
