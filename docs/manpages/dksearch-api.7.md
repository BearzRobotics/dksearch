% DKSEARCH-API(7) Version 0.0.0 | Project Manual
% dksearch contributors
% 2026-11-14

NAME
dksearch-api - HTTP interface of dksearch: JSON API version 1 and the HTML search page

SYNOPSIS
GET /api/v1/search?q=TEXT[&language=L][&content_type=T][&connector=C][&limit=N][&offset=N][&regex=PATTERN[&regex_flags=i][&regex_dialect=perl|ere]]

GET /api/v1/health

GET /, GET /search?q=TEXT[&language=L][&connector=C][&offset=N]

GET /assets/style.css

DESCRIPTION
The public, read-only interface served by dksearch(1). It needs no authentication. Every endpoint accepts GET and HEAD only; any other method receives 405 with `Allow: GET, HEAD`. Request bodies are refused with 400 and the connection is closed.

There are two adapters over the same search service. The JSON API under `/api/v1/` is for programs. The HTML pages are for people and need no JavaScript.

CONVENTIONS
Parameter values are percent-encoded; `+` in a query string means a space. Parameter and path names are case-sensitive. Paths are matched exactly: they are not percent-decoded, and a trailing slash is a different path. If a parameter is repeated, the first occurrence is used. Unknown parameters are ignored.

COMMANDS
GET /api/v1/search
Run a search.

Parameters:
q
: Required. The text to search for. Words are combined with AND. Text in double quotes is a phrase. Everything else, including `AND`, `OR`, `NEAR`, `*`, `-`, parentheses and `column:` prefixes, is searched as ordinary text and has no special meaning. At most 1024 bytes and 32 terms. A query with no letters or digits is an `empty_query` error.

language, content_type, connector
: Optional exact-match filters on the document's language tag, media type and source connector. At most 64 bytes, no control characters. An empty value means no filter.

limit
: Optional page size. Default 10, maximum 100.

offset
: Optional number of hits to skip. `offset + limit` may not exceed 10000. With `regex`, it counts matching hits.

regex, regex_flags, regex_dialect
: Optional regular-expression filter. The words in `q` choose the candidate documents through the index, in ranking order; the pattern is then checked against each candidate's stored text and only matching documents are returned, with a snippet around the first match (marked with the same `\u0002` and `\u0003` bytes). `q` must therefore contain at least one word: the filter never scans the whole corpus. `regex_flags` may be `i` for ignore case. `regex_dialect` is `perl` (the default: classes, groups, alternation, repetition, lazy and possessive quantifiers, back-references, look-around, `\d \w \s \b`) or `ere` (POSIX extended). The pattern is matched on bytes, not characters, so `.` matches one byte of a multi-byte character; unsupported constructs (for example `\p{L}`) are refused. The server limits it strictly (see `[search]` in dksearch(1)): at most 200 bytes of pattern, 200 candidate documents, 500 ms in total and a bounded number of matching steps per document by default. The response then has an additional member, `"regex": {"examined": N, "truncated": B}`: how many candidates were checked, and whether a limit ended the search early, so that more matches may exist (`has_more` is then true as well). Errors: 400 `invalid_pattern` (with the reason and position), `invalid_parameter` for bad flags or dialect, `empty_query` when `q` has no words, `regex_disabled` when the server has turned the filter off; 422 `pattern_too_complex` when the pattern ran out of steps on several documents; 429 `busy` (with `Retry-After`) when too many regex searches are running.

Response: 200 with `application/json`:

    {
      "hits": [
        {
          "id": "2715fef3ff2a8b8ffcb1039525a6e4d5",
          "connector": "gutenberg",
          "url": "https://example.org/pg1342",
          "title": "Pride and Prejudice",
          "snippet": "It is a \u0002truth\u0003 universally acknowledged",
          "score": 0.42
        }
      ],
      "has_more": false
    }

`id` is the 32-hex-digit stable document id. `url`, `title` and `snippet` may be null. `score` is higher for better matches and is comparable only within one response. Hits are ordered by score, ties by id, so paging an unchanged index is stable. `has_more` says whether another page follows. `snippet` brackets matched text with the control characters U+0002 and U+0003 (JSON `\u0002`, `\u0003`); a client must escape the text for its output format first and only then replace the markers with its own markup. Snippets come from untrusted documents and may themselves contain such characters.

