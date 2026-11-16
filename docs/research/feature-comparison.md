# Feature comparison

One row per feature candidate. "dksearch today" says what exists now (from this repository, as of 2026-11-16). Status: built, partial, candidate, planned, deferred or rejected. Cost columns are filled in only after the feature has been studied: S small, M medium, L large, `?` unknown. Nothing marked candidate is a commitment.

## Search and query

| Feature | Reference | dksearch today | Status | Complexity | Runtime | Storage | Offline | P2P | Notes / experiment |
|---|---|---|---|---|---|---|---|---|---|
| Boolean, grouping, phrase, prefix, NOT, proximity | Lucene, Meilisearch | built (query language, ADR 0024) | built | | | | yes | shared query model needed | |
| Typo tolerance | Meilisearch, Typesense | partial: edit distance 1, retried when few results | built | | | | yes | | longer distance is a candidate |
| Fielded filters (type, ext, size, dates, author, tag, language, path, domain) | Typesense | built | built | | | | yes | | |
| Regular expressions | (none of the references) | built (bytewise) | built | | | | yes | | |
| Facets / counts per field | Meilisearch, Typesense | not built | candidate | ? | ? | ? | yes | | needs counts per source/kind/language |
| Autocomplete / search as you type | Meilisearch | not built | candidate | ? | ? | ? | yes | | public pages must work without JavaScript |
| Query-language versioning | (plan 6.1) | not built | candidate | S | | | yes | needed once peers exchange queries | |
| Wildcard in the middle of a word | Lucene | not built (prefix only) | candidate | ? | ? | ? | yes | | |

## Ranking

| Feature | Reference | dksearch today | Status | Notes |
|---|---|---|---|---|
| BM25 with field weights | Lucene, Vespa | built (title and text weights configurable) | built | FTS5 weighs word counts before saturating |
| Source boost | Marginalia | built (per-source percent) | built | |
| Recency boost | Marginalia | built (off by default) | built | |
| Ranking explanation | Vespa | built (`explain=1`) | built | |
| Stop words, synonyms | Lucene | built (query time, files) | built | |
| Domain boost or demotion | Marginalia | not built | candidate | per-domain table; same multiplication as source boost |
| Domain / source diversity | Marginalia | not built | candidate | result grouping or re-rank pass |
| Ranking profiles in TOML | Vespa | partial (individual settings) | candidate | named profiles chosen per request |
| Multi-stage ranking, reranking | Vespa | not built | deferred | only with semantic search |
| Popularity, link graph | Marginalia | not built | deferred | needs crawl link data |

## Semantic and hybrid

| Feature | Reference | dksearch today | Status | Notes |
|---|---|---|---|---|
| Embeddings (local, optional) | Vespa | not built | planned | via Ollama first; stays optional, lexical search is the default |
| Vector index, ANN | Vespa | not built | planned | |
| Hybrid lexical and vector | Vespa | not built | planned | |
| Multilingual search | Lucene | partial (language field, one tokenizer) | candidate | analyzers per language |

## Sources and results

| Feature | Reference | dksearch today | Status | Notes |
|---|---|---|---|---|
| Source selection (all, one, grouped by kind) | | built | built | see [source-selection.md](source-selection.md) |
| Saved source groups | | not built | candidate | |
| Default source scope | | not built | candidate | |
| Source status and availability | | partial (jobs, counts) | candidate | |
| Duplicates across sources | | not built (ids derive from source name and source id) | candidate | content-hash grouping |
| Similar documents | | partial (images by perceptual hash) | candidate | |
| Highlighted snippets | Meilisearch | built | built | |
| PDF page references, section navigation | | not built | candidate | needed for retrieval citations |
| Previews, thumbnails | | partial (viewer for text, Markdown, ZIM, originals) | candidate | |
| Stable result identifiers | | built (32-hex ids) | built | |

## Ingestion

| Feature | Reference | dksearch today | Status | Notes |
|---|---|---|---|---|
| Local files: text, Markdown, PDF text, Office, ODF, EPUB, HTML, media metadata | | built | built | |
| ZIM, Wikipedia dumps, Gutenberg, feeds, crawl, Internet Archive metadata | | built | built | |
| Scanned PDF and OCR | | not built | planned | owner runs heavy converters |
| Source code as a document kind | | not built | candidate | |
| ZIP and TAR archives | | not built | candidate | |
| WARC / WET / WAT, CDX | Common Crawl | not built | candidate | |
| Recrawl scheduling, conditional requests | Nutch | partial (per-source schedule; no conditional requests) | candidate | |
| Distributed ingestion, queues, backpressure | StormCrawler | not built (one background task at a time) | deferred | |
| External search providers | SearXNG | not built | deferred | must be switchable off |

## Retrieval (RAG primitives)

| Feature | dksearch today | Status | Notes |
|---|---|---|---|
| Chunking, page- and section-aware chunks, overlap | not built | planned | consumes Docling Markdown; ingestion waits for the owner's runs |
| Top-K, neighbours, parent document, filtered retrieval | not built | planned | retrieval only; any answer endpoint stays an optional add-on |
| Citations with page numbers and locations | not built | planned | |

## Distributed and peer-to-peer

See [p2p-experiments.md](p2p-experiments.md). Nothing is built; everything is candidate or deferred until the first study of YaCy and the prototype sequence there.

## Operations

| Feature | dksearch today | Status | Notes |
|---|---|---|---|
| Rebuildable index, versioned schema, migrations | built | built | |
| Background jobs, cancel, resume, schedules | built | built | one at a time |
| Backup, restore, check | built | built | |
| Job retries | partial (scheduled sources retry after one interval) | candidate | |
| Metrics, query profiling, structured logs | partial (counters, access log) | candidate | |
| API keys, collection scopes, rate limits | not built | planned | |
| Offline install and upgrade | built (vendored sources, no network needed) | built | |
