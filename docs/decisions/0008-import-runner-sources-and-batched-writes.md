# 0008. Import runner, optional sources and batched durable writes

- Status: Accepted (2026-11-14), implementing decisions 0006 and 0007
- Date: 2026-11-14

## Context

Decisions 0006 and 0007 settled persistent storage and the first connectors, and required that no one be forced to use a connector. Before any dataset connector could be built, three things were missing: a driver that runs a connector into the pipeline and records the run, a way to configure sources, and writes that are both durable and fast enough for bulk imports.

A first end-to-end run showed why the last one matters. Importing three files took 70 seconds, because every document caused several separately synced commits, and this development machine's disk takes seconds per sync. Even on fast disks, per-document syncs would make a large import impractical.

## Decisions

1. **The runner** (`src/runner.zig`) drives one connector into the pipeline. It finds the resume position, writes a job record, gives the connector a `Sink`, and records how the run ended (completed, failed with a reason, cancelled). Connectors know nothing of stores or jobs. The `Sink` gained an optional `checkpoint` hook, so a connector can report its position while running, not only when it finishes.

2. **Sources are optional configuration.** `[[source]]` tables with `name`, `kind`, `enabled`, `retain_text`, and connector-specific options that the connector itself validates. No source is required; none are enabled by default. `check-config`, `serve` and `import` validate every source (enabled or not). Documents carry the source *name* as their `connector`, so two sources of the same kind never collide.

3. **Writes are batched, with a fixed commit order.** The pipeline can open a batch across the content store, the index and the document store (`beginBatch`/`commitBatch`/`abortBatch`). A batch is committed content first, then index, then document records, and only after that is the connector's position saved. This ordering is the durability argument: after a crash there may be content or index entries with no record (a re-import repeats them harmlessly), but never a record, or a saved position, that points at content that was lost. A batch ends at each connector checkpoint, or after 1000 documents. The stores keep `synchronous=FULL`; the saving comes from syncing once per batch instead of once per document, not from weakening durability.

4. **A saved position never runs ahead of durable data.** If a commit fails, the batch is rolled back and the runner reports only the last position that was committed, ignoring the position the connector hands back after being stopped.

5. **Delivery is at-least-once.** After a crash or failure a resumed run may deliver some documents again; the pipeline's duplicate detection (content hash plus revision) makes that a no-op. Exactly-once delivery was not attempted.

6. **Counting.** `Control.rejected` now means items the connector itself refused (too large, malformed); documents the pipeline rejects are counted by the runner. The job and the summary report both, as "skipped".

7. **A first real connector, `files`**, for `.txt` and `.md` under a directory. It is listed in the SPEC (local files) and let the whole path be tested end to end with no external data. It is safe by default: no symlinks followed, hidden entries skipped, size limit, UTF-8 and NUL checks. It is a bundled connector like any other and gets no private access.

8. **Commands:** `dksearch import --config FILE (SOURCE | --all)` and `dksearch rebuild`, documented in `dksearch(1)`.

## Bugs found by tests while building this

Recorded because they shaped the design:

- After a failed commit, the connector's own reported position covered documents that had been lost; trusting it would have made a resume silently skip them. Fixed by decision 4, with a test.
- A batch whose commit failed partway was marked closed before the commits ran, so the abort did nothing and a transaction stayed open on the database connection. The batch now stays open until every store has committed.
- A signal arriving while the databases are still being opened kills the process with the default action; this is accepted, since nothing has been written yet.

## Verified with the real program

On a 450-file tree: an import interrupted by SIGINT after its first batch recorded 100 documents and the position `f0099.txt` as `cancelled`; running the same command again imported only the remaining 350; a third run found all 450 unchanged; all documents, from before and after the interruption, were searchable; deleting the index and running `rebuild` restored it from the stores; the server kept answering every request while an import wrote.

## Consequences

- Any later connector (Gutenberg, Wikipedia, local feeds) only has to implement the `Connector` interface and call `sink.checkpoint` at points where its position is complete; resumability, job records, batching and durability come from the runner.
- A connector that never checkpoints still commits every 1000 documents, but then cannot resume mid-run.
- One batch is held in open transactions, so a very slow commit holds the write lock on the three databases for its duration. Imports and `rebuild` are single-writer operations.

## Not done

Removing a source's documents, deleting documents whose files vanished, a `check` command, backup procedure, concurrent imports of different sources, and per-source schedules.