GET /api/v1/health
Returns 200 and `{"status":"ok"}`. It reports that the process is serving requests and nothing about the index.

GET /search and GET /
HTML pages. `/` is the search form. `/search` takes `q`, `language`, `connector`, `offset` and, when the server offers it, `regex` and `regex_flags` (the search form has a Regex field under Filters); the page size is fixed at 10 and any `limit` is ignored. Result URLs are links only if they begin with `http://` or `https://`; otherwise they are shown as text. An empty `q` shows the form again.

GET /assets/style.css
The stylesheet, cacheable for one hour. All other responses are `Cache-Control: no-store`.

OPTIONS
None beyond the query parameters above.

OPERANDS
None.

INPUT
Request heads larger than `server.max_header_bytes` receive 431. A request target is at most 8192 bytes, must start with `/`, may not contain spaces or control characters, and may have at most 32 query parameters; otherwise the response is 400 with a plain-text body. Percent-escapes must be valid and decode to valid UTF-8.

OUTPUT
Errors from `/api/` have the form:

    {"error": {"code": "empty_query", "message": "the query has no searchable terms"}}

Code	Status	Meaning
invalid_parameter	400	A parameter is malformed (for example `limit=abc`); the message names it.
empty_query	400	`q` is missing or has no searchable terms.
invalid_query	400	The query is too long or has too many terms, or `limit`/`offset` are out of range.
not_found	404	No such endpoint.
method_not_allowed	405	Method other than GET or HEAD.
internal_error	500	The search failed. The cause is never included; it is for the operator's logs.

