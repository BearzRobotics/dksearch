# Vespa

Status: first pass (source reading, no build, nothing run). Research order: 7 of 10.

- Focus: advanced ranking and hybrid search.
- Source: <https://github.com/vespa-engine/vespa> (Java and C++), shallow clone at `/mnt/scratch/research/vespa`.
- Version or commit examined: `5cff49e5c1f2` (2026-11-16, `VERSION` 8.0.0). Vespa was not built or run.
- Claims marked (read) were checked in the files named; (known) are from prior knowledge or the public documentation and not checked here; no (observed) claims.

## Architecture as read

`Code-map.md` (read): about 1.7 million lines, half Java and half C++, about 150 flat modules. Two tiers. A stateless Java **container** (`container-search`, jDisc) parses the query, runs searcher chains and merges results from many nodes. C++ **content nodes** (`searchcore` = the server "proton", `searchlib` = indexes, attributes and ranking features, `eval` = the ranking-expression and tensor engine, `storage` = distribution and recovery) match, rank and aggregate. Configuration is deployed as an application package (schemas, services) through config servers and ZooKeeper; everything below assumes that machinery, which a single-binary engine does not need.

**Schema and rank profile (read).** A schema declares a document type, fields (index = inverted, attribute = in-memory forward column, summary) and named `rank-profile`s. `config-model/.../schema/RankProfile.java` holds the model: `firstphase`, `secondphase`, `globalphase` expressions, `rerankCount`, `keepRankCount`, `matchPhase` (degradation settings), `minHitsPerThread`, `rankScoreDropLimit` for the second and global phase, and inheritance between profiles (`inherits`, with an error when two inherited profiles clash). A profile is a name chosen per query (`ranking.profile`). Example (read, `integration/schema-language-server/.../slack_message.sd`, a test file): a profile `hybrid2` with `inputs { query(q) tensor<float>(x[384]) query(semantic_weight) double: 0.7 }`, helper `function`s (`scale(val) = 2 * atan(val/4) / 3.14159`, `cos(distance(field, text_embedding))`, `bm25(text)`), a `first-phase` expression mixing semantic and scaled BM25 with the weight, `rank-score-drop-limit: 0.0`, and `match-features` listing values to return per hit.

**Ranking features (read).** `searchlib/.../features/bm25_feature.cpp`: classic BM25 per index field, defaults `k1 = 1.2`, `b = 0.75`, average field length from the field (or a rank property); the executor sums `idf * (tf*(k1+1)) / (tf + k1*(1-b) + k1*b*len/avg)` over query terms. `nativerankfeature.h` is the older built-in (a mix of field match, attribute match, first-phase proximity, field weight). Feature executors live in a framework (`fef`) that wires features lazily, so only features reachable from the expression are computed. (known) There are hundreds of built-in features (`fieldMatch`, `closeness`, `attribute(x)`...).

**Phases (read, partly).** First phase runs on every document the query matches, on each content node, so the expression must be cheap. Second phase re-ranks the best `rerankCount` per node; the default collection heap is `HeapSize::DEFAULT_VALUE(100)` (`searchlib/.../fef/indexproperties.cpp`, property `vespa.hitcollector.heapsize`, set from `rerankCount` in `RawRankProfile.java:560`). The **global phase** runs in the container, on the merged top hits from all nodes (`container-search/.../ranking/GlobalPhaseRanker.java`: `ResultReranker` rescoring the first `rerankCount` hits using `match-features` returned by the nodes, then dropping hits at or below `rank-score-drop-limit`). It refuses explicit sorting (only `[rank]` descending). `matchPhase` (known) limits how many documents are first-phase scored by sampling on an attribute.

**Hybrid retrieval (read).** In YQL a text and a vector condition are OR-ed: `weakAnd` (via `userQuery()`) and `nearestNeighbor(field, q)` with `targetHits` (`YqlParser.java` constants `USER_QUERY`, `WEAK_AND`, `NEAREST_NEIGHBOR`; `NearestNeighborItem.targetHits`). The union is ranked by the rank profile. Score combination is therefore an *expression*, not a built-in mode: either a weighted sum of scaled features (the `hybrid2` profile above; BM25 is unbounded so it is squashed with `atan`), or, in the global phase, normalisers. `NormalizerFunctionExpander.java` (read) recognises pseudo-functions in an expression: `normalize_linear(f)`, `reciprocal_rank(f, k)` and `reciprocal_rank_fusion(f1, f2, ...)` which expands to a sum of `reciprocal_rank` terms. `ReciprocalRankNormalizer.java` (read) sorts the hits by the input feature descending and replaces each value with `1 / (k + 1 + position)`, default `k = 60` (positions counted from 0, so rank 1 gives `1/(k+1)`). `LinearNormalizer.java` does min-max scaling. NaN is treated as the worst score.

**Storage (read, partly; known for the rest).** Proton keeps per schema: a memory index (`searchlib/.../memoryindex`, inverted, updated in place, `document_inverter`, `feature_store`) and disk indexes (`diskindex`, immutable, produced by a flush and merged by `fusion`); attributes (`searchlib/attribute`, `searchcore/.../proton/attribute`) are forward columns held in memory, with an option `paged` (`schema/document/Attribute.java:61`, applied in `derived/AttributeFields.java:219`) that lets the OS page them out so they live on disk; the document store (`docstore`, compressed chunks) holds the summary fields; the document meta store maps ids to local ids; a **transaction log** (`searchlib/transactionlog`, serial numbers, chunks) makes every operation durable before it is applied and is replayed after a crash (`searchcore/.../proton/flushengine`, `initializer`). Writes are visible to queries almost at once, which is the "real-time" claim: feed, update and remove go through the log, the memory structures, then are flushed in the background.

