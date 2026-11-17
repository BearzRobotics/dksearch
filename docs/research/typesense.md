# Typesense

Status: source read; no experiments. Research order: 6 of 10.

- Focus: typo tolerance over an ART trie, text match score and sort, filters and facets, indexing and storage, API keys and scoped keys.
- Source: <https://github.com/typesense/typesense> (C++), shallow clone at `/mnt/scratch/research/typesense`.
- Version examined: commit `8532fc290a2d` (2026-11-16).
- Claims marked (read) were checked in the files named; (known) are from prior knowledge and not checked. Nothing was built or run. The default and minimum values below come from `include/collection.h` and `src/index.cpp`.

## What it is

A search server for typed documents in a schema (collections with typed fields), with typo tolerance on by default. `DESIGN.md` states the intent: simple setup, typo tolerance without a speed penalty, all primary indexes in memory, disk only for durability, optimise for reads, availability over consistency. Clustering is Raft (`raft_server.h`); a single node works.

## Architecture as read

Paths under `src/` and `include/`.

- `collection.cpp` (11,000 lines): schema, parameter validation, `Collection::search(collection_search_args_t&)`, response building (highlights, facets, grouping). `collection_manager.cpp` owns collections.
- `index.cpp` (9,500 lines): one `Index` per collection: ART trees per string field (`search_index`), numeric trees (`num_tree.h`, `numeric_range_trie.h`), facet index, geo, HNSW vectors (`hnswlib`), sort indexes.
- `art.cpp`: Adaptive Radix Tree with leaves holding a posting list and a `max_score`; `art_fuzzy_search` walks the trie with an incremental Levenshtein matrix.
- `posting_list.h`, `id_list.h`, `ids_t.h`: postings as compressed sorted id blocks with per-document token offsets (needed for proximity and highlight).
- `store.cpp`: RocksDB (Snappy, level compaction): raw JSON documents under `$DI`/`$SI` keys, collection metadata, API keys, synonyms, overrides. The search structures are not on disk: (read, from `DESIGN.md` and the code layout) they are rebuilt in memory from the stored documents at start.
- `batched_indexer.cpp`, `raft_server.cpp`: writes are queued per collection and replicated; `auth_manager.cpp`: keys; `synonym_index.cpp`, `stopwords_manager.cpp`, `curation*.cpp` (pinned/hidden hits, "overrides").

## Traced search (read)

`GET /collections/{c}/documents/search` -> `core_api.cpp::get_search` (line 639) parses parameters -> `Collection::search` (3552) validates (`query_by` weights, `num_typos` per field, `prefix` per field, `synonym_num_typos` <= 2, errors are 400 with a message), builds the default sort `text_match:desc` then `default_sorting_field` (`collection.cpp` about 2425) -> `Index::search` (index.cpp 3543) -> `Index::search_across_fields` (5460) -> `fuzzy_search_fields` (4944).

