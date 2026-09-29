import test from "node:test";
import assert from "node:assert/strict";
import { sourceRows, paginateSourceRows } from "./sourcePaging.ts";

const groups = ["a", "b", "c"].map(base => ({ base, addon: base,
  streams: Array.from({ length: 50 }, (_, i) => ({ url: `${base}${i}` })) }));
test("a large source pool renders 40 rows without changing group order or click indices", () => {
  const rows = sourceRows(groups);
  const page = paginateSourceRows(rows, 1);
  assert.equal(page.rows.length, 40);
  assert.deepEqual([page.pageCount, page.total, page.first, page.last], [4, 150, 41, 80]);
  assert.deepEqual(page.rows.slice(8, 12).map(r => [r.group.base, r.index, r.stream.url]),
    [["a", 48, "a48"], ["a", 49, "a49"], ["b", 0, "b0"], ["b", 1, "b1"]]);
  for (const row of page.rows) assert.equal(row.group.streams[row.index], row.stream);
});
test("filtering retains indices and page bounds remain finite", () => {
  const rows = sourceRows(groups.filter(g => g.base === "b"));
  assert.equal(paginateSourceRows(rows, 0).rows[0].stream.url, "b0");
  assert.equal(paginateSourceRows(rows, 1).rows[0].index, 40);
  assert.equal(paginateSourceRows(rows, 999).page, 1);
  assert.equal(paginateSourceRows(rows, -1).page, 0);
  assert.equal(paginateSourceRows(rows, NaN, NaN).page, 0);
  assert.equal(paginateSourceRows(rows, Infinity, Infinity).rows.length, 40);
  assert.equal(paginateSourceRows(rows, 0, 0).rows.length, 1);
  assert.deepEqual(paginateSourceRows([], 100).rows, []);
});
