import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
import * as dom from "./dom.ts";

// Extract the actual pure markup functions; transport/player dependencies are not executed.
function productionFunction(path, start, end, name, extras = {}) {
  const source = readFileSync(new URL(path, import.meta.url), "utf8");
  const offset = source.indexOf(start), limit = source.indexOf(end, offset);
  assert.ok(offset >= 0 && limit > offset, "production extraction markers remain exact");
  const js = stripTypeScriptTypes(source.slice(offset, limit), { mode: "strip" });
  const bindings = { ...dom, ...extras };
  return Function(...Object.keys(bindings), js + `;return ${name};`)(...Object.values(bindings));
}
const detailShell = productionFunction("../views/detail.ts", "function detailShell(", "/** The title block:", "detailShell");
const featuredHero = productionFunction("../views/board.ts", "function featuredHero(", "/** ★ imdb", "featuredHero",
  { hashFor: () => "#/detail/movie/fixture", icon: () => "", featuredMeta: () => "" });
const decodeHTML = (text) => text.replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&");
function decodeOnlyURL(markup, className) {
  const match = new RegExp(`class="${className}" style="([^"]*)"`).exec(markup);
  assert.ok(match, "rendered art has one quoted style attribute");
  const style = decodeHTML(match[1]);
  const expression = /^background-image:url\((["'])([\s\S]*)\1\)$/.exec(style);
  assert.ok(expression, "exactly one quoted URL declaration");
  const [, quote, value] = expression;
  assert.ok(!value.includes(quote) && !/[\r\n\f]/.test(value), "unescaped quotes/control newlines cannot end the URL");
  return value.replace(/\\([0-9a-f]{1,6})\s?/gi, (_, hex) => String.fromCodePoint(parseInt(hex, 16)));
}
for (const [name, render, className] of [
  ["Detail", (url) => detailShell(url, "", ""), "detail-bg"],
  ["Home", (url) => featuredHero({ id: "fixture", type: "movie", name: "Fixture", background: url }), "featured-bg"],
]) {
  test(`${name} image URLs cannot escape CSS after HTML entity decoding`, () => {
    const attack = `https://img.invalid/x');color:red;background-image:url("https://unexpected.invalid/a");/*\\\n`;
    assert.equal(decodeOnlyURL(render(attack), className), attack);
  });
  test(`${name} keeps exact valid URL spelling and attribute boundaries`, () => {
    const url = "https://IMG.invalid:443/a(b)c?q=one&two=%22three#fragment";
    assert.equal(decodeOnlyURL(render(url), className), url);
  });
}
test("CSS URL serialization replaces NUL without introducing a declaration boundary", () => {
  assert.equal(dom.cssImageURL("https://img.invalid/\0"), 'url("https://img.invalid/\\fffd ")');
});
