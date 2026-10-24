'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { exact } = require('./addon-guarded-presentation-inputs.cjs');

test('complete preceding actor method is not an attribute on the next method', () => {
    const prior = '    @MainActor private func invalidate() { detach()() }';
    const target = '    @MainActor private func start() { perform() }';
    const source = 'extension Owner {\n' + prior + '\n\n' + target + '\n}';
    const receipts = [];
    assert.equal(exact(source, '@MainActor private func start(', receipts), target);
    assert.equal(receipts.length, 1);
    assert.equal(receipts[0].firstLine, 4);
    assert.equal(receipts[0].bytes, target);
});

test('attached supported actor and discardable attributes remain in the exact slice', () => {
    const target = '    @MainActor\n    @discardableResult\n    private func start() -> Bool { true }';
    assert.equal(exact('extension Owner {\n' + target + '\n}', 'private func start('), target);
});

test('unsupported attached attributes and inline prefixes still fail closed', () => {
    for (const prefix of ['@preconcurrency', '@available(macOS 15, *)', '@Unknown']) {
        const source = 'extension Owner {\n    ' + prefix + '\n    @MainActor\n    private func start() {}\n}';
        assert.throws(() => exact(source, 'private func start('), /Unsupported comment\/attribute prefix/);
    }
    assert.throws(() => exact('extension Owner {\n    @Unknown private func start() {}\n}',
        'private func start('), /Unsupported inline prefix/);
});

test('ambiguous markers and incomplete declarations still refuse extraction', () => {
    assert.throws(() => exact('private func start() {}\nprivate func start() {}',
        'private func start('), /Missing\/ambiguous/);
    assert.throws(() => exact('extension Owner {\nprivate func start() {',
        'private func start('), /Unterminated/);
    assert.throws(() => exact('extension Owner {}', 'private func start('), /Missing\/ambiguous/);
});

test('complete preceding declaration cannot hide an attached unsupported attribute', () => {
    const source = 'extension Owner {\n    @MainActor private func prior() {}\n'
        + '    @Unknown\n    @MainActor private func start() {}\n}';
    assert.throws(() => exact(source, '@MainActor private func start('), /Unsupported comment\/attribute prefix/);
});

test('block or inline comment prefixes are not mistaken for a declaration boundary', () => {
    for (const prior of ['/* unsupported } */', 'let value = 0 // unsupported }']) {
        assert.throws(() => exact('extension Owner {\n' + prior + '\nprivate func start() {}\n}',
            'private func start('), /Unsupported comment\/attribute prefix/);
    }
});
