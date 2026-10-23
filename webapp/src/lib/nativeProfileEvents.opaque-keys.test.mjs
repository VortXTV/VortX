import test from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { existsSync } from "node:fs";
import { registerHooks } from "node:module";
import { fileURLToPath } from "node:url";
registerHooks({ resolve(specifier, context, next) {
  if (specifier.startsWith(".") && !/\.[a-z]+$/i.test(specifier) && context.parentURL) {
    const url = new URL(specifier + ".ts", context.parentURL);
    if (existsSync(fileURLToPath(url))) return { url: url.href, shortCircuit: true };
  }
  return next(specifier, context);
} });
const { canonicalJSON, canonicalJSONHash, sparseProfileEdit } = await import("./nativeProfileEvents.ts");
const opaque = JSON.parse('{"stable":true,"__proto__":{"retained":"top"},"nested":[{"__proto__":{"retained":"nested"},"constructor":"opaque","toString":"opaque"}]}');
const expected = '{"__proto__":{"retained":"top"},"nested":[{"__proto__":{"retained":"nested"},"constructor":"opaque","toString":"opaque"}],"stable":true}';
test("canonical host bytes retain own prototype-named JSON fields at every depth", () => {
  assert.equal(canonicalJSON(opaque), expected);
  assert.equal(Object.getPrototypeOf(opaque), Object.prototype);
  assert.equal({}.retained, undefined);
});
test("sparse event copies retain unknown nested own keys without prototype setters", () => {
  const source = { id: "profile", settings: { future: opaque } };
  const copied = sparseProfileEdit(source);
  assert.equal(canonicalJSON(copied.settings.future), expected);
  assert.equal(Object.prototype.hasOwnProperty.call(copied.settings.future, "__proto__"), true);
  assert.equal(Object.getPrototypeOf(source.settings.future), Object.prototype);
});
test("different opaque host payloads cannot borrow the digest of an omitted prototype key", async () => {
  const onlyOpaque = JSON.parse('{"__proto__":{"retained":true}}');
  assert.notEqual(await canonicalJSONHash(onlyOpaque), await canonicalJSONHash({}));
  assert.equal(await canonicalJSONHash(opaque), createHash("sha256").update(expected).digest("hex"));
});
