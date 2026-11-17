# Meilisearch

Status: source read; no experiments. Research order: 5 of 10.

- Focus: typo tolerance, ranking rules and tie breaking, prefix search, facets, indexing and storage, API and keys.
- Source: <https://github.com/meilisearch/meilisearch> (Rust), shallow clone at `/mnt/scratch/research/meilisearch`.
- Version examined: commit `8da741e275a2` (2026-11-16). Search core is the `milli` crate.
- Claims marked (read) were checked in the files named; (known) are from prior knowledge and not checked. Nothing was built or run.

## What it is

A single-binary search server for instant, as-you-type search over JSON documents, built on LMDB (through `heed`). Defaults aim at "typing in a box": typo tolerance, prefix matching on the last word and a fixed bucket-sort relevance with no scoring formula to tune. The community edition is MIT; some features sit under `LICENSE-EE` (`scheduler/enterprise_edition`, sharding).

## Architecture as read

Paths under `crates/`.

- `milli/src/index.rs`: all LMDB databases of one index (`db_name`): `word-docids`, `word-prefix-docids`, `word-pair-proximity-docids`, `word-position-docids`, `word-field-id-docids`, `docid-word-positions`, `facet-*`, plus a `main` key-value map with settings (`criteria`, `stop-words`, `user-defined-synonyms`, `one-typo-word-len`, `words-fst`, `words-prefixes-fst`). (read) Postings are roaring bitmaps keyed by word (and by word pair with a proximity, word with position, word with field id): the index is precomputed for the ranking rules, not for one scoring formula.
- `milli/src/search/new/`: the search: `query_term/` (parsing, typo and prefix derivations), `query_graph.rs`, `ranking_rule_graph/{typo,proximity,position,fid,words,exactness}`, `bucket_sort.rs`.
- `milli/src/update/new/`: the indexer: `extract/` (per-document extractors for searchable words, positions, facets, vectors, run in parallel), `merger.rs`, `word_fst_builder.rs`, `indexer/document_operation.rs`, `document_deletion.rs`.
- `index-scheduler/`: tasks. Every write (documents, settings, deletion) is a task in a queue, batched by `scheduler/autobatcher.rs`, run in `process_batch.rs`; the HTTP call returns a task id at once.
- `meilisearch/` (server, actix), `routes/`, `meilisearch-auth/` (keys), `meilisearch-types`.

## Traced search (read)

`POST /indexes/{uid}/search` in `meilisearch/src/routes/indexes/search.rs` (`search_with_post`) calls `perform_search`, which builds a `milli::Search` and calls `search/new/mod.rs::execute_search`.

1. `extract_tokens` / `parse_query.rs`: tokenise, drop stop words, build a query graph; each term carries derivations. `number_of_typos_allowed` decides per word: 0 if typos off, the word is in `exact_words`, or its length (in chars) is below `min_len_one_typo` (default 5, `index.rs:48`); 1 below `min_len_two_typos` (default 9); else 2.
2. `compute_derivations.rs`: derivations come from the `words-fst` (an `fst::Set`) searched with Levenshtein DFAs (`LevBuilder::new(d, true)`, so transpositions cost 1; `search/mod.rs::build_dfa` builds prefix DFAs for the last word). `find_one_two_typo_derivations` intersects the 1-typo DFA with "does not start with the same letter" and the 2-typo DFA with "starts with the same letter", so (read) a typo in the first letter counts as two. Caps: 150 one-typo words, 50 two-typo words, 1000 prefix words, 50 synonym phrases (`limits.rs`). Zero-typo prefix words come from a prefix scan of `word-docids`.
3. `get_ranking_rules_for_query_graph_search` assembles the rule chain from the `criteria` setting (default `words, typo, proximity, attributeRank, sort, wordPosition, exactness`, `criterion.rs`). `words` is forced in before any text rule.
4. `bucket_sort.rs`: the first rule splits the candidate set (a `RoaringBitmap` after filters) into ordered buckets; the next rule splits each bucket; recursion stops once `from + limit` documents are placed. Ties inside the last bucket fall to internal document id (known, not traced). A `deadline` (`search_cutoff`, 1500 ms default (known)) marks the result `degraded` instead of failing.
5. `words` drops terms when too few documents match, by `TermsMatchingStrategy` (`Last` default, `All`, `Frequency`). `typo` and `proximity` are graph rules: the cheapest path through the query graph gives a bucket; proximity distance is clamped at `MAX_DISTANCE = 4` (`proximity.rs`), cost per word pair.
6. `ScoreDetails::global_score` folds the per-rule ranks into one 0..1 `_rankingScore` (read, `score_details.rs`); it is a report of the bucket path, not an input.

