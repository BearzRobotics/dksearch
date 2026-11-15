# 0020. Regular-expression search

- Status: Accepted (2026-11-15), the user's answers: a filter over word matches; the user's own regex-zig as the engine; public use with strict limits
- Date: 2026-11-15

## Context

The user asked for advanced search, regex first. The options offered were: a filter over word matches, or also full scans; the vendored PCRE2 or a new linear-time engine; admin-only or public. The user chose the filter over word matches, proposed using regex-zig (their own library, https://github.com/BearzRobotics/regex-zig) as the engine, and chose public access with strict limits.

## Decisions

1. **A filter over word matches.** The words of the query choose candidate documents through the index (FTS5, in ranking order). The regular expression is then checked against each candidate's stored text (`content.db`), and a snippet is built around the first match. A query without a word is refused, so no query ever scans the corpus. SQLite and FTS5 stay the only index; there is no trigram index.
2. **regex-zig, vendored** at version 0.1.0 (`vendor/regex-zig`, revision recorded in `VENDORED_REVISION`; the latest release when this was written). It is pure Zig, matches the project rules (vendored, no new C code) and was reviewed first: it provides Perl, Oniguruma and POSIX ERE parsers and a bounded backtracking engine with a step budget and stack cap. Its gaps are known and documented: no LICENSE file upstream yet (the code is the project owner's own), bytewise matching only (no UTF-8 mode, no `\p{..}`), and no linear-time engine yet (its SPEC lists one as future work). dksearch therefore relies on the step budget, not on a linear-time guarantee, and has its own tests around hostile patterns. Moving to the linear-time engine later changes nothing in the API or configuration.
3. **Public, with strict limits** (the user's choice). Anyone who can reach the page can type a pattern, so everything is bounded: pattern length (200 bytes), nesting and repeat counts and compiled size (at compile time); matching steps per document (100,000) with the pattern refused as too complex when several documents exhaust them; candidates checked (200); the first 1 MiB of each text; a wall-clock budget per query (500 ms); and at most 2 regex queries at once, the next waiting 250 ms and then getting HTTP 429. All are configurable in a `[search]` table, the filter can be switched off, and the administration interface (query-testing page and API) gets ten times the limits. Ordinary word searches are unaffected: they never touch the content store or the regex semaphore.
4. **Reading the texts.** `serve` opens `content.db` through a small pool of read-only connections (`content_sqlite.ContentPool`), which refuses every write. If there is no `content.db` yet the filter is off and `serve` says so.
5. **Honest results.** The response says how many candidates were examined and whether a limit ended the search early (`regex.truncated`, and `has_more` is then true). Errors have stable codes (`invalid_pattern` with reason and position, `pattern_too_complex` 422, `busy` 429, `regex_disabled`, `empty_query`).
6. **Byte semantics.** Because the engine is bytewise, `.` matches one byte; snippets are widened to character boundaries so they stay valid UTF-8, and control characters in snippets (including the highlight markers) are turned into spaces.

## Not done

Unicode-aware matching and classes (waits for regex-zig); a linear-time engine; regex-only queries (no words) with an explicit scan cap; searching titles or metadata fields separately; saved or named patterns.