## Traced operation: one hybrid query

(read for the container side and the rank model; the node side from the module layout and (known) documentation.) Request: YQL `select * from doc where {targetHits:100}nearestNeighbor(embedding,q) or userQuery()` with `ranking.profile=hybrid`, `input.query(q)` and `query=text`.
1. The container parses YQL (`YqlParser`) into an item tree: an OR of a `NearestNeighborItem` and a `WeakAndItem` over the text terms; searchers (spell, rewrite, embedders that turn text into `query(q)`) run in a chain.
2. The query goes to every content node group, one node per partition. Each proton matches: weakAnd over the inverted index, HNSW search for the vector; the union is first-phase scored per document by the profile's expression (`bm25(text)`, `closeness`), keeping a heap of `rerankCount`.
3. The second phase, if present, rescoring that heap with a costlier expression (for example a model); `match-features` are attached to the surviving hits.
4. Each node returns its top hits; the container merges them by score. With a global phase, `GlobalPhaseRanker.rerankHitsImpl` normalises (`reciprocal_rank`) and recombines using the match features, then applies the drop limit.
5. A summary fetch loads the requested fields for the final page from the document store.
`trace.level` and `trace.explainLevel` (`query/Trace.java`) return the per-stage trace; `match-features` give the per-hit feature values, which is the practical explanation of a score (known: also `summary-features` and `rank-features` dumps).

## Compared with dksearch

dksearch: one BM25 over FTS5 (field weights, boosts and recency as settings), a retrieval API that chunks candidate documents and BM25-ranks the passages, semantic search planned as opt-in and RAG as retrieval only. That is already a two-stage design (documents, then passages) in all but name. Vespa's difference is that ranking is data: a named, inheritable profile with an expression and counts per stage.

## Useful patterns

- **Two-phase ranking with a count.** Cheap score over all matches, costly score over the top N only. For dksearch: FTS5 `bm25()` fetches N candidates, then a re-rank over those (passage BM25, title/recency boosts, later vectors) with `rerank_count` as a setting.
- **Rank profiles as named configuration.** A TOML table per profile (`[ranking.profile.news]`: field weights, boost terms, recency half-life, rerank count, drop limit), chosen per request or per collection by name; `inherits` for variants. A closed list of known terms is enough; a free expression language is not needed.
- **Fusion as a normaliser over ranks.** Reciprocal rank fusion needs no score scaling: sort each list, add `1/(k+rank)` with `k = 60`. The implementation is about 15 lines and the only knob is `k`. This is the safe default if lexical and vector lists are ever combined, since BM25 scores are unbounded and cosine scores are not.
- **Explain as data.** Per-hit "match features" (the numbers each profile term produced) beat a prose trace. dksearch's results could carry an optional `explain` object: bm25 per field, boosts, final score.
- **Score drop limit.** Removing hits under a threshold after re-ranking is a cheap precision control.
- Memory-versus-disk choice per column (`paged`): per-field decision about what must stay in RAM.

## Limitations and trade-offs

- A distributed system built for billions of documents: config servers, ZooKeeper, a container and content tier, a C++ engine, a JVM. Not self-contained, not low-resource; nothing here can be adopted as code.
- The expression language and tensor engine are a large surface; a user must understand phases to write a profile. dksearch should expose a few named knobs instead.
- The first phase sees every matched document, so a loose query makes it expensive; Vespa needs `weakAnd` and `matchPhase` to bound this, FTS5 has no equivalent beyond `LIMIT` on `bm25()` order, which still scores all matches.
- Global-phase reranking needs match features returned from the nodes; a single node does not.

## Potential dksearch applications

1. `rerank_count` and a second stage: formalise the existing candidate-then-passage step as "stage 2", with the count configurable; keep stage 1 as FTS5.
2. Named ranking profiles in TOML (weights, boosts, recency, rerank count, drop limit), selectable by `profile=` in the API and settable per collection; the profile name recorded in each result's metadata.
3. RRF with `k = 60` as the combination method when the optional semantic index exists; weighted sum as the alternative, never a raw BM25 plus cosine sum.
4. `explain=1` on the search API returning per-hit score components.
5. Not adopted: YQL (dksearch's query syntax is a user-facing text query plus filters), tensors, ONNX, the distributed layers, transaction-log replay (SQLite already gives durability).

## Questions for dksearch

- Are passage scores and document scores merged by position or by value? Test RRF against max-passage on the judgments in `test-corpus.md`.
- How much does re-ranking the top 100 change precision at 10 over plain FTS5 order on the evaluation set? That decides whether stage 2 is worth its latency.
- Can FTS5 `bm25()` weights per column be set from a profile at query time without rebuilding (yes, it is a function argument, but check the cost on large collections)?
- Experiments not done: build a small Vespa app and compare BM25-only, hybrid and re-ranked results on the same corpus (heavy; only if the owner asks).
