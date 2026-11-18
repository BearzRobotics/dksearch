# 0047: Cursor paging

Status: implemented for relevance-ordered searches over words (the API).

## Decision

- `after` is the score (as the 8 bytes of the double) and the id of the last result seen, 48 hex digits, opaque to the caller. The reply carries `next_cursor` when more follow.
- The search is the same ranking wrapped in a subquery that keeps the best 100000 results in order and selects those with a lower score, or the same score and a greater id. Results are ordered by score and then id, so ties cannot repeat or skip. The LIMIT inside the subquery also keeps SQLite from moving the condition into the full-text query, where its ranking function cannot be used in a WHERE.
- A cursor replaces `offset`; it is refused with other sort orders (they have other keys) and with a search without words.
- The page still pages with offsets for Previous/Next (it needs to go back); the API is what gains the cursor.

## Alternatives

- Offsets only: stop at 10000 results and shift when documents are added or removed between requests.
- Server-side result sets: state to keep and expire.

## Consequences

- A cursor from a different index state can skip or repeat results near its position if scores changed (a document added changes every score slightly); it never fails.
