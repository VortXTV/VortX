import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { registerHooks } from "node:module";

registerHooks({
  resolve(specifier, context, next) {
    if (specifier.startsWith(".") && !/\.[a-z]+$/i.test(specifier) && context.parentURL) {
      const candidate = new URL(specifier + ".ts", context.parentURL);
      if (existsSync(fileURLToPath(candidate))) return { url: candidate.href, shortCircuit: true };
    }
    return next(specifier, context);
  },
});

const local = new Map();
const sessionStorageValues = new Map();
const storage = (values) => ({
  getItem: (key) => (values.has(key) ? values.get(key) : null),
  setItem: (key, value) => values.set(key, String(value)),
  removeItem: (key) => values.delete(key),
  clear: () => values.clear(),
});
globalThis.localStorage = storage(local);
globalThis.sessionStorage = storage(sessionStorageValues);
globalThis.document = { documentElement: { dataset: {}, style: { setProperty() {}, removeProperty() {} } } };
globalThis.window = new EventTarget();
globalThis.matchMedia = () => ({ matches: false });

local.set("vortx.web.profiles.v1", JSON.stringify([{ id: "owner", name: "Owner", main: true }]));
local.set("vortx.web.activeProfile.v1", "owner");

const { __syncCryptoTestHooks } = await import("./vault.ts");
const { sealDocument, openDocument } = __syncCryptoTestHooks;
const { adoptSession, applySyncDoc, __continueWatchingSyncTestHooks } = await import("./account.ts");
const { clearProgress, continueWatching, webProgressTombstones } = await import("./store.ts");

async function installServer(accountSession, initialDoc) {
  let version = 20;
  let document = await sealDocument(
    accountSession.dataKey,
    new TextEncoder().encode(JSON.stringify(initialDoc)),
    accountSession.account.id,
    version,
    false,
  );
  globalThis.fetch = async (_input, init = {}) => {
    if ((init.method ?? "GET") === "PUT") {
      const body = JSON.parse(String(init.body));
      assert.ok(body.version > version);
      version = body.version;
      document = body.document;
      return new Response(JSON.stringify({ accepted: true }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    }
    return new Response(JSON.stringify({ document, version }), {
      status: 200,
      headers: { "content-type": "application/json" },
    });
  };
  return async () => {
    const plaintext = await openDocument(accountSession.dataKey, document, accountSession.account.id, version);
    return JSON.parse(new TextDecoder().decode(plaintext));
  };
}

const remoteEntry = (patch = {}) => ({
  id: "imdb:tt0903747",
  type: "series",
  name: "Breaking Bad",
  v: "tt0903747:5:16",
  t: 900,
  d: 2700,
  ...patch,
});

test("account adapter unions removals, preserves foreign fields, and respects no-clock hydration", async () => {
  const accountSession = {
    token: "token-cw",
    account: { id: "acct-cw", email: "owner@example.test", username: "owner" },
    dataKey: crypto.getRandomValues(new Uint8Array(32)),
  };
  const browserBRemoval = { keys: ["id:series:tmdb:999"], removedAt: 500 };
  const initialDoc = {
    foreignAccountField: { keep: true },
    webProgress: {
      foreignProgressField: "keep",
      owner: [remoteEntry()],
      removed: { owner: [browserBRemoval] },
    },
  };
  const readServer = await installServer(accountSession, initialDoc);

  local.set(
    "vortx.web.cw.v1",
    JSON.stringify([{
      id: "imdb:tt0903747",
      type: "series",
      name: "Breaking Bad",
      resumeId: "tt0903747:5:16",
      position: 900,
      duration: 2700,
      updatedAt: 900,
    }]),
  );
  clearProgress("imdb:tt0903747");
  const [browserARemoval] = webProgressTombstones();
  adoptSession(accountSession);
  assert.deepEqual(webProgressTombstones(), [browserARemoval], "owner tombstone uses the account base scope");
  await __continueWatchingSyncTestHooks.pushWebProgress(accountSession);

  const synced = await readServer();
  assert.deepEqual(synced.foreignAccountField, { keep: true });
  assert.equal(synced.webProgress.foreignProgressField, "keep");
  assert.equal(
    synced.webProgress.removed.owner.length,
    2,
    `concurrent browser removals are unioned: ${JSON.stringify(synced.webProgress.removed.owner)}`,
  );

  applySyncDoc(synced);
  assert.deepEqual(continueWatching(), [], "missing remote lastWatched stays older than the local tombstone");

  applySyncDoc({
    webProgress: {
      owner: [remoteEntry({ lastWatched: browserARemoval.removedAt + 1 })],
      removed: synced.webProgress.removed,
    },
  });
  assert.deepEqual(
    continueWatching().map((entry) => entry.id),
    ["imdb:tt0903747"],
    "an explicitly newer rewatch supersedes the tombstone",
  );

  local.set("vortx.web.cw.v1.overlay", JSON.stringify([{
    id: "imdb:tt0903747",
    type: "series",
    name: "Breaking Bad",
    resumeId: "tt0903747:5:16",
    position: 900,
    duration: 2700,
    updatedAt: browserARemoval.removedAt - 1,
  }]));
  applySyncDoc({
    vortx: {
      byProfile: {
        overlay: {
          library: [remoteEntry({ lastWatched: browserARemoval.removedAt - 1 })],
          removed: [browserARemoval],
        },
      },
    },
  });
  assert.deepEqual(
    JSON.parse(local.get("vortx.web.cw.v1.overlay") ?? "[]"),
    [],
    "Apple byProfile removals are folded before web hydration",
  );
});
