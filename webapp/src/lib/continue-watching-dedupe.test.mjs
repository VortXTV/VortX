import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import {
  canonicalPlaybackIdentity,
  continueWatchingIdentityKeys,
  foldContinueWatching,
} from "./continue-watching-dedupe.ts";

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

test("recognized provider playback identities retain episode suffixes", () => {
  assert.equal(canonicalPlaybackIdentity("KITSU:123:1:2", "series"), "series\u001fkitsu:123:1:2");
  assert.equal(canonicalPlaybackIdentity("tmdb:movie:123:1:2", "movie"), "movie\u001ftmdb:movie:123:1:2");
  assert.deepEqual(
    [...continueWatchingIdentityKeys({ id: "TMDB:movie:123:1:2", type: "movie" })],
    ["movie\u001ftmdb:movie:123:1:2"],
  );
});
