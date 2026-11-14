# 0003. Search index backend

- Status: Accepted (2026-11-14, by the maintainer)
- Date: 2026-11-14

## Context

SPEC section 16 item 1 leaves the index backend open and asks that options be evaluated against: Zig integration, operational simplicity, index size, query performance, incremental updates, rebuildability, and offline installation. SPEC section 7 requires tokenization, phrase and multi-term queries, field weighting (title/body), snippets, filters, deterministic pagination, update and delete, rebuild and integrity check, and ranking that an administrator can inspect. AGENTS.md requires the core in Zig unless a documented technical reason applies, minimal dependencies, no container runtime, and single-node first.

Milestone 2 needs a small, working single-node search, not web scale. The index is derived data and rebuildable from the content store, so the backend can be replaced later without losing content.

## Options considered

### A. SQLite FTS5, vendored amalgamation

- Integration: public-domain C source (`sqlite3.c`, `sqlite3.h`) compiled by `build.zig` with `SQLITE_ENABLE_FTS5`. No system library, no network at build time. A community package (allyourcodebase/sqlite3) exists, but its compatibility with Zig 0.17.1 is unverified; vendoring the amalgamation and writing our own build step avoids depending on it.
- Provides: transactional incremental insert/update/delete, crash safety, BM25 with per-column weights, phrase/NEAR/prefix queries, `snippet()`, `integrity-check` and `rebuild` commands.
- Also a candidate for the metadata database (SPEC section 16 item 2), which would keep to one embedded engine.
- Weaknesses: a C dependency in a Zig-first project; the index grows by tens of percent to multiples of the source text depending on options (reports vary, anecdotal); one-file design suits millions of documents, not billions; ranking is BM25 with weights, and per-term score breakdowns for explainability would have to be computed separately; non-English tokenization needs a custom tokenizer.

### B. Native Zig inverted index (segments, postings, BM25)

- Full control over ranking, explainability, tokenization and on-disk format; no C dependency.
- Large effort and risk: postings compression, segment merging, crash-safe writes, phrase positions, snippets, deletes. A web search found no maintained Zig library to build on; the one Zig BM25 project found is a small learning project.
- Delays Milestone 2, and the first version would likely be slower and less robust than FTS5.

### C. External engines (Xapian, Tantivy, Lucene, Meilisearch, etc.)

- Excluded or disfavoured: C++/Rust/JVM runtimes and build chains, heavier installs, or server processes, against the minimal-dependency and offline single-binary goals.

## Decision

Use SQLite FTS5 as the first index backend, vendored as the public-domain amalgamation under `vendor/sqlite/` (version 3.54.1, hash recorded in `vendor/sqlite/README.md`). Rationale from the maintainer: databases are a mature, solved problem, so the project reuses one instead of building its own storage engine.

The rest of the system must not depend on SQLite types. `src/sqlite.zig` is internal to the index backend and not exported from the core module. The `Indexer` interface already isolates writes; a query-side `Searcher` interface is added with the backend. If scale or ranking explainability later demand it, another backend can be added and the index rebuilt from retained content.

Build options (in `build.zig`): `SQLITE_ENABLE_FTS5`, `SQLITE_OMIT_LOAD_EXTENSION` (no native code is loaded at runtime), `SQLITE_DQS=0`, `SQLITE_OMIT_DEPRECATED`, `SQLITE_OMIT_SHARED_CACHE`.

## Spike results

Verified by tests in `src/sqlite.zig` on Zig 0.17.1, Linux x86_64:

1. The vendored amalgamation builds with FTS5 enabled, and the compile options are as intended.
2. Title/body BM25 weighting, phrase queries, diacritic folding and `snippet()` behave as required on a small fixture; `integrity-check` and `rebuild` commands run.

3. Rebuilding an empty index from the content and document stores reproduces identical hits, order and scores for the fixture queries (`src/rebuild.zig` tests).

Not yet verified: cross-compilation to other targets, behavior at scale, and the per-term ranking explanations the admin interface needs.

## Implementation notes

- `src/index_sqlite.zig` implements `Indexer` and `Searcher`. Two tables: `docs` (id and filterable metadata) and an FTS5 table `fts(title, body)` keyed by `docs.rowid`. Title is weighted 10:1 over body in BM25. Ties break by document id so pages are stable.
- User query text is converted to an FTS5 expression in which every term is a quoted string, so operators, column filters and punctuation are literal. Embedded NULs, over-long queries (1024 bytes) and more than 32 terms are rejected. A test found that a NUL byte otherwise truncated the string inside SQLite; that is why it is rejected.
- `DocumentStore` records now hold the full document metadata (everything except the main text, which stays in the `ContentStore`), because an index cannot be rebuilt from hashes alone. Records whose text was not retained cannot be rebuilt and are reported as `unrecoverable`.
- The schema version lives in `PRAGMA user_version`. A file from another version is refused with `SchemaMismatch`; delete it and rebuild.

## Durability

The index is rebuildable, so it opens in WAL mode with `synchronous=NORMAL` by default: it syncs at checkpoints, not at every commit. After a power loss the last few commits may be lost, but the file stays consistent, and re-import or rebuild restores the rest. `OpenOptions.sync` can select `full` or `off` (`off` is for tests and throwaway indexes only). WAL requires a local filesystem.

This was chosen after measuring: on the development machine's `/stuff` volume (btrfs) a single write plus fsync took several seconds, which made fsync-per-commit unusable and a file-backed test take over a minute. With `synchronous` set before the journal mode switch, the whole test suite runs in well under a second.

## Consequences

- Milestone 2 can reach a working local search quickly.
- The core gains a vendored C dependency that must be pinned and updated deliberately; updating means replacing `sqlite3.c`/`sqlite3.h`, checking the published hash, and updating `vendor/sqlite/README.md`.
- Building requires a C compiler, which `zig build` provides through its bundled `zig cc`.
- Whether SQLite also serves metadata and operational state is a separate decision (SPEC section 16 item 2); it is the obvious candidate.
- Scale beyond one machine's single index, and richer ranking explanations, are explicitly deferred.
