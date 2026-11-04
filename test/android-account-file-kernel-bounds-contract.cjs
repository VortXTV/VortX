#!/usr/bin/env node
'use strict';
// Source-order gate complements runtime zero-binding negatives; it is NOT a copy/parse profiler.
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const root = path.resolve(process.argv[2] || path.join(__dirname, '..'));
const rel = 'android/app/src/main/kotlin/com/vortx/android/engine/DetachedAccountFileKernel.kt';
const source = fs.readFileSync(path.join(root, rel), 'utf8');
const cases = [
  ['legacySync', '        requireInputSize(material)\n        val originalMaterial = material.copyOf(); materialSchema(originalMaterial)'],
  ['fileRestoreState', '        requireInputSize(originalNativeBytes)\n        val native = originalNativeBytes.copyOf(); generic(native, scope)'],
  ['requireLegacyReplay', '        requireInputSize(originalNativeBytes)\n        requireInputSize(material)\n        val native = originalNativeBytes.copyOf(); val originalMaterial = material.copyOf()']
];
for (const [name, prefix] of cases) {
  const start = source.indexOf(`    fun ${name}(`); assert(start >= 0, name);
  assert.equal(source.indexOf(`    fun ${name}(`, start + 1), -1, 'unique entry');
  const body = source.indexOf(' {\n', start); assert(body >= 0);
  assert.equal(source.slice(body + 3, body + 3 + prefix.length), prefix, name + ' must bound before copy, parse, or binding');
}
assert(source.includes('require(input.size <= MAX_BYTES) { "Cold account input exceeds limit" }'));
console.log('Cold account selected-input bounds source contract passed');
