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
const session = new Map();
const storage = (values) => ({
  getItem: (key) => (values.has(key) ? values.get(key) : null),
  setItem: (key, value) => values.set(key, String(value)),
  removeItem: (key) => values.delete(key),
  clear: () => values.clear(),
});
globalThis.localStorage = storage(local);
globalThis.sessionStorage = storage(session);

const css = new Map();
globalThis.document = {
  documentElement: {
    dataset: {},
    style: {
      setProperty: (key, value) => css.set(key, String(value)),
      removeProperty: (key) => css.delete(key),
    },
  },
};
globalThis.window = new EventTarget();
globalThis.matchMedia = () => ({ matches: false });

const nativeSetTimeout = globalThis.setTimeout;
let settingsTimerSchedules = 0;
globalThis.setTimeout = (fn, delay, ...args) => {
  settingsTimerSchedules += 1;
  return nativeSetTimeout(fn, delay, ...args);
};
const waitForSettingsPush = () => new Promise((resolve) => nativeSetTimeout(resolve, 1_000));

local.set(
  "vortx.web.settings.v1",
  JSON.stringify({
    accentID: "ocean",
    background: "oled",
    safetyFilter: "strict",
    instantOnly: true,
    sourceOrder: ["torrent", "debrid", "usenet", "direct"],
  }),
);
local.set(
  "vortx.web.profiles.v1",
  JSON.stringify([
    {
      id: "seed-owner",
      name: "Owner",
      avatar: "🦊",
      look: {
        accentID: "vortx",
        background: "warm",
        textScale: 1,
        audioLang: "en",
        subtitleLang: "en",
        subtitlesMode: "always",
      },
    },
    {
      id: "seed-overlay",
      name: "Overlay",
      avatar: "🐼",
      look: {
        accentID: "ocean",
        background: "oled",
        textScale: 1,
        audioLang: "fr",
        subtitleLang: "fr",
        subtitlesMode: "always",
      },
    },
  ]),
);
local.set("vortx.web.activeProfile.v1", "seed-overlay");

const { __syncCryptoTestHooks } = await import("./vault.ts");
const { sealDocument, openDocument } = __syncCryptoTestHooks;
const { getSettings, updateSettings } = await import("./settings.ts");
const { profiles, activeProfileId, setActiveProfile, addProfile, deleteProfile } = await import("./profiles.ts");
const { adoptSession, applySyncDoc } = await import("./account.ts");

const waitUntil = async (predicate, label, timeoutMs = 3_000) => {
  const deadline = Date.now() + timeoutMs;
  while (!predicate()) {
    if (Date.now() >= deadline) assert.fail(`Timed out waiting for ${label}`);
    await new Promise((resolve) => nativeSetTimeout(resolve, 10));
  }
};

const makeAccountSession = (id) => ({
  token: `token-${id}`,
  account: { id, email: `${id}@example.test`, username: id },
  dataKey: crypto.getRandomValues(new Uint8Array(32)),
});

