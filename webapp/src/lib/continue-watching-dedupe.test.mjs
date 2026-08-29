import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { foldContinueWatching } from "./continue-watching-dedupe.ts";

const fixture = JSON.parse(
  readFileSync(new URL("../../../test-fixtures/continue-watching-dedupe.json", import.meta.url), "utf8"),
);

test("shared cross-platform Continue Watching fixtures match", () => {
  assert.equal(fixture.version, 1);
  for (const testCase of fixture.cases) {
    const actual = foldContinueWatching(testCase.items, (item) => ({
      id: item.id,
      type: item.type,
      aliases: item.aliases,
      freshness: item.updatedAt,
      hasValidProgress:
        Number.isFinite(item.position) && Number.isFinite(item.duration) && item.position > 0 && item.duration >= 0,
      removed: Boolean(item.removed),
    })).map((item) => item.key);
    assert.deepEqual(actual, testCase.expected, testCase.name);
  }
});
