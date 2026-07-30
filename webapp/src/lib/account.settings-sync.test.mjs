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

  const globalProfile = addProfile("Global editor", "🎬");
  assert.equal(activeProfileId(), globalProfile.id);
  const schedulesBeforeGlobalEdit = settingsTimerSchedules;
  updateSettings({ tmdbKey: "new-global-key" });
  await waitForSettingsPush();
  assert.equal(
    settingsTimerSchedules,
    schedulesBeforeGlobalEdit + 1,
    "an account-global metadata edit remains syncable while an overlay is active",
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
    "off",
    "overlay-only playback settings never leak into the owner write",
  );
});
