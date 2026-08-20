const ACTIVE_KEY = "feed:active";
const STAGED_PREFIX = "feed:staged:";
const ROLLBACK_PREFIX = "feed:rollback:";
const ARTIFACT_SCHEMA = 2;
const MAX_BODY_BYTES = 1_048_576;
const MAX_PUBLIC_AGE = 120;
const RELEASE_TAG_RE = /^v[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.]+)?$/;
const SHA_RE = /^[0-9a-f]{64}$/i;
const COMMIT_RE = /^[0-9a-f]{40}$/i;
const REPOSITORY = "VortXTV/VortX";
const CANONICAL_ALTSTORE = "https://vortx.tv/altstore.json";

function jsonText(value) {
  return `${JSON.stringify(value, null, 2)}\n`;
}

function jsonResponse(value, status = 200, extra = {}) {
  return new Response(JSON.stringify(value), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", ...extra },
  });
}

function failure(status, code, message) {
  return jsonResponse({ error: code, message }, status, { "cache-control": "no-store" });
}

function text(value, field) {
  if (typeof value !== "string" || value.length === 0) throw new Error(`${field} is required`);
  return value;
}

function positiveInteger(value, field) {
  if (!Number.isInteger(value) || value <= 0) throw new Error(`${field} must be a positive integer`);
  return value;
}

function digest(value, field) {
  const candidate = String(value || "").replace(/^sha256:/i, "").toLowerCase();
  if (!SHA_RE.test(candidate)) throw new Error(`${field} must be a SHA-256 digest`);
  return candidate;
}

function releaseAssetURL(tag, name) {
  return `https://github.com/${REPOSITORY}/releases/download/${tag}/${name}`;
}

function expectedAssetURL(url, label) {
  const parsed = new URL(text(url, `${label || "asset"} URL`));
  if (parsed.protocol !== "https:" || parsed.hostname !== "github.com" || parsed.search || parsed.hash) {
    throw new Error("asset URL must be an immutable HTTPS GitHub URL");
  }
  return parsed.href;
}

