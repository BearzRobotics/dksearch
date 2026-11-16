# Source selection

Sources should be first-class in search, not an incidental filter. This note is the baseline and the test plan; the research projects feed ideas into it.

## Today (from the code, 2026-11-16)

- The public page has a Source drop-down: "All sources", then sources grouped by kind with an "All <kind>" choice.
- The query language has `source:NAME` (repeated means any of them) and `-source:NAME`; the API takes `connector=` and `filter=source:...`. A kind selection is turned into alternatives of its sources.
- Every result carries its source name (`connector` in the API) and is attributed on the page.
- A document's id derives from the source name and the id the source gave it, so the same file indexed by two sources is two documents.
- Per-source: boost (ranking), schedule, enabled flag, rights, and `serve_originals` for local files.
- Search itself reads only the local index, so a source whose files or server are unreachable does not affect searching what was indexed from it. What does depend on the source being present: opening originals, the ZIM viewer, and re-importing. (Read from the code; to be confirmed by a test, see below.)

## Gaps

Saved source groups; a configurable default scope (per instance, later per API key); source status shown next to the selection (last import, document count, reachable or not); source-specific filters and ranking beyond a single boost; handling of duplicates across sources (group by content hash, show "also in"); the same selection syntax in UI, query language and API (a group name usable as `source:group` and as a parameter).

## Test plan

Each item becomes an automated test unless marked manual.

1. All sources, one source, several sources, a kind: results come only from the chosen ones (UI and API agree).
2. A saved group (once built): same as several sources; unknown group is a clear error.
3. A selected source that is disabled, removed from the configuration, or whose data is unreachable: the search still succeeds; the page says what happened if something is missing.
4. The same document in two sources: both appear, each attributed to its own source; later, grouping.
5. Filters (`ext:`, `modified:`, `type:`) apply within the selected sources only.
6. Every result shows its source, in the page, the API and the viewer.
7. The viewer and originals for a selected source whose file has disappeared fail cleanly (manual first).

## Open questions

Should a group be defined in the configuration file, in the admin panel, or both (the panel edits the file today)? Should the default scope be a group or a list? Should an unreachable source be shown greyed out in the drop-down?
