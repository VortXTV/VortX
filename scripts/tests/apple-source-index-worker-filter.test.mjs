// Source-only candidate. Run serially AFTER the integrated Swift contract runner passes:
//   node scripts/tests/apple-source-index-worker-filter.test.mjs \
//     /Users/daksh/VortXTV/vortx-sources <retained-run.log> <retained-inputs.after.sha256>
// Node 26 standard-library-only test: actual worker source and SQL, in-memory SQLite, synthetic moat.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { stripTypeScriptTypes } from "node:module";
import { DatabaseSync } from "node:sqlite";
import { resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const [workerPath, runLogPath, manifestPath] = process.argv.slice(2);
assert.ok(workerPath && runLogPath && manifestPath, "worker repository, Swift run.log and source manifest are required");
const appRepo = fileURLToPath(new URL("../../", import.meta.url));
const workerRepo = pathToFileURL(resolve(workerPath) + "/");
const log = readFileSync(runLogPath, "utf8");
assert.equal(log.trimEnd().split("\n").at(-1), "ALL PASS", "Swift harness must complete successfully first");
const urls = log.split("\n").filter(line => line.startsWith("SOURCE_INDEX_SERVE_URL "));
assert.equal(urls.length, 1, "require one URL emitted by production Swift serveURL");
const serveURL = new URL(urls[0].slice("SOURCE_INDEX_SERVE_URL ".length));
assert.equal(serveURL.searchParams.get("content_id"), "tt1234568");
assert.deepEqual(serveURL.searchParams.getAll("kind"), ["torrent"]);
const inputHashes = {};
for (const line of readFileSync(manifestPath, "utf8").trim().split("\n")) {
  const match = /^([0-9a-f]{64})\s+(.+)$/.exec(line);
  assert.ok(match, "valid Swift input manifest line");
  const [, expected, path] = match;
  assert.ok(path.startsWith("app/"), "integrated runner manifest must use repository-relative app inputs");
  assert.equal(createHash("sha256").update(readFileSync(resolve(appRepo, path))).digest("hex"), expected,
    "Swift input changed since successful execution: " + path);
  inputHashes[path] = expected;
}
assert.equal(Object.keys(inputHashes).length, 9, "retain all nine actual-source harness inputs");
assert.ok(inputHashes["app/SourcesShared/SourceIndexClient.swift"]);

const readWorker = path => readFileSync(new URL(path, workerRepo), "utf8");
const moduleURLs = new Map();
function moduleURL(name) {
  if (moduleURLs.has(name)) return moduleURLs.get(name);
  let source = readWorker("src/" + name + ".ts");
  if (name === "index") {
    source = source.replace("EdgeAuthEnv, verifyClient", "verifyClient")
      .replace("MoatAuthEnv, verifyMoatToken", "verifyMoatToken").replace("AbuseEnv, checkAbuse", "checkAbuse");
    for (const dependency of ["edge_auth", "moat_auth", "abuse"]) {
      source = source.replace('"./' + dependency + '"', JSON.stringify(moduleURL(dependency)));
    }
  }
  const url = "data:text/javascript;base64," + Buffer.from(stripTypeScriptTypes(source)).toString("base64");
  moduleURLs.set(name, url);
  return url;
}
const worker = await import(moduleURL("index"));
const moat = await import(moduleURL("moat_auth"));
const database = new DatabaseSync(":memory:");
database.exec(readWorker("schema.sql"));
const queries = [];
const DB = {
  prepare(sql) {
    let values = [];
    return {
      bind(...args) { values = args; return this; },
      async run() { return { meta: { changes: Number(database.prepare(sql).run(...values).changes) } }; },
      async all() { queries.push({ sql, values }); return { results: database.prepare(sql).all(...values) }; },
      async first() { return database.prepare(sql).get(...values) ?? null; },
    };
  },
};
const env = { DB, ENFORCE_CLIENT_SIG: "0", ENFORCE_MOAT_AUTH: "1", MOAT_SEED: "synthetic-filter-seed",
  WITNESS_SEED: "synthetic-witness-seed", RL: { limit: async () => ({ success: true }) } };
const now = Date.now();
const contentID = serveURL.searchParams.get("content_id");
const insert = database.prepare("INSERT INTO sources(source_uid,content_id,kind,id,quality,size_bytes,source_tag,seeders,corroboration,first_seen,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?,?)");
const witness = database.prepare("INSERT INTO source_witness(source_uid,bucket,seen_at) VALUES(?,?,?)");
for (let index = 0; index < 120; index++) {
  const uid = "withheld-" + index;
  insert.run(uid, contentID, index % 2 ? "http" : "usenet", "https://cdn.example.com/media/" + index,
    "4K", 5_000_000_000, "", 100, 1, now, now);
  witness.run(uid, "witness-" + index, now);
}
const torrentID = "a".repeat(40);
insert.run("usable-torrent", contentID, "torrent", torrentID, "720p", 1, "", 1, 1, now, now);
witness.run("usable-torrent", "torrent-witness", now);
const day = Math.floor(now / 1000 / 86400);
const secret = await moat.deriveMoatWindowSecret(env.MOAT_SEED, day);
const payload = Buffer.from(JSON.stringify({ a: "synthetic-account", d: "synthetic-device",
  iat: Math.floor(now / 1000) - 5, exp: Math.floor(now / 1000) + 300, kid: "m" + day })).toString("base64url");
const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
const signature = Buffer.from(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(payload))).toString("base64url");
async function get(url) {
  const response = await worker.default.fetch(new Request(url, { headers: { "x-vx-moat": payload + "." + signature } }),
    env, { waitUntil() {} });
  assert.equal(response.status, 200);
  return response.json();
}
const unfilteredURL = new URL(serveURL);
unfilteredURL.searchParams.delete("kind");
const unfiltered = await get(unfilteredURL);
assert.equal(unfiltered.sources.length, 100);
assert.ok(!unfiltered.sources.some(source => source.id === torrentID), "negative control: withheld URLs fill ranked limit");
const filtered = await get(serveURL);
assert.deepEqual(filtered.sources.map(source => source.id), [torrentID], "actual Swift request selects torrent before SQL LIMIT");
assert.ok(queries.some(query => /WHERE kind = \? AND live_count >= \?/.test(query.sql)
  && query.values.includes("torrent")), "actual worker SQL uses the bound kind filter");
console.log(JSON.stringify({ result: "passed", actualSwiftRequest: serveURL.href, rankedURLRows: 120,
  unfilteredCount: 100, filteredTorrentCount: 1, liveNetworkCalls: 0, inputHashes,
  workerSourceSHA256: createHash("sha256").update(readWorker("src/index.ts")).digest("hex") }, null, 2));
database.close();