async function sha256(value) {
  const bytes = typeof value === "string" ? new TextEncoder().encode(value) : value;
  const hash = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(hash)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function hmac(secret, body) {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(body));
  return [...new Uint8Array(signature)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

function constantTimeEqual(left, right) {
  if (typeof left !== "string" || typeof right !== "string" || left.length !== right.length) return false;
  let different = 0;
  for (let index = 0; index < left.length; index += 1) different |= left.charCodeAt(index) ^ right.charCodeAt(index);
  return different === 0;
}

async function authenticate(request, body, env) {
  const secret = env.RELEASE_FEED_RECEIPT_SECRET;
  if (!secret) return false;
  const supplied = String(request.headers.get("x-vortx-receipt") || "").replace(/^sha256=/i, "").toLowerCase();
  if (!/^[0-9a-f]{64}$/.test(supplied)) return false;
  return constantTimeEqual(supplied, await hmac(secret, body));
}

function parseJSON(value, field) {
  try {
    return JSON.parse(value);
  } catch {
    throw new Error(`${field} is not valid JSON`);
  }
}

function appFor(source, bundleIdentifier) {
  if (!source || !Array.isArray(source.apps)) throw new Error("source apps[] is required");
  const matches = source.apps.filter((app) => app && app.bundleIdentifier === bundleIdentifier);
  if (matches.length !== 1) throw new Error(`source must contain exactly one ${bundleIdentifier} app`);
  return matches[0];
}

function validateSource(source, manifest) {
  const version = String(manifest.version);
  const targets = [
    { bundle: "com.stremiox.app.native", name: `VortX-iOS-${manifest.tag}-ci.ipa`, minOS: "16.0" },
    { bundle: "com.stremiox.tv", name: `VortX-tvOS-${manifest.tag}-ci.ipa`, minOS: "18.0" },
  ];
  for (const target of targets) {
    const app = appFor(source, target.bundle);
    if (!Array.isArray(app.versions) || app.versions.length === 0) throw new Error(`${target.bundle} versions[] is required`);
    const current = app.versions[0];
    const asset = target.bundle === "com.stremiox.tv" ? manifest.assets.tvos : manifest.assets.ios;
    if (String(current.buildVersion) !== String(manifest.build) || current.version !== version || current.minOSVersion !== target.minOS) {
      throw new Error(`${target.bundle} current identity does not match the staged build`);
    }
    if (current.downloadURL !== asset.url || Number(current.size) !== asset.size || String(current.sha256).toLowerCase() !== asset.sha256) {
      throw new Error(`${target.bundle} current asset metadata differs from the staged receipt`);
    }
    const builds = app.versions.map((entry) => Number(entry && entry.buildVersion));
    if (builds.some((build) => !Number.isInteger(build) || build <= 0) || new Set(builds).size !== builds.length) {
      throw new Error(`${target.bundle} history contains invalid or duplicate builds`);
    }
  }
}

function validateChecksum(checksumText, assets) {
  const records = new Map();
  for (const rawLine of checksumText.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line) continue;
    const match = line.match(/^([0-9a-f]{64})\s+\*?(?:out\/)?([^\s]+)$/i);
    if (!match) throw new Error("checksum file contains an invalid line");
    records.set(match[2], match[1].toLowerCase());
  }
  for (const asset of Object.values(assets)) {
    if (records.get(asset.checksumName) !== asset.sha256) throw new Error(`checksum does not match ${asset.name}`);
  }
}

function validateAndroidArtifact(android, manifest) {
  if (!android || android.signed !== true || typeof android.name !== "string" || typeof android.checksumName !== "string" || typeof android.signer !== "string" || android.signer.length === 0) {
    throw new Error("Android must be a signed artifact with a package name, checksum name, and signer");
  }
  const url = expectedAssetURL(android.url, "Android");
  if (url !== releaseAssetURL(manifest.tag, android.name) || android.apk !== url) throw new Error("Android URL is not bound to the immutable release asset");
  positiveInteger(Number(android.build), "Android build");
  if (Number(android.build) !== Number(manifest.build) || android.tag !== manifest.tag || android.version !== manifest.version || android.name !== manifest.name || android.notes !== manifest.notes || Boolean(android.prerelease) !== Boolean(manifest.prerelease)) {
    throw new Error("Android identity does not match the staged release");
  }
  positiveInteger(Number(android.size), "Android size");
  android.sha256 = digest(android.sha256, "Android sha256");
  positiveInteger(Number(android.assetId), "Android assetId");
  return android;
}

function validateAppcast(appcast, manifest) {
  if (!appcast || Number(appcast.schemaVersion) !== ARTIFACT_SCHEMA || appcast._generatedFromTag !== manifest.tag || appcast._generatedFromCommit !== manifest.sourceCommit) {
    throw new Error("appcast identity does not match the staged receipt");
  }
  const expected = {
    ios: { asset: manifest.assets.ios, altstore: CANONICAL_ALTSTORE, type: "ipa" },
    tvos: { asset: manifest.assets.tvos, altstore: null, type: "ipa" },
    mac: { asset: manifest.assets.mac, altstore: null, type: "dmg" },
  };
  for (const [platform, requirement] of Object.entries(expected)) {
    const entry = appcast[platform];
    if (!entry || entry.tag !== manifest.tag || entry.version !== manifest.version || Number(entry.build) !== manifest.build || entry.name !== manifest.name || entry.notes !== manifest.notes || Boolean(entry.prerelease) !== Boolean(manifest.prerelease) || entry.ipa !== requirement.asset.url || entry.url !== requirement.asset.url || Number(entry.size) !== requirement.asset.size || String(entry.sha256).toLowerCase() !== requirement.asset.sha256 || entry.altstore !== requirement.altstore || entry.artifactType !== requirement.type) {
      throw new Error(`${platform} appcast metadata differs from the staged receipt`);
    }
  }
  if (manifest.android === null) {
    if (appcast.android !== null) throw new Error("Android must be null until a signed artifact is recorded");
    return;
  }
  const android = validateAndroidArtifact(manifest.android, manifest);
  const entry = appcast.android;
  if (!entry || entry.signed !== true || entry.tag !== manifest.tag || entry.version !== manifest.version || Number(entry.build) !== manifest.build || entry.name !== manifest.name || entry.notes !== manifest.notes || Boolean(entry.prerelease) !== Boolean(manifest.prerelease) || entry.apk !== android.url || entry.url !== android.url || Number(entry.size) !== android.size || String(entry.sha256).toLowerCase() !== android.sha256 || entry.signer !== android.signer) {
    throw new Error("Android appcast metadata differs from the signed staged artifact");
  }
}

async function validateStage(payload) {
  if (Number(payload.schemaVersion) !== ARTIFACT_SCHEMA || payload.action !== "stage") throw new Error("unsupported feed receipt schema or action");
  const manifest = payload.manifest;
  if (!manifest || Number(manifest.schemaVersion) !== ARTIFACT_SCHEMA || !RELEASE_TAG_RE.test(String(manifest.tag || ""))) throw new Error("manifest identity is invalid");
  positiveInteger(manifest.build, "manifest build");
  text(manifest.name, "manifest name");
  text(manifest.notes, "manifest notes");
  text(manifest.generation, "manifest generation");
  text(manifest.sourceCommit, "manifest sourceCommit");
  if (!COMMIT_RE.test(manifest.sourceCommit)) throw new Error("manifest sourceCommit is not immutable");
  if (manifest.releaseId === null || manifest.releaseId === undefined) throw new Error("manifest releaseId is required for an immutable release receipt");
  positiveInteger(Number(manifest.releaseId), "manifest releaseId");
  if (manifest.android !== null) validateAndroidArtifact(manifest.android, manifest);
  const sourceText = text(payload.source, "source");
  const appcastText = text(payload.appcast, "appcast");
  const checksumText = text(payload.checksum, "checksum");
  const source = parseJSON(sourceText, "source");
  const appcast = parseJSON(appcastText, "appcast");
  if (jsonText(source) !== sourceText || jsonText(appcast) !== appcastText) throw new Error("feed JSON bytes are not canonical artifact bytes");
  const assets = manifest.assets;
  if (!assets || !assets.ios || !assets.tvos || !assets.tvosLite || !assets.mac) throw new Error("manifest must include all Apple artifacts");
  for (const asset of Object.values(assets)) {
    text(asset.name, "asset name");
    text(asset.checksumName, "checksum name");
    asset.url = expectedAssetURL(asset.url, asset.name);
    if (asset.url !== releaseAssetURL(manifest.tag, asset.name) || asset.state !== "uploaded") throw new Error(`asset ${asset.name} is not bound to the release`);
    positiveInteger(asset.size, `asset ${asset.name} size`);
    asset.sha256 = digest(asset.sha256, `asset ${asset.name} sha256`);
    positiveInteger(Number(asset.assetId), `asset ${asset.name} assetId`);
  }
  validateChecksum(checksumText, manifest.android === null ? assets : { ...assets, android: manifest.android });
  validateSource(source, manifest);
  validateAppcast(appcast, manifest);
  const sourceSha = await sha256(sourceText);
  const appcastSha = await sha256(appcastText);
  const checksumSha = await sha256(checksumText);
  const feedSha = await sha256(`${sourceText}\n${appcastText}\n${checksumText}`);
  if (manifest.sourceSha256 !== sourceSha || manifest.appcastSha256 !== appcastSha || manifest.checksumSha256 !== checksumSha || manifest.feedSha256 !== feedSha || manifest.generation !== `${manifest.tag}:${manifest.build}:${feedSha}`) {
    throw new Error("manifest digest does not match staged feed bytes");
  }
  return { manifest, sourceText, appcastText, checksumText };
}

async function readBody(request) {
  const contentLength = Number(request.headers.get("content-length") || 0);
  if (contentLength > MAX_BODY_BYTES) throw new Error("receipt body is too large");
  const body = await request.text();
  if (new TextEncoder().encode(body).byteLength > MAX_BODY_BYTES) throw new Error("receipt body is too large");
  return body;
}

async function coordinatorRequest(request, env, payload) {
  if (!env.COORDINATOR) return failure(503, "coordinator-unavailable", "feed coordinator binding is not configured");
  const id = env.COORDINATOR.idFromName("release-feed");
  return env.COORDINATOR.get(id).fetch(new Request("https://coordinator.internal/", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(payload),
  }));
}

