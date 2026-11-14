# 0010. Removing documents

- Status: Accepted (2026-11-14), as proposed in the working session ("lets get started")
- Date: 2026-11-14

## Context

Until now documents could only be added or updated. A file deleted from disk, or a source dropped from the configuration, stayed searchable. The stores, index and pipeline all had delete operations, but nothing used them.

## Decisions

1. **`Pipeline.remove(id)`** deletes the retained text, the index entry and then the record, in that order. The record goes last, as in `submit`, so a crash leaves a record that a repeated removal still lists and finishes. The batch commit order is unchanged (content, index, records).
2. **`dksearch remove SOURCE [--yes]`** removes everything a source name owns, in committed batches of 1000, and forgets the source's job history so a later import starts from the beginning. It is a dry run without `--yes` because the removal cannot be undone (re-importing restores it, if the source still exists). SOURCE need not be configured.
3. **`dksearch import --prune`** removes documents of the source that the connector reports gone. This is a connector capability: an optional `exists(source_id)` that answers `present`, `gone` or `unknown`. Only `gone` removes; a connector without it, an unreadable source, or any error yields `unknown`, so an unmounted disk can never empty an index. Pruning runs only after a completed import and only when asked for: deleting by default would turn a transient problem into data loss.
4. **Listing** uses a new document-store operation that pages by source id over the existing `(connector, source_id)` index, so each page costs its size, and paging stays correct while documents are being deleted.
5. `files` treats a path that is no longer a regular file as gone. `gutenberg` treats a book with no remaining local file as gone; a book that a changed `language` option would now skip is not treated as gone.

## Not done

Pruning on a schedule, a soft-delete or trash state, and removal by filter other than the whole source. Texts left behind by a crash between batches are found by `dksearch check` as unreferenced and are harmless.
