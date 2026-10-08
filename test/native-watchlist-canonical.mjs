import { createHash } from 'node:crypto';

let raw = '';
for await (const chunk of process.stdin) raw += chunk;
const rows = JSON.parse(raw);
if (rows.length !== 512) throw new Error(`Expected 512 exact-source binary64 fixtures, got ${rows.length}`);
function canonical(value) {
  if (value === null || typeof value !== 'object') return JSON.stringify(value);
  if (Array.isArray(value)) return '[' + value.map(canonical).join(',') + ']';
  return '{' + Object.keys(value).sort().map(key => JSON.stringify(key) + ':' + canonical(value[key])).join(',') + '}';
}
for (const [index, row] of rows.entries()) {
  const expected = canonical({ domain: 'vortx-watchlist-baseline-v1', profileId: row.profileId, field: row.field, value: row.value });
  if (row.canonical !== expected || row.seconds !== JSON.stringify(row.value.addedAt)) {
    throw new Error(`JavaScript canonical binary64/string mismatch at fixture ${index}`);
  }
  const hex = createHash('sha256').update(expected, 'utf8').digest('hex').slice(0, 32);
  const actor = `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
  if (actor !== row.actor) throw new Error(`Baseline actor mismatch at fixture ${index}`);
}
const golden = rows.find(row => row.value.addedAt === 123.5);
if (golden?.actor !== 'e2845c02-42cf-6e8c-1cc4-bef50778d4b4') throw new Error('Apple Unicode/slash/fraction golden mismatch');
console.log('PASS: 512 actual-source JVM ↔ Node canonical JSON, binary64 and baseline actor fixtures; Apple golden matches.');
