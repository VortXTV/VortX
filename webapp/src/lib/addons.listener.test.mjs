import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { registerHooks } from "node:module";
import { fileURLToPath } from "node:url";

registerHooks({
  resolve(specifier, context, next) {
    if (specifier.startsWith(".") && !/\.[a-z]+$/i.test(specifier) && context.parentURL) {
      const candidate = new URL(specifier + ".ts", context.parentURL);
      if (existsSync(fileURLToPath(candidate))) return { url: candidate.href, shortCircuit: true };
    }
    return next(specifier, context);
  },
});

const values = new Map();
globalThis.localStorage = {
  getItem: (key) => (values.has(key) ? values.get(key) : null),
  setItem: (key, value) => values.set(key, String(value)),
  removeItem: (key) => values.delete(key),
  clear: () => values.clear(),
};

const { renderAddons, wireAddons } = await import("../views/addons.ts");
const { blockNativeAccountProjection, setNativeAccountProjection } = await import("./store.ts");

test("persistent add-ons host receives one delegated click listener across renders", () => {
  let clickBindings = 0;
  let submitBindings = 0;
  const host = {
    querySelector(selector) {
      if (selector !== "#addon-form") return null;
      return {
        addEventListener(type) {
          if (type === "submit") submitBindings += 1;
        },
      };
    },
    addEventListener(type) {
      if (type === "click") clickBindings += 1;
    },
  };

  wireAddons(host);
  wireAddons(host);
  wireAddons(host);

  assert.equal(submitBindings, 3, "each newly rendered form still needs its own submit listener");
  assert.equal(clickBindings, 1, "the persistent main host must not accumulate delegated click listeners");
});

test("account recovery gives the Add-ons form an actionable refusal and keeps its draft", async () => {
  let markup = "", elements, submit;
  const host = {
    get innerHTML() { return markup; },
    set innerHTML(html) {
      markup = html;
      const button = { disabled: html.includes('type="submit" disabled') };
      elements = {
        "#addon-form": {
          addEventListener(_type, handler) { submit = handler; },
          querySelector() { return button; },
        },
        "#addon-url": { value: "" },
        "#addon-error": { hidden: true, textContent: "" },
      };
    },
    querySelector(selector) { return elements?.[selector] ?? null; },
    querySelectorAll() { return []; },
    addEventListener() {},
  };
  const url = "https://private-addon.test/configured-secret/manifest.json";
  let fetches = 0, changes = 0;
  globalThis.fetch = async () => { fetches++; return Response.json({ id: "sample", name: "Sample" }); };
  try {
    renderAddons(host, [], () => { changes++; });
    wireAddons(host);
    elements["#addon-url"].value = url;
    blockNativeAccountProjection("account.example");
    await submit({ preventDefault() {} });
    assert.match(elements["#addon-error"].textContent, /Sync now/);
    assert.doesNotMatch(elements["#addon-error"].textContent, /configured-secret|invalid manifest/i);
    assert.equal(elements["#addon-error"].hidden, false);
    assert.equal(elements["#addon-url"].value, url);
    renderAddons(host, [{ transportUrl: url, manifest: { id: "sample", name: "Sample" } }], () => { changes++; });
    assert.match(host.innerHTML, /type="submit" disabled/);
    assert.doesNotMatch(host.innerHTML, /configured-secret/);
    assert.equal(elements["#addon-url"].value, url);
    assert.equal(fetches, 0);
    assert.equal(changes, 0);
  } finally {
    setNativeAccountProjection(null);
  }
});
