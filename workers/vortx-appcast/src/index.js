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
const ANDROID_SIGNER_SHA256 = "FC22B87ECD9E4FA26930A1C3E227D8F7D918C646B216032B5DA820EF1AC218CA";

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

function validateReleaseAssetEvidence(asset, expectedName, expectedURL, field) {
  if (!asset || asset.name !== expectedName || asset.url !== expectedURL) throw new Error(`${field} release asset identity is invalid`);
  positiveInteger(Number(asset.assetId), `${field} assetId`);
  positiveInteger(Number(asset.size), `${field} size`);
  asset.sha256 = digest(asset.sha256, `${field} sha256`);
  return asset;
}

function checksumRecord(checksumText, expectedName) {
  const records = checksumText.split(/\r?\n/).filter(Boolean).map((line) => line.match(/^([0-9a-f]{64})\s+\*?([^\s]+)$/i));
  if (records.some((record) => !record)) throw new Error("Android checksum evidence contains an invalid line");
  const matches = records.filter((record) => record[2] === expectedName);
  if (matches.length !== 1) throw new Error(`Android checksum evidence must contain exactly one ${expectedName} record`);
  return matches[0][1].toLowerCase();
}

function provenanceBindsAPK(provenanceText, name) {
  const fingerprint = ANDROID_SIGNER_SHA256.match(/../g).join(":");
  const section = provenanceText.split(`verified APK: ${name}\n`)[1]?.split(/\nverified (?:APK|AAB): /)[0] || "";
  return section.split(/\r?\n/).some((line) => line.trim().toUpperCase() === `SIGNER SHA-256: ${fingerprint}`);
}