async function stageReceipt(payload, env) {
  return coordinatorRequest({ method: "POST" }, env, payload);
}

export class FeedCoordinator {
  constructor(state, env) {
    this.state = state;
    this.env = env;
  }

  async fetch(request) {
    const payload = await request.json();
    const current = await this.env.LASTGOOD.get(ACTIVE_KEY, { type: "json" });
    const currentGeneration = current?.manifest?.generation || null;
    if (payload.action === "stage") {
      const stagedKey = `${STAGED_PREFIX}${payload.manifest.releaseId}`;
      const existing = await this.env.LASTGOOD.get(stagedKey, { type: "json" });
      if (existing) {
        if (existing.manifest.generation !== payload.manifest.generation) return failure(409, "staged-conflict", "release ID already has a different feed generation");
        return jsonResponse({ staged: true, generation: existing.manifest.generation, releaseId: existing.manifest.releaseId });
      }
      if (current && Number(payload.manifest.build) < Number(current.manifest.build)) {
        return failure(409, "build-order", "a staged release cannot be older than the active generation");
      }
      await this.env.LASTGOOD.put(stagedKey, JSON.stringify(payload));
      return jsonResponse({ staged: true, generation: payload.manifest.generation, releaseId: payload.manifest.releaseId });
    }
    if (payload.action === "promote") {
      if (payload.expectedActiveGeneration === undefined || payload.expectedActiveGeneration !== currentGeneration) {
        return failure(409, "active-generation-conflict", "active generation changed before promotion");
      }
      const staged = await this.env.LASTGOOD.get(`${STAGED_PREFIX}${payload.releaseId}`, { type: "json" });
      if (!staged || staged.manifest.generation !== payload.generation || String(staged.manifest.releaseId) !== String(payload.releaseId)) return failure(404, "staged-generation-missing", "requested staged generation is not present");
      if (current) await this.env.LASTGOOD.put(`${ROLLBACK_PREFIX}${payload.generation}`, JSON.stringify(current));
      await this.env.LASTGOOD.put(ACTIVE_KEY, JSON.stringify(staged));
      return jsonResponse({ promoted: true, generation: payload.generation, previousGeneration: currentGeneration });
    }
    if (payload.action === "rollback") {
      if (!text(payload.expectedCurrentGeneration, "expectedCurrentGeneration") || !text(payload.restoreGeneration, "restoreGeneration")) return failure(400, "rollback-contract", "rollback requires exact current and restore generations");
      if (payload.expectedCurrentGeneration !== currentGeneration) return failure(409, "rollback-generation-conflict", "active generation changed before rollback");
      const previous = payload.restoreGeneration === "none" ? null : await this.env.LASTGOOD.get(`${ROLLBACK_PREFIX}${payload.expectedCurrentGeneration}`, { type: "json" });
      if (payload.restoreGeneration !== "none" && previous?.manifest?.generation !== payload.restoreGeneration) return failure(409, "rollback-target-mismatch", "trusted rollback generation is unavailable");
      if (previous) await this.env.LASTGOOD.put(ACTIVE_KEY, JSON.stringify(previous));
      else await this.env.LASTGOOD.delete(ACTIVE_KEY);
      return jsonResponse({ rolledBack: true, generation: payload.restoreGeneration });
    }
    return failure(400, "coordinator-action", "unsupported coordinator action");
  }
}

