# 0064: The owner marks results good or bad; the marks are the test set

Status: accepted

## Context

Ranking was being judged by eye and by 11 queries picked by the author, which are biased toward what already worked (ADR 0063 had to discard two ideas that looked right). A better test set has to come from real searches by the person who uses the engine, and it must not need a separate tool or a manual export.

## Decision

With the owner signed in, each result carries a *good* and a *bad* button (search.js; the server puts `data-feedback` on the list only for the owner). A mark is POSTed to `/feedback` and appended to `data_dir/feedback.jsonl` as one JSON line (query, address, grade 1, -1 or 0 to take a mark back, time). Only the owner's cookie is accepted; the public listener has no store and no route. The file is capped at 32 MB. `dksearch eval` reads those lines as they are: marks and judgment lines with the same query are one query, the last mark for an address wins, good results are relevant, bad ones are counted as unwanted in the top k (*Bad@k*), and a query with only bad marks is reported without scores.

## Consequences

Nothing leaves the machine and visitors cannot add anything, so no spam or poisoning. The set grows only as fast as the owner marks results, and it records the owner's taste: good for tuning one's own engine, not a general benchmark. A model that learns from the marks (a reranker) would need many more of them than a person marks by hand; the file is the first step, whatever is built on it.