1. Query tokens are normalised (locale tokenizer, optional stemming per field, stop words removed, synonyms expanded with `synonym_reduction`).
2. `fuzzy_search_fields`: for each token a list of costs `0..bounded` where `get_bounded_typo_cost` (index.cpp 7168) gives 0 below `min_len_1typo` (default 4), at most 1 below `min_len_2typo` (default 7), else 2 (capped by the field's `num_typos`, default 2). Numeric-only and alphanumeric tokens can be excluded from typos.
3. For each cost and token `art_fuzzy_search` returns up to `max_candidates` (default 4) leaves of the trie within that edit distance (a prefix search for the last token when `prefix=true`), ordered by `token_ordering` (frequency or max_score). Cost 0 is tried first; only if results stay below `typo_tokens_threshold` (default 1) does it go on to cost 1, then 2 (line 5255). The product of candidates over tokens is bounded (`COMBINATION_MIN_LIMIT`; unbounded only with `exhaustive_search`).
4. Candidate token combinations are intersected over postings, filtered by `filter_by` ids; `drop_tokens_threshold` (default 1, `left_to_right`/`right_to_left`/`both_sides`) drops tokens only when too few documents match.
5. Scoring (`match_score.h`): one 64-bit integer per match: `words_present<<40 | unique_words<<32 | (255 - total_typo_cost)<<24 | (100 - distance)<<16 | exact_match<<12 | (255 - max_offset)<<4 | synonym_score`. So the order is more words, fewer typos, closer words, exact, earlier in the field. It is a fixed-order bucket score packed in an int, comparable to Meilisearch's rule chain, with no term frequency or length normalisation.
6. Multi-field: each field's score is combined by `text_match_type` (`max_score` default, `sum_score`, `max_weight`); `query_by_weights` weight fields. Results go through a `Topster` (bounded top-N heap) ordered by up to three sort fields: `text_match`, `_eval(...)` expressions, numeric fields, `_vector_distance`, geo distance. `text_match(buckets: n)` quantises the text score so a second sort field can break ties inside a bucket (`collection.cpp` about 1986).

## Other parts

- Filters (`filter_by`): own expression language (`:=`, `:>`, `&&`, `||`, ranges, geo, `$join`); evaluated by `filter_result_iterator` as lazy id iterators over numeric trees, ART leaves and facet hashes, and merged with the text candidates. Facets: values hashed per document (`facet_hash_values_t`), counted over result ids, optional sampling for speed (`facet_sample_*`).
- Hybrid: a vector query and a keyword query in one request; embeddings can be generated at index time from a local ONNX model or a remote API (`text_embedder*.cpp`), fused by rank (`rank_fusion_score`, `hybrid_search_info`).
- Update/delete: a document gets a `seq_id`; update or delete calls `Index::remove`/`remove_field` to take its tokens out of every ART and sorted structure in place, so there are no segments or merges. Memory is the cost: the index is sized by RAM.
- Keys: `auth_manager.cpp`. Keys have actions and a collection list (wildcards) and expiry. A scoped search key is not stored: base64 of `HMAC-SHA256(parent_key, params)` + the parent key prefix + the embedded params (JSON such as `filter_by` and `expires_at`); the server recomputes the HMAC (line 238 and 398), only for search, and the embedded params override the request's.

## Useful patterns

- The cost ladder: try exact first, add typo cost only if results fall under a threshold; cheap in the common case.
- Typo parameters exposed and validated (`num_typos`, `min_len_*`, `typo_tokens_threshold`, `drop_tokens_threshold`) with clear 400 errors.
- A single comparable integer score with explicit field order; `text_match(buckets: n)` for tie-breaking by another sort field.
- Scoped keys: stateless, HMAC, params embedded and enforced, expiry.
- Bounded candidates per token (`max_candidates`) so fuzzy expansion cannot blow up.

## Limits and what not to copy

- In-memory ART per field: memory scales with vocabulary and postings; startup rebuilds from RocksDB. Opposite of dksearch's low-resource, disk-resident SQLite design.
- No BM25 (no length normalisation), a weak fit for long documents; schema required up front; 20k lines of C++ with Raft, remote embedders and analytics that dksearch does not want.
- Mixed query language knobs (`query_by`, `filter_by`, `sort_by` strings) are many; dksearch's inline filters are simpler.

## Potential dksearch uses

1. **Cost ladder for fuzzy**: run exact, and only run the vocabulary scan when results are fewer than a threshold (partly the case; make the threshold a setting and report it in `explain=1`).
2. **Typo length table**: Typesense 4 / 7 against dksearch 3 / 6 and Meilisearch 5 / 9: three independent projects choose longer minimums, so measure false matches at 3 letters.
3. **`max_candidates` per token** for the `fts5vocab` expansion (keep the closest few), which reduces the "rare word two edits away outscores" problem seen already.
4. **Tie-break buckets**: round BM25 to n buckets, then apply recency or source boost within a bucket (as `text_match(buckets:n)`); gives stable, explainable orders.
5. **Scoped public keys via HMAC** derived from a collection API key with embedded collection and expiry, verifiable without a lookup.
6. **Drop-token fallback** for long natural-language queries: AND first, drop the last or least frequent word if under a threshold.

## Questions

- Does bucketed BM25 beat the current boost sum on the test corpus, and how many buckets?
- Would a per-token candidate cap change recall measurably compared with the "only the closest spellings" rule in ADR 0031?
- Is a scoped key worth adding next to stored collection-scoped keys, or does it only matter for browser-side search?
