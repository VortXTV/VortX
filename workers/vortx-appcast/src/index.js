// Durable Object storage is the authority for every mutable release state.  Do
// not move these records back to KV: a KV read/put pair cannot provide the
// compare-and-swap semantics a release promotion needs.
const ACTIVE_KEY = "active";
const STAGED_RELEASE_PREFIX = "staged:release:";
const STAGED_GENERATION_PREFIX = "staged:generation:";
const STAGED_TAG_PREFIX = "staged:tag:";
const ROLLBACK_PREFIX = "rollback:";
const AUDIT_PREFIX = "audit:";
const QUARANTINE_PREFIX = "quarantine:legacy:";
const OPERATION_PREFIX = "operation:";
const ROLLED_BACK_PREFIX = "rolled-back:";
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

function canonicalValue(value) {
  if (Array.isArray(value)) return value.map(canonicalValue);
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.keys(value).sort().map((key) => [key, canonicalValue(value[key])]));
  }
  return value;
}

function canonicalReceiptText(payload) {
  // Authentication covers the bytes sent by the caller.  This digest covers
  // the semantic receipt and remains stable across harmless JSON key order.
  return JSON.stringify(canonicalValue({
    action: payload.action,
    manifest: payload.manifest,
    source: payload.source,
    appcast: payload.appcast,
    checksum: payload.checksum,
  }));
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
  if (Number(payload.schemaVersion) !== ARTIFACT_SCHEMA || !["stage", "repair"].includes(payload.action)) throw new Error("unsupported feed receipt schema or action");
  const manifest = payload.manifest;
  if (!manifest || Number(manifest.schemaVersion) !== ARTIFACT_SCHEMA || !RELEASE_TAG_RE.test(String(manifest.tag || ""))) throw new Error("manifest identity is invalid");
  if (manifest.prerelease !== true || !String(manifest.tag).includes("-")) throw new Error("release feed accepts immutable prerelease receipts only");
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
  return {
    manifest,
    sourceText,
    appcastText,
    checksumText,
    receiptSha256: await sha256(canonicalReceiptText(payload)),
  };
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
    if (payload.action === "read-active") {
      const active = await this.state.storage.get(ACTIVE_KEY);
      return jsonResponse({ active: active || null });
    }
    return this.state.storage.transaction(async (storage) => {
      const current = await storage.get(ACTIVE_KEY);
      const currentGeneration = current?.manifest?.generation || null;
      if (payload.action === "stage") {
        const releaseKey = `${STAGED_RELEASE_PREFIX}${payload.manifest.releaseId}`;
        const generationKey = `${STAGED_GENERATION_PREFIX}${payload.manifest.generation}`;
        const tagKey = `${STAGED_TAG_PREFIX}${payload.manifest.tag}`;
        const [byRelease, byGeneration, byTag] = await Promise.all([storage.get(releaseKey), storage.get(generationKey), storage.get(tagKey)]);
        if (byRelease || byGeneration || byTag) {
          const existing = byRelease || byGeneration || byTag;
          if (existing.manifest.generation !== payload.manifest.generation || existing.receiptSha256 !== payload.receiptSha256) return failure(409, "staged-conflict", "release or generation is already bound to different receipt bytes");
          return jsonResponse({ staged: true, idempotent: true, generation: existing.manifest.generation, releaseId: existing.manifest.releaseId, receiptSha256: existing.receiptSha256 });
        }
        if (current && Number(payload.manifest.build) < Number(current.manifest.build)) return failure(409, "build-order", "a staged release cannot be older than the active generation");
        if (current && Number(payload.manifest.build) === Number(current.manifest.build) && payload.manifest.tag !== current.manifest.tag) return failure(409, "build-tag-conflict", "a build is permanently bound to one release tag");
        if (current && payload.manifest.tag === current.manifest.tag && Number(payload.manifest.build) !== Number(current.manifest.build)) return failure(409, "tag-build-conflict", "a release tag is permanently bound to one build");
        await storage.put(releaseKey, payload);
        await storage.put(generationKey, payload);
        await storage.put(tagKey, payload);
        await storage.put(`${AUDIT_PREFIX}stage:${payload.manifest.generation}`, { action: "stage", generation: payload.manifest.generation, releaseId: payload.manifest.releaseId, receiptSha256: payload.receiptSha256 });
        return jsonResponse({ staged: true, generation: payload.manifest.generation, releaseId: payload.manifest.releaseId, receiptSha256: payload.receiptSha256 });
      }
      if (payload.action === "repair") {
        if (current) return failure(409, "repair-active-exists", "integrity repair is only allowed when no durable active receipt exists");
        if (payload.repairReason !== "integrity-repair") return failure(400, "repair-contract", "integrity repair requires the exact repair reason");
        if (!text(payload.operationId, "operationId") || !this.env.LEGACY_OBSERVED_GENERATION || !this.env.LEGACY_OBSERVED_DIGEST || payload.expectedLegacyGeneration !== this.env.LEGACY_OBSERVED_GENERATION || payload.expectedLegacyDigest !== this.env.LEGACY_OBSERVED_DIGEST || payload.manifest.generation === payload.expectedLegacyGeneration) return failure(409, "repair-generation", "integrity repair must bind distinct observed and corrected generations");
        const observed = await this.env.LEGACY_LASTGOOD?.get("feed:active", { type: "json" });
        if (!observed || observed?.manifest?.generation !== payload.expectedLegacyGeneration || await sha256(JSON.stringify(canonicalValue(observed))) !== payload.expectedLegacyDigest) return failure(409, "repair-observed", "frozen legacy receipt does not match the observed migration guard");
        const legacy = payload.legacyRelease;
        if (!legacy || String(legacy.releaseId) !== String(payload.manifest.releaseId) || legacy.tag !== payload.manifest.tag || legacy.sourceCommit !== payload.manifest.sourceCommit || legacy.prerelease !== true || legacy.tagCommit !== payload.manifest.sourceCommit) return failure(400, "repair-identity", "integrity repair release identity does not match the immutable receipt");
        if (payload.manifest.prerelease !== true || !Array.isArray(legacy.assetIds) || legacy.assetIds.length !== Object.keys(payload.manifest.assets).length || !Object.values(payload.manifest.assets).every((asset) => legacy.assetIds.includes(Number(asset.assetId)))) return failure(400, "repair-assets", "integrity repair does not bind every immutable release asset");
        const quarantineKey = `${QUARANTINE_PREFIX}${payload.expectedLegacyGeneration}`;
        if (await storage.get(quarantineKey)) return failure(409, "repair-already-recorded", "legacy generation is already quarantined");
        await storage.put(ACTIVE_KEY, payload);
        await storage.put(`${STAGED_RELEASE_PREFIX}${payload.manifest.releaseId}`, payload);
        await storage.put(`${STAGED_GENERATION_PREFIX}${payload.manifest.generation}`, payload);
        await storage.put(`${STAGED_TAG_PREFIX}${payload.manifest.tag}`, payload);
        await storage.put(quarantineKey, { state: "repaired-from-legacy", generation: payload.expectedLegacyGeneration, observedDigest: payload.expectedLegacyDigest, releaseId: payload.manifest.releaseId, receiptSha256: payload.receiptSha256 });
        await storage.put(`${OPERATION_PREFIX}${payload.operationId}`, { action: "repair", operationId: payload.operationId, receiptSha256: payload.receiptSha256 });
        await storage.put(`${AUDIT_PREFIX}repair:${payload.manifest.generation}`, { action: "repair", operationId: payload.operationId, generation: payload.manifest.generation, observedGeneration: payload.expectedLegacyGeneration, observedDigest: payload.expectedLegacyDigest, receiptSha256: payload.receiptSha256 });
        return jsonResponse({ repaired: true, generation: payload.manifest.generation, releaseId: payload.manifest.releaseId, receiptSha256: payload.receiptSha256 });
      }
      if (payload.action === "promote") {
        if (!text(payload.operationId, "operationId")) return failure(400, "operation-contract", "promotion requires a write-once operation ID");
        const staged = await storage.get(`${STAGED_RELEASE_PREFIX}${payload.releaseId}`);
        if (!staged || staged.manifest.generation !== payload.generation || String(staged.manifest.releaseId) !== String(payload.releaseId)) return failure(404, "staged-generation-missing", "requested staged generation is not present");
        if (await storage.get(`${ROLLED_BACK_PREFIX}${staged.manifest.generation}`)) return failure(409, "generation-terminal", "a rolled-back generation cannot be promoted again");
        const priorOperation = await storage.get(`${OPERATION_PREFIX}${payload.operationId}`);
        if (priorOperation) {
          const sameOperation =
            priorOperation.action === "promote" &&
            String(priorOperation.releaseId) === String(payload.releaseId) &&
            priorOperation.generation === payload.generation &&
            priorOperation.receiptSha256 === staged.receiptSha256;
          const exactTargetIsActive =
            currentGeneration === staged.manifest.generation &&
            String(current?.manifest?.releaseId) === String(staged.manifest.releaseId) &&
            current?.receiptSha256 === staged.receiptSha256;
          if (!sameOperation || !exactTargetIsActive) {
            return failure(409, "operation-state-conflict", "promotion operation cannot be replayed in the current state");
          }
          return jsonResponse({ promoted: true, idempotent: true, generation: currentGeneration, previousGeneration: currentGeneration, receiptSha256: current.receiptSha256 });
        }
        if (payload.expectedActiveGeneration === undefined || payload.expectedActiveGeneration !== currentGeneration) return failure(409, "active-generation-conflict", "active generation changed before promotion");
        if (currentGeneration === staged.manifest.generation) {
          if (String(current.manifest.releaseId) !== String(staged.manifest.releaseId) || current.receiptSha256 !== staged.receiptSha256) return failure(409, "active-receipt-conflict", "active generation is not the exact staged receipt");
          await storage.put(`${OPERATION_PREFIX}${payload.operationId}`, { action: "promote", operationId: payload.operationId, generation: currentGeneration, releaseId: payload.releaseId, receiptSha256: current.receiptSha256, idempotent: true });
          return jsonResponse({ promoted: true, idempotent: true, generation: currentGeneration, previousGeneration: currentGeneration, receiptSha256: current.receiptSha256 });
        }
        if (current && Number(staged.manifest.build) < Number(current.manifest.build)) return failure(409, "promote-build-order", "a staged generation cannot downgrade a newer active build");
        if (current && Number(staged.manifest.build) === Number(current.manifest.build) && staged.manifest.tag !== current.manifest.tag) return failure(409, "promote-build-tag-conflict", "a build is permanently bound to one active release tag");
        if (current && staged.manifest.tag === current.manifest.tag && Number(staged.manifest.build) !== Number(current.manifest.build)) return failure(409, "promote-tag-build-conflict", "an active release tag is permanently bound to one build");
        if (current) await storage.put(`${ROLLBACK_PREFIX}${payload.generation}`, current);
        await storage.put(ACTIVE_KEY, staged);
        await storage.put(`${OPERATION_PREFIX}${payload.operationId}`, { action: "promote", operationId: payload.operationId, generation: payload.generation, releaseId: payload.releaseId, receiptSha256: staged.receiptSha256 });
        await storage.put(`${AUDIT_PREFIX}promote:${payload.generation}`, { action: "promote", operationId: payload.operationId, generation: payload.generation, previousGeneration: currentGeneration, receiptSha256: staged.receiptSha256 });
        return jsonResponse({ promoted: true, generation: payload.generation, previousGeneration: currentGeneration, receiptSha256: staged.receiptSha256 });
      }
      if (payload.action === "rollback") {
        if (!text(payload.expectedCurrentGeneration, "expectedCurrentGeneration") || !text(payload.restoreGeneration, "restoreGeneration")) return failure(400, "rollback-contract", "rollback requires exact current and restore generations");
        if (payload.expectedCurrentGeneration !== currentGeneration) return failure(409, "rollback-generation-conflict", "active generation changed before rollback");
        const previous = payload.restoreGeneration === "none" ? null : await storage.get(`${ROLLBACK_PREFIX}${payload.expectedCurrentGeneration}`);
        if (payload.restoreGeneration !== "none" && previous?.manifest?.generation !== payload.restoreGeneration) return failure(409, "rollback-target-mismatch", "trusted rollback generation is unavailable");
        if (previous) await storage.put(ACTIVE_KEY, previous); else await storage.delete(ACTIVE_KEY);
        await storage.put(`${ROLLED_BACK_PREFIX}${payload.expectedCurrentGeneration}`, { generation: payload.expectedCurrentGeneration, restoreGeneration: payload.restoreGeneration });
        await storage.put(`${AUDIT_PREFIX}rollback:${payload.expectedCurrentGeneration}`, { action: "rollback", generation: payload.restoreGeneration });
        return jsonResponse({ rolledBack: true, generation: payload.restoreGeneration });
      }
      return failure(400, "coordinator-action", "unsupported coordinator action");
    });
  }
}

