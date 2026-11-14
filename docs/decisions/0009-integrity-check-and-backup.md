# 0009. Integrity check and backup

- Status: Accepted (2026-11-14), as proposed in the working session ("sound good")
- Date: 2026-11-14

## Context

`state.db` (document records, job positions) and `content.db` (retained text) are the only copy of what was imported; `index.db` is derived (ADR 0003, ADR 0006). Until now there was no way to verify them or to copy them safely: a plain file copy of a WAL-mode database taken while an import writes can be inconsistent.

## Decisions

1. **`dksearch backup [--config FILE] DIR`** copies `state.db` and `content.db` with SQLite's `VACUUM INTO` from a read-only connection. That produces a consistent snapshot at one instant, without stopping `serve` or `import`, and compacts the copy. The copy is synced and verified with `PRAGMA integrity_check` before success is reported. It never overwrites an existing file. The index is not copied: `rebuild` recreates it. Alternative considered: SQLite's online backup API, which is equivalent for this purpose but needs a page-copy loop; `VACUUM INTO` is one statement and is already used for migration backups (`sqlite.migrate`).
2. **Ordering.** `state.db` is copied before `content.db`. An import commits content before the records that refer to it, so a later content snapshot contains every text an earlier records snapshot refers to. The two copies are therefore mutually consistent even if an import ran during the backup; at worst the content copy holds extra, harmless texts.
3. **`dksearch check [--config FILE]`** is read-only: it opens files with `SQLITE_OPEN_READONLY`, never creates a missing file, never upgrades an older schema and never marks running jobs interrupted (the normal state-store open does that, which would corrupt the bookkeeping of a running import). Besides SQLite's integrity check it verifies every retained text against its stored size and SHA-256, because page-level checks do not see damaged payload bytes (confirmed by test and by damaging a real file). Exit status is 1 only for damage; missing text, unreferenced text or an index that disagrees with the records are reported as notes.
4. Both live in the core (`src/maintenance.zig`), so the executable stays a thin wrapper and SQLite remains internal to the core.

## Not done

Scheduling, retention, encryption of backups, restoring through a command (the manual procedure is in the manpage), and preventing two `import` processes from running on one `data_dir` at the same time (documented as unsupported; the second would mark the first's running job interrupted when it opens the state store).
