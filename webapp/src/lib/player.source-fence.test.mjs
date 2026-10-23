import { test } from "node:test";
import assert from "node:assert/strict";
import { registerHooks } from "node:module";
const deferred = () => { let resolve; const promise = new Promise((r) => { resolve = r; }); return { promise, resolve }; };
const state = globalThis.__playerSourceFence = { gate: deferred(), importStarted: false, instances: [], controls: [] };
const hlsMock = `
  const state = globalThis.__playerSourceFence;
  state.importStarted = true; await state.gate.promise;
  export const ErrorTypes = { NETWORK_ERROR: "network", MEDIA_ERROR: "media" };
  export default class Hls {
    static Events = { MEDIA_ATTACHED: "attached", ERROR: "error" };
    static isSupported() { return true; }
    constructor() { this.handlers = new Map(); this.starts = 0; this.recovers = 0; this.destroyed = false; state.instances.push(this); }
    loadSource(url) { this.url = url; }
    attachMedia(video) { this.video = video; }
    on(event, handler) { this.handlers.set(event, handler); }
    startLoad() { this.starts++; }
    recoverMediaError() { this.recovers++; }
    destroy() { this.destroyed = true; }
  }
`;
const mocks = {
  "hls.js": hlsMock,
  "./dom": "export const el = () => globalThis.__playerSourceFence.host;",
  "./store": "export const cwPosition = () => 0; export const recordProgress = () => {}; export const captureProgressAdmission = () => () => true;",
  "./settings": "export const getSettings = () => ({ skipStep: 10, subtitlesMode: 'always', subtitleLang: '' });",
  "./desktop": "export const nativePlaybackOwned = () => false;",
  "./nativePlayer": "export const releaseNative = () => {};",
  "./playerControls": `export function mountControls(host, video, ctx) {
    const control = { ctx, video, hls: undefined, disposed: false, setHls(value) { this.hls = value; }, dispose() { this.disposed = true; }, refreshSubtitles() {}, setAutoMuted() {}, consumeAutoMuted() { return false; }, toast() {}, notice() {}, setSkipSegments() {} };
    globalThis.__playerSourceFence.controls.push(control); return control;
  }`,
};
registerHooks({ resolve(specifier, context, next) {
  if (mocks[specifier] && /\/player\.ts$/.test(context.parentURL ?? "")) return { url: "data:text/javascript," + encodeURIComponent(mocks[specifier]), shortCircuit: true };
  return next(specifier, context);
} });
class Video extends EventTarget {
  constructor() { super(); this.kind = "video"; this.currentTime = 0; this.duration = 100; this.muted = false; this.volume = 1; this.paused = false; this.plays = 0; }
  setAttribute() {} removeAttribute() {} load() {} canPlayType() { return ""; }
  play() { this.plays++; return Promise.resolve(); } pause() { this.paused = true; }
}
const classes = new Set(["hidden"]);
state.host = { children: [], classList: { add: (value) => classes.add(value), remove: (value) => classes.delete(value), contains: (value) => classes.has(value) },
  setAttribute() {}, appendChild(video) { this.children.push(video); }, querySelector(selector) { return selector === "video" ? this.children.find((video) => video.kind === "video") ?? null : null; },
  addEventListener() {}, removeEventListener() {}, set innerHTML(_html) { this.children = []; },
};
globalThis.document = new EventTarget(); document.createElement = (tag) => { assert.equal(tag, "video"); return new Video(); };
globalThis.window = new EventTarget(); window.setTimeout = setTimeout;
Object.defineProperty(globalThis, "navigator", { configurable: true, value: { userAgent: "Chrome" } });
const player = await import("./player.ts");
const waitFor = async (ready) => { for (let attempt = 0; attempt < 100 && !ready(); attempt++) await new Promise((resolve) => setImmediate(resolve)); assert.ok(ready()); };

test("a fallback during the lazy HLS import cannot attach the old source or overwrite current controls", async () => {
  const pending = player.play("https://media.test/old.m3u8", "Old", { fallbacks: ["https://media.test/old.m3u8", "https://media.test/new.mp4"] });
  await waitFor(() => state.importStarted);
  const first = state.controls[0], oldVideo = first.video;
  first.ctx.onTryNextSource();
  const current = state.controls.at(-1); assert.equal(current.video.src, "https://media.test/new.mp4"); assert.equal(first.disposed, true);
  state.gate.resolve(); await pending;
  assert.equal(state.instances.length, 0, "a superseded import must never allocate a worker-backed HLS instance");
  assert.equal(current.hls, null); assert.equal(oldVideo.plays, 0);
  player.close();
});

test("late callbacks from a destroyed HLS instance cannot recover, play, or advance its replacement", async () => {
  await player.play("https://media.test/one.m3u8", "One", { fallbacks: ["https://media.test/one.m3u8", "https://media.test/two.m3u8", "https://media.test/three.mp4"] });
  const first = state.instances.at(-1), firstControl = state.controls.at(-1);
  firstControl.ctx.onTryNextSource(); await waitFor(() => state.instances.at(-1) !== first);
  const current = state.instances.at(-1), currentControl = state.controls.at(-1), controlsBefore = state.controls.length;
  assert.equal(first.destroyed, true); assert.equal(currentControl.hls, current);
  first.handlers.get("attached")();
  for (const type of ["network", "media", "other"]) first.handlers.get("error")(null, { fatal: true, type });
  assert.equal(first.video.plays, 0); assert.equal(first.starts, 0); assert.equal(first.recovers, 0);
  assert.equal(current.starts, 0); assert.equal(current.recovers, 0); assert.equal(state.controls.length, controlsBefore);
  current.handlers.get("error")(null, { fatal: true, type: "network" });
  current.handlers.get("error")(null, { fatal: true, type: "media" });
  assert.equal(current.starts, 1); assert.equal(current.recovers, 1);
  player.close(); assert.equal(current.destroyed, true);
  current.handlers.get("attached")(); current.handlers.get("error")(null, { fatal: true, type: "network" });
  assert.equal(current.video.plays, 0); assert.equal(current.starts, 1);
});
