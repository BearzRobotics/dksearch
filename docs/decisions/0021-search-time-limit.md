# 0021. A time limit for searches

- Status: Accepted (2026-11-15); found by measuring the English Wikipedia
- Date: 2026-11-15

## Context

With the full English Wikipedia imported (7,254,502 articles, a 38 GB index), a search for a very common word ("the", "world war") has to score millions of matching documents before it can return the best ten, and took 4 to 10 seconds on a cold cache. The connection deadline (`server.write_timeout_ms`, 10 s) covers the whole request, handler included, so a search that ran longer was cut off by closing the connection: the client received an empty reply instead of an answer.

## Decisions

1. **A per-search time limit** (`[search] query_timeout_ms`, default 5000 ms, 0 turns it off). SQLite's progress callback checks the clock every 2000 virtual-machine steps and tells SQLite to stop, so the limit costs nothing measurable on queries that finish in time. The search fails with `search.Error.Timeout`.
2. **A proper answer**: HTTP 503 with the stable code `search_timeout`, a message that says to use more specific words, and `Retry-After: 5`, on the API, the HTML page and the administration pages. The regex filter, which asks the index for candidates, passes the same error on.
3. **No partial results.** FTS5 ranks before it returns anything, so a stopped search has nothing useful to show; returning an honest error is better than a wrong or arbitrary top ten.
4. **Why not make common words fast instead**: ranking by bm25 inherently scores every match. Speeding it up needs a different design (precomputed top results per frequent term, a block-max index, or a stop-word list), which changes search quality and is a separate decision; the limit protects the server meanwhile.

## Not done

Caching frequent queries; stop words; per-source limits; reporting slow queries in the administration interface.
