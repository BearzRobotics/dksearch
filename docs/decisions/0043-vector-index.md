# 0043: A vector index over every document

Status: implemented as an exact scan over in-memory int8 vectors.

## Context

ADR 0038 reordered lexical candidates by meaning, which cannot find a document that shares no word with the query. Finding it needs the nearest vectors among all documents.

## Decision

- **Exact scan, not a graph.** The vectors of `vectors.db` (unit length, float32, ADR 0038) are loaded into memory as int8, one byte per dimension, and a query is scored against all of them with SIMD integer multiply-adds, keeping the best few in a sorted list. For a million 768-dimensional documents that is about 770 MB and a few hundred milliseconds. There is nothing to tune and no recall to lose, the index is rebuilt in seconds from the file it is derived from, and a graph (HNSW) can replace the scan later behind the same interface for libraries that are too large.
- **Quantizing to int8** changes a similarity by well under a percent; the tests compare with an exact float scan and require the same neighbours up to two nearly equal ones swapping.
- **A holder keeps it current**: it looks at `vectors.db` at most every 30 seconds and loads a new copy when the file changed (so `dksearch embed` while serving shows up), searches that began on the old copy finish on it (reference counted), and nothing is loaded when the vectors would need more than `[embeddings] index_mb` (default 2048; 0 turns the index off).
- **Fusion by reciprocal rank** of the lexical list and the vector list (k = 60). Documents found only by vectors come from `info` (title, address, no snippet) and are limited to the caller's scope.
- **Used only without filters**, language or type: a filter is defined by the lexical side, and applying it to vector hits would need those fields on every vector; with a filter the search falls back to reordering the lexical candidates (ADR 0038).

## Alternatives

- HNSW or IVF now: faster for tens of millions, but approximate, with parameters, a build step and persistence; the scan is enough until the library is that large.
- Storing vectors in the search index (a vector column): ties them to SQLite's FTS tables and rebuilds; a separate file keeps the lexical index purely lexical and rebuildable.

## Consequences

- Memory is the cost: dimensions bytes per document, shown by `index_mb`.
- Results found by vectors alone have no snippet until the viewer is opened.
