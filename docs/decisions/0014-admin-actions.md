# 0014. Admin actions: starting and cancelling imports

- Status: Accepted (2026-11-14), within the maintainer's standing request to continue Milestone 4; opt-in and reversible
- Date: 2026-11-14

## Context

ADR 0012 made the administration interface read-only and left job controls for a separate decision, because they need a job runner inside the server process and a lock protocol with the command line. SPEC milestone 4 asks for import job visibility and controls.

## Decisions

1. **Off by default: `[admin] actions = false`.** With it off, the interface is strictly read-only, exactly as ADR 0012 describes, and the action routes answer 403 `actions_disabled`. A deployment that wants the controls turns them on explicitly.
2. **One action pair: start an import of a configured, enabled source; cancel the running import.** No rebuild, removal, backup or configuration editing from the web: rebuild leaves the index partial while the server answers queries, removal is irreversible, and configuration editing needs its own design (validation, atomic replace, reload). They stay on the command line.
3. **A background manager in the core (`src/jobs.zig`), not in the HTTP layer.** It runs one import at a time in a background task using the same runner as `dksearch import`, with its own database connections, and records the last outcome in memory. The job history itself still lives in `state.db`, which is what the dashboard and the jobs page show.
4. **The writer lock is shared with the command line.** The manager takes `data_dir/write.lock` when an import starts (so "locked" is reported to the caller at once) and releases it when the run ends. A command-line import, rebuild or removal cannot run at the same time, and neither can a second manager run. The server process itself does not hold the lock while idle, so the command line works whenever no import is running.
5. **Same authentication, plus CSRF for sessions.** Actions are POSTs. A bearer token needs no form token (it is not an ambient credential); a browser session must send its per-session form token. Responses: 202 with `started` for the API, a redirect to the dashboard for forms; 404 unknown source, 409 disabled source, already running, or lock held.
6. **Cancelling is cooperative**: the import stops at its next safe point and its position is saved, so a later run resumes (ADR 0008). Shutting the server down cancels a running import and waits for it.

## Consequences

- With actions on, the server process writes to `state.db`, `content.db` and `index.db` while serving; this is the same concurrency the command-line import already has with a running server, which is tested.
- The admin dashboard gains an Imports panel (buttons per enabled source, live document count, cancel, last result), and the API gains `GET/POST /api/v1/admin/imports` and `POST /api/v1/admin/imports/cancel`.
- Running imports through the web increases what a stolen admin credential can do (it can make the server read any path a configured source points at, though it cannot change which paths, since sources come only from the configuration file). It cannot delete anything.