## Other parts

- Prefix: `words-prefixes-fst` plus `word-prefix-docids` for prefixes up to 4 bytes (`words_prefixes_fst.rs`, threshold 100 words), so short prefixes are a lookup, longer ones use the DFA. `prefix_search` can be disabled per index.
- Facets and filters (known/partly read): `filterableAttributes` must be declared; facet values live in B-tree-like `facet-id-*-docids` databases of bitmaps (`milli/src/facet`), so a filter is a bitmap AND before ranking and facet counts are bitmap intersections.
- Deletion and update (read): documents get internal u32 ids, `external-documents-ids` maps user ids. A deletion or replacement is a `DocumentChange` (`Insertion`/`Update`/deletion) that removes the old document's entries from every database in the same write transaction; there is no tombstone merge as in Lucene. LMDB is memory mapped with a huge max size (`INDEX_SIZE` 2 TiB, `option.rs`), single writer, readers never block.
- Hybrid (read): `search/hybrid.rs::execute_hybrid(semantic_ratio)` runs keyword search, returns it alone if good enough, else runs vector search and merges with the ratio as weights. Vectors use `arroy`/`hannoy` ANN in LMDB; embedders (remote REST, Ollama, local) are index settings.
- Keys (read): `meilisearch-auth`. API keys have actions, index patterns and expiry. A tenant token is a JWT (HS256/384/512, `authentication/mod.rs`) signed with an API key, carrying `searchRules` (per index filters) and expiry; only search actions accept it, and it narrows the parent key. Synonyms and stop words are index settings in the API, not files.

## Useful patterns

- Rules applied as successive bucket splits give explainable, deterministic ties: a tie is decided by the next rule, then by id, with no float to tune.
- Typo thresholds by length, first-letter-costs-two, and hard caps on derivations bound the work of fuzzy search.
- A time budget that returns partial results flagged `degraded` rather than an error.
- Short prefixes precomputed; long ones scanned with a bounded automaton.
- Tenant tokens: offline-verifiable, signed, expiring, narrowing scope, no state at the server.

## Limits and what not to copy

- The index is shaped by the ranking rules (pair-proximity, position and field databases); it is large (its own benchmarks and (known) reports show several times the text) and rebuilding after changing rules is a full reindex.
- Needs a long task queue, memory-mapped LMDB with a 2 TiB virtual size, and a Rust toolchain; none of that exists in a Zig + SQLite design. No BM25: term frequency and document length are ignored, which suits short records and fits long documents badly (a 200-page PDF and a title match tie on `words`).
- Searchable attributes order stands in for field weights; there is no per-source or recency boost except `sort` rules placed in the chain.
- Search config is JSON through the API, not a file.

## Potential dksearch uses

1. **Typo rules**: dksearch's 1 edit for 3-5 letters and 2 from 6 is looser than 5 and 9; the Meilisearch table (and "first letter wrong counts double") suggests testing min length 4-5 for 1 edit to cut false positives. dksearch already keeps first letter first; make it a cost, not a filter.
2. **Tie-breaking ranking order** as an option: after BM25 buckets (round the score to a bucket), break ties by typo count, then proximity, then exactness; today `explain=1` shows parts but ties fall to rank order.
3. **Proximity** as a re-rank over the top N only: compute the minimal word-pair distance (cap 4) from FTS5 offsets for the top 50, cheap compared to a pair index.
4. **Caps on derivations** (150/50) and a degraded-result flag on the time limit.
5. **Prefix**: FTS5 `prefix='2 3 4'` indexes for short prefixes, already close to Meilisearch's 4-byte rule.
6. **Signed search tokens** derived from a collection key (HMAC, expiry, collection and filter list) for the public interface, offline-checkable.

## Questions

- How many real queries change order with a rule chain versus BM25 plus boosts (needs the query file in `test-corpus.md`)?
- Is the first-letter rule worth the false negatives for brand and file names?
- Does a signed token fit the collection-scoped key model, or only add a second mechanism?
