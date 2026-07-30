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

const { wireAddons } = await import("../views/addons.ts");

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