Messages are for humans and may change; the codes are stable. Every response, including errors, carries `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`, `Cross-Origin-Resource-Policy: same-origin` and a Content-Security-Policy with `default-src 'none'` that allows stylesheets and scripts only from the same origin, never inline (the only script is the administration interface's `/assets/admin.js`, which updates import progress; the public interface serves none). HTML responses are `text/html; charset=utf-8`; JSON is UTF-8.

EXIT STATUS
Not applicable.

ENVIRONMENT
Not applicable.

FILES
Not applicable.

CONFIGURATION
Limits are set in the `[server]` table of the configuration file; see dksearch(1).

EXAMPLES
Basic use
    curl 'http://127.0.0.1:8080/api/v1/search?q=truth'

Phrase, filtered, second page
    curl 'http://127.0.0.1:8080/api/v1/search?q=%22truth+universally%22&language=en&limit=10&offset=10'

DIAGNOSTICS
A 400 with a plain-text body means the request target itself was malformed. A connection closed without any response means a limit or timeout in dksearch(1) was exceeded.

SECURITY CONSIDERATIONS
See dksearch(1). In particular, never insert `snippet` into HTML without escaping it first.

PRIVACY
The API sets no cookies and keeps no per-client state.

RESOURCE USAGE
A response contains at most 100 hits.

PERFORMANCE
Not measured.

CONCURRENCY AND ATOMICITY
Each request is independent. A search sees a consistent snapshot of the index.

SIGNALS
Not applicable.

NETWORK
HTTP/1.1 over plain TCP; keep-alive is supported. See dksearch(1) for timeouts and connection limits.

COMPATIBILITY
Platforms
Any HTTP client.

Standards
JSON (RFC 8259); HTTP semantics (RFC 9110) as far as implemented.

Stability guarantees
Within `/api/v1/`: adding response fields or optional parameters is allowed, so clients must ignore unknown fields. Removing a field, changing its meaning, or changing error codes requires a new version `/api/v2/`. A superseded version stays available for a documented period. The HTML pages and their markup are not part of the stable API.

ADMINISTRATION API
The administration interface is a separate listener (see dksearch(1), `admin.*`), not part of the public API above. It has the same conventions (JSON, `error` objects with stable codes, `no-store`), accepts GET and HEAD for data, and requires authentication: `Authorization: Bearer TOKEN` (see **dksearch admin-token**) or a session cookie from signing in at `/login`. Without it the API answers 401 with `WWW-Authenticate: Bearer` and code `unauthorized`; pages redirect to `/login`. The endpoints below are read-only except the two that start and cancel imports, which work only when the server is configured with `admin.actions = true` (otherwise they answer 403 with code `actions_disabled`).

GET /api/v1/admin/status
: Returns `version`, `uptime_seconds`, `documents` (total), `data_bytes` (`index`, `state`, `content`, null when a file is absent), `auth` (`token`, `password`: whether set; `sessions`: live sessions), and the counters `public` and `admin`, each with `requests`, `status_2xx` to `status_5xx`, `latency_le_10ms`, `latency_le_50ms`, `latency_le_250ms`, `latency_le_1000ms`, `latency_over_1000ms`, `connections_accepted`, `connections_refused_busy`, `connections_timed_out` (all since the process started).

GET /api/v1/admin/sources
: Returns `sources`: one entry per configured source (`name`, `kind`, `enabled`, `configured: true`, `documents`, `last_job`) and one per name that has documents but is no longer configured (`configured: false`).

GET /api/v1/admin/jobs
: Returns `jobs`: the 50 most recent import jobs, newest first (`id`, `source`, `kind`, `state`, `started_at`, `finished_at` as Unix seconds or null, `submitted`, `rejected`, `skip_reasons` (an object with the counts `robots`, `network`, `certificate`, `http_status`, `wrong_type`, `too_large`, `encoding`, `no_text`, `redirect` and `limit`; they add up to at most `rejected`, because only some connectors say why they skipped something), `error_message`). A job shown as `running` may belong to an import that was killed; it is marked interrupted the next time a command opens the data.

GET /api/v1/admin/search
: Runs a search like the public API (`q`, optional `language` and `connector`, at most 20 results) and returns `hits` with their ranking `score`, plus `tokenizer`, `title_weight` and `body_weight`, so ranking can be inspected. Same errors as the public search (`empty_query`, `invalid_query`). The HTML page `/search` is the same thing for people.

GET /api/v1/admin/imports
: Returns `actions` (whether imports can be started), `running` (`source`, `started_at`, `submitted` so far, `progress_done` and `progress_total`: the connector's own measure of how far it is, such as bytes of a dump read or files handled, with a total of 0 when it cannot tell; or null) and `last` (the last import started through this interface since the process began: `source`, `state`, `submitted`, `rejected`, `skip_reasons` (as for jobs), `failure`, `finished_at`, or null).

POST /api/v1/admin/imports
: Starts an import of the source named by the form field `source` (`application/x-www-form-urlencoded` body). Returns 202 with `started`. Errors: 404 `unknown_source`, 409 `source_disabled`, `already_running` or `locked` (another import, rebuild or removal holds the data directory), 403 `actions_disabled`.

POST /api/v1/admin/imports/cancel
: Asks the running import to stop at its next safe point (its position is saved). Returns 200 with `cancelling` (false if nothing was running).

The HTML pages `/` (dashboard) and `/jobs`, `POST /login` (field `credential`: the password or the token), `POST /logout` and, with actions enabled, `POST /actions/import` (fields `source`) and `POST /actions/cancel` are for browsers; the last three carry the per-session form token in the field `csrf`. The same compatibility rules apply: fields may be added within `v1`.

LIMITATIONS
No document endpoints. The administration API can start and cancel imports only when enabled, and cannot rebuild, remove, back up or change configuration. No sorting options, total counts, or faceting. The public API has no authentication or rate limiting; the administration API requires a credential.

BUGS
See dksearch(1).

TROUBLESHOOTING
Empty `hits` for a query that should match: check the filters, and check that the index is populated (see **import** in dksearch(1)).

NOTES
Document ids are derived from the connector name and the source's own identifier, so the same item keeps the same id across re-imports and index rebuilds.

CAVEATS
Scores are not comparable between different queries.

HISTORY
Version 1 of the API is introduced with dksearch 0.0.0.

DEPRECATION
Nothing is deprecated.

SEE ALSO
dksearch(1)

AUTHOR
dksearch contributors.

COPYRIGHT
Copyright 2026 dksearch contributors. SPDX-License-Identifier: GPL-2.0-only

LICENSE
GNU General Public License, version 2 only. See dksearch(1).

AVAILABILITY
Not yet published.

VERSION
This manual describes the `/api/v1/` interface of dksearch version 0.0.0.