async function handleReceipt(request, env) {
  if (request.method !== "POST") return failure(405, "method", "receipt endpoint accepts POST only");
  const body = await readBody(request);
  if (!(await authenticate(request, body, env))) return failure(401, "receipt-auth", "authenticated release receipt required");
  const payload = parseJSON(body, "receipt");
  if (payload.action === "stage") {
    const validated = await validateStage(payload);
    return stageReceipt({ ...payload, ...validated }, env);
  }
  if (payload.action === "promote" || payload.action === "rollback") return coordinatorRequest(request, env, payload);
  return failure(400, "receipt-action", "unsupported receipt action");
}

async function handlePublic(pathname, env) {
  const active = await env.LASTGOOD.get(ACTIVE_KEY, { type: "json" });
  if (!active || !active.manifest?.generation) return failure(503, "feed-unavailable", "no verified feed generation is active");
  const body = pathname === "/appcast.json" ? active.appcastText : active.sourceText;
  const generation = active.manifest.generation;
  return new Response(body, {
    status: 200,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": `public, max-age=${MAX_PUBLIC_AGE}, s-maxage=${MAX_PUBLIC_AGE}, must-revalidate`,
      etag: `"${generation}"`,
      "x-vortx-feed-generation": generation,
      "x-vortx-feed-state": "active",
    },
  });
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    try {
      if (url.pathname === "/__release/receipt") return await handleReceipt(request, env);
      if (request.method !== "GET") return failure(405, "method", "feed routes accept GET only");
      if (url.pathname === "/altstore.json" || url.pathname === "/vortx-altstore.json" || url.pathname === "/appcast.json") return await handlePublic(url.pathname, env);
      return failure(404, "route", "unknown feed route");
    } catch (error) {
      return failure(503, "feed-validation", error instanceof Error ? error.message : "feed validation failed");
    }
  },
};