async function handleReceipt(request, env) {
  if (request.method !== "POST") return failure(405, "method", "receipt endpoint accepts POST only");
  const body = await readBody(request);
  if (!(await authenticate(request, body, env))) return failure(401, "receipt-auth", "authenticated release receipt required");
  const payload = parseJSON(body, "receipt");
  if (payload.action === "stage" || payload.action === "repair") {
    const validated = await validateStage(payload);
    return stageReceipt({ ...payload, ...validated }, env);
  }
  if (payload.action === "promote" || payload.action === "rollback") return coordinatorRequest(request, env, payload);
  return failure(400, "receipt-action", "unsupported receipt action");
}

async function handlePublic(request, pathname, env) {
  const response = await coordinatorRequest(new Request("https://coordinator.internal/"), env, { action: "read-active" });
  if (!response.ok) return response;
  const { active } = await response.json();
  const frozen = !active || !active.manifest?.generation ? await env.LEGACY_LASTGOOD?.get("feed:active", { type: "json" }) : null;
  const selected = active || frozen;
  if (!selected || !selected.manifest?.generation) return failure(503, "feed-unavailable", "no verified feed generation is active");
  const body = pathname === "/appcast.json" ? selected.appcastText : selected.sourceText;
  const generation = selected.manifest.generation;
  const headers = {
      "content-type": "application/json; charset=utf-8",
      "cache-control": `public, max-age=${MAX_PUBLIC_AGE}, s-maxage=${MAX_PUBLIC_AGE}, must-revalidate`,
      etag: `"${generation}"`,
      "x-vortx-feed-generation": generation,
      "x-vortx-feed-state": "active",
    };
  // Conditional GET: an unchanged generation answers 304 so source clients and
  // health probes can refresh without re-downloading identical bytes.
  const clientEtag = request.headers.get("if-none-match");
  if (clientEtag && clientEtag.trim() === `"${generation}"`) return new Response(null, { status: 304, headers });
  // HEAD serves the exact metadata of the GET (including content-length via
  // the runtime) with an empty body.
  if (request.method === "HEAD") return new Response(null, { status: 200, headers });
  return new Response(body, {
    status: 200,
    headers,
  });
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    try {
      if (url.pathname === "/__release/receipt") return await handleReceipt(request, env);
      const isFeedRoute = url.pathname === "/altstore.json" || url.pathname === "/vortx-altstore.json" || url.pathname === "/appcast.json";
      if (isFeedRoute && (request.method === "GET" || request.method === "HEAD")) return await handlePublic(request, url.pathname, env);
      if (isFeedRoute) return failure(405, "method", "feed routes accept GET and HEAD only");
      return failure(404, "route", "unknown feed route");
    } catch (error) {
      return failure(503, "feed-validation", error instanceof Error ? error.message : "feed validation failed");
    }
  },
};
