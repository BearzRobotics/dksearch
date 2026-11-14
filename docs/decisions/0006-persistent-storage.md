# 0006. Persistent storage for documents, content and import state

- Status: Accepted (2026-11-14, by the maintainer)
- Date: 2026-11-14

## Context

SPEC section 16 items 2 and 3 are open: the metadata/operational database and the retained-content format. Milestone 3 needs both: connectors must store what they import somewhere durable, rebuilds must work from it, and imports must be resumable (SPEC section 15, milestone 3).

Today the `ContentStore` and `DocumentStore` interfaces exist (`src/storage.zig`) with only in-memory implementations, and the index (`index.db`, SQLite FTS5) is derived data that may be deleted at any time (ADR 0003).

The important difference: the index can be thrown away and rebuilt, but the stores are the source of truth. Losing them loses the only copy of what was imported, so they need migrations, backups and integrity checks that the index does not.

Retention volume varies hugely between sources: an English Wikipedia dump is reported at tens of GB compressed (per the Wikipedia database download page) and several times that as text, while Project Gutenberg is expected to be much smaller. Neither has been measured here.

## Proposed decision

Use SQLite (already vendored, ADR 0003) for all persistent state, in separate database files under `storage.data_dir`:

| File | Holds | Nature |
|---|---|---|
| `index.db` | FTS5 search index | Derived. Delete and rebuild freely. Exists today. |
| `state.db` | Document metadata and provenance records, source registry, import jobs and checkpoints | Source of truth. Versioned schema with forward migrations. |
| `content.db` | Retained main text, one row per document, compressed | Source of truth for text. Separable so retention policy, backup and pruning can differ. |

Details:

- **Content compression:** per-document deflate (`std.compress.flate`, which can both compress and decompress), stored as a BLOB with the hash of the uncompressed text. zstd would compress better, but the standard library can only decompress it; a vendored zstd could be revisited if measurements justify it.
- **Atomicity:** writing a document touches `content.db` and `state.db`, which are different files, so there is no single transaction. The pipeline already orders its writes so that the provenance record in `state.db` comes last and a retry is idempotent (`src/pipeline.zig`). The same rule is kept: content first, then the index, then the record. A crash can leave orphan content (harmless, reclaimable by a check command) but never a record without content.
- **Migrations:** `state.db` and `content.db` carry `PRAGMA user_version`. Opening an older file runs numbered migrations inside a transaction after copying the file to a backup alongside it; opening a newer one is refused. This differs from `index.db`, where a mismatch means "delete and rebuild".
- **Import jobs:** `state.db` has tables for sources (connector type, name, configuration reference, enabled), jobs (state, started/finished, counters, last error) and checkpoints (the opaque `Outcome.checkpoint` from `src/connector.zig`). A job interrupted by a crash is found in state `running` at startup and resumes from its last checkpoint or is marked failed.
- **Interfaces:** `SqliteDocumentStore` and `SqliteContentStore` implement the existing `src/storage.zig` interfaces. Everything above them (pipeline, rebuild, connectors) is unchanged. `Record` already carries the full document metadata needed to rebuild.
- **Integrity and backup:** a `dksearch check` command verifies SQLite integrity, hashes of stored content against records, and orphan content. Backup is `sqlite3`-style online backup of `state.db` and `content.db` (the index is excluded because it is rebuildable); documented in a manpage when the command exists.
- **Raw source retention is separate from normalized text.** Retaining the original archive (for example a Wikipedia dump) is the administrator's choice and lives wherever they keep it; connectors read from it. Only normalized text and metadata go in `content.db`.

## Alternatives

- **One database for everything:** simplest, but ties index, state and bulk text to one file, so backing up the state means copying the largest file, and pruning content needs a full-file vacuum that blocks everything.
- **Files on disk (one per document, content-addressed):** easy to inspect, but millions of small files are slow and awkward for backup on most filesystems, and there is no atomic link with metadata.
- **Packed append-only segment files plus offsets:** compact and fast for bulk, but it means writing and maintaining our own storage engine, compaction and crash recovery, which is what using a database avoids (ADR 0003 rationale).
- **A different embedded database (LMDB, RocksDB, DuckDB):** another vendored C/C++ dependency for no capability SQLite lacks at this scale.

## Consequences if accepted

- No new dependency; SQLite is already built in. All persistent data remains one well-understood file format, readable with any SQLite tool.
- SQLite is a single-writer database per file. Ingestion writes are serialized per file; this is adequate for one importer at a time and is revisited if concurrent imports are needed.
- Very large single files (hundreds of GB) are possible but unpleasant to copy and vacuum; if a source outgrows that, content can be sharded across several `content.db` files behind the same interface without changing callers.
- Migrations and backups for `state.db` and `content.db` become a maintenance responsibility we must test (crash during migration, version mismatch, restore).

## Retention (decided)

Per-source retention (SPEC section 4.1: some sources forbid keeping text) (SPEC section 4.1: some sources forbid keeping text) should be enforced in the pipeline only, as today with `retain_text`, or also by keeping such sources in a separate content file that can be deleted wholesale. Decided: it stays in the pipeline (`retain_text`), not in separate files.

## Implementation status

Implemented (2026-11-14), with tests:

- `src/sqlite.zig`: shared statement helpers and `migrate`. A file older than the code is first copied to `PATH.pre-vN` (made with `VACUUM INTO`), then each missing step runs in its own transaction together with its version bump; a failing step rolls back and leaves the version unchanged (`MigrationFailed`); a file newer than the code is refused untouched (`NewerSchema`).
- `src/content_sqlite.zig` (`SqliteContentStore`): zlib-compressed text with a SHA-256 and size per row. Reads re-check checksum, hash and size and report `Corrupt` rather than returning damaged text; the recorded size bounds decompression. Defaults to `synchronous=FULL` because it is source-of-truth data.
- `src/state_sqlite.zig` (`SqliteStateStore`): the `DocumentStore` implementation (full metadata as JSON plus indexed id/connector/source columns; the main text is never stored here) and the job tables with `startJob`, `saveCheckpoint`, `finishJob`, `getJob` and `resumePoint`. Jobs found `running` at open time are marked `interrupted`, and their last checkpoint is the resume point.
- A pipeline run over these stores followed by a rebuild into an empty index reproduces the same hits.

Not yet done: nothing creates `state.db` or `content.db` from the command line (no importer exists yet); the `dksearch check` integrity command and the backup procedure are still to be written, with their manpage text; orphan content (content written but its record never committed) is not yet detected or reclaimed.

A note for developers: the file-backed tests create temporary directories under `.zig-cache/tmp`. On a filesystem with slow metadata operations they can take seconds each even though synchronous writes are disabled in them.
