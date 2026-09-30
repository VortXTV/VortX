import test from "node:test";
import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";

// Real detail rendering/actions/ranking/paging; only transport, storage and the video sink are fixtures.
const mocks = {
  "../lib/addon": `export const fetchMeta=(a,t,id)=>globalThis.detailFixture.meta(id);
    export const fetchStreams=(a,t,id)=>globalThis.detailFixture.streams(id);
    export const fetchSimilar=async()=>[]; export const fetchSubtitles=async()=>[];`,
  "../lib/player": `export const play=async(url,title,options)=>{globalThis.detailFixture.played.push({url,title,options});};
    export const currentPlayToken=()=>1; export const setSkipSegments=()=>{};`,
  "../lib/store": `export const cwPosition=()=>0; export const cwProgress=()=>0; export const cwResumeId=()=>null;
    export const inLibrary=()=>false; export const toggleLibrary=()=>{};`,
  "../lib/settings": `export const getSettings=()=>({useAddonOrder:true,hideWords:"",requireWords:"",safetyFilter:"off"});`,
  "../lib/trailer": `export const resolveBackendTrailer=async()=>null; export const userTrailerLang=()=>"en";`,
  "../lib/skip": `export const fetchSkipSegments=async()=>[];`,
  "./board": `export const posterCard=()=>"";`,
};
registerHooks({ resolve(specifier, context, next) {
  if (context.parentURL?.endsWith("/views/detail.ts") && mocks[specifier]) {
    return { url: `data:text/javascript,${encodeURIComponent(mocks[specifier])}`, shortCircuit: true };
  }
  if (specifier.startsWith(".") && !/\.[a-z]+$/i.test(specifier) && context.parentURL) {
    const url = new URL(specifier + ".ts", context.parentURL);
    if (existsSync(fileURLToPath(url))) return { url: url.href, shortCircuit: true };
  }
  return next(specifier, context);
} });
class Element {
  innerHTML = "";
  dataset;
  constructor(dataset = {}) { this.dataset = dataset; }
  closest() { return this; }
  querySelector() { return null; }
}
globalThis.HTMLElement = Element;
globalThis.document = { title: "" };
const { openDetail, closeDetail, handleDetailClick } = await import("../views/detail.ts");
const flush = () => new Promise(resolve => setImmediate(resolve));
const action = (name, data = {}) => handleDetailClick(new Element({ action: name, ...data }));
const group = (base, count = 1) => ({ transportUrl: base, addonName: base,
  streams: Array.from({ length: count }, (_, i) => ({ url: `https://media.invalid/${base}/${i}`, name: "1080p" })) });
const movie = id => ({ id, type: "movie", name: id });
const series = { id: "tt123", type: "series", name: "Series", videos: [1, 2, 3].map(episode =>
  ({ id: `tt123:1:${episode}`, season: 1, episode, title: `Episode ${episode}` })) };
function fixture(meta = movie, streams = async () => []) {
  globalThis.detailFixture = { meta: async id => meta(id), streams, played: [] };
  return globalThis.detailFixture;
}
function deferred() { let resolve; const promise = new Promise(done => { resolve = done; }); return { promise, resolve }; }

test("source pages keep add-on order, exact click identity and reset on filtering", async () => {
  const f = fixture(movie, async () => [group("a", 50), group("b", 50)]);
  const host = new Element();
  await openDetail(host, [], "movie", "tt1"); await flush();
  await action("toggle-sources");
  assert.equal((host.innerHTML.match(/data-action="play-stream"/g) ?? []).length, 40);
  await action("source-page", { page: "1" });
  assert.match(host.innerHTML, /Sources 41–80 of 100/);
  await action("play-stream", { base: "b", index: "0" });
  assert.equal(f.played[0].url, "https://media.invalid/b/0");
  await action("filter", { base: "b" });
  assert.match(host.innerHTML, /Sources 1–40 of 50/);
  closeDetail();
});
test("no-source refresh is recoverable and double clicks start only one request", async () => {
  const pending = deferred(); let calls = 0;
  fixture(movie, async () => ++calls === 1 ? [] : pending.promise);
  const host = new Element();
  await openDetail(host, [], "movie", "tt1"); await flush();
  assert.match(host.innerHTML, /data-action="refresh-sources"/);
  const refresh = action("refresh-sources");
  await action("refresh-sources");
  assert.equal(calls, 2);
  pending.resolve([group("recovered")]); await refresh;
  assert.match(host.innerHTML, /data-action="play-best"/);
  closeDetail();
});
test("a slower previous title cannot repaint a newer title", async () => {
  const pending = deferred();
  fixture(id => id === "ttA" ? pending.promise : movie(id), async id => [group(id)]);
  const host = new Element();
  const old = openDetail(host, [], "movie", "ttA");
  await openDetail(host, [], "movie", "ttB"); await flush();
  pending.resolve(movie("ttA")); await old;
  assert.match(host.innerHTML, />ttB</); assert.doesNotMatch(host.innerHTML, />ttA</);
  closeDetail();
});
test("closing an episode invalidates its sources and next-episode callback cannot play a later title", async () => {
  const pending = deferred();
  const f = fixture(id => id === series.id ? series : movie(id), async id => id === "tt123:1:2" ? pending.promise : [group(id)]);
  const host = new Element();
  await openDetail(host, [], "series", series.id);
  await action("open-episode", { videoId: "tt123:1:1" });
  await action("play-best");
  assert.equal(f.played.length, 1);
  f.played[0].options.onNextEpisode(); await flush();
  await openDetail(host, [], "movie", "ttOther"); await flush();
  pending.resolve([group("stale-episode")]); await flush();
  assert.equal(f.played.length, 1, "stale next callback must not auto-play the new title's sources");
  assert.doesNotMatch(host.innerHTML, /stale-episode/);
  closeDetail();
});
test("closing an episode prevents late sources from appearing on the series overview", async () => {
  const pending = deferred();
  fixture(() => series, async () => pending.promise);
  const host = new Element();
  await openDetail(host, [], "series", series.id);
  const opening = action("open-episode", { videoId: "tt123:1:1" });
  await action("close-episode");
  pending.resolve([group("late")]); await opening;
  assert.doesNotMatch(host.innerHTML, /data-action="play-best"|data-action="refresh-sources"/);
  closeDetail();
});
