import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
import { escapeHtml } from "./dom.ts";

// Follow dom.css-image.test.mjs: execute the production markup, avoiding player/transport side effects.
function sourcePart(path, start, end) {
  const source = readFileSync(new URL(path, import.meta.url), "utf8");
  const offset = source.indexOf(start), limit = source.indexOf(end, offset);
  assert.ok(offset >= 0 && limit > offset, "production extraction markers remain exact");
  return source.slice(offset, limit);
}

const controlsSource = sourcePart("./playerControls.ts", "export function mountControls(", "  const $ =");
function controlsShell(ctx) {
  const title = { textContent: "" };
  const stage = { innerHTML: "", querySelector: (selector) => selector === "#pl-title" ? title : null };
  const document = { createElement: () => stage };
  const js = stripTypeScriptTypes(controlsSource.replace(/^export /, "") + "\nreturn stageRoot;\n}", { mode: "strip" });
  const mount = Function("document", "icon", "escapeHtml", js + ";return mountControls;")(document, () => "", escapeHtml);
  mount({ appendChild() {} }, {}, ctx);
  return { stage, title };
}

const toggleSource = sourcePart("../views/settings.ts", "function toggle(", "/** A -/+ stepper");
const toggle = Function(stripTypeScriptTypes(toggleSource, { mode: "strip" }) + ";return toggle;")();
const segmentedSource = sourcePart("../views/settings.ts", "function segmented(", "function toggle(");
const segmented = Function("escapeHtml", stripTypeScriptTypes(segmentedSource, { mode: "strip" }) + ";return segmented;")(escapeHtml);
const labelsSource = sourcePart("../views/settings.ts", "const SOURCE_LABELS:", "let host:");
const rowSource = sourcePart("../views/settings.ts", "function row(", "function profilesSection(");
const reorderSource = sourcePart("../views/settings.ts", "function reorderList(", "// ---- Interaction");
const reorderList = Function("escapeHtml", stripTypeScriptTypes(labelsSource + rowSource + reorderSource, { mode: "strip" }) + ";return reorderList;")(escapeHtml);
const moveSourceText = sourcePart("../views/settings.ts", "function moveSource(", "/** Download the local data");
function sourceMover(saved) {
  const writes = [];
  let renders = 0;
  const move = Function("getSettings", "updateSettings", "rerender",
    stripTypeScriptTypes(labelsSource + moveSourceText, { mode: "strip" }) + ";return moveSource;")(
    () => ({ sourceOrder: saved }), (patch) => writes.push(patch), () => { renders += 1; });
  return { move, writes, renders: () => renders };
}
const attack = '\"><img data-dom-xss-probe src=x onerror="globalThis.__domXss = true"><span data-x="';

test("player skip labels encode runtime persisted values in both text and quoted attributes", () => {
  const { stage } = controlsShell({ title: "Fixture", skipStep: attack });
  assert.equal(stage.innerHTML.includes("<img data-dom-xss-probe"), false);
  assert.equal(stage.innerHTML.includes("&lt;img data-dom-xss-probe"), true);
  assert.equal((stage.innerHTML.match(/<small>[^<]*<\/small>/g) ?? []).length, 2);
  assert.equal((stage.innerHTML.match(/aria-label="Skip (?:back|forward) [^"]* seconds"/g) ?? []).length, 2);
});

test("player retains ordinary numeric skip labels and plain-text add-on titles", () => {
  for (const skipStep of [10, 15, 30]) {
    const { stage, title } = controlsShell({ title: attack, skipStep });
    assert.ok(stage.innerHTML.includes(`aria-label="Skip back ${skipStep} seconds"`));
    assert.ok(stage.innerHTML.includes(`aria-label="Skip forward ${skipStep} seconds"`));
    assert.equal((stage.innerHTML.match(new RegExp(`<small>${skipStep}</small>`, "g")) ?? []).length, 2);
    assert.equal(stage.innerHTML.includes(attack), false);
    assert.equal(title.textContent, attack);
  }
});

test("settings switch attributes use boolean literals for hostile runtime persisted values", () => {
  const markup = toggle("toggle-alerts", attack);
  assert.equal(markup.includes("data-dom-xss-probe"), false);
  assert.ok(markup.includes('class="switch on"'));
  assert.ok(markup.includes('aria-checked="true"'));
});

test("settings switches retain ordinary true and false states", () => {
  assert.ok(toggle("toggle-alerts", true).includes('class="switch on"'));
  assert.ok(toggle("toggle-alerts", true).includes('aria-checked="true"'));
  assert.ok(toggle("toggle-alerts", false).includes('class="switch"'));
  assert.ok(toggle("toggle-alerts", false).includes('aria-checked="false"'));
});

test("segmented controls encode labels and quoted values without changing known control semantics", () => {
  const markup = segmented([{ value: attack, label: attack, on: true }], attack, "quality");
  assert.equal(markup.includes("<img data-dom-xss-probe"), false);
  assert.equal((markup.match(/&lt;img data-dom-xss-probe/g) ?? []).length, 3);
  assert.ok(markup.includes('class="seg selected"'));
  assert.equal(segmented([{ value: "1080", label: "1080p", on: false }], "set-quality", "quality"),
    '<div class="segmented" role="group"><button class="seg" data-action="set-quality" data-quality="1080">1080p</button></div>');
});

test("priority rows tolerate malformed or future saved values without changing the saved input", () => {
  for (const value of [null, false, 42, {}, "torrent"]) assert.equal(reorderList(value), "");
  const saved = ["future-source", "direct", "__proto__", attack, null, { toString: 1 }, "debrid"];
  const before = [...saved];
  const markup = reorderList(saved);
  assert.deepEqual(saved, before);
  assert.equal(markup.includes("data-dom-xss-probe"), false);
  assert.equal(markup.includes("future-source"), false);
  assert.equal((markup.match(/data-action="source-move"/g) ?? []).length, 4);
  assert.ok(markup.includes('data-type="direct" data-dir="-1" disabled'));
  assert.ok(markup.includes('data-type="debrid" data-dir="1" disabled'));
  assert.ok(markup.indexOf("Plain HTTP/HTTPS") < markup.indexOf("Real-Debrid"));
});

test("priority movement swaps adjacent visible types while preserving unsupported entries in place", () => {
  const future = { kind: "future-source" };
  const saved = ["direct", "future-source", "__proto__", null, future, "debrid", "torrent"];
  const { move, writes, renders } = sourceMover(saved);
  assert.equal(move("direct", 1), true);
  assert.deepEqual(writes, [{ sourceOrder: ["debrid", "future-source", "__proto__", null, future, "direct", "torrent"] }]);
  assert.deepEqual(saved, ["direct", "future-source", "__proto__", null, future, "debrid", "torrent"]);
  assert.equal(renders(), 1);
  const up = sourceMover(saved);
  up.move("debrid", -1);
  assert.deepEqual(up.writes, writes);
});

test("invalid priority movements cannot write settings or rerender", () => {
  for (const saved of [null, {}, "direct", ["direct", "future-source", "debrid"]]) {
    const mover = sourceMover(saved);
    mover.move("__proto__", 1);
    mover.move("future-source", -1);
    mover.move("direct", 0);
    mover.move("direct", 0.5);
    mover.move("direct", -1);
    mover.move("debrid", 1);
    assert.deepEqual(mover.writes, []);
    assert.equal(mover.renders(), 0);
  }
});