async function buildAndroidAugmentation(payload, current) {
  if (!current?.manifest || !current.receiptSha256) throw new Error("Android augmentation requires a durable active receipt");
  if (
    payload.expectedActiveGeneration !== current.manifest.generation ||
    payload.expectedReceiptSha256 !== current.receiptSha256 ||
    payload.expectedSourceSha256 !== current.manifest.sourceSha256 ||
    payload.expectedAppcastSha256 !== current.manifest.appcastSha256
  ) throw new Error("Android augmentation active receipt CAS does not match");
  if (String(payload.releaseId) !== String(current.manifest.releaseId) || payload.releaseTag !== current.manifest.tag) throw new Error("Android augmentation release identity does not match the active receipt");
  if (current.manifest.android !== null) throw new Error("Android augmentation requires a null manifest Android entry");
  const currentAppcast = parseJSON(current.appcastText, "active appcast");
  if (currentAppcast.android !== null) throw new Error("Android augmentation requires a null appcast Android entry");

  const version = current.manifest.version;
  const tag = current.manifest.tag;
  const names = {
    full: `VortX-${version}-full-mpv-universal.apk`,
    play: `VortX-${version}-play-media3-universal.apk`,
    checksum: "SHA256SUMS-android.txt",
    provenance: "SIGNING_PROVENANCE.txt",
  };
  const evidence = payload.evidence;
  if (!evidence || !evidence.assets) throw new Error("Android augmentation release evidence is required");
  const releaseURL = (name) => releaseAssetURL(tag, name);
  const fullAsset = validateReleaseAssetEvidence(evidence.assets.full, names.full, releaseURL(names.full), "Android full");
  const playAsset = validateReleaseAssetEvidence(evidence.assets.play, names.play, releaseURL(names.play), "Android play");
  const checksumAsset = validateReleaseAssetEvidence(evidence.assets.checksum, names.checksum, releaseURL(names.checksum), "Android checksum");
  const provenanceAsset = validateReleaseAssetEvidence(evidence.assets.provenance, names.provenance, releaseURL(names.provenance), "Android provenance");
  if (new Set([fullAsset.assetId, playAsset.assetId, checksumAsset.assetId, provenanceAsset.assetId]).size !== 4) throw new Error("Android release evidence asset IDs must be distinct");
  const androidChecksumText = text(evidence.checksumText, "Android checksum evidence");
  const provenanceText = text(evidence.provenanceText, "Android provenance evidence");
  if (new TextEncoder().encode(androidChecksumText).byteLength !== checksumAsset.size || await sha256(androidChecksumText) !== checksumAsset.sha256) throw new Error("Android checksum evidence bytes do not match the immutable release asset");
  if (new TextEncoder().encode(provenanceText).byteLength !== provenanceAsset.size || await sha256(provenanceText) !== provenanceAsset.sha256) throw new Error("Android provenance evidence bytes do not match the immutable release asset");
  if (checksumRecord(androidChecksumText, names.full) !== fullAsset.sha256 || checksumRecord(androidChecksumText, names.play) !== playAsset.sha256) throw new Error("Android APK digests do not match checksum evidence");
  if (
    !provenanceBindsAPK(provenanceText, names.full) ||
    !provenanceBindsAPK(provenanceText, names.play) ||
    !provenanceText.includes(`release tag: ${tag}`) ||
    !provenanceText.includes(`release tag commit: ${current.manifest.sourceCommit}`) ||
    !provenanceText.includes(`source commit: ${current.manifest.sourceCommit}`)
  ) throw new Error("Android signing provenance does not bind both APKs, release identity, and production signer");

  const androidEntry = (engine, asset) => ({
    tag,
    version,
    build: Number(current.manifest.build),
    name: current.manifest.name,
    notes: current.manifest.notes,
    prerelease: Boolean(current.manifest.prerelease),
    applicationId: "com.vortx.android",
    engine,
    artifactType: "apk",
    signed: true,
    url: asset.url,
    size: Number(asset.size),
    sha256: asset.sha256,
    signer: ANDROID_SIGNER_SHA256,
  });
  const android = {
    full: androidEntry("mpv", fullAsset),
    play: androidEntry("media3", playAsset),
  };
  const appcastText = jsonText({ ...currentAppcast, android });
  const sourceText = current.sourceText;
  const checksumText = current.checksumText;
  const sourceSha256 = await sha256(sourceText);
  const appcastSha256 = await sha256(appcastText);
  const checksumSha256 = await sha256(checksumText);
  const feedSha256 = await sha256(`${sourceText}\n${appcastText}\n${checksumText}`);
  const manifest = {
    ...current.manifest,
    generation: `${tag}:${current.manifest.build}:${feedSha256}`,
    feedSha256,
    sourceSha256,
    appcastSha256,
    checksumSha256,
    android,
  };
  const successor = { manifest, sourceText, appcastText, checksumText };
  successor.receiptSha256 = await sha256(JSON.stringify(canonicalValue(successor)));
  return successor;
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
  const tagIsPrerelease = String(manifest.tag).includes("-");
  if (typeof manifest.prerelease !== "boolean" || manifest.prerelease !== tagIsPrerelease) {
    throw new Error("manifest prerelease state must match the release tag");
  }
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
    // LEGACY_LASTGOOD is immutable fallback state.  Capture it outside the
    // Durable Object transaction so release serialization never waits on KV.
    const legacySnapshot = await this.env.LEGACY_LASTGOOD?.get("feed:active", { type: "json" });
    let legacyPredecessor = null;
    let legacyBootstrapInvalid = false;
    if (legacySnapshot) {
      try {
        // Older frozen receipts predate receiptSha256.  Validate their exact
        // canonical artifacts and derive the same semantic digest used by new
        // durable receipts before they are eligible for migration.
        legacyPredecessor = await validateStage(legacySnapshot);
      } catch {
        legacyBootstrapInvalid = true;
      }
    }
    return this.state.storage.transaction(async (storage) => {
      const current = await storage.get(ACTIVE_KEY);
      // During the one-time migration, public routes can still serve the
      // immutable last-known-good receipt from KV before the Durable Object
      // has an active record.  Use that exact visible predecessor for CAS and
      // rollback, but only while no durable record exists.
      const predecessor = current || (!current ? legacyPredecessor : null);
      const currentGeneration = predecessor?.manifest?.generation || null;
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
        const observed = legacySnapshot;
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
        if (!current && legacyBootstrapInvalid) return failure(409, "legacy-active-invalid", "frozen legacy receipt cannot be used as a promotion predecessor");
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
            String(predecessor?.manifest?.releaseId) === String(staged.manifest.releaseId) &&
            predecessor?.receiptSha256 === staged.receiptSha256;
          if (!sameOperation || !exactTargetIsActive) {
            return failure(409, "operation-state-conflict", "promotion operation cannot be replayed in the current state");
          }
          if (!current) await storage.put(ACTIVE_KEY, staged);
          return jsonResponse({ promoted: true, idempotent: true, generation: currentGeneration, previousGeneration: currentGeneration, receiptSha256: staged.receiptSha256 });
        }
        if (payload.expectedActiveGeneration === undefined || payload.expectedActiveGeneration !== currentGeneration) return failure(409, "active-generation-conflict", "active generation changed before promotion");
        if (currentGeneration === staged.manifest.generation) {
          if (String(predecessor.manifest.releaseId) !== String(staged.manifest.releaseId) || predecessor.receiptSha256 !== staged.receiptSha256) return failure(409, "active-receipt-conflict", "active generation is not the exact staged receipt");
          if (!current) await storage.put(ACTIVE_KEY, staged);
          await storage.put(`${OPERATION_PREFIX}${payload.operationId}`, { action: "promote", operationId: payload.operationId, generation: currentGeneration, releaseId: payload.releaseId, receiptSha256: staged.receiptSha256, idempotent: true });
          return jsonResponse({ promoted: true, idempotent: true, generation: currentGeneration, previousGeneration: currentGeneration, receiptSha256: staged.receiptSha256 });
        }
        if (predecessor && Number(staged.manifest.build) < Number(predecessor.manifest.build)) return failure(409, "promote-build-order", "a staged generation cannot downgrade a newer active build");
        if (predecessor && Number(staged.manifest.build) === Number(predecessor.manifest.build) && staged.manifest.tag !== predecessor.manifest.tag) return failure(409, "promote-build-tag-conflict", "a build is permanently bound to one active release tag");
        if (predecessor && staged.manifest.tag === predecessor.manifest.tag && Number(staged.manifest.build) !== Number(predecessor.manifest.build)) return failure(409, "promote-tag-build-conflict", "an active release tag is permanently bound to one build");
        if (predecessor) await storage.put(`${ROLLBACK_PREFIX}${payload.generation}`, predecessor);
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
        await storage.put(`${AUDIT_PREFIX}rollback:${payload.expectedCurrentGeneration}`, { action: "rollback", expectedCurrentGeneration: payload.expectedCurrentGeneration, generation: payload.restoreGeneration });
        return jsonResponse({ rolledBack: true, generation: payload.restoreGeneration });
      }
      if (payload.action === "augment-android") {
        if (!text(payload.operationId, "operationId")) return failure(400, "operation-contract", "Android augmentation requires a write-once operation ID");
        if (!current) return failure(409, "augmentation-active-not-durable", "Android augmentation requires a durable active receipt");
        const priorOperation = await storage.get(`${OPERATION_PREFIX}${payload.operationId}`);
        const priorAudit = await storage.get(`${AUDIT_PREFIX}augment-android:${payload.expectedActiveGeneration}`);
        if (priorAudit) {
          if (priorAudit.operationId !== payload.operationId) return failure(409, "augmentation-already-recorded", "a different Android augmentation is permanently bound to this predecessor");
          const sameOperation =
            priorOperation?.action === "augment-android" &&
            priorOperation.predecessorGeneration === payload.expectedActiveGeneration &&
            priorOperation.successorGeneration === priorAudit.successorGeneration &&
            priorOperation.successorReceiptSha256 === priorAudit.successorReceiptSha256;
          const exactSuccessorIsActive = currentGeneration === priorAudit.successorGeneration && current.receiptSha256 === priorAudit.successorReceiptSha256;
          if (!sameOperation || !exactSuccessorIsActive) return failure(409, "operation-state-conflict", "Android augmentation cannot be replayed in the current state");
          return jsonResponse({ augmented: true, idempotent: true, generation: priorAudit.successorGeneration, previousGeneration: priorAudit.predecessorGeneration, receiptSha256: priorAudit.successorReceiptSha256 });
        }
        let successor;
        try {
          successor = await buildAndroidAugmentation(payload, current);
        } catch (error) {
          return failure(409, "augmentation-evidence-conflict", error instanceof Error ? error.message : "Android augmentation evidence is invalid");
        }
        if (successor.manifest.generation === currentGeneration) return failure(409, "augmentation-generation-conflict", "Android augmentation did not produce a distinct content-addressed generation");
        await storage.put(`${ROLLBACK_PREFIX}${successor.manifest.generation}`, current);
        await storage.put(`${STAGED_GENERATION_PREFIX}${successor.manifest.generation}`, successor);
        await storage.put(ACTIVE_KEY, successor);
        const operation = { action: "augment-android", operationId: payload.operationId, predecessorGeneration: currentGeneration, successorGeneration: successor.manifest.generation, predecessorReceiptSha256: current.receiptSha256, successorReceiptSha256: successor.receiptSha256 };
        await storage.put(`${OPERATION_PREFIX}${payload.operationId}`, operation);
        await storage.put(`${AUDIT_PREFIX}augment-android:${currentGeneration}`, operation);
        return jsonResponse({ augmented: true, generation: successor.manifest.generation, previousGeneration: currentGeneration, receiptSha256: successor.receiptSha256 });
      }
      if (payload.action === "recover") {
        if (!text(payload.operationId, "operationId")) return failure(400, "operation-contract", "recovery requires a write-once operation ID");
        if (payload.recoveryReason !== "post-publication-rollback") return failure(400, "recovery-contract", "recovery requires the exact post-publication rollback reason");
        // Recovery is intentionally more restrictive than promotion.  It can
        // only undo a recorded rollback from a durable active predecessor;
        // a frozen KV fallback is never mutable recovery state.
        if (!current) return failure(409, "recovery-active-not-durable", "recovery requires a durable active predecessor");
        const staged = await storage.get(`${STAGED_RELEASE_PREFIX}${payload.releaseId}`);
        if (!staged || staged.manifest.generation !== payload.generation || String(staged.manifest.releaseId) !== String(payload.releaseId)) return failure(404, "staged-generation-missing", "requested staged generation is not present");
        if (payload.targetSourceSha256 !== staged.manifest.sourceSha256) return failure(409, "recovery-source-mismatch", "recovery source digest is not the exact staged source bytes");
        const priorOperation = await storage.get(`${OPERATION_PREFIX}${payload.operationId}`);
        const priorRecovery = await storage.get(`${AUDIT_PREFIX}recover:${staged.manifest.generation}`);
        const exactTargetIsActive =
          currentGeneration === staged.manifest.generation &&
          String(current.manifest.releaseId) === String(staged.manifest.releaseId) &&
          current.receiptSha256 === staged.receiptSha256;
        if (priorRecovery) {
          if (priorRecovery.operationId !== payload.operationId) return failure(409, "recovery-already-recorded", "a different recovery operation is permanently bound to this generation");
          const sameOperation =
            priorOperation?.action === "recover" &&
            String(priorOperation.releaseId) === String(payload.releaseId) &&
            priorOperation.generation === payload.generation &&
            priorOperation.predecessorGeneration === payload.expectedActiveGeneration &&
            priorOperation.receiptSha256 === staged.receiptSha256 &&
            priorOperation.targetSourceSha256 === staged.manifest.sourceSha256 &&
            priorRecovery.targetSourceSha256 === staged.manifest.sourceSha256;
          if (!sameOperation || !exactTargetIsActive) return failure(409, "operation-state-conflict", "recovery operation cannot be replayed in the current state");
          return jsonResponse({ recovered: true, idempotent: true, generation: staged.manifest.generation, previousGeneration: priorOperation.predecessorGeneration, receiptSha256: staged.receiptSha256 });
        }
        if (payload.expectedActiveGeneration !== currentGeneration) return failure(409, "recovery-generation-conflict", "active generation changed before recovery");
        if (currentGeneration === staged.manifest.generation) return failure(409, "recovery-target-active", "a new recovery operation cannot claim an already active target");
        const terminal = await storage.get(`${ROLLED_BACK_PREFIX}${staged.manifest.generation}`);
        if (!terminal || terminal.generation !== staged.manifest.generation || terminal.restoreGeneration !== currentGeneration) return failure(409, "recovery-terminal-mismatch", "recovery requires the terminal rollback marker for this exact predecessor");
        const rollback = await storage.get(`${ROLLBACK_PREFIX}${staged.manifest.generation}`);
        if (!rollback || rollback.manifest?.generation !== currentGeneration || String(rollback.manifest?.releaseId) !== String(current.manifest.releaseId) || rollback.receiptSha256 !== current.receiptSha256) return failure(409, "recovery-rollback-mismatch", "recovery predecessor does not match the preserved rollback receipt");
        const promoteAudit = await storage.get(`${AUDIT_PREFIX}promote:${staged.manifest.generation}`);
        const rollbackAudit = await storage.get(`${AUDIT_PREFIX}rollback:${staged.manifest.generation}`);
        const promoteOperation = promoteAudit?.operationId ? await storage.get(`${OPERATION_PREFIX}${promoteAudit.operationId}`) : null;
        if (
          !promoteAudit || promoteAudit.action !== "promote" || promoteAudit.generation !== staged.manifest.generation || promoteAudit.previousGeneration !== currentGeneration || promoteAudit.receiptSha256 !== staged.receiptSha256 ||
          !promoteOperation || promoteOperation.action !== "promote" || String(promoteOperation.releaseId) !== String(staged.manifest.releaseId) || promoteOperation.generation !== staged.manifest.generation || promoteOperation.receiptSha256 !== staged.receiptSha256 ||
          !rollbackAudit || rollbackAudit.action !== "rollback" || rollbackAudit.generation !== currentGeneration || (rollbackAudit.expectedCurrentGeneration !== undefined && rollbackAudit.expectedCurrentGeneration !== staged.manifest.generation)
        ) return failure(409, "recovery-audit-mismatch", "recovery requires matching promotion and rollback audit records");
        if (Number(staged.manifest.build) <= Number(current.manifest.build)) return failure(409, "recovery-build-order", "recovery target must be newer than the active predecessor");
        if (staged.manifest.tag === current.manifest.tag) return failure(409, "recovery-tag-build-conflict", "recovery target tag must differ from the active predecessor");
        await storage.put(ACTIVE_KEY, staged);
        await storage.put(`${OPERATION_PREFIX}${payload.operationId}`, { action: "recover", operationId: payload.operationId, generation: staged.manifest.generation, releaseId: staged.manifest.releaseId, predecessorGeneration: currentGeneration, receiptSha256: staged.receiptSha256, targetSourceSha256: staged.manifest.sourceSha256 });
        await storage.put(`${AUDIT_PREFIX}recover:${staged.manifest.generation}`, { action: "recover", operationId: payload.operationId, generation: staged.manifest.generation, previousGeneration: currentGeneration, receiptSha256: staged.receiptSha256, targetSourceSha256: staged.manifest.sourceSha256 });
        return jsonResponse({ recovered: true, generation: staged.manifest.generation, previousGeneration: currentGeneration, receiptSha256: staged.receiptSha256 });
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
  if (payload.action === "promote" || payload.action === "rollback" || payload.action === "recover" || payload.action === "augment-android") return coordinatorRequest(request, env, payload);
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
