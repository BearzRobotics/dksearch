# 0029: Ranking controls, stop words and synonyms, schedules, skip examples

Status: implemented.

## Context

The admin panel is meant to be feature complete, and a personal search engine needs to be tunable by its owner without code changes: which sources count more, whether newer is better, what common words to ignore, how to import regularly, and why some pages were skipped.

## Decision

- **Ranking.** The score is the weighted text match (`[search] title_weight`, `body_weight`, default 10 and 1 as before) times a per-source `boost` (percent, default 100, set on the source) times an optional recency factor `1 + recency_boost% / (1 + age / half_life)` (`[search] recency_boost`, `recency_half_life_days`; off by default). Everything is a multiplication in the same SQL expression, so ordering stays one pass and needs no exponentials. The API's `explain=1` returns the factors (and the title and text matches on their own; FTS5 weighs word counts before saturating them, so those two do not add up to the text score). Source boosts are read from the live source list on each search, so editing one applies at once; weights and recency apply at restart.
- **Stop words and synonyms.** Plain files (`stop_words_file`, `synonyms_file`), off unless set, applied only when a query is read, never to the index, so changing them needs no rebuild. Stop words are dropped from plain words (not phrases) unless nothing else would be left. A synonym group widens a plain word into an OR of the members (members of several words are phrases). A malformed file stops the server at start with the line number, rather than silently searching without it.
- **Schedules.** A source may say `schedule = "daily"` (or `6h`, `30m`, `weekly`, ...). The server checks every 30 seconds and starts the most overdue due source through the same job manager as the buttons (one task at a time, the writer lock, resumable). Counted from the start of the last job; a failed run is retried after one interval. It needs `admin.actions`. Cron expressions were rejected: intervals cover the need, and external timers remain available (`docs/deploy`).
- **Skip examples.** Connectors that can name what they refuse (crawl: the address; files: the path) keep up to twenty examples per reason (a hundred per run), stored with the job in a new `job_skips` table (state.db migration 3) and shown from the Jobs page and at `/api/v1/admin/jobs/skipped`. The counts remain the complete record. A new reason `unreadable` covers local files that could not be read or understood. `serve` brings an older state.db up to date at start, because the admin pages open it read-only.

## Alternatives

- Boosts in the index: would need a rebuild to change.
- Index-time stop words: would need a rebuild and hide words from phrase searches.
- A cron parser: more to get wrong for little gain.
- Storing every skipped address: unbounded for large crawls.

## Consequences

- bm25 scores of a boosted or recency-weighted search are no longer comparable with unweighted ones (they never were comparable across searches).
- Skip examples are a sample by design; the first twenty per reason are kept, not the most interesting.
