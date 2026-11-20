# 0072: Ranking from the best candidates

Status: accepted

## Context

A search that matches tens of thousands of documents took 0.6 s ("language", 22,000 matches), 0.27 s ("linux", 11,000). `perf` and a few queries in SQLite showed where it went: not the ranking (the same query with its filters took 0.03 s in SQLite) but the factors computed for every match (source boost, recency, the language factor, domain demotion, a file name as a title: about 25 microseconds a match), and then the per-domain window over all of them.

## Decision

For a relevance-ordered search of words (no cursor, not deeper than page 5,000 results, no trusted-sources-first, no explanation asked for, excerpts made by us), the best `candidate_pool` (2,000, or four times the results wanted) matches by the text score are taken first from the full-text index alone, as a subquery (`SELECT rowid, bm25(...) ... ORDER BY score LIMIT K`); the join with the documents, the filters, the factors, the per-domain window and the final order are applied to those. If the filters leave the page short and more documents match than the candidates (a cheap count that stops at K+1), the exact query is run, so a result is never lost.

A first version restricted the exact query to the candidates with `fts.rowid IN (...)`: it passed the unit tests and made the real searches take five seconds (SQLite handles that shape badly on a large full-text index). It was rolled back within minutes and replaced by the subquery.

## Consequences

Measured with `crap` on the 414,000-document index: "language" 607 ms to 120 ms, "linux" 268 ms to 91 ms, "lanague" 1.02 s to 0.46 s, a search with few matches unchanged (39 ms). The top-10 lists of 40 different searches were identical to the exact ones, and `dksearch eval` gave the same scores. The approximation: a document outside the best 2,000 by text score is never shown, even if its factors would lift it; with factors of a few times at most and flat score landscapes that is not seen in practice, and a search that wants more than 500 results ranks the rest exactly. Unit tests on small indexes cannot see this kind of cost: a change to the shape of a query is measured on the large index.
