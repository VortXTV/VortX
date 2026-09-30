import type { RankedGroup } from "./streamRanking";
import type { Stream } from "./types";

/** Keep the original group and its ranked index: paging must never change what a click plays. */
export interface SourceRow {
  group: RankedGroup;
  stream: Stream;
  index: number;
}

export function sourceRows(groups: readonly RankedGroup[]): SourceRow[] {
  return groups.flatMap((group) => group.streams.map((stream, index) => ({ group, stream, index })));
}

export function paginateSourceRows(rows: readonly SourceRow[], requestedPage: number, pageSize = 40) {
  const size = Number.isFinite(pageSize) ? Math.max(1, Math.floor(pageSize)) : 40;
  const total = rows.length;
  const pageCount = Math.max(1, Math.ceil(total / size));
  const page = Number.isFinite(requestedPage)
    ? Math.min(Math.max(0, Math.floor(requestedPage)), pageCount - 1) : 0;
  const start = page * size;
  const visible = rows.slice(start, start + size);
  return { rows: visible, page, pageCount, total,
    first: total === 0 ? 0 : start + 1, last: total === 0 ? 0 : start + visible.length };
}
