'use strict';

const crypto = require('crypto');

// V3 RECOVERY-ONLY PROPOSAL. UNRUN. Parent's standalone runner supplies the
// already captured Facade bytes and existing exact extractDeclaration helper.
// This is a narrow source-prefix contract, not a Swift parser or compiler.
function admissionPrimitivePeer(facade, extractDeclaration) {
    const owner = 'app/SourcesShared/VortxNativeCoreFacade.swift';
    const declarations = [];
    const validationOnly = [];
    function exact(signature, required) {
        const start = facade.indexOf(signature);
        if (start < 0) throw new Error('Admission primitive absent: ' + signature);
        const lineStart = facade.lastIndexOf('\n', start - 1) + 1;
        if (facade.slice(lineStart, start).trim() !== '')
            throw new Error('Inline prefix before admission primitive: ' + signature);
        const lines = facade.slice(0, lineStart).split(/\r?\n/);
        let index = lines.length - 1;
        while (index >= 0) {
            const prior = lines[index].trim();
            if (!prior || prior.startsWith('//')) { index--; continue; }
            if (prior !== '}')
                throw new Error('Unsupported attribute/block prefix before: ' + signature);
            break;
        }
        if (index < 0) throw new Error('Missing closed predecessor before: ' + signature);
        const bytes = extractDeclaration(facade, signature);
        for (const fragment of required) {
            if (!bytes.includes(fragment))
                throw new Error('Admission primitive declaration changed: ' + fragment);
        }
        if (bytes.includes('@unchecked Sendable'))
            throw new Error('Admission primitive gained @unchecked Sendable: ' + signature);
        declarations.push({ owner, signature, bytes });
        return bytes;
    }

    function validate(signature, required) {
        const bytes = extractDeclaration(facade, signature);
        for (const fragment of required) {
            if (!bytes.includes(fragment))
                throw new Error('Task-cancellation declaration changed: ' + fragment);
        }
        validationOnly.push({
            owner,
            signature,
            sha256: crypto.createHash('sha256').update(bytes, 'utf8').digest('hex')
        });
        return bytes;
    }

    const facadeLock = exact(
        'final class VortxNativeFacadeLock: NSLocking, Sendable {',
        ['private let underlying = NSRecursiveLock()',
            'private let storage = OSAllocatedUnfairLock(initialState: State())',
            'func afterOutermostUnlock(_ delivery: @escaping @Sendable () -> Void) {']);
    const admissionFence = exact(
        'final class VortxNativeMetadataAdmissionFence: Sendable {',
        ['private let state = OSAllocatedUnfairLock(initialState: State())',
            'func captureInstallation() -> UUID',
            'func retireInstallation()',
            'func replaceRequest(_ request: UUID)',
            'fileprivate func withCurrent<Result: Sendable>',
            'operation: @Sendable () -> Result']);
    validate(
        '    private func begin(_ field: String, replacingSelection: Bool = true) -> UUID? {',
        ['let previous = tasks.removeValue(forKey: field)',
            'if let previous { lock.afterOutermostUnlock { previous.cancel() } }']);
    validate(
        '    private func enqueue(_ field: String, initial: VortxJSON? = nil, replacingSelection: Bool = true,\n'
            + '                         operation: @escaping @Sendable (@escaping @Sendable (VortxJSON) -> Void) async throws -> [String: VortxJSON]) -> Bool {',
        ['guard let ticket = begin(field, replacingSelection: replacingSelection) else { return false }',
            'if closed || generations[field] != ticket {',
            'lock.afterOutermostUnlock { task.cancel() }',
            'else { tasks[field] = task }']);
    return {
        source: 'import Foundation\nimport Darwin\nimport Dispatch\nimport os\n\n'
            + facadeLock + '\n\n' + admissionFence,
        declarations,
        validationOnly,
        declarationTransformations: [],
        owner,
        sourceOnly: ['exact F lock', 'exact W fence'],
        syntheticOnly: ['checked RAM B/M scalar state', 'real Swift Task cancellation fixture'],
        excluded: ['Facade/Session/FIFO/CoreBridge owner', 'Manager/ProfileStore/SDK/C symbols',
            'presentation actors']
    };
}

module.exports = { admissionPrimitivePeer };
