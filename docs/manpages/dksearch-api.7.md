% DKSEARCH-API(7) Version 0.0.0 | Project Manual
% dksearch contributors
% 2026-11-14

NAME
dksearch-api - HTTP interface of dksearch: JSON API version 1 and the HTML search page

SYNOPSIS
GET /api/v1/search?q=TEXT[&language=L][&content_type=T][&connector=C][&limit=N][&offset=N]

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
: Optional number of hits to skip. `offset + limit` may not exceed 10000.

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
HTML pages. `/` is the search form. `/search` takes `q`, `language`, `connector` and `offset`; the page size is fixed at 10 and any `limit` is ignored. Result URLs are links only if they begin with `http://` or `https://`; otherwise they are shown as text. An empty `q` shows the form again.

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

Messages are for humans and may change; the codes are stable. Every response, including errors, carries `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`, `Cross-Origin-Resource-Policy: same-origin` and a Content-Security-Policy with `default-src 'none'`. HTML responses are `text/html; charset=utf-8`; JSON is UTF-8.

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

LIMITATIONS
Read-only; no document or administration endpoints yet. No sorting options, total counts, or faceting. No authentication or rate limiting.

BUGS
See dksearch(1).

TROUBLESHOOTING
Empty `hits` for a query that should match: check the filters, and check that the index is populated (dksearch(1) cannot yet import documents).

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