async function installSyncServer(accountSession, initialDoc, initialVersion = 100, beforeAcceptPut) {
  let serverVersion = initialVersion;
  let serverDocument = await sealDocument(
    accountSession.dataKey,
    new TextEncoder().encode(JSON.stringify(initialDoc)),
    accountSession.account.id,
    serverVersion,
    false,
  );
  const requests = [];
  const puts = [];

  globalThis.fetch = async (input, init = {}) => {
    const request = { input: String(input), init };
    requests.push(request);
    if ((init.method ?? "GET") === "PUT") {
      const body = JSON.parse(String(init.body));
      puts.push(body);
      const override = beforeAcceptPut ? await beforeAcceptPut(puts.length, body) : null;
      if (override instanceof Response) return override;
      const accepted = body.version > serverVersion;
      if (accepted) {
        serverVersion = body.version;
        serverDocument = body.document;
      }
      return new Response(JSON.stringify({ accepted }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    }
    return new Response(JSON.stringify({ document: serverDocument, version: serverVersion }), {
      status: 200,
      headers: { "content-type": "application/json" },
    });
  };

  return {
    requests,
    puts,
    async readDoc() {
      const plaintext = await openDocument(
        accountSession.dataKey,
        serverDocument,
        accountSession.account.id,
        serverVersion,
      );
      assert.ok(plaintext, "server document must decrypt");
      return JSON.parse(new TextDecoder().decode(plaintext));
    },
  };
}

const settingsDoc = (settings, apiKeys = {}) => ({
  apiKeys,
  vortx: {
    updatedAt: 100,
    profiles: [
      {
        id: "remote-owner",
        name: "Owner",
        main: true,
        settings: {
          accentID: "vortx",
          oled: false,
          textScale: 1,
          playback: { audioLang: "en", subtitleLang: "en", safetyMode: "off" },
          ...settings,
        },
      },
    ],
  },
});

test("settings sync writes only owner edits and never echoes hydration or overlay changes", async (t) => {
  t.after(() => {
    globalThis.setTimeout = nativeSetTimeout;
  });
  assert.equal(activeProfileId(), "seed-overlay", "fixture starts as a page reload under an overlay");
  setActiveProfile("seed-owner");
  assert.equal(getSettings().accentID, "vortx", "reload reconstructs the persisted owner look");
  assert.equal(getSettings().background, "warm", "reload cannot seed the owner with the overlay appearance");
  assert.equal(getSettings().safetyFilter, "strict", "non-profile settings remain shared across the roster");
  assert.deepEqual(
    getSettings().sourceOrder,
    ["torrent", "debrid", "usenet", "direct"],
    "shared source ordering survives the owner transition",
  );
  updateSettings({
    safetyFilter: "off",
    instantOnly: false,
    sourceOrder: ["debrid", "usenet", "torrent", "direct"],
  });

  const dataKey = crypto.getRandomValues(new Uint8Array(32));
  const accountSession = {
    token: "test-token",
    account: { id: "acct-settings-test", email: "owner@example.test", username: "owner" },
    dataKey,
  };
  adoptSession(accountSession);

  const accountDoc = {
    vortx: {
      updatedAt: 10,
      profiles: [
        {
          id: "synced-owner",
          name: "Owner",
          main: true,
          settings: {
            accentID: "vortx",
            oled: false,
            textScale: 1,
            playback: { audioLang: "en", subtitleLang: "en" },
          },
        },
      ],
    },
  };
  const encodedDoc = await sealDocument(
    dataKey,
    new TextEncoder().encode(JSON.stringify(accountDoc)),
    accountSession.account.id,
    10,
    false,
  );

  const requests = [];
  let serverDocument = encodedDoc;
  let serverVersion = 10;
  globalThis.fetch = async (input, init = {}) => {
    requests.push({ input: String(input), init });
    if ((init.method ?? "GET") === "PUT") {
      const body = JSON.parse(String(init.body));
      serverDocument = body.document;
      serverVersion = body.version;
      return new Response(JSON.stringify({ accepted: true }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    }
    return new Response(JSON.stringify({ document: serverDocument, version: serverVersion }), {
      status: 200,
      headers: { "content-type": "application/json" },
    });
  };

  const schedulesBeforeHydration = settingsTimerSchedules;
  applySyncDoc(accountDoc);
  await waitForSettingsPush();
  assert.equal(
    settingsTimerSchedules,
    schedulesBeforeHydration,
    "read-down hydration must not schedule an upward settings write",
  );
  assert.equal(requests.length, 0, "read-down hydration must not execute an upward settings write");

  const ownerId = profiles()[0].id;
  const schedulesBeforeOverlay = settingsTimerSchedules;
  const kids = addProfile("Kids", "🐼");
  assert.notEqual(activeProfileId(), ownerId);
  updateSettings({ accentID: "ocean" });
  await waitForSettingsPush();
  assert.equal(
    settingsTimerSchedules,
    schedulesBeforeOverlay,
    "switching to or editing an overlay profile must not schedule an owner settings write",
  );
  assert.equal(requests.length, 0, "overlay profile changes must never execute an owner settings write");

  const schedulesBeforeOverlayHydration = settingsTimerSchedules;
  applySyncDoc({
    ...accountDoc,
    apiKeys: { tmdb: "overlay-hydrated-tmdb" },
    vortx: {
      ...accountDoc.vortx,
      updatedAt: 11,
      profiles: [
        {
          ...accountDoc.vortx.profiles[0],
          settings: { ...accountDoc.vortx.profiles[0].settings, accentID: "royal" },
        },
      ],
    },
  });
  await waitForSettingsPush();
  assert.equal(
    settingsTimerSchedules,
    schedulesBeforeOverlayHydration,
    "account hydration while an overlay is active must remain read-only",
  );
  assert.equal(requests.length, 0, "overlay-active hydration must not echo into the owner account");
  assert.equal(
    getSettings().accentID,
    "ocean",
    "owner hydration must not replace the active overlay's local appearance",
  );
  assert.equal(
    getSettings().tmdbKey,
    "overlay-hydrated-tmdb",
    "account-global metadata keys still apply while an overlay is active",
  );

  const schedulesBeforeOwnerSwitch = settingsTimerSchedules;
  setActiveProfile(ownerId);
  assert.equal(getSettings().accentID, "royal", "returning to the owner applies the hydrated owner snapshot");
  assert.equal(
    settingsTimerSchedules,
    schedulesBeforeOwnerSwitch,
    "a profile switch applies local state but is not itself an owner edit",
  );

  const schedulesBeforeDeleteFallback = settingsTimerSchedules;
  setActiveProfile(kids.id);
  updateSettings({ background: "oled" });
  deleteProfile(kids.id);
  assert.equal(activeProfileId(), ownerId, "deleting the active overlay falls back to the owner");
  assert.equal(getSettings().background, "warm", "implicit fallback restores the owner's complete settings snapshot");
  assert.equal(
    settingsTimerSchedules,
    schedulesBeforeDeleteFallback,
    "overlay switching and deletion must not create an owner write",
  );

  const remoteDoc = structuredClone(accountDoc);
  remoteDoc.vortx.updatedAt = 20;
  remoteDoc.vortx.profiles[0].settings.accentID = "forest";
  serverVersion = 20;
  serverDocument = await sealDocument(
    dataKey,
    new TextEncoder().encode(JSON.stringify(remoteDoc)),
    accountSession.account.id,
    serverVersion,
    false,
  );

  const globalProfile = addProfile("Global editor", "🎬");
  assert.equal(activeProfileId(), globalProfile.id);
  const schedulesBeforeGlobalEdit = settingsTimerSchedules;
  updateSettings({ tmdbKey: "new-global-key", safetyFilter: "strict" });
  await waitForSettingsPush();
  assert.equal(
    settingsTimerSchedules,
    schedulesBeforeGlobalEdit + 1,
    "an account-global metadata edit remains syncable while an overlay is active",
  );
  const overlayPut = requests.find((request) => request.init.method === "PUT");
  const overlayPutBody = JSON.parse(String(overlayPut.init.body));
  const overlayPlaintext = await openDocument(
    dataKey,
    overlayPutBody.document,
    accountSession.account.id,
    overlayPutBody.version,
  );
  assert.ok(overlayPlaintext, "the overlay settings write must remain a valid account document");
  const overlayWritten = JSON.parse(new TextDecoder().decode(overlayPlaintext));
  assert.equal(
    overlayWritten.apiKeys.tmdb,
    "new-global-key",
    "the global metadata edit is written to the encrypted account document",
  );
  assert.equal(
    overlayWritten.profileEdits.roster[0].settings.accentID,
    "forest",
    "an overlay shared-setting write preserves a newer remote owner appearance",
  );
  assert.equal(
    overlayWritten.profileEdits.roster[0].settings.playback.safetyMode,
    "strict",
    "the overlay shared-setting delta reaches the owner without replacing unrelated owner fields",
  );
  setActiveProfile(ownerId);
  assert.equal(
    getSettings().tmdbKey,
    "new-global-key",
    "returning to the owner cannot erase a global metadata edit made under an overlay",
  );

  const schedulesBeforeOwnerEdit = settingsTimerSchedules;
  updateSettings({ accentID: "forest" });
  await waitForSettingsPush();
  assert.equal(
    settingsTimerSchedules,
    schedulesBeforeOwnerEdit + 1,
    "an owner settings edit remains eligible for coalesced account sync",
  );
  assert.equal(
    requests.filter((request) => (request.init.method ?? "GET") === "GET").length,
    2,
    "the global overlay edit and owner edit each read the latest account doc once",
  );
  assert.equal(
    requests.filter((request) => request.init.method === "PUT").length,
    2,
    "the global overlay edit and coalesced owner edit are each written once",
  );
  const put = requests.filter((request) => request.init.method === "PUT").at(-1);
  const putBody = JSON.parse(String(put.init.body));
  const plaintext = await openDocument(
    dataKey,
    putBody.document,
    accountSession.account.id,
    putBody.version,
  );
  assert.ok(plaintext, "the owner settings write must remain a valid account document");
  const written = JSON.parse(new TextDecoder().decode(plaintext));
  assert.equal(
    written.profileEdits.roster[0].settings.accentID,
    "forest",
    "the surviving write carries the owner's edit",
  );
  assert.equal(written.profileEdits.roster[0].settings.oled, false, "overlay appearance never leaks into the owner write");
  assert.equal(
    written.profileEdits.roster[0].settings.playback.safetyMode,
    "strict",
    "the shared playback setting survives the later owner write",
  );
});

test("rapid separate settings edits union their changed keys into one latest-doc patch", async () => {
  const accountSession = makeAccountSession("acct-rapid-settings");
  const remote = settingsDoc();
  adoptSession(accountSession);
  applySyncDoc(remote);
  const server = await installSyncServer(accountSession, remote);

  updateSettings({ accentID: "ocean" });
  updateSettings({ background: "oled" });

  await waitUntil(() => server.puts.length === 1, "one coalesced settings PUT");
  const written = await server.readDoc();
  const owner = written.profileEdits.roster.find((row) => row.id === "remote-owner");
  assert.equal(owner.settings.accent, "ocean");
  assert.equal(owner.settings.oled, true);
  assert.equal(server.puts.length, 1, "rapid changes must remain one write");
});

test("slow settings writes are serialized so the newest same-key edit wins", async () => {
  let releaseFirstPut;
  const firstPutGate = new Promise((resolve) => {
    releaseFirstPut = resolve;
  });
  const accountSession = makeAccountSession("acct-serialized-settings");
  const remote = settingsDoc();
  adoptSession(accountSession);
  applySyncDoc(remote);
  const server = await installSyncServer(accountSession, remote, 100, async (putNumber) => {
    if (putNumber === 1) await firstPutGate;
  });

  updateSettings({ accentID: "ocean" });
  await waitUntil(() => server.puts.length === 1, "first slow settings PUT");
  updateSettings({ accentID: "royal" });
  await new Promise((resolve) => nativeSetTimeout(resolve, 900));
  assert.equal(server.puts.length, 1, "a second settings PUT must not overlap the first");

  releaseFirstPut();
  await waitUntil(() => server.puts.length === 2, "serialized follow-up settings PUT");
  const written = await server.readDoc();
  const owner = written.profileEdits.roster.find((row) => row.id === "remote-owner");
  assert.equal(owner.settings.accent, "royal", "the later edit must be the stored value");
});

test("switching accounts cancels a pending settings timer from the old session", async () => {
  const first = makeAccountSession("acct-pending-first");
  const second = makeAccountSession("acct-pending-second");
  const requests = [];
  globalThis.fetch = async (input, init = {}) => {
    requests.push({ input: String(input), init });
    return new Response(JSON.stringify({}), {
      status: 200,
      headers: { "content-type": "application/json" },
    });
  };

  adoptSession(first);
  applySyncDoc(settingsDoc());
  updateSettings({ accentID: "forest" });
  adoptSession(second);
  applySyncDoc({});

  await new Promise((resolve) => nativeSetTimeout(resolve, 1_000));
  assert.equal(requests.length, 0, "the first account's pending timer must be discarded");
});

test("an owner edit preserves unrelated settings from the latest remote document", async () => {
  const accountSession = makeAccountSession("acct-owner-stale-remote");
  const hydrated = settingsDoc();
  const newerRemote = settingsDoc({
    oled: true,
    playback: { audioLang: "fr", subtitleLang: "de", safetyMode: "strict" },
  });
  newerRemote.vortx.updatedAt = 200;

  adoptSession(accountSession);
  applySyncDoc(hydrated);
  const server = await installSyncServer(accountSession, newerRemote, 200);
  updateSettings({ accentID: "forest" });

  await waitUntil(() => server.puts.length === 1, "owner delta PUT");
  const written = await server.readDoc();
  const owner = written.profileEdits.roster.find((row) => row.id === "remote-owner");
  assert.equal(owner.settings.accent, "forest");
  assert.equal(owner.settings.oled, true, "a stale local background must not replace the newer remote value");
  assert.equal(
    owner.settings.playback.safetyMode,
    "strict",
    "a stale local playback value must not replace the newer remote value",
  );
});

test("API-key-only account documents support deletion and hydrate missing keys as cleared", async () => {
  const accountSession = makeAccountSession("acct-api-keys-only");
  const remote = { apiKeys: { tmdb: "test-tmdb-value", mdblist: "test-mdblist-value" } };
  adoptSession(accountSession);
  applySyncDoc(remote);
  assert.equal(getSettings().tmdbKey, "test-tmdb-value");
  assert.equal(getSettings().mdblistKey, "test-mdblist-value");
  const server = await installSyncServer(accountSession, remote);

  updateSettings({ tmdbKey: "" });
  await waitUntil(() => server.puts.length === 1, "API key deletion PUT");
  const written = await server.readDoc();
  assert.equal(Object.hasOwn(written.apiKeys, "tmdb"), false, "clearing a key must remove it remotely");
  assert.equal(written.apiKeys.mdblist, "test-mdblist-value", "deleting one key must preserve the other");

  applySyncDoc({});
  assert.equal(getSettings().tmdbKey, "");
  assert.equal(getSettings().mdblistKey, "", "a remote missing key must clear the hydrated local value");
});

test("settings writes preserve the effective web roster, tombstones, fields, and library references", async () => {
  const accountSession = makeAccountSession("acct-effective-web-roster");
  const remote = settingsDoc();
  remote.vortx.profiles.push({
    id: "native-child",
    name: "Native child",
    main: false,
    settings: { accentID: "ocean", playback: {} },
  });
  remote.profileEdits = {
    editedAt: 200,
    roster: [
      {
        id: "remote-owner",
        name: "Renamed owner",
        familyEdit: true,
        settings: { accent: "ocean", playback: { safetyMode: "strict" } },
      },
      {
        id: "native-child",
        name: "Renamed native child",
        pin: "test-pin-hash",
        disabledAddons: ["https://disabled.example/manifest.json"],
      },
      {
        id: "web-created",
        name: "Web created",
        familyEdit: true,
        settings: { avatar: "🛰️", playback: { audioLang: "fr" } },
      },
      { id: "web-deleted", name: "Deleted child", deleted: true },
    ],
    libraryAdds: {
      "web-created": [{ id: "tt-web-created", type: "movie", name: "Pending web title" }],
    },
  };

  adoptSession(accountSession);
  applySyncDoc(remote);
  setActiveProfile(profiles()[0].id);
  const server = await installSyncServer(accountSession, remote, 200);
  updateSettings({ accentID: "gold" });

  await waitUntil(() => server.puts.length === 1, "effective roster settings PUT");
  const written = await server.readDoc();
  const roster = written.profileEdits.roster;
  const owner = roster.find((row) => row.id === "remote-owner");
  const nativeChild = roster.find((row) => row.id === "native-child");
  const webCreated = roster.find((row) => row.id === "web-created");
  const webDeleted = roster.find((row) => row.id === "web-deleted");

  assert.equal(owner.name, "Renamed owner");
  assert.equal(owner.familyEdit, true);
  assert.equal(owner.settings.accent, "gold");
  assert.equal(owner.settings.playback.safetyMode, "strict");
  assert.equal(nativeChild.name, "Renamed native child");
  assert.equal(nativeChild.pin, "test-pin-hash");
  assert.deepEqual(nativeChild.disabledAddons, ["https://disabled.example/manifest.json"]);
  assert.equal(webCreated.name, "Web created");
  assert.equal(webCreated.familyEdit, true);
  assert.equal(webCreated.settings.avatar, "🛰️");
  assert.equal(webDeleted.deleted, true);
  assert.deepEqual(written.profileEdits.libraryAdds, remote.profileEdits.libraryAdds);
});

test("a failed serialized batch merges into queued edits and retries an isolated failure", async () => {
  let releaseFirstPut;
  const firstPutGate = new Promise((resolve) => {
    releaseFirstPut = resolve;
  });
  let activePuts = 0;
  let maxActivePuts = 0;
  const failedPuts = new Set([1, 3]);
  const accountSession = makeAccountSession("acct-failed-settings-batch");
  const remote = settingsDoc();
  adoptSession(accountSession);
  applySyncDoc(remote);
  const server = await installSyncServer(accountSession, remote, 100, async (putNumber) => {
    activePuts += 1;
    maxActivePuts = Math.max(maxActivePuts, activePuts);
    if (putNumber === 1) await firstPutGate;
    activePuts -= 1;
    if (failedPuts.has(putNumber)) {
      return new Response(JSON.stringify({ error: "injected settings write failure" }), {
        status: 503,
        headers: { "content-type": "application/json" },
      });
    }
    return null;
  });

  updateSettings({ safetyFilter: "strict", accentID: "ocean" });
  await waitUntil(() => server.puts.length === 1, "first failing settings PUT");
  updateSettings({ accentID: "royal", background: "oled" });
  await new Promise((resolve) => nativeSetTimeout(resolve, 900));
  assert.equal(server.puts.length, 1, "the queued batch must not overlap the failing write");

  releaseFirstPut();
  await waitUntil(() => server.puts.length === 2, "queued retry after the first failure");
  let written = await server.readDoc();
  let owner = written.profileEdits.roster.find((row) => row.id === "remote-owner");
  assert.equal(owner.settings.accent, "royal", "the newest same-key value must win");
  assert.equal(owner.settings.oled, true);
  assert.equal(owner.settings.playback.safetyMode, "strict", "the failed batch's distinct key must be retried");

  updateSettings({ subtitleFont: "classic" });
  await waitUntil(() => server.puts.length === 3, "isolated failing settings PUT");
  await waitUntil(() => server.puts.length === 4, "automatic retry without another user edit");
  written = await server.readDoc();
  owner = written.profileEdits.roster.find((row) => row.id === "remote-owner");
  assert.equal(owner.settings.playback.subFont, "classic");
  assert.equal(maxActivePuts, 1, "retry writes must remain serialized");
});

test("session identity changes clear account data immediately and preserve device-local settings", () => {
  const first = makeAccountSession("acct-clear-first");
  const refreshed = {
    ...first,
    token: "token-acct-clear-first-refreshed",
  };
  const second = makeAccountSession("acct-clear-second");

  adoptSession(first);
  applySyncDoc(
    settingsDoc(
      {
        accentID: "royal",
        oled: true,
        playback: {
          audioLang: "fr",
          subtitleLang: "de",
          safetyMode: "strict",
          sourceTypeOrder: ["torrent", "direct"],
          subFont: "classic",
        },
      },
      { tmdb: "account-a-tmdb", mdblist: "account-a-mdblist" },
    ),
  );
  const ownerId = profiles()[0].id;
  addProfile("Account A overlay", "🧭");
  updateSettings({
    autoplayTrailers: false,
    directLinksOnly: true,
    skipStep: 30,
    episodeAlerts: true,
    performance: "reduced",
  });

  adoptSession(refreshed);
  assert.equal(getSettings().tmdbKey, "account-a-tmdb", "a token refresh must retain the same account's settings");
  assert.equal(getSettings().mdblistKey, "account-a-mdblist");
  assert.equal(getSettings().accentID, "royal");
  assert.equal(getSettings().background, "oled");
  assert.equal(getSettings().safetyFilter, "strict");
  assert.deepEqual(getSettings().sourceOrder, ["torrent", "direct"]);
  assert.equal(getSettings().subtitleFont, "classic");
  assert.equal(getSettings().autoplayTrailers, false);
  assert.equal(getSettings().directLinksOnly, true);
  assert.equal(getSettings().skipStep, 30);
  assert.equal(getSettings().episodeAlerts, true);
  assert.equal(getSettings().performance, "reduced");
  setActiveProfile(ownerId);
  assert.equal(getSettings().accentID, "royal");
  assert.equal(getSettings().background, "oled");

  applySyncDoc(settingsDoc({ accentID: "crimson", oled: true }, { tmdb: "refreshed-tmdb" }));
  adoptSession(second);
  assert.equal(getSettings().tmdbKey, "", "account A credentials must clear before account B hydration");
  assert.equal(getSettings().accentID, "vortx", "account A appearance must clear before account B hydration");
  assert.equal(getSettings().background, "warm");
  assert.equal(getSettings().performance, "reduced", "safe device-local settings must survive account changes");
});
