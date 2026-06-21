// Device-bound wrapping key for protecting the persisted account data key at rest.
//
// THREAT: before this, the raw 32-byte data key sat in localStorage in plaintext, so any XSS one-liner
// (`localStorage.getItem`), a malicious browser extension, or an at-rest storage dump could lift it and
// decrypt the user's synced vault forever. This module mints a NON-EXTRACTABLE AES-GCM key that lives
// only in IndexedDB. CryptoKey objects are structured-cloneable even when non-extractable, so the key
// persists across reloads while its raw bytes are NEVER readable by JavaScript. vault.ts wraps the data
// key under it, so localStorage holds only ciphertext that is useless without this key.
//
// SCOPE: this is a purely LOCAL protection. It does not touch the wire protocol, the KDF, ITERS, or the
// seal/open framing, so cross-surface interop (app / desktop / website) is unaffected. It is defense in
// depth: it defeats passive at-rest theft and raises the bar on active XSS (which can no longer exfiltrate
// a permanent key), though an actively-running XSS payload can still ask this key to decrypt in-tab.
//
// DEGRADATION: every call returns null instead of throwing when IndexedDB or WebCrypto is unavailable
// (private mode, locked-down browser). Callers treat null as "cannot securely persist", degrading to a
// forced re-login on the next reload rather than ever falling back to a plaintext key at rest.

const DB_NAME = "vortx-keys";
const STORE = "keys";
const KEY_ID = "deviceKey.v1";

/** Open (creating on first use) the key store. */
function openDb(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    if (typeof indexedDB === "undefined") {
      reject(new Error("no-indexeddb"));
      return;
    }
    const req = indexedDB.open(DB_NAME, 1);
    req.onupgradeneeded = () => {
      if (!req.result.objectStoreNames.contains(STORE)) req.result.createObjectStore(STORE);
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error ?? new Error("idb-open-failed"));
  });
}

function idbGet(db: IDBDatabase, id: string): Promise<unknown> {
  return new Promise((resolve, reject) => {
    const req = db.transaction(STORE, "readonly").objectStore(STORE).get(id);
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error ?? new Error("idb-get-failed"));
  });
}

function idbPut(db: IDBDatabase, id: string, value: CryptoKey): Promise<void> {
  return new Promise((resolve, reject) => {
    const tx = db.transaction(STORE, "readwrite");
    tx.objectStore(STORE).put(value, id);
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error ?? new Error("idb-put-failed"));
    tx.onabort = () => reject(tx.error ?? new Error("idb-put-aborted"));
  });
}

async function resolveDeviceKey(): Promise<CryptoKey | null> {
  try {
    if (typeof crypto === "undefined" || !crypto.subtle) return null;
    const db = await openDb();
    try {
      const existing = await idbGet(db, KEY_ID);
      if (existing && (existing as CryptoKey).type === "secret") return existing as CryptoKey;
      // First run on this device: mint a non-extractable AES-GCM-256 key and persist it.
      const key = await crypto.subtle.generateKey({ name: "AES-GCM", length: 256 }, false, ["encrypt", "decrypt"]);
      await idbPut(db, KEY_ID, key);
      return key;
    } finally {
      db.close();
    }
  } catch {
    return null;
  }
}

// Memoize the get-or-create so concurrent callers (saveSession + loadSession on boot) share ONE result -
// without this, two racing callers could each mint a key and the later put() would orphan the wrapped data
// key. A null result (IndexedDB unavailable) is not cached, so a later call can retry.
let deviceKeyPromise: Promise<CryptoKey | null> | null = null;

/** Get this device's non-extractable wrapping key, creating it on first use. Returns null when secure
 *  storage is unavailable, so callers can degrade gracefully instead of persisting a plaintext key. */
export function getDeviceKey(): Promise<CryptoKey | null> {
  if (!deviceKeyPromise) {
    deviceKeyPromise = resolveDeviceKey().then((k) => {
      if (!k) deviceKeyPromise = null; // allow a retry next time
      return k;
    });
  }
  return deviceKeyPromise;
}
