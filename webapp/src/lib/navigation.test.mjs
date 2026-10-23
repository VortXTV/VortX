import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { registerHooks } from "node:module";
import { fileURLToPath } from "node:url";
import { runInNewContext } from "node:vm";
registerHooks({ resolve(specifier, context, next) {
  if (specifier.startsWith(".") && !/\.[a-z]+$/i.test(specifier) && context.parentURL) {
    const candidate = new URL(specifier + ".ts", context.parentURL);
    if (existsSync(fileURLToPath(candidate))) return { url: candidate.href, shortCircuit: true };
  }
  return next(specifier, context);
} });
globalThis.location = { hash: "#/", search: "" };
const { parseRoute } = await import("./router.ts");

test("malformed percent escapes fall back to Home without disabling later valid navigation", () => {
  for (const hash of ["#/search/%", "#/discover/%zz", "#/detail/movie/%E0%A4%A", "#/detail/%/tt1"]) {
    location.hash = hash;
    assert.deepEqual(parseRoute(), { name: "home" }, hash);
  }
  location.hash = "#/search/caf%C3%A9"; assert.deepEqual(parseRoute(), { name: "search", query: "café" });
  location.hash = "#/detail/movie/opaque%2Fid"; assert.deepEqual(parseRoute(), { name: "detail", type: "movie", id: "opaque/id" });
});

test("the actual splash function tolerates denied storage reads and writes before shell startup", () => {
  const source = readFileSync(new URL("../main.ts", import.meta.url), "utf8");
  const body = source.match(/function dismissSplash\(\): void \{([\s\S]*?)\n\}/)?.[1];
  assert.ok(body, "test must execute the current main.ts splash body");
  for (const deny of ["getItem", "setItem"]) {
    let removed = 0; const timers = [];
    const sessionStorage = { getItem() { if (deny === "getItem") throw new Error("denied"); return null; }, setItem() { if (deny === "setItem") throw new Error("denied"); } };
    assert.doesNotThrow(() => runInNewContext(`(function () {${body}})()`, {
      sessionStorage, document: { getElementById: () => ({ remove() { removed++; } }) },
      window: { matchMedia: () => ({ matches: false }), setTimeout(fn) { timers.push(fn); } },
    }));
    assert.equal(timers.length, 1); timers[0](); assert.equal(removed, 1);
  }
});

test("TV reseating keeps focus inside the active Detail overlay instead of the background tab", async () => {
  let focused = null, queued;
  const leaf = (name) => ({ name, hidden: false, closest: () => null, getBoundingClientRect: () => ({ width: 100, height: 40 }), focus() { focused = name; }, scrollIntoView() {} });
  const detailButton = leaf("detail"), backgroundTab = leaf("background-tab");
  const detail = {
    classList: { contains: (name) => name === "active" },
    querySelectorAll: (selector) => selector.startsWith("a[href]") ? [detailButton] : [],
    matches: () => false, contains: (node) => node === detailButton,
  };
  globalThis.document = {
    body: {}, activeElement: null,
    documentElement: { classList: { add() {} } },
    getElementById: (id) => id === "detail-host" ? detail : null,
    querySelector: (selector) => selector === ".tab.active" ? backgroundTab : null,
    addEventListener() {},
  };
  globalThis.window = new EventTarget(); window.webOS = {};
  globalThis.getComputedStyle = () => ({ visibility: "visible" });
  globalThis.requestAnimationFrame = (fn) => { queued = fn; };
  globalThis.MutationObserver = class { observe() {} };
  const { initTvPlatform } = await import("./tvnav.ts");
  initTvPlatform(); assert.equal(typeof queued, "function"); queued();
  assert.equal(focused, "detail");
});
