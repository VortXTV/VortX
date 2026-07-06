// In-repo crypto test for the version-bound sync-document format, exercising the REAL functions from
// vault.ts (via __syncCryptoTestHooks) rather than a re-implementation. Run: `npm test` (node --test).
// Covers: v2 round-trip, the rollback/downgrade rejections, legacy compatibility, tamper resistance, the
// H-1 ratchet + H-2 floor helpers, and a FIXED Swift/CryptoKit-sealed vector to pin cross-surface interop.
import { test } from "node:test";
import assert from "node:assert/strict";

// Stub browser storage BEFORE importing the module (its ratchet/floor helpers use localStorage).
const store = new Map();
globalThis.localStorage = {
  getItem: (k) => (store.has(k) ? store.get(k) : null),
  setItem: (k, v) => store.set(k, String(v)),
  removeItem: (k) => store.delete(k),
  clear: () => store.clear(),
};
globalThis.sessionStorage = globalThis.localStorage;

const { __syncCryptoTestHooks: H } = await import("./vault.ts");
const { sealDocument, openDocument, DOC_V2_PREFIX, sawV2, markSawV2, syncFloor, bumpSyncFloor } = H;

const enc = (s) => new TextEncoder().encode(s);
const dec = (u) => new TextDecoder().decode(u);
const key = () => crypto.getRandomValues(new Uint8Array(32));
const ACCT = "acct_12345";
const PT = JSON.stringify({ vortx: { addons: ["a", "b"] }, version: 7 });

test("v2 seal/open round-trips and blocks rollback", async () => {
  const dk = key();
  const blob = await sealDocument(dk, enc(PT), ACCT, 200, true);
  assert.ok(blob.startsWith(DOC_V2_PREFIX), "v2 blob carries the prefix");
  assert.equal(dec(await openDocument(dk, blob, ACCT, 200)), PT, "opens at its own version");
  assert.equal(await openDocument(dk, blob, ACCT, 201), null, "forged HIGHER version rejected (rollback blocked)");
  assert.equal(await openDocument(dk, blob, ACCT, 199), null, "lower version rejected");
  assert.equal(await openDocument(dk, blob, "other", 200), null, "wrong account rejected");
  assert.equal(await openDocument(key(), blob, ACCT, 200), null, "wrong data key rejected");
});

test("legacy (writeV2=false) stays readable and un-prefixed", async () => {
  const dk = key();
  const legacy = await sealDocument(dk, enc(PT), ACCT, 5, false);
  assert.ok(!legacy.startsWith(DOC_V2_PREFIX), "legacy write is bare base64");
  assert.equal(dec(await openDocument(dk, legacy, ACCT, 5)), PT, "legacy opens");
  assert.equal(dec(await openDocument(dk, legacy, ACCT, 999)), PT, "legacy ignores version");
});

test("prefix tamper fails the tag", async () => {
  const dk = key();
  const v2 = await sealDocument(dk, enc(PT), ACCT, 10, true);
  const legacy = await sealDocument(dk, enc(PT), ACCT, 10, false);
  assert.equal(await openDocument(dk, v2.slice(DOC_V2_PREFIX.length), ACCT, 10), null, "stripping v2. -> legacy path fails");
  assert.equal(await openDocument(dk, DOC_V2_PREFIX + legacy, ACCT, 10), null, "forging v2. onto legacy fails");
});

test("Swift/CryptoKit-sealed vector opens here (cross-surface byte format pinned)", async () => {
  // Fixed regression vector sealed by the app's VortXSyncCrypto.sealDocument (Swift CryptoKit AES-GCM +
  // additionalData, iv||ct||tag, standard base64) for (dataKey, "acct_12345", 1720000000042, PT). If the
  // app or web AAD/framing ever drifts, this stops opening.
  const dk = new Uint8Array(Buffer.from("iH7MYN3sR9hZ7pUVlYylPIW1q1SxXo71Ekzv6Amr+lU=", "base64"));
  const blob = "v2.9lZC5mhG159j/xSzo2QduSbhqvr1dN9bM9tyo2ldJub4WcA4Ozrw7ZtGAs3rU0+tsaoCZEjRXkApXrHNvnQOBgdqmW9JaA==";
  assert.equal(dec(await openDocument(dk, blob, "acct_12345", 1720000000042)), PT, "Swift v2 blob opens in JS");
  assert.equal(await openDocument(dk, blob, "acct_12345", 1720000000043), null, "and rejects a forged version");
});

test("H-1 ratchet + H-2 floor are per-account", () => {
  store.clear();
  assert.equal(sawV2("A"), false);
  markSawV2("A");
  assert.equal(sawV2("A"), true, "ratchet set for A");
  assert.equal(sawV2("B"), false, "not for B (per-account)");

  assert.equal(syncFloor("A"), 0);
  bumpSyncFloor("A", 1000);
  assert.equal(syncFloor("A"), 1000, "floor raised for A");
  bumpSyncFloor("A", 5);
  assert.equal(syncFloor("A"), 1000, "floor is monotonic (5 does not lower it)");
  assert.equal(syncFloor("B"), 0, "B floor independent (account-switch safe)");
});
